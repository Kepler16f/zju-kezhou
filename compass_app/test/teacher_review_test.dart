// 导师模式（P1/P2）widget 回归：
//  1. 审阅页空态与合规文案（不登录教务、不访问教师端、不含分数）；
//  2. 导入合法分享包 → 学生档案摘要 + 审计报告渲染（假引擎，验证 UI 链路）；
//  3. 导入非法内容 → 明确错误；
//  4. 设置页「分享给导师」卡渲染导出与入口按钮。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/share_pack.dart';
import 'package:compass_app/main.dart';
import 'package:compass_app/pages/teacher_review_page.dart';

/// 审阅页假引擎返回的最小合法 report（结构对齐 AuditEngine.build 输出）。
Map<String, dynamic> fakeReport() => {
      'summary': [
        {
          'module_id': 'm1',
          'module_path': '专业核心课',
          'required': 4.0,
          'earned': 2.0,
          'gap': 2.0,
          'remaining_future': 2.0,
          'color': 'yellow',
          'status': '🟡 待补',
          'missing_courses': <Map<String, dynamic>>[],
        }
      ],
      'warnings': <Map<String, dynamic>>[],
      'extra_courses': <Map<String, dynamic>>[],
      'totals': {'required': 4.0, 'earned': 2.0, 'gap': 2.0},
      'disclaimer': '仅供参考',
      'trace': {'plan': '样例方案', 'engine': 'v-test'},
    };

Map<String, dynamic> _courseRow(String name) => {
      'course_id': 'K$name',
      'name': name,
      'credits': 2.0,
      'grade': 90, // 会被导出侧剔除
      'five_point': 4.0, // 会被导出侧剔除
      'passed': true,
      'semester': '2024-A',
      'category': '',
      'original': '90',
      'xkkh': 'SECRET', // 会被导出侧剔除
    };

String _samplePackJson() => buildSharePack(
      student: {
        'alias': '匿名同学',
        'major': 'cs',
        'grade': '2023',
        'current_semester': '2026-A',
      },
      courses: [_courseRow('数据结构')],
      plan: {
        'meta': {'major': 'cs'},
        'modules': [
          {'module_id': 'm1', 'title': '专业核心课', 'required_credits': 4.0}
        ],
        'courses': <Map<String, dynamic>>[],
      },
    ).jsonText;

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('审阅页空态：合规声明可见、导入引导可见', (tester) async {
    await tester.pumpWidget(_wrap(TeacherReviewPage(
      onAudit: (_) => fakeReport(),
      onRegisterPlan: (_, __) {},
    )));
    await tester.pump();
    expect(find.text('选课指导模式'), findsOneWidget);
    expect(find.textContaining('不登录教务'), findsOneWidget);
    expect(find.textContaining('不含分数'), findsWidgets);
    expect(find.text('还没有导入分享包'), findsOneWidget);
    expect(find.text('从剪贴板导入'), findsOneWidget);
    expect(find.text('导入粘贴内容'), findsOneWidget);
  });

  testWidgets('导入合法包 → 学生摘要 + 审计报告渲染', (tester) async {
    // 默认 800 视口不构建视口外的「审阅意见」卡，撑高一次渲染全页。
    await tester.binding.setSurfaceSize(const Size(1200, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late Map<String, dynamic> audited;
    await tester.pumpWidget(_wrap(TeacherReviewPage(
      onAudit: (record) {
        audited = record;
        return fakeReport();
      },
      onRegisterPlan: (_, __) {},
    )));
    await tester.pump();
    // 输入分享包 JSON 并点导入
    await tester.enterText(find.byType(TextField), _samplePackJson());
    await tester.tap(find.text('导入粘贴内容'));
    await tester.pump();

    // 学生档案摘要（匿名同学 + 专业）渲染
    expect(find.textContaining('匿名同学 的学业档案'), findsOneWidget);
    // 审计区渲染（假引擎的板块行 + totals 标签）
    expect(find.textContaining('专业核心课'), findsWidgets);
    expect(find.text('应修'), findsOneWidget);
    // 引擎确实收到了 record，且 courses 行不含敏感字段（脱敏在导出侧已完成）
    final row = (audited['courses'] as List).first as Map;
    expect(row.containsKey('grade'), isFalse);
    expect(row.containsKey('xkkh'), isFalse);
    expect(row['name'], '数据结构');
    // 审阅意见导出按钮出现
    expect(find.text('复制审阅意见'), findsOneWidget);
  });

  testWidgets('回归 v0.13.11：onAudit 返回包装 map 也须正常渲染（不红屏）',
      (tester) async {
    // 生产里 engine.main 成功返回 {'report','report_json'} 包装 map；
    // 教师端接线曾漏解包导致 ReportSection 强转 report['totals'] 命中 null 红屏。
    // 本用例注入包装形状，验证页面兜底解包后审计区正常渲染。
    await tester.binding.setSurfaceSize(const Size(1200, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrap(TeacherReviewPage(
      onAudit: (_) => {'report': fakeReport(), 'report_json': '{}'},
      onRegisterPlan: (_, __) {},
    )));
    await tester.pump();
    await tester.enterText(find.byType(TextField), _samplePackJson());
    await tester.tap(find.text('导入粘贴内容'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('匿名同学 的学业档案'), findsOneWidget);
    expect(find.text('应修'), findsOneWidget);
    expect(find.textContaining('专业核心课'), findsWidgets);
  });

  testWidgets('导入非法内容 → 明确拒入错误', (tester) async {
    await tester.pumpWidget(_wrap(TeacherReviewPage(
      onAudit: (_) => fakeReport(),
      onRegisterPlan: (_, __) {},
    )));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '不是 JSON');
    await tester.tap(find.text('导入粘贴内容'));
    await tester.pump();
    expect(find.textContaining('有效的 JSON'), findsOneWidget);
  });

  testWidgets('设置页：分享给指导教师卡渲染导出与选课指导入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(const KeZhouApp());
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });
    // 切到设置页。NavigationBar 为 onlyShowSelected 标签行为：未选中页签的
    // 文字标签中心贴在屏幕下沿之外，tap 文字会 miss——点图标。
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.byIcon(Icons.settings_outlined)));
    await tester.pump();
    await tester.dragUntilVisible(
      find.text('导出到剪贴板'),
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.pump();
    // 2026-10-18 需求 #3：「分享给导师」改名「分享给指导教师」，
    // 「导师审阅模式」改名「选课指导模式」且为独立开关（SwitchListTile）。
    expect(find.text('分享给指导教师'), findsOneWidget);
    expect(find.text('导出到剪贴板'), findsOneWidget);
    expect(find.text('选课指导模式'), findsOneWidget);
    expect(find.byType(Switch), findsWidgets);
    expect(find.textContaining('实名导出'), findsOneWidget);
  });
}
