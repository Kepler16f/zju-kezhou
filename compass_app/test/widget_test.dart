// 冒烟测试：底部导航六页渲染 + 样例审计全流程（设置页运行 → 自动切审计页出报告）
// + 选课页未登录引导与去设置跳转。
// 引擎逻辑的完整覆盖见 engine_test/analytics/exam/course_marks/request_throttle 等
// （纯 Dart 单测，dart test 可跑）。
//
// 可测性注意：App 的 initState 与"运行样例审计"都经 rootBundle 真实 IO 加载资产。
// flutter_test 主体跑在 FakeAsync（fake clock）下，不投递真实 I/O 完成回调，会把
// 永久 pending 的 Future 写进全局 rootBundle 字符串缓存并毒化后续所有用例。
// 样例流程整体放进 runAsync（真实时钟 + 真实 delay），彻底规避 fake clock 的 IO 问题。
//
// 断言作用域：IndexedStack 会构建全部子页，跨页共享的文案（如免责声明）必须用
// find.descendant 限定在目标页内断言，否则新增页面会撞挂既有用例（设计评审B）。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/main.dart';
import 'package:compass_app/pages/audit_page.dart';

/// 测试环境无原生插件，mock 路径通道避免 MissingPluginException。
void _mockPlatformChannels() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pp = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pp, (call) async => null);
}

void main() {
  _mockPlatformChannels();

  testWidgets('六页导航渲染（课舟）', (tester) async {
    // 真实时钟下完成资产加载，避免 pending 缓存毒化后续用例。
    await tester.runAsync(() async {
      await tester.pumpWidget(const KeZhouApp());
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });

    // 应用名"课舟"只在窗口 titlebar 与设置页版本号中出现，不作为渲染断言；
    // 底部导航 tab + 学业页空态即为渲染正确性的证据。
    expect(find.text('学业'), findsOneWidget);
    expect(find.text('审计'), findsOneWidget);
    expect(find.text('工具'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('选课'), findsOneWidget);
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

      // 自动切到审计页：报告主体出现（限定在本页内断言：选课页也含免责声明同款文案）
      Finder inAudit(Finder f) =>
          find.descendant(of: find.byType(AuditPage), matching: f);
      expect(inAudit(find.textContaining('三色学分达成度')), findsOneWidget);
      expect(inAudit(find.textContaining('风险提示')), findsOneWidget);
      expect(inAudit(find.textContaining('仅供与导师沟通参考')), findsOneWidget);
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

  testWidgets('选课页：未登录引导 → 去设置 → AI 组渲染', (tester) async {
    // 选课页在未登录时不联网（active 门控 + loggedIn 门控），本用例不触碰任何真实请求
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(const KeZhouApp());
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });

    await tester.tap(find.text('选课'));
    await tester.pump();
    await tester.pump();
    expect(find.text('登录教务网后可查看选课入口与课程'), findsOneWidget);
    expect(find.text('仅只读查询：不会进行任何选课/退课提交'), findsOneWidget);

    // 去设置页登录 → 跳到设置页
    await tester.tap(find.text('去设置页登录'));
    await tester.pump();
    await tester.pump();
    expect(find.text('运行样例审计'), findsOneWidget);

    // AI 解读组渲染（默认关闭态：标题 + 发送范围说明 + 提供方分段）
    expect(find.text('AI 解读'), findsOneWidget);
    expect(find.textContaining('只翻译，不替你做选择'), findsOneWidget);
    expect(find.textContaining('开启后仅发送'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
  });

  testWidgets('选课页：演示数据 → 汇总 → 建议卡（离线全流程，录屏场景 6 路径）', (tester) async {
    // 全程离线：演示数据来自 assets 样例，不触碰任何网络（演示模式守卫会拦截刷新类按钮）
    await tester.binding.setSurfaceSize(const Size(1400, 3600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(const KeZhouApp());
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      await tester.tap(find.text('选课'));
      await tester.pump();
      await tester.pump();

      // rootBundle 真实 IO 需在 runAsync 下完成
      await tester.tap(find.text('加载演示数据（合成样例）'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });

    // 主体渲染 + 演示数据标记（绝不能冒充教务实时数据）
    expect(find.text('课程选择'), findsOneWidget);
    expect(find.textContaining('演示数据（合成样例'), findsOneWidget);
    expect(find.text('第一轮（演示）'), findsOneWidget);

    // 跨轮汇总：同一教学班跨两轮出现 + 容量/已选快照变化
    await tester.tap(find.text('跨轮汇总'));
    await tester.pump();
    await tester.tap(find.text('汇总全部入口'));
    await tester.pump();
    expect(find.textContaining('60/45  →  60/52'), findsOneWidget);
    expect(find.textContaining('出现在 2 个入口'), findsWidgets);

    // 建议卡：确定性计数 + 与课表冲突（演示课表 星期一第3-4节 与 J2001A 重叠）
    await tester.tap(find.text('建议卡'));
    await tester.pump();
    expect(find.text('建议卡（本机确定性计算）'), findsOneWidget);
    expect(find.textContaining('与课表冲突 1'), findsOneWidget);
    expect(find.textContaining('与当前课表重叠：周一 第3-4节（第1-16周）'), findsOneWidget);
    // 无 AI 配置 → 面板显示未启用（默认关闭，无需 AI 也可用）。
    // 注意 IndexedStack 全页构建：设置页 AI 卡也有同一标题 → findsWidgets 而非 findsOneWidget
    expect(find.textContaining('AI 解读（可选）'), findsWidgets);
    expect(find.text('去设置'), findsOneWidget);
  });
}
