/// pages/grade_detail_page.dart — 成绩详情页（Helechron GradeDetailPage 对应物）：
/// 按学期分组的成绩明细，每行：课名 / 学分 / 百分制 / 五分绩点 / 状态。
/// 长按课程行 → 本地排除标记编辑（不计入学分 / 不计入绩点，报告 §3.1）：
/// 仅作用于学业视图计算域，不影响审计口径与教务原始数据。
library;

import 'package:flutter/material.dart';

import '../data/semester.dart';
import '../engine/analytics.dart';
import '../engine/course_marks.dart';

class GradeDetailPage extends StatefulWidget {
  final List<Map<String, dynamic>> courses;
  final Map<String, Map<String, bool>> marks;
  final void Function(String key, String kind, bool value)? onMark;
  const GradeDetailPage(
      {super.key, required this.courses, this.marks = const {}, this.onMark});

  @override
  State<GradeDetailPage> createState() => _GradeDetailPageState();
}

class _GradeDetailPageState extends State<GradeDetailPage> {
  late Map<String, Map<String, bool>> _marks = Map.of(widget.marks);

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
            return Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
              child: Text(
                  '长按课程行可设本地排除（不计入学分 / 绩点）——仅学业视图，不影响审计'
                  '${markedCount > 0 ? '｜已标记 $markedCount 门' : ''}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            );
          }
          final sem = semesters[i - 1];
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
