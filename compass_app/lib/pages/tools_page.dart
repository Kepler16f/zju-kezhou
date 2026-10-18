/// pages/tools_page.dart — 工具页签（2026-10-18 需求 #1）：
/// 「学期走势（五分制折线，可收起）」+「GPA 模拟器 / 目标反推」自学业页迁出，
/// 独立为底栏规范索引 3 的页签。数据与学业页同源（主线传入，含本地排除标记的
/// 展示视图），下拉刷新走主线 onRefresh；空数据引导去「设置」页。
library;

import 'package:flutter/material.dart';

import '../data/semester.dart';
import '../engine/analytics.dart';
import '../widgets/gpa_simulator.dart';
import '../widgets/line_chart.dart';

class ToolsPage extends StatefulWidget {
  final List<Map<String, dynamic>> courses;
  final Map<String, Map<String, bool>> marks; // 本地排除标记（口径注释计数用）
  final Future<void> Function()? onRefresh;
  final VoidCallback? onGoSettings;

  const ToolsPage(
      {super.key, required this.courses,
      this.marks = const {},
      this.onRefresh,
      this.onGoSettings});

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  bool _trendOpen = false; // 走势卡默认收起（诉求：可收起/展开）

  @override
  Widget build(BuildContext context) {
    final courses = widget.courses;

    if (courses.isEmpty) {
      // 空态与学业页同款引导（文案刻意区分，便于测试各自锁定）。
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.build_outlined,
                  size: 56, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              const Text('暂无工具数据', style: TextStyle(fontSize: 16)),
              const SizedBox(height: 6),
              const Text('切到「设置」页导入成绩后，这里提供学期走势与 GPA 模拟器',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 14),
              FilledButton.tonalIcon(
                  onPressed: widget.onGoSettings,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('去设置')),
            ],
          ),
        ),
      );
    }

    final trend = Analytics.semesterTrend(courses);
    // semesterOrder 与 semesterTrend 内部同序（升序，unknown 最前），按下标配对。
    final sems = Analytics.semesterOrder(courses);
    // 走势默认五分制（任务包 B）：喂 five/cumulative_five，TrendChart 的
    // term/cumulative 字段名本就与分制无关，line_chart.dart 无需改动。
    final points = [
      for (var i = 0; i < trend.length; i++)
        TrendPoint(scholarTrendShortLabel(sems[i]), trend[i]['five']!,
            trend[i]['cumulative_five']!)
    ];

    return RefreshIndicator(
      onRefresh: () async => await widget.onRefresh?.call(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          // 学期走势：可收起卡片（诉求 #6），默认收起，标题行自带文案。
          // 收起时不构建曲线，省一次绘制。
          _trendCard(context, points),
          GpaSimulatorCard(courses: courses),
          Text(
              '口径：GPA 排除弃修/待录/缓考/二级制/线上课；五分绩点取教务 jd，'
              '缺失时参考换算；正式认定以教务为准。'
              '${widget.marks.isNotEmpty ? '已应用本地排除标记 ${widget.marks.length} 门（仅展示视图，不影响审计）。' : ''}',
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      ),
    );
  }

  /// 学期走势可收起卡（自学业页原样迁入）。
  Widget _trendCard(BuildContext context, List<TrendPoint> points) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _trendOpen = !_trendOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.show_chart,
                      size: 18, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text('学期走势（五分制）',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold)),
                  ),
                  AnimatedRotation(
                    turns: _trendOpen ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.expand_more,
                        size: 20, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: _trendOpen
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Column(
                      children: [
                        TrendChart(points: points),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _legend(Theme.of(context).colorScheme.primary,
                                '累计 GPA'),
                            const SizedBox(width: 12),
                            _legend(Theme.of(context).colorScheme.tertiary,
                                '学期 GPA'),
                          ],
                        ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _legend(Color c, String label) => Row(
        children: [
          Container(width: 18, height: 3, color: c),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      );
}

/// 学期编码 → 走势图短标签（纯函数，测试锁定于 test/tools_page_test.dart）：
/// '2023-A' → '23秋'，'2023-B' → '24春'，'2022-C' → '23短'。
/// 先走 data/semester.dart 的 termCodeLabel（'2023-A'→'2023秋冬'），
/// 再取年份后两位 + 季名首字压缩宽度；解析不了原样返回，'unknown' 显示 '?'。
String scholarTrendShortLabel(String sem) {
  if (sem == 'unknown') return '?';
  final full = termCodeLabel(sem);
  final m = RegExp(r'^(\d{2})(\d{2})([秋冬春短])').firstMatch(full);
  if (m == null) return full; // 宁缺勿猜：认不出就显示全称
  return '${m.group(2)}${m.group(3)}';
}
