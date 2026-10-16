// test/timetable_view_test.dart — 课表周视图冒烟（诉求 #15/#4）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/xk_parse.dart';
import 'package:compass_app/widgets/timetable_view.dart';

TimetableRow row(String name,
        {int day = 1,
        int start = 1,
        int end = 1,
        String subTerm = '秋冬',
        int parity = 0}) =>
    TimetableRow(
        name: name,
        teacher: '师甲',
        place: 'A101',
        day: day,
        start: start,
        end: end,
        weekStart: 1,
        weekEnd: 8,
        parity: parity,
        subTerm: subTerm);

void main() {
  testWidgets('全部/冬/空 筛选渲染', (tester) async {
    final rows = [
      row('线性代数'), // 秋冬 → 秋/冬都显示
      row('大学写作', subTerm: '秋'), // 仅秋/全部
      row('体育课', day: 2, start: 11),
    ];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(child: TimetableView(rows: rows)))));

    // 默认「全部」：三门课名都在
    expect(find.text('线性代数'), findsOneWidget);
    expect(find.text('大学写作'), findsOneWidget);
    expect(find.text('体育课'), findsOneWidget);

    // 点「冬」：'秋冬' 行保留、单 '秋' 行消失
    await tester.tap(find.text('冬'));
    await tester.pump();
    expect(find.text('线性代数'), findsOneWidget);
    expect(find.text('大学写作'), findsNothing);

    // 点「短」：全部为空 → 空态提示
    await tester.tap(find.text('短'));
    await tester.pump();
    expect(find.text('本学期暂无课表数据'), findsOneWidget);
  });

  testWidgets('空 rows 直接空态', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(child: TimetableView(rows: [])))));
    expect(find.text('本学期暂无课表数据'), findsOneWidget);
  });

  testWidgets('同格多门（冲突对）两课同屏冒烟', (tester) async {
    final rows = [
      row('课A', day: 3, start: 5, end: 6),
      row('课B', day: 3, start: 5, end: 6),
    ];
    await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: SingleChildScrollView(child: TimetableView(rows: rows)))));
    expect(find.text('课A'), findsOneWidget);
    expect(find.text('课B'), findsOneWidget);
  });

  test('真实形态 kbList 行 → 视图入参 rows 非空', () {
    // 解析层已有 xk_parse_test 覆盖；此处冒烟 parseXskbListToSlots 的 rows
    final t = parseXskbListToSlots([
      {
        'kcb': '示例课<br>秋冬{第1-8周|1节/周}<br>师乙<br>A-101zwfzwf',
        'xqj': '2',
        'djj': '3',
        'skcd': '2',
        'dsz': '2',
        'xxq': '秋冬',
      },
    ]);
    expect(t.rows.single.name, '示例课');
    expect(t.rows.single.end, 4);
    expect(t.rows.single.subTerm, '秋冬');
  });
}
