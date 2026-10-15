// 冒烟测试：底部导航四页渲染 + 样例审计全流程（设置页运行 → 自动切审计页出报告）。
// 引擎逻辑的完整覆盖见 engine_test/analytics/exam/course_marks/request_throttle 等
// （83 项纯 Dart 单测，dart test 可跑）。
//
// 可测性注意：App 的 initState 与"运行样例审计"都经 rootBundle 真实 IO 加载资产。
// flutter_test 主体跑在 FakeAsync（fake clock）下，不投递真实 I/O 完成回调，会把
// 永久 pending 的 Future 写进全局 rootBundle 字符串缓存并毒化后续所有用例。
// 样例流程整体放进 runAsync（真实时钟 + 真实 delay），彻底规避 fake clock 的 IO 问题。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/main.dart';

/// 测试环境无原生插件，mock 路径通道避免 MissingPluginException。
void _mockPlatformChannels() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pp = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pp, (call) async => null);
}

void main() {
  _mockPlatformChannels();

  testWidgets('四页导航渲染（课舟）', (tester) async {
    // 真实时钟下完成资产加载，避免 pending 缓存毒化后续用例。
    await tester.runAsync(() async {
      await tester.pumpWidget(const KeZhouApp());
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });

    // 应用名"课舟"只在窗口 titlebar 与设置页版本号中出现，不作为渲染断言；
    // 底部导航四个 tab + 学业页空态即为渲染正确性的证据。
    expect(find.text('学业'), findsOneWidget);
    expect(find.text('审计'), findsOneWidget);
    expect(find.text('工具'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    // 学业页空态引导
    expect(find.text('暂无学业数据'), findsOneWidget);
  });

  testWidgets('样例审计全流程：设置页运行 → 自动切审计页', (tester) async {
    // 全程真实时钟：rootBundle IO 走真 HttpClient，真实 delay 驱动加载与状态更新。
    // 报告是 ListView 懒加载，默认 600 高视口只构建折叠线以上的模块瓦片，
    // "风险提示"/免责声明在下方未构建——撑高 surface 让整份报告一次渲染。
    await tester.binding.setSurfaceSize(const Size(1200, 4000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(const KeZhouApp());
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // 切到"设置"
      await tester.tap(find.text('设置'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // 点"运行样例审计"，轮询直到审计页报告出现（上限 5s）。
      await tester.tap(find.text('运行样例审计'));
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
        if (find.textContaining('三色学分达成度').evaluate().isNotEmpty) break;
      }

      // 自动切到审计页：报告主体出现
      expect(find.textContaining('三色学分达成度'), findsOneWidget);
      expect(find.textContaining('风险提示'), findsOneWidget);
      expect(find.textContaining('仅供与导师沟通参考'), findsOneWidget);
    });

    // 学业页有数据：切过去看 GPA 卡 + 成绩详情入口
    await tester.tap(find.text('学业'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('成绩'), findsOneWidget);
    expect(find.text('五分制'), findsOneWidget);
    expect(find.text('点击查看各学期成绩明细'), findsOneWidget);

    // 点成绩卡进详情页（按学期分组）
    await tester.tap(find.text('成绩'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('成绩明细'), findsOneWidget);
    expect(find.textContaining('秋季'), findsWidgets);
  });
}
