/// engine/course_marks.dart — 课程本地排除标记（对齐 Helechron 学分看板能力，纯函数无 IO）。
/// 学生可对单门课手动勾选「不计入学分」/「不计入绩点」（报告 §3.1）：
///  - 排除标记仅作用于学业视图的计算域（GPA/学分看板/走势/模拟器），
///    绝不污染审计口径——审计引擎不经过本模块，永远吃原始记录；
///  - 标记键：优先选课课号 xkkh（同一次修读唯一），无 xkkh（粘贴/样例模式）
///    退化为 name|semester；
///  - 标记按"排除"语义存储（excludeCredit/excludeGpa），两项皆非排除即清除该键。
library;

import 'dart:convert';

/// 课程行的标记键（跨会话稳定）。
String courseMarkKey(Map<String, dynamic> c) {
  final xkkh = (c['xkkh'] as String?)?.trim();
  if (xkkh != null && xkkh.isNotEmpty) return 'xkkh:$xkkh';
  final name = ((c['name'] as String?) ?? '').trim();
  final sem = (c['semester'] as String?) ?? 'unknown';
  return 'ns:$name|$sem';
}

/// 标记 JSON 反序列化（容错：坏结构/非法值一律丢弃，返回空表）。
Map<String, Map<String, bool>> parseMarks(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    final out = <String, Map<String, bool>>{};
    decoded.forEach((k, v) {
      if (v is Map) {
        final row = <String, bool>{
          if (v['excludeCredit'] is bool) 'excludeCredit': v['excludeCredit'] as bool,
          if (v['excludeGpa'] is bool) 'excludeGpa': v['excludeGpa'] as bool,
        };
        if (row.isNotEmpty) out[k.toString()] = row; // 全非法 → 连键一起丢弃
      }
    });
    return out;
  } catch (_) {
    return {};
  }
}

/// 应用标记：excludeCredit → credit_included=false；excludeGpa → gpa_included=false。
/// 只翻转显式排除项，其余字段原样保留；返回新 List/Map（不改入参，原始记录零污染）。
List<Map<String, dynamic>> applyCourseMarks(
    List<Map<String, dynamic>> courses, Map<String, Map<String, bool>> marks) {
  if (marks.isEmpty) return courses;
  return [
    for (final c in courses)
      () {
        final m = marks[courseMarkKey(c)];
        if (m == null) return c;
        final out = Map<String, dynamic>.of(c);
        if (m['excludeCredit'] == true) out['credit_included'] = false;
        if (m['excludeGpa'] == true) out['gpa_included'] = false;
        return out;
      }(),
  ];
}
