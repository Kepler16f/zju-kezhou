// test/plan_audit_adapter_test.dart — PDF 解析结果 → 审计 PlanFile 适配器单测。
// 纯 Dart（package:test），CI 白名单 `dart test` 可直接跑；不依赖 flutter_test。
import 'package:test/test.dart';

import 'package:compass_app/data/plan_pdf_parse.dart';
import 'package:compass_app/engine/audit.dart';
import 'package:compass_app/engine/plan_audit_adapter.dart';

/// 合成方案：L1 通识课程(72.5) → L2 通识必修课程(62) → L3 思政类(14，2 门课)；
/// L2 通识选修课程(3-6，无课、带「二选一」「至少修读2门」说明；其下仅一个空板块)；
/// L3 空板块（无课无学分，应丢弃）；L1 集中实践环节(14，无课叶子，应保留)。
/// 叶子优先取舍后保留：思政类 / 通识选修课程 / 集中实践环节——
/// 父板块（通识课程、通识必修课程）只作 rollup，不再单独计入总学分。
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

/// 三层包含结构（真实 PDF 常态：课程挂在 L4）：
/// 一、通识课程 72.5 ⊇ 1.通识必修 62 ⊇ (1)思政类 14 ⊇ L4 必修12 + 选修2。
/// 旧口径会把 72.5+62+14+12+2 全加进 totals（重复计费）；叶子优先只计 14。
const PlanPdfSections threeLevelSections = PlanPdfSections(sections: [
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
  ),
  PdfModuleSection(
    title: '必修课程',
    level: 4,
    creditsRaw: '12',
    parentPath: '通识课程 · 通识必修课程 · 思政类',
    courses: [
      PdfCourseRow(code: 'MARX1004G', name: '大学生思想文化素养', credits: 2.0),
      PdfCourseRow(code: 'MARX1006G', name: '马克思主义基本原理', credits: 1.0),
    ],
  ),
  PdfModuleSection(
    title: '选修课程',
    level: 4,
    creditsRaw: '2',
    parentPath: '通识课程 · 通识必修课程 · 思政类',
    courses: [
      PdfCourseRow(code: 'MARX2005G', name: '中国共产党历史与理论', credits: 1.0),
    ],
  ),
]);

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

  group('keptSectionFlags（叶子优先取舍，防父子重复计费）', () {
    test('合成方案：父板块丢弃、叶子保留、空板块丢弃', () {
      // 0 通识课程(父) / 1 通识必修课程(父) / 2 思政类(叶·有课) /
      // 3 通识选修课程(叶·仅学分标注，空转板块不算保留子板块) / 4 空转板块 / 5 集中实践
      expect(keptSectionFlags(synthSections()),
          [false, false, true, true, false, true]);
    });

    test('三层包含结构：要求挂在 L1、课程挂在 L4 → 只保留 L4', () {
      expect(keptSectionFlags(threeLevelSections),
          [false, false, false, true, true]);
    });

    test('无课无学分的深层板块被丢弃，不阻止父板块按叶子保留', () {
      // L2 通识选修 3-6 的唯一孩子是空板块（被丢弃）→ L2 是有效叶子，要求不丢
      const ps = PlanPdfSections(sections: [
        PdfModuleSection(title: '通识选修课程', level: 2, creditsRaw: '3-6'),
        PdfModuleSection(
            title: '空转板块', level: 3, parentPath: '通识选修课程'),
      ]);
      expect(keptSectionFlags(ps), [true, false]);
    });

    test('乱序输入不动点收敛（不依赖文档顺序）', () {
      // 子板块先出现、父板块后出现（合成数据可能如此），不动点迭代仍收敛
      const ps = PlanPdfSections(sections: [
        PdfModuleSection(
          title: '思政类',
          level: 3,
          creditsRaw: '14',
          parentPath: '通识课程 · 通识必修课程',
          courses: [PdfCourseRow(code: 'M1001', name: '甲课程', credits: 2.0)],
        ),
        PdfModuleSection(
          title: '通识必修课程',
          level: 2,
          creditsRaw: '62',
          parentPath: '通识课程',
        ),
        PdfModuleSection(title: '通识课程', level: 1, creditsRaw: '72.5'),
      ]);
      expect(keptSectionFlags(ps), [true, false, false]);
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
      // 叶子优先：父板块（通识课程 / 通识必修课程）只作 rollup，不再成审计模块；
      // 无课且无学分标注的空转板块丢弃
      expect(modules.map((m) => m['module_id']),
          ['sec2-思政类', 'sec3-通识选修课程', 'sec5-集中实践环节']);

      // module_path：完整 label（含自身标题），兄弟板块不再共享同一行；
      // 顶层无上级时退化为自身 title。
      expect(moduleOf(plan, 'sec2-思政类')['module_path'],
          '通识课程 · 通识必修课程 · 思政类');
      expect(moduleOf(plan, 'sec5-集中实践环节')['module_path'], '集中实践环节');
      expect(moduleOf(plan, 'sec2-思政类')['required_credits'], 14.0);
      expect(moduleOf(plan, 'sec3-通识选修课程')['required_credits'], 3.0); // '3-6' 取下限
      expect(moduleOf(plan, 'sec5-集中实践环节')['required_credits'], 14.0);

      // course_ids 只含本板块课程；无课叶子板块保留但 course_ids 为空
      expect(moduleOf(plan, 'sec2-思政类')['course_ids'], ['MARX1004G', 'MARX1005G']);
      expect(moduleOf(plan, 'sec5-集中实践环节')['course_ids'], isEmpty);

      // 选择约束随模块带出（供 UI/后续审计）
      expect(moduleOf(plan, 'sec3-通识选修课程')['choice_rule'], isNotNull);
      expect((moduleOf(plan, 'sec3-通识选修课程')['choice_rule'] as Map)['pick_from'], 2);
      expect(moduleOf(plan, 'sec2-思政类').containsKey('choice_rule'), isFalse);
    });

    test('三层包含结构：required 总和 = 叶子和，父板块不再重复计入', () {
      final p = planFileFromPdf(threeLevelSections, major: 'm', grade: '2026');
      final modules = (p['modules'] as List).cast<Map<String, dynamic>>();
      expect(
          modules.map((m) => m['module_id']), ['sec3-必修课程', 'sec4-选修课程']);
      // required 总和 = 12 + 2 = 14（恰为思政类声明学分），
      // 旧口径会把 72.5+62+14+12+2=162.5 全计进 totals（重复计费）
      final sumReq = modules.fold<double>(
          0, (a, m) => a + (m['required_credits'] as num).toDouble());
      expect(sumReq, 14.0);
      expect((p['meta'] as Map)['total_credits'], 14.0);
      // 完整路径含自身标题：两个兄弟子规则不再显示成同一行。
      expect(modules.first['module_path'],
          '通识课程 · 通识必修课程 · 思政类 · 必修课程');
      expect(modules[1]['module_path'],
          '通识课程 · 通识必修课程 · 思政类 · 选修课程');
    });

    test('混合父板块（自身挂课 + 有被保留子板块）：保留、要求按直属课程和计', () {
      const ps = PlanPdfSections(sections: [
        PdfModuleSection(
          title: '科研实践',
          level: 1,
          creditsRaw: '30',
          courses: [PdfCourseRow(code: 'PR1001', name: '科研训练', credits: 3.0)],
        ),
        PdfModuleSection(
          title: '学科竞赛',
          level: 2,
          creditsRaw: '8',
          parentPath: '科研实践',
          courses: [PdfCourseRow(code: 'PR2002', name: '竞赛实践', credits: 2.0)],
        ),
      ]);
      final p = planFileFromPdf(ps, major: 'm', grade: '2026');
      final modules = (p['modules'] as List).cast<Map<String, dynamic>>();
      expect(modules.map((m) => m['module_id']), ['sec0-科研实践', 'sec1-学科竞赛']);
      // 父板块要求 = 直属课程和（3.0），不照抄含子板块的标注 30；子板块 8.0 照常
      expect(moduleOf(p, 'sec0-科研实践')['required_credits'], 3.0);
      expect(moduleOf(p, 'sec1-学科竞赛')['required_credits'], 8.0);
      // 总和 11 = 3 + 8，无重复计费；quality 如实说明混合口径
      final meta = p['meta'] as Map<String, dynamic>;
      expect(meta['total_credits'], 11.0);
      expect((meta['quality'] as List)
          .any((q) => q.toString().contains('科研实践') && q.contains('直属课程')), isTrue);
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
      // 未显式给 totalCredits：保留模块要求之和（思政类14+通识选修3+集中实践14），
      // 与 AuditEngine totals.required 严格同口径
      expect(meta['total_credits'], 31.0);
      final quality = (meta['quality'] as List).cast<String>();
      expect(quality, contains('PDF 第 3 页表格识别存在折行'));
      expect(quality.any((q) => q.contains('叶子优先')), isTrue);
      expect(quality.any((q) => q.contains('3 个板块 / 2 门课程')), isTrue);
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
      final mods = (p['modules'] as List).cast<Map<String, dynamic>>();
      expect(mods.map((m) => m['module_id']).toList(), ['sec0-必修课程']);
      // 同路径重复板块合并为一个，课程全部归入该模块，required 取较大声明值。
      expect(mods.single['required_credits'], 12.0);
      expect(mods.single['course_ids'], containsAll(['A1001', 'B1002']));
      expect(courseOf(p, 'A1001')['module_id'], 'sec0-必修课程');
      expect(courseOf(p, 'B1002')['module_id'], 'sec0-必修课程');
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
      expect(summary.length, 3); // 叶子优先后：思政类 / 通识选修 / 集中实践

      final sizheng = summary.firstWhere((s) => s['module_id'] == 'sec2-思政类');
      expect(sizheng['required'], 14.0);
      expect(sizheng['earned'], 4.0); // 两门均已通过，计入所在板块
      expect(sizheng['gap'], 10.0);
      expect(sizheng['color'], isNot('green'));
      final totals = report['totals'] as Map;
      expect(totals['earned'], 4.0);
      // 重复计费修复（用户反馈「三色学分重复计费」）：
      // 旧口径 totals.required = 72.5+62+14+3+14 = 165.5（父子板块都计）；
      // 叶子优先后 = 14+3+14 = 31，且与 meta.total_credits 严格同口径
      expect(totals['required'], 31.0);
      expect(totals['required'], (plan['meta'] as Map)['total_credits']);
      expect(report['trace'], isNotNull);
    });

    test('AuditEngine 集成：totals.required 不超方案声明总学分（容差 +2 说明见下）', () {
      // 声明总学分 165 模拟教务口径（各板块标注之和/最低毕业学分，天然含父子包含
      // 关系，旧口径会把它计成 162.5+ 还叠加）。叶子优先后 required = 14 远小于它。
      // 容差 +2 的解释：板块学分取标注首数字段下限（'3-6'→3）可能比教务声明口径
      // 略小；混合父板块按直属课程和计也可能与声明略有出入——审计只应「不超过
      // 声明太多」，超出即意味着仍在重复计费。
      final plan = planFileFromPdf(threeLevelSections,
          major: 'm', grade: '2026', totalCredits: 165.0);
      final report = AuditEngine({}).build(<String, dynamic>{
        'student': {'major': 'm', 'grade': '2026', 'current_semester': '2026-A'},
        'courses': [
          {'course_id': 'MARX1004G', 'name': '大学生思想文化素养', 'credits': 2.0, 'semester': '2026-A', 'grade': 88},
          {'course_id': 'MARX1006G', 'name': '马克思主义基本原理', 'credits': 1.0, 'semester': '2026-A', 'grade': 85},
          {'course_id': 'MARX2005G', 'name': '中国共产党历史与理论', 'credits': 1.0, 'semester': '2026-B', 'grade': 90},
        ],
      }, plan);
      final totals = report['totals'] as Map;
      expect(totals['required'], 14.0); // 12 + 2，叶子板块之和
      expect(totals['earned'], 4.0);
      expect(totals['required'], lessThanOrEqualTo(165.0 + 2.0));
      // 三色 summary 只含叶子板块，无父板块行
      final paths = (report['summary'] as List)
          .map((s) => (s as Map)['module_path'])
          .toList();
      expect(paths, isNot(contains('通识课程')));
      expect(paths, isNot(contains('通识课程 · 通识必修课程')));
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

  // ── 「门」规则板块（#12 尾）：门数不是学分，不得污染 totals.required ──────
  group('「门」规则板块不污染审计学分（#12 尾）', () {
    /// 任务给定的合成场景：父板块 10.5 学分 + 3 条门规则
    /// （2 条 0 课程、1 条挂 4 门各 1.5 学分课程，仿真实「博雅技艺/大学写作」规则）。
    const countRuleSections = PlanPdfSections(sections: [
      PdfModuleSection(title: '通识选修课程', level: 2, creditsRaw: '10.5'),
      PdfModuleSection(
          title: '至少修读1门通识核心课程',
          level: 4,
          creditsRaw: '1',
          creditsUnit: '门',
          parentPath: '通识选修课程'),
      PdfModuleSection(
          title: '理工农医学生在四类中至少修读2门',
          level: 4,
          creditsRaw: '2',
          creditsUnit: '门',
          parentPath: '通识选修课程'),
      PdfModuleSection(
          title: '至少修读1门“博雅技艺”类课程',
          level: 4,
          creditsRaw: '1',
          creditsUnit: '门',
          parentPath: '通识选修课程',
          courses: [
            PdfCourseRow(code: 'PHIL0701G', name: '大学写作——写作・人', credits: 1.5),
            PdfCourseRow(code: 'PHIL0702G', name: '大学写作——写作・自然', credits: 1.5),
            PdfCourseRow(code: 'PHIL0703G', name: '大学写作——写作・社会', credits: 1.5),
            PdfCourseRow(code: 'PHIL0704G', name: '大学写作——创意写作', credits: 1.5),
          ]),
    ]);

    test('keptSectionFlags：门规则板块一律不保留，父板块成为有效叶子', () {
      expect(keptSectionFlags(countRuleSections), [true, false, false, false]);
    });

    test('门数不计入 required：totals 只剩父板块标注的 10.5，绝不 10.5+1+2+6', () {
      final p = planFileFromPdf(countRuleSections, major: 'm', grade: '2026');
      final modules = (p['modules'] as List).cast<Map<String, dynamic>>();
      // 0 课程门规则板块不成模块（修复前会以 required=1/2 计入并恒报红）；
      // 带课表门规则板块的课程并入父板块，门规则本身 0 学分要求
      expect(modules.map((m) => m['module_id']), ['sec0-通识选修课程']);
      expect(moduleOf(p, 'sec0-通识选修课程')['required_credits'], 10.5);
      expect((p['meta'] as Map)['total_credits'], 10.5);
      expect((p['courses'] as List).length, 4);
      expect(courseOf(p, 'PHIL0701G')['module_id'], 'sec0-通识选修课程');
    });

    test('AuditEngine 集成：totals.required == 父板块标注，不因门规则虚增', () {
      final p = planFileFromPdf(countRuleSections, major: 'm', grade: '2026');
      final report = AuditEngine({}).build(<String, dynamic>{
        'student': {'major': 'm', 'grade': '2026', 'current_semester': '2026-A'},
        'courses': [
          {'course_id': 'PHIL0702G', 'name': '大学写作——写作・自然', 'credits': 1.5, 'grade': 88},
        ],
      }, p);
      final totals = report['totals'] as Map;
      // 关键不变式：门规则板块不得使 totals.required 高于父板块标注 10.5
      //（修复前 = 1+2+1 = 4 的门数假学分；若按课程和计要求则会虚增到 10.5+6）
      expect(totals['required'], 10.5);
      expect(totals['earned'], 1.5);
      expect(totals['required'], (p['meta'] as Map)['total_credits']);
    });

    test('0 课程的门规则板块不产生幽灵模块', () {
      const ps = PlanPdfSections(sections: [
        PdfModuleSection(title: '通识选修课程', level: 2, creditsRaw: '10.5'),
        PdfModuleSection(
            title: '至少修读1门通识核心课程',
            level: 4,
            creditsRaw: '1',
            creditsUnit: '门',
            parentPath: '通识选修课程'),
        PdfModuleSection(
            title: '四类中至少修读2门',
            level: 4,
            creditsRaw: '2',
            creditsUnit: '门',
            parentPath: '通识选修课程'),
      ]);
      final p = planFileFromPdf(ps, major: 'm', grade: '2026');
      expect((p['modules'] as List).length, 1);
      expect((p['meta'] as Map)['total_credits'], 10.5);
    });

    test('上级板块不可用时：门规则板块自建 required 0 模块，课程不丢', () {
      const ps = PlanPdfSections(sections: [
        PdfModuleSection(title: '通识选修课程', level: 2, creditsRaw: '10.5'),
        // 兄弟叶子带课表且保留 → 父板块有被保留后代，自身被丢弃
        PdfModuleSection(
            title: '选修课程',
            level: 3,
            creditsRaw: '2',
            parentPath: '通识选修课程',
            courses: [PdfCourseRow(code: 'X1001', name: '甲课', credits: 2.0)]),
        PdfModuleSection(
            title: '至少修读1门耕读课程',
            level: 4,
            creditsRaw: '1',
            creditsUnit: '门',
            parentPath: '通识选修课程',
            courses: [PdfCourseRow(code: 'G1001', name: '耕读课', credits: 1.5)]),
      ]);
      final p = planFileFromPdf(ps, major: 'm', grade: '2026');
      final modules = (p['modules'] as List).cast<Map<String, dynamic>>();
      expect(modules.map((m) => m['module_id']),
          ['sec1-选修课程', 'sec2-至少修读1门耕读课程']);
      // 自建模块 required 0（门数绝不当学分），count_rule 标记如实
      expect(moduleOf(p, 'sec2-至少修读1门耕读课程')['required_credits'], 0.0);
      expect(moduleOf(p, 'sec2-至少修读1门耕读课程')['count_rule'], isTrue);
      expect(courseOf(p, 'G1001')['module_id'], 'sec2-至少修读1门耕读课程');
      final total = modules.fold<double>(
          0, (a, m) => a + (m['required_credits'] as num).toDouble());
      expect(total, 2.0); // 仅兄弟叶子板块的 2 学分，门数未计入
    });
  });

  // ── 认定类板块（#13）：美育/劳育/创新创业/心理健康 ─────────────────────────
  group('认定类板块保留为模块并计 earned（#13）', () {
    /// 仿真实 PDF「五、其他必修环节（认定型学分）」：四类板块均无课程表，
    /// 说明文本抽自真实方案（劳育为「32学时」非学分）。
    const certifiedSections = PlanPdfSections(sections: [
      PdfModuleSection(title: '其他必修环节（认定型学分）', level: 1),
      PdfModuleSection(
          title: '美育类',
          level: 3,
          parentPath: '其他必修环节（认定型学分）',
          notes: [
            '要求学生修读2学分美育类课程。可修读通识选修课程中的“文艺审美”类课程，'
                '详见本科生院公布的美育类课程清单。'
          ]),
      PdfModuleSection(
          title: '劳育类',
          level: 3,
          parentPath: '其他必修环节（认定型学分）',
          notes: ['要求学生修读32学时劳动教育类课程，详见本科生院公布的劳动教育类课程清单。']),
      PdfModuleSection(
          title: '创新创业类',
          level: 3,
          parentPath: '其他必修环节（认定型学分）',
          notes: ['要求学生修读2学分创新创业类课程，详见本科生院公布的创新创业类课程清单。']),
      PdfModuleSection(
          title: '心理健康类',
          level: 3,
          parentPath: '其他必修环节（认定型学分）',
          notes: ['要求学生修读2学分心理健康类课程，详见本科生院公布的心理健康类课程清单。']),
    ]);

    final transcript = <Map<String, dynamic>>[
      {'course_id': 'PSY1001', 'name': '大学生心理适应与发展', 'credits': 1.0, 'grade': 92},
      {'course_id': 'CS1001', 'name': '方案外普通课', 'credits': 2.0, 'grade': 80},
    ];

    test('无课无学分标注的认定板块保留为模块，required 取说明「修读N学分」', () {
      final p = planFileFromPdf(certifiedSections,
          major: 'm', grade: '2026', transcript: transcript);
      final modules = (p['modules'] as List).cast<Map<String, dynamic>>();
      // 父板块（无标注无课、非认定）仍丢弃；四个认定板块保留
      expect(modules.map((m) => m['module_id']),
          ['sec1-美育类', 'sec2-劳育类', 'sec3-创新创业类', 'sec4-心理健康类']);
      expect(moduleOf(p, 'sec1-美育类')['required_credits'], 2.0);
      expect(moduleOf(p, 'sec2-劳育类')['required_credits'], 0.0); // 32学时≠学分
      expect(moduleOf(p, 'sec3-创新创业类')['required_credits'], 2.0);
      expect(moduleOf(p, 'sec4-心理健康类')['required_credits'], 2.0);
      expect(moduleOf(p, 'sec4-心理健康类')['certified_category'], '心理健康类');
      // module_path 末段 = 类别名（coursesCategoryMap/学分看板按末段取类别）
      expect(moduleOf(p, 'sec4-心理健康类')['module_path'],
          '其他必修环节（认定型学分） · 心理健康类');
    });

    test('transcript 未命中课程按 certifiedCategoryOf 挂进认定模块', () {
      final p = planFileFromPdf(certifiedSections,
          major: 'm', grade: '2026', transcript: transcript);
      final psych = courseOf(p, 'PSY1001');
      expect(psych['module_id'], 'sec4-心理健康类');
      expect(psych['credits'], 1.0);
      // 非认定类的方案外课不挂，保持「未匹配」如实呈现
      expect((p['courses'] as List).where((c) => c['course_id'] == 'CS1001'),
          isEmpty);
    });

    test('AuditEngine 集成：心理健康类 earned 累加、totals 含认定要求', () {
      final p = planFileFromPdf(certifiedSections,
          major: 'm', grade: '2026', transcript: transcript);
      final report = AuditEngine({}).build(<String, dynamic>{
        'student': {'major': 'm', 'grade': '2026', 'current_semester': '2026-A'},
        'courses': [
          {'course_id': 'PSY1001', 'name': '大学生心理适应与发展', 'credits': 1.0, 'grade': 92},
          {'course_id': 'CS1001', 'name': '方案外普通课', 'credits': 2.0, 'grade': 80},
        ],
      }, p);
      final summary =
          (report['summary'] as List).cast<Map<String, dynamic>>();
      final psych = summary.firstWhere((s) => s['module_id'] == 'sec4-心理健康类');
      expect(psych['required'], 2.0);
      expect(psych['earned'], 1.0); // 核心诉求：认定类模块 earned > 0
      final totals = report['totals'] as Map;
      // required = 美育2 + 劳育0 + 创新创业2 + 心理健康2 = 6（此前认定要求整体缺失）
      expect(totals['required'], 6.0);
      expect(totals['earned'], 1.0);
      final extra =
          (report['extra_courses'] as List).cast<Map<String, dynamic>>();
      expect(extra.map((e) => e['course_id']), ['CS1001']);
    });

    test('transcript 缺省（默认空）不挂课，认定模块仍保留', () {
      final p = planFileFromPdf(certifiedSections, major: 'm', grade: '2026');
      expect((p['courses'] as List), isEmpty);
      expect((p['modules'] as List).length, 4);
    });
  });

  // ── 用户反馈 #3/#4：多选一 & 并列模块不重复计分 ─────────────────────────
  group('多选一与并列模块（#3/#4）', () {
    test('detectChoiceRule：多选一 / 任选其一 → 单门成组', () {
      final r1 = detectChoiceRule('本组课程多选一，修读1门即满足本组要求。');
      expect(r1, isNotNull);
      expect(r1!.minCourses, 1);
      expect(r1.singlePick, isTrue);
      final r2 = detectChoiceRule('以下课程任选其一即可。');
      expect(r2, isNotNull);
      expect(r2!.singlePick, isTrue);
      // 反例：任意选修不是数量约束
      expect(detectChoiceRule('任意选修课程均可计入。'), isNull);
    });

    test('detectAlternativeModules：模块级任选其一', () {
      const kids = [
        PdfModuleSection(title: '本专业进阶模块', level: 2),
        PdfModuleSection(title: '跨专业学习模块（微辅修）', level: 2),
        PdfModuleSection(title: '学生自主修读模块', level: 2),
      ];
      final s = detectAlternativeModules(
          kids, '以下三个模块中任选其一，满足其一即可认定。');
      expect(s, isNotNull);
      expect(s!.optionCount, 3);
      // 课程级「多选一」不能升级成模块级并列（无「模块」二字）
      expect(detectAlternativeModules(const [], '本组课程多选一'), isNull);
    });

    const personality = PlanPdfSections(sections: [
      PdfModuleSection(title: '个性修读课程', level: 1, creditsRaw: '20'),
      PdfModuleSection(
        title: '本专业进阶模块',
        level: 2,
        creditsRaw: '20',
        parentPath: '个性修读课程',
        courses: [PdfCourseRow(code: 'A1001', name: '进阶课', credits: 20)],
      ),
      PdfModuleSection(
        title: '跨专业学习模块（微辅修）',
        level: 2,
        creditsRaw: '20',
        parentPath: '个性修读课程',
        notes: ['以下三个模块中任选其一，满足其一即可认定。'],
        courses: [PdfCourseRow(code: 'B1002', name: '跨专业课', credits: 20)],
      ),
      PdfModuleSection(
        title: '学生自主修读模块',
        level: 2,
        creditsRaw: '20',
        parentPath: '个性修读课程',
        courses: [PdfCourseRow(code: 'C1003', name: '自主课', credits: 20)],
      ),
    ]);

    test('并列模块：只生成一组、总要求 20 而非 60', () {
      final p = planFileFromPdf(personality, major: 'm', grade: '2026');
      final mods = (p['modules'] as List).cast<Map<String, dynamic>>();
      expect(mods.length, 3);
      for (final m in mods) {
        expect(m['counts_toward_totals'], isFalse);
        expect(m['alternative_group_id'], isNotNull);
      }
      final groups =
          (p['alternative_groups'] as List).cast<Map<String, dynamic>>();
      expect(groups.length, 1);
      expect(groups.single['required_credits'], 20.0);
      expect((groups.single['options'] as List).length, 3);
      expect((p['meta'] as Map)['total_credits'], 20.0);
    });

    test('并列模块接入审计：任一选项达成即整组绿，totals 不重复计', () {
      final p = planFileFromPdf(personality, major: 'm', grade: '2026');
      final report = AuditEngine({}).build(<String, dynamic>{
        'student': {
          'major': 'm',
          'grade': '2026',
          'current_semester': '2026-A',
        },
        'courses': [
          {
            'course_id': 'A1001',
            'name': '进阶课',
            'credits': 20.0,
            'semester': '2026-A',
            'grade': 90,
          },
        ],
      }, p);
      final summary = (report['summary'] as List).cast<Map<String, dynamic>>();
      expect(summary.length, 1);
      final g = summary.single;
      expect(g['alternative_group'], isTrue);
      expect(g['required'], 20.0);
      expect(g['earned'], 20.0);
      expect(g['gap'], 0.0);
      expect(g['color'], 'green');
      expect((report['totals'] as Map)['required'], 20.0);
      expect((report['totals'] as Map)['gap'], 0.0);
    });

    test('多选一：要求按最便宜一门折算，选一门即达成', () {
      const ps = PlanPdfSections(sections: [
        PdfModuleSection(title: '通识选修课程', level: 1, creditsRaw: '10.5'),
        PdfModuleSection(
          title: '通识核心课程组',
          level: 2,
          creditsRaw: '8',
          parentPath: '通识选修课程',
          notes: ['本组课程多选一，修读1门即满足本组要求。'],
          courses: [
            PdfCourseRow(code: 'C1', name: '甲', credits: 2),
            PdfCourseRow(code: 'C2', name: '乙', credits: 2),
            PdfCourseRow(code: 'C3', name: '丙', credits: 2),
            PdfCourseRow(code: 'C4', name: '丁', credits: 2),
          ],
        ),
      ]);
      final p = planFileFromPdf(ps, major: 'm', grade: '2026');
      final m = moduleOf(p, 'sec1-通识核心课程组');
      expect(m['required_credits'], 2.0);
      expect((m['choice_rule'] as Map)['single_pick'], isTrue);
      final report = AuditEngine({}).build(<String, dynamic>{
        'student': {
          'major': 'm',
          'grade': '2026',
          'current_semester': '2026-A',
        },
        'courses': [
          {
            'course_id': 'C1',
            'name': '甲',
            'credits': 1.0,
            'semester': '2026-A',
            'grade': 85,
          },
        ],
      }, p);
      final row = ((report['summary'] as List).cast<Map<String, dynamic>>())
          .firstWhere((r) => r['module_id'] == 'sec1-通识核心课程组');
      expect(row['gap'], 0.0);
      expect(row['color'], 'green');
    });

    test('混合父板块：子板块认领课程后父板块不再重复要求', () {
      const ps = PlanPdfSections(sections: [
        PdfModuleSection(
          title: '通识选修课程',
          level: 1,
          creditsRaw: '10.5',
          courses: [
            PdfCourseRow(code: 'C1', name: '甲', credits: 2),
            PdfCourseRow(code: 'C2', name: '乙', credits: 2),
          ],
        ),
        PdfModuleSection(
          title: '博雅技艺',
          level: 2,
          creditsRaw: '4',
          parentPath: '通识选修课程',
          courses: [
            PdfCourseRow(code: 'C1', name: '甲', credits: 2),
            PdfCourseRow(code: 'C2', name: '乙', credits: 2),
          ],
        ),
      ]);
      final p = planFileFromPdf(ps, major: 'm', grade: '2026');
      final mods = (p['modules'] as List).cast<Map<String, dynamic>>();
      expect(mods.map((m) => m['module_id']), ['sec1-博雅技艺']);
      expect(mods.single['required_credits'], 4.0);
      expect((p['meta'] as Map)['total_credits'], 4.0);
    });
  });
}
