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

import '../engine/course_state.dart';

/// 审计报告的可嵌入展示：
/// 顶部应修/已取得/缺口 totals 卡 + 三色模块瓦片 + 未匹配课程 + 风险提示 + 免责声明。
class ReportSection extends StatelessWidget {
  final Map<String, dynamic> report;

  /// 渲染在 totals 卡正下方的附加行（方案页：本学期已选/在修学分，诉求 #8）。
  final Widget? belowTotals;

  /// 可选修读状态证据（成绩单/本学期已选/课表）。缺失时仅按报告 passed
  /// 标“已修”，其余为“未修”；不影响任何 earned/gap 数值。
  final PlanCourseEvidence? courseEvidence;

  /// 顶栏按钮直达（方案页 #9）：非空时对应瓦片重建并默认展开（token 变化即
  /// 重建，再次点击按钮可再次展开）；key 供宿主 Scrollable.ensureVisible 定位。
  /// 全部默认 null —— 无参默认行为与旧版完全一致。
  final String? modulesRevealToken;
  final String? warningsRevealToken;
  final GlobalKey? modulesKey;
  final GlobalKey? warningsKey;

  const ReportSection({
    super.key,
    required this.report,
    this.belowTotals,
    this.courseEvidence,
    this.modulesRevealToken,
    this.warningsRevealToken,
    this.modulesKey,
    this.warningsKey,
  });

  static const _colors = {
    'green': Color(0xFF16A34A),
    'yellow': Color(0xFFF59E0B),
    'red': Color(0xFFDC2626),
    'blue': Color(0xFF2563EB), // 口径色（诉求 #4）：蓝=已选上（已选未获学分）
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
    // 口径说明（诉求 #4）：引擎逐字输出的 caliber_notes（kCaliberEarnedNote /
    // kCaliberSelectedNote 等），UI 只搬运不复制；紧邻 disclaimer 展示。
    final caliberNotes =
        (report['caliber_notes'] as List? ?? const []).whereType<String>();
    // stretch：宿主 ListView 原本给子项的是通栏宽度，这里保持同样的通栏排版。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _num('应修', t['required']),
                    _num('已取得', t['earned']),
                    _num('缺口', t['gap'],
                        color: (t['gap'] as num) > 0 ? _colors['red']! : null),
                  ],
                ),
                // 已选未获（诉求 #4）：与已取得并列但绝不合并，提示口径。
                if ((t['selected_no_credit'] as num? ?? 0) > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '已选未获 ${t['selected_no_credit']} 门（未计入已取得，也不抵扣缺口）',
                      style:
                          TextStyle(fontSize: 11, color: _colors['blue']),
                    ),
                  ),
                // 总学分口径（v1.4）：方案声明「最低毕业学分」（引擎 totals.
                // plan_total_credits 原样展示）；total_basis=module_sum_fallback
                // 时引擎不输出该字段，此行不显示（口径见 caliber_notes/trace）。
                if (t['plan_total_credits'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '方案总学分 ${_fmtCredits(t['plan_total_credits'])}（声明）',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (belowTotals != null) belowTotals!,
        if (report['foreign_rule'] is Map)
          _foreignRuleCard((report['foreign_rule'] as Map).cast<String, dynamic>()),
        const SizedBox(height: 8),
        KeyedSubtree(
          key: modulesKey,
          child: ExpansionTile(
          key: modulesRevealToken != null
              ? ValueKey('report-modules#$modulesRevealToken')
              : const PageStorageKey<String>('report-modules'),
          initiallyExpanded: modulesRevealToken != null,
          tilePadding: EdgeInsets.zero,
          title: Text('三色学分达成度（${summary.length} 个板块）',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 15)),
          children: [
            // 颜色口径（诉求 #4）：绿=已获学分，蓝=已选上（已选未获学分）。
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('绿=已获学分；蓝=已选上（已选未获学分，与已取得分开呈现）',
                  style: TextStyle(fontSize: 10.5, color: Colors.grey)),
            ),
            // 外语口径通知（用户反馈 #7）：引擎把「外语等级→要求学分」的核算
            // 结果写进 trace.notes，这里搬到三色学分内联展示，让设置页的等级/
            // 分数选择与方案页学分可见地打通（此前 UI 从不渲染 trace.notes）。
            for (final n in (trace['notes'] as List? ?? const [])
                .whereType<String>()
                .where((n) => n.contains('外语')))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 3),
                child: Text('· $n',
                    style: const TextStyle(
                        fontSize: 10.5, height: 1.35, color: Colors.indigo)),
              ),
            for (final m in summary) _moduleTile(context, m),
          ],
        ),
        ),
        if (caliberNotes.isNotEmpty)
          ExpansionTile(
            key: const PageStorageKey<String>('report-caliber'),
            initiallyExpanded: false,
            tilePadding: EdgeInsets.zero,
            title: Text('口径说明（${caliberNotes.length} 条）',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final n in caliberNotes)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text('· $n',
                            style: const TextStyle(
                                fontSize: 11.5,
                                height: 1.45,
                                color: Colors.blueGrey)),
                      ),
                  ],
                ),
              ),
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
          KeyedSubtree(
            key: warningsKey,
            child: ExpansionTile(
              key: warningsRevealToken != null
                  ? ValueKey('report-warnings#$warningsRevealToken')
                  : const PageStorageKey<String>('report-warnings'),
              initiallyExpanded: warningsRevealToken != null,
              tilePadding: EdgeInsets.zero,
              title: Text('风险提示（${warnings.length} 条）',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
              children: [
                for (final w in warnings) _warningCard(w),
              ],
            ),
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

  /// 学分数展示：整数去掉小数尾（103.0 → "103"，4.5 保持 "4.5"）。
  String _fmtCredits(Object? v) {
    if (v is! num) return '$v';
    final d = v.toDouble();
    return d == d.roundToDouble() ? d.toStringAsFixed(0) : '$d';
  }

  /// 报告课程 → 名称状态表：先取共享证据，再用报告自身 passed 兜底/升级。
  Map<String, PlanCourseState> _statesForCourses(
      List<Map<String, dynamic>> courses) {
    final names = <String>[
      for (final c in courses)
        if ('${c['name'] ?? ''}'.trim().isNotEmpty) '${c['name'] ?? ''}'.trim(),
    ];
    final resolved = resolvePlanCourseStates(
        names, courseEvidence ?? const PlanCourseEvidence());
    final out = <String, PlanCourseState>{};
    for (final c in courses) {
      final name = '${c['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      out[name] = c['passed'] == true
          ? PlanCourseState.earned
          : (resolved[name] ?? PlanCourseState.unknown);
    }
    return out;
  }

  Map<PlanCourseState, int> _stateCounts(
      List<Map<String, dynamic>> courses, Map<String, PlanCourseState> states) {
    final out = <PlanCourseState, int>{
      PlanCourseState.earned: 0,
      PlanCourseState.active: 0,
      PlanCourseState.unknown: 0,
    };
    for (final c in courses) {
      final name = '${c['name'] ?? ''}'.trim();
      final display = courseDisplayState(c['passed'] == true
          ? PlanCourseState.earned
          : (states[name] ?? PlanCourseState.unknown));
      out[display] = (out[display] ?? 0) + 1;
    }
    return out;
  }

  double _creditsForState(List<Map<String, dynamic>> courses,
      Map<String, PlanCourseState> states, PlanCourseState target) {
    final wanted = courseDisplayState(target);
    var sum = 0.0;
    for (final c in courses) {
      final name = '${c['name'] ?? ''}'.trim();
      final state = c['passed'] == true
          ? PlanCourseState.earned
          : (states[name] ?? PlanCourseState.unknown);
      if (courseDisplayState(state) != wanted) continue;
      sum += (c['credits'] as num?)?.toDouble() ?? 0;
    }
    return sum;
  }

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

  /// 外语等级规则卡（用户反馈 #10）：设置页选择的等级如何落到方案学分，
  /// 必须与审计结果同屏可见——L1/L2（2026 级起）必修大学英语IV，L3 免修。
  Widget _foreignRuleCard(Map<String, dynamic> rule) {
    final level = '${rule['level'] ?? ''}';
    final credits = rule['required_credits'];
    final exempt = rule['exempt'] == true;
    final course = '${rule['required_course'] ?? ''}';
    final newRule = rule['new_rule'] == true;
    final detail = exempt
        ? '外语模块按 0 分核算，免修，无需修读大学英语IV'
        : course.isNotEmpty
            ? '外语模块按 ${_fmtCredits(credits)} 分核算，必修$course'
            : '外语模块按 ${_fmtCredits(credits)} 分核算';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.translate, size: 15, color: Colors.indigo),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              '外语等级 $level（${newRule ? '2026级新规' : '旧规'}）：$detail',
              style: const TextStyle(
                  fontSize: 11, height: 1.4, color: Colors.indigo),
            ),
          ),
        ],
      ),
    );
  }

  Widget _moduleTile(BuildContext context, Map<String, dynamic> m) {
    final color = _colors[m['color']] ?? Colors.grey;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final courses = (m['plan_courses'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final states = _statesForCourses(courses);
    final stateCounts = _stateCounts(courses, states);
    final activeCredits =
        _creditsForState(courses, states, PlanCourseState.active);
    final path = '${m['module_path'] ?? ''}';
    final title = '${m['title'] ?? _lastSegment(path)}';
    // 口径（需求 #2/#4）：已修学分直接用引擎 earned；在修学分只做蓝色提示，
    // 绝不相加到 earned，也不改变 gap。
    final earnedVal = (m['earned'] as num?) ?? 0;
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
                  _stat('已修学分', _fmtCredits(earnedVal),
                      earnedVal > 0 ? _colors['green']! : onSurface),
                  _stat('在修学分', '${_fmtCredits(activeCredits)}（不计入已修）',
                      _colors['blue']!),
                  _stat('缺口', '${m['gap']}',
                      (m['gap'] as num) > 0 ? _colors['red']! : onSurface),
                  _stat('方案课程', '${courses.length} 门', onSurface),
                  _stat('已修课程', '${stateCounts[PlanCourseState.earned] ?? 0} 门',
                      _colors['green']!),
                  _stat('在修课程', '${stateCounts[PlanCourseState.active] ?? 0} 门',
                      _colors['blue']!),
                  if ((m['selected_no_credit'] as num? ?? 0) > 0)
                    _stat(
                        '已选未获',
                        '${m['selected_no_credit']} 门（不计入已修）',
                        _colors['blue']!),
                  _stat(
                      '未修课程',
                      '${stateCounts[PlanCourseState.unknown] ?? 0} 门',
                      onSurface),
                ],
              ),
            ],
          ),
        ),
        trailing: Text('${m['gap']} 分',
            style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        children: [_moduleDetail(context, m, states)],
      ),
    );
  }

  /// 展开内容：培养方案的详细要求 + 全部课程（含已取得），而不是只有 missing。
  Widget _moduleDetail(BuildContext context, Map<String, dynamic> m,
      Map<String, PlanCourseState> states) {
    final notes = (m['notes'] as List? ?? const []);
    final subRules = (m['sub_requirements'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final courses = (m['plan_courses'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final stateCounts = _stateCounts(courses, states);
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
              '方案课程清单（${courses.length} 门'
              '，已修 ${stateCounts[PlanCourseState.earned] ?? 0} 门'
              '，在修 ${stateCounts[PlanCourseState.active] ?? 0} 门'
              '，未修 ${stateCounts[PlanCourseState.unknown] ?? 0} 门）',
              style:
                  const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          if (courses.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 3),
              child: Text('该板块暂未生成逐门课程明细；详细要求见上方修读说明。',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey)),
            )
          else
            for (final c in courses) _planCourseRow(c, states),
        ],
      ),
    );
  }

  Widget _planCourseRow(
      Map<String, dynamic> c, Map<String, PlanCourseState> states) {
    final name = '${c['name'] ?? ''}'.trim();
    final passed = c['passed'] == true;
    final state = passed
        ? PlanCourseState.earned
        : (states[name] ?? PlanCourseState.unknown);
    final display = courseDisplayState(state);
    final closed = c['closed'] == true;
    final record = c['record'] is Map
        ? (c['record'] as Map).cast<String, dynamic>()
        : null;
    final terms = (c['terms'] as List? ?? const []).join('、');
    final color = switch (display) {
      PlanCourseState.earned => _colors['green']!,
      PlanCourseState.active => _colors['blue']!,
      _ => Colors.grey,
    };
    final subtitle = <String>[
      '${c['credits'] ?? '?'} 学分',
      if (display == PlanCourseState.earned)
        '已获学分'
      else if (display == PlanCourseState.active)
        '已选未出分，不计入已修'
      else if (state == PlanCourseState.noCredit)
        '有记录未获学分，需重修'
      else if (closed)
        '学籍年限内已无开课窗口'
      else
        '未修${terms.isEmpty ? '' : ' · 可选窗口 $terms'}',
      if (record != null && '${record['semester'] ?? ''}'.isNotEmpty)
        '${record['semester']}'
      else if (c['page'] != null)
        '方案P${c['page']}',
    ].join(' · ');
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        display == PlanCourseState.earned
            ? Icons.check_circle
            : display == PlanCourseState.active
                ? Icons.schedule
                : closed
                    ? Icons.lock
                    : Icons.radio_button_unchecked,
        size: 18,
        color: color,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text('${c['name'] ?? '未命名课程'}',
                style: const TextStyle(fontSize: 12.5)),
          ),
          const SizedBox(width: 4),
          _courseStateBadge(state),
        ],
      ),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
    );
  }

  Widget _courseStateBadge(PlanCourseState state) {
    final display = courseDisplayState(state);
    final color = switch (display) {
      PlanCourseState.earned => _colors['green']!,
      PlanCourseState.active => _colors['blue']!,
      _ => Colors.grey,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        courseStateLabel(state),
        style: TextStyle(fontSize: 10.5, color: color),
      ),
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
