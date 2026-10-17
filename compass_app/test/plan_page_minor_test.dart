// test/plan_page_minor_test.dart — 方案页小任务纯函数测试（任务包 A）。
//
// 顶部 group：板块课程 chips 的「已修」标亮打通（配合任务 5）——
// resolvePassedNames 除成绩单全等外，getCloseMatches 相似度 ≥0.85 也算已修；
// 后一 group：「微辅修」板块判据（任务 7，诉求 #10）。
//
// 两个函数均定义在 lib/pages/curriculum_plan_page.dart（依赖 material），
// 本文件属 Flutter 测试：不加入 dart test 纯 Dart 白名单，由
// `flutter test --no-pub` 全量覆盖（同 plan_page_badges_test.dart）。
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/plan_pdf_parse.dart';
import 'package:compass_app/engine/plan_audit_adapter.dart';
import 'package:compass_app/pages/curriculum_plan_page.dart';

void main() {
  group('resolvePassedNames：已修标定（全等 + 模糊 ≥0.85）', () {
    const transcript = {
      '大学英语（II）',
      '概率论与数理统计乙',
      '数据结构与算法',
      '高等数学B',
    };

    test('成绩单全等命中：照旧算已修（回归原行为）', () {
      expect(
        resolvePassedNames(['数据结构与算法', '高等数学B'], transcript),
        {'数据结构与算法', '高等数学B'},
      );
    });

    test('模糊命中：写法略有出入（全角括号/后缀）也算已修', () {
      // 全等不中，但相似度 2*6/(6+8) ≈ 0.857 ≥ 0.85。
      final out = resolvePassedNames(['大学英语II'], transcript);
      expect(out, contains('大学英语II'));
      // 成绩单名更长（如带班次后缀）同理命中：8/9 对 16/17 ≈ 0.941。
      expect(resolvePassedNames(['概率论与数理统计'], transcript),
          contains('概率论与数理统计'));
    });

    test('不同课程不误标（0.8 < 0.85、无公共主干），宁缺勿猜', () {
      // 「高等数学A」 vs 成绩单「高等数学B」：相似度 0.8，不命中。
      // 「数据结构」 vs 「线性代数」：几乎没有公共主干。
      final out = resolvePassedNames(['高等数学A', '数据结构'], transcript);
      expect(out, isEmpty);
    });

    test('保留方案侧原写法（trim 匹配但按原文查表）', () {
      const transcript2 = {'大学英语II'};
      final out = resolvePassedNames([' 大学英语II '], transcript2);
      expect(out, {' 大学英语II '});
    });

    test('空成绩单 / 空名单 / 空名 → 空集，不抛异常', () {
      expect(resolvePassedNames(['大学英语II'], const {}), isEmpty);
      expect(resolvePassedNames(const <String>[], transcript), isEmpty);
      expect(resolvePassedNames(['', '  '], transcript), isEmpty);
    });
  });

  group('isMinorElectiveSection：微辅修板块判据（任务 7）', () {
    test('标题含「微辅修」→ 命中', () {
      const s = PdfModuleSection(title: '微辅修课程', level: 2);
      expect(isMinorElectiveSection(s), isTrue);
    });

    test('上级链（parentPath）含「微辅修」→ 命中（子块随整支剔除）', () {
      const s = PdfModuleSection(
        title: '数字系统',
        level: 3,
        parentPath: '计算机微辅修 · 微辅修课程',
      );
      expect(isMinorElectiveSection(s), isTrue);
    });

    test('普通板块不命中', () {
      const s = PdfModuleSection(
        title: '通识必修课程',
        level: 2,
        parentPath: '通识课程',
      );
      expect(isMinorElectiveSection(s), isFalse);
    });
  });

  // ── 认定类板块「已修」标亮（#13）：判定与引擎适配器同源 ───────────────────
  group('certifiedCategoryOf：认定类课程归类（#13）', () {
    test('合成成绩单课例：大学生心理适应与发展 → 心理健康类', () {
      const transcript = ['大学生心理适应与发展'];
      expect(certifiedCategoryOf(transcript.first), '心理健康类');
    });

    test('四类各一正例 + 负例不误归', () {
      expect(certifiedCategoryOf('书法与篆刻'), '美育类');
      expect(certifiedCategoryOf('农事劳动实践'), '劳育类');
      expect(certifiedCategoryOf('创新创业基础'), '创新创业类');
      expect(certifiedCategoryOf('社会实践'), isNull); // 裸「实践」不收
      expect(certifiedCategoryOf('高等数学B'), isNull);
    });
  });

  group('certifiedRowsForSection：认定类板块从成绩单补「已修」chips（#13）', () {
    const transcript = [
      {'course_id': 'PSY1001', 'name': '大学生心理适应与发展', 'credits': 1.0},
      {'course_id': 'ART1001', 'name': '书法基础', 'credits': 1.5},
      {'name': '社会实践', 'credits': 1.0}, // 负例：不进任何认定类
    ];

    test('无课表认定板块：返回同类成绩单课程（用于标亮已修）', () {
      const sec = PdfModuleSection(
          title: '心理健康类', level: 3, parentPath: '其他必修环节（认定型学分）');
      final rows = certifiedRowsForSection(sec, transcript);
      expect(rows.map((r) => r.name), ['大学生心理适应与发展']);
      expect(rows.first.credits, 1.0);
      expect(rows.first.code, 'PSY1001');
    });

    test('板块自带课程表时不重复补（宁缺勿猜）', () {
      const sec = PdfModuleSection(
          title: '心理健康类',
          level: 3,
          courses: [PdfCourseRow(code: 'PSY2002', name: '心理健康导论', credits: 1.0)]);
      expect(certifiedRowsForSection(sec, transcript), isEmpty);
    });

    test('非认定板块 / 四级以下板块不补', () {
      const sec = PdfModuleSection(title: '思政类', level: 3);
      expect(certifiedRowsForSection(sec, transcript), isEmpty);
      const deep = PdfModuleSection(
          title: '心理健康类', level: 4, parentPath: '其他必修环节（认定型学分）');
      expect(certifiedRowsForSection(deep, transcript), isEmpty);
    });

    test('重修同名课去重；空成绩单安全', () {
      const sec = PdfModuleSection(title: '美育类', level: 3);
      const dup = [
        {'name': '书法基础', 'credits': 1.5},
        {'name': '书法基础', 'credits': 1.5},
      ];
      expect(certifiedRowsForSection(sec, dup).length, 1);
      expect(certifiedRowsForSection(sec, const []), isEmpty);
    });
  });
}
