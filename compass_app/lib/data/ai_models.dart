/// data/ai_models.dart — 模型列表值对象与解析（纯 Dart，无 IO）。
///
/// 为什么单独成文件：设置页只需要展示「模型 id / 上下文大小」，
/// 不应为了拿一个值对象而被迫引入 ai_client.dart 的 dart:io / dart:isolate。
///
/// 解析原则：
///  - 兼容 OpenAI 兼容接口（{data:[{id,...}]}）、Anthropic（{data:[{id,display_name}]}）
///    与 Pollinations（顶层数组 [{name,...}]）三种常见形状；
///  - 上下文大小优先取接口字段，其次查内置参考表（明确标注「内置参考」），
///    两者都没有就显示「未知」——绝不给用户编造数字；
///  - 模型列表正文可能回显密钥，错误文案统一过 redactAiSecrets。
library;

import 'dart:convert';

import 'ai_config.dart';

/// 模型条目。contextTokens 为上下文窗口（输入+输出）的 token 数。
class AiModelInfo {
  const AiModelInfo({
    required this.id,
    this.displayName,
    this.contextTokens,
    this.maxOutputTokens,
    this.sourceNote,
  });

  final String id;
  final String? displayName;
  final int? contextTokens;
  final int? maxOutputTokens;

  /// 上下文数字的来源说明：接口提供 / 内置参考值。null 表示未知。
  final String? sourceNote;

  String get title =>
      (displayName == null || displayName!.trim().isEmpty) ? id : displayName!;

  String get contextLabel => formatTokenCount(contextTokens);

  String get outputLabel => formatTokenCount(maxOutputTokens);
}

/// token 数的人类可读格式：64000 → 64K，1047576 → 1M，未知 → 未知。
String formatTokenCount(int? n) {
  if (n == null || n <= 0) return '未知';
  if (n >= 1000000) {
    final m = n / 1000000;
    return '${_compactDouble(m)}M';
  }
  if (n >= 1000) {
    final k = n / 1000;
    return '${_compactDouble(k)}K';
  }
  return '$n';
}

String _compactDouble(double v) =>
    v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

/// 模型列表拉取结果。error 非空即失败；models 为空但 error 为空表示服务商返回空表。
class AiModelsResult {
  const AiModelsResult._({this.models = const [], this.error, this.note});

  factory AiModelsResult.success(List<AiModelInfo> models, {String? note}) =>
      AiModelsResult._(models: List<AiModelInfo>.unmodifiable(models), note: note);

  factory AiModelsResult.failure(String error) =>
      AiModelsResult._(error: error);

  final List<AiModelInfo> models;
  final String? error;

  /// 服务商附加说明（如分页提示），可选。
  final String? note;

  bool get ok => error == null;
}

/// 解析模型列表响应（纯函数，导出给单测）。
AiModelsResult parseModelsReply(
  int status,
  String body, {
  required AiProvider provider,
}) {
  if (status < 200 || status >= 300) {
    return AiModelsResult.failure(_statusMessage(status, body));
  }
  final decoded = _tryDecode(body);
  final items = _itemsOf(decoded);
  if (items == null) {
    return AiModelsResult.failure('无法识别的模型列表结构（既不是数组，也没有 data/models 字段）');
  }
  final out = <AiModelInfo>[];
  final seen = <String>{};
  for (final item in items) {
    if (item is String) {
      final id = item.trim();
      if (id.isNotEmpty && seen.add(id)) {
        out.add(AiModelInfo(id: id));
      }
      continue;
    }
    if (item is! Map) continue;
    final map = item.cast<String, Object?>();
    final id = _pickString(map, const ['id', 'model', 'name', 'model_name', 'modelName']);
    if (id == null || id.isEmpty || !seen.add(id)) continue;
    final display = _pickString(map, const ['display_name', 'displayName', 'title']);
    final providedContext = _pickInt(map, const [
          'context_length',
          'context_window',
          'context_window_tokens',
          'max_context_length',
          'max_model_len',
          'max_input_tokens',
          'input_token_limit',
          'n_ctx',
        ]) ??
        _nestedInt(map, const ['top_provider', 'context_length']) ??
        _nestedInt(map, const ['architecture', 'context_length']);
    final known = providedContext == null ? _knownContext(id) : null;
    final output = _pickInt(map, const [
      'max_output_tokens',
      'max_completion_tokens',
      'output_token_limit',
      'max_tokens',
    ]);
    out.add(AiModelInfo(
      id: id,
      displayName: display,
      contextTokens: providedContext ?? known?.tokens,
      maxOutputTokens: output,
      sourceNote: providedContext != null
          ? '接口提供'
          : (known == null ? null : '内置参考值，以服务商文档为准'),
    ));
  }
  if (out.isEmpty) {
    return AiModelsResult.failure('服务商返回了空模型列表');
  }
  final note = decoded is Map && decoded['note'] is String
      ? (decoded['note'] as String).trim()
      : null;
  return AiModelsResult.success(out,
      note: note != null && note.isNotEmpty ? note : null);
}

/// 洗掉正文里可能回显的密钥（与 ai_client 的 _redact 同源；本文件不引 dart:io，
/// 因此单独提供一份给模型列表解析使用）。
String redactAiSecrets(String text) {
  var out = text.replaceAllMapped(
      RegExp(r'''(["'（(]?\s*bearer\s+)["'“”]?[^\s"',，。；;）)]+''',
          caseSensitive: false),
      (m) => '${m[1]}***');
  out = out.replaceAllMapped(
      RegExp(r'''(api[_-]?key|x-api-key)(["']?\s*[:=]\s*["']?)[^",\s}，。；]+''',
          caseSensitive: false),
      (m) => '${m[1]}${m[2]}***');
  out = out.replaceAll(RegExp(r'sk-[A-Za-z0-9._\-]{3,}'), 'sk-***');
  out = out.replaceAll(
      RegExp(r'app-[A-Za-z0-9._\-]{6,}', caseSensitive: false), 'app-***');
  return out;
}

List<Object?>? _itemsOf(Object? decoded) {
  if (decoded is List) return decoded;
  if (decoded is Map) {
    for (final key in const ['data', 'models', 'result', 'items']) {
      final v = decoded[key];
      if (v is List) return v;
    }
  }
  return null;
}

String? _pickString(Map<String, Object?> map, List<String> keys) {
  for (final k in keys) {
    final v = map[k];
    if (v is String && v.trim().isNotEmpty) return v.trim();
  }
  return null;
}

int? _pickInt(Map<String, Object?> map, List<String> keys) {
  for (final k in keys) {
    final n = _parseTokenCount(map[k]);
    if (n != null) return n;
  }
  return null;
}

int? _nestedInt(Map<String, Object?> map, List<String> keys) {
  if (keys.length != 2) return null;
  final nested = map[keys[0]];
  if (nested is Map) {
    return _parseTokenCount(nested[keys[1]]);
  }
  return null;
}

int? _parseTokenCount(Object? v) {
  if (v is int) return v > 0 ? v : null;
  if (v is num) return v > 0 ? v.toInt() : null;
  if (v is String) {
    final m = RegExp(r'^([0-9]+(?:\.[0-9]+)?)\s*([kKmM])?$').firstMatch(v.trim());
    if (m == null) return null;
    final n = double.parse(m.group(1)!);
    final unit = m.group(2)?.toLowerCase();
    final out = unit == 'k'
        ? n * 1000
        : unit == 'm'
            ? n * 1000000
            : n;
    return out > 0 ? out.round() : null;
  }
  return null;
}

({int tokens, String note})? _knownContext(String id) {
  final key = id.trim().toLowerCase();
  final exact = _knownContextWindows[key];
  if (exact != null) {
    return (tokens: exact, note: '内置参考值，以服务商文档为准');
  }
  // 前缀匹配按 key 长度降序，避免 gpt-4o 抢在 gpt-4o-mini 之前命中。
  final keys = _knownContextWindows.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final k in keys) {
    if (key.startsWith('$k-') || key.startsWith('$k:') || key.startsWith('$k.')) {
      return (tokens: _knownContextWindows[k]!, note: '内置参考值，以服务商文档为准');
    }
  }
  return null;
}

/// 常见模型的上下文窗口参考值（仅当接口不提供该字段时使用）。
/// 只收录公开且稳定的型号；不确定的一律不写，宁可显示「未知」也不编造。
const Map<String, int> _knownContextWindows = <String, int>{
  'deepseek-chat': 65536,
  'deepseek-reasoner': 65536,
  'gpt-4o': 128000,
  'gpt-4o-mini': 128000,
  'gpt-4.1': 1047576,
  'gpt-4.1-mini': 1047576,
  'gpt-4.1-nano': 1047576,
  'o1': 200000,
  'o1-mini': 128000,
  'o3': 200000,
  'o3-mini': 200000,
  'claude-3-opus': 200000,
  'claude-3-sonnet': 200000,
  'claude-3-haiku': 200000,
  'claude-3-5-sonnet': 200000,
  'claude-3-5-haiku': 200000,
  'claude-sonnet-4': 200000,
  'claude-opus-4': 200000,
};

Object? _tryDecode(String body) {
  try {
    return jsonDecode(body);
  } on FormatException {
    return null;
  }
}

String _statusMessage(int status, String body) {
  final snippet = redactAiSecrets(_snippet(body));
  final tail = snippet.isEmpty ? '' : '：$snippet';
  if (status == 401 || status == 403) {
    return '认证失败（HTTP $status），请检查 API Key 是否正确、是否有读取模型列表的权限';
  }
  if (status == 429) return '限流（HTTP $status），请稍候再试';
  if (status == 404) return '该服务商没有模型列表接口（HTTP 404），请手动填写模型名';
  if (status >= 500) return '服务商内部错误（HTTP $status），请稍后重试';
  return '拉取模型列表失败（HTTP $status）$tail';
}

String _snippet(String body) {
  final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= 200) return flat;
  return String.fromCharCodes(flat.runes.take(200));
}
