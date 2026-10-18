// test/engine_audit_test.dart — audit 口径回归（2026-10-18 用户实测与明确口径）：
//  1) 选课组（四选一 / 选 N 门）只按「至少 N 门」折算要求学分，不再全组和；
//  2) 外语等级 L1/L2/L3 封顶外语类模块要求学分，缺省不假设；
//  3) 多标签课程（同一 course_id/名称出现在多个模块）按各模块分别计学分
//     （v1.4 多重计分，用户明确「一节课两个标签同时计入两边」，与教务一致）；
//  4) selected_no_credit（已选未获学分）与 earned（已获学分）分开呈现，
//     多标签课程同步双计；同一模块内重复行去重、重修只计一次；
//  5) totals 总学分口径：方案声明 meta.total_credits 为准（plan_total_credits /
//     total_basis），未声明回落模块求和并在 trace.notes 说明。
// 纯 Dart 测试（无 Flutter 依赖），可与 engine_test.dart 同批跑。
import 'package:test/test.dart';

import 'package:compass_app/engine/audit.dart';

Map<String, dynamic> planOf({
  required List<Map<String, dynamic>> modules,
  required List<Map<String, dynamic>> courses,
  String major = 't_major',
  double? totalCredits,
}) =>
    {
      'meta': {
        'major': major,
        'grade': '2023',
        'source_doc': '合成测试方案',
        'verified_at': '2026-10-13',
        if (totalCredits != null) 'total_credits': totalCredits,
      },
      'modules': modules,
      'courses': courses,
    };

Map<String, dynamic> moduleOf({
  required String id,
  required String path,
  required double requiredCredits,
  String? title,
  int? nSelect,
  Map<String, dynamic>? group,
  Map<String, dynamic>? choiceRule,
  bool? countRule,
  String? creditsUnit,
}) =>
    {
      'module_id': id,
      'module_path': path,
      'required_credits': requiredCredits,
      if (title != null) 'title': title,
      if (nSelect != null) 'n_select': nSelect,
      if (group != null) 'group': group,
      if (choiceRule != null) 'choice_rule': choiceRule,
      if (countRule != null) 'count_rule': countRule,
      if (creditsUnit != null) 'plan_credits_unit': creditsUnit,
    };

Map<String, dynamic> courseOf(String cid, String name, double credits,
        {required String moduleId}) =>
    {
      'course_id': cid,
      'name': name,
      'credits': credits,
      'module_id': moduleId,
      'nature': '限选',
      'offered': ['秋', '春'],
      'offered_years': null,
      'prereq': <String>[],
      'source': {'page': 1},
    };

Map<String, dynamic> rec({
  List<Map<String, dynamic>> courses = const [],
  List<Map<String, dynamic>> planned = const [],
}) =>
    {
      'student': {
        'alias': 't',
        'major': 't_major',
        'grade': '2023',
        'current_semester': '2026-A',
      },
      'source': 'paste',
      'courses': courses,
      'planned_courses': planned,
    };

Map<String, dynamic> passed(String cid, String name, double credits,
        {double grade = 85}) =>
    {'course_id': cid, 'name': name, 'credits': credits, 'grade': grade, 'semester': '2025-A'};

Map<String, dynamic> failed(String cid, String name, double credits) =>
    {'course_id': cid, 'name': name, 'credits': credits, 'grade': 50, 'semester': '2025-A'};

Map<String, dynamic>? moduleRow(Map<String, dynamic> report, String id) {
  for (final m in (report['summary'] as List).cast<Map<String, dynamic>>()) {
    if (m['module_id'] == id) return m;
  }
  return null;
}

void main() {
  // 「大学写作（四选一）」类组：4 门各 2.0，被全量和成 required 8.0（用户 bug 指纹）
  final writingCourses = [
    courseOf('W1', '大学写作——写作·人', 2.0, moduleId: 'writing_group'),
    courseOf('W2', '大学写作——写作·自然', 2.0, moduleId: 'writing_group'),
    courseOf('W3', '大学写作——写作·社会', 2.0, moduleId: 'writing_group'),
    courseOf('W4', '大学写作——创意写作', 2.0, moduleId: 'writing_group'),
  ];
  final groupPlan = planOf(modules: [
    moduleOf(
      id: 'writing_group',
      path: '通识教育/通识选修 · 大学写作（四选一）',
      requiredCredits: 8.0,
      title: '大学写作（四选一）',
    ),
  ], courses: writingCourses);

  group('选课组：四选一只计满足', () {
    test('title「四选一」→ 要求学分按 1 门折算，不再全组和 8.0', () {
      final r = AuditEngine({}).build(rec(), groupPlan);
      final m = moduleRow(r, 'writing_group')!;
      expect(m['required'], 2.0);
      expect(m['earned'], 0.0);
      expect(m['gap'], 2.0);
      // 未来可修 8 分 ≥ 缺口 → yellow（不是红）
      expect(m['color'], 'yellow');
      expect(r['totals']['required'], 2.0);
    });

    test('任过 1 门即达成（green），earned 按实际计', () {
      final r = AuditEngine({}).build(
          rec(courses: [passed('W2', '大学写作——写作·自然', 2.0)]), groupPlan);
      final m = moduleRow(r, 'writing_group')!;
      expect(m['required'], 2.0);
      expect(m['earned'], 2.0);
      expect(m['gap'], 0.0);
      expect(m['color'], 'green');
    });

    test('组内超修 2 门不推高要求：gap 仍 0，totals.required 不重复计', () {
      final r = AuditEngine({}).build(
          rec(courses: [
            passed('W1', '大学写作——写作·人', 2.0),
            passed('W2', '大学写作——写作·自然', 2.0),
          ]),
          groupPlan);
      final m = moduleRow(r, 'writing_group')!;
      expect(m['required'], 2.0);
      expect(m['earned'], 4.0); // earned 如实（超修部分不折算掉）
      expect(m['gap'], 0.0);
      expect(m['color'], 'green');
      expect(r['totals']['required'], 2.0);
      expect(r['totals']['gap'], 0.0);
    });

    test('n_select 显式字段同效（组内任选 N 门）', () {
      final p = planOf(modules: [
        moduleOf(id: 'g', path: '通识选修 · 耕读经典类', requiredCredits: 6.0, nSelect: 1),
      ], courses: [
        courseOf('G1', '耕读经典A', 2.0, moduleId: 'g'),
        courseOf('G2', '耕读经典B', 2.0, moduleId: 'g'),
        courseOf('G3', '耕读经典C', 2.0, moduleId: 'g'),
      ]);
      final r = AuditEngine({}).build(
          rec(courses: [passed('G3', '耕读经典C', 2.0)]), p);
      final m = moduleRow(r, 'g')!;
      expect(m['required'], 2.0);
      expect(m['color'], 'green');
    });

    test('「选 1 门」/「至少修读 N 门」门数口径（count_rule）按 N 门最便宜折算', () {
      final p = planOf(modules: [
        moduleOf(
          id: 'gengdu',
          path: '通识教育/通识选修 · 耕读经典类',
          requiredCredits: 1.0, // 门数（不是学分）
          title: '至少修读1门耕读经典类课程',
          countRule: true,
        ),
      ], courses: [
        courseOf('GD1', '耕读课甲', 1.5, moduleId: 'gengdu'),
        courseOf('GD2', '耕读课乙', 3.0, moduleId: 'gengdu'),
      ]);
      final r = AuditEngine({}).build(
          rec(courses: [passed('GD2', '耕读课乙', 3.0)]), p);
      final m = moduleRow(r, 'gengdu')!;
      expect(m['required'], 1.5); // 1 门最便宜课程折算，绝不是 1.0 学分或 4.5 全组和
      expect(m['earned'], 3.0);
      expect(m['color'], 'green');
    });

    test('标注正确（要求 < 全组和 / 无组信号）的模块一律不动', () {
      final p = planOf(modules: [
        // 选修池：要求 10.5，池内课程只有 8 分 → 指纹不成立，不动
        moduleOf(id: 'pool', path: '通识教育/通识选修', requiredCredits: 10.5),
      ], courses: writingCourses);
      final r = AuditEngine({}).build(rec(), p);
      expect(moduleRow(r, 'pool')!['required'], 10.5);
    });

    test('门数折算不出（count 模块无课程）时归 0，绝不把门数当学分', () {
      final p = planOf(modules: [
        moduleOf(id: 'empty_count', path: 'x', requiredCredits: 2.0, countRule: true),
      ], courses: const []);
      final r = AuditEngine({}).build(rec(), p);
      expect(moduleRow(r, 'empty_count')!['required'], 0.0);
    });
  });

  // ── 外语等级 L1/L2/L3 ────────────────────────────────────────────────────
  final foreignPlan = planOf(modules: [
    moduleOf(id: 'foreign_lang', path: '通识教育/外语类', requiredCredits: 9.0),
    moduleOf(id: 'major_core', path: '专业教育/专业核心', requiredCredits: 4.0),
  ], courses: [
    courseOf('FE1', '大学英语Ⅰ', 3.0, moduleId: 'foreign_lang'),
    courseOf('FE2', '大学英语Ⅱ', 3.0, moduleId: 'foreign_lang'),
    courseOf('FE3', '大学英语Ⅲ', 3.0, moduleId: 'foreign_lang'),
    courseOf('CS1', '程序设计基础', 4.0, moduleId: 'major_core'),
  ]);

  group('外语等级三档', () {
    for (final entry in {
      'L1': 6.0,
      'L2': 4.5,
      'L3': 3.0,
    }.entries) {
      test('$entry.key → 外语模块要求按 ${entry.value} 封顶（过 1 门 3 分即相应达成度）', () {
        final r = AuditEngine({}).build(
            rec(courses: [passed('FE1', '大学英语Ⅰ', 3.0)]),
            foreignPlan,
            action: {'foreign_lang_level': entry.key});
        final m = moduleRow(r, 'foreign_lang')!;
        expect(m['required'], entry.value);
        expect(m['earned'], 3.0);
        expect(m['gap'],
            double.parse((entry.value - 3.0).clamp(0.0, double.infinity).toStringAsFixed(2)));
        expect('${(r['trace']['notes'] as List).join()}',
            contains('外语等级 ${entry.key}'));
      });
    }

    test('L3 过 1 门即 green；非外语模块要求不受影响', () {
      final r = AuditEngine({}).build(
          rec(courses: [passed('FE1', '大学英语Ⅰ', 3.0)]),
          foreignPlan,
          action: {'foreign_lang_level': 'L3'});
      expect(moduleRow(r, 'foreign_lang')!['color'], 'green');
      expect(moduleRow(r, 'major_core')!['required'], 4.0);
    });

    test('封顶只降不升：方案要求 4.5 时选 L1 仍按 4.5', () {
      final p = planOf(modules: [
        moduleOf(id: 'foreign_lang', path: '通识教育/外语类', requiredCredits: 4.5),
      ], courses: [courseOf('FE1', '大学英语Ⅰ', 3.0, moduleId: 'foreign_lang')]);
      final r = AuditEngine({}).build(rec(),
          p,
          action: {'foreign_lang_level': 'L1'});
      expect(moduleRow(r, 'foreign_lang')!['required'], 4.5);
    });

    test('等级缺省不假设：按方案原要求核算，trace 注明「外语等级未选择」', () {
      final r = AuditEngine({}).build(
          rec(courses: [passed('FE1', '大学英语Ⅰ', 3.0)]), foreignPlan);
      final m = moduleRow(r, 'foreign_lang')!;
      expect(m['required'], 9.0);
      expect(m['gap'], 6.0);
      final notes = (r['trace']['notes'] as List).cast<String>().join();
      expect(notes, contains('外语等级未选择'));
    });

    test('非法等级显式报错（宁缺勿猜，不静默忽略）', () {
      expect(
          () => AuditEngine({}).build(rec(), foreignPlan,
              action: {'foreign_lang_level': 'L9'}),
          throwsArgumentError);
      final out = AuditEngine({'t_major': foreignPlan})
          .main(rec(), action: {'foreign_lang_level': 'L9'});
      expect(out.containsKey('error'), isTrue);
      expect(out['error'], contains('外语等级'));
    });

    test('方案无外语模块时给等级：trace 注明未生效', () {
      final r = AuditEngine({}).build(rec(),
          groupPlan,
          action: {'foreign_lang_level': 'L2'});
      expect(
          (r['trace']['notes'] as List).join(), contains('未在方案中识别外语类模块'));
    });
  });

  // ── 多标签课程双计（多重计分，v1.4 用户口径）─────────────────────────────
  group('多标签课程双计', () {
    // W1 同时挂在「大学写作（四选一）」与「专业限选」两个模块
    final multiPlan = planOf(modules: [
      moduleOf(
        id: 'writing_group',
        path: '通识教育/通识选修 · 大学写作（四选一）',
        requiredCredits: 8.0,
        title: '大学写作（四选一）',
      ),
      moduleOf(id: 'other', path: '专业教育/专业限选', requiredCredits: 2.0),
    ], courses: [
      ...writingCourses,
      courseOf('W1', '大学写作——写作·人', 2.0, moduleId: 'other'),
    ]);

    test('同一 course_id 出现在两个模块：两模块各计一次（earned 双计）', () {
      final r = AuditEngine({})
          .build(rec(courses: [passed('W1', '大学写作——写作·人', 2.0)]), multiPlan);
      expect(moduleRow(r, 'writing_group')!['earned'], 2.0);
      expect(moduleRow(r, 'other')!['earned'], 2.0);
      expect(r['totals']['earned'], 4.0);
      expect(r['totals']['required'], 4.0); // 组 2.0（折算）+ 限选 2.0
      // summary 明细：两处 W1 均标 multi_tag
      for (final id in ['writing_group', 'other']) {
        final w1 = (moduleRow(r, id)!['plan_courses'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((c) => c['course_id'] == 'W1');
        expect(w1['multi_tag'], isTrue, reason: id);
      }
      // trace 注明多重计分；caliber_notes 固定含多重计分口径
      expect((r['trace']['notes'] as List).join(), contains('多重计分'));
      expect((r['caliber_notes'] as List), contains(kCaliberMultiTagNote));
    });

    test('已选未获同步双计：failed W1 在两个模块各计 1 门', () {
      final r = AuditEngine({}).build(
          rec(courses: [failed('W1', '大学写作——写作·人', 2.0)]), multiPlan);
      expect(moduleRow(r, 'writing_group')!['selected_no_credit'], 1);
      expect(moduleRow(r, 'other')!['selected_no_credit'], 1);
      expect(moduleRow(r, 'writing_group')!['earned'], 0.0);
      expect(moduleRow(r, 'other')!['earned'], 0.0);
    });

    test('重修多条记录：每模块仍只计一次', () {
      final r = AuditEngine({}).build(
          rec(courses: [
            passed('W1', '大学写作——写作·人', 2.0, grade: 61),
            passed('W1', '大学写作——写作·人', 2.0, grade: 88),
          ]),
          multiPlan);
      expect(moduleRow(r, 'writing_group')!['earned'], 2.0);
      expect(moduleRow(r, 'other')!['earned'], 2.0);
      expect(r['totals']['earned'], 4.0);
    });

    test('同名不同号跨模块（名称多归属）：同样双计', () {
      final p = planOf(modules: [
        moduleOf(id: 'm1', path: '专业教育/专业核心', requiredCredits: 3.0),
        moduleOf(id: 'm2', path: '通识教育/劳育类', requiredCredits: 2.0),
      ], courses: [
        courseOf('A1', '劳动教育实践', 3.0, moduleId: 'm1'),
        courseOf('B2', '劳动教育实践', 2.0, moduleId: 'm2'),
      ]);
      final r = AuditEngine({})
          .build(rec(courses: [passed('A1', '劳动教育实践', 3.0)]), p);
      expect(moduleRow(r, 'm1')!['earned'], 3.0);
      expect(moduleRow(r, 'm2')!['earned'], 2.0);
      expect(r['totals']['earned'], 5.0);
    });

    test('单归属课程不受影响：只计一次', () {
      final r = AuditEngine({}).build(
          rec(courses: [passed('W2', '大学写作——写作·自然', 2.0)]), groupPlan);
      expect(moduleRow(r, 'writing_group')!['earned'], 2.0);
      expect(r['totals']['earned'], 2.0);
    });
  });

  // ── 同一模块内去重与重修口径 ─────────────────────────────────────────────
  group('模块内去重', () {
    test('同模块重复行（同 course_id 多行）：earned/明细只计一次', () {
      final p = planOf(modules: [
        moduleOf(id: 'm1', path: '专业教育/专业核心', requiredCredits: 4.0),
      ], courses: [
        courseOf('A', '课程甲', 2.0, moduleId: 'm1'),
        courseOf('A', '课程甲', 2.0, moduleId: 'm1'), // 重复行
        courseOf('B', '课程乙', 2.0, moduleId: 'm1'),
      ]);
      final r = AuditEngine({}).build(rec(courses: [passed('A', '课程甲', 2.0)]), p);
      final m = moduleRow(r, 'm1')!;
      expect(m['earned'], 2.0); // 绝不 4.0
      expect(m['selected_no_credit'], 0);
      expect(
          (m['plan_courses'] as List).where((c) => c['course_id'] == 'A').length, 1);
      expect(r['totals']['required'], 4.0); // 甲+乙（重复行去重，不虚增）
      expect(r['totals']['earned'], 2.0);
    });

    test('重修同一门课两条记录：只计一次学分', () {
      final r = AuditEngine({}).build(
          rec(courses: [
            passed('W1', '大学写作——写作·人', 2.0, grade: 61),
            passed('W1', '大学写作——写作·人', 2.0, grade: 88),
          ]),
          groupPlan);
      expect(moduleRow(r, 'writing_group')!['earned'], 2.0);
      expect(r['totals']['earned'], 2.0);
    });
  });

  // ── totals 总学分口径（v1.4：方案声明为准，模块求和回落）──────────────────
  group('totals 总学分口径', () {
    test('方案声明 total_credits：plan_total_credits 原值 + plan_declared', () {
      final p = planOf(modules: [
        moduleOf(id: 'm1', path: '专业教育/专业核心', requiredCredits: 4.0),
      ], courses: [
        courseOf('A', '课程甲', 2.0, moduleId: 'm1'),
        courseOf('B', '课程乙', 2.0, moduleId: 'm1'),
      ], totalCredits: 160.0);
      final r = AuditEngine({})
          .build(rec(courses: [passed('A', '课程甲', 2.0)]), p);
      final t = r['totals'];
      expect(t['plan_total_credits'], 160.0);
      expect(t['total_basis'], 'plan_declared');
      expect(t['required'], 4.0); // 模块级照旧
      expect((r['trace']['notes'] as List).join(), contains('最低毕业学分 160 分'));
    });

    test('方案未声明：回落模块求和（module_sum_fallback），无 plan_total_credits', () {
      final r = AuditEngine({}).build(rec(), groupPlan); // planOf 无 total_credits
      final t = r['totals'];
      expect(t.containsKey('plan_total_credits'), isFalse);
      expect(t['total_basis'], 'module_sum_fallback');
      expect(t['required'], 2.0);
      expect((r['trace']['notes'] as List).join(), contains('回落'));
    });

    test('固定口径说明第三条（多重计分）逐字存在', () {
      final r = AuditEngine({}).build(rec(), groupPlan);
      expect((r['caliber_notes'] as List), contains(kCaliberMultiTagNote));
    });
  });

  // ── 已选 vs 已获口径（selected_no_credit）────────────────────────────────
  group('selected_no_credit 口径', () {
    final p = planOf(modules: [
      moduleOf(id: 'm1', path: '专业教育/专业核心', requiredCredits: 4.0),
    ], courses: [
      courseOf('A', '课程甲', 2.0, moduleId: 'm1'),
      courseOf('B', '课程乙', 2.0, moduleId: 'm1'),
      courseOf('C', '课程丙', 2.0, moduleId: 'm1'),
    ]);

    test('已修未过 计 1；已获学分不计；计划选课计入（去重）', () {
      final r = AuditEngine({}).build(
          rec(
            courses: [
              passed('A', '课程甲', 2.0),
              failed('B', '课程乙', 2.0),
            ],
            planned: [
              {'course_id': 'B', 'name': '课程乙', 'semester': '2026-B'},
              {'course_id': 'C', 'name': '课程丙', 'semester': '2026-B'},
            ],
          ),
          p);
      final m = moduleRow(r, 'm1')!;
      expect(m['earned'], 2.0); // 已获：只有甲
      expect(m['selected_no_credit'], 2); // 已选未获：乙（失败+重计划去重）、丙（计划）
      expect(m['gap'], 2.0);
    });

    test('在修未出分（无成绩行）计入已选未获；全过则归 0', () {
      final r = AuditEngine({}).build(
          rec(courses: [
            {'course_id': 'A', 'name': '课程甲', 'credits': 2.0, 'semester': '2026-A'},
            passed('B', '课程乙', 2.0),
          ]),
          p);
      final m = moduleRow(r, 'm1')!;
      expect(m['earned'], 2.0);
      expect(m['selected_no_credit'], 1);
      // 补齐后归 0
      final r2 = AuditEngine({}).build(
          rec(courses: [passed('A', '课程甲', 2.0), passed('B', '课程乙', 2.0)]), p);
      expect(moduleRow(r2, 'm1')!['selected_no_credit'], 0);
    });
  });

  // ── 口径说明与 trace ─────────────────────────────────────────────────────
  group('caliber_notes 与 trace.notes', () {
    test('报告含口径说明字段（紧邻 disclaimer），固定两条逐字存在', () {
      final r = AuditEngine({}).build(rec(), groupPlan);
      final notes = (r['caliber_notes'] as List).cast<String>();
      expect(r.containsKey('disclaimer'), isTrue);
      expect(notes, contains(kCaliberEarnedNote));
      expect(notes, contains(kCaliberSelectedNote));
      expect(notes.join(), contains('选课组口径')); // 组折算实际生效 → 追加说明
      expect(notes.join(), isNot(contains('外语口径'))); // 方案无外语模块
    });

    test('无组方案不追加选课组口径；每模块都输出 selected_no_credit', () {
      final r = AuditEngine({}).build(rec(), foreignPlan);
      final notes = (r['caliber_notes'] as List).cast<String>().join();
      expect(notes, isNot(contains('选课组口径')));
      expect(notes, contains('外语口径'));
      for (final m in (r['summary'] as List).cast<Map<String, dynamic>>()) {
        expect(m.containsKey('selected_no_credit'), isTrue);
        expect(m['selected_no_credit'], isA<int>());
      }
    });
  });

  // ── 纯函数单元 ────────────────────────────────────────────────────────────
  group('detectModuleGroupRule / effectiveRequiredCredits 纯函数', () {
    test('title 文本：四选一/五选二/至少修读3门/选 2 门', () {
      int? mc(String path, String title) =>
          detectModuleGroupRule({'module_path': path, 'title': title})?.minCourses;
      expect(mc('x', '大学写作（四选一）'), 1);
      expect(mc('x', '博雅技艺（五选二）'), 2);
      expect(mc('x', '至少修读3门通识核心课程'), 3);
      expect(mc('x', '耕读经典类选 1 门'), 1);
      expect(mc('通识教育/通识必修', '通识必修课程'), isNull); // 无信号不猜
      expect(mc('专业教育/专业限选', '任意选修'), isNull);
    });

    test('显式字段优先级：n_select > group > choice_rule > title', () {
      expect(
          detectModuleGroupRule({
            'n_select': 2,
            'choice_rule': {'min_courses': 1},
            'module_path': '四选一',
          })!.source,
          'n_select');
      expect(
          detectModuleGroupRule({
            'group': {'min_courses': 2, 'min_credits': 3.0},
            'module_path': '四选一',
          })!.source,
          'group');
    });

    test('effectiveRequiredCredits：门数折算 / 全组和指纹 / 正确标注不动', () {
      // 门数口径：required 2 门 → 2 门最便宜（1.5+1.5=3.0）
      expect(
          effectiveRequiredCredits({
            'required_credits': 2.0,
            'count_rule': true,
          }, [
            {'course_id': 'a', 'credits': 3.0},
            {'course_id': 'b', 'credits': 1.5},
            {'course_id': 'c', 'credits': 1.5},
          ]),
          3.0);
      // 全组和指纹：required 8 == 组内和 8 + 四选一 → 2.0
      expect(
          effectiveRequiredCredits({
            'required_credits': 8.0,
            'module_path': '大学写作（四选一）',
          }, [
            for (var i = 1; i <= 4; i++)
              {'course_id': 'w$i', 'credits': 2.0},
          ]),
          2.0);
      // 标注正确（4 < 8）：不动
      expect(
          effectiveRequiredCredits({
            'required_credits': 4.0,
            'module_path': '大学写作（四选一）',
          }, [
            for (var i = 1; i <= 4; i++)
              {'course_id': 'w$i', 'credits': 2.0},
          ]),
          4.0);
      // 多标签重复行去重后只计一次：required 4 == 去重和 4 → 折算 2.0
      expect(
          effectiveRequiredCredits({
            'required_credits': 4.0,
            'n_select': 1,
          }, [
            {'course_id': 'w1', 'credits': 2.0},
            {'course_id': 'w1', 'credits': 2.0},
            {'course_id': 'w2', 'credits': 2.0},
          ]),
          2.0);
    });

    test('isForeignLangModule：外语类/大学英语 命中，专业核心不命中', () {
      expect(isForeignLangModule({'module_path': '通识教育/外语类'}), isTrue);
      expect(isForeignLangModule({'title': '大学英语系列'}), isTrue);
      expect(isForeignLangModule({'category': '专业核心'}), isFalse);
    });
  });

  // ── main() action 装配 ───────────────────────────────────────────────────
  group('main() action 装配', () {
    final engine = AuditEngine({'t_major': foreignPlan});
    test("action 'audit' 与缺省等价", () {
      expect(engine.main(rec(), action: 'audit').containsKey('report'), isTrue);
      expect(engine.main(rec()).containsKey('report'), isTrue);
    });
    test("action Map 生效：L2 封顶 4.5", () {
      final out = engine.main(
          rec(courses: [passed('FE1', '大学英语Ⅰ', 3.0)]),
          action: {'foreign_lang_level': 'L2'});
      final report = out['report'] as Map<String, dynamic>;
      final m = (report['summary'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((x) => x['module_id'] == 'foreign_lang');
      expect(m['required'], 4.5);
    });
    test("未知 action 串报错（与 Python 镜像同形）", () {
      expect(engine.main(rec(), action: 'nope')['error'], 'unknown action: nope');
    });
  });
}
