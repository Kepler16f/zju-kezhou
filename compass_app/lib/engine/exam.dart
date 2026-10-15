/// engine/exam.dart — 考试周冲刺引擎（纯函数，无 IO/无 UI）。
/// 对齐 Helechron 考试冲刺能力的确定性部分（报告 §6.1–6.2）：
///  - 正方考试接口行 → ExamInfo 的容错解析（字段名跨版本差异 + HTML 表格兜底）；
///  - 21 天窗口内的冲刺汇总：最近一场、排考时间冲突（红）、同日连考（橙，间隔<90min）；
///  - 倒计时文案。考场地图外部导航需要 url_launcher 依赖，当前提供"复制考场信息"兜底。
library;

class ExamInfo {
  final String name;
  final DateTime start;
  final DateTime end;
  final String location;
  final String seat;
  const ExamInfo({
    required this.name,
    required this.start,
    required this.end,
    this.location = '',
    this.seat = '',
  });

  String get locationFull => location.isEmpty
      ? (seat.isEmpty ? '考场待公布' : '考场待公布（座位 $seat）')
      : (seat.isEmpty ? location : '$location（座位 $seat）');
}

/// 单条正方考试记录 → ExamInfo。字段名容错（kcmc/ksmc、jsmc/jsmcq/cdmc、zwh/zwh1）；
/// 时间优先取完整区间（kssj 形如 "2026-01-20 08:00~10:00"），否则 ksrq+kssj 拼合。
/// 无法解析出课程名或开始时间的行返回 null（调用方过滤）。
ExamInfo? examFromRow(Map<String, dynamic> row) {
  String pick(List<String> keys) {
    for (final k in keys) {
      final v = row[k]?.toString().trim();
      if (v != null && v.isNotEmpty) return v;
    }
    return '';
  }

  final name = pick(['kcmc', 'ksmc', 'courseName']);
  if (name.isEmpty) return null;
  final loc = pick(['jsmc', 'jsmcq', 'cdmc', 'kscd', 'examRoom']);
  final seat = pick(['zwh', 'zwh1', 'seatNo']);

  final range = _parseTimeRange(
      '${pick(['ksrq', 'kssjrq'])} ${pick(['kssj', 'kssj2'])}');
  if (range == null) return null;
  return ExamInfo(
      name: name, start: range.$1, end: range.$2, location: loc, seat: seat);
}

/// 解析日期+时间区间，支持 "2026-01-20 08:00~10:00"、"2026-01-20 08:00-10:00"、
/// "2026-1-5 8:00~9:50"、"2026/01/20 08:00"（无结束时间默认 2 小时）。
(DateTime, DateTime)? _parseTimeRange(String text) {
  final m = RegExp(
          r'(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})日?\s*(\d{1,2}):(\d{2})'
          r'(?:\s*[~\-—至]+\s*(\d{1,2}):(\d{2}))?')
      .firstMatch(text);
  if (m == null) return null;
  DateTime at(int day, int hh, int mm) =>
      DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!),
          int.parse(m.group(3)!) + day, hh, mm);
  final start = at(0, int.parse(m.group(4)!), int.parse(m.group(5)!));
  final end = m.group(6) != null
      ? at(0, int.parse(m.group(6)!), int.parse(m.group(7)!))
      : start.add(const Duration(hours: 2));
  if (!end.isAfter(start)) return null;
  return (start, end);
}

/// 正方考试接口返回行列表 → ExamInfo 列表（按开始时间升序，丢弃脏行）。
List<ExamInfo> examsFromRows(List<dynamic> rows) {
  final out = <ExamInfo>[];
  for (final r in rows) {
    if (r is! Map) continue;
    final e = examFromRow(Map<String, dynamic>.from(r));
    if (e != null) out.add(e);
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// HTML 表格兜底（接口返回非 JSON 时）：逐 <tr> 提取 <td> 文本，
/// 识别"课程名 + 时间区间"组合，其余列按含教学楼关键词/数字座位容错。
/// 考场判定必须命中药实证（校区名或"字母+数字"楼号），防空串通配误吞课程名。
List<ExamInfo> examsFromHtmlTable(String html) {
  final out = <ExamInfo>[];
  final room = RegExp(
      r'((东|西|南|北)溪?校区?|紫金港|玉泉|华家池|海宁|之江)|[A-Za-z]\d{1,3}(-\d{1,4})?');
  for (final tr in html.split(RegExp(r'<tr[^>]*>', caseSensitive: false))
      .skip(1)) {
    final tds = RegExp(r'<td[^>]*>(.*?)</td>',
            caseSensitive: false, dotAll: true)
        .allMatches(tr)
        .map((m) => m
            .group(1)!
            .replaceAll(RegExp(r'<[^>]+>'), '')
            .replaceAll('&nbsp;', ' ')
            .trim())
        .where((t) => t.isNotEmpty)
        .toList();
    if (tds.length < 2) continue;
    final timeCell = tds.firstWhere(RegExp(r'\d{4}[-/.]').hasMatch,
        orElse: () => '');
    if (timeCell.isEmpty) continue;
    final parsed = _parseTimeRange(timeCell);
    if (parsed == null) continue;
    final name = tds.first; // 约定课程名在时间列之前；首列即时间则无法定位课程名
    if (name == timeCell) continue;
    final loc = tds.firstWhere(room.hasMatch, orElse: () => '');
    final seatCell = tds.firstWhere(RegExp(r'^\d{1,3}$').hasMatch,
        orElse: () => '');
    out.add(ExamInfo(
        name: name, start: parsed.$1, end: parsed.$2, location: loc,
        seat: seatCell));
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// 冲刺汇总（确定性规则）。
class SprintReport {
  final List<ExamInfo> upcoming; // 窗口内，按开始时间升序
  final List<(ExamInfo, ExamInfo)> conflicts; // 时间重叠
  final List<(ExamInfo, ExamInfo)> sameDayRush; // 同日间隔 < rushGap
  final ExamInfo? next;
  const SprintReport(
      {required this.upcoming,
      required this.conflicts,
      required this.sameDayRush,
      required this.next});
}

SprintReport examSprint(
  List<ExamInfo> exams,
  DateTime now, {
  int withinDays = 21,
  Duration rushGap = const Duration(minutes: 90),
}) {
  final horizon = now.add(Duration(days: withinDays));
  final upcoming =
      exams.where((e) => e.end.isAfter(now) && e.start.isBefore(horizon)).toList()
        ..sort((a, b) => a.start.compareTo(b.start));
  final conflicts = <(ExamInfo, ExamInfo)>[];
  final rush = <(ExamInfo, ExamInfo)>[];
  for (var i = 0; i < upcoming.length; i++) {
    for (var j = i + 1; j < upcoming.length; j++) {
      final a = upcoming[i], b = upcoming[j];
      if (a.end.isAfter(b.start)) {
        conflicts.add((a, b)); // 排考重叠：startA < endB（a 先开考）
      } else if (_sameDay(a.start, b.start) &&
          b.start.difference(a.end) < rushGap) {
        rush.add((a, b)); // 同日连考：间隔过短
      }
    }
  }
  return SprintReport(
      upcoming: upcoming,
      conflicts: conflicts,
      sameDayRush: rush,
      next: upcoming.isEmpty ? null : upcoming.first);
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 倒计时文案：">2 天 → X 天 Y 小时；>1 小时 → X 小时 Y 分；否则 X 分钟"。
String countdownText(Duration d) {
  if (d.isNegative) return '已开考';
  final days = d.inDays;
  if (days >= 2) return '$days 天 ${d.inHours - days * 24} 小时';
  if (d.inHours >= 1) {
    return '${d.inHours} 小时 ${d.inMinutes - d.inHours * 60} 分';
  }
  return '${d.inMinutes} 分钟';
}
