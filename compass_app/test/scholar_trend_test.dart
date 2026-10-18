// test/scholar_trend_test.dart — 工具页走势卡（五分制/可收起/学期短标签）冒烟
// + 学业页快捷卡随滚动内容接入（诉求 #8）验证。
// 2026-10-18 需求 #1：学期走势与 GPA 模拟器自学业页迁至独立「工具」页签。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/pages/scholar_page.dart';
import 'package:compass_app/pages/tools_page.dart';
import 'package:compass_app/widgets/gpa_simulator.dart';
import 'package:compass_app/widgets/line_chart.dart';

Map<String, dynamic> course(String name, double credits, double five,
        double grade, String sem) =>
    {
      'name': name, 'credits': credits, 'five_point': five, 'grade': grade,
      'semester': sem, 'category': '专业必修课', 'passed': true,
      'gpa_included': true, 'credit_included': true,
    };

/// 合成成绩单：两个学期、三门课（走势出现两个数据点）。
final syntheticCourses = [
  course('数据结构', 4, 4.8, 92, '2023-A'),
  course('操作系统', 3, 4.5, 85, '2023-B'),
  course('算法导论', 2, 5.0, 96, '2023-B'),
];

Widget trendHost() => MaterialApp(home: ToolsPage(courses: syntheticCourses));

Widget scholarHost() => MaterialApp(
    home: ScholarPage(
        courses: syntheticCourses, practice: const {}, exams: const []));

void main() {
  group('scholarTrendShortLabel 学期短标签（纯函数）', () {
    test('秋冬/春夏/短 缩写：年份后两位 + 季名首字', () {
      expect(scholarTrendShortLabel('2023-A'), '23秋');
      // 春夏在次年（'2023-B' 经 termCodeLabel → '2024春夏'）
      expect(scholarTrendShortLabel('2023-B'), '24春');
      // 小学期在学年末（'2022-C' → '2023短'）
      expect(scholarTrendShortLabel('2022-C'), '23短');
      expect(scholarTrendShortLabel('2023-C'), '24短');
    });
    test('解析不了宁缺勿猜：unknown 显示 ?，怪串原样', () {
      expect(scholarTrendShortLabel('unknown'), '?');
      expect(scholarTrendShortLabel('奇怪的输入'), '奇怪的输入');
    });
  });

  group('ToolsPage 走势卡', () {
    testWidgets('走势默认收起，展开后出现五分制曲线；模拟器默认五分制口径',
        (tester) async {
      // 拉高视口让 ListView 全部子项参与构建（走势卡在列表深处）。
      await tester.binding.setSurfaceSize(const Size(1080, 3200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(trendHost());

      // 可收起卡自带标题行（独立 SectionHeader 已移除）
      expect(find.text('学期走势（五分制）'), findsOneWidget);
      // 默认收起：曲线未构建
      expect(find.byType(TrendChart), findsNothing);
      // GPA 模拟器折叠标题默认五分制口径
      expect(find.byType(GpaSimulatorCard), findsOneWidget);
      expect(find.textContaining('当前五分制'), findsOneWidget);

      // 展开后曲线与图例出现
      await tester.tap(find.text('学期走势（五分制）'));
      await tester.pumpAndSettle();
      expect(find.byType(TrendChart), findsOneWidget);
      expect(find.text('累计 GPA'), findsOneWidget);
      expect(find.text('学期 GPA'), findsOneWidget);

      // 再点收起：曲线重新移出构建树
      await tester.tap(find.text('学期走势（五分制）'));
      await tester.pumpAndSettle();
      expect(find.byType(TrendChart), findsNothing);
    });

    testWidgets('学业页不再嵌走势与模拟器（需求 #1 迁出）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 3200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(scholarHost());
      expect(find.text('学期走势（五分制）'), findsNothing);
      expect(find.byType(GpaSimulatorCard), findsNothing);
    });
  });

  group('ScholarPage 快捷卡', () {
    testWidgets('快捷卡在 ListView 滚动内容内；窄屏（320 宽）不溢出',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(scholarHost());

      expect(tester.takeException(), isNull);
      // 快捷入口已是滚动内容（ListView 子树）的一部分，不再是固定列
      expect(
          find.descendant(
              of: find.byType(ListView), matching: find.text('培养方案')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(ListView), matching: find.text('我的课表')),
          findsOneWidget);
    });
  });
}
