/// engine/matching.dart — 已修记录 ↔ 方案课程的同一性匹配（确定性纯函数，无 IO）。
/// 由 engine/audit.dart 原 _isPassed/_match 逐行搬移（2026-10-15，选课建议复用），
/// 行为必须与搬移前逐字节一致：护栏 = golden_dart_report.json 字节 diff + 双引擎 parity；
/// 遍历顺序不可改（cross_engine_parity 按 index 比对 matched/unmatched 列表元素）。
///
/// 2026-10-19 用户反馈（v1.7）：新增「课程变体签名」隔离
/// （courseVariantSignature / bestVariantAwareMatch）——大学英语（I）、
/// 大学英语（II）、大学英语（H）是三门不同课程，只修其中一门时，
/// 绝不允许把另外两门也模糊匹配成已修；engine/audit.py 同步镜像。
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
    // 空串不是有效课号：认定类合成行、部分教务导出都会带 ''。若让它进
    // byId，所有空课号的成绩行会精确命中同一门课（曾导致军训/国家安全
    // 教育全部挂到「大学生心理适应与发展」），必须按无效键跳过。
    final cid = c['course_id'];
    if (cid is String && cid.trim().isNotEmpty) byId[cid] = c;
    names.add(c['name'] as String);
    byName[c['name'] as String] = c;
  }
  final matched = <List<dynamic>>[];
  final unmatched = <Map<String, dynamic>>[];
  for (final r in recordCourses) {
    Map<String, dynamic>? course;
    final cid = r['course_id'];
    if (cid is String && cid.trim().isNotEmpty && byId.containsKey(cid)) {
      course = byId[cid];
    } else {
      final close = bestVariantAwareMatch(r['name'] as String, names);
      if (close != null) course = byName[close];
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

/// 课程变体签名：提取括号内/名字末尾的等级与班型记号（H、I/II/III、1-10、
/// 一…十、上/中/下、甲/乙/丙/丁 等），并归一为同一写法。
/// 用户反馈：大学英语（I）、大学英语（II）、大学英语（H）是三门不同课程；
/// 只修了其中一门时，绝不能把另外两门也标成已修。签名不同即视为不同课程。
String courseVariantSignature(String name) {
  final s = _halfWidthAscii(name).toLowerCase();
  final sigs = <String>[];
  for (final m in _bracketGroup.allMatches(s)) {
    final canon = _canonicalVariant(m.group(1) ?? '');
    if (canon != null) sigs.add(canon);
  }
  // 括号内记号之外，再看去掉括号后的末尾记号（如「大学英语II」「数学A（上）」）。
  final tail = _trailingVariant
      .firstMatch(s.replaceAll(_bracketGroup, ''));
  if (tail != null) {
    final canon = _canonicalVariant(tail.group(1) ?? '');
    if (canon != null) sigs.add(canon);
  }
  sigs.sort();
  return sigs.join('|');
}

/// 变体安全的模糊匹配（替代裸 getCloseMatches）：先排除签名冲突的候选
/// （I ≠ II ≠ H ≠ 上 ≠ 下…），再按相似度取最优。
///  * 记录名带签名：只认同签名候选（同签名都没有时才允许无签名候选）；
///  * 记录名无签名：候选里出现多个不同签名（I/II 并存）视为歧义，返回 null。
String? bestVariantAwareMatch(String word, List<String> possibilities,
    {double cutoff = 0.85}) {
  final sig = courseVariantSignature(word);
  final scored = <_VariantCandidate>[];
  for (var i = 0; i < possibilities.length; i++) {
    final p = possibilities[i];
    final ps = courseVariantSignature(p);
    if (sig.isNotEmpty && ps.isNotEmpty && ps != sig) continue;
    final r = SeqMatcher(word, p).ratio();
    if (r >= cutoff) {
      scored.add(_VariantCandidate(r, i, p, ps));
    }
  }
  if (scored.isEmpty) return null;
  var pool = scored;
  if (sig.isEmpty) {
    final distinct =
        scored.where((e) => e.signature.isNotEmpty).map((e) => e.signature).toSet();
    if (distinct.length > 1) return null; // 泛名同时命中 I/II…：宁缺勿猜
    final plain = scored.where((e) => e.signature.isEmpty).toList();
    if (plain.isNotEmpty) pool = plain;
  } else {
    final same = scored.where((e) => e.signature == sig).toList();
    if (same.isNotEmpty) pool = same;
  }
  pool.sort((a, b) {
    final c = b.ratio.compareTo(a.ratio);
    return c != 0 ? c : a.index.compareTo(b.index);
  });
  return pool.first.name;
}

class _VariantCandidate {
  final double ratio;
  final int index;
  final String name;
  final String signature;
  const _VariantCandidate(this.ratio, this.index, this.name, this.signature);
}

/// 全角 ASCII → 半角（仅签名提取用；不影响匹配原文）。
String _halfWidthAscii(String s) {
  final sb = StringBuffer();
  for (final ch in s.runes) {
    sb.writeCharCode(ch >= 0xFF01 && ch <= 0xFF5E ? ch - 0xFEE0 : ch);
  }
  return sb.toString();
}

final RegExp _bracketGroup =
    RegExp(r'[（(【\[《「『]([^）)】\]》」』]*)[）)】\]》」』]');

final RegExp _trailingVariant = RegExp(
    r'(?:^|[^a-z0-9])(h|i{1,3}|iv|v|vi{0,3}|ix|x|10|[1-9]'
    r'|[一二三四五六七八九十]|[壹贰叁肆伍陆柒捌玖拾]'
    r'|[ⅰⅱⅲⅳⅴⅵⅶⅷⅸⅹⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ]'
    r'|上|中|下|[甲乙丙丁]|[a-z])$');

/// 变体记号 → 统一签名。罗马/中文/财务数字都折成阿拉伯数字，
/// 全角罗马（Ⅰ..Ⅹ）单独列出（部分平台 toLowerCase 不折叠）。
const Map<String, String> _variantTokens = {
  'h': 'h',
  'i': '1', 'ii': '2', 'iii': '3', 'iv': '4', 'v': '5',
  'vi': '6', 'vii': '7', 'viii': '8', 'ix': '9', 'x': '10',
  'ⅰ': '1', 'ⅱ': '2', 'ⅲ': '3', 'ⅳ': '4', 'ⅴ': '5',
  'ⅵ': '6', 'ⅶ': '7', 'ⅷ': '8', 'ⅸ': '9', 'ⅹ': '10',
  'Ⅰ': '1', 'Ⅱ': '2', 'Ⅲ': '3', 'Ⅳ': '4', 'Ⅴ': '5',
  'Ⅵ': '6', 'Ⅶ': '7', 'Ⅷ': '8', 'Ⅸ': '9', 'Ⅹ': '10',
  '1': '1', '2': '2', '3': '3', '4': '4', '5': '5',
  '6': '6', '7': '7', '8': '8', '9': '9', '10': '10',
  '一': '1', '二': '2', '三': '3', '四': '4', '五': '5',
  '六': '6', '七': '7', '八': '8', '九': '9', '十': '10',
  '壹': '1', '贰': '2', '叁': '3', '肆': '4', '伍': '5',
  '陆': '6', '柒': '7', '捌': '8', '玖': '9', '拾': '10',
  '上': '上', '中': '中', '下': '下',
  '甲': '甲', '乙': '乙', '丙': '丙', '丁': '丁',
};

String? _canonicalVariant(String raw) {
  final t = _halfWidthAscii(raw).trim().toLowerCase();
  if (t.isEmpty) return null;
  return _variantTokens[t];
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
