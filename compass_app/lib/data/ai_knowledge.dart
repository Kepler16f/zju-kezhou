/// data/ai_knowledge.dart — 内置知识库接口（答疑用）。
///
/// 当前只提供接口与一个零依赖的内存实现；等收到知识库数据后，
/// 可以在不动 UI / 不动 AiClient 的前提下接上：
///   - 资源包：把 JSON 放进 assets/knowledge/，用 [InMemoryAiKnowledgeBase.fromJson] 加载；
///   - 本地文件 / 远程索引：实现 [AiKnowledgeBase.retrieve] 即可。
///
/// 约定：
///  - retrieve 只接收用户问题，不接收学业/成绩数据（知识库检索不应接触个人信息）；
///  - 返回的片段由 [buildChatSystemPrompt] 放进 system 消息，**不会展示给用户**；
///  - 检索失败必须返回空列表而不是抛异常（答疑是增强能力，不得阻断对话）。
library;

/// 一条知识库片段（发送给模型的已整理文本）。
class AiKnowledgeSnippet {
  const AiKnowledgeSnippet({
    required this.title,
    required this.text,
    this.source,
  });

  final String title;
  final String text;
  final String? source;
}

/// 知识库文档（检索前形态）。
class AiKnowledgeDocument {
  const AiKnowledgeDocument({
    required this.id,
    required this.title,
    required this.text,
    this.keywords = const [],
    this.source,
  });

  final String id;
  final String title;
  final String text;

  /// 人工指定的关键词（可选）；为空时从标题/正文自动切词。
  final List<String> keywords;
  final String? source;

  AiKnowledgeSnippet toSnippet() =>
      AiKnowledgeSnippet(title: title, text: text, source: source);
}

/// 知识库检索接口。实现方可以同步/异步加载，但只能返回已脱敏的公开知识文本。
abstract interface class AiKnowledgeBase {
  Future<List<AiKnowledgeSnippet>> retrieve(String query, {int topK = 4});
}

/// 空知识库（默认）。不产生任何片段，也不触网。
class EmptyAiKnowledgeBase implements AiKnowledgeBase {
  const EmptyAiKnowledgeBase();

  @override
  Future<List<AiKnowledgeSnippet>> retrieve(String query, {int topK = 4}) async =>
      const <AiKnowledgeSnippet>[];
}

/// 内存知识库：关键词/字面匹配打分，零依赖、可单测。
///
/// 这不是向量检索，但足够应付「课程规则/培养方案说明/常见问题」这类
/// 术语密集的校内知识；等用户提供正式语料后可直接替换 retrieve 实现。
class InMemoryAiKnowledgeBase implements AiKnowledgeBase {
  InMemoryAiKnowledgeBase(List<AiKnowledgeDocument> documents)
      : _documents = List<AiKnowledgeDocument>.unmodifiable(documents);

  /// 从 JSON 加载。支持两种形状：
  ///  - `[{"id":..,"title":..,"text":..,"keywords":[..],"source":..}, ...]`
  ///  - `{"documents":[...]}`
  factory InMemoryAiKnowledgeBase.fromJson(Object? json) {
    Object? raw = json;
    if (json is Map) raw = json['documents'] ?? json['items'];
    if (raw is! List) return InMemoryAiKnowledgeBase(const []);
    final docs = <AiKnowledgeDocument>[];
    for (var i = 0; i < raw.length; i++) {
      final item = raw[i];
      if (item is! Map) continue;
      final title = '${item['title'] ?? item['name'] ?? ''}'.trim();
      final text = '${item['text'] ?? item['content'] ?? ''}'.trim();
      if (title.isEmpty && text.isEmpty) continue;
      final keywords = <String>[];
      final kw = item['keywords'];
      if (kw is List) {
        for (final k in kw) {
          final s = '$k'.trim();
          if (s.isNotEmpty) keywords.add(s);
        }
      }
      docs.add(AiKnowledgeDocument(
        id: '${item['id'] ?? 'doc-$i'}',
        title: title.isEmpty ? '知识片段 ${i + 1}' : title,
        text: text,
        keywords: keywords,
        source: item['source'] is String ? '${item['source']}' : null,
      ));
    }
    return InMemoryAiKnowledgeBase(docs);
  }

  final List<AiKnowledgeDocument> _documents;

  int get length => _documents.length;

  @override
  Future<List<AiKnowledgeSnippet>> retrieve(String query, {int topK = 4}) async {
    final terms = _termsOf(query);
    if (terms.isEmpty || _documents.isEmpty) {
      return const <AiKnowledgeSnippet>[];
    }
    final scored = <(double, AiKnowledgeDocument)>[];
    for (final doc in _documents) {
      final haystack = '${doc.title}\n${doc.text}\n${doc.keywords.join(' ')}'
          .toLowerCase();
      var score = 0.0;
      for (final t in terms) {
        if (doc.keywords.any((k) => k.toLowerCase() == t)) {
          score += 3; // 人工关键词命中权重最高
        }
        var index = haystack.indexOf(t);
        var hits = 0;
        while (index >= 0 && hits < 8) {
          hits++;
          index = haystack.indexOf(t, index + t.length);
        }
        score += hits;
      }
      if (score > 0) scored.add((score, doc));
    }
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    return [
      for (final e in scored.take(topK.clamp(1, 8).toInt())) e.$2.toSnippet(),
    ];
  }

  /// 中英文混合切词：英文/数字按词，中文取 2 字滑窗（无需分词依赖）。
  static List<String> _termsOf(String query) {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return const [];
    final out = <String>{};
    for (final m in RegExp(r'[a-z0-9_]{2,}').allMatches(q)) {
      out.add(m.group(0)!);
    }
    final cjk = RegExp(r'[一-鿿]+').allMatches(q).map((m) => m.group(0)!);
    for (final run in cjk) {
      if (run.length == 1) {
        out.add(run);
      } else {
        for (var i = 0; i + 2 <= run.length; i++) {
          out.add(run.substring(i, i + 2));
        }
      }
    }
    return out.toList();
  }
}
