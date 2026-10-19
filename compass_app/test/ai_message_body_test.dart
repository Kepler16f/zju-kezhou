// test/ai_message_body_test.dart — AI 回复 Markdown/公式渲染（用户反馈 #14）。
//
// 锁定：粗体/列表/围栏代码块/行内公式能渲染且不抛；空串不崩；公式降级
// 保留 LaTeX 原文（等宽展示），链接显示文字与 URL。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/widgets/ai_message_body.dart';

Widget wrap(String text) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AiMessageBody(text),
        ),
      ),
    );

void main() {
  testWidgets('粗体/行内码/行内公式渲染且无异常', (tester) async {
    await tester.pumpWidget(wrap(
        '这是**粗体**、`inline_code`，以及行内公式 \$x^2+y^2\$ 结束。'));
    await tester.pump();
    expect(find.textContaining('粗体'), findsOneWidget);
    expect(find.textContaining('inline_code'), findsOneWidget);
    expect(find.textContaining('x^2+y^2'), findsOneWidget); // 降级保留原文
    expect(tester.takeException(), isNull);
  });

  testWidgets('标题/无序列表/有序列表渲染', (tester) async {
    await tester.pumpWidget(wrap(
        '# 标题一\n\n- 第一项\n- 第二项\n\n1. 步骤一\n2. 步骤二\n'));
    await tester.pump();
    expect(find.textContaining('标题一'), findsOneWidget);
    expect(find.textContaining('第一项'), findsOneWidget);
    expect(find.textContaining('步骤一'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('围栏代码块保留原样（含缩进/符号）', (tester) async {
    await tester.pumpWidget(wrap('代码：\n```dart\nvoid main() {\n  run();\n}\n```\n'));
    await tester.pump();
    expect(find.textContaining('void main()'), findsOneWidget);
    expect(find.textContaining('run();'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('块级公式 \$\$...\$\$ 走代码块降级', (tester) async {
    await tester.pumpWidget(wrap('推导：\n\$\$\n\\frac{a}{b} = c\n\$\$\n'));
    await tester.pump();
    expect(find.textContaining(r'\frac{a}{b}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('链接显示文字与 URL；空串不崩', (tester) async {
    await tester.pumpWidget(wrap('见 [课舟](https://example.com/x) 。'));
    await tester.pump();
    expect(find.textContaining('课舟'), findsOneWidget);
    expect(find.textContaining('https://example.com/x'), findsOneWidget);

    await tester.pumpWidget(wrap('   '));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('超长文本截断渲染不崩（>20k）', (tester) async {
    await tester.pumpWidget(wrap('字' * 25000));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
