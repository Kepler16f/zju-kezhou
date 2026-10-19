/// engine/course_state.dart — 培养方案课程修读状态三态标定（纯 Dart）。
///
/// 2026-10-18 需求 #3：方案阅读页、学业达成审计页与选课页共用同一口径：
///  * earned：成绩通过且计入学分（绿）；
///  * active：本学期已选/课表在修，或成绩单待录（蓝）；
///  * noCredit：有记录但未获学分（未过/缺考/缓考/弃修等）；
///  * unknown：无证据（未修/未知，灰）。
/// 宁缺勿猜：无法确认时保留 unknown，绝不把“已选”算成“已获”。
library;

import 'matching.dart' show bestVariantAwareMatch;

/// 方案课程名“已修”解析（保留原写法，供 UI 直接查表）：
/// 成绩单全等命中优先，另用 difflib 风格相似度（cutoff 0.85）兜底。
/// 纯函数、不抛异常、宁缺勿猜：无命中一律视为未修。
Set<String> resolvePassedNames(
    Iterable<String> names, Set<String> transcriptNames) {
  if (transcriptNames.isEmpty) return const {};
  final possibilities = transcriptNames.toList();
  final out = <String>{};
  for (final raw in names) {
    final n = raw.trim();
    if (n.isEmpty) continue;
    if (transcriptNames.contains(n) ||
        bestVariantAwareMatch(n, possibilities) != null) {
      out.add(raw);
    }
  }
  return out;
}

/// 方案课程 chips 的修读状态：把原“成绩单里出现过就算已修”拆成三态，
/// 避免在修未出分/未通过的课被混入“已修”（无证据=unknown）。
enum PlanCourseState {
  /// 已修完：有成绩、通过且计入学分（绿）。
  earned,

  /// 在修：本学期已选/课表在修，或成绩待录未出分（蓝）。
  active,

  /// 已有记录未获学分：未过/缺考/缓考/弃修/无效等，需重修（橙）。
  noCredit,

  /// 无证据：未修/未知（灰）。
  unknown,
}

/// 单条成绩单记录 → 修读状态（不抛异常；认不出返回 null 不强行归类）。
/// 口径与引擎一致（engine/matching.dart 的 isPassed：passed 字段优先、缺省
/// grade≥60；credit_included 缺省视为 true）。
PlanCourseState? transcriptRowState(Map<String, dynamic> r) {
  final passedField = r['passed'];
  final isPassed = passedField != null
      ? passedField == true
      : ((r['grade'] as num?)?.toDouble() ?? 0) >= 60;
  if (isPassed && ((r['credit_included'] as bool?) ?? true)) {
    return PlanCourseState.earned;
  }
  final original = '${r['original'] ?? ''}'.trim();
  if (original == '待录') return PlanCourseState.active;
  if (isPassed) return PlanCourseState.noCredit; // 通过但学分被排除：未获学分
  final grade = (r['grade'] as num?)?.toDouble() ?? 0;
  const noCreditMarks = {'不及格', '不合格', '缺考', 'F', '弃修', '缓考', '无效'};
  if (noCreditMarks.contains(original) || (grade > 0 && !isPassed)) {
    return PlanCourseState.noCredit;
  }
  return null;
}

/// 修读状态证据集合（课程名均 trim；同一门课多来源冲突时按
/// earned > active > noCredit 优先级取，见 resolvePlanCourseStates）。
class PlanCourseEvidence {
  final Set<String> earned; // 已修完（有成绩且通过计学分）
  final Set<String> active; // 在修（本学期已选/课表/成绩待录）
  final Set<String> noCredit; // 有记录未获学分（未过/缓考/弃修等）
  const PlanCourseEvidence({
    this.earned = const {},
    this.active = const {},
    this.noCredit = const {},
  });
}

/// 从四个数据源收集修读状态证据（顶层纯函数、不抛异常、宁缺勿猜）：
///  * transcript 成绩单行：逐行 transcriptRowState 归类；
///  * choosed 本学期已选 / timetable 本学期课表：在修证据（active）；
///  * report 审计 plan_courses：passed=true → earned；
///    passed=false 且 record.grade>0（确有分数）→ noCredit；
///    grade 缺失/为 0 不猜（可能是待录，也可能是词语分映射 0）。
PlanCourseEvidence collectPlanCourseEvidence({
  List<Map<String, dynamic>> transcript = const [],
  Iterable<String> choosedNames = const [],
  Iterable<String> timetableNames = const [],
  List<Map<String, dynamic>> reportPlanCourses = const [],
}) {
  final earned = <String>{};
  final active = <String>{};
  final noCredit = <String>{};
  for (final r in transcript) {
    final name = '${r['name'] ?? ''}'.trim();
    if (name.isEmpty) continue;
    final st = transcriptRowState(r);
    if (st == PlanCourseState.earned) {
      earned.add(name);
    } else if (st == PlanCourseState.active) {
      active.add(name);
    } else if (st == PlanCourseState.noCredit) {
      noCredit.add(name);
    }
  }
  for (final n in choosedNames) {
    final t = n.trim();
    if (t.isNotEmpty) active.add(t);
  }
  for (final n in timetableNames) {
    final t = n.trim();
    if (t.isNotEmpty) active.add(t);
  }
  for (final c in reportPlanCourses) {
    final name = '${c['name'] ?? ''}'.trim();
    if (name.isEmpty) continue;
    if (c['passed'] == true) {
      earned.add(name);
      continue;
    }
    final g = ((c['record'] as Map?)?['grade'] as num?)?.toDouble() ?? 0;
    if (c['passed'] == false && g > 0) noCredit.add(name);
  }
  return PlanCourseEvidence(earned: earned, active: active, noCredit: noCredit);
}

/// 方案课程名 → 修读状态：对每个证据集合复用 resolvePassedNames
/// （全等 + 相似度 ≥0.85），同一门课按 earned > active > noCredit 取最高
/// 优先级；无证据的名字也保留在结果里、值为 unknown。
Map<String, PlanCourseState> resolvePlanCourseStates(
    Iterable<String> planNames, PlanCourseEvidence ev) {
  final out = <String, PlanCourseState>{};
  void mark(Set<String> source, PlanCourseState st) {
    if (source.isEmpty) return;
    for (final n in resolvePassedNames(planNames, source)) {
      out.putIfAbsent(n, () => st); // 先标高优先级，低优先级不覆盖
    }
  }

  mark(ev.earned, PlanCourseState.earned);
  mark(ev.active, PlanCourseState.active);
  mark(ev.noCredit, PlanCourseState.noCredit);
  for (final n in planNames) {
    out.putIfAbsent(n, () => PlanCourseState.unknown);
  }
  return out;
}

/// UI 三态归并：页面只展示“已修 / 在修 / 未修”。
/// noCredit 与 unknown 都归入“未修”（是否需重修由副标题补充，不改口径）。
PlanCourseState courseDisplayState(PlanCourseState state) => switch (state) {
      PlanCourseState.earned => PlanCourseState.earned,
      PlanCourseState.active => PlanCourseState.active,
      _ => PlanCourseState.unknown,
    };

/// 三态可见文案（选课页与报告课程行共用）。
String courseStateLabel(PlanCourseState state) =>
    switch (courseDisplayState(state)) {
      PlanCourseState.earned => '已修',
      PlanCourseState.active => '在修',
      _ => '未修',
    };
