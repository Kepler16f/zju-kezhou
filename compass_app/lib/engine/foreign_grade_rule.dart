/// engine/foreign_grade_rule.dart — 外语年级兜底显示规则（纯函数，仅 UI 用）。
///
/// 用户口径（2026-10-18 反馈 #10）：
///  * 2026 级起：L1/L2 必修「大学英语IV」，L3 免修；
///  * 2026 级以前：所有等级都必修「大学英语IV」（旧生无免修）。
/// 这是「培养方案没列出具体外语课」时的兜底显示规则——方案若已列课程/给出
/// 具体要求，一律以方案为准，本模块不参与审计学分计算、不改动
/// kForeignLangCaps 口径（审计侧等级封顶仍是 L1=6/L2=4.5/L3=3）。
library;

/// 2026 级起启用「按等级免修」新规则的分界年。
const int kForeignGradeRuleStartYear = 2026;

/// 各年级兜底要求的必修外语课名（方案没列课时的显示提示）。
const String kForeignRequiredCourse = '大学英语IV';

/// 从年级字符串解析入学年份：'2026'/'2026级'/「2025-2026」→ 首个 19xx/20xx
/// 四位年份；非 19/20 开头四位 → null（宁缺勿猜，无年份不套用年级规则）。
int? parseForeignGradeYear(String? grade) {
  final m = RegExp(r'(?:19|20)\d{2}').firstMatch(grade ?? '');
  return m == null ? null : int.parse(m.group(0)!);
}

/// 2026 级起 L3 免修；更早年级或年级未知 → 不套用免修（保持现状按 3 分要求）。
bool isForeignExemptByGrade({required int? gradeYear, required String? level}) {
  if (gradeYear == null || level == null) return false;
  return gradeYear >= kForeignGradeRuleStartYear &&
      level.trim().toUpperCase() == 'L3';
}

/// 年级兜底一行提示（方案外语板块未列具体课程时的显示层说明）；
/// 年级未知返回 null（不打扰——用户可能连的是内置无年级方案）。
String? foreignGradeHint({required int? gradeYear}) {
  if (gradeYear == null) return null;
  if (gradeYear >= kForeignGradeRuleStartYear) {
    return '2026级起：L1/L2 必修$kForeignRequiredCourse，L3 免修';
  }
  return '2026级前：各等级均必修$kForeignRequiredCourse';
}

/// L3 段标签（2026级起显示「免修」，否则显示原 3 分口径）。
String foreignL3Label({required int? gradeYear}) =>
    (gradeYear != null && gradeYear >= kForeignGradeRuleStartYear)
        ? 'L3·免修'
        : 'L3·3分';
