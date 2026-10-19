// test/plan_reveal_bar_test.dart — 方案页顶栏直达按钮（用户反馈 #9）。
//
// 锁定：报告存在时渲染「三色学分/风险提示」按钮；风险提示带条数角标；
// 点按 → 审计区展开且对应瓦片直接展开可见（长报告不再需要手动翻找）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/credential_store.dart';
import 'package:compass_app/data/zju_client.dart';
import 'package:compass_app/pages/curriculum_plan_page.dart';

final report = <String, dynamic>{
  'totals': {'required': 10, 'earned': 2, 'gap': 8},
  'summary': [
    <String, dynamic>{
      'module_id': 'm1',
      'module_path': '专业必修',
      'required': 10,
      'earned': 2,
      'gap': 8,
      'color': 'red',
      'plan_courses': const <Map<String, dynamic>>[],
      'course_stats': {'total': 0, 'passed': 0, 'pending': 0},
      'missing_courses': const <Map<String, dynamic>>[],
    },
  ],
  'warnings': [
    {'type': 'module_gap', 'level': 'red', 'text': '专业必修缺口 8 分', 'refs': []},
    {'type': 'offering_closed', 'level': 'yellow', 'text': '某课已停开', 'refs': []},
  ],
  'extra_courses': const <Map<String, dynamic>>[],
  'caliber_notes': const <String>[],
  'trace': {'plan': '测试方案', 'engine': 'v1.5'},
  'disclaimer': '测试免责声明',
};

void main() {
  Widget page() => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 2000,
            child: CurriculumPlanPage(
              client: ZjuClient(CredentialStore()),
              store: CredentialStore(),
              loggedIn: false,
              onGoSettings: () {},
              report: report,
            ),
          ),
        ),
      );

  testWidgets('报告存在：渲染两枚直达按钮，风险提示带条数角标', (tester) async {
    await tester.pumpWidget(page());
    await tester.pump();
    expect(find.text('三色学分'), findsOneWidget);
    expect(find.text('风险提示'), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // warnings 条数角标
  });

  testWidgets('点三色学分：审计区展开且达成度瓦片直接可见', (tester) async {
    await tester.pumpWidget(page());
    await tester.pump();
    // 初始：外层审计收起，达成度瓦片不在屏幕（children 未构建）
    expect(find.textContaining('绿=已获学分'), findsNothing);
    await tester.tap(find.text('三色学分'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.textContaining('三色学分达成度（1 个板块）'), findsOneWidget);
    expect(find.textContaining('绿=已获学分'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点风险提示：警告瓦片直接展开并显示警告内容', (tester) async {
    await tester.pumpWidget(page());
    await tester.pump();
    expect(find.textContaining('专业必修缺口 8 分'), findsNothing);
    await tester.tap(find.text('风险提示'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('风险提示（2 条）'), findsOneWidget);
    expect(find.textContaining('专业必修缺口 8 分'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无报告：不渲染直达按钮（空态不误导）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CurriculumPlanPage(
          client: ZjuClient(CredentialStore()),
          store: CredentialStore(),
          loggedIn: false,
          onGoSettings: () {},
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('三色学分'), findsNothing);
    expect(find.text('风险提示'), findsNothing);
  });
}
