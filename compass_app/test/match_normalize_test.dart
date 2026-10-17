/// test/match_normalize_test.dart — 诉求 #6/#8 纯函数单测：
///  - pages/scholar_page.dart 的课程名归一化与已选↔成绩单匹配
///    （normalizeCourseName / matchRecordForCourse / recordEarnedCredit）；
///  - pages/grade_detail_page.dart 的学期子标签等宽布局参数（semesterChipColumns）。
/// 两者所在文件 import Flutter，故用 flutter test 运行（非纯 dart test）。
library;

import 'package:compass_app/pages/grade_detail_page.dart';
import 'package:compass_app/pages/scholar_page.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> rec(String id, String name,
        {num? grade, bool? passed, bool? creditIncluded, String? semester}) =>
    <String, dynamic>{
      'course_id': id,
      'name': name,
      if (grade != null) 'grade': grade,
      if (passed != null) 'passed': passed,
      if (creditIncluded != null) 'credit_included': creditIncluded,
      if (semester != null) 'semester': semester,
    };

void main() {
  group('normalizeCourseName（诉求 #6 归一化）', () {
    test('全角 ASCII → 半角并转小写', () {
      expect(normalizeCourseName('ＡＢＣ１２３'), 'abc123');
      expect(normalizeCourseName('Python'), 'python');
    });

    test('去空白：半角空格 / 全角空格 / 制表与换行', () {
      expect(normalizeCourseName('高等 数学'), '高等数学');
      expect(normalizeCourseName('大学　物理'), '大学物理');
      expect(normalizeCourseName('线\n性\t代 数'), '线性代数');
    });

    test('括号符号去除、括号内文字保留（教学班/类别尾注）', () {
      expect(normalizeCourseName('高等数学（甲）'), '高等数学甲');
      expect(normalizeCourseName('大学英语（Ⅲ）'), normalizeCourseName('大学英语Ⅲ'));
      expect(normalizeCourseName('体育【提高班】'), '体育提高班');
    });

    test('语义内容不删：版本号 / 罗马数字后缀保留', () {
      expect(normalizeCourseName('大学物理Ⅱ'), contains('物理'));
      expect(normalizeCourseName('大学物理Ⅱ').endsWith('Ⅱ'.toLowerCase()), isTrue);
    });

    test('空与纯符号 → 空串（不抛异常）', () {
      expect(normalizeCourseName(''), '');
      expect(normalizeCourseName('　 （） '), '');
    });
  });

  group('matchRecordForCourse（已选 ↔ 成绩单）', () {
    test('course_id 精确优先（名称不一致也认）', () {
      final records = [rec('MATH101', '高等数学（甲）Ⅰ', grade: 92, passed: true)];
      final hit = matchRecordForCourse(
          courseId: 'MATH101', name: '微积分上', records: records);
      expect(hit, same(records.first));
    });

    test('course_id 未命中时退回归一化名称全等（全角/括号差异）', () {
      final records = [rec('ENG3', '大学英语（Ⅲ）', grade: 88, passed: true)];
      expect(
          matchRecordForCourse(
              courseId: 'WRONG', name: '大学英语Ⅲ', records: records),
          same(records.first));
      expect(
          matchRecordForCourse(
              courseId: null, name: '大学 英语 （Ⅲ） ', records: records),
          same(records.first));
    });

    test('同一课号多条（重修多学期）：已获学分优先、学期最晚次之', () {
      final failed = rec('T1', '大学物理Ⅱ',
          grade: 55, passed: false, semester: '2023-B');
      final passedLate = rec('T1', '大学物理Ⅱ',
          grade: 88, passed: true, semester: '2024-B');
      final passedEarly = rec('T1', '大学物理Ⅱ',
          grade: 90, passed: true, semester: '2023-A');
      final hit = matchRecordForCourse(
          courseId: 'T1', name: '大学物理Ⅱ', records: [failed, passedEarly, passedLate]);
      expect(hit, same(passedLate));
    });

    test('包含兜底：唯一命中才认', () {
      final records = [rec('DS1', '数据结构（英）', grade: 85, passed: true)];
      expect(
          matchRecordForCourse(
              courseId: null, name: '数据结构', records: records),
          same(records.first));
    });

    test('包含兜底：多候选歧义 → 宁缺勿猜返回 null', () {
      final records = [
        rec('PE3', '体育Ⅲ', grade: 80, passed: true),
        rec('PE4', '体育Ⅳ', grade: 85, passed: true),
      ];
      expect(
          matchRecordForCourse(courseId: null, name: '体育', records: records),
          isNull);
    });

    test('包含兜底：单字名不参与（防误配）；空名/空记录不抛异常', () {
      expect(
          matchRecordForCourse(
              courseId: null, name: '物', records: [rec('P1', '物理实验')]),
          isNull);
      expect(
          matchRecordForCourse(courseId: null, name: '', records: const []),
          isNull);
      expect(
          matchRecordForCourse(
              courseId: '', name: '大学英语', records: [rec('E1', '')]),
          isNull);
    });

    test('完全无命中 → null', () {
      expect(
          matchRecordForCourse(
              courseId: null,
              name: '天体物理导论',
              records: [rec('X', '高等数学（甲）Ⅰ')]),
          isNull);
    });
  });

  group('recordEarnedCredit（已获学分口径）', () {
    test('passed 优先 / 缺省 grade>=60；credit_included=false 一票否决', () {
      expect(recordEarnedCredit(rec('A', '甲', grade: 92, passed: true)),
          isTrue);
      expect(recordEarnedCredit(rec('B', '乙', grade: 75)), isTrue);
      expect(recordEarnedCredit(rec('C', '丙', grade: 50, passed: false)),
          isFalse);
      expect(recordEarnedCredit(rec('D', '丁', grade: 92, creditIncluded: false)),
          isFalse);
      expect(recordEarnedCredit(rec('E', '戊')), isFalse); // 无成绩不猜
    });
  });

  group('semesterChipColumns（诉求 #8 等宽布局）', () {
    test('按 96px 下限均分，窄屏减列、宽屏封顶 8', () {
      expect(semesterChipColumns(400), 4);
      expect(semesterChipColumns(350), 3);
      expect(semesterChipColumns(96), 1);
      expect(semesterChipColumns(800), 8);
      expect(semesterChipColumns(2000), 8);
    });

    test('非法宽度不抛异常，按 1 列处理', () {
      expect(semesterChipColumns(0), 1);
      expect(semesterChipColumns(-5), 1);
      expect(semesterChipColumns(95), 1);
    });
  });
}
