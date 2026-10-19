// test/ai_client_test.dart — AI 客户端单测：请求构造 / 响应解析 / 错误分类 / 重试策略。
// 全程不发真实网络：纯函数直接断言，涉及 chat() 的一律注入假 sender。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:compass_app/data/ai_client.dart';
import 'package:compass_app/data/ai_config.dart';
import 'package:compass_app/data/ai_models.dart';

/// 组一份可用配置（sender 注入后不会真的出网）。
AiConfig _cfg(
  AiProvider provider, {
  String base = 'https://api.example.com',
  String model = 'm-1',
  String key = 'k-123',
}) =>
    AiConfig(provider: provider, baseUrl: base, apiKey: key, model: model);

/// 大小写不敏感地取头（各家文档的头名大小写并不统一）。
String? _header(Map<String, String> headers, String name) {
  for (final e in headers.entries) {
    if (e.key.toLowerCase() == name.toLowerCase()) {
      return e.value;
    }
  }
  return null;
}

Map<String, dynamic> _json(String body) =>
    jsonDecode(body) as Map<String, dynamic>;

void main() {
  group('buildRequest（三家 provider 的 URL / 头 / body 形状）', () {
    test('openai：拼 /chat/completions，Bearer 放 Authorization 头', () {
      final (url, headers, body) = buildRequest(
        _cfg(AiProvider.openai, base: 'https://api.deepseek.com/v1/'),
        '你是助手',
        [
          {'role': 'user', 'content': '你好'}
        ],
        1024,
      );
      expect(url, 'https://api.deepseek.com/v1/chat/completions');
      expect(_header(headers, 'authorization'), 'Bearer k-123');
      expect(_header(headers, 'content-type'), 'application/json');
      final m = _json(body);
      expect(m['model'], 'm-1');
      expect(m['max_tokens'], 1024);
      expect(m['temperature'], 0.3);
      expect(m['stream'], false);
      final msgs = m['messages'] as List<dynamic>;
      expect(msgs.length, 2);
      expect((msgs[0] as Map<String, dynamic>)['role'], 'system');
      expect((msgs[0] as Map<String, dynamic>)['content'], '你是助手');
      expect((msgs[1] as Map<String, dynamic>)['content'], '你好');
    });

    test('anthropic：base 已带 /v1 时不重复拼接', () {
      final (url, headers, body) = buildRequest(
        _cfg(AiProvider.anthropic, base: 'https://api.anthropic.com/v1'),
        'sys',
        [
          {'role': 'user', 'content': 'q'}
        ],
        512,
      );
      expect(url, 'https://api.anthropic.com/v1/messages');
      expect(_header(headers, 'x-api-key'), 'k-123');
      expect(_header(headers, 'anthropic-version'), '2023-06-01');
      expect(_header(headers, 'content-type'), 'application/json');
      // 绝不用 Bearer，也绝不把密钥塞进 URL/正文
      expect(_header(headers, 'authorization'), isNull);
      final m = _json(body);
      expect(m['system'], 'sys');
      expect(m['max_tokens'], 512);
      expect(m['model'], 'm-1');
      expect(body.contains('k-123'), isFalse);
    });

    test('anthropic：base 不带 /v1 时补 /v1，且绝不携带采样参数', () {
      final (url, _, body) = buildRequest(
        _cfg(AiProvider.anthropic, base: 'https://api.anthropic.com///'),
        'sys',
        [
          {'role': 'user', 'content': 'q'}
        ],
        512,
      );
      expect(url, 'https://api.anthropic.com/v1/messages');
      final m = _json(body);
      // claude-opus-5-5 已移除采样参数，携带 temperature/top_p/thinking 会 400
      expect(m.containsKey('temperature'), isFalse);
      expect(m.containsKey('top_p'), isFalse);
      expect(m.containsKey('thinking'), isFalse);
    });

    test('dify：query 由 system + 分隔线 + 最后一条 user 拼成', () {
      final (url, headers, body) = buildRequest(
        _cfg(AiProvider.dify, base: 'https://api.dify.ai/v1'),
        'sys',
        [
          {'role': 'user', 'content': '第一问'},
          {'role': 'assistant', 'content': '答'},
          {'role': 'user', 'content': '最后问'},
        ],
        4096,
      );
      expect(url, 'https://api.dify.ai/v1/chat-messages');
      expect(_header(headers, 'authorization'), 'Bearer k-123');
      final m = _json(body);
      // Dify 的 conversation_id 恒为空，必须把历史一起塞进 query，否则追问失忆。
      expect(m['query'], 'sys\n\n---\n\n用户：第一问\n助手：答\n用户：最后问');
      expect(m['response_mode'], 'blocking');
      expect(m['user'], 'compass-app');
      expect(m['conversation_id'], '');
      expect(m['inputs'], isEmpty);
    });

    test('none：不抛异常，返回空元组（chat 已在 enabled 处拦截）', () {
      final (url, headers, body) =
          buildRequest(const AiConfig(), 's', const [], 100);
      expect(url, '');
      expect(headers, isEmpty);
      expect(body, '');
    });
  });

  group('parseReply：openai', () {
    test('正常取 choices[0].message.content 与 model', () {
      final out = parseReply(
          200,
          '{"choices":[{"message":{"role":"assistant","content":"  答案  "}}],'
          '"model":"deepseek-chat"}');
      expect(out, isA<AiReply>());
      final r = out as AiReply;
      expect(r.text, '答案');
      expect(r.model, 'deepseek-chat');
    });

    test('缺 choices 字段 → badResponse', () {
      final out = parseReply(200, '{"id":"x","model":"deepseek-chat"}');
      expect(out, isA<AiFailure>());
      expect((out as AiFailure).kind, AiFailKind.badResponse);
    });

    test('choices 为空数组 → badResponse；content 全空白 → empty', () {
      expect((parseReply(200, '{"choices":[]}') as AiFailure).kind,
          AiFailKind.badResponse);
      expect(
          (parseReply(200, '{"choices":[{"message":{"content":"   "}}]}')
                  as AiFailure)
              .kind,
          AiFailKind.empty);
    });

    test('200 但正文是 HTML 错误页 → server（公益端点限流/过载，可重试）', () {
      expect(
          (parseReply(200, '<html>502 Bad Gateway</html>') as AiFailure).kind,
          AiFailKind.server);
    });

    test('200 但正文是非 JSON 非 HTML 的乱码 → badResponse', () {
      expect((parseReply(200, 'garbage-not-json') as AiFailure).kind,
          AiFailKind.badResponse);
    });
  });

  group('parseReply：anthropic', () {
    test('多个 text 块按序拼接', () {
      final out = parseReply(
          200,
          '{"model":"claude-opus-5-5","content":['
          '{"type":"thinking","thinking":"略"},'
          '{"type":"text","text":"第一段。"},'
          '{"type":"text","text":"第二段。"}],'
          '"stop_reason":"end_turn"}');
      expect((out as AiReply).text, '第一段。第二段。');
      expect(out.model, 'claude-opus-5-5');
    });

    test('stop_reason=refusal → refused（不重试）', () {
      final out = parseReply(200, '{"content":[],"stop_reason":"refusal"}');
      expect(out, isA<AiFailure>());
      expect((out as AiFailure).kind, AiFailKind.refused);
    });

    test('空内容 → empty', () {
      expect(
          (parseReply(200, '{"content":[],"stop_reason":"end_turn"}')
                  as AiFailure)
              .kind,
          AiFailKind.empty);
      expect(
          (parseReply(200,
                      '{"content":[{"type":"text","text":""}],"stop_reason":"end_turn"}')
                  as AiFailure)
              .kind,
          AiFailKind.empty);
    });

    test('缺 content 字段 → badResponse', () {
      expect((parseReply(200, '{"stop_reason":"end_turn"}') as AiFailure).kind,
          AiFailKind.badResponse);
    });
  });

  group('parseReply：dify', () {
    test('取 answer', () {
      final out = parseReply(200, '{"answer":"你好，同学","conversation_id":"c1"}');
      expect((out as AiReply).text, '你好，同学');
    });

    test('answer 空白 → empty；answer 缺失 → badResponse', () {
      expect((parseReply(200, '{"answer":"   "}') as AiFailure).kind,
          AiFailKind.empty);
      expect((parseReply(200, '{"conversation_id":"c1"}') as AiFailure).kind,
          AiFailKind.badResponse);
    });
  });

  group('parseReply：宽松 JSON（#11 推荐课程响应）', () {
    test('UTF-8 BOM 可直接解析', () {
      final out = parseReply(
          200, '\uFEFF{"choices":[{"message":{"content":"BOM 答案"}}]}');
      expect((out as AiReply).text, 'BOM 答案');
    });

    test('SSE 多帧按序拼接 delta', () {
      final body = 'data: {"choices":[{"delta":{"content":"你"}}]}\n\n'
          'data: {"choices":[{"delta":{"content":"好"}}]}\n\n'
          'data: [DONE]\n\n';
      final out = parseReply(200, body);
      expect((out as AiReply).text, '你好');
    });

    test('NDJSON 多行 JSON 提取第一个完整对象', () {
      final body = '{"choices":[{"message":{"content":"第一帧回答"}}]}\n'
          '{"id":"trailer","choices":[]}\n';
      final out = parseReply(200, body);
      expect((out as AiReply).text, '第一帧回答');
    });

    test('JSON 前后有代理杂质仍可提取', () {
      final body = 'gateway noise 502\n'
          '{"choices":[{"message":{"content":"杂质中提取"}}]}\n'
          'upstream tail';
      final out = parseReply(200, body);
      expect((out as AiReply).text, '杂质中提取');
    });

    test('双编码 JSON 再解一次', () {
      final inner = jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': '双编码答案'},
          },
        ],
      });
      final out = parseReply(200, jsonEncode(inner));
      expect((out as AiReply).text, '双编码答案');
    });

    test('纯乱码仍 badResponse，带脱敏响应开头', () {
      final out =
          parseReply(200, 'garbage-not-json sk-abcdef1234567890 and more');
      final failure = out as AiFailure;
      expect(failure.kind, AiFailKind.badResponse);
      expect(failure.message, contains('响应开头'));
      expect(failure.message, contains('garbage-not-json'));
      expect(failure.message, contains('sk-***'));
      expect(failure.message, isNot(contains('sk-abcdef1234567890')));
    });
  });

  group('parseReply：非 2xx 错误分类', () {
    test('401/403 → auth，且文案不含密钥', () {
      final unauthorized = parseReply(
              401, '{"error":{"message":"invalid key sk-abcdef1234567890"}}')
          as AiFailure;
      expect(unauthorized.kind, AiFailKind.auth);
      expect(unauthorized.message.contains('sk-abcdef1234567890'), isFalse);
      expect((parseReply(403, '{}') as AiFailure).kind, AiFailKind.auth);
    });

    test('429 → rateLimit；402 公益额度 → rateLimit', () {
      expect((parseReply(429, '{"error":"rate limited"}') as AiFailure).kind,
          AiFailKind.rateLimit);
      final free =
          parseReply(402, '{"status":402,"error":{"code":"FREE_LIMIT"}}')
              as AiFailure;
      expect(free.kind, AiFailKind.rateLimit);
      expect(free.message, contains('公益'));
    });

    test('400/422 → badRequest，可带正文片段但洗掉回显的密钥', () {
      final out = parseReply(400,
              '{"error":"bad request","api_key":"sk-secret1234567890","hint":"model not found"}')
          as AiFailure;
      expect(out.kind, AiFailKind.badRequest);
      expect(out.message.contains('model not found'), isTrue);
      expect(out.message.contains('sk-secret1234567890'), isFalse);
      // 也绝不允许把请求头原样带出
      expect(out.message.toLowerCase().contains('authorization:'), isFalse);
      expect(
          (parseReply(422, '{"detail":"validation error"}') as AiFailure).kind,
          AiFailKind.badRequest);
    });

    test('500/503 → server', () {
      expect((parseReply(500, '{"error":"boom"}') as AiFailure).kind,
          AiFailKind.server);
      expect((parseReply(503, '') as AiFailure).kind, AiFailKind.server);
    });

    test('其它状态码（如 302 登录页）→ badResponse', () {
      expect((parseReply(302, '<html>login</html>') as AiFailure).kind,
          AiFailKind.badResponse);
    });
  });

  group('normalizeBaseUrl', () {
    test('去首尾空白与尾部全部斜杠', () {
      expect(AiConfig.normalizeBaseUrl('  https://api.x.com/v1///  '),
          'https://api.x.com/v1');
      expect(
          AiConfig.normalizeBaseUrl('https://api.x.com/'), 'https://api.x.com');
      expect(
          AiConfig.normalizeBaseUrl('https://api.x.com'), 'https://api.x.com');
      expect(AiConfig.normalizeBaseUrl('   '), '');
    });

    test('协议自带的 // 不被吃掉', () {
      expect(AiConfig.normalizeBaseUrl('https://'), 'https://');
    });

    test('与 anthropic 的 /v1 去重协同', () {
      expect(
        buildRequest(
          _cfg(AiProvider.anthropic, base: 'https://api.anthropic.com/v1//'),
          's',
          const [],
          1,
        ).$1,
        'https://api.anthropic.com/v1/messages',
      );
    });
  });

  group('AiConfig 序列化与容错', () {
    test('fromJson：null / 垃圾 / 未知 provider 一律回落 none', () {
      expect(AiConfig.fromJson(null).provider, AiProvider.none);
      expect(AiConfig.fromJson('not a map').provider, AiProvider.none);
      expect(AiConfig.fromJson(42).provider, AiProvider.none);
      expect(
          AiConfig.fromJson(<String, Object?>{'provider': 'gemini'}).provider,
          AiProvider.none);
      expect(AiConfig.fromJson(<String, Object?>{'provider': 'gemini'}).enabled,
          isFalse);
      // 缺 provider 键同样回落 none（不猜提供方：猜错会把密钥发去错误域名）
      expect(
          AiConfig.fromJson(<String, Object?>{'baseUrl': 'https://x'}).enabled,
          isFalse);
      expect(AiConfig.fromJson(<String, Object?>{'provider': 7}).provider,
          AiProvider.none);
    });

    test('fromJson：字段类型不对按空串处理，不抛异常', () {
      final c = AiConfig.fromJson(<String, Object?>{
        'provider': 'openai',
        'baseUrl': 123,
        'apiKey': null,
        'model': <String>['x'],
      });
      expect(c.provider, AiProvider.openai);
      expect(c.baseUrl, '');
      expect(c.apiKey, '');
      expect(c.model, '');
      expect(c.enabled, isFalse);
    });

    test('toJson/fromJson 往返一致（含大小写不敏感的 provider 名）', () {
      final c = _cfg(AiProvider.anthropic, base: 'https://api.anthropic.com');
      final back = AiConfig.fromJson(jsonDecode(jsonEncode(c.toJson())));
      expect(back.provider, AiProvider.anthropic);
      expect(back.baseUrl, c.baseUrl);
      expect(back.apiKey, c.apiKey);
      expect(back.model, c.model);
      expect(back.direct, c.direct);
      expect(back.enabled, isTrue);
      expect(
          AiConfig.fromJson(<String, Object?>{'provider': 'OpenAI'}).provider,
          AiProvider.openai);
    });

    test('direct 序列化往返：true 落盘后读回仍为 true', () {
      final c = _cfg(AiProvider.openai).copyWith(direct: true);
      final json = jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>;
      expect(json['direct'], isTrue);
      final back = AiConfig.fromJson(json);
      expect(back.direct, isTrue);
    });

    test('direct 容错：缺键 / 非 true 的垃圾值一律回落 false（旧配置兼容）', () {
      final old = AiConfig.fromJson(<String, Object?>{
        'provider': 'openai',
        'baseUrl': 'https://api.example.com',
        'apiKey': 'k',
      });
      expect(old.direct, isFalse);
      for (final junk in <Object?>['true', 1, null, <String>['x'], false]) {
        expect(
            AiConfig.fromJson(<String, Object?>{
              'provider': 'openai',
              'baseUrl': 'https://api.example.com',
              'apiKey': 'k',
              'direct': junk,
            }).direct,
            isFalse);
      }
    });

    test('enabled 三件套：缺提供方或地址或密钥都算未配置', () {
      expect(const AiConfig().enabled, isFalse);
      expect(_cfg(AiProvider.openai).enabled, isTrue);
      expect(_cfg(AiProvider.openai, base: '').enabled, isFalse);
      expect(_cfg(AiProvider.openai, key: '').enabled, isFalse);
      // 预设不含 apiKey，故仅点预设不构成可发送状态
      expect(AiConfig.preset(AiProvider.openai).enabled, isFalse);
    });

    test('copyWith 只改指定字段', () {
      final c = _cfg(AiProvider.openai);
      final d = c.copyWith(model: 'deepseek-reasoner');
      expect(d.model, 'deepseek-reasoner');
      expect(d.provider, c.provider);
      expect(d.baseUrl, c.baseUrl);
      expect(d.apiKey, c.apiKey);
      expect(d.direct, c.direct);
      // direct 也能单独翻（AI 直连开关在设置页就是靠这一改）
      expect(c.copyWith(direct: true).direct, isTrue);
      expect(c.copyWith(direct: true).model, c.model);
    });
  });

  group('chat：重试策略与传输层异常', () {
    test('5xx 重试一次后成功（sender 恰被调用 2 次）', () async {
      var calls = 0;
      final client = AiClient(
        _cfg(AiProvider.openai, base: 'https://api.example.com/v1'),
        sender: (req) async {
          calls++;
          expect(req.url, 'https://api.example.com/v1/chat/completions');
          expect(req.headers['Authorization'], 'Bearer k-123');
          if (calls == 1) {
            return const AiHttpReply(500, '{"error":"overloaded"}');
          }
          return const AiHttpReply(
              200, '{"choices":[{"message":{"content":"重试成功"}}]}');
        },
      );
      final out = await client.chat(
        system: 's',
        messages: [
          {'role': 'user', 'content': 'q'}
        ],
      );
      expect(calls, 2);
      expect((out as AiReply).text, '重试成功');
    });

    test('401 绝不重试（sender 只被调用 1 次）', () async {
      var calls = 0;
      final client = AiClient(
        _cfg(AiProvider.anthropic, base: 'https://api.anthropic.com'),
        sender: (req) async {
          calls++;
          return const AiHttpReply(
              401, '{"error":{"message":"invalid x-api-key"}}');
        },
      );
      final out = await client.chat(
        system: 's',
        messages: [
          {'role': 'user', 'content': 'q'}
        ],
      );
      expect(calls, 1);
      expect((out as AiFailure).kind, AiFailKind.auth);
    });

    test('429 绝不重试（sender 只被调用 1 次）', () async {
      var calls = 0;
      final client = AiClient(
        _cfg(AiProvider.dify),
        sender: (req) async {
          calls++;
          return const AiHttpReply(429, '{"error":"too many requests"}');
        },
      );
      final out = await client.chat(system: 's', messages: const []);
      expect(calls, 1);
      expect((out as AiFailure).kind, AiFailKind.rateLimit);
    });

    test('400 绝不重试（参数错误重试等于再买一次同样的失败）', () async {
      var calls = 0;
      final client = AiClient(
        _cfg(AiProvider.openai),
        sender: (req) async {
          calls++;
          return const AiHttpReply(400, '{"error":"model not found"}');
        },
      );
      final out = await client.chat(system: 's', messages: const []);
      expect(calls, 1);
      expect((out as AiFailure).kind, AiFailKind.badRequest);
    });

    test('TimeoutException → timeout（按设计重试，共 2 次）', () async {
      var calls = 0;
      final client = AiClient(
        _cfg(AiProvider.openai),
        sender: (req) async {
          calls++;
          throw TimeoutException('测试超时');
        },
      );
      final out = await client.chat(
        system: 's',
        messages: [
          {'role': 'user', 'content': 'q'}
        ],
      );
      expect((out as AiFailure).kind, AiFailKind.timeout);
      expect(calls, 2);
    });

    test('SocketException → network（按设计重试，共 2 次）', () async {
      var calls = 0;
      final client = AiClient(
        _cfg(AiProvider.openai),
        sender: (req) async {
          calls++;
          throw SocketException('连接被拒绝');
        },
      );
      final out = await client.chat(
        system: 's',
        messages: [
          {'role': 'user', 'content': 'q'}
        ],
      );
      expect((out as AiFailure).kind, AiFailKind.network);
      expect(calls, 2);
    });

    test('HandshakeException → network，文案带代理/直连自救提示（任务 #13）', () async {
      var calls = 0;
      final client = AiClient(
        _cfg(AiProvider.openai),
        sender: (req) async {
          calls++;
          throw const HandshakeException('测试：TLS 握手失败');
        },
      );
      // network 可重试（与 SocketException 用例同策略，重试共 2 次）；
      // 本用例重点断言文案：代理拦截 https 时给用户的自救提示必须出现。
      final out = await client.chat(
        system: 's',
        messages: [
          {'role': 'user', 'content': 'q'}
        ],
      );
      final failure = out as AiFailure;
      expect(failure.kind, AiFailKind.network);
      expect(calls, 2);
      expect(failure.message, contains('直连'));
      expect(failure.message, contains('代理'));
    });

    test('config.direct 透传到 sender 收到的请求上（直连开关的传递链）', () async {
      AiHttpRequest? seen;
      Future<AiHttpReply> fakeSender(AiHttpRequest req) async {
        seen = req;
        return const AiHttpReply(200, '{"choices":[{"message":{"content":"ok"}}]}');
      }

      await AiClient(_cfg(AiProvider.openai, key: 'k'), sender: fakeSender)
          .chat(
        system: 's',
        messages: [
          {'role': 'user', 'content': 'q'}
        ],
      );
      expect(seen!.direct, isFalse);

      await AiClient(_cfg(AiProvider.openai).copyWith(direct: true),
              sender: fakeSender)
          .chat(
        system: 's',
        messages: [
          {'role': 'user', 'content': 'q'}
        ],
      );
      expect(seen!.direct, isTrue);
    });

    test('未配置时不发请求，直接 notConfigured', () async {
      var calls = 0;
      final client = AiClient(
        const AiConfig(),
        sender: (req) async {
          calls++;
          return const AiHttpReply(200, '{}');
        },
      );
      final out = await client.chat(
        system: 's',
        messages: [
          {'role': 'user', 'content': 'q'}
        ],
      );
      expect(calls, 0);
      expect((out as AiFailure).kind, AiFailKind.notConfigured);
    });

    test('成功响应不会被重试（sender 只被调用 1 次）', () async {
      var calls = 0;
      final client = AiClient(
        _cfg(AiProvider.dify),
        sender: (req) async {
          calls++;
          return const AiHttpReply(200, '{"answer":"好的"}');
        },
      );
      final out = await client.chat(system: 's', messages: const []);
      expect(calls, 1);
      expect((out as AiReply).text, '好的');
    });
  });

  group('stream：请求形状与 SSE 增量解析', () {
    test('openai/anthropic 流式请求带 stream:true', () {
      final (_, _, openaiBody) = buildRequest(
        _cfg(AiProvider.openai),
        's',
        const [],
        100,
        stream: true,
      );
      expect(_json(openaiBody)['stream'], isTrue);

      final (_, _, anthropicBody) = buildRequest(
        _cfg(AiProvider.anthropic),
        's',
        const [],
        100,
        stream: true,
      );
      expect(_json(anthropicBody)['stream'], isTrue);
    });

    test('OpenAI SSE：逐段回调，最终文本为完整拼接', () async {
      final deltas = <String>[];
      final client = AiClient(
        _cfg(AiProvider.openai),
        streamSender: (req) async* {
          yield const AiStreamMeta(200);
          yield const AiStreamLine(
              'data: {"model":"m-1","choices":[{"delta":{"content":"你"}}]}');
          yield const AiStreamLine(
              'data: {"choices":[{"delta":{"content":"好"}}]}');
          yield const AiStreamLine('data: [DONE]');
        },
      );
      final out = await client.chat(
        system: 's',
        messages: const [
          {'role': 'user', 'content': 'q'}
        ],
        onDelta: deltas.add,
      );
      expect((out as AiReply).text, '你好');
      expect(out.model, 'm-1');
      expect(deltas.join(), '你好');
    });

    test('Anthropic SSE：content_block_delta 拼接', () async {
      final deltas = <String>[];
      final client = AiClient(
        _cfg(AiProvider.anthropic),
        streamSender: (req) async* {
          yield const AiStreamMeta(200);
          yield const AiStreamLine(
              'data: {"type":"message_start","message":{"model":"claude-x"}}');
          yield const AiStreamLine(
              'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"第一段"}}');
          yield const AiStreamLine(
              'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"第二段"}}');
        },
      );
      final out = await client.chat(
        system: 's',
        messages: const [
          {'role': 'user', 'content': 'q'}
        ],
        onDelta: deltas.add,
      );
      expect((out as AiReply).text, '第一段第二段');
      expect(out.model, 'claude-x');
      expect(deltas.join(), '第一段第二段');
    });

    test('NDJSON 裸 JSON 行也按 delta/content 消费', () async {
      final deltas = <String>[];
      final client = AiClient(
        _cfg(AiProvider.openai),
        streamSender: (req) async* {
          yield const AiStreamMeta(200);
          yield const AiStreamLine('{"choices":[{"delta":{"content":"ND"}}]}');
          yield const AiStreamLine(
              '{"choices":[{"delta":{"content":"JSON"}}]}');
        },
      );
      final out = await client.chat(
        system: 's',
        messages: const [
          {'role': 'user', 'content': 'q'}
        ],
        onDelta: deltas.add,
      );
      expect((out as AiReply).text, 'NDJSON');
      expect(deltas.join(), 'NDJSON');
    });

    test('服务端忽略 stream、返回整段 JSON：兜底解析并回调一次', () async {
      final deltas = <String>[];
      final client = AiClient(
        _cfg(AiProvider.openai),
        streamSender: (req) async* {
          yield const AiStreamMeta(200);
          yield const AiStreamLine(
              '{"choices":[{"message":{"content":"完整回答"}}]}');
        },
      );
      final out = await client.chat(
        system: 's',
        messages: const [
          {'role': 'user', 'content': 'q'}
        ],
        onDelta: deltas.add,
      );
      expect((out as AiReply).text, '完整回答');
      expect(deltas, ['完整回答']);
    });

    test('流式超时未吐字：降级非流式重试成功（sender 被调用）', () async {
      final deltas = <String>[];
      var nonStreamCalls = 0;
      final client = AiClient(
        _cfg(AiProvider.pollinations),
        // 非流式兜底：返回整段 JSON
        sender: (req) async {
          nonStreamCalls++;
          expect(req.body.contains('"stream":true'), isFalse,
              reason: '降级请求应为非流式');
          return const AiHttpReply(
              200, '{"choices":[{"message":{"content":"降级成功"}}]}');
        },
        // 流式：一上来就 error（未 emit 任何 delta），触发降级
        streamSender: (req) async* {
          yield const AiStreamError('AI 服务响应超时（公益端点排队/过载），请稍候重试');
        },
      );
      final out = await client.chat(
        system: 's',
        messages: const [
          {'role': 'user', 'content': 'q'}
        ],
        onDelta: deltas.add,
      );
      expect((out as AiReply).text, '降级成功');
      expect(nonStreamCalls, 1);
      // 降级走非流式：内容不回调 delta，只作为最终文本返回
      expect(deltas, isEmpty);
    });
  });

  group('listModels', () {
    test('OpenAI 兼容：GET /models，解析上下文大小', () async {
      final client = AiClient(
        _cfg(AiProvider.openai, base: 'https://api.example.com/v1'),
        sender: (req) async {
          expect(req.method, 'GET');
          expect(req.url, 'https://api.example.com/v1/models');
          expect(req.headers['Authorization'], 'Bearer k-123');
          return const AiHttpReply(
              200,
              '{"data":[{"id":"m-1","context_length":128000},'
              '{"id":"m-2","context_window":65536}]}');
        },
      );
      final result = await client.listModels();
      expect(result.ok, isTrue);
      expect(result.models, hasLength(2));
      final m1 = result.models.firstWhere((m) => m.id == 'm-1');
      expect(m1.contextTokens, 128000);
      expect(m1.contextLabel, '128K');
    });

    test('Dify 没有模型列表接口：不发请求', () async {
      var calls = 0;
      final client = AiClient(
        _cfg(AiProvider.dify),
        sender: (req) async {
          calls++;
          return const AiHttpReply(200, '{}');
        },
      );
      final result = await client.listModels();
      expect(result.ok, isFalse);
      expect(result.error, contains('没有模型列表接口'));
      expect(calls, 0);
    });
  });

  group('parseModelsReply', () {
    test('Anthropic 形状 + 内置上下文参考', () {
      final result = parseModelsReply(
        200,
        '{"data":[{"id":"claude-3-5-sonnet-20241022",'
        '"display_name":"Claude 3.5 Sonnet"}]}',
        provider: AiProvider.anthropic,
      );
      expect(result.ok, isTrue);
      final m = result.models.single;
      expect(m.displayName, 'Claude 3.5 Sonnet');
      expect(m.contextTokens, 200000);
      expect(m.sourceNote, contains('内置参考'));
    });

    test('Pollinations 顶层数组 + 字符串数组', () {
      final result = parseModelsReply(
        200,
        '[{"name":"openai","description":"x"},"mistral"]',
        provider: AiProvider.pollinations,
      );
      expect(result.ok, isTrue);
      expect(
          result.models.map((m) => m.id), containsAll(['openai', 'mistral']));
      expect(result.models.first.contextTokens, isNull);
      expect(result.models.first.contextLabel, '未知');
    });
  });
}
