// test/foreign_grade_rule_test.dart — 外语年级兜底显示规则（任务 #10）。
//
// 用户口径：2026 级起 L1/L2 必修大学英语IV、L3 免修；2026 级前各等级均必修
// 大学英语IV（旧生 6 分口径）。这是「方案没列出具体外语课」时的显示兜底，
// 方案有明确要求时以方案为准——本模块不参与审计学分计算。
import 'package:compass_app/engine/foreign_grade_rule.dart';
import 'package:test/test.dart';

void main() {
  group('parseForeignGradeYear', () {
    test('常见年级写法解析', () {
      expect(parseForeignGradeYear('2026'), 2026);
      expect(parseForeignGradeYear('2026级'), 2026);
      expect(parseForeignGradeYear('2024'), 2024);
      expect(parseForeignGradeYear('2025-2026'), 2025); // 首个年份
      expect(parseForeignGradeYear('  2023 '), 2023);
    });

    test('无年份/脏串 → null（不套用规则）', () {
      expect(parseForeignGradeYear(null), null);
      expect(parseForeignGradeYear(''), null);
      expect(parseForeignGradeYear('大一'), null);
      expect(parseForeignGradeYear('61025'), null); // 非 19/20 开头
    });
  });

  group('L3 免修', () {
    test('2026 级起 L3 → 免修；L1/L2 与更早年级 → 不免修', () {
      expect(isForeignExemptByGrade(gradeYear: 2026, level: 'L3'), isTrue);
      expect(isForeignExemptByGrade(gradeYear: 2027, level: 'l3'), isTrue);
      expect(isForeignExemptByGrade(gradeYear: 2026, level: 'L1'), isFalse);
      expect(isForeignExemptByGrade(gradeYear: 2026, level: 'L2'), isFalse);
      expect(isForeignExemptByGrade(gradeYear: 2025, level: 'L3'), isFalse);
      expect(isForeignExemptByGrade(gradeYear: null, level: 'L3'), isFalse);
    });
  });

  group('兜底提示与标签', () {
    test('2026 级起提示 L1/L2 必修大学英语IV、L3 免修', () {
      final h = foreignGradeHint(gradeYear: 2026);
      expect(h, isNotNull);
      expect(h, contains('大学英语IV'));
      expect(h, contains('L3 免修'));
    });

    test('2026 级前提示各等级均必修大学英语IV', () {
      final h = foreignGradeHint(gradeYear: 2024);
      expect(h, contains('大学英语IV'));
      expect(h, contains('2026级前'));
    });

    test('年级未知不打扰', () {
      expect(foreignGradeHint(gradeYear: null), isNull);
    });

    test('L3 标签随年级变化', () {
      expect(foreignL3Label(gradeYear: 2026), 'L3·免修');
      expect(foreignL3Label(gradeYear: 2025), 'L3·3分');
      expect(foreignL3Label(gradeYear: null), 'L3·3分');
    });
  });
}
