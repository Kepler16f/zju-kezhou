/// engine/matching.dart — 已修记录 ↔ 方案课程的同一性匹配（确定性纯函数，无 IO）。
/// 由 engine/audit.dart 原 _isPassed/_match 逐行搬移（2026-10-15，选课建议复用），
/// 行为必须与搬移前逐字节一致：护栏 = golden_dart_report.json 字节 diff + 双引擎 parity；
/// 遍历顺序不可改（cross_engine_parity 按 index 比对 matched/unmatched 列表元素）。
library;

import 'timeline.dart';

/// 通过判定：passed 字段优先，缺省 grade>=60（与 Python 侧同口径）。
bool isPassed(Map<String, dynamic> r) {
  final passed = r['passed'];
  if (passed != null) return passed == true;
  final g = r['grade'];
  return g != null && (g as num).toDouble() >= Timeline.passGrade;
}

/// 已修记录 ↔ 方案课程：course_id 精确优先，名称相似度≥0.85 兜底。
/// 返回 (matched 对 [recordRow, planCourse], unmatched 记录行)；
/// 未命中不抛错——由调用方决定 unmatched 的呈现（audit: extra_courses）。
(List<List<dynamic>>, List<Map<String, dynamic>>) matchRecordToPlan(
    List<Map<String, dynamic>> recordCourses, Map<String, dynamic> plan) {
  final byId = <String, Map<String, dynamic>>{};
  final names = <String>[];
  final byName = <String, Map<String, dynamic>>{};
  for (final c in (plan['courses'] as List).cast<Map<String, dynamic>>()) {
    byId[c['course_id'] as String] = c;
    names.add(c['name'] as String);
    byName[c['name'] as String] = c;
  }
  final matched = <List<dynamic>>[];
  final unmatched = <Map<String, dynamic>>[];
  for (final r in recordCourses) {
    Map<String, dynamic>? course;
    final cid = r['course_id'];
    if (cid != null && byId.containsKey(cid)) {
      course = byId[cid];
    } else {
      final close = getCloseMatches(r['name'] as String, names, n: 1, cutoff: 0.85);
      if (close.isNotEmpty) course = byName[close.first];
    }
    if (course == null) {
      unmatched.add(r);
    } else {
      matched.add([r, course]);
    }
  }
  return (matched, unmatched);
}
