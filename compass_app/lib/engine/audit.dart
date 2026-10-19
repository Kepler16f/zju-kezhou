/// engine/audit.dart — M2 学业进度审计规则引擎（确定性计算，无网络、无 LLM）。
/// 与 Python 版 engine/audit.py 逐逻辑对齐；golden 数据由 assets/golden/ 加载。
///
/// 口径（v1.3，2026-10-18 用户实测「积分重复计算」修复）：
///  * 选课组：模块内「四选一 / 选 N 门 / 至少修读 N 门」类组按「至少 N 门」
///    折算要求学分，不再按组内全部课程求和（识别见 [detectModuleGroupRule] 与
///    [effectiveRequiredCredits]：仅当要求学分 == 组内全部课程学分和（全量和
///    指纹）或模块为门数口径（count_rule / plan_credits_unit='门'）时折算，
///    只降不升——标注正确的模块一律不动）；
///  * 外语口径：build(record, plan, action) 的 action 支持
///    {'foreign_lang_credits': 正数}（自选要求学分=用户指定，可超过方案原要求，
///    2026-10-18 改版）与 {'foreign_lang_level': 'L1'|'L2'|'L3'}（向后兼容档位：
///    映射 caps 只降不升，L1=6 / L2=4.5 / L3=3）；两者缺省不假设，
///    trace 注明「外语等级未选择」；
///  * 已选 vs 已获：每模块输出 selected_no_credit（已选未获学分课程数），
///    与 earned（已获学分）分开呈现；报告顶层附 caliber_notes 口径说明；
///  * 多重计分（v1.4，2026-10-18 用户明确口径）：同一课程（course_id 或名称）
///    出现在方案多个模块（多标签）时，一条成绩单记录按每个所属模块分别计学分
///    （earned 与 selected_no_credit 同步双计；同一模块内仍去重、重修只计一次）；
///  * 总学分口径（v1.4）：毕业总要求以方案声明 meta.total_credits（最低毕业
///    学分）为准——totals 新增 plan_total_credits / total_basis；模块级要求照旧，
///    方案未声明时回落模块求和并在 trace.notes 说明；
///  * 三态打通与三选一（v1.5，2026-10-18 用户 #4/#8/#9）：
///    ① 在修证据降级：缺口类警告（graduation_risk / offering_closed 明细措辞）
///      读取 record['planned_courses']（可选参数 uiActiveNames 可并入 UI 侧证据），
///      已选（在修未出分）的课不再按「未修」报缺口——全额覆盖缺口时
///      red→yellow 并注记「已在修，待出成绩」，部分覆盖时文案给出「已选 X 门
///      N 学分（在修），仍缺 …」；missing_courses 行标记 active:true。
///      earned/totals 口径不变（在修绝不抵扣已获学分，既有红线）；
///    ② 并列选项组（alternative_groups）合成后，被落选选项模块的缺口类警告
///      一并清除（此前按三个选项分别生成红警，合成后未清理 → 缺口重复报警）；
///      组行自身缺口 >0 时补一条组级 graduation_risk；
///    ③ Python 镜像（engine/audit.py）补齐 alternative_groups 组行、singlePick
///      达成、countShort 与在修降级，双引擎逐字段对齐。
library;

import 'dart:convert';

import 'disclaimer.dart';
import 'matching.dart';
import 'timeline.dart';

// ── 选课组与外语等级口径（纯函数，独立可测；Python 镜像按同一规则对齐）──────

/// 外语等级 → 外语类模块「要求学分」封顶值（2026 级前口径：L1 计 6 分、
/// L2 计 4.5 分、L3 计 3 分；按等级封顶，绝不抬高方案原要求）。
const Map<String, double> kForeignLangCaps = <String, double>{
  'L1': 6.0,
  'L2': 4.5,
  'L3': 3.0,
};

/// 2026 级起的外语新规（用户反馈 #10）：L1/L2 必修「大学英语IV」，
/// L3 免修（要求学分 0）。等级档位改为**强制**该值（可升可降），
/// 因为方案 PDF 里仍写「L1 应修 6 / L2 应修 4.5 / L3 应修 3」，
/// 只降不升会让 L1 停在方案写的 3 分、L3 永远免修不掉。
const int kForeignNewRuleGradeYear = 2026;
const String kForeignRequiredCourse = '大学英语IV';
const Map<String, double> kForeignLangCaps2026 = <String, double>{
  'L1': 6.0,
  'L2': 4.5,
  'L3': 0.0,
};

/// 按入学年级取外语等级档位要求；2026 级起用新规，否则用旧封顶值。
double? foreignCapForLevel(String level, int? gradeYear) {
  final map = (gradeYear != null && gradeYear >= kForeignNewRuleGradeYear)
      ? kForeignLangCaps2026
      : kForeignLangCaps;
  return map[level];
}

/// 报告口径说明（顶层 caliber_notes 的固定两条，字面量被测试逐字断言；
/// UI 据此对 earned / selected_no_credit 用不同颜色注释）。
const String kCaliberEarnedNote =
    'earned=已获学分：仅统计已通过且计入学分的课程，同一门课重修/补考只计一次；'
    '弃修/待录/缓考/无效不计入。';
const String kCaliberSelectedNote =
    'selected_no_credit=已选未获学分：本模块内已修未通过（含在修未出分、'
    '弃修/待录/缓考/无效）或已列入计划选课、尚未取得学分的课程门数'
    '（按方案课程去重），与 earned 分开呈现，请勿相加当作总进度。';

/// 多重计分口径（v1.4，用户 2026-10-18 明确：一节课有两个标签时同时计入两边
/// 学分，与教务系统一致；固定第三条，字面量被测试逐字断言）。
const String kCaliberMultiTagNote =
    '同一课程多类别归属时按各模块分别计学分（培养方案口径），与教务系统一致。';

/// 选课组规则（「四选一」「选 N 门」「至少修读 N 门」等修读选择约束）。
/// [minCourses] 为组内至少要修的门数；[minCredits] 为显式学分下限（可空）；
/// [source] 记录识别来源，便于追溯（n_select/group/choice_rule/title）。
class ModuleGroupRule {
  final int? minCourses;
  final double? minCredits;
  final String source;

  /// 「多选一 / 任选其一 / 只选一门」：选够门数即整个模块达成，
  /// 不再按模块标注学分判缺口（用户反馈 #3）。
  final bool singlePick;

  const ModuleGroupRule({
    this.minCourses,
    this.minCredits,
    required this.source,
    this.singlePick = false,
  });
}

const String _cnNum = r'[0-9]+|[一二两三四五六七八九十]+';

const Map<String, int> _cnDigits = {
  '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
  '五': 5, '六': 6, '七': 7, '八': 8, '九': 9, '十': 10,
};

int? _parseCnCount(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  return int.tryParse(t) ?? _cnDigits[t];
}

/// 模块标识文本（module_path/title）→ 组内至少门数；无显式门数信号返回 null。
/// 支持「N 选 M」（N>M≥1，取 M）、「选 N 门」「至少（修读）N 门」；
/// 中文数字与阿拉伯数字皆可。刻意**不扫 notes**：说明文本里的门数常是只约束
/// 组内一部分课程的子规则（如「其中大学写作至少修读1门」），套到整模块会
/// 错杀真实总要求（宁缺勿猜）。
int? _countRuleFromText(String text) {
  final pick = RegExp('($_cnNum)\\s*选\\s*($_cnNum)').firstMatch(text);
  if (pick != null) {
    final n = _parseCnCount(pick.group(1)!);
    final m = _parseCnCount(pick.group(2)!);
    if (n != null && m != null && n > m && m > 0) return m;
  }
  final door =
      RegExp('(?:至少\\s*(?:修读|修)?\\s*|选\\s*)($_cnNum)\\s*门').firstMatch(text);
  if (door != null) {
    final x = _parseCnCount(door.group(1)!);
    if (x != null && x > 0) return x;
  }
  // 「多选一 / 任选其一」= 选 1 门即达成；裸「任选」不匹配（任意选修不是约束）。
  if (RegExp(r'(多选一|任选其一|任选一门|只选一门|选择其中一门|选其中一门)')
      .hasMatch(text)) {
    return 1;
  }
  final pickN =
      RegExp('(?:任选|只选|选择其中)\\s*($_cnNum)\\s*门').firstMatch(text);
  if (pickN != null) {
    final x = _parseCnCount(pickN.group(1)!);
    if (x != null && x > 0) return x;
  }
  return null;
}

/// 识别模块的选课组规则；识别不了返回 null（按普通学分模块核算，宁缺勿猜）。
/// 识别优先级：
///  1. 显式结构字段 `n_select`（组内任选 N 门）；
///  2. 显式结构字段 `group`（{min_courses, min_credits} 任一非空）；
///  3. `choice_rule`（engine/plan_audit_adapter.dart 从板块说明识别的约束）；
///  4. 模块标识文本（module_path + title）里的「N 选 M / 选 N 门 / 至少 N 门」。
ModuleGroupRule? detectModuleGroupRule(Map<String, dynamic> m) {
  final ns = m['n_select'];
  if (ns is num && ns >= 1) {
    return ModuleGroupRule(minCourses: ns.round(), source: 'n_select');
  }
  for (final key in const ['group', 'choice_rule']) {
    final g = m[key];
    if (g is! Map) continue;
    final mcRaw = g['min_courses'];
    final mc = mcRaw is num && mcRaw >= 1 ? mcRaw.round() : null;
    final mcx = (g['min_credits'] as num?)?.toDouble();
    if (mc != null || (mcx != null && mcx > 0)) {
      return ModuleGroupRule(
          minCourses: mc,
          minCredits: mcx,
          source: key,
          singlePick: g['single_pick'] == true);
    }
  }
  final idText = '${m['module_path'] ?? ''} ${m['title'] ?? ''}';
  final fromText = _countRuleFromText(idText);
  if (fromText != null) {
    return ModuleGroupRule(minCourses: fromText, source: 'title');
  }
  return null;
}

/// 外语类模块判据：module_path/title/category 命中「外语」或「英语」
/// （覆盖「外语类」「大学英语」等常见板块名；宁缺勿猜，不扫 notes/课程名）。
bool isForeignLangModule(Map<String, dynamic> m) {
  final t =
      '${m['module_path'] ?? ''} ${m['title'] ?? ''} ${m['category'] ?? ''}';
  return t.contains('外语') || t.contains('英语');
}

/// 课程行外语名判据（与板块判据同一组词面：外语/英语；宁缺勿猜不扫 日语 等
/// 小语种——成绩单小语种课极少且板块名通常含「外语」，会走板块路径）。
bool isForeignCourseName(String name) =>
    name.contains('外语') || name.contains('英语');

/// 素质拓展课堂模块判据（第二/三/四课堂）：无课程表、按平台记点认定，
/// 不能用「排课窗口/重修」口径报延毕风险（用户 #9）。
bool isPracticeModule(Map<String, dynamic> m) {
  final t = '${m['module_path'] ?? ''} ${m['title'] ?? ''} ${m['category'] ?? ''}';
  return t.contains('第二课堂') || t.contains('第三课堂') || t.contains('第四课堂');
}

/// 认定类模块（美育/劳育/创新创业/心理健康/军体/思政）：按清单认定，
/// 无固定开课窗口，同样不按课程排课口径报风险。
bool isCertifiedModule(Map<String, dynamic> m) =>
    m['certified_category'] is String;

/// 方案课程的开课学期列表；null/缺字段（认定类合成课程）统一为空列表，
/// 表示「方案未标注开课窗口」，调用方据此跳过开课冲突判断而不是崩溃。
List<String> offeredOf(Map<String, dynamic> c) =>
    (c['offered'] as List?)?.map((e) => '$e').toList() ?? const <String>[];

/// 外语板块行锚定（v1.5.1 #7）：详见 build() 调用点注释。纯函数：返回可能需要
/// 补挂合成行的新 plan（浅拷贝 + courses 追加），条件不满足一律原样返回。
Map<String, dynamic> _attachForeignAnchors(
    Map<String, dynamic> record, Map<String, dynamic> plan) {
  final modules = (plan['modules'] as List? ?? const []).cast<Map<String, dynamic>>();
  final foreignMods = modules.where(isForeignLangModule).toList();
  if (foreignMods.length != 1) return plan; // 0 个无关；>1 个歧义不猜
  final recordCourses =
      (record['courses'] as List? ?? const []).cast<Map<String, dynamic>>();
  final foreignRows = recordCourses
      .where((r) => isForeignCourseName('${r['name'] ?? ''}'.trim()))
      .toList();
  if (foreignRows.isEmpty) return plan;
  final planCourses =
      (plan['courses'] as List? ?? const []).cast<Map<String, dynamic>>();
  final foreignMid = '${foreignMods.single['module_id']}';
  // 板块已列外语课程表 → 锚定由既有匹配（ID/相似度/归一化兜底）负责，绝不重复挂。
  if (planCourses.any((c) => '${c['module_id'] ?? ''}' == foreignMid &&
      isForeignCourseName('${c['name'] ?? ''}'.trim()))) {
    return plan;
  }
  final existingIds = {for (final c in planCourses) '${c['course_id'] ?? ''}'};
  final existingNames = {
    for (final c in planCourses)
      normalizeCourseName('${c['name'] ?? ''}'.trim())
  };
  final synth = <Map<String, dynamic>>[];
  final claimed = <String>{}; // 成绩单同名/同id行只合成一次（重修）
  for (final r in foreignRows) {
    final rid = '${r['course_id'] ?? ''}'.trim();
    final rname = '${r['name'] ?? ''}'.trim();
    if (rname.isEmpty) continue;
    if (rid.isNotEmpty && existingIds.contains(rid)) continue;
    if (existingNames.contains(normalizeCourseName(rname))) continue;
    if (!claimed.add(rid.isNotEmpty ? rid : rname)) continue;
    final cr = r['credits'];
    synth.add(<String, dynamic>{
      'course_id': rid.isEmpty ? rname : rid,
      'name': rname,
      'credits': cr is num && cr > 0 ? cr.toDouble() : 0.0,
      'module_id': foreignMid,
      'nature': '必修',
      'offered': null,
      'grade_cycle': null,
      'offered_years': null,
      'prereq': <String>[],
      'source': <String, dynamic>{'page': null},
    });
  }
  if (synth.isEmpty) return plan;
  return <String, dynamic>{
    ...plan,
    'courses': [...planCourses, ...synth],
  };
}

double _r2(double v) => double.parse(v.toStringAsFixed(2));

/// 模块「有效要求学分」：修正两类「积分重复计算」（纯函数，宁缺勿猜、只降不升）：
///  * 门数口径模块（count_rule / plan_credits_unit='门'，如自建的门规则板块）：
///    required_credits 里的数字是要求**门数**不是学分 → 按 N 门最便宜课程折算；
///    折算不出（无课程/无门数信号）时保持原值（0 保持 0），绝不把门数当学分；
///  * 学分口径模块：仅当「要求学分 == 组内全部课程学分和」（选课组被全量和的
///    指纹）且存在含门数下限的组规则时，改按「N 门最便宜课程学分和」（有显式
///    minCredits 时取二者较大值）折算——方案标注正确（要求 < 全组和）的模块
///    一律不动。
double effectiveRequiredCredits(
    Map<String, dynamic> m,
    List<Map<String, dynamic>> moduleCourses,
    {ModuleGroupRule? rule}) {
  rule ??= detectModuleGroupRule(m);
  final req0 = (m['required_credits'] as num?)?.toDouble() ?? 0.0;
  // 组内课程去重（同一课程多标签/重复行只计一次学分），学分升序
  final seen = <String>{};
  final credits = <double>[];
  for (final c in moduleCourses) {
    final cid = '${c['course_id'] ?? c['name'] ?? ''}';
    if (!seen.add(cid)) continue;
    final v = (c['credits'] as num?)?.toDouble();
    if (v != null && v > 0) credits.add(v);
  }
  credits.sort();
  final fullSum = credits.fold<double>(0, (a, b) => a + b);

  double? cheapestSum(int n) {
    if (n < 1 || credits.isEmpty) return null;
    final take = n > credits.length ? credits.length : n;
    var s = 0.0;
    for (var i = 0; i < take; i++) {
      s += credits[i];
    }
    return s;
  }

  final isCount =
      m['count_rule'] == true || '${m['plan_credits_unit'] ?? ''}'.trim() == '门';
  if (isCount) {
    final n = rule?.minCourses ?? (req0 >= 1 ? req0.round() : null);
    final byCredits = rule?.minCredits ?? cheapestSum(n ?? 0);
    if (byCredits != null && byCredits > 0) return _r2(byCredits);
    return req0 <= 0 ? req0 : 0.0; // 门数折算不出时归 0，绝不把门数当学分
  }
  if (rule != null &&
      rule.minCourses != null &&
      rule.minCourses! >= 1 &&
      req0 > 0 &&
      fullSum > 0 &&
      (req0 - fullSum).abs() <= 1e-6) {
    var candidate = cheapestSum(rule.minCourses!);
    final mc = rule.minCredits;
    if (mc != null && mc > 0 && (candidate == null || mc > candidate)) {
      candidate = mc;
    }
    if (candidate != null && candidate < req0 - 1e-9) return _r2(candidate);
  }
  return req0;
}

class AuditEngine {
  static const engineVersion = "1.7";
  static const graduationYears = 6;

  final Map<String, dynamic> plans; // major -> PlanFile（内置 golden）
  final Map<String, Map<String, dynamic>> runtimePlans = {}; // 教务实时方案

  AuditEngine(this.plans);

  /// 注册教务实时获取的培养方案（优先于内置样例；key 建议用 normalizeMajorName 结果）
  void registerRuntimePlan(String key, Map<String, dynamic> plan) =>
      runtimePlans[key] = plan;

  void clearRuntimePlans() => runtimePlans.clear();

  static AuditEngine fromJsonAssets(Map<String, String> nameToJson) {
    final plans = <String, dynamic>{};
    nameToJson.forEach((_, jsonStr) {
      final p = json.decode(jsonStr) as Map<String, dynamic>;
      plans[p['meta']['major'] as String] = p;
    });
    return AuditEngine(plans);
  }

  Map<String, dynamic> findPlan(String major) {
    final p = runtimePlans[major] ?? plans[major];
    if (p == null) {
      throw ArgumentError('方案数据中无该专业：$major（支持：'
          '${[...runtimePlans.keys, ...plans.keys].join('、')}）');
    }
    return p;
  }

  // 已修↔方案的匹配与通过判定已移至 engine/matching.dart（选课建议共用，行为不变）。

  Map<String, dynamic> build(Map<String, dynamic> record, Map<String, dynamic> plan,
      {Map<String, dynamic>? action, Set<String>? uiActiveNames}) {
    // ── 外语板块行锚定（v1.5.1，用户反馈 #7「外语类课程也没匹配上去」）──────
    // 外语板块常见「方案只写应修学分、不给课程表」。此时成绩单里已修的外语课
    // （大学英语I/II…）在 plan['courses'] 无锚点，落进 extra_courses，外语板块
    // earned=0、gap 虚大（复现：已修大学英语I → earned=0.0/gap=6.0）。修法：
    // 存在唯一外语板块且该板块未列任何外语名课程行时，把未匹配的外语名成绩单
    // 行作为合成行挂到该板块（course_id 用成绩单行自身 id/名）。命中才返回
    // 浅拷贝，不命中/无需挂载原样返回，绝不改动传入对象（纯函数）。
    plan = _attachForeignAnchors(record, plan);
    // action 参数校验（宁缺勿猜：非法外语等级显式报错，不静默忽略；未知键忽略）
    final foreignLevelRaw = action?['foreign_lang_level'];
    if (foreignLevelRaw != null &&
        !kForeignLangCaps.containsKey('$foreignLevelRaw')) {
      throw ArgumentError(
          '未知的外语等级：$foreignLevelRaw（支持 L1/L2/L3）');
    }
    final foreignCreditsRaw = action?['foreign_lang_credits'];
    double? foreignCredits;
    if (foreignCreditsRaw != null) {
      final v = foreignCreditsRaw is num ? foreignCreditsRaw.toDouble() : null;
      // 0 = 免修（用户反馈 #10：2026 级起 L3 免修）——要求学分按 0 计；
      // 负数/非数仍拒绝（宁缺勿猜）。
      if (v == null || v < 0) {
        throw ArgumentError('非法的外语要求学分：$foreignCreditsRaw（需为非负数，0=免修）');
      }
      foreignCredits = v;
    }
    // 自选学分优先（=用户指定的模块要求）；level 档位按入学年级取档：
    // 2026 级起 L1/L2/L3 → 6/4.5/0（强制，可升可降），此前仍只降不升。
    final gradeYearForRule =
        int.tryParse('${(record['student'] as Map?)?['grade'] ?? ''}');
    final levelCap = foreignLevelRaw == null
        ? null
        : foreignCapForLevel('$foreignLevelRaw', gradeYearForRule);
    final foreignCap = foreignCredits ?? levelCap;
    final foreignNewRule = foreignCredits == null &&
        foreignLevelRaw != null &&
        gradeYearForRule != null &&
        gradeYearForRule >= kForeignNewRuleGradeYear;

    final recordCourses = (record['courses'] as List).cast<Map<String, dynamic>>();
    final (matched, unmatched) = matchRecordToPlan(recordCourses, plan);
    final planModules = (plan['modules'] as List).cast<Map<String, dynamic>>();
    final planHasForeign = planModules.any(isForeignLangModule);

    // ── 多重计分（v1.4）：多标签课程的归属展开 ─────────────────────────────
    // 数据表达：plan['courses'] 同一 course_id（或同名）出现多行、module_id
    // 不同（当前 golden/适配器均单归属；多行多归属出现时按本口径展开）。
    // 一条成绩单记录按其全部归属行分别计学分：每模块至多一次（module_id 去重）、
    // 同一模块内重复行仍去重、重修只计一次（见 earnedClaimed）。单归属课程
    // 展开后恰为原单行，行为与 v1.3 一致。
    final planRowsAll = (plan['courses'] as List).cast<Map<String, dynamic>>();
    final rowsById = <String, List<Map<String, dynamic>>>{};
    final rowsByName = <String, List<Map<String, dynamic>>>{};
    final moduleIdsByKey = <String, Set<String>>{}; // 'i|课号' / 'n|课名' → 所属模块
    for (final c in planRowsAll) {
      final cid = '${c['course_id'] ?? ''}';
      final nm = '${c['name'] ?? ''}';
      final mid = '${c['module_id'] ?? ''}';
      if (cid.isNotEmpty) {
        rowsById.putIfAbsent(cid, () => []).add(c);
        moduleIdsByKey.putIfAbsent('i|$cid', () => <String>{}).add(mid);
      }
      if (nm.isNotEmpty) {
        rowsByName.putIfAbsent(nm, () => []).add(c);
        moduleIdsByKey.putIfAbsent('n|$nm', () => <String>{}).add(mid);
      }
    }
    // 多标签判定：该行课号或课名去重后归属 >1 个模块（summary 明细标 multi_tag）
    bool planRowIsMultiTag(Map<String, dynamic> c) {
      final cid = '${c['course_id'] ?? ''}';
      final nm = '${c['name'] ?? ''}';
      return (cid.isNotEmpty && (moduleIdsByKey['i|$cid']?.length ?? 0) > 1) ||
          (nm.isNotEmpty && (moduleIdsByKey['n|$nm']?.length ?? 0) > 1);
    }

    // 一条匹配到的方案课程 → 其在方案中的全部归属行（课号相同或课名相同的行
    // 取并集；同一模块只保留首行——一条成绩单记录对每个模块至多贡献一次学分）。
    List<Map<String, dynamic>> membershipsOf(Map<String, dynamic> c) {
      final cid = '${c['course_id'] ?? ''}';
      final nm = '${c['name'] ?? ''}';
      final rows = <Map<String, dynamic>>[
        if (cid.isNotEmpty) ...rowsById[cid] ?? const [],
        if (nm.isNotEmpty) ...rowsByName[nm] ?? const [],
      ];
      final seenMods = <String>{};
      final out = <Map<String, dynamic>>[];
      for (final row in rows) {
        if (seenMods.add('${row['module_id'] ?? ''}')) out.add(row);
      }
      return out;
    }

    var multiTagCourseCount = 0; // 方案中多标签课程数（去重，供 trace.notes）
    final countedMultiTagKeys = <String>{};
    for (final c in planRowsAll) {
      final cid = '${c['course_id'] ?? ''}';
      final nm = '${c['name'] ?? ''}';
      final key = cid.isNotEmpty ? 'i|$cid' : (nm.isNotEmpty ? 'n|$nm' : null);
      if (key == null || !countedMultiTagKeys.add(key)) continue;
      if (planRowIsMultiTag(c)) multiTagCourseCount++;
    }

    final earned = <String, double>{};
    for (final m in planModules) {
      earned[m['module_id'] as String] = 0.0;
    }
    // 方案行同一性键：课号优先，空课号（认定类合成行/教务导出）退回课名。
    // 全用 '' 当键会让同模块多门无号课互相顶替（用户 #5：军训/国家安全教育
    // 曾被合并到同一门心理课）。
    String courseKey(Map<String, dynamic> c) {
      final cid = '${c['course_id'] ?? ''}'.trim();
      return cid.isNotEmpty ? cid : 'n|${c['name'] ?? ''}'.trim();
    }

    final passedIds = <String>{};
    final earnedCids = <String>{}; // 已获学分：通过且计入学分（与 earned 累加同条件）
    final selectedNoCreditIds = <String>{}; // 已选未获学分：已修未取得学分的课程
    final earnedClaimed = <String>{}; // '课号|模块'：一门课在每个模块只计一次学分
    final matchedRecordByPlanId = <String, Map<String, dynamic>>{};
    for (final pair in matched) {
      final r = pair[0] as Map<String, dynamic>, c = pair[1] as Map<String, dynamic>;
      final credited = isPassed(r) && (r['credit_included'] as bool? ?? true);
      for (final row in membershipsOf(c)) {
        final key = courseKey(row);
        final mid = '${row['module_id']}';
        matchedRecordByPlanId.putIfAbsent(key, () => r);
        if (!credited) {
          // 在修未出分 / 已修未过 / 弃修待录缓考无效：已选但未获学分
          // （多标签课程每个所属模块都计：selected_no_credit 同步双计）
          selectedNoCreditIds.add(key);
        }
        if (isPassed(r)) passedIds.add(key);
        // 同一门课重修多次只计一次学分（(课, 模块) 由首条通过记录认领）；
        // 多标签课程在每个所属模块分别计学分（多重计分，培养方案口径）；
        // credit_included=false（弃修/待录/缓考/无效）不计入已取得学分，
        // 但仍视为已通过，避免重复出现在待修。
        if (isPassed(r) && earnedClaimed.add('$key|$mid') && credited) {
          earned[row['module_id'] as String] =
              earned[row['module_id'] as String]! + (row['credits'] as num).toDouble();
          earnedCids.add(key);
        }
      }
    }

    final byId = <String, Map<String, dynamic>>{};
    for (final c in (plan['courses'] as List).cast<Map<String, dynamic>>()) {
      // 空课号不是有效键（认定类合成行/教务导出空串）：放进 byId 会让先修
      // 检查与计划选课按 '' 串到同一门课。
      final cid = c['course_id'];
      if (cid is String && cid.trim().isNotEmpty) byId[cid] = c;
    }

    // 计划选课（已选未出分）：计入选课组口径的“已选未获学分”。
    // 键口径（v1.5.1 #7）：course_id 为空时用课程名兜底——外语板块无课程表时
    // 已选行常见只有名字（教务 zzxk 行无课号），两侧键必须同源才数得上。
    final planCourses =
        (record['planned_courses'] as List? ?? []).cast<Map<String, dynamic>>();
    for (final x in planCourses) {
      final cid = '${x['course_id'] ?? ''}'.trim();
      final nm = '${x['name'] ?? ''}'.trim();
      if (cid.isNotEmpty) {
        selectedNoCreditIds.add(cid);
      } else if (nm.isNotEmpty) {
        // 与 courseKey 同源：空课号行统一用 'n|课名' 键。
        selectedNoCreditIds.add('n|$nm');
      }
    }

    // ── 在修证据（v1.5 三态打通，用户 #4/#9）──────────────────────────────
    // 「在修未出分」= 已列入计划选课（planned_courses，main.dart 已按教务已选
    // 回填）或调用方显式传入的 uiActiveNames（UI 侧本学期已选/课表证据；
    // 不传时仅用 record 内证据，引擎自足，main.dart 无需改调用点）。
    // 仅用于警告降级与 missing_courses 标记，绝不抵扣 earned / gap / totals
    //（在修不计已修是既有红线）。
    final activeIds = <String>{}; // 方案课程号口径
    final activeNames = <String>{}; // 课程名口径
    void addActive(Object? id, Object? name) {
      final i = '$id'.trim();
      if (id != null && i.isNotEmpty && i != 'null') activeIds.add(i);
      final n = '${name ?? ''}'.trim();
      if (n.isNotEmpty) activeNames.add(n);
    }

    for (final x in planCourses) {
      addActive(x['course_id'], x['name']);
    }
    for (final n in uiActiveNames ?? const <String>{}) {
      final t = n.trim();
      if (t.isNotEmpty) activeNames.add(t);
    }
    final activeNameList = activeNames.toList();
    // 与审计匹配同口径：精确名命中，或 difflib 风格相似度 ≥0.85 兜底。
    bool isActiveCourse(Map<String, dynamic> c) {
      final cid = '${c['course_id'] ?? ''}'.trim();
      if (cid.isNotEmpty && activeIds.contains(cid)) return true;
      final nm = '${c['name'] ?? ''}'.trim();
      if (nm.isEmpty || activeNameList.isEmpty) return false;
      if (activeNames.contains(nm)) return true;
      return bestVariantAwareMatch(nm, activeNameList) != null;
    }

    // 模块课程一次取齐（保持 plan['courses'] 原序）：剩余/明细/组口径共用
    final coursesByModule = <String, List<Map<String, dynamic>>>{};
    for (final c in (plan['courses'] as List).cast<Map<String, dynamic>>()) {
      coursesByModule.putIfAbsent('${c['module_id']}', () => []).add(c);
    }

    final curIdx = Timeline.semIdx(record['student']['current_semester'] as String);
    final gradeYear = int.parse(record['student']['grade'] as String);
    final gradIdx = gradeYear * Timeline.semestersPerGradeYear +
        graduationYears * Timeline.semestersPerGradeYear - 1;
    const horizon = graduationYears + 1;

    List<int> futureIdx(Map<String, dynamic> c) =>
        Timeline.courseOpenIdx(c, gradeYear, horizon)
            .where((i) => curIdx < i && i <= gradIdx)
            .toList();

    final summary = <Map<String, dynamic>>[];
    final warnings = <Map<String, dynamic>>[];
    var groupApplied = false; // 是否有模块的组口径折算实际生效（供 caliber_notes）
    // 每模块缺口类警告（graduation_risk / offering_closed）在 warnings 中的
    // 起始下标；并列选项组合成后据此清除落选选项的警告（v1.5）。
    final moduleWarnStart = <String, int>{};
    final moduleWarnEnd = <String, int>{};

    for (final m in planModules) {
      final mid = m['module_id'] as String;
      final moduleCourses = coursesByModule[mid] ?? const [];
      final groupRule = detectModuleGroupRule(m);
      final req0 = (m['required_credits'] as num).toDouble();
      var req = effectiveRequiredCredits(m, moduleCourses, rule: groupRule);
      if ((req - req0).abs() > 1e-9) groupApplied = true;
      // 外语口径：仅外语类模块。自选学分=用户指定的模块要求（可升可降）；
      // level 档位 2026 级起强制新规值（可升可降），此前仍只降不升。
      if (foreignCap != null && isForeignLangModule(m)) {
        if (foreignCredits != null) {
          req = foreignCredits;
        } else if (foreignNewRule) {
          req = foreignCap;
        } else if (foreignCap < req) {
          req = foreignCap;
        }
      }
      final got = double.parse(earned[mid]!.toStringAsFixed(2));
      final minCourses = groupRule?.minCourses;
      final passedInGroup = <String>{};
      if (minCourses != null) {
        for (final c in moduleCourses) {
          final key = courseKey(c);
          if (passedIds.contains(key)) passedInGroup.add(key);
        }
      }
      // #3：多选一/任选其一——选够门数即整组达成，允许已获学分少于标注
      // （标注是整组上限，不是必须全修）。
      final singlePickSatisfied = groupRule?.singlePick == true &&
          minCourses != null &&
          passedInGroup.length >= minCourses;
      final gap = singlePickSatisfied
          ? 0.0
          : double.parse(
              (req - got).clamp(0.0, double.infinity).toStringAsFixed(2));
      // 剩余可选 = 未通过课程；同一模块内同课号（无号则同名）重复行只计一次
      final remaining = <Map<String, dynamic>>[];
      final seenRemainingIds = <String>{};
      for (final c in moduleCourses) {
        final key = courseKey(c);
        if (passedIds.contains(key)) continue;
        if (!seenRemainingIds.add(key)) continue;
        remaining.add(c);
      }
      var openBeforeGrad = 0.0;
      for (final c in remaining) {
        if (futureIdx(c).isNotEmpty) openBeforeGrad += (c['credits'] as num).toDouble();
      }
      openBeforeGrad = double.parse(openBeforeGrad.toStringAsFixed(2));
      // 选课组门数校验：学分够但通过门数不足（重课覆盖多门轻课要求的罕见失配）
      // 不得判绿——此时 gap 可能为 0，颜色仍按待补呈现。
      final countShort =
          minCourses != null && passedInGroup.length < minCourses;
      // 无课程表的模块（第二/三/四课堂、认定类清单）：没有「未来可选学分」
      // 概念，缺口一律按待补（黄）呈现，绝不判红/延毕（用户 #9）。
      final noSchedule = isPracticeModule(m) || isCertifiedModule(m);
      final color = (gap <= 1e-9 && !countShort)
          ? 'green'
          : noSchedule
              ? 'yellow'
              : (gap <= openBeforeGrad + 1e-9 ? 'yellow' : 'red');
      final status = color == 'green'
          ? '🟢 已达成'
          : color == 'yellow'
              ? '🟡 待补'
              : '🔴 学籍年限内无法补足';

      // 在修覆盖（v1.5，用户 #4/#9）：剩余课程里「已列入计划选课（在修未出分）」
      // 的部分。只降级警告措辞，不抵扣 gap/earned（既有红线：在修不算已获）。
      final remainingActive =
          remaining.where(isActiveCourse).toList(); // 未通过的在修课（可补学分）
      final activeCredit = double.parse(remainingActive
          .fold<num>(0, (s, c) => s + (c['credits'] as num))
          .toStringAsFixed(2));
      final hasActive = gap > 0 && remainingActive.isNotEmpty;

      final missing = <Map<String, dynamic>>[];
      if (gap > 0) {
        final sorted = [...remaining]..sort(
            (a, b) => (b['credits'] as num).compareTo(a['credits'] as num));
        for (final c in sorted) {
          final fi = futureIdx(c);
          final src = (c['source'] as Map<String, dynamic>?);
          missing.add({
            'course_id': c['course_id'],
            'name': c['name'],
            'credits': c['credits'],
            'offered': c['offered'],
            'offered_years': c['offered_years'],
            'terms': fi.map(Timeline.idxStr).toList(),
            'closed': fi.isEmpty,
            // 在修标记（v1.5）：已选未出分的课不再当作普通缺口，UI 据此
            // 呈现「在修」三态；credits 合计口径不变。
            'active': isActiveCourse(c),
            'page': src?['page'],
          });
        }
      }
      // 方案课程全量明细：展开卡片时展示“培养方案详细要求”，不再只有
      // gap=0 时的「学分已满足」。missing_courses 保留以兼容旧消费者。
      final planCoursesOfModule = <Map<String, dynamic>>[];
      final seenPlanCourseIds = <String>{};
      for (final c in moduleCourses) {
        final key = courseKey(c);
        if (!seenPlanCourseIds.add(key)) continue;
        final fi = futureIdx(c);
        final record = matchedRecordByPlanId[key];
        final src = c['source'];
        planCoursesOfModule.add(<String, dynamic>{
          'course_id': c['course_id'],
          'name': c['name'],
          'credits': c['credits'],
          'offered': c['offered'],
          'offered_years': c['offered_years'],
          'terms': fi.map(Timeline.idxStr).toList(),
          'closed': fi.isEmpty,
          'passed': passedIds.contains(key),
          // 多标签课程标记（v1.4）：该课在方案中归属多个模块，学分按各模块
          // 分别计（UI 可据此注明「此课学分已同时计入其归属的另一模块」）。
          if (planRowIsMultiTag(c)) 'multi_tag': true,
          if (record != null)
            'record': <String, dynamic>{
              'semester': record['semester'],
              'grade': record['grade'],
            },
          'page': src is Map ? src['page'] : null,
        });
      }
      // 方案外已选外语课（用户反馈 #9）：外语模块常见「方案只写应修学分、
      // 不给课程表」，已选外语课不在 moduleCourses 里，导致三色明细看不到。
      // 这里按课名把计划选课/已选行补进外语模块（planned_only=true），
      // 只进 selected_no_credit（在修），不改 earned / gap 口径。
      if (isForeignLangModule(m)) {
        for (final p in planCourses) {
          final pid = '${p['course_id'] ?? ''}'.trim();
          final pname = '${p['name'] ?? ''}'.trim();
          final key = pid.isNotEmpty ? pid : pname;
          if (key.isEmpty) continue;
          final already = moduleCourses.any((c) =>
              '${c['course_id'] ?? ''}'.trim() == pid ||
              ('${c['name'] ?? ''}'.trim() == pname && pname.isNotEmpty));
          if (already) continue;
          if (!(pname.contains('外语') || pname.contains('英语'))) continue;
          if (!seenPlanCourseIds.add(key)) continue;
          planCoursesOfModule.add(<String, dynamic>{
            'course_id': pid.isEmpty ? null : pid,
            'name': pname,
            'credits': p['credits'],
            'offered': null,
            'offered_years': null,
            'terms': const <String>[],
            'closed': false,
            'passed': false,
            'planned_only': true,
            'page': null,
          });
        }
      }

      // 已选未获学分课程数：方案课程里「已修未取得学分（未通过/在修未出分/
      final selectedNoCredit = planCoursesOfModule
          .where((c) {
            final k = courseKey(c);
            return k.isNotEmpty &&
                !earnedCids.contains(k) &&
                selectedNoCreditIds.contains(k);
          })
          .length;
      final planCourseStats = <String, int>{
        'total': planCoursesOfModule.length,
        'passed': planCoursesOfModule.where((c) => c['passed'] == true).length,
        'pending': planCoursesOfModule.where((c) => c['passed'] != true).length,
        'closed': planCoursesOfModule.where((c) => c['closed'] == true).length,
      };
      summary.add({
        'module_id': mid,
        'module_path': m['module_path'],
        'title': m['title'],
        'level': m['level'],
        'category': m['category'],
        'plan_credits_raw': m['plan_credits_raw'],
        'plan_credits_unit': m['plan_credits_unit'],
        'notes': m['notes'] ?? const [],
        if (m.containsKey('choice_rule')) 'choice_rule': m['choice_rule'],
        if (m.containsKey('alternative')) 'alternative': m['alternative'],
        if (m.containsKey('certified_category'))
          'certified_category': m['certified_category'],
        if (m.containsKey('sub_requirements'))
          'sub_requirements': m['sub_requirements'],
        'required': req,
        'earned': got,
        'selected_no_credit': selectedNoCredit,
        'gap': gap,
        'remaining_future': openBeforeGrad,
        'color': color,
        'status': status,
        'plan_courses': planCoursesOfModule,
        'course_stats': planCourseStats,
        'missing_courses': missing,
      });

      String refOf(Map<String, dynamic> c) =>
          '${c['course_id']}@p${(c['source'] as Map<String, dynamic>?)?['page']}';

      moduleWarnStart[mid] ??= warnings.length;
      if (noSchedule && gap > 0) {
        // 课堂/认定类：只给信息提示，不按排课窗口/重修口径报延毕（#9）。
        warnings.add({
          'type': 'graduation_risk',
          'level': 'yellow',
          'text': isPracticeModule(m)
              ? '「${m['module_path']}」素质拓展记点认定，无课程表可排课；'
                  '请在素质拓展平台完成并提交认定，当前缺口 ${_g(gap)} 分。'
              : '「${m['module_path']}」按认定类课程清单认定，无固定开课窗口；'
                  '请按本科生院清单修读并提交认定，当前缺口 ${_g(gap)} 分。',
          'refs': const <String>[],
        });
      } else if (color == 'red' && gap > 0) {
        final closed = remaining.where((c) => futureIdx(c).isEmpty).toList();
        final open = remaining.where((c) => futureIdx(c).isNotEmpty).toList();
        final closedCredit =
            double.parse(closed.fold<num>(0, (s, c) => s + (c['credits'] as num)).toStringAsFixed(2));
        final detail = closed
            .take(3)
            .map((c) => '《${c['name']}》${_g(c['credits'])}分')
            .join('、');
        final cause = closed.isNotEmpty && closedCredit >= gap
            ? '方案内该模块剩余课程在学籍年限内已无开课窗口：$detail'
            : '即使重修补上（可补 ${_g(double.parse(open.fold<num>(0, (s, c) => s + (c['credits'] as num)).toStringAsFixed(2)))} 分），缺口 ${_g(gap)} 分仍超出未来可选学分';
        // 在修全额覆盖缺口 → 降级 yellow（延毕红警不再按「未修」口径报）；
        // 部分覆盖 → 仍 red 但文案给出「已选 N 学分（在修），仍缺 …」。
        final fullyCovered = hasActive && activeCredit >= gap - 1e-9;
        warnings.add({
          'type': 'graduation_risk',
          'level': fullyCovered ? 'yellow' : 'red',
          'text': fullyCovered
              ? '「${m['module_path']}」缺口 ${_g(gap)} 分（已在修，待出成绩）：'
                  '已选 ${remainingActive.length} 门 ${_g(activeCredit)} 学分，'
                  '出分即达成，暂无延毕风险。'
              : hasActive
                  ? '「${m['module_path']}」缺口 ${_g(gap)} 分，已选 ${remainingActive.length} 门'
                      ' ${_g(activeCredit)} 学分（在修，待出成绩），'
                      '仍缺 ${_g(double.parse((gap - activeCredit).clamp(0.0, double.infinity).toStringAsFixed(2)))} 分：'
                      '$cause。存在延毕风险，请尽快与教务确认替代方案。'
                  : '「${m['module_path']}」缺口 ${_g(gap)} 分，$cause。'
                      '存在延毕风险，请尽快与教务确认替代方案。',
          'refs': closed.take(3).map(refOf).toList(),
        });
      } else if (color == 'yellow' && gap > 0) {
        final tight = remaining.where((c) {
          if (futureIdx(c).isEmpty) return false;
          final cyc = c['offered_years'];
          final off = offeredOf(c);
          return cyc != null || off.length == 1;
        }).toList();
        tight.sort((a, b) {
          final la = futureIdx(a).length, lb = futureIdx(b).length;
          if (la != lb) return la.compareTo(lb);
          return (b['credits'] as num).compareTo(a['credits'] as num);
        });
        for (final c in tight.take(2)) {
          final cyc = c['offered_years'];
          final why = cyc != null
              ? '（隔年开课，仅 ${(cyc as List).join('、')} 学年）'
              : '（仅${offeredOf(c).first}开课）';
          final takenFailed = matched.any((pair) =>
              pair[1]['course_id'] == c['course_id'] && !isPassed(pair[0] as Map<String, dynamic>));
          final verb = takenFailed
              ? '已修未过需重修'
              : isActiveCourse(c)
                  ? '已在修，待出成绩' // v1.5：不再把在修课报成「尚未修」
                  : '尚未修';
          warnings.add({
            'type': 'offering_closed',
            'level': 'yellow',
            'text': '「${c['name']}」${_g(c['credits'])}分$verb，$why，可选窗口：'
                '${futureIdx(c).map(Timeline.idxStr).join('、')}；错过需等待。',
            'refs': [refOf(c)],
          });
        }
      }
      moduleWarnEnd[mid] = warnings.length;
    }

    // 先修检查（已修侧）
    for (final pair in matched) {
      final r = pair[0] as Map<String, dynamic>, c = pair[1] as Map<String, dynamic>;
      if (!isPassed(r)) continue;
      for (final p in (c['prereq'] as List? ?? [])) {
        if (passedIds.contains(p)) continue;
        final pc = byId[p];
        if (pc == null) continue;
        warnings.add({
          'type': 'prereq_gap',
          'level': 'red',
          'text': '「${c['name']}」已通过，但其先修「${pc['name']}」在记录中未通过（或缺失），选课资格存疑，请与教务核实。',
          'refs': [
            '${c['course_id']}@p${(c['source'] as Map?)?['page']}',
            '${pc['course_id']}@p${(pc['source'] as Map?)?['page']}',
          ],
        });
      }
    }

    // 计划选课表内部（planCourses 已在上方取齐，计入选课组「已选未获学分」口径）
    final semOfPlan = <String, List<int>>{};
    for (final x in planCourses) {
      final cid = x['course_id'];
      if (cid == null) continue;
      semOfPlan.putIfAbsent(cid as String, () => []).add(
          Timeline.semIdx((x['semester'] ?? record['student']['current_semester']) as String));
    }
    for (final x in planCourses) {
      final c = byId[x['course_id']];
      if (c == null) continue;
      final xi = semOfPlan[c['course_id']]!.first;
      final term = xi % 2 == 0 ? '秋' : '春';
      final ref = '${c['course_id']}@p${(c['source'] as Map?)?['page']}';
      final offered = offeredOf(c);
      // offered 为空 = 方案未标注开课学期（认定类合成课程），无从判断，不告警
      if (offered.isNotEmpty && !offered.contains(term)) {
        warnings.add({
          'type': 'offering_closed',
          'level': 'yellow',
          'text': '计划选课「${c['name']}」排在 ${Timeline.idxStr(xi)}，但培养方案标注仅'
              '${offered.join('/')}开课，需调整学期。',
          'refs': [ref],
        });
      } else if (c['offered_years'] != null &&
          !(c['offered_years'] as List).contains(xi ~/ 2)) {
        warnings.add({
          'type': 'offering_closed',
          'level': 'yellow',
          'text': '计划选课「${c['name']}」排在 ${Timeline.idxStr(xi)}，但该课隔年开课（仅 '
              '${(c['offered_years'] as List).join('、')} 学年），本学期不开，需等到对应学年。',
          'refs': [ref],
        });
      }
      for (final p in (c['prereq'] as List? ?? [])) {
        if (passedIds.contains(p)) continue;
        final pk = semOfPlan[p];
        final pc = byId[p];
        if (pk != null && pk.reduce((a, b) => a < b ? a : b) >= xi && pc != null) {
          warnings.add({
            'type': 'prereq_same_semester',
            'level': 'red',
            'text': '计划选课「${c['name']}」需先修「${pc['name']}」，但先修排在同一学期或更晚'
                '（${Timeline.idxStr(pk.reduce((a, b) => a < b ? a : b))} vs ${Timeline.idxStr(xi)}），会选不上，需拆开两学期。',
            'refs': [
              ref,
              '${pc['course_id']}@p${(pc['source'] as Map?)?['page']}',
            ],
          });
        }
      }
    }
    // ── 并列选项组（用户反馈 #4）：组内任选其一，只计一次 ──────────────────
    // PlanFile.alternative_groups 由 plan_audit_adapter 生成：每个选项子树
    // 的模块都在 modules 里（明细可展开），但只有「最优选项」进入组行与总计。
    final altGroupsRaw = plan['alternative_groups'];
    final altApplied = altGroupsRaw is List && altGroupsRaw.isNotEmpty;
    var displaySummary = summary;
    if (altApplied) {
      final byId = <String, Map<String, dynamic>>{
        for (final r in summary) '${r['module_id']}': r,
      };
      final groupRows = <Map<String, dynamic>>[];
      final optionIds = <String>{};
      // v1.5（A2）：落选选项模块警告的 warnings 下标集与组级风险新警告。
      final pruneWarnIdx = <int>{};
      final groupWarnings = <Map<String, dynamic>>[];
      for (final raw in altGroupsRaw) {
        if (raw is! Map) continue;
        final opts = raw['options'];
        if (opts is! List) continue;
        final rows = <Map<String, dynamic>>[];
        for (final o in opts) {
          if (o is! Map) continue;
          final ids = <String>[
            for (final e in (o['module_ids'] as List? ?? const [])) '$e',
          ];
          final mods = <Map<String, dynamic>>[
            for (final id in ids)
              if (byId[id] != null) byId[id]!,
          ];
          if (mods.isEmpty) continue;
          optionIds.addAll(mods.map((r) => '${r['module_id']}'));
          double sumOf(String key) => mods.fold<double>(
              0, (a, r) => a + ((r[key] as num?)?.toDouble() ?? 0));
          final req = sumOf('required');
          final got = sumOf('earned');
          final rem = sumOf('remaining_future');
          final gap = double.parse(
              (req - got).clamp(0.0, double.infinity).toStringAsFixed(2));
          rows.add(<String, dynamic>{
            'title': '${o['title'] ?? ''}',
            'module_ids': ids,
            'required': req,
            'earned': got,
            'gap': gap,
            'remaining_future': rem,
            'color': gap <= 1e-9
                ? 'green'
                : (gap <= rem + 1e-9 ? 'yellow' : 'red'),
          });
        }
        if (rows.isEmpty) continue;
        rows.sort((a, b) {
          final c = (a['gap'] as num).compareTo(b['gap'] as num);
          if (c != 0) return c;
          final d = (b['earned'] as num).compareTo(a['earned'] as num);
          if (d != 0) return d;
          return (a['required'] as num).compareTo(b['required'] as num);
        });
        final best = rows.first;
        final bestRows = <Map<String, dynamic>>[
          for (final id in (best['module_ids'] as List))
            if (byId['$id'] != null) byId['$id']!,
        ];
        final groupReq = (raw['required_credits'] as num?)?.toDouble() ?? 0;
        final req =
            groupReq > 0 ? groupReq : (best['required'] as num).toDouble();
        final got = (best['earned'] as num).toDouble();
        final rem = (best['remaining_future'] as num).toDouble();
        final gap = double.parse(
            (req - got).clamp(0.0, double.infinity).toStringAsFixed(2));
        final color = gap <= 1e-9
            ? 'green'
            : (gap <= rem + 1e-9 ? 'yellow' : 'red');
        final stats = <String, int>{};
        for (final r in bestRows) {
          final st = r['course_stats'];
          if (st is Map) {
            for (final e in st.entries) {
              final k = '${e.key}';
              stats[k] = (stats[k] ?? 0) + ((e.value as num?)?.toInt() ?? 0);
            }
          }
        }
        groupRows.add(<String, dynamic>{
          'module_id': '${raw['group_id']}',
          'module_path': raw['path'],
          'title': raw['title'],
          'level': 2,
          'category': raw['title'],
          'notes': const <String>[],
          'alternative_group': true,
          'option_count': rows.length,
          'options': rows,
          'required': req,
          'earned': got,
          'selected_no_credit': bestRows.fold<int>(
              0, (a, r) => a + ((r['selected_no_credit'] as num?)?.toInt() ?? 0)),
          'gap': gap,
          'remaining_future': rem,
          'color': color,
          'status': color == 'green'
              ? '🟢 已达成'
              : color == 'yellow'
                  ? '🟡 待补'
                  : '🔴 学籍年限内无法补足',
          'plan_courses': <Map<String, dynamic>>[
            for (final r in bestRows)
              ...((r['plan_courses'] as List? ?? const [])
                  .cast<Map<String, dynamic>>()),
          ],
          'course_stats': stats,
          'missing_courses': <Map<String, dynamic>>[
            for (final r in bestRows)
              ...((r['missing_courses'] as List? ?? const [])
                  .cast<Map<String, dynamic>>()),
          ],
        });
        // v1.5（A2）：组内各选项模块在上方按「三份都要求」各自生成过缺口警告
        //（本专业进阶/跨专业学习/自主修读 ×3 红警）。组行达成度只认最优选项，
        // 故清除全部选项模块的缺口类警告，仅在组行仍红时报一条组级风险。
        for (final id in optionIds) {
          final s = moduleWarnStart[id];
          final e = moduleWarnEnd[id];
          if (s != null && e != null) {
            for (var i = s; i < e; i++) {
              pruneWarnIdx.add(i);
            }
          }
        }
        if (color == 'red' && gap > 0) {
          final groupMissing = <Map<String, dynamic>>[
            for (final r in bestRows)
              ...((r['missing_courses'] as List? ?? const [])
                  .cast<Map<String, dynamic>>()),
          ];
          double cred(Map<String, dynamic> c) =>
              ((c['credits'] as num?) ?? 0).toDouble();
          final closed = groupMissing.where((c) => c['closed'] == true).toList();
          final open = groupMissing.where((c) => c['closed'] != true).toList();
          final closedCredit =
              double.parse(closed.fold<double>(0, (s, c) => s + cred(c)).toStringAsFixed(2));
          final detail = closed
              .take(3)
              .map((c) => '《${c['name']}》${_g(cred(c))}分')
              .join('、');
          final cause = closed.isNotEmpty && closedCredit >= gap
              ? '方案内该组剩余课程在学籍年限内已无开课窗口：$detail'
              : '即使重修补上（可补 ${_g(double.parse(open.fold<double>(0, (s, c) => s + cred(c)).toStringAsFixed(2)))} 分），缺口 ${_g(gap)} 分仍超出未来可选学分';
          final actives = groupMissing.where((c) => c['active'] == true).toList();
          final activeCredit = double.parse(
              actives.fold<double>(0, (s, c) => s + cred(c)).toStringAsFixed(2));
          final fullyCovered = actives.isNotEmpty && activeCredit >= gap - 1e-9;
          groupWarnings.add({
            'type': 'graduation_risk',
            'level': fullyCovered ? 'yellow' : 'red',
            'text': fullyCovered
                ? '「${raw['path']}」缺口 ${_g(gap)} 分（已在修，待出成绩）：'
                    '已选 ${actives.length} 门 ${_g(activeCredit)} 学分，'
                    '出分即达成，暂无延毕风险。'
                : actives.isNotEmpty
                    ? '「${raw['path']}」缺口 ${_g(gap)} 分，已选 ${actives.length} 门'
                        ' ${_g(activeCredit)} 学分（在修，待出成绩），'
                        '仍缺 ${_g(double.parse((gap - activeCredit).clamp(0.0, double.infinity).toStringAsFixed(2)))} 分：'
                        '$cause。存在延毕风险，请尽快与教务确认替代方案。'
                    : '「${raw['path']}」缺口 ${_g(gap)} 分，$cause。'
                        '存在延毕风险，请尽快与教务确认替代方案。',
            'refs': closed
                .take(3)
                .map((c) => '${c['course_id']}@p${c['page']}')
                .toList(),
          });
        }
      }
      // v1.5：落选（含非最优）选项模块的旧缺口警告在此统一剔除（组行只按
      // 最优选项报一条），「三选一缺口 ×3」不再重复。剔除下标只覆盖模块循环
      // 段（pruneWarnIdx），循环后新增的警告（先修/计划/冲突等）不受影响。
      if (pruneWarnIdx.isNotEmpty) {
        final kept = <Map<String, dynamic>>[];
        for (var i = 0; i < warnings.length; i++) {
          if (!pruneWarnIdx.contains(i)) kept.add(warnings[i]);
        }
        warnings
          ..clear()
          ..addAll(kept);
      }
      warnings.addAll(groupWarnings);

      // 组行插到首个选项的位置；选项模块行不再单独展示，避免「20+20+20」。
      final firstIndex = <String, int>{};
      for (final g in groupRows) {
        final ids = <String>{
          for (final o in (g['options'] as List))
            ...(o['module_ids'] as List).cast<String>(),
        };
        var idx = summary.length;
        for (var i = 0; i < summary.length; i++) {
          if (ids.contains('${summary[i]['module_id']}')) {
            idx = i;
            break;
          }
        }
        firstIndex['${g['module_id']}'] = idx;
      }
      final byFirst = <int, List<Map<String, dynamic>>>{};
      for (final g in groupRows) {
        byFirst
            .putIfAbsent(firstIndex['${g['module_id']}']!, () => [])
            .add(g);
      }
      final out = <Map<String, dynamic>>[];
      for (var i = 0; i <= summary.length; i++) {
        if (byFirst[i] != null) out.addAll(byFirst[i]!);
        if (i == summary.length) break;
        if (optionIds.contains('${summary[i]['module_id']}')) continue;
        out.add(summary[i]);
      }
      displaySummary = out;
    }

    final sems = planCourses.map((x) => x['semester']).where((s) => s != null).toSet();
    for (final semester in sems) {
      final group = planCourses.where((x) => x['semester'] == semester).toList();
      for (final cf in Timeline.checkPlan(group)) {
        warnings.add({
          'type': 'time_conflict',
          'level': 'red',
          'text': '$semester 计划课表冲突：${cf['a']} 与 ${cf['b']} ${cf['detail']}。',
          'refs': [],
        });
      }
    }

    // 未通过课程重修提醒
    for (final r in recordCourses) {
      if (r['grade'] != null && !isPassed(r)) {
        warnings.add({
          'type': 'failed_recheck',
          'level': 'yellow',
          'text': '《${r['name']}》成绩 ${_g(r['grade'])} 未通过，需重修或补考，该课程学分未计入。',
          'refs': [],
        });
      }
    }
    if (unmatched.isNotEmpty) {
      warnings.add({
        'type': 'unmatched_courses',
        'level': 'info',
        'text': '以下 ${unmatched.length} 门课程未在培养方案中匹配到，未计入模块学分'
            '（多为超修任选或名称差异过大，请人工核对）：'
            '${unmatched.take(5).map((u) => u['name']).join('、')}。',
        'refs': [],
      });
    }

    // 总学分口径（v1.6）：毕业总要求以方案声明 meta.total_credits（最低毕业
    // 学分）为准；素质拓展第二/三/四课堂属于方案总学分之外的额外毕业要求
    // （真实方案原文「148.5+8」），按方案声明时单独加回，避免模块求和把
    // 并列选项/微辅修重复计入（用户 #8）。模块求和只在方案未声明时回落。
    final planTotalRaw = (plan['meta'] as Map?)?['total_credits'];
    final planTotalCredits = planTotalRaw is num ? planTotalRaw.toDouble() : null;
    final moduleRequired = double.parse(
        displaySummary.fold<num>(0, (s, m) => s + m['required'])
            .toStringAsFixed(2));
    final practiceRequired = double.parse(displaySummary
        .where(isPracticeModule)
        .fold<num>(0, (s, m) => s + m['required'])
        .toStringAsFixed(2));
    final earnedTotal = double.parse(
        displaySummary.fold<num>(0, (s, m) => s + m['earned'])
            .toStringAsFixed(2));
    final requiredTotal = planTotalCredits != null
        ? double.parse((planTotalCredits + practiceRequired).toStringAsFixed(2))
        : moduleRequired;
    // 已选未获（诉求 #4）：与 earned 分开呈现，绝不并入已取得，也不抵扣 gap。
    final selectedNoCreditTotal = displaySummary.fold<int>(
        0, (s, m) => s + ((m['selected_no_credit'] as num?)?.toInt() ?? 0));
    final totals = {
      'required': requiredTotal,
      'earned': earnedTotal,
      'gap': double.parse(
          (requiredTotal - earnedTotal).clamp(0.0, double.infinity)
              .toStringAsFixed(2)),
      'selected_no_credit': selectedNoCreditTotal,
      'module_required': moduleRequired,
      if (planTotalCredits != null)
        'plan_total_credits': planTotalCredits, // 方案声明「最低毕业学分」原值
      if (planTotalCredits != null) 'extra_practice_credits': practiceRequired,
      'total_basis':
          planTotalCredits != null ? 'plan_declared' : 'module_sum_fallback',
    };

    // 口径说明（供 UI 用不同颜色注释；固定三条 + 按方案内容追加的组/外语口径）
    final caliberNotes = <String>[
      kCaliberEarnedNote,
      kCaliberSelectedNote,
      kCaliberMultiTagNote,
      if (groupApplied)
        '选课组口径：模块内「四选一/选N门/至少修读N门」类组按「至少 N 门」'
            '折算要求学分（组内其余课程为可选项，不再全部求和），任过 N 门即达成。',
      if (altApplied)
        '并列模块口径：本专业进阶 / 跨专业学习（微辅修）/ 学生自主修读等'
            '「任选其一」的模块按一个选项计一次要求学分，组内其他选项不报缺口。',
      if (planHasForeign)
        '外语口径：外语类模块要求学分可自选（审计动作 foreign_lang_credits 正数，'
            '可超过方案原要求；或 foreign_lang_level 档位：2026 级起 L1=6 分、'
            'L2=4.5 分（必修大学英语IV）、L3=0 分免修，2026 级前 L1=6 / L2=4.5 / '
            'L3=3 且只降不升）；未选择时按方案原要求核算。',
    ];
    final traceNotes = <String>[
      if (foreignCap != null && planHasForeign)
        foreignCredits != null
            ? '外语要求学分自选 ${_g(foreignCredits)} 分：外语类模块要求学分'
                '按 ${_g(foreignCap)} 分核算。'
            : foreignNewRule
                ? '外语等级 $foreignLevelRaw（${gradeYearForRule} 级新规）→ 外语类'
                    '模块要求学分按 ${_g(foreignCap)} 分核算'
                    '${foreignCap == 0 ? '（免修，无需修读$kForeignRequiredCourse）' : '，必修$kForeignRequiredCourse'}。'
                : '外语等级 $foreignLevelRaw → 自选 ${_g(foreignCap)} 分：外语类模块'
                    '要求学分按 ${_g(foreignCap)} 分封顶。',
      if (foreignCap != null && !planHasForeign)
        foreignCredits != null
            ? '未在方案中识别外语类模块，foreign_lang_credits=$foreignCreditsRaw 未生效。'
            : '未在方案中识别外语类模块，foreign_lang_level=$foreignLevelRaw 未生效。',
      if (foreignCap == null && planHasForeign)
        '外语等级未选择，外语类模块按方案原要求核算。',
      // 总学分口径（v1.6）：方案声明 + 素质拓展课堂额外学分；未声明则模块求和。
      if (planTotalCredits != null)
        '总计学分口径：方案声明最低毕业学分 ${_g(planTotalCredits)} 分'
            '${practiceRequired > 0 ? ' + 素质拓展课堂 ${_g(practiceRequired)} 分' : ''}'
            ' = 应修 ${_g(totals['required'])} 分（各模块要求之和为 '
            '${_g(totals['module_required'])} 分，含三选一/微辅修等重复口径，'
            '毕业总要求以方案声明为准）。',
      if (planTotalCredits == null)
        '总计学分口径：方案未声明总学分（meta.total_credits 缺失），'
            '按各模块要求学分之和 ${_g(totals['required'])} 分回落计算。',
      // 多重计分（v1.4）：方案确有多标签课程时说明双计口径
      if (multiTagCourseCount > 0)
        '多重计分：方案中 $multiTagCourseCount 门课程同时归属多个模块，'
            '其学分按各所属模块分别计入（earned 与 selected_no_credit 同口径）。',
    ];

    return {
      'summary': displaySummary,
      'warnings': warnings,
      'extra_courses': unmatched,
      'totals': totals,
      if (foreignLevelRaw != null)
        'foreign_rule': {
          'level': '$foreignLevelRaw',
          'required_credits': foreignCap,
          'new_rule': foreignNewRule,
          'required_course': (foreignNewRule && (foreignCap ?? 0) > 0)
              ? kForeignRequiredCourse
              : null,
          'exempt': foreignNewRule && (foreignCap ?? 0) == 0,
        },
      'caliber_notes': caliberNotes,
      'disclaimer': kDisclaimer,
      'trace': {
        'plan': '${plan['meta']['source_doc']}'
            '${(plan['meta']['grade'] ?? '').toString().isEmpty ? '' : ' ${plan['meta']['grade']}级'}'
            '（核验日 ${plan['meta']['verified_at'] ?? '-'}）',
        'engine': 'v$engineVersion',
        'notes': traceNotes,
      },
    };
  }

  static String _g(Object? n) {
    final d = (n as num).toDouble();
    return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toString();
  }

  /// 兼容 Python 版 main() 的入口（record 为 JSON 字符串或 Map）。
  /// action 支持：
  ///  * null / 'audit'（缺省）→ 普通审计；
  ///  * Map → 审计动作参数，支持 {'foreign_lang_credits': 正数}（自选外语要求
  ///    学分，可超过方案原要求）与 {'foreign_lang_level': 'L1'|'L2'|'L3'}
  ///    （向后兼容档位，映射 caps 只降不升，见 kForeignLangCaps；
  ///    同传时 credits 优先）；
  ///    未知键忽略（向前兼容），非法值显式报错（宁缺勿猜）；
  ///  * 其它类型 → {'error': 'unknown action: ...'}（与 Python 镜像同形）。
  Map<String, dynamic> main(Object recordInput, {Object? action}) {
    Map<String, dynamic>? actionMap;
    if (action is Map) {
      actionMap = <String, dynamic>{
        for (final e in action.entries) '${e.key}': e.value,
      };
    } else if (action is String) {
      if (action != 'audit') return {'error': 'unknown action: $action'};
    } else if (action != null) {
      return {'error': 'unknown action: $action'};
    }
    final rec = recordInput is String
        ? json.decode(recordInput) as Map<String, dynamic>
        : recordInput as Map<String, dynamic>;
    try {
      final plan = findPlan(rec['student']['major'] as String);
      final report = build(rec, plan, action: actionMap);
      return {'report': report, 'report_json': json.encode(report)};
    } on ArgumentError catch (e) {
      return {'error': e.message.toString()};
    }
  }
}
