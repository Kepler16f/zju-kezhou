// test/minor_plan_page_test.dart — 微辅修独立页测试。
//
// 说明：已登录取数链路依赖真实教务网（ZjuClient 为具体类，不便伪造），
// 故页面级测试只覆盖未登录引导与已登录静态骨架（不触发任何请求）；
// 「从方案板块里挑出微辅修相关板块」的核心逻辑在 minor_plan_page.dart
// 里以纯函数 pickMinorSections 导出，在此用合成数据单测（含
// 「微辅修：N学分」冒号板块 + 普通板块 + 辅修板块，断言只选出微辅修相关）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/credential_store.dart';
import 'package:compass_app/data/plan_pdf_parse.dart';
import 'package:compass_app/data/zju_client.dart';
import 'package:compass_app/pages/minor_plan_page.dart';

void main() {
  group('pickMinorSections（纯函数）', () {
    test('合成方案：只挑出「微辅修」支，主修与辅修不混入', () {
      const text = '''
课程设置与学分分布
一、通识课程                72.5学分
1.通识必修课程              62学分
课程号 课程名称 学分 周学时 总学时 建议学年学期
MARX1004G 大学生思想文化素养 2.0 2.0-0.0 32 一(秋冬)
二、专业课程                40.5学分
(1)专业必修课程                24.5学分
课程号 课程名称 学分 周学时 总学时 建议学年学期
BEFS1039M 食品科学导论 1.5 1.5-0.0 24 一(夏)
辅修培养方案：
微辅修：12.5学分
A.跨专业课程至少1门
课程号 课程名称 学分 周学时 总学时 建议学年学期
IMIN1001G 微辅修课程甲 2.5 2.0-0.0 40 一(秋冬)
IMIN1002G 微辅修课程乙 3.0 3.0-0.0 48 二(春夏)
辅修：25学分
课程号 课程名称 学分 周学时 总学时 建议学年学期
IMAJ1001G 辅修课程丙 3.0 3.0-0.0 48 二(秋冬)
''';
      final parsed = parsePlanPdfText(text);
      // 前置确认：合成文本确实解析出了微辅修（冒号式）与辅修两条同级板块
      expect(parsed.sections.map((s) => s.title), containsAll(['微辅修', '辅修']));

      final minors = pickMinorSections(parsed.sections);
      expect(minors.map((s) => s.title).toList(), ['微辅修']);
      expect(minors.single.creditsRaw, '12.5');
      expect(minors.single.courses.map((c) => c.code).toList(),
          ['IMIN1001G', 'IMIN1002G']);
      // 「辅修：25学分」一支（含其课程）绝不混入
      expect(minors.single.courses.map((c) => c.name),
          isNot(contains('辅修课程丙')));
      expect(minors.single.courses.map((c) => c.name),
          isNot(contains('大学生思想文化素养')));
    });

    test('构造板块：锚点后的更深层级归该支；同层普通板块终止该支', () {
      final minors = pickMinorSections(const [
        PdfModuleSection(title: '通识课程', level: 1, creditsRaw: '72.5'),
        PdfModuleSection(title: '微辅修', level: 2, creditsRaw: '12.5'),
        PdfModuleSection(title: '必修课程', level: 3, creditsRaw: '10'),
        PdfModuleSection(title: '选修课程', level: 4, creditsRaw: '2.5'),
        PdfModuleSection(title: '辅修', level: 2, creditsRaw: '25'),
      ]);
      expect(minors.map((s) => s.title).toList(),
          ['微辅修', '必修课程', '选修课程']);
    });

    test('title/parentPath 含「微辅修」均命中（含变体命名）', () {
      final minors = pickMinorSections(const [
        PdfModuleSection(title: '计算机科学与技术微辅修', level: 2, creditsRaw: '15'),
        PdfModuleSection(
            title: '课程清单', level: 3, parentPath: '计算机科学与技术微辅修'),
        PdfModuleSection(title: '其他必修环节', level: 1),
      ]);
      expect(minors.map((s) => s.title).toList(),
          ['计算机科学与技术微辅修', '课程清单']);
    });

    test('空输入与不含微辅修的输入返回空', () {
      expect(pickMinorSections(const []), isEmpty);
      expect(
        pickMinorSections(const [
          PdfModuleSection(title: '通识课程', level: 1),
          PdfModuleSection(title: '专业课程', level: 1),
        ]),
        isEmpty,
      );
    });
  });

  group('MinorPlanPage 页面', () {
    MinorPlanPage page({
      required bool loggedIn,
      required VoidCallback onGoSettings,
    }) =>
        MinorPlanPage(
          client: ZjuClient(CredentialStore()),
          store: CredentialStore(),
          loggedIn: loggedIn,
          onGoSettings: onGoSettings,
          transcript: const [
            {'name': ' 大学生思想文化素养 ', 'credits': 2.0},
          ],
        );

    testWidgets('未登录：渲染引导与「去设置」，点击触发 onGoSettings', (tester) async {
      var goCount = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: page(loggedIn: false, onGoSettings: () => goCount++),
        ),
      ));
      expect(find.text('登录教务网后可查看其他专业的微辅修方案'), findsOneWidget);
      expect(find.text('去设置'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('去设置'));
      await tester.pump();
      expect(goCount, 1);
    });

    testWidgets('已登录：默认展示专业搜索区与说明，不自动发请求', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: page(loggedIn: true, onGoSettings: () {}),
        ),
      ));
      expect(find.byType(TextField), findsOneWidget);
      expect(find.textContaining('选择专业'), findsWidgets);
      expect(find.text('去设置'), findsNothing);
    });
  });
}
