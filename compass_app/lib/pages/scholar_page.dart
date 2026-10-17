/// pages/scholar_page.dart — 学业页 v3：顶部日期·学期·周次栏（下接快捷卡，随内容滚动）
/// + 考试周冲刺置顶卡 + 成绩额头条（点击进成绩详情页）+ GPA 数字格 + 学分看板 +
/// 课堂分 + 学期走势（五分制，可收起）+ GPA 模拟器（原「工具」页并入，诉求 #2）。
/// 空数据引导去"设置"页。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/semester.dart';
import '../data/xk_models.dart';
import '../data/xk_parse.dart';
import '../engine/analytics.dart';
import '../engine/exam.dart';
import '../widgets/exam_sprint_card.dart';
import '../widgets/gpa_simulator.dart';
import '../widgets/line_chart.dart';
import '../widgets/scholar_cards.dart';
import 'grade_detail_page.dart';

class ScholarPage extends StatefulWidget {
  final List<Map<String, dynamic>> courses;
  final Map<String, double> practice;
  final List<ExamInfo> exams;
  final Map<String, Map<String, bool>> marks;
  final void Function(String key, String kind, bool value)? onMark;
  final XkListParseResult? choosed; // 本学期已选（在修，未出成绩）
  final String? sourceLabel;
  final VoidCallback? onGoSettings;
  final Future<void> Function()? onRefresh;

  /// 日期栏下方快捷卡（诉求 #16）：培养方案 / 我的课表。
  /// 课表周视图当前内嵌在方案页底部，两卡暂都跳方案页签。
  final VoidCallback? onGoPlan;
  final VoidCallback? onGoTimetable;

  const ScholarPage(
      {super.key, required this.courses, required this.practice,
      this.exams = const [], this.marks = const {}, this.onMark,
      this.choosed, this.sourceLabel, this.onGoSettings, this.onRefresh,
      this.onGoPlan, this.onGoTimetable});

  @override
  State<ScholarPage> createState() => _ScholarPageState();
}

class _ScholarPageState extends State<ScholarPage> {
  // 日期栏跨午夜/跨周需自刷新：每小时重算一次足够，且成本低。
  late Timer _clock;
  bool _trendOpen = false; // 走势卡默认收起（诉求：可收起/展开）

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(minutes: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final courses = widget.courses;
    final practice = widget.practice;
    final exams = widget.exams;
    final marks = widget.marks;
    final choosed = widget.choosed;
    final sourceLabel = widget.sourceLabel;
    final onGoSettings = widget.onGoSettings;
    final onRefresh = widget.onRefresh;

    if (courses.isEmpty) {
      return Column(
        children: [
          _dateBanner(context),
          // 空态无滚动区，快捷卡自带横向留白；有数据态由 ListView 提供留白。
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _quickLinks(context),
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.school_outlined,
                        size: 56, color: Theme.of(context).colorScheme.outline),
                    const SizedBox(height: 12),
                    const Text('暂无学业数据', style: TextStyle(fontSize: 16)),
                    const SizedBox(height: 6),
                    const Text('切到「设置」页，选择样例 / 粘贴成绩 / 登录教务网',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 14),
                    FilledButton.tonalIcon(
                        onPressed: onGoSettings,
                        icon: const Icon(Icons.settings_outlined),
                        label: const Text('去设置')),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }

    final o = Analytics.overall(courses);
    final cats = Analytics.creditByCategory(courses);
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

    return Column(
      children: [
        _dateBanner(context),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => await onRefresh?.call(),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              children: [
                // 快捷入口移入滚动内容首行（诉求 #8）：与内容同滚；
                // 日期栏底边距 4 + ListView 顶留白 4 = 8px 节奏。
                _quickLinks(context),
                // 考试周冲刺置顶卡（21 天窗口内有考试才渲染，内部 30s 自刷倒计时）
                if (exams.isNotEmpty) ExamSprintCard(exams: exams),
                ForeheadCard(
                  foreheadColor: ScholarPalette.okGreen,
                  icon: Icons.school,
                  title: '成绩',
                  trailing: sourceLabel,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => GradeDetailPage(
                          courses: courses,
                          marks: marks,
                          choosed: choosed,
                          onMark: widget.onMark))),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                              child: TwoLineCard(
                                  title: '五分制',
                                  content: o['five']!.toStringAsFixed(2),
                                  color: ScholarPalette.cyan)),
                          const SizedBox(width: 8),
                          Expanded(
                              child: TwoLineCard(
                                  title: '四分制(4.3)',
                                  content: o['four']!.toStringAsFixed(2),
                                  extraContent:
                                      '旧四分制 ${_legacyFour(courses).toStringAsFixed(2)}',
                                  color: ScholarPalette.spring)),
                          const SizedBox(width: 8),
                          Expanded(
                              child: TwoLineCard(
                                  title: '加权百分制',
                                  content: o['weighted']!.toStringAsFixed(2),
                                  color: ScholarPalette.magenta)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                              child: TwoLineCard(
                                  title: '已取得学分',
                                  content:
                                      o['earned_credits']!.toStringAsFixed(1),
                                  color: ScholarPalette.peach)),
                          const SizedBox(width: 8),
                          Expanded(
                              child: TwoLineCard(
                                  title: '计入GPA学分',
                                  content:
                                      o['gpa_credits']!.toStringAsFixed(1),
                                  color: ScholarPalette.sakura)),
                          const SizedBox(width: 8),
                          Expanded(
                              child: TwoLineCard(
                                  title: '已取得门数',
                                  content:
                                      '${courses.where(Analytics.isPassed).length}',
                                  color: ScholarPalette.sand)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Row(
                        children: [
                          Icon(Icons.chevron_right, size: 14),
                          Text('点击查看各学期成绩明细',
                              style:
                                  TextStyle(fontSize: 11, color: Colors.grey)),
                        ],
                      ),
                    ],
                  ),
                ),
                if (choosed != null) _choosedCard(context, choosed),
                const SectionHeader('学分看板（按课程性质）'),
                // 口径（诉求 #4）：已获学分正常色；审计存在「已选未获学分」时
                // 由 CreditBoardCard 追加蓝色注释（待 main.dart 接线传审计汇总数）。
                CreditBoardCard(cats: cats),
                const SectionHeader('课堂分（素拓）'),
                Card(
                  child: practice.isEmpty
                      ? const ListTile(
                          leading: Icon(Icons.info_outline),
                          title: Text('未获取'),
                          subtitle: Text('教务网模式登录后自动拉取第二/三/四课堂记点',
                              style: TextStyle(fontSize: 11)))
                      : Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              for (final e in practice.entries)
                                Column(
                                  children: [
                                    Text(e.value.toStringAsFixed(1),
                                        style: const TextStyle(
                                            fontSize: 22,
                                            fontWeight: FontWeight.bold)),
                                    Text(e.key,
                                        style: const TextStyle(fontSize: 11)),
                                  ],
                                ),
                            ],
                          ),
                        ),
                ),
                // 学期走势：可收起卡片（诉求 #6），默认收起，标题行自带文案
                //（不再用独立 SectionHeader）。收起时不构建曲线，省一次绘制。
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => setState(() => _trendOpen = !_trendOpen),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          child: Row(
                            children: [
                              Icon(Icons.show_chart,
                                  size: 18,
                                  color:
                                      Theme.of(context).colorScheme.primary),
                              const SizedBox(width: 6),
                              const Expanded(
                                child: Text('学期走势（五分制）',
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold)),
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
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        _legend(
                                            Theme.of(context)
                                                .colorScheme
                                                .primary,
                                            '累计 GPA'),
                                        const SizedBox(width: 12),
                                        _legend(
                                            Theme.of(context)
                                                .colorScheme
                                                .tertiary,
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
                ),
                const SectionHeader('GPA 模拟器'),
                GpaSimulatorCard(courses: courses),
                Text(
                    '口径：GPA 排除弃修/待录/缓考/二级制/线上课；五分绩点取教务 jd，'
                    '缺失时参考换算；正式认定以教务为准。'
                    '${marks.isNotEmpty ? '已应用本地排除标记 ${marks.length} 门（仅学业视图，不影响审计）。' : ''}',
                    style: const TextStyle(fontSize: 10, color: Colors.grey)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 快捷入口（诉求 #16）：培养方案 / 我的课表。已移入滚动内容首行（诉求 #8），
  /// 横向留白由外层 ListView/空态容器提供，此处只管行内布局与窄屏收字。
  Widget _quickLinks(BuildContext context) {
    return Row(
      children: [
        Expanded(
            child: _quickCard(
                Icons.menu_book, '培养方案', widget.onGoPlan)),
        const SizedBox(width: 8),
        Expanded(
            child: _quickCard(
                Icons.calendar_month, '我的课表', widget.onGoTimetable)),
      ],
    );
  }

  Widget _quickCard(IconData icon, String label, VoidCallback? onTap) => Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                // 窄屏不溢出：文字走 Flexible 收缩 + ellipsis。
                Flexible(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
                const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
              ],
            ),
          ),
        ),
      );

  /// 顶部一行：今天是x年x月x日 xx学期第x周第x天（诉求 #8）。
  Widget _dateBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = termForDate(DateTime.now());
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primaryContainer,
            scheme.tertiaryContainer.withValues(alpha: 0.6),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.wb_sunny_outlined, size: 18, color: scheme.onSurface),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              todayLine(DateTime.now()),
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface),
            ),
          ),
          if (!t.vacation)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(t.tag,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                      color: scheme.primary)),
            ),
        ],
      ),
    );
  }

  /// 本学期已选（在修）摘要卡。默认收起，展开后列出课程明细。
  /// 诉求 #6：已选列表可能与成绩单重叠（成绩已出/重修补选）——先按课程号/
  /// 归一化课程名匹配成绩记录再呈现：已获得学分的不再被笼统标成「在修，未出成绩」，
  /// 未匹配到任何成绩记录的在卡底给清单提示（视为在修）。
  /// 口径不变：已选课程本身不参与 GPA / 三色达成度计算。
  Widget _choosedCard(BuildContext context, XkListParseResult choosed) {
    final theme = Theme.of(context);
    if (choosed.state == 'unavailable') {
      return Card(
        child: ListTile(
          leading: Icon(Icons.info_outline, color: theme.colorScheme.error),
          title: const Text('本学期已选暂不可用'),
          subtitle: Text(choosed.issues.isEmpty
              ? '请到设置页重新拉取教务数据'
              : choosed.issues.first),
        ),
      );
    }
    if (choosed.state == 'empty' || choosed.courses.isEmpty) {
      return const Card(
        child: ListTile(
          title: Text('本学期已选'),
          subtitle: Text('0 门（接口明确返回空）'),
        ),
      );
    }
    final hits = <Map<String, dynamic>?>[
      for (final c in choosed.courses)
        matchRecordForCourse(
            courseId: c.kch, name: c.kcmc, records: widget.courses),
    ];
    var creditedCnt = 0;
    var earnedCredits = 0.0;
    var pendingCredits = 0.0;
    final unmatchedNames = <String>[];
    for (var i = 0; i < choosed.courses.length; i++) {
      final c = choosed.courses[i];
      final h = hits[i];
      if (h != null && recordEarnedCredit(h)) {
        creditedCnt++;
        earnedCredits +=
            ((h['credits'] as num?)?.toDouble()) ?? (c.xf ?? 0);
      } else {
        pendingCredits += c.xf ?? 0;
        if (h == null) unmatchedNames.add(c.kcmc);
      }
    }
    return Card(
      child: ExpansionTile(
        initiallyExpanded: false,
        leading: Icon(Icons.playlist_add_check_circle_outlined,
            color: theme.colorScheme.primary),
        title: Text(creditedCnt == choosed.courses.length
            ? '本学期已选（成绩均已出，已获学分）'
            : creditedCnt > 0
                ? '本学期已选（$creditedCnt 门已出成绩并获学分）'
                : '本学期已选（在修，未出成绩）'),
        subtitle: Text(<String>[
          '${choosed.courses.length} 门',
          if (creditedCnt > 0)
            '已获学分 $creditedCnt 门 ${_fmtCredits(earnedCredits)} 分',
          if (creditedCnt < choosed.courses.length)
            '在修 ${_fmtCredits(pendingCredits)} 学分',
          if (creditedCnt == 0) '不计入 GPA / 已取得学分',
        ].join(' · ')),
        children: [
          for (var i = 0; i < choosed.courses.length; i++)
            _choosedRow(context, choosed.courses[i], hits[i]),
          if (unmatchedNames.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Text(
                  '未匹配到成绩记录（视为在修，未出成绩）${unmatchedNames.length} 门：'
                  '${unmatchedNames.take(8).join('、')}${unmatchedNames.length > 8 ? ' 等' : ''}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ),
        ],
      ),
    );
  }

  /// 已选课程明细行（诉求 #6）：按匹配结果分三态——
  /// 已获学分（绿勾）/ 已有记录未获学分（重修·缓考·待录等）/ 未匹配（在修）。
  Widget _choosedRow(
      BuildContext context, XkCourse c, Map<String, dynamic>? hit) {
    final base = <String>[
      if (c.xf != null) '${c.xf} 学分',
      if (c.teacher.isNotEmpty) c.teacher,
      if (c.sksj.isNotEmpty) c.sksj,
      if (c.cdmc.isNotEmpty) c.cdmc,
    ];
    if (hit == null) {
      return ListTile(
        dense: true,
        leading: const Icon(Icons.schedule, size: 18),
        title: Text(c.kcmc, style: const TextStyle(fontSize: 13)),
        subtitle: base.isEmpty ? null : Text(base.join(' · ')),
      );
    }
    final sem = ((hit['semester'] as String?) ?? '').trim();
    final semLabel = (sem.isEmpty || sem == 'unknown') ? '' : termCodeLabel(sem);
    final original = ((hit['original'] as String?) ?? '').trim();
    final grade = (hit['grade'] as num?)?.toInt() ?? 0;
    if (recordEarnedCredit(hit)) {
      return ListTile(
        dense: true,
        leading: const Icon(Icons.check_circle,
            size: 18, color: ScholarPalette.earnedGreen),
        title: Text(c.kcmc, style: const TextStyle(fontSize: 13)),
        subtitle: Text(<String>[
          '已获得学分',
          if (semLabel.isNotEmpty) semLabel,
          if (grade > 0) '$grade 分',
          ...base,
        ].join(' · ')),
      );
    }
    return ListTile(
      dense: true,
      leading: const Icon(Icons.history, size: 18),
      title: Text(c.kcmc, style: const TextStyle(fontSize: 13)),
      subtitle: Text(<String>[
        '已有成绩记录，未获学分',
        if (semLabel.isNotEmpty) semLabel,
        if (original.isNotEmpty) original else if (grade > 0) '$grade 分' else '未出分',
        ...base,
      ].join(' · ')),
    );
  }

  String _fmtCredits(num v) {
    final d = v.toDouble();
    return (d - d.roundToDouble()).abs() < 1e-9
        ? '${d.round()}'
        : d.toStringAsFixed(1);
  }

  double _legacyFour(List<Map<String, dynamic>> courses) {
    var sum = 0.0, credits = 0.0;
    for (final c in courses) {
      if (!((c['gpa_included'] as bool?) ?? true)) continue;
      final five = Analytics.fiveOf(c); // jd 缺失时按百分制换算（与总计同口径）
      final credit = (c['credits'] as num?)?.toDouble() ?? 0.0;
      sum += (five > 4.0 ? 4.0 : five) * credit;
      credits += credit;
    }
    return credits == 0 ? 0.0 : sum / credits;
  }

  Widget _legend(Color c, String label) => Row(
        children: [
          Container(width: 18, height: 3, color: c),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      );
}

/// 学期编码 → 走势图短标签（纯函数，测试锁定于 test/scholar_trend_test.dart）：
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

// ── 已选课程 ↔ 成绩单匹配（诉求 #6；纯函数，测试锁定于 test/match_normalize_test.dart）──

/// 成绩记录是否「已获得学分」：通过（passed / grade≥60）且学分未被排除
/// （credit_included 缺省视为 true；弃修/待录/缓考/无效与本地排除标记均为 false）。
bool recordEarnedCredit(Map<String, dynamic> r) =>
    Analytics.isPassed(r) && ((r['credit_included'] as bool?) ?? true);

/// 课程名归一化（诉求 #6）：全角 ASCII → 半角、去全部空白（含全角空格/零宽字符）、
/// 去括号符号本身但保留括号内文字（（甲）→ 甲）、转小写。
/// 语义内容一律不删（Ⅰ / 数字版本号 / 教学班尾注文字等后缀保留），
/// 供正方成绩单与培养方案/已选列表两套数据源对齐后再比对。
String normalizeCourseName(String raw) {
  const spaces = {0x20, 0xA0, 0x3000, 0x200B, 0xFEFF};
  const brackets = {
    0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, // ( ) [ ] { } 及其全角形态（已折半角）
    0x3010, 0x3011, 0x300C, 0x300D, // 【 】 「 」
  };
  final sb = StringBuffer();
  for (final ch in raw.runes) {
    if (ch >= 0x09 && ch <= 0x0D) continue; // 制表/换行等控制空白
    var half = ch;
    if (half >= 0xFF01 && half <= 0xFF5E) half -= 0xFEE0; // 全角 ASCII → 半角
    if (spaces.contains(half) || brackets.contains(half)) continue;
    sb.writeCharCode(half);
  }
  return sb.toString().toLowerCase();
}

/// 单门已选课程 ↔ 成绩单记录匹配（纯函数、不抛异常、未命中返回 null，宁缺勿猜）：
///  1) course_id 精确：已选 kch 非空且成绩单存在该课号——同一课号多条（重修多学期）
///     取「已获学分优先、学期最晚次之、分数再次」的一条；
///  2) 归一化课程名全等：同名多条合并为同一门课，取法同上；
///  3) 归一化双向包含兜底：候选去重后唯一命中才认，且已选名≥2 字符（防单字误配）。
Map<String, dynamic>? matchRecordForCourse({
  required String? courseId,
  required String name,
  required List<Map<String, dynamic>> records,
}) {
  final id = (courseId ?? '').trim();
  if (id.isNotEmpty) {
    final byId = records
        .where((r) => ((r['course_id'] as String?) ?? '').trim() == id)
        .toList();
    if (byId.isNotEmpty) return _bestRecordOf(byId);
  }
  final norm = normalizeCourseName(name);
  if (norm.isEmpty) return null; // 占位名/空名不参与名称匹配
  final groups = <String, List<Map<String, dynamic>>>{};
  for (final r in records) {
    final rn = normalizeCourseName((r['name'] as String?) ?? '');
    if (rn.isEmpty) continue;
    groups.putIfAbsent(rn, () => []).add(r);
  }
  final exact = groups[norm];
  if (exact != null) return _bestRecordOf(exact);
  if (norm.length < 2) return null; // 包含兜底不认单字（宁缺勿猜）
  Map<String, dynamic>? hit;
  var hits = 0;
  for (final e in groups.entries) {
    if (e.key.contains(norm) || norm.contains(e.key)) {
      hits++;
      hit ??= _bestRecordOf(e.value);
    }
  }
  return hits == 1 ? hit : null;
}

/// 同一门课的多条成绩记录（重修/补考跨学期）→ 确定性取一条：
/// 已获学分优先，学期最晚次之（'unknown' 视为最早），百分制分数再次。
Map<String, dynamic>? _bestRecordOf(List<Map<String, dynamic>> rows) {
  if (rows.isEmpty) return null;
  String semKey(Map<String, dynamic> r) {
    final s = ((r['semester'] as String?) ?? '').trim();
    return (s.isEmpty || s == 'unknown') ? '' : s;
  }

  final sorted = [...rows]..sort((a, b) {
      final pa = recordEarnedCredit(a) ? 1 : 0;
      final pb = recordEarnedCredit(b) ? 1 : 0;
      if (pa != pb) return pb - pa;
      final sa = semKey(a), sb = semKey(b);
      if (sa != sb) return sb.compareTo(sa);
      return ((b['grade'] as num?)?.toDouble() ?? 0)
          .compareTo((a['grade'] as num?)?.toDouble() ?? 0);
    });
  return sorted.first;
}
