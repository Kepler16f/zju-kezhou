// test/plan_page_course_state_test.dart — 方案课程修读状态三态标定纯函数小测
// （2026-10-18 需求 #3：把「成绩单里出现过就算已修」拆成
//   绿=已修完 / 蓝=在修 / 橙=有记录未获学分需重修 / 灰=未修未知）。
//
// 被测函数定义在 lib/pages/curriculum_plan_page.dart（依赖 material），
// 因此本文件属 Flutter 测试：不加入 .github/workflows/_engine-check.yml 的
// dart test 纯 Dart 白名单（同 plan_page_badges_test.dart），
// 由 `flutter test --no-pub` 全量覆盖。
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/pages/curriculum_plan_page.dart';

void main() {
  group('transcriptRowState：单条成绩单记录归类', () {
    test('通过且计学分 → earned（passed 字段优先，缺省按 grade≥60 判）', () {
      expect(
          transcriptRowState(
              {'passed': true, 'grade': 88, 'credit_included': true}),
          PlanCourseState.earned);
      expect(transcriptRowState({'grade': 88}), PlanCourseState.earned);
      // 词语分：及格（60）计学分 → earned（与引擎口径一致）。
      expect(transcriptRowState({'original': '及格', 'grade': 60}),
          PlanCourseState.earned);
    });

    test('待录 → active（在修未出分，不再混入已修）', () {
      expect(transcriptRowState(
          {'original': '待录', 'grade': 0, 'passed': false}),
          PlanCourseState.active);
    });

    test('未过/缺考/缓考/弃修/无效 → noCredit（有记录未获学分）', () {
      for (final o in ['不及格', '不合格', '缺考', '缓考', '弃修', '无效']) {
        expect(
            transcriptRowState({'original': o, 'grade': 0, 'passed': false}),
            PlanCourseState.noCredit,
            reason: o);
      }
      // 百分制未过（passed 缺省按分判）。
      expect(transcriptRowState({'grade': 55}), PlanCourseState.noCredit);
      expect(transcriptRowState({'original': 'F', 'grade': 0, 'passed': false}),
          PlanCourseState.noCredit);
    });

    test('通过但学分被排除（罕见数据）→ noCredit（未获学分）', () {
      expect(
          transcriptRowState(
              {'passed': true, 'grade': 90, 'credit_included': false}),
          PlanCourseState.noCredit);
    });

    test('无分数无已知标记 → null（宁缺勿猜）', () {
      expect(transcriptRowState({'original': '', 'grade': 0}), isNull);
      expect(transcriptRowState(const {}), isNull);
    });
  });

  group('collectPlanCourseEvidence：四数据源收集', () {
    test('成绩单逐行归类（earned/active/noCredit）', () {
      final ev = collectPlanCourseEvidence(transcript: [
        {'name': '数学分析', 'passed': true, 'grade': 90},
        {'name': '大学英语', 'original': '待录', 'grade': 0, 'passed': false},
        {'name': '大学物理', 'grade': 48},
        {'name': '', 'passed': true, 'grade': 90}, // 空名丢弃
      ]);
      expect(ev.earned, {'数学分析'});
      expect(ev.active, {'大学英语'});
      expect(ev.noCredit, {'大学物理'});
    });

    test('已选/课表 → active；报告 plan_courses 按 passed/record 归类', () {
      final ev = collectPlanCourseEvidence(
        choosedNames: ['数据结构', '  '],
        timetableNames: ['体育'],
        reportPlanCourses: [
          {'name': '高等数学', 'passed': true},
          {
            'name': '线性代数',
            'passed': false,
            'record': {'semester': '2025-A', 'grade': 40},
          },
          {
            'name': '程序设计',
            'passed': false,
            'record': {'semester': '2025-B', 'grade': 0}, // 0 分不猜
          },
          {'name': '', 'passed': true}, // 空名丢弃
        ],
      );
      expect(ev.active, {'数据结构', '体育'});
      expect(ev.earned, {'高等数学'});
      expect(ev.noCredit, {'线性代数'});
      expect(ev.earned.contains('程序设计'), isFalse);
      expect(ev.noCredit.contains('程序设计'), isFalse);
    });

    test('空输入不抛异常', () {
      final ev = collectPlanCourseEvidence();
      expect(ev.earned, isEmpty);
      expect(ev.active, isEmpty);
      expect(ev.noCredit, isEmpty);
    });
  });

  group('resolvePlanCourseStates：方案名 → 三态（全等 + 模糊 + 优先级）', () {
    test('earned > active > noCredit：已获学分不被「本学期重选」覆盖；'
        '未过的课本学期重修标在修', () {
      final ev = collectPlanCourseEvidence(
        transcript: [
          {'name': '数据结构', 'passed': true, 'grade': 85},
          {'name': '操作系统', 'grade': 40},
        ],
        choosedNames: ['数据结构', '操作系统'],
      );
      final states = resolvePlanCourseStates(['数据结构', '操作系统'], ev);
      expect(states['数据结构'], PlanCourseState.earned);
      expect(states['操作系统'], PlanCourseState.active);
    });

    test('noCredit 兜底：既非在修也未过的课标「未过需重修」', () {
      final ev = collectPlanCourseEvidence(transcript: [
        {'name': '大学物理', 'grade': 48},
      ]);
      final states = resolvePlanCourseStates(['大学物理'], ev);
      expect(states['大学物理'], PlanCourseState.noCredit);
    });

    test('模糊命中与原「已修」口径一致（≥0.85，2*6/(6+8)≈0.857）', () {
      final ev = collectPlanCourseEvidence(transcript: [
        {'name': '大学英语（II）', 'passed': true, 'grade': 80},
      ]);
      final states = resolvePlanCourseStates(['大学英语II'], ev);
      expect(states['大学英语II'], PlanCourseState.earned);
    });

    test('不同课程不误标；无证据 → unknown（宁缺勿猜）', () {
      final ev = collectPlanCourseEvidence(transcript: [
        {'name': '高等数学B', 'passed': true, 'grade': 80},
      ]);
      final states = resolvePlanCourseStates(['高等数学A', '量子计算'], ev);
      expect(states['高等数学A'], PlanCourseState.unknown); // 0.8 < 0.85
      expect(states['量子计算'], PlanCourseState.unknown);
    });

    test('报告证据可补成绩单缺名（引擎课号匹配过的结果）', () {
      final ev = collectPlanCourseEvidence(reportPlanCourses: [
        {'name': '量子计算导论', 'passed': true},
      ]);
      final states = resolvePlanCourseStates(['量子计算导论'], ev);
      expect(states['量子计算导论'], PlanCourseState.earned);
    });

    test('空方案名 → 空 map；有名字无证据 → 补 unknown（宁缺勿猜不丢弃）', () {
      expect(resolvePlanCourseStates(
          const <String>[], collectPlanCourseEvidence()), isEmpty);
      final states =
          resolvePlanCourseStates(['数据结构'], collectPlanCourseEvidence());
      expect(states['数据结构'], PlanCourseState.unknown);
    });
  });
}
