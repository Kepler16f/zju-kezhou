// test/zju_parse_test.dart — 教务响应解析纯函数单测（真实链路的关键转换）。
import 'package:test/test.dart';

import 'package:compass_app/data/zju_parse.dart';

void main() {
  group('semesterFromXkkh', () {
    test('标准选课课号取学年学期', () {
      // 旧口径连续 8 位（历史样例）
      expect(semesterFromXkkh('220232024-100001'), '2023-A');
      expect(semesterFromXkkh('2320252026-200045'), '2025-B');
    });
    test('真实形态（成绩单实测）：(2026-2027-1)-课程号-班号', () {
      expect(semesterFromXkkh('(2026-2027-1)-ADMN1004G-0011337-1'), '2026-A');
      expect(semesterFromXkkh('(2025-2026-2)-MARX1004G-0011337-1'), '2025-B');
    });
    test('短学期（学期号 3）→ -C', () {
      expect(semesterFromXkkh('(2026-2027-3)-ADMN0704G-0000001-1'), '2026-C');
      expect(semesterFromXkkh('20262027-3-001'), '2026-C');
    });
    test('带分隔符形态', () {
      expect(semesterFromXkkh('2026-2027-1'), '2026-A');
      expect(semesterFromXkkh('2025-2026（2）'), '2025-B');
    });
    test('学年不连续不误匹配', () {
      expect(semesterFromXkkh('20202099-1xx'), isNull);
    });
    test('无模式返回 null', () {
      expect(semesterFromXkkh('xtwkc-体育'), isNull);
    });
  });

  group('inferGradeFromStudentId', () {
    test('32x 学号推入学年', () {
      expect(inferGradeFromStudentId('3260009999'), '2026');
      expect(inferGradeFromStudentId('3230101234'), '2023');
    });
    test('非标准返回 null', () {
      expect(inferGradeFromStudentId('2260101109'), isNull);
      expect(inferGradeFromStudentId(null), isNull);
    });
  });

  group('gradeItemToCourse', () {
    test('百分制通过课', () {
      final c = gradeItemToCourse({
        'kch': 'CS1001', 'kcmc': '程序设计基础', 'xf': '4.0', 'cj': '91',
        'xkkh': '220232024-100001', 'kcxzmc': '专业必修',
      })!;
      expect(c['name'], '程序设计基础');
      expect(c['credits'], 4.0);
      expect(c['grade'], 91);
      expect(c['passed'], true);
      expect(c['semester'], '2023-A');
    });
    test('不及格与弃修不通过', () {
      expect(gradeItemToCourse({'kcmc': 'A', 'xf': '2', 'cj': '55', 'xkkh': '220232024-11'})!['passed'], false);
      expect(gradeItemToCourse({'kcmc': 'B', 'xf': '2', 'cj': '弃修', 'xkkh': '220232024-11'})!['passed'], false);
      expect(gradeItemToCourse({'kcmc': 'C', 'xf': '2', 'cj': '及格', 'xkkh': '220232024-21'})!['passed'], true);
      expect(gradeItemToCourse({'kcmc': 'D', 'xf': '2', 'cj': '不合格', 'xkkh': '220232024-21'})!['passed'], false);
    });
    test('空名条目丢弃', () {
      expect(gradeItemToCourse({'kcmc': '', 'xf': '1'}), isNull);
    });
  });

  group('currentSemesterFrom', () {
    test('取最晚学期', () {
      expect(
        currentSemesterFrom([
          {'semester': '2023-A'}, {'semester': '2025-B'}, {'semester': '2024-A'},
        ]),
        '2025-B',
      );
      expect(currentSemesterFrom([{'semester': 'unknown'}]), isNull);
    });
  });
}
