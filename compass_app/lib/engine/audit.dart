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
///    方案未声明时回落模块求和并在 trace.notes 说明。
library;

import 'dart:convert';

import 'disclaimer.dart';
import 'matching.dart';
import 'timeline.dart';

// ── 选课组与外语等级口径（纯函数，独立可测；Python 镜像按同一规则对齐）──────

/// 外语等级 → 外语类模块「要求学分」封顶值（用户 2026-10-18 明确口径：
/// L1 计 6 分、L2 计 4.5 分、L3 计 3 分；按等级封顶，绝不抬高方案原要求）。
const Map<String, double> kForeignLangCaps = <String, double>{
  'L1': 6.0,
  'L2': 4.5,
  'L3': 3.0,
};

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
  static const engineVersion = '1.4';
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
      {Map<String, dynamic>? action}) {
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
      if (v == null || !(v > 0)) {
        throw ArgumentError('非法的外语要求学分：$foreignCreditsRaw（需为正数）');
      }
      foreignCredits = v;
    }
    // 自选学分优先（=用户指定的模块要求）；level 档位向后兼容（映射 caps 作默认）
    final foreignCap = foreignCredits ??
        (foreignLevelRaw == null ? null : kForeignLangCaps['$foreignLevelRaw']!);

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
    final passedIds = <String>{};
    final earnedCids = <String>{}; // 已获学分：通过且计入学分（与 earned 累加同条件）
    final selectedNoCreditIds = <String>{}; // 已选未获学分：已修未取得学分的课程
    final earnedClaimed = <String>{}; // '课号|模块'：一门课在每个模块只计一次学分
    final matchedRecordByPlanId = <String, Map<String, dynamic>>{};
    for (final pair in matched) {
      final r = pair[0] as Map<String, dynamic>, c = pair[1] as Map<String, dynamic>;
      final credited = isPassed(r) && (r['credit_included'] as bool? ?? true);
      for (final row in membershipsOf(c)) {
        final cid = '${row['course_id']}';
        final mid = '${row['module_id']}';
        matchedRecordByPlanId.putIfAbsent(cid, () => r);
        if (!credited) {
          // 在修未出分 / 已修未过 / 弃修待录缓考无效：已选但未获学分
          // （多标签课程每个所属模块都计：selected_no_credit 同步双计）
          selectedNoCreditIds.add(cid);
        }
        if (isPassed(r)) passedIds.add(cid);
        // 同一门课重修多次只计一次学分（(课, 模块) 由首条通过记录认领）；
        // 多标签课程在每个所属模块分别计学分（多重计分，培养方案口径）；
        // credit_included=false（弃修/待录/缓考/无效）不计入已取得学分，
        // 但仍视为已通过，避免重复出现在待修。
        if (isPassed(r) && earnedClaimed.add('$cid|$mid') && credited) {
          earned[row['module_id'] as String] =
              earned[row['module_id'] as String]! + (row['credits'] as num).toDouble();
          earnedCids.add(cid);
        }
      }
    }

    final byId = <String, Map<String, dynamic>>{};
    for (final c in (plan['courses'] as List).cast<Map<String, dynamic>>()) {
      byId[c['course_id'] as String] = c;
    }

    // 计划选课（已选未出分）：计入选课组口径的“已选未获学分”
    final planCourses =
        (record['planned_courses'] as List? ?? []).cast<Map<String, dynamic>>();
    for (final x in planCourses) {
      final cid = x['course_id'];
      if (cid != null) selectedNoCreditIds.add('$cid');
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

    for (final m in planModules) {
      final mid = m['module_id'] as String;
      final moduleCourses = coursesByModule[mid] ?? const [];
      final groupRule = detectModuleGroupRule(m);
      final req0 = (m['required_credits'] as num).toDouble();
      var req = effectiveRequiredCredits(m, moduleCourses, rule: groupRule);
      if ((req - req0).abs() > 1e-9) groupApplied = true;
      // 外语口径：仅外语类模块。自选学分=用户指定的模块要求（可升可降，
      // 用户明确「可修超过要求学分」）；level 档位向后兼容旧口径只降不升
      // （缺省 → 方案原要求）。
      if (foreignCap != null && isForeignLangModule(m)) {
        if (foreignCredits != null) {
          req = foreignCredits;
        } else if (foreignCap < req) {
          req = foreignCap;
        }
      }
      final got = double.parse(earned[mid]!.toStringAsFixed(2));
      final minCourses = groupRule?.minCourses;
      final passedInGroup = <String>{};
      if (minCourses != null) {
        for (final c in moduleCourses) {
          final cid = '${c['course_id']}';
          if (passedIds.contains(cid)) passedInGroup.add(cid);
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
      // 剩余可选 = 未通过课程；同一模块内同课号重复行只计一次
      // （无课号行无法判同，不去重——宁缺勿猜）
      final remaining = <Map<String, dynamic>>[];
      final seenRemainingIds = <String>{};
      for (final c in moduleCourses) {
        final cid = '${c['course_id']}';
        if (passedIds.contains(cid)) continue;
        if (cid.isNotEmpty && !seenRemainingIds.add(cid)) continue;
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
      final color = (gap <= 1e-9 && !countShort)
          ? 'green'
          : (gap <= openBeforeGrad + 1e-9 ? 'yellow' : 'red');
      final status = color == 'green'
          ? '🟢 已达成'
          : color == 'yellow'
              ? '🟡 待补'
              : '🔴 学籍年限内无法补足';

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
            'page': src?['page'],
          });
        }
      }
      // 方案课程全量明细：展开卡片时展示“培养方案详细要求”，不再只有
      // gap=0 时的「学分已满足」。missing_courses 保留以兼容旧消费者。
      final planCoursesOfModule = <Map<String, dynamic>>[];
      final seenPlanCourseIds = <String>{};
      for (final c in moduleCourses) {
        final cid = '${c['course_id'] ?? ''}';
        if (!seenPlanCourseIds.add(cid)) continue;
        final fi = futureIdx(c);
        final record = matchedRecordByPlanId[cid];
        final src = c['source'];
        planCoursesOfModule.add(<String, dynamic>{
          'course_id': c['course_id'],
          'name': c['name'],
          'credits': c['credits'],
          'offered': c['offered'],
          'offered_years': c['offered_years'],
          'terms': fi.map(Timeline.idxStr).toList(),
          'closed': fi.isEmpty,
          'passed': passedIds.contains(cid),
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
      // 弃修待录缓考无效）或已列入计划选课」且尚未取得学分的去重门数
      final selectedNoCredit = planCoursesOfModule
          .where((c) =>
              !earnedCids.contains('${c['course_id']}') &&
              selectedNoCreditIds.contains('${c['course_id']}'))
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

      if (color == 'red' && gap > 0) {
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
        warnings.add({
          'type': 'graduation_risk',
          'level': 'red',
          'text': '「${m['module_path']}」缺口 ${_g(gap)} 分，$cause。存在延毕风险，请尽快与教务确认替代方案。',
          'refs': closed.take(3).map(refOf).toList(),
        });
      } else if (color == 'yellow' && gap > 0) {
        final tight = remaining.where((c) {
          if (futureIdx(c).isEmpty) return false;
          final cyc = c['offered_years'];
          final off = (c['offered'] as List);
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
              : '（仅${(c['offered'] as List).first}开课）';
          final takenFailed = matched.any((pair) =>
              pair[1]['course_id'] == c['course_id'] && !isPassed(pair[0] as Map<String, dynamic>));
          final verb = takenFailed ? '已修未过需重修' : '尚未修';
          warnings.add({
            'type': 'offering_closed',
            'level': 'yellow',
            'text': '「${c['name']}」${_g(c['credits'])}分$verb，$why，可选窗口：'
                '${futureIdx(c).map(Timeline.idxStr).join('、')}；错过需等待。',
            'refs': [refOf(c)],
          });
        }
      }
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
      if (!(c['offered'] as List).contains(term)) {
        warnings.add({
          'type': 'offering_closed',
          'level': 'yellow',
          'text': '计划选课「${c['name']}」排在 ${Timeline.idxStr(xi)}，但培养方案标注仅'
              '${(c['offered'] as List).join('/')}开课，需调整学期。',
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
      }
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

    // 总学分口径（v1.4）：毕业总要求以方案声明 meta.total_credits（最低毕业
    // 学分）为准，模块级要求照旧；模块求和只在方案未声明时回落（total_basis
    // 注明口径，trace.notes 同步说明）。
    final planTotalRaw = (plan['meta'] as Map?)?['total_credits'];
    final planTotalCredits = planTotalRaw is num ? planTotalRaw.toDouble() : null;
    final totals = {
      'required': double.parse(
          displaySummary.fold<num>(0, (s, m) => s + m['required'])
              .toStringAsFixed(2)),
      'earned': double.parse(
          displaySummary.fold<num>(0, (s, m) => s + m['earned'])
              .toStringAsFixed(2)),
      'gap': double.parse(
          displaySummary.fold<num>(0, (s, m) => s + m['gap'])
              .toStringAsFixed(2)),
      if (planTotalCredits != null)
        'plan_total_credits': planTotalCredits, // 方案声明「最低毕业学分」原值
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
            '可超过方案原要求；或 foreign_lang_level L1=6 分、L2=4.5 分、L3=3 分'
            '按档位封顶）；未选择时按方案原要求核算。',
    ];
    final traceNotes = <String>[
      if (foreignCap != null && planHasForeign)
        foreignCredits != null
            ? '外语要求学分自选 ${_g(foreignCredits)} 分：外语类模块要求学分'
                '按 ${_g(foreignCap)} 分核算。'
            : '外语等级 $foreignLevelRaw → 自选 ${_g(foreignCap)} 分：外语类模块'
                '要求学分按 ${_g(foreignCap)} 分封顶。',
      if (foreignCap != null && !planHasForeign)
        foreignCredits != null
            ? '未在方案中识别外语类模块，foreign_lang_credits=$foreignCreditsRaw 未生效。'
            : '未在方案中识别外语类模块，foreign_lang_level=$foreignLevelRaw 未生效。',
      if (foreignCap == null && planHasForeign)
        '外语等级未选择，外语类模块按方案原要求核算。',
      // 总学分口径（v1.4）：以方案声明为准；未声明则回落模块求和（宁缺勿猜）。
      if (planTotalCredits != null)
        '总计学分口径：方案声明最低毕业学分 ${_g(planTotalCredits)} 分'
            '（meta.total_credits），各模块要求之和为 ${_g(totals['required'])} 分'
            '——模块间课程交叉/折算时二者可不同，毕业总要求以方案声明为准。',
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
