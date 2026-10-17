/// widgets/report_view.dart — AuditReport JSON → 三色达成度 UI（数据全部来自引擎，UI 零计算）。
///
/// 审计功能并入「方案」页（诉求 #13）后，报告改为可嵌入形态：
/// [ReportSection] 是无滚动 Column（无外层 padding、不自带 ListView），
/// 由宿主页的 ListView 负责滚动；旧 AuditPage 独立页已随页签合并删除。
///
/// 展示原则（用户反馈 #3/#4）：
///  - 模块标题用培养方案板块标题 + 完整路径，兄弟板块不再显示成同一行；
///  - 卡片/风险提示默认收起，收起时外面只显示数量；
///  - 展开后展示方案要求/修读说明/规则/全部课程（不只 missing），
///    不再出现“学分已满足，无待修课程”这种空泛结论。
library;

import 'package:flutter/material.dart';

/// 审计报告的可嵌入展示：
/// 顶部应修/已取得/缺口 totals 卡 + 三色模块瓦片 + 未匹配课程 + 风险提示 + 免责声明。
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
    final summary = (report['summary'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final warnings = (report['warnings'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final extra = (report['extra_courses'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final trace = (report['trace'] as Map?) ?? const {};
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
                _num('已取得', t['earned']),
                _num('缺口', t['gap'],
                    color: (t['gap'] as num) > 0 ? _colors['red']! : null),
              ],
            ),
          ),
        ),
        if (belowTotals != null) belowTotals!,
        const SizedBox(height: 8),
        ExpansionTile(
          key: const PageStorageKey<String>('report-modules'),
          initiallyExpanded: false,
          tilePadding: EdgeInsets.zero,
          title: Text('三色学分达成度（${summary.length} 个板块）',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 15)),
          children: [
            for (final m in summary) _moduleTile(context, m),
          ],
        ),
        if (extra.isNotEmpty)
          ExpansionTile(
            key: const PageStorageKey<String>('report-extra'),
            initiallyExpanded: false,
            tilePadding: EdgeInsets.zero,
            title: Text('已修但未匹配到方案（${extra.length} 门）',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15)),
            children: [_extraCard(extra)],
          ),
        if (warnings.isNotEmpty)
          ExpansionTile(
            key: const PageStorageKey<String>('report-warnings'),
            initiallyExpanded: false,
            tilePadding: EdgeInsets.zero,
            title: Text('风险提示（${warnings.length} 条）',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15)),
            children: [
              for (final w in warnings) _warningCard(w),
            ],
          ),
        const SizedBox(height: 10),
        Text(
          '${report['disclaimer']}\n${trace['plan']}｜计算引擎 ${trace['engine']}',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _num(String label, Object? v, {Color? color}) => Column(
        children: [
          Text('$v',
              style: TextStyle(
                  fontSize: 24, fontWeight: FontWeight.bold, color: color)),
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
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final stats = (m['course_stats'] as Map?) ?? const {};
    final path = '${m['module_path'] ?? ''}';
    final title = '${m['title'] ?? _lastSegment(path)}';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        key: PageStorageKey<String>('module-${m['module_id']}'),
        initiallyExpanded: false,
        leading: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (path.isNotEmpty && path != title)
                Text(path,
                    style:
                        const TextStyle(fontSize: 10.5, color: Colors.grey)),
              const SizedBox(height: 2),
              Wrap(
                spacing: 8,
                runSpacing: 2,
                children: [
                  _stat('应修', '${m['required']}', onSurface),
                  _stat('已取得', '${m['earned']}', onSurface),
                  _stat('缺口', '${m['gap']}',
                      (m['gap'] as num) > 0 ? _colors['red']! : onSurface),
                  _stat('方案课程', '${stats['total'] ?? 0} 门', onSurface),
                  _stat('已取得课程', '${stats['passed'] ?? 0} 门', onSurface),
                  _stat('待修课程', '${stats['pending'] ?? 0} 门', onSurface),
                ],
              ),
            ],
          ),
        ),
        trailing: Text('${m['gap']} 分',
            style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        children: [_moduleDetail(context, m)],
      ),
    );
  }

  /// 展开内容：培养方案的详细要求 + 全部课程（含已取得），而不是只有 missing。
  Widget _moduleDetail(BuildContext context, Map<String, dynamic> m) {
    final notes = (m['notes'] as List? ?? const []);
    final subRules = (m['sub_requirements'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final courses = (m['plan_courses'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final stats = (m['course_stats'] as Map?) ?? const {};
    final rule = m['choice_rule'] is Map
        ? (m['choice_rule'] as Map).cast<String, dynamic>()
        : null;
    final alt = m['alternative'] is Map
        ? (m['alternative'] as Map).cast<String, dynamic>()
        : null;
    final rawCredits = '${m['plan_credits_raw'] ?? ''}'.trim();
    final unit = '${m['plan_credits_unit'] ?? '学分'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              '培养方案要求：应修 ${m['required']} 学分'
              '${rawCredits.isEmpty ? '' : '（方案标注 $rawCredits $unit）'}',
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600)),
          if (rule != null) ...[
            const SizedBox(height: 3),
            Text('修读规则：${rule['text'] ?? ''}',
                style: const TextStyle(fontSize: 12)),
          ],
          if (alt != null) ...[
            const SizedBox(height: 3),
            Text(
                '并行选项（${alt['option_count'] ?? ''} 选 1）：'
                '${(alt['option_titles'] as List? ?? const []).join('、')}',
                style: const TextStyle(fontSize: 12)),
          ],
          if (subRules.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Text('板块内要求',
                style: TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600)),
            for (final r in subRules)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  '· ${r['title'] ?? ''}'
                  '${'${r['credits_raw'] ?? ''}'.trim().isEmpty ? '' : '（${r['credits_raw']} ${r['credits_unit'] ?? '学分'}）'}'
                  '${r['choice_rule'] is Map ? '：${(r['choice_rule'] as Map)['text'] ?? ''}' : ''}',
                  style: const TextStyle(fontSize: 11.5, height: 1.4),
                ),
              ),
          ],
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Text('修读说明',
                style: TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600)),
            for (final n in notes)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('· $n',
                    style: const TextStyle(fontSize: 11.5, height: 1.45)),
              ),
          ],
          const SizedBox(height: 6),
          Text(
              '方案课程清单（${stats['total'] ?? courses.length} 门'
              '，已取得 ${stats['passed'] ?? 0} 门'
              '，待修 ${stats['pending'] ?? 0} 门）',
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600)),
          if (courses.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 3),
              child: Text('该板块暂未生成逐门课程明细；详细要求见上方修读说明。',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey)),
            )
          else
            for (final c in courses) _planCourseRow(c),
        ],
      ),
    );
  }

  Widget _planCourseRow(Map<String, dynamic> c) {
    final passed = c['passed'] == true;
    final closed = c['closed'] == true;
    final record = c['record'] is Map
        ? (c['record'] as Map).cast<String, dynamic>()
        : null;
    final terms = (c['terms'] as List? ?? const []).join('、');
    final subtitle = <String>[
      '${c['credits'] ?? '?'} 学分',
      if (passed)
        '已取得'
      else if (closed)
        '学籍年限内已无开课窗口'
      else
        '待修${terms.isEmpty ? '' : ' · 可选窗口 $terms'}',
      if (record != null && '${record['semester'] ?? ''}'.isNotEmpty)
        '${record['semester']}'
      else if (c['page'] != null)
        '方案P${c['page']}',
    ].join(' · ');
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        passed
            ? Icons.check_circle
            : closed
                ? Icons.lock
                : Icons.schedule,
        size: 18,
        color: passed
            ? _colors['green']
            : closed
                ? _colors['red']
                : _colors['yellow'],
      ),
      title: Text('${c['name'] ?? '未命名课程'}',
          style: const TextStyle(fontSize: 12.5)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
    );
  }

  Widget _warningCard(Map<String, dynamic> w) {
    final level = w['level'] as String;
    final color = switch (level) {
      'red' => _colors['red']!,
      'yellow' => _colors['yellow']!,
      _ => Colors.blueGrey
    };
    final refs = (w['refs'] as List? ?? []);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 12),
      shape: RoundedRectangleBorder(
          side: BorderSide(color: color.withValues(alpha: 0.35)),
          borderRadius: BorderRadius.circular(10)),
      child: ListTile(
        leading: Icon(
            level == 'red'
                ? Icons.warning_amber_rounded
                : Icons.info_outline,
            color: color),
        title: Text(w['text'] as String, style: const TextStyle(fontSize: 13)),
        subtitle: refs.isNotEmpty
            ? Text('溯源：${refs.join(' ｜ ')}',
                style:
                    const TextStyle(fontSize: 11, color: Colors.blueGrey))
            : null,
      ),
    );
  }

  /// 已修但未匹配到方案的课程（成绩单里有、方案模块里没找到）。
  /// 按学期分组平铺展示，全部列出、一个不漏。
  Widget _extraCard(List<Map<String, dynamic>> extra) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 12),
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
                    Expanded(
                        child: Text('${c['name']}',
                            style: const TextStyle(fontSize: 12.5))),
                    if ('${c['semester'] ?? ''}'.isNotEmpty)
                      Text(' ${c['semester']} ',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey)),
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

  static String _lastSegment(String path) {
    final segments = path
        .split(RegExp('[·/]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return segments.isEmpty ? path : segments.last;
  }
}
