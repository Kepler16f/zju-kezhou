/// test/choosed_state_test.dart — 「本学期已选」行状态：已获学分 / 在修 / 未获。
///
/// 用户反馈：成绩页与方案-学业达成审计页都必须区分「已出分已获学分」与
/// 「已选上未出分」，且两页同口径。本文件锁定共享分类函数与文案。
/// 纯 Dart（course_state.dart 无 Flutter 依赖）。
library;

import 'package:compass_app/engine/course_state.dart';
import 'package:test/test.dart';

Map<String, dynamic> row(String id, String name,
        {num? grade, bool? passed, String original = '', bool? included}) =>
    <String, dynamic>{
      'course_id': id,
      'name': name,
      if (grade != null) 'grade': grade,
      if (passed != null) 'passed': passed,
      if (original.isNotEmpty) 'original': original,
      if (included != null) 'credit_included': included,
    };

void main() {
  group('choosedCourseTranscriptState', () {
    test('成绩单已通过且计学分 → earned（已获学分）', () {
      final st = choosedCourseTranscriptState(
        courseId: 'MATH1135G',
        name: '微积分（甲）Ⅰ',
        transcript: [row('MATH1135G', '微积分（甲）Ⅰ', grade: 88)],
      );
      expect(st, PlanCourseState.earned);
      expect(choosedCreditLabel(st), '已获学分');
    });

    test('成绩单待录 → active（在修未出分）', () {
      final st = choosedCourseTranscriptState(
        courseId: '',
        name: '大学英语Ⅲ',
        transcript: [row('', '大学英语Ⅲ', original: '待录')],
      );
      expect(st, PlanCourseState.active);
      expect(choosedCreditLabel(st), '在修（未出成绩）');
    });

    test('成绩单无记录 → null（纯在修）', () {
      expect(
        choosedCourseTranscriptState(
            courseId: 'X1', name: '未知课', transcript: const []),
        isNull,
      );
    });

    test('课号精确优先：名称写法不同也认', () {
      final st = choosedCourseTranscriptState(
        courseId: 'PHY1002G',
        name: '大学物理（乙）Ⅰ',
        transcript: [row('PHY1002G', '大学物理乙I', grade: 90)],
      );
      expect(st, PlanCourseState.earned);
    });

    test('变体隔离：只选了微积分（甲）Ⅰ，不能被 Ⅱ 的成绩标成已获', () {
      final st = choosedCourseTranscriptState(
        courseId: '',
        name: '微积分（甲）Ⅰ',
        transcript: [row('', '微积分（甲）Ⅱ', grade: 95)],
      );
      expect(st, isNull);
    });

    test('未通过 → noCredit（未获学分）', () {
      final st = choosedCourseTranscriptState(
        courseId: '',
        name: '线性代数（甲）',
        transcript: [row('', '线性代数（甲）', grade: 52)],
      );
      expect(st, PlanCourseState.noCredit);
      expect(choosedCreditLabel(st), '未获学分');
    });
  });
}
