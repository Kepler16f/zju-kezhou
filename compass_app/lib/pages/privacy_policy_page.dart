/// pages/privacy_policy_page.dart — 隐私政策正文页（渲染 assets/privacy_policy.md）。
///
/// 设计约束：
///  - 正文随包发布（assets/privacy_policy.md，与仓库 docs/隐私政策.md 逐字节一致），
///    离线可读、不联网、不依赖任何远程接口。
///  - 加载失败给出明确错误与「重试」按钮，绝不白屏、绝不抛异常。
///  - Markdown 渲染器**自研**（见 [PolicyMarkdownBody]）：不借用 AI 对话专用的
///    lib/widgets/ai_message_body.dart（那是聊天气泡样式，标题色/行高与本页政策阅读场景不符）。
///    支持一级/二级标题（加粗、标题色 #1F4E79）、段落（行高 1.6）、无序/有序列表、
///    围栏代码块（等宽底色）、加粗、行内代码；表格降级为"单元格以 ｜ 连接"的段落；
///    任何未知语法一律降级为纯文本段落——绝不抛异常、绝不丢内容。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:markdown/markdown.dart' as md;

/// 政策正文加载器（可注入：便于测试，也便于将来切换正文来源）。
typedef PolicyMarkdownLoader = Future<String> Function();

/// 隐私政策正文页。
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key, this.loader});

  /// 正文加载器；省略时从随包资源 [assetPath] 读取。
  final PolicyMarkdownLoader? loader;

  /// 随包发布的政策正文资源路径（需在 pubspec.yaml 的 assets 中登记）。
  static const String assetPath = 'assets/privacy_policy.md';

  /// 政策生效日期（与正文一致）。
  static const String effectiveDate = '2026-10-21';

  /// 默认加载器：rootBundle 异步读取随包正文。
  static Future<String> loadFromAssetBundle() =>
      rootBundle.loadString(assetPath);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('隐私政策')),
      body: Column(
        children: [
          Expanded(
            child: _PolicyBodyView(loader: loader ?? loadFromAssetBundle),
          ),
          const _PolicyFooter(),
        ],
      ),
    );
  }
}

/// 正文区域：负责异步加载、加载态、错误态与重试。
class _PolicyBodyView extends StatefulWidget {
  const _PolicyBodyView({required this.loader});

  final PolicyMarkdownLoader loader;

  @override
  State<_PolicyBodyView> createState() => _PolicyBodyViewState();
}

class _PolicyBodyViewState extends State<_PolicyBodyView> {
  late Future<String> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  /// 把同步抛出的异常也转成 failed future，统一交给 FutureBuilder 显示错误与重试。
  Future<String> _load() {
    try {
      return widget.loader();
    } catch (e, st) {
      return Future<String>.error(e, st);
    }
  }

  void _retry() {
    setState(() {
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _PolicyLoadError(error: snap.error, onRetry: _retry);
        }
        final text = snap.data ?? '';
        if (text.trim().isEmpty) {
          return _PolicyLoadError(error: '政策正文为空', onRetry: _retry);
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: PolicyMarkdownBody(text),
        );
      },
    );
  }
}

/// 加载失败：明确说明 + 重试按钮。
class _PolicyLoadError extends StatelessWidget {
  const _PolicyLoadError({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: scheme.error),
            const SizedBox(height: 12),
            const Text(
              '隐私政策正文加载失败',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              '错误信息：${error ?? '未知错误'}\n'
              '请检查随包资源 assets/privacy_policy.md 是否存在，或重试。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 页脚固定说明（政策与实现一致性 + 生效日期）。
class _PolicyFooter extends StatelessWidget {
  const _PolicyFooter();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Text(
        '本政策与开源仓库中的实现一致，可对照代码复核 · 生效日期 '
        '${PrivacyPolicyPage.effectiveDate}',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// 政策正文的 Markdown → Widget 渲染器（自研，容错优先）。
///
/// 支持的块级元素：
///  - 一级/二级标题（加粗、标题色 #1F4E79；三级及以下为同色系浅一档）
///  - 段落（行高 1.6）
///  - 无序列表（项目符号）/ 有序列表（序号），均带缩进
///  - 围栏代码块（等宽字体 + 浅底色 + 圆角边框）
///  - 引用块（左侧竖线）与分隔线
///  - 表格 → **降级**为"单元格以 ｜ 连接"的段落（不崩、不丢单元格文字）
///
/// 支持的行内元素：**加粗**、*斜体*、~~删除线~~、`行内代码`（等宽 + 浅底）、链接、硬换行。
///
/// 容错约定：任何未知标签都降级为纯文本段落；解析整体失败时按空行切段纯文本展示——
/// 绝不抛异常、绝不丢内容。
class PolicyMarkdownBody extends StatelessWidget {
  const PolicyMarkdownBody(this.markdown, {super.key});

  final String markdown;

  /// 政策主题色（标题色）：深蓝 #1F4E79。
  static const Color policyColor = Color(0xFF1F4E79);

  /// 三级及以下标题的浅一档同色系。
  static const Color subHeadingColor = Color(0xFF2C5F8F);

  /// 视为块级的标签（未知父节点内遇到它们时递归按块渲染）。
  static const Set<String> _blockTags = <String>{
    'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'ul', 'ol', 'li', 'pre', 'blockquote', 'hr', 'table',
  };

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style;
    final codeBg = Theme.of(context).colorScheme.surfaceContainerHighest;
    final blocks = <Widget>[];
    try {
      final doc = md.Document(
        extensionSet: md.ExtensionSet.gitHubFlavored,
        encodeHtml: false,
      );
      for (final node in doc.parse(markdown)) {
        try {
          blocks.addAll(_block(context, node, base, codeBg));
        } catch (_) {
          // 单块渲染失败：降级为纯文本段落（内容不丢）。
          final t = node.textContent.trim();
          if (t.isNotEmpty) {
            blocks.add(Text(t, style: base.copyWith(height: 1.6)));
          }
        }
      }
    } catch (_) {
      // 解析整体失败：按空行切段，纯文本展示（内容不丢）。
      blocks.addAll(_plainFallback(markdown, base));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: blocks,
    );
  }

  /// 纯文本兜底：空行分段。
  List<Widget> _plainFallback(String text, TextStyle base) {
    final out = <Widget>[];
    for (final part in text.split(RegExp(r'\n\s*\n'))) {
      final t = part.trim();
      if (t.isEmpty) continue;
      out.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(t, style: base.copyWith(height: 1.6)),
      ));
    }
    return out;
  }

  List<Widget> _block(
      BuildContext context, md.Node node, TextStyle base, Color codeBg) {
    if (node is md.Text) {
      final t = node.text.trim();
      if (t.isEmpty) return const <Widget>[];
      return <Widget>[Text(t, style: base.copyWith(height: 1.6))];
    }
    if (node is! md.Element) {
      final t = node.textContent.trim();
      if (t.isEmpty) return const <Widget>[];
      return <Widget>[Text(t, style: base.copyWith(height: 1.6))];
    }
    final el = node;
    switch (el.tag) {
      case 'p':
        return <Widget>[_paragraph(el, base, codeBg)];
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        return <Widget>[_heading(el, base, codeBg)];
      case 'ul':
      case 'ol':
        return <Widget>[_list(context, el, base, codeBg)];
      case 'pre':
        return <Widget>[_codeBlock(context, el, base, codeBg)];
      case 'blockquote':
        return <Widget>[_blockquote(context, el, base, codeBg)];
      case 'hr':
        return <Widget>[
          Divider(
              height: 18, color: Theme.of(context).colorScheme.outlineVariant),
        ];
      case 'table':
        return _table(el, base, codeBg);
      default:
        return _unknown(context, el, base, codeBg);
    }
  }

  Widget _paragraph(md.Element el, TextStyle base, Color codeBg) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text.rich(_inlineChildren(
            el.children ?? const <md.Node>[], base.copyWith(height: 1.6), codeBg)),
      );

  Widget _heading(md.Element el, TextStyle base, Color codeBg) {
    final size = switch (el.tag) {
      'h1' => 20.0,
      'h2' => 17.0,
      'h3' => 15.5,
      _ => 14.5,
    };
    final bool strong = el.tag == 'h1' || el.tag == 'h2';
    return Padding(
      padding: EdgeInsets.only(top: strong ? 12 : 8, bottom: 4),
      child: Text.rich(_inlineChildren(
        el.children ?? const <md.Node>[],
        base.copyWith(
          fontSize: size,
          fontWeight: FontWeight.bold,
          color: strong ? policyColor : subHeadingColor,
          height: 1.35,
        ),
        codeBg,
      )),
    );
  }

  Widget _list(
      BuildContext context, md.Element el, TextStyle base, Color codeBg) {
    final bool ordered = el.tag == 'ol';
    final items = (el.children ?? const <md.Node>[])
        .whereType<md.Element>()
        .where((e) => e.tag == 'li')
        .toList();
    return Padding(
      padding: const EdgeInsets.only(left: 6, top: 2, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 24,
                    child: Text(
                      ordered ? '${i + 1}.' : '•',
                      style: base.copyWith(
                          fontWeight: FontWeight.w700,
                          color: policyColor,
                          height: 1.6),
                    ),
                  ),
                  Expanded(child: _liContent(context, items[i], base, codeBg)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 列表项：紧凑列表（直接是行内节点）或松散列表（内含段落等块级节点）。
  Widget _liContent(
      BuildContext context, md.Element li, TextStyle base, Color codeBg) {
    final children = li.children ?? const <md.Node>[];
    final bool hasBlock = children
        .any((c) => c is md.Element && _blockTags.contains(c.tag));
    if (!hasBlock) {
      return Text.rich(
          _inlineChildren(children, base.copyWith(height: 1.6), codeBg));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final c in children) ..._block(context, c, base, codeBg),
      ],
    );
  }

  Widget _codeBlock(
      BuildContext context, md.Element pre, TextStyle base, Color codeBg) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: codeBg.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant, width: 0.6),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          pre.textContent.trimRight(),
          style: base.copyWith(
              fontFamily: 'monospace', fontSize: 12, height: 1.45),
        ),
      ),
    );
  }

  Widget _blockquote(
      BuildContext context, md.Element el, TextStyle base, Color codeBg) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(
        border: Border(
            left: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final c in el.children ?? const <md.Node>[])
            ..._block(context, c, base, codeBg),
        ],
      ),
    );
  }

  /// 表格降级：每行渲染为一段，单元格之间用全角竖线「｜」连接。
  List<Widget> _table(md.Element el, TextStyle base, Color codeBg) {
    final rows = <Widget>[];
    for (final section
        in (el.children ?? const <md.Node>[]).whereType<md.Element>()) {
      if (section.tag != 'thead' && section.tag != 'tbody') continue;
      for (final tr in (section.children ?? const <md.Node>[])
          .whereType<md.Element>()
          .where((e) => e.tag == 'tr')) {
        final cells =
            (tr.children ?? const <md.Node>[]).whereType<md.Element>().toList();
        if (cells.isEmpty) continue;
        final spans = <InlineSpan>[];
        for (var i = 0; i < cells.length; i++) {
          if (i > 0) {
            spans.add(
                TextSpan(text: ' ｜ ', style: base.copyWith(height: 1.6)));
          }
          spans.add(_inlineChildren(
              cells[i].children ?? const <md.Node>[],
              base.copyWith(height: 1.6),
              codeBg));
        }
        rows.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text.rich(TextSpan(children: spans)),
        ));
      }
    }
    if (rows.isEmpty) {
      // 极端情况（表头/表体结构异常）：整体文本降级展示，不丢内容。
      final t = el.textContent.trim();
      if (t.isNotEmpty) {
        rows.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(t, style: base.copyWith(height: 1.6)),
        ));
      }
    }
    return rows;
  }

  /// 未知标签：含块级子节点 → 递归按块渲染；否则按纯文本段落渲染。
  List<Widget> _unknown(
      BuildContext context, md.Element el, TextStyle base, Color codeBg) {
    final children = el.children ?? const <md.Node>[];
    if (children.isEmpty) {
      final t = el.textContent.trim();
      if (t.isEmpty) return const <Widget>[];
      return <Widget>[Text(t, style: base.copyWith(height: 1.6))];
    }
    final bool hasBlock = children
        .any((c) => c is md.Element && _blockTags.contains(c.tag));
    if (hasBlock) {
      return <Widget>[
        for (final c in children) ..._block(context, c, base, codeBg),
      ];
    }
    return <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text.rich(
            _inlineChildren(children, base.copyWith(height: 1.6), codeBg)),
      ),
    ];
  }

  TextSpan _inlineChildren(
          List<md.Node> nodes, TextStyle style, Color codeBg) =>
      TextSpan(
          children: <InlineSpan>[for (final n in nodes) _inline(n, style, codeBg)]);

  TextSpan _inline(md.Node node, TextStyle style, Color codeBg) {
    if (node is md.Text) return TextSpan(text: node.text, style: style);
    if (node is! md.Element) {
      return TextSpan(text: node.textContent, style: style);
    }
    final el = node;
    switch (el.tag) {
      case 'strong':
        return _inlineChildren(el.children ?? const <md.Node>[],
            style.copyWith(fontWeight: FontWeight.bold), codeBg);
      case 'em':
        return _inlineChildren(el.children ?? const <md.Node>[],
            style.copyWith(fontStyle: FontStyle.italic), codeBg);
      case 'del':
        return _inlineChildren(el.children ?? const <md.Node>[],
            style.copyWith(decoration: TextDecoration.lineThrough), codeBg);
      case 'code':
        return TextSpan(
          text: el.textContent,
          style: style.copyWith(
            fontFamily: 'monospace',
            fontSize: (style.fontSize ?? 14) * 0.92,
            backgroundColor: codeBg.withValues(alpha: 0.75),
          ),
        );
      case 'a':
        final href = el.attributes['href'] ?? '';
        final label = el.textContent;
        return TextSpan(
          text: href.isEmpty || href == label ? label : '$label（$href）',
          style: style.copyWith(
              color: policyColor, decoration: TextDecoration.underline),
        );
      case 'br':
        return const TextSpan(text: '\n');
      default:
        return _inlineChildren(el.children ?? const <md.Node>[], style, codeBg);
    }
  }
}
