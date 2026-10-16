/// pages/scholar_page.dart — 学业页 v3：顶部日期·学期·周次栏 + 考试周冲刺置顶卡 +
/// 成绩额头条（点击进成绩详情页）+ GPA 数字格 + 学分看板 + 课堂分 + 学期走势 +
/// GPA 模拟器（原「工具」页并入，诉求 #2）。空数据引导去"设置"页。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/semester.dart';
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
  final String? sourceLabel;
  final VoidCallback? onGoSettings;
  final Future<void> Function()? onRefresh;
  const ScholarPage(
      {super.key, required this.courses, required this.practice,
      this.exams = const [], this.marks = const {}, this.onMark,
      this.sourceLabel, this.onGoSettings, this.onRefresh});

  @override
  State<ScholarPage> createState() => _ScholarPageState();
}

class _ScholarPageState extends State<ScholarPage> {
  // 日期栏跨午夜/跨周需自刷新：每小时重算一次足够，且成本低。
  late Timer _clock;

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
    final sourceLabel = widget.sourceLabel;
    final onGoSettings = widget.onGoSettings;
    final onRefresh = widget.onRefresh;

    if (courses.isEmpty) {
      return Column(
        children: [
          _dateBanner(context),
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
    final maxCat = cats.isEmpty ? 1.0 : (cats.first['credits'] as double);
    final trend = Analytics.semesterTrend(courses);
    final points = [
      for (var i = 0; i < trend.length; i++)
        TrendPoint(_label(trend[i]), trend[i]['four']!,
            trend[i]['cumulative_four']!)
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
                // 考试周冲刺置顶卡（21 天窗口内有考试才渲染，内部 30s 自刷倒计时）
                if (exams.isNotEmpty) ExamSprintCard(exams: exams),
                ForeheadCard(
                  foreheadColor: ScholarPalette.okGreen,
                  icon: Icons.school,
                  title: '成绩',
                  trailing: sourceLabel,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => GradeDetailPage(
                          courses: courses, marks: marks, onMark: widget.onMark))),
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
                                  title: '获得学分',
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
                                  title: '已修门数',
                                  content: '${o['count']}',
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
                const SectionHeader('学分看板（按课程性质）'),
                Card(
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
                      ],
                    ),
                  ),
                ),
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
                const SectionHeader('学期走势（4.3 制）'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      children: [
                        TrendChart(points: points),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _legend(
                                Theme.of(context).colorScheme.primary,
                                '累计 GPA'),
                            const SizedBox(width: 12),
                            _legend(
                                Theme.of(context).colorScheme.tertiary,
                                '学期 GPA'),
                          ],
                        ),
                      ],
                    ),
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

  String _label(Map<String, double> t) {
    final idx = t['semester_idx']!;
    if (idx < 0) return '?';
    final y = (idx / 2).floor();
    return '$y-${idx % 2 == 0 ? 'A' : 'B'}';
  }

  double _legacyFour(List<Map<String, dynamic>> courses) {
    var sum = 0.0, credits = 0.0;
    for (final c in courses) {
      if (!((c['gpa_included'] as bool?) ?? true)) continue;
      final five = (c['five_point'] as num?)?.toDouble() ?? 0.0;
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
