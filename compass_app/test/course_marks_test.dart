// test/course_marks_test.dart — 本地排除标记单测：键稳定性/容错解析/应用语义/零污染。
import 'package:test/test.dart';

import 'package:compass_app/engine/course_marks.dart';

Map<String, dynamic> c(String name, String semester,
        {String? xkkh, double credits = 3.0}) =>
    {
      'name': name,
      'semester': semester,
      'credits': credits,
      'grade': 90,
      'five_point': 4.8,
      'passed': true,
      'credit_included': true,
      'gpa_included': true,
      if (xkkh != null) 'xkkh': xkkh,
    };

void main() {
  group('courseMarkKey', () {
    test('xkkh 优先（同一门课多次修读各自独立）', () {
      final a = courseMarkKey(c('数据结构', '2023-A', xkkh: 'T20232024-1A'));
      final b = courseMarkKey(c('数据结构', '2023-B', xkkh: 'T20232024-1B'));
      expect(a, isNot(equals(b)));
      expect(a, 'xkkh:T20232024-1A');
    });
    test('无 xkkh 退化为名称+学期', () {
      expect(courseMarkKey(c('高等数学', '2023-A')), 'ns:高等数学|2023-A');
      expect(courseMarkKey(c(' 高等数学 ', '2023-A')), 'ns:高等数学|2023-A'); // trim
      expect(courseMarkKey({'name': ''}), 'ns:|unknown');
    });
  });

  group('parseMarks（容错解析）', () {
    test('合法 JSON', () {
      final m = parseMarks('{"xkkh:T1":{"excludeCredit":true},'
          '"ns:体育|2023-A":{"excludeGpa":true}}');
      expect(m['xkkh:T1']!['excludeCredit'], isTrue);
      expect(m['ns:体育|2023-A']!['excludeGpa'], isTrue);
    });
    test('坏 JSON / 非 Map / 非布尔值一律丢弃', () {
      expect(parseMarks(null), isEmpty);
      expect(parseMarks(''), isEmpty);
      expect(parseMarks('not json'), isEmpty);
      expect(parseMarks('[1,2]'), isEmpty);
      expect(parseMarks('{"k":{"excludeCredit":"yes"}}')['k'], isNull);
    });
  });

  group('applyCourseMarks（应用语义）', () {
    final raw = [
      c('甲', '2023-A', xkkh: 'T1'),
      c('乙', '2023-A', xkkh: 'T2'),
      c('体育', '2023-A'),
    ];
    test('排除学分只动 credit_included；排除 GPA 只动 gpa_included', () {
      final out = applyCourseMarks(raw, {
        'xkkh:T1': {'excludeCredit': true},
        'ns:体育|2023-A': {'excludeGpa': true},
      });
      expect(out[0]['credit_included'], isFalse);
      expect(out[0]['gpa_included'], isTrue); // 未标记的域不受影响
      expect(out[1]['credit_included'], isTrue);
      expect(out[2]['gpa_included'], isFalse);
      expect(out[2]['credit_included'], isTrue);
    });
    test('未标记课程原样透传；入参零污染', () {
      final out = applyCourseMarks(raw, {
        'xkkh:T1': {'excludeCredit': true},
      });
      expect(identical(out[1], raw[1]), isTrue); // 未标记行原对象透传
      expect(raw[0]['credit_included'], isTrue); // 原始记录不被修改
      expect(raw.length, 3);
    });
    test('空标记返回同一实例（零开销路径）', () {
      expect(identical(applyCourseMarks(raw, {}), raw), isTrue);
    });
    test('双排除可叠加，标记撤销后恢复默认', () {
      var marks = {
        'xkkh:T1': {'excludeCredit': true, 'excludeGpa': true},
      };
      var out = applyCourseMarks(raw, marks);
      expect(out[0]['credit_included'], isFalse);
      expect(out[0]['gpa_included'], isFalse);
      out = applyCourseMarks(raw, {});
      expect(out[0]['credit_included'], isTrue);
      expect(out[0]['gpa_included'], isTrue);
    });
  });
}
