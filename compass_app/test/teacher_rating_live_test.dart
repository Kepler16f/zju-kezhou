// test/teacher_rating_live_test.dart — 实时评分客户端纯函数回归。
//
// 站点详情页标题实测形态：
//   <title>毕惟红老师 9.39分 422人打分 - 查老师</title>
// 解析必须只认该形态；脏页/登录页/无评分页一律 null（宁缺勿猜）。
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/teacher_rating_live.dart';

void main() {
  group('parseTeacherRatingHtml', () {
    test('真实标题形态 → 姓名/评分/人数', () {
      final r = parseTeacherRatingHtml(
          '<html><head><title>毕惟红老师 9.39分 422人打分 - 查老师</title></head></html>');
      expect(r, isNotNull);
      expect(r!.teacher, '毕惟红');
      expect(r.avg, 9.39);
      expect(r.count, 422);
      expect(r.displayText, '评分 9.4/10（422 人评 · 查老师）');
    });

    test('整数分/多空格/无空格变体', () {
      final r = parseTeacherRatingHtml('<title>张三老师 9分 12人打分 - 查老师</title>');
      expect(r?.avg, 9.0);
      expect(r?.count, 12);
    });

    test('越界分数/非教师页/空串 → null', () {
      expect(parseTeacherRatingHtml('<title>张三老师 10.5分 12人打分</title>'), isNull);
      expect(parseTeacherRatingHtml('<title>课舟</title>'), isNull);
      expect(parseTeacherRatingHtml(''), isNull);
      expect(parseTeacherRatingHtml('<title>登录 - 查老师</title>'), isNull);
    });
  });

  group('parseTeacherSearchId', () {
    const html = '''
<div class="item" onclick="window.location='/t/6310/'">
    <div class="left">
        <h3>刘海峰</h3>
        <p>教育学院</p>
    </div>
    <div class="right">
        <h2>N/A</h2>
    </div>
</div>
<hr>
<div class="item" onclick="window.location='/t/159/'">
    <div class="left">
        <h3>商丽浩</h3>
        <p>教育学院</p>
    </div>
    <div class="right">
        <h2>8.1</h2>
    </div>
</div>
''';

    test('精确姓名 → 对应 ID（模糊结果不采用）', () {
      expect(parseTeacherSearchId(html, '刘海峰'), '6310');
      expect(parseTeacherSearchId(html, '商丽浩'), '159');
      // 只返回模糊相近的别人：宁缺勿猜
      expect(parseTeacherSearchId(html, '刘海'), isNull);
      expect(parseTeacherSearchId(html, '王小明'), isNull);
    });

    test('姓名空白/大小写归一（教务偶有空格）', () {
      expect(parseTeacherSearchId(html, ' 刘海峰 '), '6310');
    });
  });
}
