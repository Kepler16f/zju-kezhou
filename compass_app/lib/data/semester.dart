/// data/semester.dart — 浙大学年学期日历（纯函数，可单测）。
///
/// 编码沿用引擎口径：'YYYY-A' = 秋冬学期（YYYY 年秋启动），'YYYY-B' = 春夏学期。
/// 周次依据校历起始周一推算；近年起始日有表可查，缺表年份退回启发式
/// （秋冬=9 月第二个周一，春夏=秋冬起始 +24 周，小学期=春夏起始 +16 周）。
/// 「短」= 学年末的小学期（夏季），放在该学年春季学期之后。
library;

/// 一个日期所处学期的信息（首页日期栏用）。
class TermInfo {
  final String code; // '2026-A' / '2026-B' / '2026-SS'
  final String name; // '秋冬学期' / '春夏学期' / '小学期'
  final String tag; // '2026秋冬' / '2027春夏' / '2027短'
  final int week; // 第几周（1 起）；假期为 0
  final bool vacation; // 是否处于假期（寒/暑，介于两个学期之间）

  const TermInfo(
      {required this.code,
      required this.name,
      required this.tag,
      required this.week,
      required this.vacation});
}

/// 各学年秋冬学期开课日（周一，校历；key = 学年首年）。
/// 2026-09-14 已与校历核实；其余为近年常规安排，误差最多影响周次 ±1。
const Map<int, String> _fallStarts = {
  2020: '2020-09-14',
  2021: '2021-09-13',
  2022: '2022-09-12',
  2023: '2023-09-11',
  2024: '2024-09-09',
  2025: '2025-09-15',
  2026: '2026-09-14',
  2027: '2027-09-13',
  2028: '2028-09-11',
};

DateTime _fallStart(int y) => DateTime.parse(_fallStarts[y] ?? _heuristic(y));

/// 启发式：9 月第二个周一。
String _heuristic(int y) {
  final first = DateTime(y, 9, 1);
  final firstMon = 1 + (8 - first.weekday) % 7; // 周一=1
  final secondMon = firstMon + 7;
  return '${y.toString().padLeft(4, '0')}-09-${secondMon.toString().padLeft(2, '0')}';
}

DateTime _springStart(int y) => _fallStart(y).add(const Duration(days: 24 * 7));
DateTime _shortStart(int y) => _springStart(y).add(const Duration(days: 16 * 7));

/// 日期 → 学期信息；假期返回下一学期（week=0, vacation=true）。
/// 教学周按 20 周计：秋冬第 21 周起视为寒假、春夏满 16 周进入小学期。
TermInfo termForDate(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  // 学年首年：日期落在 Y 年 9 月起的秋冬 → 学年 Y；1-8 月 → 学年 Y-1 的春夏/短。
  final y = day.month >= 8 ? day.year : day.year - 1;
  final fs = _fallStart(y);
  final ss = _springStart(y);
  final xs = _shortStart(y);

  if (!day.isBefore(fs)) {
    if (day.isBefore(ss)) {
      final week = (day.difference(fs).inDays ~/ 7) + 1;
      if (week > 20) {
        return TermInfo(
            code: '$y-B',
            name: '春夏学期',
            tag: '${y + 1}春夏',
            week: 0,
            vacation: true); // 寒假
      }
      return TermInfo(
          code: '$y-A',
          name: '秋冬学期',
          tag: '$y秋冬',
          week: week < 1 ? 1 : week,
          vacation: false);
    }
    if (day.isBefore(xs)) {
      return TermInfo(
          code: '$y-B',
          name: '春夏学期',
          tag: '${y + 1}春夏',
          week: (day.difference(ss).inDays ~/ 7) + 1,
          vacation: false);
    }
    if (day.isBefore(xs.add(const Duration(days: 5 * 7)))) {
      return TermInfo(
          code: '$y-SS',
          name: '小学期',
          tag: '${y + 1}短',
          week: (day.difference(xs).inDays ~/ 7) + 1,
          vacation: false);
    }
    // 暑假 → 下学年秋冬
    return TermInfo(
        code: '${y + 1}-A',
        name: '秋冬学期',
        tag: '${y + 1}秋冬',
        week: 0,
        vacation: true);
  }
  // 8 月及以前：处于上学年日程内（春夏/短/暑假），或寒假。
  if (!day.isBefore(_shortStart(y - 1).add(const Duration(days: 5 * 7))) &&
      day.isBefore(fs)) {
    // 暑假
    return TermInfo(
        code: '$y-A',
        name: '秋冬学期',
        tag: '$y秋冬',
        week: 0,
        vacation: true);
  }
  if (!day.isBefore(xs)) {
    return TermInfo(
        code: '${y - 1}-SS',
        name: '小学期',
        tag: '$y短',
        week: (day.difference(xs).inDays ~/ 7) + 1,
        vacation: false);
  }
  if (!day.isBefore(ss)) {
    return TermInfo(
        code: '${y - 1}-B',
        name: '春夏学期',
        tag: '$y春夏',
        week: (day.difference(ss).inDays ~/ 7) + 1,
        vacation: false);
  }
  // 寒假（秋冬结束 ~ 春夏开始之间）。
  return TermInfo(
      code: '${y - 1}-B',
      name: '春夏学期',
      tag: '$y春夏',
      week: 0,
      vacation: true);
}

/// 首页日期栏一行文案：今天是 2026年10月16日 秋冬学期第5周第5天。
String todayLine(DateTime now) {
  final t = termForDate(now);
  final date = '${now.year}年${now.month}月${now.day}日';
  final dayInWeek = now.weekday; // 周一=第1天
  if (t.vacation) {
    final vac = t.code.endsWith('-B') ? '寒假' : '暑假';
    return '今天是$date $vac';
  }
  return '今天是$date ${t.name}第${t.week}周第$dayInWeek天';
}

/// 培养方案 PDF 的学期串（如「一(秋冬)」「二(秋)/二(冬)」「一(秋冬)+一(春夏)」）
/// → 按年级推算的日历标签（「2026秋冬」「2027秋/2027冬」「2026秋冬+2027春夏」）。
/// 解析不了的部分原样保留。
String prettyPlanTerm(String raw, {required int gradeYear}) {
  if (raw.isEmpty) return raw;
  final segRe = RegExp(r'([一二三四])(\(([^)]*)\))?');
  final out = raw.replaceAllMapped(segRe, (m) {
    final idx = ['一', '二', '三', '四'].indexOf(m.group(1)!) + 1; // 第几学年
    final half = m.group(3) ?? '';
    if (idx <= 0) return m.group(0)!;
    if (half == '短') return '${gradeYear + idx}短';
    switch (half) {
      case '秋冬':
        return '${gradeYear + idx - 1}秋冬';
      case '春夏':
        return '${gradeYear + idx}春夏';
      case '秋':
        return '${gradeYear + idx - 1}秋';
      case '冬':
        return '${gradeYear + idx - 1}冬';
      case '春':
        return '${gradeYear + idx}春';
      case '夏':
        return '${gradeYear + idx}夏';
      default:
        return m.group(0)!;
    }
  });
  return out;
}

/// 学期编码（'2026-A'）→ 展示标签（'2026秋冬'）。
String termCodeLabel(String code) {
  final m = RegExp(r'^(\d{4})-([AB])$').firstMatch(code);
  if (m == null) return code;
  final y = int.parse(m.group(1)!);
  return m.group(2) == 'A' ? '$y秋冬' : '${y + 1}春夏';
}
