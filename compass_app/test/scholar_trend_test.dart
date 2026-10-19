// test/scholar_trend_test.dart — 学业页走势卡（五分制/可收起/学期短标签）冒烟
// + 快捷卡随滚动内容接入（诉求 #8）验证。
// 2026-10-19 需求：「成绩 / 工具」子选项卡下线，走势卡与 GPA 模拟器卡内联到
// 学业页「素拓看板」section 之后；走势展开态改由 ScholarPage 自身 State 持有，
// 不再需要（也不再有）IndexedStack 保活切换。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/pages/scholar_page.dart';
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

  group('ScholarPage 走势卡（内联）', () {
    testWidgets('走势默认收起，展开后出现五分制曲线；模拟器默认五分制口径',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 3200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(scholarHost());

      // 收起态：有标题无曲线；模拟器卡已内联（ExpansionTile 收起，不画内部控件）。
      expect(find.text('学期走势（五分制）'), findsOneWidget);
      expect(find.byType(TrendChart), findsNothing);
      expect(find.byType(GpaSimulatorCard), findsOneWidget);
      expect(find.text('目标反推：剩余 30 学分，想达到五分制 4.5'), findsNothing);

      // 点标题行展开走势（AnimatedSize 200ms）。
      await tester.tap(find.text('学期走势（五分制）'));
      await tester.pumpAndSettle();
      expect(find.byType(TrendChart), findsOneWidget);
      // 五分制数据点：23秋 4.80、24春 (4.5*3+5*2)/5=4.70。
      final chart = tester.widget<TrendChart>(find.byType(TrendChart));
      expect(chart.points.length, 2);
      expect(chart.points.first.label, '23秋');
      expect(chart.points.first.term, closeTo(4.8, 0.001));
      expect(chart.points.last.term, closeTo(4.7, 0.001));

      // 再点收起。
      await tester.tap(find.text('学期走势（五分制）'));
      await tester.pumpAndSettle();
      expect(find.byType(TrendChart), findsNothing);
    });

    testWidgets('走势展开态跨页签切换保活（学业页 State 常驻）',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 3200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(scholarHost());

      // 展开走势后模拟离开/回到学业页：ScholarPage 常驻主线 IndexedStack，
      // _trendOpen 随本页 State 保活，曲线不能丢。
      await tester.tap(find.text('学期走势（五分制）'));
      await tester.pumpAndSettle();
      expect(find.byType(TrendChart), findsOneWidget);
      await tester.pump();
      expect(find.byType(TrendChart), findsOneWidget);
    });
  });

  group('ScholarPage 素拓看板与工具卡内联（2026-10-19 需求）', () {
    testWidgets('「素拓看板」标题下内联渲染学期走势 + GPA 模拟器两张卡',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 3200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(scholarHost());

      // 子选项卡彻底下线：不再有 SegmentedButton / scholar-tab-* 入口。
      expect(find.byType(SegmentedButton<int>), findsNothing);
      expect(find.byKey(const Key('scholar-tab-grades')), findsNothing);
      expect(find.byKey(const Key('scholar-tab-tools')), findsNothing);

      // 改名后的 section 标题（原「课堂分（素拓）」）。
      expect(find.text('素拓看板'), findsOneWidget);
      expect(find.text('课堂分（素拓）'), findsNothing);

      // 两张工具卡内联在成绩 ListView 滚动内容里。
      expect(
          find.descendant(
              of: find.byType(ListView), matching: find.text('学期走势（五分制）')),
          findsOneWidget);
      expect(
          find.descendant(of: find.byType(ListView),
              matching: find.byType(GpaSimulatorCard)),
          findsOneWidget);

      // 顺序证据（宁缺勿猜地验证「素拓看板之后」）：纵向布局里
      // 走势卡标题应位于素拓看板标题之下、模拟器标题又在走势卡之下。
      final secY = tester
          .getTopLeft(find.text('素拓看板'))
          .dy;
      final trendY =
          tester.getTopLeft(find.text('学期走势（五分制）')).dy;
      final simY =
          tester.getTopLeft(find.text('GPA 模拟器')).dy;
      expect(trendY, greaterThan(secY));
      expect(simY, greaterThan(trendY));
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
