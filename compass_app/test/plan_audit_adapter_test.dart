// test/plan_audit_adapter_test.dart — PDF 解析结果 → 审计 PlanFile 适配器单测。
// 纯 Dart（package:test），CI 白名单 `dart test` 可直接跑；不依赖 flutter_test。
import 'package:test/test.dart';

import 'package:compass_app/data/plan_pdf_parse.dart';
import 'package:compass_app/engine/audit.dart';
import 'package:compass_app/engine/plan_audit_adapter.dart';

/// 合成方案：L1 通识课程 → L2 通识必修课程 → L3 思政类（2 门课）；
/// L2 通识选修课程（无课、带「二选一」「至少修读2门」说明）；
/// 另有 L3 无课无学分板块（应被丢弃）、L1 集中实践环节（level≤2 有学分无课，应保留）。
PlanPdfSections synthSections() => const PlanPdfSections(
      qualityNotes: ['PDF 第 3 页表格识别存在折行'],
      sections: [
        PdfModuleSection(title: '通识课程', level: 1, creditsRaw: '72.5'),
        PdfModuleSection(
          title: '通识必修课程',
          level: 2,
          creditsRaw: '62',
          parentPath: '通识课程',
        ),
        PdfModuleSection(
          title: '思政类',
          level: 3,
          creditsRaw: '14',
          parentPath: '通识课程 · 通识必修课程',
          notes: ['建议一年级学生修读。'],
          courses: [
            PdfCourseRow(
                code: 'MARX1004G',
                name: '大学生思想文化素养',
                credits: 2.0,
                hours: '2.0-0.0',
                semester: '一(秋冬)'),
            PdfCourseRow(
                code: 'MARX1005G',
                name: '新时代实践教育',
                credits: 2.0,
                hours: '+2',
                semester: '一(秋冬)/一(春夏)'),
          ],
        ),
        PdfModuleSection(
          title: '通识选修课程',
          level: 2,
          creditsRaw: '3-6',
          parentPath: '通识课程',
          notes: ['体育类与美育类二选一，至少修读2门。', '课程清单以选课网为准。'],
        ),
        // 无课程、无学分标注的三级板块：既无课也无要求 → 丢弃
        PdfModuleSection(
            title: '空转板块', level: 3, parentPath: '通识课程 · 通识选修课程'),
        PdfModuleSection(title: '集中实践环节', level: 1, creditsRaw: '14'),
      ],
    );

Map<String, dynamic> courseOf(Map<String, dynamic> plan, String id) =>
    (plan['courses'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((c) => c['course_id'] == id);

Map<String, dynamic> moduleOf(Map<String, dynamic> plan, String id) =>
    (plan['modules'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((m) => m['module_id'] == id);

void main() {
  group('纯函数小工具', () {
    test('requiredCreditsFrom 取首个数字段', () {
      expect(requiredCreditsFrom('62'), 62.0);
      expect(requiredCreditsFrom('3-6'), 3.0);
      expect(requiredCreditsFrom('+4'), 4.0);
      expect(requiredCreditsFrom('72.5'), 72.5);
      expect(requiredCreditsFrom(''), 0.0);
    });

    test('offeredFromSemester 学期串映射', () {
      expect(offeredFromSemester('一(秋冬)'), ['秋']);
      expect(offeredFromSemester('二(秋)/二(冬)'), ['秋']);
      expect(offeredFromSemester('一(秋冬)/一(春夏)'), ['秋', '春']);
      expect(offeredFromSemester('三(短)'), ['夏']);
      expect(offeredFromSemester('一(春)'), ['春']);
      expect(offeredFromSemester(''), isNull);
      expect(offeredFromSemester('   '), isNull);
      expect(offeredFromSemester('按学期安排'), isNull); // 无学期字宁缺勿猜
    });

    test('natureFromSectionTitle', () {
      expect(natureFromSectionTitle('专业必修课程'), '必修');
      expect(natureFromSectionTitle('通识选修课程'), '选修');
      expect(natureFromSectionTitle('专业限选'), '选修');
      expect(natureFromSectionTitle('思政类'), '必修'); // 未明示按必修
    });

    test('moduleSlug 稳定且中文可用；uniqueSlug 同名加序号', () {
      expect(moduleSlug('思 政 类', 2), 'sec2-思政类');
      expect(moduleSlug('通识必修课程', 1), 'sec1-通识必修课程');
      // 超 12 字截断
      expect(moduleSlug('通识必修课程思政社会实践环节', 7), 'sec7-通识必修课程思政社会实践');
      final taken = <String>{'sec3-必修课程'};
      expect(uniqueSlug('sec3-必修课程', taken), 'sec3-必修课程-2');
      expect(uniqueSlug('sec9-必修课程', taken), 'sec9-必修课程');
    });
  });

  group('detectChoiceRule', () {
    test('二选一 + 至少修读2门 并存时合并', () {
      final r = detectChoiceRule('体育类与美育类二选一，至少修读2门。');
      expect(r, isNotNull);
      expect(r!.pickFrom, 2);
      expect(r.minCourses, 2);
      expect(r.minCredits, isNull);
      expect(r.text, contains('二选一'));
      expect(r.text, contains('至少修读2门'));
    });

    test('N 选 M 与学分下限', () {
      final r = detectChoiceRule('在以下课程中5选2，至少修读2学分。');
      expect(r, isNotNull);
      expect(r!.pickFrom, 5);
      expect(r.minCourses, 2);
      expect(r.minCredits, 2.0);
    });

    test('显式门数下限优先于 N 选 M 隐含值', () {
      final r = detectChoiceRule('四类课程任选其一，至少修读3门。');
      expect(r!.minCourses, 3);
    });

    test('普通文字 / 空串不猜', () {
      expect(detectChoiceRule('建议一年级学生修读。'), isNull);
      expect(detectChoiceRule(''), isNull);
      expect(detectChoiceRule('至少修读若干门'), isNull); // 无数值不上猜
    });
  });

  group('detectAlternativeModules', () {
    test('父板块说明命中「以下 N 种模块中的一种」', () {
      final kids = <PdfModuleSection>[
        const PdfModuleSection(title: '工程实习', level: 3),
        const PdfModuleSection(title: '工艺实习', level: 3),
        const PdfModuleSection(title: '综合实训', level: 3),
      ];
      final s = detectAlternativeModules(
          kids, '实践环节要求：以下三种模块中的一种，满足其一即可认定。');
      expect(s, isNotNull);
      expect(s!.optionCount, 3);
      expect(s.optionTitles, ['工程实习', '工艺实习', '综合实训']);
    });

    test('阿拉伯数字亦可命中；未命中/「一种」返回 null', () {
      expect(detectAlternativeModules(const [], '以下2种模块中的一种')!.optionCount, 2);
      expect(detectAlternativeModules(const [], '按板块要求修读即可'), isNull);
      expect(detectAlternativeModules(const [], '以下一种模块即可'), isNull);
    });
  });

  group('planFileFromPdf', () {
    final plan = planFileFromPdf(synthSections(),
        major: '食品科学与工程', grade: '2026', sourceDoc: 'zdbk 2026级方案.pdf');

    test('板块取舍与 module_path / required_credits', () {
      final modules = (plan['modules'] as List).cast<Map<String, dynamic>>();
      // 丢弃：无课且无学分标注的三级板块
      expect(modules.map((m) => m['module_id']),
          ['sec0-通识课程', 'sec1-通识必修课程', 'sec2-思政类', 'sec3-通识选修课程', 'sec5-集中实践环节']);
      final ids = modules.map((m) => m['module_id']).toList();
      expect(ids, isNot(contains('sec4-空转板块')));

      // module_path：parentPath 优先；parentPath 空退化为自身 title
      expect(moduleOf(plan, 'sec2-思政类')['module_path'], '通识课程 · 通识必修课程');
      expect(moduleOf(plan, 'sec0-通识课程')['module_path'], '通识课程');
      expect(moduleOf(plan, 'sec3-通识选修课程')['required_credits'], 3.0); // '3-6' 取下限
      expect(moduleOf(plan, 'sec1-通识必修课程')['required_credits'], 62.0);

      // course_ids 只含本板块课程；无课板块保留但 course_ids 为空
      expect(moduleOf(plan, 'sec2-思政类')['course_ids'], ['MARX1004G', 'MARX1005G']);
      expect(moduleOf(plan, 'sec5-集中实践环节')['course_ids'], isEmpty);

      // 选择约束随模块带出（供 UI/后续审计）
      expect(moduleOf(plan, 'sec3-通识选修课程')['choice_rule'], isNotNull);
      expect((moduleOf(plan, 'sec3-通识选修课程')['choice_rule'] as Map)['pick_from'], 2);
      expect(moduleOf(plan, 'sec2-思政类').containsKey('choice_rule'), isFalse);
    });

    test('课程字段：course_id/module_id/nature/offered/source', () {
      final autumn = courseOf(plan, 'MARX1004G');
      expect(autumn['name'], '大学生思想文化素养');
      expect(autumn['credits'], 2.0);
      expect(autumn['module_id'], 'sec2-思政类');
      expect(autumn['nature'], '必修');
      expect(autumn['offered'], ['秋']);
      expect(autumn['prereq'], isEmpty);
      expect(autumn['grade_cycle'], isNull);
      expect(autumn['offered_years'], isNull);
      expect(autumn['source'], {'page': ''});
      expect(courseOf(plan, 'MARX1005G')['offered'], ['秋', '春']);
    });

    test('meta 与 quality 说明如实', () {
      final meta = plan['meta'] as Map<String, dynamic>;
      expect(meta['major'], '食品科学与工程');
      expect(meta['grade'], '2026');
      expect(meta['source_doc'], 'zdbk 2026级方案.pdf');
      // 未显式给 totalCredits：只累加无保留子板块的板块（思政类14+通识选修3+集中实践14）
      expect(meta['total_credits'], 31.0);
      final quality = (meta['quality'] as List).cast<String>();
      expect(quality, contains('PDF 第 3 页表格识别存在折行'));
      expect(quality.any((q) => q.contains('5 个板块 / 2 门课程')), isTrue);
      expect(planFileFromPdf(synthSections(), major: 'm', grade: 'g',
              totalCredits: 175.0)['meta']['total_credits'],
          175.0);
    });

    test('空输入不抛异常且结构完整', () {
      final empty = planFileFromPdf(const PlanPdfSections(), major: 'x', grade: 'y');
      expect(empty['modules'], isEmpty);
      expect(empty['courses'], isEmpty);
      expect((empty['meta'] as Map)['quality'], isNotEmpty);
    });

    test('同名板块重复时 module_id 不冲突', () {
      const dup = PlanPdfSections(sections: [
        PdfModuleSection(title: '必修课程', level: 4, creditsRaw: '12', courses: [
          PdfCourseRow(code: 'A1001', name: '甲', credits: 2),
        ]),
        PdfModuleSection(title: '必修课程', level: 4, creditsRaw: '8', courses: [
          PdfCourseRow(code: 'B1002', name: '乙', credits: 3),
        ]),
      ]);
      final p = planFileFromPdf(dup, major: 'x', grade: 'y');
      final ids = (p['modules'] as List)
          .cast<Map<String, dynamic>>()
          .map((m) => m['module_id'])
          .toList();
      expect(ids, ['sec0-必修课程', 'sec1-必修课程']);
      expect(courseOf(p, 'A1001')['offered'], isNull); // 无学期串
    });
  });

  group('接入 AuditEngine', () {
    test('PDF 全量方案 + 同名成绩单 → 无未匹配课程', () {
      final plan = planFileFromPdf(synthSections(),
          major: '食品科学与工程', grade: '2026');
      final engine = AuditEngine({});
      engine.registerRuntimePlan('食品科学与工程', plan);

      final record = <String, dynamic>{
        'student': {
          'alias': '本人',
          'major': '食品科学与工程',
          'grade': '2026',
          'current_semester': '2026-A',
        },
        'courses': [
          {'course_id': 'MARX1004G', 'name': '大学生思想文化素养', 'credits': 2.0, 'semester': '2026-A', 'grade': 88},
          {'course_id': 'MARX1005G', 'name': '新时代实践教育', 'credits': 2.0, 'semester': '2026-B', 'grade': 90},
        ],
      };

      final found = engine.findPlan('食品科学与工程');
      expect(found, same(plan));

      final report = engine.build(record, found);
      expect(report['extra_courses'], isEmpty); // 核心诉求：不再报「未匹配到方案」
      final summary = (report['summary'] as List).cast<Map<String, dynamic>>();
      expect(summary.length, (plan['modules'] as List).length);

      final sizheng = summary.firstWhere((s) => s['module_id'] == 'sec2-思政类');
      expect(sizheng['required'], 14.0);
      expect(sizheng['earned'], 4.0); // 两门均已通过，计入所在板块
      expect(sizheng['gap'], 10.0);
      expect(sizheng['color'], isNot('green'));
      expect((report['totals'] as Map)['earned'], 4.0);
      expect(report['trace'], isNotNull);
    });

    test('成绩单按名称近似命中（无 course_id 也能匹配）', () {
      final plan = planFileFromPdf(synthSections(), major: 'm', grade: '2026');
      final report = AuditEngine({}).build(<String, dynamic>{
        'student': {'major': 'm', 'grade': '2026', 'current_semester': '2026-A'},
        'courses': [
          {'name': '大学生思想文化素养', 'credits': 2.0, 'grade': 77},
        ],
      }, plan);
      expect(report['extra_courses'], isEmpty);
    });
  });
}
