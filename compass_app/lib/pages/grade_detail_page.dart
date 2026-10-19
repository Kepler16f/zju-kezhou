/// pages/grade_detail_page.dart — 成绩详情页（Helechron GradeDetailPage 对应物）：
/// 按学期分组的成绩明细，每行：课名 / 学分 / 百分制 / 五分绩点 / 状态。
/// 长按课程行 → 本地排除标记编辑（不计入学分 / 不计入绩点，报告 §3.1）：
/// 仅作用于学业视图计算域，不影响审计口径与教务原始数据。
library;

import 'package:flutter/material.dart';

import '../data/semester.dart';
import '../data/xk_models.dart';
import '../data/xk_parse.dart';
import '../engine/analytics.dart';
import '../engine/course_marks.dart';
import '../engine/course_state.dart';

class GradeDetailPage extends StatefulWidget {
  final List<Map<String, dynamic>> courses;
  final Map<String, Map<String, bool>> marks;
  final XkListParseResult? choosed; // 本学期已选（在修，未出成绩）
  final void Function(String key, String kind, bool value)? onMark;
  const GradeDetailPage(
      {super.key,
      required this.courses,
      this.marks = const {},
      this.choosed,
      this.onMark});

  @override
  State<GradeDetailPage> createState() => _GradeDetailPageState();
}

class _GradeDetailPageState extends State<GradeDetailPage> {
  late Map<String, Map<String, bool>> _marks = Map.of(widget.marks);
  String? _selectedSem; // 学期子标签选中项（诉求 #8）；null = 全部学期平铺

  @override
  void didUpdateWidget(GradeDetailPage old) {
    super.didUpdateWidget(old);
    if (!identical(widget.marks, old.marks)) _marks = Map.of(widget.marks);
  }

  void _setMark(String key, String kind, bool value) {
    setState(() {
      final row = Map<String, bool>.of(_marks[key] ?? const {});
      row[kind] = value;
      if (!(row['excludeCredit'] ?? false) && !(row['excludeGpa'] ?? false)) {
        _marks.remove(key); // 两项都不排除：清除该课的标记
      } else {
        _marks[key] = row;
      }
    });
    widget.onMark?.call(key, kind, value);
  }

  @override
  Widget build(BuildContext context) {
    final courses = applyCourseMarks(widget.courses, _marks);
    final semesters = Analytics.semesterOrder(courses);
    final markedCount = _marks.length;
    return Scaffold(
      appBar: AppBar(title: const Text('成绩明细')),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: semesters.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
                  child: Text(
                      '长按课程行可设本地排除（不计入学分 / 绩点）——仅学业视图，不影响审计'
                      '${markedCount > 0 ? '｜已标记 $markedCount 门' : ''}',
                      style:
                          const TextStyle(fontSize: 11, color: Colors.grey)),
                ),
                // 学期子标签（诉求 #8）：等宽 chips，点选过滤学期分组。
                if (semesters.length > 1) _semesterChips(context, semesters),
                if (widget.choosed != null)
                  _choosedCard(context, widget.choosed!),
              ],
            );
          }
          final sem = semesters[i - 1];
          // 诉求 #8：选中某学期时只展示该分组；「全部」恢复平铺。
          if (_selectedSem != null && sem != _selectedSem) {
            return const SizedBox.shrink();
          }
          final bucket = courses
              .where((c) => (c['semester'] as String? ?? 'unknown') == sem)
              .toList()
            ..sort((a, b) => (b['credits'] as num).compareTo(a['credits']));
          final o = Analytics.overall(bucket);
          final label = sem == 'unknown' ? '未识别学期' : _semLabel(sem);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
                child: Row(
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                    const Spacer(),
                    Text(
                        'GPA ${o['four']!.toStringAsFixed(2)}｜'
                        '${o['gpa_credits']!.toStringAsFixed(1)} 学分',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.primary)),
                  ],
                ),
              ),
              Card(
                child: Column(
                  children: [
                    for (final c in bucket)
                      _gradeRow(context, c, isLast: identical(c, bucket.last)),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 学期子标签（诉求 #8）：全部 Tab/Chip 固定等宽——LayoutBuilder 量宽后按
  /// [semesterChipColumns] 均分每行宽度，放不下自动换行（移动端不挤）。
  /// 点选某学期只显示该分组；「全部」恢复平铺。
  Widget _semesterChips(BuildContext context, List<String> semesters) {
    final chips = <MapEntry<String?, String>>[
      const MapEntry(null, '全部'),
      for (final s in semesters) MapEntry(s, termCodeLabel(s)),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 2),
      child: LayoutBuilder(builder: (context, cons) {
        const gap = 6.0;
        final perRow = semesterChipColumns(cons.maxWidth);
        final chipW = (cons.maxWidth - gap * (perRow - 1)) / perRow;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final c in chips)
              SizedBox(
                width: chipW,
                child: ChoiceChip(
                  label: SizedBox(
                    width: double.infinity,
                    child: Text(c.value,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12)),
                  ),
                  selected: _selectedSem == c.key,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                  onSelected: (_) => setState(() => _selectedSem = c.key),
                ),
              ),
          ],
        );
      }),
    );
  }

  /// 本学期已选分组：逐门区分「已获学分（成绩已出）」与「已选上（在修未出分）」。
  /// 与方案页审计区共用 [choosedCourseTranscriptState]，两页口径必须一致
  ///（用户反馈：审计页此前把所有已选课都当在修）。
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
    final states = <String, PlanCourseState?>{
      for (final c in choosed.courses)
        '${c.kch}\u0000${c.kcmc}': choosedCourseTranscriptState(
            courseId: c.kch, name: c.kcmc, transcript: widget.courses),
    };
    final earned = choosed.courses
        .where((c) => states['${c.kch}\u0000${c.kcmc}'] == PlanCourseState.earned)
        .toList();
    final active = choosed.courses.where(
        (c) => states['${c.kch}\u0000${c.kcmc}'] != PlanCourseState.earned).toList();
    double creditOf(Iterable<XkCourse> rows) =>
        rows.fold<double>(0, (s, c) => s + (c.xf ?? 0));
    final credits = creditOf(choosed.courses);
    String num(double v) =>
        (v - v.roundToDouble()).abs() < 1e-9 ? '${v.round()}' : v.toStringAsFixed(1);
    final countText = '${choosed.courses.length} 门 · ${num(credits)} 学分';
    final splitText = earned.isEmpty
        ? ' · 均为在修（未出成绩）'
        : ' · 已获学分 ${earned.length} 门 ${num(creditOf(earned))} 分 / '
            '在修 ${active.length} 门';
    return Card(
      margin: const EdgeInsets.only(top: 6, bottom: 4),
      child: ExpansionTile(
        initiallyExpanded: true,
        leading: Icon(Icons.playlist_add_check_circle_outlined,
            color: theme.colorScheme.primary),
        title: const Text('本学期已选（已获学分与在修分开）'),
        subtitle: Text('$countText$splitText'),
        children: [
          for (final c in choosed.courses)
            ListTile(
              dense: true,
              leading: Icon(
                states['${c.kch}\u0000${c.kcmc}'] == PlanCourseState.earned
                    ? Icons.check_circle_outline
                    : Icons.schedule,
                size: 18,
                color: states['${c.kch}\u0000${c.kcmc}'] == PlanCourseState.earned
                    ? Colors.green
                    : theme.colorScheme.primary,
              ),
              title: Text(c.kcmc),
              subtitle: Text(<String>[
                choosedCreditLabel(states['${c.kch}\u0000${c.kcmc}']),
                if (c.xf != null) '${c.xf} 学分',
                if (c.teacher.isNotEmpty) c.teacher,
                if (c.sksj.isNotEmpty) c.sksj,
                if (c.cdmc.isNotEmpty) c.cdmc,
              ].join(' · ')),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
                earned.isEmpty
                    ? '已选课程尚未出分；出分后自动计入上方学期成绩与 GPA。'
                    : '已获学分的课已计入上方学期成绩/GPA；在修课程未出分，不计入。',
                style: TextStyle(fontSize: 11, color: theme.hintColor)),
          ),
        ],
      ),
    );
  }

  void _showMarkEditor(BuildContext context, Map<String, dynamic> c) {
    final key = courseMarkKey(c);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          // 每次重建实时读 _marks（_setMark 换新 Map），开关状态不滞后
          final exCredit = _marks[key]?['excludeCredit'] ?? false;
          final exGpa = _marks[key]?['excludeGpa'] ?? false;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text('「${c['name']}」本地标记',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text(
                    '仅作用于学业视图（GPA/学分看板/模拟器），不影响审计结果与教务原始数据',
                    style: TextStyle(fontSize: 11)),
              ),
              SwitchListTile(
                  title: const Text('不计入学分'),
                  value: exCredit,
                  onChanged: (v) {
                    _setMark(key, 'excludeCredit', v);
                    setSheet(() {}); // 重新读取 _marks
                  }),
              SwitchListTile(
                  title: const Text('不计入绩点（GPA）'),
                  value: exGpa,
                  onChanged: (v) {
                    _setMark(key, 'excludeGpa', v);
                    setSheet(() {}); // 重新读取 _marks
                  }),
              const SizedBox(height: 12),
            ],
          );
        },
      ),
    );
  }

  Widget _gradeRow(BuildContext context, Map<String, dynamic> c,
      {required bool isLast}) {
    final passed = Analytics.isPassed(c); // 缺 passed 字段的记录按 grade>=60 推断
    final five = (c['five_point'] as num?)?.toDouble() ?? 0.0;
    final grade = (c['grade'] as num?)?.toInt() ?? 0;
    final original = (c['original'] as String?) ?? '';
    final gpaIncluded = (c['gpa_included'] as bool?) ?? true;
    final creditIncluded = (c['credit_included'] as bool?) ?? true;
    final marked = _marks.containsKey(courseMarkKey(c));
    return Column(
      children: [
        ListTile(
          dense: true,
          onLongPress: () => _showMarkEditor(context, c),
          title: Row(
            children: [
              Expanded(
                child: Text(c['name'] as String,
                    style: TextStyle(
                        fontSize: 14,
                        color: passed
                            ? null
                            : Theme.of(context).colorScheme.error)),
              ),
              if (marked)
                Icon(Icons.label_outline,
                    size: 13, color: Theme.of(context).colorScheme.tertiary),
            ],
          ),
          subtitle: Text(
              '${(c['credits'] as num).toStringAsFixed(1)} 学分'
              '${original.isNotEmpty && original != grade.toString() ? '｜$original' : ''}'
              '${!gpaIncluded ? '｜不计GPA' : ''}'
              '${!creditIncluded ? '｜不计学分' : ''}',
              style: const TextStyle(fontSize: 11)),
          trailing: SizedBox(
            width: 110,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(grade.toString(),
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: passed ? null : Theme.of(context).colorScheme.error)),
                    Text(five > 0 ? '绩点 ${five.toStringAsFixed(1)}' : '—',
                        style: const TextStyle(fontSize: 10)),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (!isLast) const Divider(height: 1, indent: 16),
      ],
    );
  }

  String _semLabel(String sem) {
    // "2023-A" → "2023秋冬"；"2023-B" → "2024春夏"（诉求 #8：日历标签）
    return termCodeLabel(sem);
  }
}

/// 学期子标签每行列数（诉求 #8 等宽，纯函数，测试锁定于 test/match_normalize_test.dart）：
/// 尽量保证每枚 chip ≥96px（容纳「2023秋冬」6 字标签），窄屏自动减列换行，
/// 宽屏封顶 8 列防标签过散。非法/零宽输入按 1 列处理。
int semesterChipColumns(double maxWidth) {
  if (maxWidth <= 0) return 1;
  final n = (maxWidth / 96).floor();
  if (n < 1) return 1;
  return n > 8 ? 8 : n;
}
