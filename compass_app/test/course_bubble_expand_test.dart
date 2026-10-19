// test/course_bubble_expand_test.dart — 选课气泡点按展开/收起 + 教师评分行回归。
//
// 锁定：
//  * 收起态只显示课名+标签，详情行与评分行不可见；
//  * 点按展开后 时间/地点/教师/评分 行出现；再点收起后消失；
//  * 命中评分表显示「评分 x.x/10（n 人评 · 查老师）」，未命中显示「评分：暂无」；
//  * 展开时 onTap 仍透传（页面据此弹已修/在修的防重复 SnackBar）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/teacher_rating.dart';
import 'package:compass_app/data/xk_models.dart';
import 'package:compass_app/engine/course_state.dart';
import 'package:compass_app/pages/course_select_page.dart';

void main() {
  const course = XkCourse(
    kcmc: '数据结构',
    kch: 'CS101',
    xf: 3.5,
    teacher: '张三',
    sksj: '周一 1-2 节',
    cdmc: '紫金港二教101',
  );

  final store = TeacherRatingStore.fromJson(const {
    '张三': {'avg': 9.3, 'count': 10, 'source': '查老师'},
  });

  Future<void> pumpBubble(WidgetTester tester,
      {TeacherRatingStore? ratings, void Function()? onTap}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 360, // 与选课页一致：外层由页面 ConstrainedBox(maxWidth) 封顶
            child: CourseBubble(
              course: course,
              ratings: ratings,
              onTap: onTap,
            ),
          ),
        ),
      ),
    ));
  }

  testWidgets('点按展开显示 时间/地点/教师/评分，再点收起消失', (tester) async {
    await pumpBubble(tester, ratings: store);

    // 收起态：详情不进屏幕
    expect(find.text('时间 周一 1-2 节'), findsNothing);
    expect(find.text('地点 紫金港二教101'), findsNothing);
    expect(find.text('教师 张三'), findsNothing);
    expect(find.textContaining('评分'), findsNothing);

    await tester.tap(find.byType(CourseBubble));
    await tester.pumpAndSettle(); // AnimatedSize 收敛

    expect(find.text('时间 周一 1-2 节'), findsOneWidget);
    expect(find.text('地点 紫金港二教101'), findsOneWidget);
    expect(find.text('教师 张三'), findsOneWidget);
    expect(find.text('课程号 CS101'), findsOneWidget);
    // 课程号/学分只由详情块渲染一次（用户反馈：放大卡里字段出现两遍）
    expect(find.text('学分 3.5'), findsOneWidget);
    expect(find.text('3.5 学分'), findsNothing);
    expect(find.text('评分 9.3/10（10 人评 · 查老师）'), findsOneWidget);

    // 再点收起
    await tester.tap(find.byType(CourseBubble));
    await tester.pumpAndSettle();
    expect(find.text('时间 周一 1-2 节'), findsNothing);
    expect(find.text('评分 9.3/10（10 人评 · 查老师）'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未命中评分表：展开行显示「评分：暂无」', (tester) async {
    await pumpBubble(tester, ratings: TeacherRatingStore.empty);
    await tester.tap(find.byType(CourseBubble));
    await tester.pumpAndSettle();
    expect(find.text('评分：暂无'), findsOneWidget);
    expect(find.textContaining('人评'), findsNothing);
  });

  testWidgets('展开时仍透传 onTap（页面弹防重复提示的通道不断）', (tester) async {
    var taps = 0;
    await pumpBubble(tester, ratings: store, onTap: () => taps++);
    await tester.tap(find.byType(CourseBubble));
    await tester.pumpAndSettle();
    expect(taps, 1);
    await tester.tap(find.byType(CourseBubble));
    await tester.pumpAndSettle();
    expect(taps, 2);
  });

  testWidgets('已修课程展开不影响弱化样式：课名/状态仍可见', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 360,
            child: CourseBubble(
              course: course,
              state: PlanCourseState.earned,
              ratings: store,
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byType(CourseBubble));
    await tester.pumpAndSettle();
    expect(find.text('已修'), findsOneWidget);
    expect(find.textContaining('修读状态 已修'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('展开后显示教学班（教师/时间/地点），逐个匹配评分', (tester) async {
    const bare = XkCourse(kcmc: '微积分（甲）Ⅰ', kch: 'MATH1135G', xf: 5.0);
    const jxbs = [
      XkCourse(
          kcmc: '微积分（甲）Ⅰ',
          kch: 'MATH1135G',
          jxbmc: '01',
          teacher: '汪国军',
          sksj: '周二第1,2节',
          cdmc: '紫金港东2-203',
          cap: 60,
          selected: 42),
      XkCourse(
          kcmc: '微积分（甲）Ⅰ',
          kch: 'MATH1135G',
          jxbmc: '02',
          teacher: '李四',
          sksj: '周四第3,4节',
          cdmc: '紫金港东1-101'),
    ];
    final jxbStore = TeacherRatingStore.fromJson(const {
      '汪国军': {'avg': 9.4, 'count': 148, 'source': '查老师'},
    });
    var expands = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 380,
            child: CourseBubble(
              course: bare,
              ratings: jxbStore,
              teachingClasses: jxbs,
              onExpand: () => expands++,
            ),
          ),
        ),
      ),
    ));
    expect(find.textContaining('教学班 01'), findsNothing);
    await tester.tap(find.byType(CourseBubble));
    await tester.pumpAndSettle();
    expect(expands, 1);
    expect(find.textContaining('教学班（2）'), findsOneWidget);
    expect(find.textContaining('教学班 01'), findsOneWidget);
    expect(find.textContaining('汪国军'), findsOneWidget);
    expect(find.textContaining('周二第1,2节'), findsOneWidget);
    expect(find.textContaining('紫金港东2-203'), findsOneWidget);
    expect(find.textContaining('容量 60/已选 42'), findsOneWidget);
    expect(find.textContaining('教学班 02'), findsOneWidget);
    // 平行班教师不同：命中的显示分数，未命中的显示「暂无」
    expect(find.text('评分 9.4/10（148 人评 · 查老师）'), findsOneWidget);
    expect(find.text('评分：暂无'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
