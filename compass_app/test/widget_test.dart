// 冒烟测试：底部导航四页签渲染 + 样例审计全流程（设置页运行 → 自动切方案页，
// 内嵌「学业达成审计」区出报告，诉求 #13）+ 选课页未登录引导与去设置跳转。
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
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/credential_store.dart';
import 'package:compass_app/main.dart';
import 'package:compass_app/pages/curriculum_plan_page.dart';

/// 底栏 NavigationBar 为 onlyShowSelected 标签行为：未选中页签的文字标签中心
/// 贴在屏幕下沿之外，find.text 的 tap 会 miss（命中不到）——页签切换一律点
/// NavigationBar 内的图标。
Finder navTabIcon(IconData icon) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.byIcon(icon));

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
    // 底部导航 tab + 学业页空态即为渲染正确性的证据。
    expect(find.text('学业'), findsOneWidget);
    expect(find.text('方案'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('选课'), findsOneWidget);
    // 审计页签已并入方案页（诉求 #13）；2026-10-18 需求 #5 起「工具」不再是
    // 独立底栏页，而是学业页内的子选项卡。
    expect(find.text('审计'), findsNothing);
    expect(find.byType(NavigationDestination), findsNWidgets(4));
    expect(find.text('工具'), findsOneWidget);
    // 学业页空态引导 + 顶部日期学期栏（诉求 #8）
    expect(find.text('暂无学业数据'), findsOneWidget);
    expect(find.textContaining('今天是'), findsOneWidget);
  });

  testWidgets('样例审计全流程：设置页运行 → 自动切方案页内嵌审计区', (tester) async {
    // 全程真实时钟：rootBundle IO 走真 HttpClient，真实 delay 驱动加载与状态更新。
    // 报告区内嵌在方案页的 ListView（诉求 #13），默认 600 高视口只构建视口内的
    // 板块，"风险提示"/免责声明在下方未构建——撑高 surface 让整页一次渲染。
    await tester.binding.setSurfaceSize(const Size(1200, 4000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(const KeZhouApp());
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // 切到"设置"
      await tester.tap(navTabIcon(Icons.settings_outlined));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // 点"运行样例审计"，轮询直到方案页内嵌审计区出现（上限 5s）。
      await tester.tap(find.text('运行样例审计'));
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
        if (find.text('学业达成审计').evaluate().isNotEmpty) break;
      }

      // 审计区默认收起：先展开外层，再断言三色/风险标题与免责声明。
      Finder inPlan(Finder f) =>
          find.descendant(of: find.byType(CurriculumPlanPage), matching: f);
      expect(inPlan(find.text('学业达成审计')), findsOneWidget);
      await tester.tap(inPlan(find.text('学业达成审计')));
      await tester.pump();
      expect(inPlan(find.textContaining('三色学分达成度（')), findsOneWidget);
      expect(inPlan(find.textContaining('风险提示（')), findsOneWidget);
      expect(inPlan(find.textContaining('仅供与导师沟通参考')), findsOneWidget);
    });

    // 学业页有数据：切过去看 GPA 卡 + 成绩详情入口
    // 学业页有数据：切过去看 GPA 卡 + 成绩详情入口
    await tester.tap(navTabIcon(Icons.dashboard_outlined));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('成绩'), findsWidgets);
    expect(find.text('五分制'), findsOneWidget);
    expect(find.text('点击查看各学期成绩明细'), findsOneWidget);
    // 回归：样例记录缺 passed/gpa_included 时 GPA 曾整卡归零、已修门数曾显示 null
    expect(find.text('0.00'), findsNothing);
    expect(find.text('null'), findsNothing);

    // 点成绩卡进详情页（按学期分组）
    await tester.tap(find.text('点击查看各学期成绩明细'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('成绩明细'), findsOneWidget);
    // 诉求 #8：学期标签日历化（2023-A → 2023秋冬）
    expect(find.textContaining('秋冬'), findsWidgets);
    expect(find.textContaining('春季'), findsNothing);
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

    await tester.tap(navTabIcon(Icons.how_to_vote_outlined));
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

      await tester.tap(navTabIcon(Icons.how_to_vote_outlined));
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
    // 类别名既出现在 chip 上，也作为课程气泡的标签出现。
    expect(find.text('第一轮（演示）'), findsWidgets);

    // 所有课程：同一教学班跨两轮出现 + 容量/已选快照变化（详情在气泡 Tooltip）
    await tester.tap(find.text('所有课程'));
    await tester.pump();
    await tester.tap(find.text('汇总全部入口'));
    await tester.pump();
    final tooltipText = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((t) => t.message ?? '')
        .join('\n');
    expect(tooltipText.contains('60/45'), isTrue);
    expect(tooltipText.contains('60/52'), isTrue);
    expect(tooltipText.contains('出现在 2 个'), isTrue);

    // 建议卡：确定性计数 + 与课表冲突（演示课表 星期一第3-4节 与 J2001A 重叠）
    await tester.tap(find.text('建议卡'));
    await tester.pump();
    expect(find.text('建议卡（本机确定性计算）'), findsOneWidget);
    expect(find.textContaining('与课表冲突 1'), findsOneWidget);
    expect(find.textContaining('与当前课表重叠：周一 第3-4节（第1-16周）'), findsOneWidget);
    // 2026-10-18 需求 #2：首次安装默认关闭 AI（不再出厂预置公益端点），
    // 故选课页 AI 面板显示「未启用」引导（去设置），而非发送范围说明。
    // 注意 IndexedStack 全页构建：设置页 AI 卡也有同一标题 → findsWidgets。
    expect(find.textContaining('AI 解读（可选）'), findsWidgets);
    expect(find.textContaining('未启用：建议卡为本机计算'), findsOneWidget);
    expect(find.text('去设置'), findsWidgets);
    expect(find.textContaining('开启后仅发送'), findsNothing);
  });

  group('底栏偏好迁移（旧五列 → 新四列）', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('compass_nav_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('旧五排列去掉工具位 3，设置 4 映射为 3', () async {
      final store = CredentialStore(tmp);
      await store.saveTabOrder('0,1,2,3,4');
      expect(await store.loadTabOrder(), '0,1,2,3');

      await store.saveTabOrder('2,0,3,4,1');
      expect(await store.loadTabOrder(), '2,0,3,1');
    });

    test('旧五列默认页：工具 3→学业 0，设置 4→3', () async {
      final store = CredentialStore(tmp);
      await store.saveTabOrder('0,1,2,3,4');
      await store.saveDefaultTab(3);
      expect(await store.loadDefaultTab(), 0);
      await store.saveDefaultTab(4);
      expect(await store.loadDefaultTab(), 3);
    });

    test('新四排列默认页原样保留', () async {
      final store = CredentialStore(tmp);
      await store.saveTabOrder('2,1,0,3');
      await store.saveDefaultTab(3);
      expect(await store.loadDefaultTab(), 3);
    });

    test('非法/重复顺序回落默认，默认页回落学业', () async {
      final store = CredentialStore(tmp);
      await store.saveTabOrder('0,0,1,2');
      expect(await store.loadTabOrder(), '0,1,2,3');
      await store.saveDefaultTab(2);
      expect(await store.loadDefaultTab(), 0);
    });
  });
}
