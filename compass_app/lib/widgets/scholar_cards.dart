/// widgets/scholar_cards.dart — Helechron 风格卡片组件（视觉模式独立实现）。
/// TwoLineCard：小标题+大数字+浅色底；ForeheadCard：彩色额头条（图标+标题+右侧状态）+内容区。
/// CreditBoardCard：学分看板（诉求 #4 口径注释：绿=已获学分，蓝=已选上）。
library;

import 'package:flutter/material.dart';

import '../engine/audit.dart' show kCaliberSelectedNote;

class ScholarPalette {
  static const cyan = Color(0xFF7DD3FC);
  static const peach = Color(0xFFFDBA74);
  static const spring = Color(0xFF86EFAC);
  static const sakura = Color(0xFFF9A8D4);
  static const sand = Color(0xFFE7C98B);
  static const magenta = Color(0xFFF0A3C8);
  static const okGreen = Color(0xFF6EE7B7);

  /// 口径色（诉求 #4，与三色报告/已选卡一致）：绿=已获学分，蓝=已选上。
  static const earnedGreen = Color(0xFF16A34A);
  static const selectedBlue = Color(0xFF2563EB);
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

/// 学分看板卡（诉求 #4 口径注释）：按课程性质展示已获学分，数值保持正常色；
/// 审计存在「已选未获学分」（selected_no_credit 之和 > 0）时，板底追加蓝色注释
/// 「另 N 门已选未获学分」，并引用 engine/audit.dart 的 [kCaliberSelectedNote]
/// 口径原文（文案单一来源，UI 不复制第二份）。颜色口径：绿=已获学分，蓝=已选上。
/// [cats] 为 Analytics.creditByCategory 输出（category/credits）；
/// [selectedNoCreditCount] 待 main.dart 从审计报告 summary 汇总传入（缺省 0 不显示）。
class CreditBoardCard extends StatelessWidget {
  final List<Map<String, dynamic>> cats;
  final int selectedNoCreditCount;
  const CreditBoardCard({super.key, required this.cats, this.selectedNoCreditCount = 0});

  @override
  Widget build(BuildContext context) {
    final maxCat = cats.isEmpty ? 1.0 : (cats.first['credits'] as double);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            for (final cat in cats)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                        width: 108,
                        child: Text(cat['category'] as String,
                            style: const TextStyle(fontSize: 12),
                            overflow: TextOverflow.ellipsis)),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: (cat['credits'] as double) / maxCat,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    SizedBox(
                        width: 48,
                        child: Text('${cat['credits']}',
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 12))),
                  ],
                ),
              ),
            if (selectedNoCreditCount > 0) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.playlist_add_circle_outlined,
                      size: 15, color: ScholarPalette.selectedBlue),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text('另 $selectedNoCreditCount 门已选未获学分',
                        style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: ScholarPalette.selectedBlue)),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(kCaliberSelectedNote,
                    style: TextStyle(
                        fontSize: 10,
                        height: 1.4,
                        color: Colors.grey.shade600)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
