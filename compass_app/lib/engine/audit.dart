/// engine/audit.dart — M2 学业进度审计规则引擎（确定性计算，无网络、无 LLM）。
/// 与 Python 版 engine/audit.py 逐逻辑对齐；golden 数据由 assets/golden/ 加载。
library;

import 'dart:convert';

import 'disclaimer.dart';
import 'matching.dart';
import 'timeline.dart';

class AuditEngine {
  static const engineVersion = '1.1';
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

  Map<String, dynamic> build(Map<String, dynamic> record, Map<String, dynamic> plan) {
    final recordCourses = (record['courses'] as List).cast<Map<String, dynamic>>();
    final (matched, unmatched) = matchRecordToPlan(recordCourses, plan);

    final earned = <String, double>{};
    for (final m in (plan['modules'] as List).cast<Map<String, dynamic>>()) {
      earned[m['module_id'] as String] = 0.0;
    }
    final passedIds = <String>{};
    for (final pair in matched) {
      final r = pair[0] as Map<String, dynamic>, c = pair[1] as Map<String, dynamic>;
      if (isPassed(r)) {
        earned[c['module_id'] as String] =
            earned[c['module_id'] as String]! + (c['credits'] as num).toDouble();
        passedIds.add(c['course_id'] as String);
      }
    }

    final byId = <String, Map<String, dynamic>>{};
    for (final c in (plan['courses'] as List).cast<Map<String, dynamic>>()) {
      byId[c['course_id'] as String] = c;
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

    for (final m in (plan['modules'] as List).cast<Map<String, dynamic>>()) {
      final req = (m['required_credits'] as num).toDouble();
      final mid = m['module_id'] as String;
      final got = double.parse(earned[mid]!.toStringAsFixed(2));
      final gap = double.parse((req - got).clamp(0.0, double.infinity).toStringAsFixed(2));
      final remaining = (plan['courses'] as List)
          .cast<Map<String, dynamic>>()
          .where((c) => c['module_id'] == mid && !passedIds.contains(c['course_id']))
          .toList();
      var openBeforeGrad = 0.0;
      for (final c in remaining) {
        if (futureIdx(c).isNotEmpty) openBeforeGrad += (c['credits'] as num).toDouble();
      }
      openBeforeGrad = double.parse(openBeforeGrad.toStringAsFixed(2));
      final color = gap <= 1e-9 ? 'green' : (gap <= openBeforeGrad + 1e-9 ? 'yellow' : 'red');
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
      summary.add({
        'module_id': mid,
        'module_path': m['module_path'],
        'required': req,
        'earned': got,
        'gap': gap,
        'remaining_future': openBeforeGrad,
        'color': color,
        'status': status,
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

    // 计划选课表内部
    final planCourses = (record['planned_courses'] as List? ?? []).cast<Map<String, dynamic>>();
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

    final totals = {
      'required': double.parse(summary.fold<num>(0, (s, m) => s + m['required']).toStringAsFixed(2)),
      'earned': double.parse(summary.fold<num>(0, (s, m) => s + m['earned']).toStringAsFixed(2)),
      'gap': double.parse(summary.fold<num>(0, (s, m) => s + m['gap']).toStringAsFixed(2)),
    };

    return {
      'summary': summary,
      'warnings': warnings,
      'extra_courses': unmatched,
      'totals': totals,
      'disclaimer': kDisclaimer,
      'trace': {
        'plan': '${plan['meta']['source_doc']}'
            '${(plan['meta']['grade'] ?? '').toString().isEmpty ? '' : ' ${plan['meta']['grade']}级'}'
            '（核验日 ${plan['meta']['verified_at'] ?? '-'}）',
        'engine': 'v$engineVersion',
      },
    };
  }

  static String _g(Object? n) {
    final d = (n as num).toDouble();
    return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toString();
  }

  /// 兼容 Python 版 main() 的入口（record 为 JSON 字符串或 Map）
  Map<String, dynamic> main(Object recordInput, {String action = 'audit'}) {
    if (action != 'audit') return {'error': 'unknown action: $action'};
    final rec = recordInput is String
        ? json.decode(recordInput) as Map<String, dynamic>
        : recordInput as Map<String, dynamic>;
    try {
      final plan = findPlan(rec['student']['major'] as String);
      final report = build(rec, plan);
      return {'report': report, 'report_json': json.encode(report)};
    } on ArgumentError catch (e) {
      return {'error': e.message.toString()};
    }
  }
}
