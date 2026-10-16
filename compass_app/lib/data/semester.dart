/// data/semester.dart — 浙大学年学期日历（纯函数，可单测）。
///
/// 编码沿用引擎口径：'YYYY-A' = 秋冬学期（YYYY 年秋启动），'YYYY-B' = 春夏学期。
/// 周次依据校历起始周一推算；近年起始日有表可查，缺表年份退回启发式
/// （秋冬=9 月第二个周一，春夏=秋冬起始 +24 周，小学期=春夏起始 +16 周）。
/// 「短」= 学年末的小学期（夏季），放在该学年春季学期之后。
library;

/// 一个日期所处学期的信息（首页日期栏用）。
class TermInfo {
  final String code; // '2026-A' / '2026-B' / '2026-C'（A 秋冬 / B 春夏 / C 短）
  final String name; // '秋冬学期' / '春夏学期' / '小学期'
  final String tag; // '2026秋冬' / '2027春夏' / '2027短'
  final int week; // 第几周（1 起）；假期为 0
  final bool vacation; // 是否处于假期（寒/暑，介于两个学期之间）
  final String? subName; // 子学期：'秋学期' / '冬学期' / '春学期' / '夏学期'（无分划为 null）
  final int subWeek; // 子学期内周次（1 起）；无子学期为 0

  const TermInfo(
      {required this.code,
      required this.name,
      required this.tag,
      required this.week,
      required this.vacation,
      this.subName,
      this.subWeek = 0});
}

/// 秋冬/春夏学期按 8 周切子学期：秋 1-8、冬 9-16（春夏同理：春 1-8、夏 9-16）。
/// 第 17 周起为考试周/机动，无子学期归属。
({String? name, int week}) subTermOf(String termCode, int week) {
  if (week < 1 || week > 16) return (name: null, week: 0);
  final isFall = termCode.endsWith('-A');
  if (week <= 8) {
    return (name: isFall ? '秋学期' : '春学期', week: week);
  }
  return (name: isFall ? '冬学期' : '夏学期', week: week - 8);
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

  TermInfo mk(String code, String name, String tag, int week, bool vacation) {
    final sub = vacation ? (name: null, week: 0) : subTermOf(code, week);
    return TermInfo(
        code: code,
        name: name,
        tag: tag,
        week: week,
        vacation: vacation,
        subName: sub.name,
        subWeek: sub.week);
  }

  if (!day.isBefore(fs)) {
    if (day.isBefore(ss)) {
      final week = (day.difference(fs).inDays ~/ 7) + 1;
      if (week > 20) {
        return mk('$y-B', '春夏学期', '${y + 1}春夏', 0, true); // 寒假
      }
      return mk('$y-A', '秋冬学期', '$y秋冬', week < 1 ? 1 : week, false);
    }
    if (day.isBefore(xs)) {
      return mk('$y-B', '春夏学期', '${y + 1}春夏',
          (day.difference(ss).inDays ~/ 7) + 1, false);
    }
    if (day.isBefore(xs.add(const Duration(days: 5 * 7)))) {
      return mk('$y-C', '小学期', '${y + 1}短',
          (day.difference(xs).inDays ~/ 7) + 1, false);
    }
    // 暑假 → 下学年秋冬
    return mk('${y + 1}-A', '秋冬学期', '${y + 1}秋冬', 0, true);
  }
  // 8 月及以前：处于上学年日程内（春夏/短/暑假），或寒假。
  if (!day.isBefore(_shortStart(y - 1).add(const Duration(days: 5 * 7))) &&
      day.isBefore(fs)) {
    // 暑假
    return mk('$y-A', '秋冬学期', '$y秋冬', 0, true);
  }
  if (!day.isBefore(xs)) {
    return mk('${y - 1}-C', '小学期', '$y短',
        (day.difference(xs).inDays ~/ 7) + 1, false);
  }
  if (!day.isBefore(ss)) {
    return mk('${y - 1}-B', '春夏学期', '$y春夏',
        (day.difference(ss).inDays ~/ 7) + 1, false);
  }
  // 寒假（秋冬结束 ~ 春夏开始之间）。
  return mk('${y - 1}-B', '春夏学期', '$y春夏', 0, true);
}

/// 首页日期栏一行文案：
///  行课期 → 今天是 2026年10月16日 秋学期第5周第5天（秋冬内分秋/冬，诉求 #4）
///  第 17 周起/假期 → 今天是 2026年1月12日 寒假 / 秋冬学期第17周（考试周）
String todayLine(DateTime now) {
  final t = termForDate(now);
  final date = '${now.year}年${now.month}月${now.day}日';
  final dayInWeek = now.weekday; // 周一=第1天
  if (t.vacation) {
    final vac = t.code.endsWith('-B') ? '寒假' : '暑假';
    return '今天是$date $vac';
  }
  if (t.subName != null) {
    return '今天是$date ${t.subName}第${t.subWeek}周第$dayInWeek天'
        '（${t.tag}第${t.week}周）';
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

/// 学期编码（'2026-A' / '2026-C'）→ 展示标签（'2026秋冬' / '2027短'）。
/// 编码约定：A=秋冬（当年秋起）、B=春夏（次年春起）、C=短（次年夏）。
String termCodeLabel(String code) {
  final m = RegExp(r'^(\d{4})-([ABC])$').firstMatch(code);
  if (m == null) return code;
  final y = int.parse(m.group(1)!);
  return switch (m.group(2)) {
    'A' => '$y秋冬',
    'B' => '${y + 1}春夏',
    _ => '${y + 1}短',
  };
}

/// 教务学期串 → 日历标签。兼容多口径（zdbk 接口 kkxq/xnxq 常见形态）：
///  '20232024-1' / '2023-2024(1)' → '2023秋冬'；'2026秋冬' 原样；
///  '一(秋冬)' 风格（PDF 口径）需年级，未传年级时保留原文。
String prettySemester(String raw, {int gradeYear = 0}) {
  if (raw.isEmpty) return raw;
  // '20232024-1' / '2023-2024(1)' / '2025-2026（1）' 等学年+学期号形态
  final m = RegExp(r'(\d{4})\D{0,5}(\d{4})\D{0,3}([12])\D{0,3}$').firstMatch(raw);
  if (m != null && int.parse(m.group(2)!) == int.parse(m.group(1)!) + 1) {
    final y = int.parse(m.group(1)!);
    return m.group(3) == '1' ? '$y秋冬' : '${y + 1}春夏';
  }
  if (RegExp(r'^\d{4}-(秋冬|春夏|短)$').hasMatch(raw)) return raw;
  if (gradeYear > 0 && RegExp(r'^[一二三四]').hasMatch(raw)) {
    return prettyPlanTerm(raw, gradeYear: gradeYear);
  }
  return raw;
}
