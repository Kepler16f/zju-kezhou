// test/category_wiring_test.dart — 课程类别打通纯函数单测（学分看板「未分类」修复）。
// 纯 Dart（package:test），不依赖 Flutter 页面；main.dart 只调用 adapter 里的逻辑。
// 数据流：培养方案板块 module_path → matchRecordToPlan（与审计同口径）→
// tailCategory 末段 → applyPlanCategories 只补空 category（教务 kcxzmc 不动）。
import 'package:test/test.dart';

import 'package:compass_app/data/plan_pdf_parse.dart';
import 'package:compass_app/engine/plan_audit_adapter.dart';

void main() {
  group('tailCategory（module_path → 类别末段）', () {
    test('「 · 」全路径（PDF 适配器口径）取最后一段', () {
      expect(tailCategory('通识课程 · 通识必修课程 · 思政类'), '思政类');
      expect(tailCategory('通识课程 · 通识必修课程'), '通识必修课程');
      expect(tailCategory('集中实践环节'), '集中实践环节');
    });

    test('「/」路径（内置 golden 方案口径）同样切分', () {
      expect(tailCategory('通识教育/通识必修'), '通识必修');
      expect(tailCategory('专业教育/专业核心'), '专业核心');
      expect(tailCategory('任意选修'), '任意选修');
    });

    test('空 / 纯分隔符 / 首尾分隔符 → 宁缺勿猜（空串即保持「未分类」）', () {
      expect(tailCategory(''), '');
      expect(tailCategory('   '), '');
      expect(tailCategory('/'), '');
      expect(tailCategory(' · '), '');
      expect(tailCategory('通识课程 · '), '通识课程');
      expect(tailCategory('/通识必修/'), '通识必修');
    });
  });

  group('coursesCategoryMap / applyPlanCategories', () {
    // PDF 口径方案（经叶子优先取舍）：思政类（L3，直接挂课）与其子 L4 必修课程
    // 都保留——前者 module_path = '通识课程 · 通识必修课程'，后者再深一层。
    final pdfPlan = planFileFromPdf(
      const PlanPdfSections(sections: [
        PdfModuleSection(
          title: '思政类',
          level: 3,
          creditsRaw: '14',
          parentPath: '通识课程 · 通识必修课程',
          courses: [
            PdfCourseRow(code: 'MARX1004G', name: '大学生思想文化素养', credits: 2.0),
          ],
        ),
        PdfModuleSection(
          title: '必修课程',
          level: 4,
          creditsRaw: '12',
          parentPath: '通识课程 · 通识必修课程 · 思政类',
          courses: [
            PdfCourseRow(code: 'MARX1005G', name: '新时代实践教育', credits: 2.0),
          ],
        ),
      ]),
      major: 'm',
      grade: '2026',
    );

    test('成绩单行按 course_id 命中，补上方案板块末段类别', () {
      final rows = <Map<String, dynamic>>[
        {'course_id': 'MARX1004G', 'name': '大学生思想文化素养', 'credits': 2.0, 'grade': 90},
        {'course_id': 'MARX1005G', 'name': '新时代实践教育', 'credits': 2.0, 'grade': 88},
      ];
      expect(coursesCategoryMap(rows, pdfPlan), {
        // 新口径优先用模块 category 字段；两个板块都归属「思政类」。
        '大学生思想文化素养': '思政类',
        '新时代实践教育': '思政类',
      });

      final filled = applyPlanCategories(rows, pdfPlan);
      expect(filled, 2);
      expect(rows[0]['category'], '思政类');
      expect(rows[1]['category'], '思政类');
    });

    test('内置 golden 口径（/ 路径、无 title 字段）同样打通；名称相似度兜底', () {
      const goldenPlan = <String, dynamic>{
        'meta': {'major': 'm', 'grade': '2023'},
        'modules': [
          {'module_id': 'general_required', 'module_path': '通识教育/通识必修', 'required_credits': 34.0},
          {'module_id': 'major_core', 'module_path': '专业教育/专业核心', 'required_credits': 39.0},
        ],
        'courses': [
          {'course_id': 'GS1001', 'name': '思想道德与法治', 'credits': 3.0, 'module_id': 'general_required'},
          {'course_id': 'CS2001', 'name': '数据结构基础', 'credits': 4.5, 'module_id': 'major_core'},
        ],
      };
      final rows = <Map<String, dynamic>>[
        {'course_id': 'GS1001', 'name': '思想道德与法治', 'credits': 3.0, 'grade': 85},
        // 无 course_id：走 matchRecordToPlan 的名称相似度 ≥0.85 兜底（与审计同口径）
        {'name': '数据结构基础', 'credits': 4.5, 'grade': 91},
      ];
      final filled = applyPlanCategories(rows, goldenPlan);
      expect(filled, 2);
      expect(rows[0]['category'], '通识必修');
      expect(rows[1]['category'], '专业核心');
    });

    test('只补空值：教务自带 kcxzmc 绝不覆盖；「未分类」视同空可补', () {
      final rows = <Map<String, dynamic>>[
        {'course_id': 'MARX1004G', 'name': '大学生思想文化素养', 'credits': 2.0, 'grade': 90, 'category': '专业必修'},
        {'course_id': 'MARX1005G', 'name': '新时代实践教育', 'credits': 2.0, 'grade': 88, 'category': '未分类'},
        {'name': '大学生思想文化素养', 'credits': 2.0, 'grade': 77},
      ];
      final filled = applyPlanCategories(rows, pdfPlan);
      expect(filled, 2);
      expect(rows[0]['category'], '专业必修'); // 原值保留
      expect(rows[1]['category'], '思政类'); // 「未分类」→ 方案类别
      expect(rows[2]['category'], '思政类');
    });

    test('未匹配课程保持无类别；空 plan / 空课程 / 脏数据不抛异常', () {
      final rows = <Map<String, dynamic>>[
        {'name': '方案外语课', 'credits': 1.0, 'grade': 66},
        {'credits': 2.0, 'grade': 70}, // 无名称无课程号：过滤掉，不进匹配
      ];
      expect(coursesCategoryMap(rows, pdfPlan), isEmpty);
      expect(applyPlanCategories(rows, pdfPlan), 0);
      expect(rows[0].containsKey('category'), isFalse);
      expect(rows[1].containsKey('category'), isFalse);

      expect(applyPlanCategories(const [], pdfPlan), 0);
      expect(coursesCategoryMap(const [], const {}), isEmpty);
      expect(applyPlanCategories(const [], const {}), 0);
      // 方案缺 courses / modules / 形态不符 → 返回空映射，不抛
      expect(coursesCategoryMap(const [
        {'name': '任意课', 'grade': 80},
      ], const {
        'modules': '不是列表',
        'courses': null,
      }), isEmpty);
    });

    test('恢复会话场景：缓存行已带类别 → 不重复改写', () {
      final rows = <Map<String, dynamic>>[
        {'course_id': 'MARX1004G', 'name': '大学生思想文化素养', 'credits': 2.0, 'grade': 90, 'category': '通识必修课程'},
      ];
      expect(applyPlanCategories(rows, pdfPlan), 0);
      expect(rows[0]['category'], '通识必修课程');
    });
  });

  // ── 认定类关键词归类（#13）：词表/优先级见 lib/engine/plan_audit_adapter.dart ──
  group('certifiedCategoryOf（认定类课程关键词归类）', () {
    test('各类正例（词表源自真实方案说明文本）', () {
      // 心理健康
      expect(certifiedCategoryOf('大学生心理适应与发展'), '心理健康类');
      expect(certifiedCategoryOf('大学生心理健康教育'), '心理健康类');
      // 美育
      expect(certifiedCategoryOf('中国书法'), '美育类');
      expect(certifiedCategoryOf('音乐鉴赏'), '美育类');
      expect(certifiedCategoryOf('戏剧表演入门'), '美育类');
      expect(certifiedCategoryOf('美术基础'), '美育类');
      expect(certifiedCategoryOf('艺术与审美'), '美育类');
      expect(certifiedCategoryOf('舞蹈基础'), '美育类');
      // 劳育
      expect(certifiedCategoryOf('农事劳动实践'), '劳育类');
      expect(certifiedCategoryOf('中华农耕文明与耕读文化'), '劳育类');
      expect(certifiedCategoryOf('志愿服务'), '劳育类');
      expect(certifiedCategoryOf('专业实践劳动'), '劳育类');
      // 创新创业
      expect(certifiedCategoryOf('创新创业基础'), '创新创业类');
      expect(certifiedCategoryOf('创新训练计划'), '创新创业类');
      expect(certifiedCategoryOf('大创项目'), '创新创业类');
    });

    test('负例：普通课不误归（宁缺勿猜，裸「实践」太泛不收）', () {
      expect(certifiedCategoryOf('高等数学B'), isNull);
      expect(certifiedCategoryOf('大学英语II'), isNull);
      expect(certifiedCategoryOf('社会实践'), isNull); // 裸「实践」不收
      expect(certifiedCategoryOf('新时代实践教育'), isNull); // 思政课含「实践」不误伤
      expect(certifiedCategoryOf('生产实习'), isNull);
      expect(certifiedCategoryOf('概率论与数理统计'), isNull);
      expect(certifiedCategoryOf(''), isNull);
      expect(certifiedCategoryOf('   '), isNull);
    });

    test('多类同命中：心理健康 > 美育 > 创新创业 > 劳育（写死顺序可测）', () {
      expect(certifiedCategoryOf('心理健康与艺术鉴赏'), '心理健康类');
      expect(certifiedCategoryOf('艺术与创新创业'), '美育类');
      expect(certifiedCategoryOf('创新创业与志愿服务'), '创新创业类');
      expect(certifiedCategoryOf('劳动与农事'), '劳育类');
    });
  });

  group('applyPlanCategories 认定类第二路兜底（#13）', () {
    // 与上方 group 同口径的方案：仅思政类/必修课程两板块（含课表）。
    final smallPlan = planFileFromPdf(
      const PlanPdfSections(sections: [
        PdfModuleSection(
          title: '思政类',
          level: 3,
          creditsRaw: '14',
          parentPath: '通识课程 · 通识必修课程',
          courses: [
            PdfCourseRow(code: 'MARX1004G', name: '大学生思想文化素养', credits: 2.0),
          ],
        ),
      ]),
      major: 'm',
      grade: '2026',
    );

    test('未命中方案模块的行按 certifiedCategoryOf 补类别；命中行照旧', () {
      final rows = <Map<String, dynamic>>[
        {'course_id': 'MARX1004G', 'name': '大学生思想文化素养', 'credits': 2.0, 'grade': 90},
        {'name': '大学生心理适应与发展', 'credits': 1.0, 'grade': 92},
        {'name': '社会实践', 'credits': 1.0, 'grade': 85},
        {'name': '大学生心理适应与发展', 'credits': 1.0, 'grade': 60, 'category': '未分类'},
        {'name': '创新创业基础', 'credits': 2.0, 'grade': 88, 'category': '专业必修'},
      ];
      final filled = applyPlanCategories(rows, smallPlan);
      expect(filled, 3);
      expect(rows[0]['category'], '思政类'); // 方案模块命中（主路径）用 category 字段
      expect(rows[1]['category'], '心理健康类'); // 认定类兜底
      expect(rows[2].containsKey('category'), isFalse); // 负例不猜
      expect(rows[3]['category'], '心理健康类'); // 「未分类」视同空可补
      expect(rows[4]['category'], '专业必修'); // 教务自带类别绝不覆盖
    });
  });
}
