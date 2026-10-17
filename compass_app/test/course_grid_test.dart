// test/course_grid_test.dart — 选课课程网格（任务3）：列数断点 + 课程小卡冒烟。
// 页面依赖重（ZjuClient 等），故网格列数与课程小卡抽成顶层纯函数/独立 widget 直连测试。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/xk_models.dart';
import 'package:compass_app/pages/course_select_page.dart';

void main() {
  test('gridColumns 断点：每列目标最小 260px、最多 3 列、保底 1 列', () {
    expect(gridColumns(320), 1); // 手机窄屏退一列
    expect(gridColumns(259), 1); // 不足一列也保底 1
    expect(gridColumns(520), 2); // 2×260 阈值边界
    expect(gridColumns(600), 2);
    expect(gridColumns(900), 3);
    expect(gridColumns(1280), 3); // 宽屏封顶
  });

  testWidgets('CourseMiniCard 冒烟：课名/教师/时间/容量可见，余量标签正确',
      (tester) async {
    const c = XkCourse(
      kcmc: '数据结构基础',
      jxbmc: '01',
      teacher: '张三',
      sksj: '星期一 第3,4节',
      cap: 120,
      selected: 96,
    );
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 300, child: CourseMiniCard(course: c)),
        ),
      ),
    ));

    expect(find.text('数据结构基础（01）'), findsOneWidget);
    expect(find.textContaining('张三'), findsOneWidget);
    expect(find.textContaining('3,4节'), findsOneWidget); // 「星期」已缩写
    expect(find.text('余 24'), findsOneWidget);
    expect(find.text('容量 120/已选 96'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('CourseMiniCard 窄容器（120px）不出溢出异常：已满标签正确',
      (tester) async {
    const c = XkCourse(
      kcmc: '一门名字特别特别特别特别长的课程名称示例课程',
      teacher: '李四',
      sksj: '星期五 第11,12节',
      cap: 30,
      selected: 30,
    );
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 120, child: CourseMiniCard(course: c)),
        ),
      ),
    ));
    await tester.pump();

    expect(find.textContaining('李四'), findsOneWidget);
    expect(find.text('已满'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('CourseMiniCard 冲突标记：标签与冲突文案可见', (tester) async {
    const c = XkCourse(kcmc: '概率论', teacher: '王五', cap: 60, selected: 10);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
              width: 300, child: CourseMiniCard(course: c, conflict: true)),
        ),
      ),
    ));

    expect(find.text('冲突'), findsOneWidget);
    expect(find.text('与当前课表冲突'), findsOneWidget);
    expect(find.text('余 50'), findsNothing); // 冲突优先占用标签位
    expect(tester.takeException(), isNull);
  });
}
