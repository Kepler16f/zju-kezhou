/// widgets/report_view.dart — AuditReport JSON → 三色达成度 UI（数据全部来自引擎，UI 零计算）。
///
/// 审计功能并入「方案」页（诉求 #13）后，报告改为可嵌入形态：
/// [ReportSection] 是无滚动 Column（无外层 padding、不自带 ListView），
/// 由宿主页的 ListView 负责滚动；旧 AuditPage 独立页已随页签合并删除。
library;

import 'package:flutter/material.dart';

/// 审计报告的可嵌入展示：
/// 顶部应修/已修/缺口 totals 卡 + 三色模块瓦片 + 未匹配课程 + 风险提示 + 免责声明。
class ReportSection extends StatelessWidget {
  final Map<String, dynamic> report;

  /// 渲染在 totals 卡正下方的附加行（方案页：本学期已选/在修学分，诉求 #8）。
  final Widget? belowTotals;

  const ReportSection({super.key, required this.report, this.belowTotals});

  static const _colors = {
    'green': Color(0xFF16A34A),
    'yellow': Color(0xFFF59E0B),
    'red': Color(0xFFDC2626),
  };

  @override
  Widget build(BuildContext context) {
    final t = report['totals'] as Map<String, dynamic>;
    final summary = (report['summary'] as List).cast<Map<String, dynamic>>();
    final warnings = (report['warnings'] as List).cast<Map<String, dynamic>>();
    final extra = (report['extra_courses'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    // stretch：宿主 ListView 原本给子项的是通栏宽度，这里保持同样的通栏排版。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _num('应修', t['required']),
                _num('已修', t['earned']),
                _num('缺口', t['gap'], color: (t['gap'] as num) > 0 ? _colors['red']! : null),
              ],
            ),
          ),
        ),
        if (belowTotals != null) belowTotals!,
        const SizedBox(height: 8),
        const Text('三色学分达成度', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 4),
        for (final m in summary) _moduleTile(context, m),
        if (extra.isNotEmpty) ...[
          const SizedBox(height: 10),
          // 需求：不匹配方案的课也要如实展示，不能只字里行间省略。
          Text('已修但未匹配到方案（${extra.length} 门）',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          _extraCard(extra),
        ],
        if (warnings.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('风险提示（看不见的坑）',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          for (final w in warnings) _warningCard(w),
        ],
        const SizedBox(height: 10),
        Text(
          '${report['disclaimer']}\n${(report['trace'] as Map)['plan']}｜计算引擎 ${(report['trace'] as Map)['engine']}',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _num(String label, Object? v, {Color? color}) => Column(
        children: [
          Text('$v',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      );

  /// 模块统计小项：灰标签 + 加粗数值（紧凑、可换行）。
  Widget _stat(String label, String value, Color valueColor) => Text.rich(
        TextSpan(
          text: '$label ',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
          children: [
            TextSpan(
                text: value,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: valueColor)),
          ],
        ),
      );

  Widget _moduleTile(BuildContext context, Map<String, dynamic> m) {
    final color = _colors[m['color']] ?? Colors.grey;
    final missing = (m['missing_courses'] as List? ?? []).cast<Map<String, dynamic>>();
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        leading: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        title: Text(m['module_path'], style: const TextStyle(fontWeight: FontWeight.w600)),
        // 窄屏上一行塞不下四项统计会和 trailing 挤在一起，改为 Wrap 逐项换行。
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Wrap(
            spacing: 8,
            runSpacing: 2,
            children: [
              _stat('应修', '${m['required']}', onSurface),
              _stat('已修', '${m['earned']}', onSurface),
              _stat('缺口', '${m['gap']}',
                  (m['gap'] as num) > 0 ? _colors['red']! : onSurface),
              _stat('未来可选', '${m['remaining_future']}', onSurface),
            ],
          ),
        ),
        trailing: Text('${m['gap']} 分', style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        children: [
          if (missing.isEmpty)
            const ListTile(title: Text('✅ 学分已满足，无待修课程'))
          else
            Column(
              children: [
                for (final c in missing)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      c['closed'] == true ? Icons.lock : Icons.schedule,
                      size: 18,
                      color: c['closed'] == true ? Colors.red : Colors.orange,
                    ),
                    title: Text(c['name'] as String),
                    subtitle: Text(_courseLine(c),
                        style: const TextStyle(fontSize: 11)),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  String _courseLine(Map<String, dynamic> c) {
    final credit = c['credits'];
    if (c['closed'] == true) {
      return '$credit分 ｜ 学籍年限内已无开课窗口 ｜ 方案P${c['page'] ?? '?'}';
    }
    final terms = (c['terms'] as List? ?? []).join('、');
    return '$credit分 ｜ 可选窗口 $terms ｜ 方案P${c['page'] ?? '?'}';
  }

  Widget _warningCard(Map<String, dynamic> w) {
    final level = w['level'] as String;
    final color = switch (level) { 'red' => _colors['red']!, 'yellow' => _colors['yellow']!, _ => Colors.blueGrey };
    final refs = (w['refs'] as List? ?? []);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      shape: RoundedRectangleBorder(
          side: BorderSide(color: color.withValues(alpha: 0.35)),
          borderRadius: BorderRadius.circular(10)),
      child: ListTile(
        leading: Icon(level == 'red' ? Icons.warning_amber_rounded : Icons.info_outline, color: color),
        title: Text(w['text'] as String, style: const TextStyle(fontSize: 13)),
        subtitle: refs.isNotEmpty
            ? Text('溯源：${refs.join(' ｜ ')}', style: const TextStyle(fontSize: 11, color: Colors.blueGrey))
            : null,
      ),
    );
  }

  /// 已修但未匹配到方案的课程（成绩单里有、方案模块里没找到）。
  /// 按学期分组平铺展示，全部列出、一个不漏。
  Widget _extraCard(List<Map<String, dynamic>> extra) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                '以下课程在成绩单里有、但未匹配到培养方案模块（多为超修任选/通识大类/名称差异），'
                '不计入模块学分，仅供参考。',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            for (final c in extra)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text('${c['name']}', style: const TextStyle(fontSize: 12.5))),
                    if ('${c['semester'] ?? ''}'.isNotEmpty)
                      Text(' ${c['semester']} ',
                          style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    Text('${c['credits'] ?? '?'} 分',
                        style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
