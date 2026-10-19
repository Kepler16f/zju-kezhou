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

/// 已修记录 ↔ 方案课程：course_id 精确优先，名称相似度≥0.85 兜底；
/// 仍不命中时，最后用「归一化名唯一包含」兜底（外语等级罗马/中文数字变体，
/// 用户反馈 #7：大学英语（Ⅰ）/大学英语1/大学英语I（基础外语）等写法过不了 0.85）。
/// 归一化兜底只在「恰有一个方案课程」满足条件时生效（唯一性即 宁缺勿猜：
/// 大学英语 会同时命中 I/II/III/IV → 放弃，绝不蒙混）。返回 (matched 对
/// [recordRow, planCourse], unmatched 记录行)；未命中不抛错——由调用方决定
/// unmatched 的呈现（audit: extra_courses）。
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
      // 归一化兜底：仅在相似度也落空时进入，命中唯一才认，否则维持 unmatched
      //（既有行为零变化：精确/相似度路径产出的 matched 对与顺序完全不变，
      //  金标/parity 不受影响）。
      course ??= _uniqueNormalizedMatch(
          r['name'] as String, names, byName);
    }
    if (course == null) {
      unmatched.add(r);
    } else {
      matched.add([r, course]);
    }
  }
  return (matched, unmatched);
}

/// 归一化课名：小写、去空白（半/全角）、去括号字符（保留括号内文字），
/// 再把「独立量词数字」统一为阿拉伯数字——覆盖外语等级等课程名后缀的
/// 罗马数字（Ⅰ/Ⅱ/III/IV）、中文数字（一二三四）、财务数字（壹贰叁肆）
/// 与半角阿拉伯写法，使「大学英语（Ⅰ）」与「大学英语1」归一到同一串。
/// 只替换白名单记号（i/ii/…/x 及其全角、一..十、壹..拾），绝不动 c/d/l/m
/// 这类易混单字母。纯函数、不抛异常。
String normalizeCourseName(String name) {
  var s = name.toLowerCase();
  s = s.replaceAll(RegExp(r'[\s\u3000]+'), '');
  s = s
      .replaceAll(RegExp(r'[（(【\[《「『]'), '')
      .replaceAll(RegExp(r'[）)】\]》」』]'), '');
  // 全角罗马 → 半角（ⅰ..ⅹ / Ⅰ..Ⅹ）。
  const fwRoman = {
    'ⅰ': 'i', 'ⅱ': 'ii', 'ⅲ': 'iii', 'ⅳ': 'iv', 'ⅴ': 'v',
    'ⅵ': 'vi', 'ⅶ': 'vii', 'ⅷ': 'viii', 'ⅸ': 'ix', 'ⅹ': 'x',
  };
  fwRoman.forEach((k, v) => s = s.replaceAll(k, v));
  // 中文/财务数字 → 阿拉伯（单字，词内少见，风险低）。
  const cnDigit = {
    '一': '1', '壹': '1', '二': '2', '贰': '2', '三': '3', '叁': '3',
    '四': '4', '肆': '4', '五': '5', '伍': '5', '六': '6', '陆': '6',
    '七': '7', '柒': '7', '八': '8', '捌': '8', '九': '9', '玖': '9',
  };
  cnDigit.forEach((k, v) => s = s.replaceAll(k, v));
  // 半角罗马记号（仅白名单，最长优先，且须词边界：前后非拉丁字母数字）→ 阿拉伯。
  const romanMap = {
    'viii': '8', 'iii': '3', 'vii': '7', 'ix': '9', 'iv': '4',
    'vi': '6', 'ii': '2', 'x': '10', 'v': '5', 'i': '1',
  };
  for (final e in romanMap.entries) {
    final re = RegExp('(?<![a-z0-9])${e.key}(?![a-z0-9])');
    s = s.replaceAllMapped(re, (_) => e.value);
  }
  return s;
}

/// 在归一化名上做「唯一包含」匹配：记录归一化名与方案归一化名互相包含
/// （相等或一方为另一方子串）视为候选；候选恰一个时返回其方案行，否则 null
/// （歧义/无解一律放弃，宁缺勿猜——如「大学英语」归一化后仍是四门课的子串）。
Map<String, dynamic>? _uniqueNormalizedMatch(
  String recordName,
  List<String> planNames,
  Map<String, Map<String, dynamic>> byName,
) {
  final rn = normalizeCourseName(recordName);
  if (rn.isEmpty) return null;
  Map<String, dynamic>? hit;
  var count = 0;
  for (final pn in planNames) {
    final cn = normalizeCourseName(pn);
    if (cn.isEmpty) continue;
    if (cn == rn || cn.contains(rn) || rn.contains(cn)) {
      count++;
      hit = byName[pn];
      if (count > 1) return null; // 歧义：多个方案课都包含/被包含 → 放弃
    }
  }
  return count == 1 ? hit : null;
}
