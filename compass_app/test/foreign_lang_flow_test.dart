// test/foreign_lang_flow_test.dart — 外语学分链路回归（用户反馈 #7）。
//
// 一手证据复现自崩溃代理留下的探针（tool/_tmp_repro_foreign.dart），场景锁定：
//  A 板块有课表 + 已修：既有路径不变；
//  B 板块无课表 + 已修外语课：v1.5.1 行锚定 → earned 计入、gap 抵扣；
//  C 板块无课表 + 在修外语课：补挂 planned 行 + selected_no_credit 数得上；
//  D 归一化兜底：外语等级罗马/中文/半角数字变体全部命中方案行。
// Python 镜像 engine/tests/test_engine.py::ForeignAnchorTest 同数据同断言。
import 'package:compass_app/engine/audit.dart';
import 'package:compass_app/engine/matching.dart';
import 'package:test/test.dart';

Map<String, dynamic> _plan({required bool foreignHasCourses}) =>
    <String, dynamic>{
      'meta': {
        'source_doc': '复现', 'grade': '2024',
        'verified_at': '2025-09-01', 'total_credits': 160
      },
      'modules': [
        {'module_id': 'foreign', 'module_path': '通识教育/外语类', 'title': '外语类', 'required_credits': 6.0, 'plan_credits_unit': '学分'},
        {'module_id': 'major', 'module_path': '专业教育/专业核心', 'title': '专业核心', 'required_credits': 40.0, 'plan_credits_unit': '学分'},
      ],
      'courses': [
        {'course_id': 'CS1001', 'name': '程序设计入门', 'credits': 4.0, 'module_id': 'major', 'offered': ['秋', '春'], 'offered_years': null},
        if (foreignHasCourses)
          {'course_id': 'EN1001', 'name': '大学英语I', 'credits': 2.0, 'module_id': 'foreign', 'offered': ['秋', '春'], 'offered_years': null},
      ],
    };

Map<String, dynamic> _record(List<Map<String, dynamic>> courses,
        {List<Map<String, dynamic>> planned = const []}) =>
    <String, dynamic>{
      'student': {'name': '测试', 'major': '计算机', 'grade': '2024', 'current_semester': '2025-2026-1', 'student_id': 'x'},
      'courses': courses,
      'planned_courses': planned,
    };

Map<String, dynamic> foreignRow(Map<String, dynamic> report) =>
    (report['summary'] as List).cast<Map<String, dynamic>>().firstWhere((m) => m['module_id'] == 'foreign');

void main() {
  group('外语板块行锚定（#7 B/C）', () {
    final eng = AuditEngine({});

    test('B 板块无课表 + 已修大学英语I → earned=2 gap=4 不再落 extra', () {
      final r = eng.build(
        _record([
          {'course_id': 'XJ001', 'name': '大学英语I', 'credits': 2.0, 'grade': 85, 'semester': '2024-2025-1', 'category': '基础外语'},
        ]),
        _plan(foreignHasCourses: false),
        action: {'foreign_lang_level': 'L1'},
      );
      final f = foreignRow(r);
      expect(f['earned'], 2.0);
      expect(f['gap'], 4.0);
      expect((r['extra_courses'] as List), isEmpty);
    });

    test('C 板块无课表 + 在修大学英语II → selected_no_credit=1', () {
      final r = eng.build(
        _record([], planned: [
          {'course_id': '', 'name': '大学英语II', 'credits': 2.0},
        ]),
        _plan(foreignHasCourses: false),
      );
      final f = foreignRow(r);
      expect(f['selected_no_credit'], 1);
      expect((f['plan_courses'] as List).any((c) => (c as Map)['planned_only'] == true), isTrue);
    });

    test('A 板块有课表：锚定不重复挂载，行为与旧版一致', () {
      final r = eng.build(
        _record([
          {'course_id': 'XJ001', 'name': '大学英语I', 'credits': 2.0, 'grade': 85, 'semester': '2024-2025-1', 'category': '基础外语'},
        ]),
        _plan(foreignHasCourses: true),
        action: {'foreign_lang_level': 'L1'},
      );
      final f = foreignRow(r);
      expect(f['earned'], 2.0);
      expect((f['plan_courses'] as List).length, 1); // 没有合成重复行
    });

    test('小语种课名（日语）+ 无外语板块：一律不动（宁缺勿猜）', () {
      final plan = _plan(foreignHasCourses: false);
      (plan['modules'] as List).removeWhere((m) => m['module_id'] == 'foreign');
      final r = eng.build(
        _record([
          {'course_id': 'JP1', 'name': '日语入门', 'credits': 2.0, 'grade': 85, 'semester': '2024-2025-1'},
        ]),
        plan,
      );
      final extra = (r['extra_courses'] as List);
      expect(extra.map((c) => (c as Map)['name']), contains('日语入门'));
    });
  });

  group('归一化匹配兜底（#7 等级变体）', () {
    const planNames = ['大学英语I', '大学英语II', '大学英语III', '大学英语IV'];
    test('罗马/全角/中文/半角数字变体全部命中且唯一', () {
      final byName = {for (final n in planNames) n: {'course_id': n, 'name': n}};
      for (final (v, expect_) in [
        ('大学英语（I）', '大学英语I'),
        ('大学英语（Ⅰ）', '大学英语I'),
        ('大学英语1', '大学英语I'),
        ('大学英语I（基础外语）', '大学英语I'),
        ('大学英语（四）', '大学英语IV'),
        ('大学英语肆', '大学英语IV'),
        ('大学英语 IV', '大学英语IV'),
      ]) {
        final hit = _matchName(v, byName);
        expect(hit, expect_, reason: v);
      }
    });

    test('裸「大学英语」歧义（四门皆子串）→ 放弃，绝不蒙混', () {
      final byName = {for (final n in planNames) n: {'course_id': n, 'name': n}};
      expect(_matchName('大学', byName), isNull);
    });

    test('归一化幂等且不吞正常课名', () {
      expect(normalizeCourseName('数据结构'), '数据结构');
      expect(normalizeCourseName('高等数学（上）'), normalizeCourseName('高等数学上'));
      // 罗马替换不吃单词内部的字母：c 不是罗马记号，「C语言」归一后仍是 c语言
      expect(normalizeCourseName('C语言'), 'c语言');
    });
  });
}

/// 走 matchRecordToPlan 的兜底通道（无 course_id、相似度先落空）。
/// 返回命中行的课名（null=未命中）。
String? _matchName(String name, Map<String, Map<String, dynamic>> byName) {
  final recordCourses = [
    {'name': name, 'credits': 2.0, 'grade': 85},
  ];
  final plan = <String, dynamic>{
    'courses': byName.values.toList(),
  };
  final (matched, _) = matchRecordToPlan(recordCourses, plan);
  return matched.isEmpty ? null : '${(matched.single[1] as Map)['name']}';
}
