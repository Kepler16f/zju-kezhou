/// data/ai_client.dart — 可切换的 AI 客户端（OpenAI 兼容 / Anthropic / Dify）。
///
/// 职责：把「配置 + 系统提示 + 消息列表」变成一次 HTTP 调用，再把响应翻译成
/// AiReply（成功文本）或 AiFailure（带分类的失败），供上层 AI 助手页直接展示。
///
/// 红线（违反任何一条都会造成安全事故或整条链路降级，改代码前先读完）：
///  1. apiKey 只进请求头：绝不写进日志、异常文案与失败提示。本文件所有对外的
///     message 都过一遍 _redact —— 有的网关会把请求头原样回显在错误正文里，
///     不做清洗就有把密钥泄进 UI 的风险。
///  2. TLS 必须走默认校验：绝不给 HttpClient 设 badCertificateCallback。
///     教务网那套「容忍校园 portal 自签名证书」是内网权宜之计，公网 AI 服务绝不可复制，
///     否则任何中间人都能截走用户的 apiKey（而密钥是按次计费的真金白银）。
///  3. 网络必须走后台 isolate：顶层函数 + 只传 String/int/Map 载荷，禁止闭包捕获 this。
///     历史回归（zju_client 0.10.5 实测教训）：闭包直接内嵌在实例方法里时，会与引用
///     this 的兄弟闭包共享 Context，序列化连带实例字段（含 Future）→ unsendable →
///     全部请求抛异常降级。本文件因此把 isolate 载荷压成纯 Map，且让持有闭包的顶层函数
///     作用域里只有那个 Map，从结构上排除捕获实例的可能。
///
/// 设计取舍：
///  - 零新依赖：只用 dart:io / dart:isolate / dart:convert（http、dio 一律不引）；
///  - sender 可注入：AiHttpSender 让单测用假发送器覆盖重试与错误分类，不发真实网络；
///  - 重试只针对 server / timeout / network：服务端故障与网络抖动重试有价值，
///    认证、限流、参数错误重试只会放大风控与账单，一律不重试。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'ai_config.dart';
import 'ai_models.dart';

/// HTTP 发送器契约：默认是后台 isolate 实现，单测可换成假发送器。
typedef AiHttpSender = Future<AiHttpReply> Function(AiHttpRequest req);

/// 一次 HTTP 调用的完整描述（值对象，字段全部可序列化，便于压成 isolate 载荷）。
class AiHttpRequest {
  const AiHttpRequest({
    required this.url,
    this.method = 'POST',
    this.headers = const <String, String>{},
    this.body = '',
    this.timeout = const Duration(seconds: 60),
  });

  final String url;
  final String method;
  final Map<String, String> headers;
  final String body;

  /// 响应读取超时（连接超时另由 isolate 内的 connectionTimeout 管）。
  final Duration timeout;
}

/// 原始 HTTP 结果（未做任何业务解释，解释交给 parseReply）。
class AiHttpReply {
  const AiHttpReply(this.status, this.body);

  final int status;
  final String body;
}

/// 流式传输事件（后台 isolate → 主 isolate）。
/// 不直接传异常对象：跨 isolate 传输异常上下文既不可靠，也可能带出请求头。
sealed class AiStreamEvent {
  const AiStreamEvent();
}

/// 响应头已到达（状态码）。
class AiStreamMeta extends AiStreamEvent {
  const AiStreamMeta(this.status);

  final int status;
}

/// 一行响应正文（SSE 的 data: 行，或非流式 JSON 的一行）。
class AiStreamLine extends AiStreamEvent {
  const AiStreamLine(this.line);

  final String line;
}

/// 传输失败（已转成可读文本，不含密钥）。
class AiStreamError extends AiStreamEvent {
  const AiStreamError(this.message);

  final String message;
}

/// 流式发送器契约：默认实现把收发放进后台 isolate；单测可注入同步流。
typedef AiStreamSender = Stream<AiStreamEvent> Function(AiHttpRequest req);

/// 失败分类：决定 UI 该提示「改配置」「稍后再试」还是「重试按钮」。
enum AiFailKind {
  /// 401/403：密钥无效或无权限。重试无意义，只能引导用户改配置。
  auth,

  /// 429：触发限流。重试只会火上浇油，应提示稍后再试。
  rateLimit,

  /// 400/422：请求本身不合法（模型名错、参数被拒）。重试等于把同样的错误再买一次。
  badRequest,

  /// 5xx：服务端故障。可重试（本文件自动重试 1 次）。
  server,

  /// 超时（连接或读取）。可重试。
  timeout,

  /// 网络层失败：断网、连接被拒、TLS 握手失败。可重试。
  network,

  /// 2xx 但正文为空（模型没吐字）。
  empty,

  /// 模型明确拒绝回答（Anthropic stop_reason=refusal）。
  refused,

  /// 状态码或响应体结构无法识别。
  badResponse,

  /// 尚未配置提供方/地址/密钥，请求根本没发出去。
  notConfigured,
}

/// 调用结果基类：sealed 保证调用方 switch 时不会漏掉分支。
sealed class AiOutcome {
  const AiOutcome();
}

/// 成功：text 为可直接展示的正文，model 为服务端回报的模型名（可能为空串）。
class AiReply extends AiOutcome {
  const AiReply(this.text, this.model);

  final String text;
  final String model;
}

/// 失败：message 为中文可读文案，绝不包含 apiKey 与请求头。
class AiFailure extends AiOutcome {
  const AiFailure(this.kind, this.message);

  final AiFailKind kind;
  final String message;

  @override
  String toString() => message;
}

/// 构造一次请求（纯函数，导出给单测）。
/// 返回三元组 (url, headers, bodyJson)：单测不必起 isolate、不必发网络，
/// 就能把三家 provider 的 URL 形状、头位置、body 字段逐项钉死。
/// 注意 anthropic 分支绝不拼 temperature/top_p/thinking：claude-opus-5-5 的采样参数
/// 已从 API 移除，携带会被 400 拒绝。
(String url, Map<String, String> headers, String bodyJson) buildRequest(
  AiConfig config,
  String system,
  List<Map<String, String>> messages,
  int maxTokens, {
  bool stream = false,
}) {
  switch (config.provider) {
    case AiProvider.pollinations:
      // 公益端点（OpenAI 兼容）：无 Authorization 头、body 压到最小形状
      //（该网关对多余采样参数偶发 400，实测 model+messages 最稳）；
      // 端点是 /openai 本体而非 /v1/chat/completions。
      final base = AiConfig.normalizeBaseUrl(config.baseUrl);
      final url = '${base.isEmpty ? kFreeAiBaseUrl : base}/openai';
      final body = jsonEncode(<String, Object?>{
        'model': config.model.isEmpty ? kFreeAiModel : config.model,
        'messages': <Map<String, String>>[
          <String, String>{'role': 'system', 'content': system},
          ..._plainMessages(messages),
        ],
        'max_tokens': maxTokens,
        if (stream) 'stream': true,
      });
      return (
        url,
        <String, String>{
          'Content-Type': 'application/json',
          if (stream) 'Accept': 'text/event-stream',
        },
        body,
      );

    case AiProvider.openai:
      final url =
          '${AiConfig.normalizeBaseUrl(config.baseUrl)}/chat/completions';
      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${config.apiKey}',
        if (stream) 'Accept': 'text/event-stream',
      };
      final body = jsonEncode(<String, Object?>{
        'model': config.model,
        'messages': <Map<String, String>>[
          <String, String>{'role': 'system', 'content': system},
          ..._plainMessages(messages),
        ],
        'temperature': 0.3,
        'max_tokens': maxTokens,
        'stream': stream,
      });
      return (url, headers, body);

    case AiProvider.anthropic:
      final base = AiConfig.normalizeBaseUrl(config.baseUrl);
      // /v1 去重：官方文档两种写法都有（带 /v1 与不带），若用户填了 /v1 还照拼
      // /v1/messages 会得到 /v1/v1/messages，直接 404。
      final url = base.endsWith('/v1') ? '$base/messages' : '$base/v1/messages';
      final headers = <String, String>{
        'content-type': 'application/json',
        'x-api-key': config.apiKey,
        'anthropic-version': '2023-06-01',
        if (stream) 'Accept': 'text/event-stream',
      };
      final body = jsonEncode(<String, Object?>{
        'model': config.model,
        'max_tokens': maxTokens,
        'system': system,
        'messages': _plainMessages(messages),
        if (stream) 'stream': true,
      });
      return (url, headers, body);

    case AiProvider.dify:
      final url = '${AiConfig.normalizeBaseUrl(config.baseUrl)}/chat-messages';
      final headers = <String, String>{
        'Authorization': 'Bearer ${config.apiKey}',
        'content-type': 'application/json',
        if (stream) 'Accept': 'text/event-stream',
      };
      final body = jsonEncode(<String, Object?>{
        'inputs': <String, Object?>{},
        'query': _difyQuery(system, messages),
        'response_mode': stream ? 'streaming' : 'blocking',
        'user': 'compass-app',
        'conversation_id': '',
      });
      return (url, headers, body);

    case AiProvider.none:
      // chat() 已在 enabled 处拦截，这里对任意输入都给出确定值而不是抛异常，
      // 让纯函数保持全定义（单测可直接断言空元组）。
      return ('', const <String, String>{}, '');
  }
}

/// 模型列表请求（GET）。Dify / none 没有等价接口，返回 null。
(String url, Map<String, String> headers)? buildModelsRequest(AiConfig config) {
  switch (config.provider) {
    case AiProvider.pollinations:
      final base = AiConfig.normalizeBaseUrl(config.baseUrl);
      return (
        '${base.isEmpty ? kFreeAiBaseUrl : base}/models',
        const <String, String>{'Content-Type': 'application/json'},
      );
    case AiProvider.openai:
      return (
        '${AiConfig.normalizeBaseUrl(config.baseUrl)}/models',
        <String, String>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${config.apiKey}',
        },
      );
    case AiProvider.anthropic:
      final base = AiConfig.normalizeBaseUrl(config.baseUrl);
      final url = base.endsWith('/v1')
          ? '$base/models?limit=1000'
          : '$base/v1/models?limit=1000';
      return (
        url,
        <String, String>{
          'content-type': 'application/json',
          'x-api-key': config.apiKey,
          'anthropic-version': '2023-06-01',
        },
      );
    case AiProvider.dify:
    case AiProvider.none:
      return null;
  }
}


/// 解析响应（纯函数，导出给单测）。
///
/// 为什么按「响应体形状」而不是按 provider 识别：本函数是无状态纯函数，
/// 三家 2xx 正文字段互斥（choices / content[] / answer），形状识别足够可靠，
/// 也让单测不必构造 config。refusal 属于强特征，优先于形状判断。
AiOutcome parseReply(int status, String body) {
  if (status < 200 || status >= 300) {
    return _failureForStatus(status, body);
  }
  final decoded = _tryDecode(body);
  if (decoded is! Map) {
    // 公益端点（Pollinations）繁忙/限流时会以 HTTP 200 返回 HTML 错误页而不是 JSON
    //（2026-10-18 用户实测"响应不是合法的 JSON 对象"）。判为 server 类可重试错误，
    // chat() 自动重试一次，并给出比"解析失败"可读得多的文案。
    final head = body.trimLeft();
    if (head.startsWith('<') || head.toLowerCase().contains('<!doctype html')) {
      return const AiFailure(AiFailKind.server,
          '公益端点暂时返回了错误页（多为限流或过载），请稍候重试；'
          '持续出现可在设置里换用自有 API Key');
    }
    return const AiFailure(AiFailKind.badResponse, '响应不是合法的 JSON 对象，无法解析');
  }
  final map = decoded.cast<String, Object?>();
  if (map['stop_reason'] == 'refusal') {
    return const AiFailure(AiFailKind.refused, '模型拒绝回答本次请求，请调整提问内容后重试');
  }
  if (map['choices'] is List) {
    return _parseOpenAi(map);
  }
  if (map['content'] is List) {
    return _parseAnthropic(map);
  }
  if (map.containsKey('answer')) {
    return _parseDify(map);
  }
  return const AiFailure(
      AiFailKind.badResponse, '无法识别的响应结构（缺少 choices / content / answer 字段）');
}

/// 默认发送器：把请求压成纯 Map 后交给后台 isolate（红线 3）。
/// 这里刻意不在本函数内写闭包：闭包的 Context 会按「同一函数内被捕获变量」分配，
/// 让持有闭包的顶层函数 [_httpInIsolate] 作用域里只剩 spec，才算真正安全。
Future<AiHttpReply> defaultAiSender(AiHttpRequest req) => _httpInIsolate(
      <String, dynamic>{
        'url': req.url,
        'method': req.method,
        'headers': Map<String, String>.from(req.headers),
        'body': req.body,
        'timeoutMs': req.timeout.inMilliseconds,
      },
    );

/// 顶层函数：作用域内只有 spec 一个局部量，Isolate.run 的闭包 Context 不可能
/// 牵连到 AiClient / AiHttpRequest（历史回归的根因就是捕获了实例）。
Future<AiHttpReply> _httpInIsolate(Map<String, dynamic> spec) =>
    Isolate.run(() => _sendIsolate(spec));

/// 顶层函数：真正的收发，运行在后台 isolate 内。除 spec 外不引用任何外部量。
///
/// 连接策略：只设 connectionTimeout（15s）；绝不设 badCertificateCallback（红线 2），
/// 绝不设 findProxy（走系统代理 —— 否则 Clash/公司代理下的用户会连不出去）。
/// 响应体一律 utf8.decode(allowMalformed: true)：个别网关返回半截中文，
/// 严格解码会抛异常，把一次「内容略乱但可用」的响应变成彻底失败。
Future<AiHttpReply> _sendIsolate(Map<String, dynamic> spec) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final deadline =
      Duration(milliseconds: (spec['timeoutMs'] as int?) ?? 60000);
  try {
    final uri = Uri.parse(spec['url'] as String? ?? '');
    final request = (spec['method'] as String? ?? 'POST') == 'GET'
        ? await client.getUrl(uri)
        : await client.postUrl(uri);
    final headers = spec['headers'];
    if (headers is Map) {
      headers.forEach((k, v) => request.headers.set('$k', '$v'));
    }
    request.add(utf8.encode(spec['body'] as String? ?? ''));
    final resp = await request.close().timeout(deadline);
    final bytes = await resp.expand((chunk) => chunk).toList().timeout(deadline);
    return AiHttpReply(resp.statusCode, utf8.decode(bytes, allowMalformed: true));
  } finally {
    client.close(force: true);
  }
}

/// 默认流式发送器：后台 isolate 逐行回传，主 isolate 负责 SSE 解析与 UI 回调。
/// 仍然遵守红线 3（网络在后台 isolate）；只是把 Isolate.run 换成了
/// Isolate.spawn + SendPort，以便在响应未结束时就能把增量送回来。
Stream<AiStreamEvent> defaultAiStreamSender(AiHttpRequest req) {
  final controller = StreamController<AiStreamEvent>();
  final receive = ReceivePort();
  Isolate? isolate;
  var closed = false;
  var canceled = false;

  void close() {
    if (closed) return;
    closed = true;
    receive.close();
    controller.close();
  }

  receive.listen((message) {
    if (message is! Map) return;
    switch ('${message['type']}') {
      case 'meta':
        final status = message['status'];
        if (status is int && !closed) controller.add(AiStreamMeta(status));
        break;
      case 'line':
        final line = message['line'];
        if (line is String && !closed) controller.add(AiStreamLine(line));
        break;
      case 'error':
        final msg = '${message['error'] ?? '网络请求异常'}';
        if (!closed) controller.add(AiStreamError(msg));
        close();
        break;
      case 'done':
        close();
        break;
    }
  });

  final spec = <String, dynamic>{
    'url': req.url,
    'method': req.method,
    'headers': Map<String, String>.from(req.headers),
    'body': req.body,
    'timeoutMs': req.timeout.inMilliseconds,
  };
  unawaited(Isolate.spawn(_streamIsolateEntry, <Object?>[spec, receive.sendPort])
      .then<void>((iso) {
    isolate = iso;
    if (canceled) iso.kill(priority: Isolate.immediate);
  }).catchError((Object e, StackTrace _) {
    if (!closed) {
      controller.add(AiStreamError('$e'));
      close();
    }
  }));

  controller.onCancel = () {
    canceled = true;
    isolate?.kill(priority: Isolate.immediate);
    close();
  };
  return controller.stream;
}

/// isolate 入口（同步签名，避免个别平台对 Future 返回值的入口推断差异）。
void _streamIsolateEntry(List<Object?> args) {
  unawaited(_streamIsolateMain(args));
}

/// 顶层函数：真正的流式收发，运行在后台 isolate 内。
Future<void> _streamIsolateMain(List<Object?> args) async {
  final spec = (args[0] as Map).cast<String, dynamic>();
  final port = args[1] as SendPort;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final deadline =
      Duration(milliseconds: (spec['timeoutMs'] as int?) ?? 60000);
  try {
    final uri = Uri.parse(spec['url'] as String? ?? '');
    final request = (spec['method'] as String? ?? 'POST') == 'GET'
        ? await client.getUrl(uri)
        : await client.postUrl(uri);
    final headers = spec['headers'];
    if (headers is Map) {
      headers.forEach((k, v) => request.headers.set('$k', '$v'));
    }
    request.add(utf8.encode(spec['body'] as String? ?? ''));
    final resp = await request.close().timeout(deadline);
    port.send(<String, Object?>{'type': 'meta', 'status': resp.statusCode});
    // 手动按换行切分，避免依赖 LineSplitter 的 Converter 泛型细节；
    // 同时兼容 SSE 的 \r\n 与 \n。
    var pending = '';
    await for (final chunk in resp.transform(utf8.decoder).timeout(deadline)) {
      pending += chunk;
      final parts = pending.split('\n');
      pending = parts.removeLast();
      for (final part in parts) {
        port.send(<String, Object?>{
          'type': 'line',
          'line': part.endsWith('\r')
              ? part.substring(0, part.length - 1)
              : part,
        });
      }
    }
    if (pending.isNotEmpty) {
      port.send(<String, Object?>{'type': 'line', 'line': pending});
    }
    port.send(const <String, Object?>{'type': 'done'});
  } on TimeoutException {
    // pollinations 过载时会挂起 SSE 连接：首个字节迟迟不来，Stream.timeout 抛出
    // 「TimeoutException after 0:01:00 …No stream event…」（2026-10-18 用户实测）。
    // 换成可读中文；调用方（_chatStreaming）在未吐字时会自动降级非流式再试。
    port.send(<String, Object?>{
      'type': 'error',
      'error': 'AI 服务响应超时（公益端点排队/过载），请稍候重试',
    });
  } catch (e) {
    port.send(<String, Object?>{'type': 'error', 'error': '$e'});
  } finally {
    client.close(force: true);
  }
}

/// 可切换的 AI 客户端。config 变化时直接新建实例即可（无内部状态、无连接池）。
class AiClient {
  AiClient(this.config, {AiHttpSender? sender, AiStreamSender? streamSender})
      : _sender = sender ?? defaultAiSender,
        _streamSender = streamSender ?? defaultAiStreamSender;

  final AiConfig config;
  final AiHttpSender _sender;
  final AiStreamSender _streamSender;

  /// 重试前的冷却：给对端一次喘息，也避开瞬时抖动。1s 足以覆盖绝大多数瞬断。
  static const Duration _retryDelay = Duration(seconds: 1);

  /// 发起一次对话。messages 元素形状：{'role': 'user'|'assistant', 'content': '...'}。
  ///
  /// [onDelta] 非空时走流式请求：模型每吐出一段文字就回调一次；最终仍返回完整
  /// AiOutcome（调用方据此决定写入历史还是展示错误）。流式失败若已经吐过字，
  /// 不再重试——重试会在 UI 上产生重复/拼接错乱的半截回答。
  Future<AiOutcome> chat({
    required String system,
    required List<Map<String, String>> messages,
    int maxTokens = 8192,
    void Function(String delta)? onDelta,
  }) async {
    if (!config.enabled) {
      return const AiFailure(AiFailKind.notConfigured,
          '尚未配置 AI 服务：请在设置中填写提供方、以 http(s):// 开头的接口地址与 API Key');
    }
    final deltaSink = onDelta;
    final streaming = deltaSink != null;
    final (url, headers, bodyJson) =
        buildRequest(config, system, messages, maxTokens, stream: streaming);
    final req = AiHttpRequest(url: url, headers: headers, body: bodyJson);
    if (deltaSink != null) {
      final (streamed, emitted) = await _chatStreaming(req, deltaSink);
      // 流式挂起降级（2026-10-18 用户实测 pollinations 超时"No stream event"）：
      // 一个字都没吐出来就失败时，同一请求改非流式再走一次——非流式路径对排队更
      // 宽容；已吐过字则绝不重来（会产生两段拼接的回答）。
      if (streamed is AiFailure &&
          !emitted &&
          _isRetriable(streamed.kind)) {
        final (nu, nh, nb) =
            buildRequest(config, system, messages, maxTokens, stream: false);
        final nreq = AiHttpRequest(url: nu, headers: nh, body: nb);
        return _scrubKey(await _attempt(nreq), config.apiKey);
      }
      return streamed;
    }
    var attempt = 1;
    while (true) {
      // 结构性脱敏兜底：失败文案里凡出现完整 apiKey 一律替换（不依赖网关排版猜测；
      // 正则黑名单只作第二层——实测有 app- 前缀 / 引号紧贴 Bearer / 键含 +/ 等绕过形态）
      final outcome = _scrubKey(await _attempt(req), config.apiKey);
      final retriable = outcome is AiFailure && _isRetriable(outcome.kind);
      if (!retriable || attempt >= 2) {
        return outcome;
      }
      attempt++;
      await Future<void>.delayed(_retryDelay);
    }
  }

  /// 拉取服务商模型列表（自定义 Key 场景）。不触网条件与 chat 相同。
  /// 只做一次重试：模型列表是用户手动触发的辅助操作，不值得反复轰炸。
  Future<AiModelsResult> listModels() async {
    if (!config.enabled) {
      return AiModelsResult.failure(
          '尚未配置 AI 服务：请先填写提供方、以 http(s):// 开头的接口地址与 API Key');
    }
    final reqInfo = buildModelsRequest(config);
    if (reqInfo == null) {
      return AiModelsResult.failure('当前提供方没有模型列表接口，请手动填写模型名');
    }
    final (url, headers) = reqInfo;
    final req = AiHttpRequest(
      url: url,
      method: 'GET',
      headers: headers,
      timeout: const Duration(seconds: 30),
    );
    var attempt = 1;
    while (true) {
      try {
        final reply = await _sender(req);
        final result = _scrubModels(
            parseModelsReply(reply.status, reply.body,
                provider: config.provider),
            config.apiKey);
        final retriable = reply.status >= 500;
        if (!retriable || attempt >= 2) return result;
      } on Exception catch (e) {
        final failure = _failureFromError(e);
        if (!_isRetriable(failure.kind) || attempt >= 2) {
          return AiModelsResult.failure(failure.message);
        }
      }
      attempt++;
      await Future<void>.delayed(_retryDelay);
    }
  }

  /// 流式对话：SSE 增量解析 + 完整结果汇总。返回 (结果, 是否已吐过字)——
  /// 调用方据此决定"流式挂起时能否安全降级为非流式重试"（已吐字则不能重来）。
  Future<(AiOutcome, bool)> _chatStreaming(
    AiHttpRequest req,
    void Function(String delta) onDelta,
  ) async {
    var attempt = 1;
    while (true) {
      final text = StringBuffer();
      final raw = StringBuffer();
      var emitted = false;
      var status = 0;
      var model = '';
      var refused = false;
      String? streamError;

      void emit(String delta) {
        if (delta.isEmpty) return;
        text.write(delta);
        emitted = true;
        onDelta(delta);
      }

      try {
        await for (final event in _streamSender(req)) {
          if (event is AiStreamMeta) {
            status = event.status;
            continue;
          }
          if (event is AiStreamError) {
            streamError = redactAiSecrets(event.message);
            break;
          }
          if (event is! AiStreamLine) continue;
          final line = event.line;
          raw.writeln(line);
          final trimmed = line.trimLeft();
          if (!trimmed.startsWith('data:')) continue;
          final data = trimmed.substring(5).trim();
          if (data.isEmpty || data == '[DONE]') continue;
          final decoded = _tryDecode(data);
          if (decoded is! Map) continue;
          final map = decoded.cast<String, Object?>();
          final type = '${map['type'] ?? ''}';

          // Anthropic 事件
          if (type == 'content_block_delta') {
            final delta = map['delta'];
            if (delta is Map &&
                delta['type'] == 'text_delta' &&
                delta['text'] is String) {
              emit(delta['text'] as String);
            }
            continue;
          }
          if (type == 'message_start') {
            final message = map['message'];
            if (message is Map && message['model'] is String) {
              model = message['model'] as String;
            }
            continue;
          }
          if (type == 'message_delta') {
            final delta = map['delta'];
            if (delta is Map && '${delta['stop_reason']}' == 'refusal') {
              refused = true;
            }
            continue;
          }
          if (type == 'error' || type == 'overloaded_error') {
            final err = map['error'];
            streamError = err is Map
                ? redactAiSecrets('${err['message'] ?? err}')
                : redactAiSecrets('$err');
            continue;
          }
          if (type == 'message_stop') continue;

          // Dify 事件
          final difyEvent = map['event'];
          if (difyEvent is String) {
            if (difyEvent == 'message' ||
                difyEvent == 'agent_message' ||
                difyEvent == 'message_replace') {
              final answer = map['answer'];
              if (answer is String) emit(answer);
            } else if (difyEvent == 'error') {
              streamError = redactAiSecrets('${map['message'] ?? '模型返回错误'}');
            }
            continue;
          }

          // OpenAI 兼容事件（含 Pollinations）
          final choices = map['choices'];
          if (choices is List && choices.isNotEmpty) {
            final first = choices.first;
            if (first is Map) {
              final modelName = map['model'];
              if (modelName is String && modelName.isNotEmpty) model = modelName;
              final delta = first['delta'];
              if (delta is Map && delta['content'] is String) {
                emit(delta['content'] as String);
              }
              final message = first['message'];
              if (message is Map && message['content'] is String) {
                emit(message['content'] as String);
              }
            }
            continue;
          }

          // 少数网关直接回 {"answer": "..."} / {"content": "..."}。
          final answer = map['answer'] ?? map['content'];
          if (answer is String) emit(answer);
        }
      } on Exception catch (e) {
        streamError ??= redactAiSecrets(_failureFromError(e).message);
      }

      AiOutcome outcome;
      if (streamError != null) {
        outcome = AiFailure(AiFailKind.network, '网络连接中断：$streamError');
      } else if (status >= 300) {
        outcome = _failureForStatus(status, raw.toString());
      } else if (refused) {
        outcome = const AiFailure(
            AiFailKind.refused, '模型拒绝回答本次请求，请调整提问内容后重试');
      } else if (text.isEmpty) {
        // 服务端忽略了 stream 参数、直接返回整段 JSON 的兜底。
        final fallback = parseReply(status == 0 ? 200 : status, raw.toString());
        if (fallback is AiReply) {
          emitted = true;
          onDelta(fallback.text);
          outcome = fallback;
        } else {
          outcome = fallback;
        }
      } else {
        outcome = AiReply(text.toString().trim(), model);
      }

      final scrubbed = _scrubKey(outcome, config.apiKey);
      final retriable = scrubbed is AiFailure && _isRetriable(scrubbed.kind);
      // 已经吐过字就绝不重试：否则 UI 会收到重叠的两段回答。
      if (!retriable || emitted || attempt >= 2) return (scrubbed, emitted);
      attempt++;
      await Future<void>.delayed(_retryDelay);
    }
  }

  /// 把失败文案中的完整密钥替换为 ***（密钥长度 >= 6 才做，避免误伤短串）。
  static AiOutcome _scrubKey(AiOutcome outcome, String apiKey) {
    if (outcome is AiFailure &&
        apiKey.length >= 6 &&
        outcome.message.contains(apiKey)) {
      return AiFailure(outcome.kind, outcome.message.replaceAll(apiKey, '***'));
    }
    return outcome;
  }

  static AiModelsResult _scrubModels(AiModelsResult result, String apiKey) {
    final error = result.error;
    if (error != null && apiKey.length >= 6 && error.contains(apiKey)) {
      return AiModelsResult.failure(error.replaceAll(apiKey, '***'));
    }
    return result;
  }

  /// 单次尝试：发送 + 解析，并把任何传输层异常翻译成失败分类。
  /// 只捕 Exception 不捕 Error：前者是网络世界的预期意外，后者是本文件的编程错误，
  /// 应当冒泡到测试/日志里暴露出来，而不是伪装成「网络异常」。
  Future<AiOutcome> _attempt(AiHttpRequest req) async {
    try {
      final reply = await _sender(req);
      return parseReply(reply.status, reply.body);
    } on Exception catch (e) {
      return _failureFromError(e);
    }
  }

  /// 只有服务端故障、超时与网络抖动值得重试。
  static bool _isRetriable(AiFailKind kind) => switch (kind) {
        AiFailKind.server || AiFailKind.timeout || AiFailKind.network => true,
        _ => false,
      };
}

/// 传输层异常 -> 失败分类。
/// 文案里只允许出现 OS 级错误描述，绝不允许拼接请求头或密钥（红线 1）。
AiFailure _failureFromError(Object error) {
  if (error is TimeoutException) {
    return const AiFailure(AiFailKind.timeout, 'AI 服务响应超时，请检查网络后重试');
  }
  if (error is HandshakeException) {
    return const AiFailure(
        AiFailKind.network, 'TLS 握手失败，无法建立安全连接，请检查网络环境是否被劫持');
  }
  if (error is SocketException) {
    return AiFailure(AiFailKind.network,
        '网络连接失败：${error.osError?.message ?? error.message}');
  }
  if (error is FormatException) {
    return const AiFailure(AiFailKind.badRequest, '接口地址格式不正确，请在 AI 设置中检查地址');
  }
  return const AiFailure(AiFailKind.network, '网络请求异常，请稍后重试');
}

/// 非 2xx 状态码 -> 失败分类。
AiOutcome _failureForStatus(int status, String body) {
  if (status == 401 || status == 403) {
    return AiFailure(AiFailKind.auth,
        'AI 服务认证失败（HTTP $status），请检查 API Key 是否正确、是否有该模型的权限');
  }
  if (status == 402) {
    // 公益端点（Pollinations）免费额度用尽时返回 402 FREE_LIMIT，不是密钥问题。
    return const AiFailure(AiFailKind.rateLimit,
        '公益端点免费额度暂时用完（HTTP 402），请等待约 30 秒后重试，或在设置中换用自有 API Key');
  }
  if (status == 429) {
    return const AiFailure(AiFailKind.rateLimit, 'AI 服务限流（HTTP 429），请稍候再试');
  }
  if (status == 400 || status == 422) {
    // 参数错误带一段正文能极大加速排查，但正文可能回显请求头，必须先洗再拼。
    final snippet = _redact(_snippet(body));
    final tail = snippet.isEmpty ? '' : '：$snippet';
    return AiFailure(AiFailKind.badRequest, 'AI 请求被拒绝（HTTP $status）$tail');
  }
  if (status >= 500) {
    return AiFailure(AiFailKind.server, 'AI 服务内部错误（HTTP $status）');
  }
  return AiFailure(AiFailKind.badResponse, 'AI 服务返回了意外的状态码（HTTP $status）');
}

/// openai 形状：choices[0].message.content。
AiOutcome _parseOpenAi(Map<String, Object?> map) {
  final choices = map['choices'];
  if (choices is! List || choices.isEmpty) {
    return const AiFailure(AiFailKind.badResponse, '响应缺少 choices 内容');
  }
  final first = choices.first;
  final message = first is Map ? first['message'] : null;
  final content = message is Map ? message['content'] : null;
  final text = content is String ? content.trim() : '';
  if (text.isEmpty) {
    return const AiFailure(AiFailKind.empty, '模型返回了空内容');
  }
  return AiReply(text, _modelOf(map));
}

/// anthropic 形状：content[] 中 type==text 的块按序拼接（思考块等其他类型跳过）。
AiOutcome _parseAnthropic(Map<String, Object?> map) {
  final blocks = map['content'];
  if (blocks is! List) {
    return const AiFailure(AiFailKind.badResponse, '响应缺少 content 内容');
  }
  final buf = StringBuffer();
  for (final block in blocks) {
    if (block is! Map || block['type'] != 'text') {
      continue;
    }
    final t = block['text'];
    if (t is String) {
      buf.write(t);
    }
  }
  final text = buf.toString().trim();
  if (text.isEmpty) {
    return const AiFailure(AiFailKind.empty, '模型返回了空内容');
  }
  return AiReply(text, _modelOf(map));
}

/// dify 形状：answer 字段。
AiOutcome _parseDify(Map<String, Object?> map) {
  final answer = map['answer'];
  if (answer == null) {
    return const AiFailure(AiFailKind.badResponse, '响应缺少 answer 字段');
  }
  if (answer is! String) {
    return const AiFailure(AiFailKind.badResponse, '响应 answer 字段类型异常');
  }
  final text = answer.trim();
  if (text.isEmpty) {
    return const AiFailure(AiFailKind.empty, '模型返回了空内容');
  }
  return AiReply(text, _modelOf(map));
}

/// dify 没有独立 system 通道，只能把系统提示与历史塞进 query，
/// 用分隔线与真正的用户问题隔开（若 system 为空则不加分隔符，避免前导空行）。
/// 必须带全量历史：Dify 的 conversation_id 固定为空，不带历史就等于每轮失忆。
String _difyQuery(String system, List<Map<String, String>> messages) {
  final buf = StringBuffer();
  final sys = system.trim();
  if (sys.isNotEmpty) buf.write(sys);
  final turns = <String>[];
  for (final m in messages) {
    final content = (m['content'] ?? '').trim();
    if (content.isEmpty) continue;
    final role = (m['role'] ?? '') == 'assistant' ? '助手' : '用户';
    turns.add('$role：$content');
  }
  if (turns.isNotEmpty) {
    if (buf.isNotEmpty) buf.write('\n\n---\n\n');
    buf.write(turns.join('\n'));
  }
  return buf.toString().trim();
}

/// 归一化消息角色/正文：非字符串（调用方手抖传了 null）按空串处理，
/// 避免 jsonEncode 把 null 送上去被服务端 400。
List<Map<String, String>> _plainMessages(List<Map<String, String>> messages) =>
    <Map<String, String>>[
      for (final m in messages)
        <String, String>{'role': m['role'] ?? '', 'content': m['content'] ?? ''},
    ];

/// 宽松取模型名：缺失返回空串（dify 响应本来就不带 model）。
String _modelOf(Map<String, Object?> map) {
  final m = map['model'];
  return m is String ? m : '';
}

/// 尝试解码 JSON，失败返回 null（交给调用方分类成 badResponse）。
Object? _tryDecode(String body) {
  try {
    return jsonDecode(body);
  } on FormatException {
    return null;
  }
}

/// 取正文前 200 个码点并压平空白，仅供 400/422 的排查提示。
/// 按码点而不是按 UTF-16 单元截断：否则四字节字符会被劈成半个，文案里出现乱码方块。
String _snippet(String body) {
  final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= 200) {
    return flat;
  }
  return String.fromCharCodes(flat.runes.take(200));
}

/// 洗掉可能泄漏密钥的片段：有的网关/代理会把请求头原样回显进错误正文，
/// 直接展示就等于把 apiKey 打印在界面上（红线 1）。
/// 本函数是第二层防线；第一层是 chat() 里按 apiKey 原文替换的结构性兜底。
String _redact(String text) {
  // 两个 Dart 坑记在这：RegExp 不支持内联 (?i)（只能 caseSensitive:false 构造参数）；
  // String.replaceAll 不支持 $n 组引用（组插值必须用 replaceAllMapped，且用三引号
  // 原始串避免引号转义问题）。
  var out = text.replaceAllMapped(
      RegExp(r'''(["'（(]?\s*bearer\s+)["'“”]?[^\s"',，。；;）)]+''',
          caseSensitive: false),
      (m) => '${m[1]}***');
  out = out.replaceAllMapped(
      RegExp(r'''(api[_-]?key|x-api-key)(["']?\s*[:=]\s*["']?)[^",\s}，。；]+''',
          caseSensitive: false),
      (m) => '${m[1]}${m[2]}***');
  out = out.replaceAll(RegExp(r'sk-[A-Za-z0-9._\-]{3,}'), 'sk-***');
  out = out.replaceAll(RegExp(r'app-[A-Za-z0-9._\-]{6,}', caseSensitive: false), 'app-***');
  return out;
}
