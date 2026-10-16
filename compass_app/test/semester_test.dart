/// test/semester_test.dart — 学期日历与培养方案学期标签换算。
library;

import 'package:test/test.dart';

import 'package:compass_app/data/semester.dart';

void main() {
  group('termForDate', () {
    test('2026 秋冬开课日为周一，记第 1 周', () {
      final t = termForDate(DateTime(2026, 9, 14));
      expect(DateTime(2026, 9, 14).weekday, 1);
      expect(t.code, '2026-A');
      expect(t.tag, '2026秋冬');
      expect(t.week, 1);
      expect(t.vacation, isFalse);
    });

    test('2026-10-16 为秋冬第 5 周', () {
      final t = termForDate(DateTime(2026, 10, 16));
      expect(t.code, '2026-A');
      expect(t.week, 5);
    });

    test('1 月仍属秋冬学期', () {
      final t = termForDate(DateTime(2026, 1, 10));
      expect(t.code, '2025-A');
      expect(t.tag, '2025秋冬');
    });

    test('2 月上旬为寒假（返回春夏学期、vacation）', () {
      final t = termForDate(DateTime(2026, 2, 10));
      expect(t.vacation, isTrue);
      expect(t.code, '2025-B');
      expect(t.tag, '2026春夏');
      expect(t.week, 0);
    });

    test('3 月起为春夏学期', () {
      final t = termForDate(DateTime(2026, 3, 9));
      expect(t.code, '2025-B');
      expect(t.tag, '2026春夏');
      expect(t.vacation, isFalse);
    });

    test('6 月下旬起为小学期（短）', () {
      final t = termForDate(DateTime(2026, 7, 1));
      expect(t.code, '2025-SS');
      expect(t.tag, '2026短');
      expect(t.vacation, isFalse);
    });

    test('8 月为暑假（返回下学年秋冬、vacation）', () {
      final t = termForDate(DateTime(2026, 8, 10));
      expect(t.vacation, isTrue);
      expect(t.code, '2026-A');
      expect(t.tag, '2026秋冬');
    });

    test('校历表内所有开课日均为周一', () {
      // 经 _heuristic 兜底路径抽查 2029 年（9 月第二个周一）。
      final t = termForDate(DateTime(2029, 9, 10));
      expect(DateTime(2029, 9, 10).weekday, 1);
      expect(t.week, 1);
    });
  });

  group('todayLine', () {
    test('一行包含日期、学期周次与周内第几天', () {
      final line = todayLine(DateTime(2026, 10, 16, 21, 30)); // 周五
      expect(line, contains('2026年10月16日'));
      expect(line, contains('秋冬学期第5周第5天'));
      expect(line.contains('\n'), isFalse);
    });

    test('假期显示寒/暑假', () {
      expect(todayLine(DateTime(2026, 8, 10)), contains('暑假'));
      expect(todayLine(DateTime(2026, 2, 10)), contains('寒假'));
    });
  });

  group('prettyPlanTerm', () {
    test('一(秋冬) → 年级当年秋冬', () {
      expect(prettyPlanTerm('一(秋冬)', gradeYear: 2026), '2026秋冬');
    });
    test('组合串与斜杠分隔', () {
      expect(prettyPlanTerm('一(秋冬)+一(春夏)', gradeYear: 2026),
          '2026秋冬+2027春夏');
      expect(prettyPlanTerm('二(秋)/二(冬)', gradeYear: 2026), '2027秋/2027冬');
    });
    test('短学期计入学年末', () {
      expect(prettyPlanTerm('三(短)', gradeYear: 2026), '2029短');
    });
    test('四学年春夏', () {
      expect(prettyPlanTerm('四(春夏)', gradeYear: 2026), '2030春夏');
    });
    test('无法识别的原样保留', () {
      expect(prettyPlanTerm('五(春夏)', gradeYear: 2026), '五(春夏)');
      expect(prettyPlanTerm('', gradeYear: 2026), '');
    });
  });

  group('termCodeLabel', () {
    test('A/B 编码 → 中文标签', () {
      expect(termCodeLabel('2026-A'), '2026秋冬');
      expect(termCodeLabel('2026-B'), '2027春夏');
      expect(termCodeLabel('unknown'), 'unknown');
    });
  });

  group('prettySemester', () {
    test('教务学年学期串 → 日历标签', () {
      expect(prettySemester('20232024-1'), '2023秋冬');
      expect(prettySemester('20262027-2'), '2027春夏');
      expect(prettySemester('2025-2026（1）'), '2025秋冬');
    });
    test('已是日历标签 / 非连续学年 / 空串 → 原样', () {
      expect(prettySemester('2026秋冬'), '2026秋冬');
      expect(prettySemester('20232025-1'), '20232025-1');
      expect(prettySemester(''), '');
    });
    test('PDF 年级式学期串传年级才换算', () {
      expect(prettySemester('一(秋冬)', gradeYear: 2026), '2026秋冬');
      expect(prettySemester('一(秋冬)'), '一(秋冬)');
    });
  });
}
