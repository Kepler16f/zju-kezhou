/// widgets/scholar_cards.dart — Helechron 风格卡片组件（视觉模式独立实现）。
/// TwoLineCard：小标题+大数字+浅色底；ForeheadCard：彩色额头条（图标+标题+右侧状态）+内容区。
library;

import 'package:flutter/material.dart';

class ScholarPalette {
  static const cyan = Color(0xFF7DD3FC);
  static const peach = Color(0xFFFDBA74);
  static const spring = Color(0xFF86EFAC);
  static const sakura = Color(0xFFF9A8D4);
  static const sand = Color(0xFFE7C98B);
  static const magenta = Color(0xFFF0A3C8);
  static const okGreen = Color(0xFF6EE7B7);
}

class TwoLineCard extends StatelessWidget {
  final String title;
  final String content;
  final String? extraContent;
  final Color color;
  const TwoLineCard(
      {super.key, required this.title, required this.content, required this.color,
      this.extraContent});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: dark ? color.withValues(alpha: 0.18) : color.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          Text(content,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis),
          if (extraContent != null)
            Text(extraContent!,
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class ForeheadCard extends StatelessWidget {
  final Color foreheadColor;
  final IconData icon;
  final String title;
  final String? trailing; // 右侧状态（如"更新于 N 分钟前"）
  final Widget child;
  final VoidCallback? onTap;
  const ForeheadCard(
      {super.key, required this.foreheadColor, required this.icon,
      required this.title, required this.child, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: foreheadColor.withValues(alpha: 0.35),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                children: [
                  Icon(icon, size: 17, color: scheme.onSurface),
                  const SizedBox(width: 6),
                  Text(title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  if (trailing != null)
                    Flexible(
                      child: Text(trailing!,
                          style: TextStyle(
                              fontSize: 11, color: scheme.onSurfaceVariant),
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
              ),
            ),
            Padding(padding: const EdgeInsets.all(10), child: child),
          ],
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  const SectionHeader(this.title, {super.key});

  @override
  Widget build(BuildContext context) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
        child: Text(title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      );
}
