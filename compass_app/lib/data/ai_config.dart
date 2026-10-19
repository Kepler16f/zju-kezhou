/// data/ai_config.dart — AI 客户端配置（提供方 / 接口地址 / API Key / 模型名）。
///
/// 职责：只做「配置值对象」这一件事 —— 存取、序列化、容错反序列化、预设占位。
/// 为什么单独成文件：设置页、持久化层与 ai_client 三方都要引用它；若把枚举塞进
/// ai_client.dart，设置页会为了拿一个枚举而被迫拖入 dart:io / dart:isolate。
///
/// 安全红线（与 ai_client.dart 文件头同源）：
///  - apiKey 只允许作为「请求头」离开本机，绝不进日志、异常文案与 UI 提示；
///    本文件只负责存取，不负责输出，故除 toJson（落盘用）外不暴露任何密钥文本。
///  - fromJson 必须容错：配置文件被手改、截断、跨版本串台时宁可回落默认值也不能抛异常，
///    否则启动早期读配置会把整个 App 拖崩。这是设置页最常踩的坑，故写成硬约定。
///  - 零新依赖：只用 dart:core（不用 json_serializable 之类的生成器）。
library;

/// 支持的 AI 服务提供方。
/// none：未启用（默认值）；pollinations：免费公益端点（无需 Key，见下）；
/// openai：OpenAI 兼容接口（本项目预设指向 DeepSeek）；
/// anthropic：Anthropic Messages API；dify：Dify 应用 API。
enum AiProvider { none, pollinations, openai, anthropic, dify }

/// Pollinations 公益端点（OpenAI 兼容 /chat/completions 形状，匿名可用、无需 Key）。
/// 免费通道有时限流/排队；把它接进 App 的前提是"发送内容已脱敏"这一红线不变。
const String kFreeAiBaseUrl = 'https://text.pollinations.ai';
const String kFreeAiModel = 'openai';

/// AI 配置值对象（不可变，改配置用 [copyWith]）。
///
/// [enabled] 只校验「提供方 + 地址 + 密钥」三件套：缺模型名不该阻止请求（服务端会回落
/// 默认模型），缺密钥则请求必然 401，所以直接判为未配置、连请求都不发（省一次失败+重试）。
class AiConfig {
  const AiConfig({
    this.provider = AiProvider.none,
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
    this.direct = false,
  });

  final AiProvider provider;
  final String baseUrl;
  final String apiKey;
  final String model;

  /// AI 直连开关（任务 #13）：true 时请求绕过系统代理/环境变量代理（findProxy=DIRECT），
  /// false（默认）维持旧行为——走系统代理，保障公司内网等必须借代理出网的场景。
  /// 为什么默认 false：代理下连不出去的代价高于偶发 TLS 握手失败的代价；
  /// 开着 Clash 类代理的用户遇到 HandshakeException（代理拦截 https）时手动打开本开关。
  /// 只影响 AI 端点；教务网（zju_client）恒直连，不受此开关控制。
  final bool direct;

  /// 是否可以发起请求（设置页/入口按钮据此决定 AI 助手可用与否）。
  /// 地址必须带 http(s):// 协议头：漏写 scheme（如只填 api.deepseek.com）会在发送时
  /// 抛 ArgumentError（Error 类，客户端有意只捕 Exception）——在入口直接判为未配置，
  /// 把"永久忙态软锁死"变成清晰的配置提示（评审实测过的故障形态）。
  /// pollinations 是公益端点：无需 Key 即开箱可用（enabled 恒真，地址固定内置）。
  bool get enabled => switch (provider) {
        AiProvider.none => false,
        AiProvider.pollinations => true,
        _ =>
          apiKey.isNotEmpty &&
              (baseUrl.startsWith('http://') || baseUrl.startsWith('https://')),
      };

  AiConfig copyWith({
    AiProvider? provider,
    String? baseUrl,
    String? apiKey,
    String? model,
    bool? direct,
  }) =>
      AiConfig(
        provider: provider ?? this.provider,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        direct: direct ?? this.direct,
      );

  /// 序列化（供沙箱持久化）。密钥随配置一起落盘是设计使然：没有密钥配置就没意义。
  /// direct 恒写入（不落 false 的旧配置文件由 fromJson 缺键回落 false，向后兼容）。
  Map<String, Object?> toJson() => <String, Object?>{
        'provider': provider.name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'direct': direct,
      };

  /// 容错反序列化：null / 非 Map / 坏字段类型 / 未知 provider 字符串
  /// 一律回落 const AiConfig()（provider=none），绝不抛异常。
  /// 有意不做「猜提供方」：猜错会把用户密钥发到错误的域名，宁可让他重选一次。
  static AiConfig fromJson(Object? json) {
    if (json is! Map) {
      return const AiConfig();
    }
    final provider = _providerFromName(json['provider']);
    if (provider == null || provider == AiProvider.none) {
      return const AiConfig();
    }
    return AiConfig(
      provider: provider,
      baseUrl: _str(json['baseUrl']),
      apiKey: _str(json['apiKey']),
      model: _str(json['model']),
      direct: json['direct'] == true,
    );
  }

  /// 归一化接口地址：去首尾空白，再去掉尾部所有斜杠。
  /// 为什么必须去尾斜杠：用户从文档复制地址常带一个或多个 `/`，直接拼接会得到
  /// `https://host/v1//chat/completions`，部分网关对双斜杠返回 404。
  /// 为什么加 `://` 保护：输入 `https://` 时若无脑去尾斜杠会砍成 `https:`，
  /// 反而把地址毁掉，故协议自带的两个斜杠不动。
  static String normalizeBaseUrl(String raw) {
    var s = raw.trim();
    while (s.endsWith('/') && !s.endsWith('://')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// 提供方预设：只作为设置页输入框里的占位提示（baseUrl/model 各填一份示例）。
  /// 有意不含 apiKey —— 预设本身不构成 enabled，避免「看起来配好了其实没钥匙」。
  static AiConfig preset(AiProvider p) {
    switch (p) {
      case AiProvider.pollinations:
        return const AiConfig(
          provider: AiProvider.pollinations,
          baseUrl: kFreeAiBaseUrl,
          model: kFreeAiModel,
        );
      case AiProvider.openai:
        return const AiConfig(
          provider: AiProvider.openai,
          baseUrl: 'https://api.deepseek.com/v1',
          model: 'deepseek-chat',
        );
      case AiProvider.anthropic:
        return const AiConfig(
          provider: AiProvider.anthropic,
          baseUrl: 'https://api.anthropic.com',
          model: 'claude-opus-5-5',
        );
      case AiProvider.dify:
        return const AiConfig(provider: AiProvider.dify, baseUrl: '', model: '');
      case AiProvider.none:
        return const AiConfig();
    }
  }

  /// 字符串字段读取：类型不对就按空串处理（容错约定的一半）。
  /// 顺带 trim：手抄配置最常见的错误是首尾混进空白或换行，直接拿去拼 URL 会拼歪。
  static String _str(Object? v) => v is String ? v.trim() : '';

  /// 提供方名解析：大小写不敏感；未知/缺失/非字符串都返回 null（由调用方回落默认）。
  static AiProvider? _providerFromName(Object? name) {
    if (name is! String) {
      return null;
    }
    final key = name.trim().toLowerCase();
    for (final p in AiProvider.values) {
      if (p.name == key) {
        return p;
      }
    }
    return null;
  }
}
