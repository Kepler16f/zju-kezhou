// test/analytics_test.dart — 学业分析引擎单测（手算对照）。
import 'package:test/test.dart';

import 'package:compass_app/engine/analytics.dart';
import 'package:compass_app/data/zju_parse.dart' show fourFromFive;

Map<String, dynamic> c(String name, double credits, double five, double grade,
        {String sem = '2023-A', String cat = '专业必修课', bool passed = true}) =>
    {
      'name': name, 'credits': credits, 'five_point': five, 'grade': grade,
      'semester': sem, 'category': cat, 'passed': passed,
      'gpa_included': passed, 'credit_included': true,
    };

void main() {
  group('fourFromFive', () {
    test('映射表', () {
      expect(fourFromFive(5.0), 4.3);
      expect(fourFromFive(4.8), 4.2);
      expect(fourFromFive(4.5), 4.1);
      expect(fourFromFive(4.2), 4.0);
      expect(fourFromFive(4.0), 4.0);
      expect(fourFromFive(3.7), 3.7);
    });
  });

  group('overall', () {
    test('加权与 GPA 手算', () {
      // 两门课：4 学分 92 分（five 4.8）、3 学分 85 分（five 4.5）
      final o = Analytics.overall([
        c('A', 4, 4.8, 92),
        c('B', 3, 4.5, 85),
      ]);
      // 五分：(4.8*4 + 4.5*3)/7 = (19.2+13.5)/7 = 32.7/7 = 4.6714…
      expect(o['five']!, closeTo(32.7 / 7, 1e-9));
      // 4.3 制：(4.2*4 + 4.1*3)/7 = (16.8+12.3)/7 = 29.1/7
      expect(o['four']!, closeTo(29.1 / 7, 1e-9));
      // 加权：(92*4 + 85*3)/7 = (368+255)/7 = 623/7
      expect(o['weighted']!, closeTo(623 / 7, 1e-9));
      expect(o['earned_credits'], 7.0);
    });
    test('挂科不计 GPA 学分但已修口径另计', () {
      final o = Analytics.overall([
        c('A', 4, 4.8, 92),
        c('F', 3, 0.0, 55, passed: false),
      ]);
      expect(o['gpa_credits'], 4.0);
      expect(o['five']!, 4.8);
      expect(o['earned_credits'], 4.0); // 挂科未获学分
    });
    test('缺 passed/gpa_included/five_point 字段（样例/手写记录）仍计入 GPA', () {
      // 回归：曾因 passed 缺省 false 把整份成绩单排除在 GPA 之外（学业页显示 0.00）
      final o = Analytics.overall([
        {'name': '思想道德与法治', 'credits': 3.0, 'grade': 85, 'semester': '2023-A'},
        {'name': '大学物理', 'credits': 4.0, 'grade': 55, 'semester': '2023-A'}, // 不及格
      ]);
      expect(o['gpa_credits'], 3.0); // 只有及格课计入
      expect(o['five']!, closeTo(4.5, 1e-9)); // 85 分 → 4.5（参考换算兜底）
      expect(o['earned_credits'], 3.0);
      expect(Analytics.isPassed({'grade': 85}), isTrue);
      expect(Analytics.isPassed({'grade': 55}), isFalse);
      expect(Analytics.isPassed({'passed': true, 'grade': 10}), isTrue); // 显式字段优先
    });
  });

  group('semesterTrend', () {
    test('分桶与累计', () {
      final t = Analytics.semesterTrend([
        c('A', 4, 4.8, 92, sem: '2023-A'),
        c('B', 3, 4.5, 85, sem: '2023-B'),
        c('C', 2, 5.0, 96, sem: '2023-B'),
      ]);
      expect(t.length, 2);
      expect(t[0]['four']!, 4.2); // 2023-A 单门 4.8→4.2
      // 2023-B: (4.1*3 + 4.3*2)/5 = (12.3+8.6)/5 = 20.9/5 = 4.18
      expect(t[1]['four']!, closeTo(20.9 / 5, 1e-9));
      // 累计: (4.2*4 + 20.9)/9 = (16.8+20.9)/9
      expect(t[1]['cumulative_four']!, closeTo(37.7 / 9, 1e-9));
      expect(t[1]['credits'], 5.0);
    });
  });

  group('creditByCategory', () {
    test('按 kcxzmc 聚合', () {
      final board = Analytics.creditByCategory([
        c('A', 4, 4.8, 92, cat: '通识必修课'),
        c('B', 3, 4.5, 85, cat: '通识必修课'),
        c('C', 2, 5.0, 96, cat: '专业必修课'),
        c('F', 3, 0.0, 55, cat: '专业必修课', passed: false), // 不计
      ]);
      expect(board.length, 2);
      expect(board[0]['category'], '通识必修课');
      expect(board[0]['credits'], 7.0);
      expect(board[1]['credits'], 2.0);
    });
  });

  group('simulateGpa', () {
    test('加一门预测', () {
      final base = [c('A', 4, 4.8, 92)];
      // 加 3 学分预期 4.5（→4.1）：(4.2*4 + 4.1*3)/7
      final g = Analytics.simulateGpa(base, [
        {'credits': 3.0, 'five_point': 4.5}
      ]);
      expect(g, closeTo(29.1 / 7, 1e-9));
    });
  });

  group('requiredFiveForTarget', () {
    test('可达目标反推', () {
      final base = [c('A', 4, 4.8, 92)]; // four=4.2
      // 目标 4.3，剩 8 学分：需要 (4.3*12 - 4.2*4)/8 = (51.6-16.8)/8 = 4.35 → 超 4.3 无解
      expect(Analytics.requiredFiveForTarget(base, 4.3, 8), isNull);
      // 目标 4.2，剩 8 学分：需要 (4.2*12-16.8)/8 = 33.6/8 = 4.2 四分 → 五分 4.8（4.8 才映射 4.2）
      expect(Analytics.requiredFiveForTarget(base, 4.2, 8), 4.8);
      // 目标 4.0，剩 8：需要 (48-16.8)/8 = 3.9 → <4.0，五分=3.9
      expect(Analytics.requiredFiveForTarget(base, 4.0, 8), closeTo(3.9, 1e-9));
    });
  });
}
