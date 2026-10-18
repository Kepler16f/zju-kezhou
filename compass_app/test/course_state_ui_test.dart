// test/course_state_ui_test.dart — 选课页/审计报告三态 UI 回归。
//
// 状态口径与方案阅读页共用 engine/course_state.dart；本文件锁定：
//  * 选课气泡显示 已修/在修/未修、学分与类别；
//  * 在修课程点按提示“请勿重复选择”；
//  * 报告模块头显示在修学分，课程明细同样三态，earned/gap 不因在修改变。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/xk_models.dart';
import 'package:compass_app/engine/course_state.dart';
import 'package:compass_app/pages/course_select_page.dart';
import 'package:compass_app/widgets/report_view.dart';

void main() {
  group('三态文案与防重复提示', () {
    test('earned/active/noCredit/unknown → 已修/在修/未修/未修', () {
      expect(courseStateLabel(PlanCourseState.earned), '已修');
      expect(courseStateLabel(PlanCourseState.active), '在修');
      expect(courseStateLabel(PlanCourseState.noCredit), '未修');
      expect(courseStateLabel(PlanCourseState.unknown), '未修');
    });

    test('已修与在修都有防重复选择提示；未知不打扰', () {
      expect(courseRepeatHint(PlanCourseState.earned), contains('无需重复选择'));
      expect(courseRepeatHint(PlanCourseState.active), contains('请勿重复选择'));
      expect(courseRepeatHint(PlanCourseState.unknown), isNull);
    });
  });

  testWidgets('CourseBubble 显示三态标签、学分与类别', (tester) async {
    const course = XkCourse(
      kcmc: '数据结构',
      kch: 'CS101',
      xf: 3.5,
      categories: ['专业必修'],
    );
    for (final (state, label) in [
      (PlanCourseState.earned, '已修'),
      (PlanCourseState.active, '在修'),
      (PlanCourseState.unknown, '未修'),
    ]) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: CourseBubble(course: course, state: state),
            ),
          ),
        ),
      ));
      expect(find.text(label), findsOneWidget);
      expect(find.text('3.5 学分'), findsOneWidget);
      expect(find.text('专业必修'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('CourseBubble 在修课程点按触发回调', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CourseBubble(
          course: const XkCourse(kcmc: '大学物理', xf: 4),
          state: PlanCourseState.active,
          onTap: () => taps++,
        ),
      ),
    ));
    await tester.tap(find.byType(CourseBubble));
    await tester.pump();
    expect(taps, 1);
    expect(find.text('在修'), findsOneWidget);
  });

  testWidgets('ReportSection 模块头显示在修学分，课程行为三态', (tester) async {
    final report = <String, dynamic>{
      'totals': {'required': 10, 'earned': 2, 'gap': 8},
      'summary': [
        <String, dynamic>{
          'module_id': 'm1',
          'module_path': '专业必修',
          'title': '专业必修',
          'level': 2,
          'category': '专业',
          'plan_credits_raw': '10',
          'plan_credits_unit': '学分',
          'notes': const <String>[],
          'required': 10,
          'earned': 2,
          'gap': 8,
          'color': 'red',
          'plan_courses': [
            {
              'name': '已修课',
              'credits': 2,
              'passed': true,
              'terms': const <String>[],
              'closed': false,
              'page': 1,
            },
            {
              'name': '在修课',
              'credits': 3,
              'passed': false,
              'terms': const <String>[],
              'closed': false,
              'page': 1,
            },
            {
              'name': '未修课',
              'credits': 5,
              'passed': false,
              'terms': const <String>['2026-A'],
              'closed': false,
              'page': 1,
            },
          ],
          'course_stats': {'total': 3, 'passed': 1, 'pending': 2},
          'missing_courses': const <Map<String, dynamic>>[],
        },
      ],
      'warnings': const <Map<String, dynamic>>[],
      'extra_courses': const <Map<String, dynamic>>[],
      'caliber_notes': const <String>[],
      'trace': {'plan': '测试方案', 'engine': 'test'},
      'disclaimer': '测试免责声明',
    };
    const evidence = PlanCourseEvidence(
      earned: {'已修课'},
      active: {'在修课'},
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ReportSection(report: report, courseEvidence: evidence),
        ),
      ),
    ));

    await tester.tap(find.textContaining('三色学分达成度'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已修学分'), findsOneWidget);
    expect(find.textContaining('3（不计入已修）'), findsOneWidget);
    expect(find.text('8 分'), findsOneWidget);

    await tester.tap(find.text('专业必修'));
    await tester.pumpAndSettle();
    expect(find.text('已修'), findsOneWidget);
    expect(find.text('在修'), findsOneWidget);
    expect(find.text('未修'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
