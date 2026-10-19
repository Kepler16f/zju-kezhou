/// widgets/ai_message_body.dart — AI 回复的 Markdown + 公式降级渲染（#14）。
///
/// 设计取舍：
///  * 完整 KaTeX 体积过大、且与鸿蒙 3.27 兼容性不可控，公式采用**降级渲染**：
///    行内 $...$ 用等宽浅底保留 LaTeX 原文，块级 $$...$$ 走代码块样式。
///  * 只做对话里常见的块级元素（标题/段落/列表/围栏代码/引用/分隔线）；
///    未知标签按段落内联渲染，绝不抛异常、绝不丢内容。
///  * 纯 Stateless 渲染，不触网；超长文本截断到 20k 字符防一次排版卡顿。
library;

import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;

class AiMessageBody extends StatelessWidget {
  const AiMessageBody(this.markdown, {super.key});

  final String markdown;

  @override
  Widget build(BuildContext context) {
    final text = markdown.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    final clipped =
        text.length > 20000 ? '${text.substring(0, 20000)}\n…' : text;
    final nodes = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored)
        .parse(_extractMathBlocks(clipped));
    final base = DefaultTextStyle.of(context).style;
    final codeBg = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final n in nodes) ..._block(context, n, base, codeBg),
      ],
    );
  }

  /// 块级公式 → 围栏代码块（`latex`），复用代码块样式且不被 Markdown 转义吞掉。
  static String _extractMathBlocks(String s) => s.replaceAllMapped(
        RegExp(r'\$\$([\s\S]*?)\$\$'),
        (m) => '\n```latex\n${m.group(1)!.trim()}\n```\n',
      );

  List<Widget> _block(
      BuildContext context, md.Node node, TextStyle base, Color codeBg) {
    if (node is md.Text) {
      if (node.text.trim().isEmpty) return const [];
      return [Text.rich(_inline(node, base, codeBg))];
    }
    final el = node as md.Element;
    switch (el.tag) {
      case 'p':
        return [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text.rich(
                _inlineChildren(el.children ?? const [], base, codeBg)),
          ),
        ];
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final size = switch (el.tag) {
          'h1' => 18.0,
          'h2' => 16.5,
          'h3' => 15.0,
          _ => 14.0,
        };
        return [
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Text.rich(_inlineChildren(
                el.children ?? const [],
                base.copyWith(fontSize: size, fontWeight: FontWeight.bold),
                codeBg)),
          ),
        ];
      case 'pre':
        return [_codeBlock(context, el, base, codeBg)];
      case 'ul':
      case 'ol':
        return [_list(el, base, codeBg)];
      case 'blockquote':
        return [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.only(left: 8),
            decoration: BoxDecoration(
              border: Border(
                  left: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      width: 3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in el.children ?? const <md.Node>[])
                  ..._block(context, c, base, codeBg),
              ],
            ),
          ),
        ];
      case 'hr':
        return [
          Divider(
              height: 10,
              color: Theme.of(context).colorScheme.outlineVariant)
        ];
      default:
        // 表格等未专门支持的块：退化为内联文本，保证内容不丢。
        if ((el.children ?? const <md.Node>[]).isNotEmpty) {
          return [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text.rich(
                  _inlineChildren(el.children ?? const [], base, codeBg)),
            ),
          ];
        }
        return const [];
    }
  }

  Widget _codeBlock(
      BuildContext context, md.Element pre, TextStyle base, Color codeBg) {
    final codeEl = (pre.children ?? const <md.Node>[])
        .whereType<md.Element>()
        .cast<md.Element?>()
        .firstWhere((e) => e?.tag == 'code', orElse: () => null);
    final text = codeEl?.textContent ?? pre.textContent;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: codeBg.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant, width: 0.6),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          text.trimRight(),
          style: base.copyWith(
              fontFamily: 'monospace', fontSize: 11.5, height: 1.35),
        ),
      ),
    );
  }

  Widget _list(md.Element el, TextStyle base, Color codeBg) {
    final ordered = el.tag == 'ol';
    final items = (el.children ?? const <md.Node>[])
        .whereType<md.Element>()
        .where((e) => e.tag == 'li')
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 1, bottom: 1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ordered ? '${i + 1}. ' : '• ',
                    style: base.copyWith(fontWeight: FontWeight.w600)),
                Expanded(
                  child: Text.rich(_inlineChildren(
                      items[i].children ?? const [], base, codeBg)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  TextSpan _inlineChildren(
          List<md.Node> nodes, TextStyle style, Color codeBg) =>
      TextSpan(
          children: [for (final n in nodes) _inline(n, style, codeBg)]);

  TextSpan _inline(md.Node node, TextStyle style, Color codeBg) {
    if (node is md.Text) return _withInlineMath(node.text, style, codeBg);
    final el = node as md.Element;
    switch (el.tag) {
      case 'strong':
        return _inlineChildren(el.children ?? const [],
            style.copyWith(fontWeight: FontWeight.bold), codeBg);
      case 'em':
        return _inlineChildren(el.children ?? const [],
            style.copyWith(fontStyle: FontStyle.italic), codeBg);
      case 'del':
        return _inlineChildren(el.children ?? const [],
            style.copyWith(decoration: TextDecoration.lineThrough), codeBg);
      case 'code':
        return TextSpan(
          text: el.textContent,
          style: style.copyWith(
            fontFamily: 'monospace',
            fontSize: (style.fontSize ?? 14) * 0.92,
            backgroundColor: codeBg.withValues(alpha: 0.7),
          ),
        );
      case 'a':
        final href = el.attributes['href'] ?? '';
        final label = el.textContent;
        return TextSpan(
          text: href.isEmpty || href == label ? label : '$label（$href）',
          style: style.copyWith(
              color: Colors.blue.shade700,
              decoration: TextDecoration.underline),
        );
      case 'br':
        return const TextSpan(text: '\n');
      default:
        return _inlineChildren(el.children ?? const [], style, codeBg);
    }
  }

  /// 行内公式降级：`$...$` 用等宽字体原样展示，不打断正文流。
  TextSpan _withInlineMath(String text, TextStyle style, Color codeBg) {
    if (!text.contains(r'$')) return TextSpan(text: text, style: style);
    final spans = <TextSpan>[];
    var cursor = 0;
    final re = RegExp(r'\$([^$\n]+)\$');
    for (final m in re.allMatches(text)) {
      if (m.start > cursor) {
        spans.add(
            TextSpan(text: text.substring(cursor, m.start), style: style));
      }
      spans.add(TextSpan(
        text: m.group(1),
        style: style.copyWith(
          fontFamily: 'monospace',
          fontSize: (style.fontSize ?? 14) * 0.92,
          backgroundColor: codeBg.withValues(alpha: 0.55),
        ),
      ));
      cursor = m.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor), style: style));
    }
    return TextSpan(style: style, children: spans);
  }
}
