// test/engine_test.dart — Python engine/tests/test_engine.py 的完整 Dart 移植。
// 双引擎同源同数据：任何一侧行为漂移都会在这里失败（答辩"算错了谁负责"的证据）。
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:compass_app/engine/adapters.dart';
import 'package:compass_app/engine/audit.dart';
import 'package:compass_app/engine/timeline.dart';

Map<String, dynamic> loadPlan(String major) =>
    json.decode(File('assets/golden/$major.json').readAsStringSync()) as Map<String, dynamic>;

final cs = loadPlan('computer_science');
final se = loadPlan('software_engineering');
final engine = AuditEngine({'computer_science': cs, 'software_engineering': se});

Map<String, dynamic> rec({String major = 'computer_science', String current = '2026-A',
    List<Map<String, dynamic>> courses = const [], List planned = const []}) =>
    {
      'student': {'alias': 't', 'major': major, 'grade': '2023', 'current_semester': current},
      'source': 'paste',
      'courses': courses,
      'planned_courses': planned,
    };

Map<String, dynamic> cr(String? cid, String name, double credits, {double grade = 80, String sem = '2025-A'}) =>
    {'course_id': cid, 'name': name, 'credits': credits, 'grade': grade, 'semester': sem};

void main() {
  group('timeline', () {
    test('sem order', () {
      expect(Timeline.semIdx('2026-A') < Timeline.semIdx('2026-B'), isTrue);
      expect(Timeline.semIdx('2026-B') < Timeline.semIdx('2027-A'), isTrue);
    });
    test('open idx biennial', () {
      expect(Timeline.courseOpenIdx({'offered': ['春'], 'offered_years': [2027]}, 2023, 6), [2027 * 2 + 1]);
    });
    test('open idx multi', () {
      expect(Timeline.courseOpenIdx({'offered': ['秋', '春'], 'offered_years': null}, 2026, 2),
          [2026 * 2, 2026 * 2 + 1, 2027 * 2, 2027 * 2 + 1]);
    });
  });

  group('three color', () {
    test('green exact', () {
      final general = (cs['courses'] as List)
          .cast<Map<String, dynamic>>()
          .where((c) => c['module_id'] == 'general_required')
          .map((c) => cr(c['course_id'], c['name'], (c['credits'] as num).toDouble()))
          .toList();
      final m = _module(engine.build(rec(courses: general), cs), 'general_required');
      expect(m['color'], 'green');
      expect(m['gap'], 0.0);
    });
    test('yellow when coverable', () {
      final r = engine.build(rec(courses: [cr('CS3101', '人工智能导论', 3.0)]), cs);
      expect(_module(r, 'major_limited')['color'], 'yellow');
    });
    test('red when pool closed', () {
      final r = engine.build(rec(), cs);
      expect(_module(r, 'free_elective')['color'], 'red');
      expect(r['warnings'].any((w) => w['type'] == 'graduation_risk' && '${w['text']}'.contains('任意选修')), isTrue);
    });
    test('failed not counted', () {
      final r = engine.build(rec(courses: [cr('CS3101', '人工智能导论', 3.0, grade: 59)]), cs);
      expect(_module(r, 'major_limited')['earned'], 0.0);
      expect(r['warnings'].any((w) => w['type'] == 'failed_recheck'), isTrue);
    });
  });

  group('prereq', () {
    test('prereq gap detected', () {
      final r = engine.build(rec(courses: [cr('CS3001', '操作系统', 4.0)]), cs);
      expect(r['warnings'].any((w) => w['type'] == 'prereq_gap' && '${w['text']}'.contains('计算机组成原理')), isTrue);
    });
    test('prereq same semester', () {
      final planned = [
        {'course_id': 'CS3002', 'name': '编译原理', 'semester': '2026-B', 'time_slots': []},
        {'course_id': 'CS2001', 'name': '数据结构与算法', 'semester': '2026-B', 'time_slots': []},
      ];
      final r = engine.build(rec(planned: planned), cs);
      final hit = r['warnings'].firstWhere((w) => w['type'] == 'prereq_same_semester');
      expect('${hit['text']}'.contains('拆开两学期'), isTrue);
    });
    test('prereq ok no warning', () {
      final r = engine.build(rec(courses: [
        cr('CS1001', '程序设计基础', 4.0),
        cr('CS2002', '计算机组成原理', 4.0),
        cr('CS2001', '数据结构与算法', 4.0),
      ]), cs);
      expect(r['warnings'].any((w) => w['type'] == 'prereq_gap'), isFalse);
    });
  });

  group('offering', () {
    test('plan wrong season', () {
      final r = engine.build(
          rec(planned: [{'course_id': 'CS2003', 'name': '算法设计与分析', 'semester': '2026-B'}]), cs);
      expect(r['warnings'].any((w) => w['type'] == 'offering_closed' && '${w['text']}'.contains('仅秋')), isTrue);
    });
    test('plan wrong cycle', () {
      final r = engine.build(
          rec(planned: [{'course_id': 'CS3102', 'name': '信息安全导论', 'semester': '2026-B'}]), cs);
      expect(r['warnings'].any((w) => '${w['text']}'.contains('隔年开课')), isTrue);
    });
    test('missed biennial pool', () {
      final m = _module(engine.build(rec(), cs), 'intensive_practice');
      final closed = (m['missing_courses'] as List).cast<Map<String, dynamic>>()
          .firstWhere((c) => c['course_id'] == 'PR4001');
      expect(closed['closed'], isTrue);
    });
  });

  group('time conflict', () {
    test('overlap', () {
      expect(Timeline.slotsConflict(
          [{'day': 2, 'start': 3, 'end': 4}], [{'day': 2, 'start': 4, 'end': 5}]), isNotNull);
    });
    test('week disjoint', () {
      expect(Timeline.slotsConflict(
          [{'day': 2, 'start': 1, 'end': 2, 'week_start': 1, 'week_end': 8}],
          [{'day': 2, 'start': 1, 'end': 2, 'week_start': 9, 'week_end': 16}]), isNull);
    });
    test('plan conflict report', () {
      final planned = [
        {'course_id': 'CS3006', 'name': '计算机体系结构', 'semester': '2027-A',
          'time_slots': [{'day': 5, 'start': 1, 'end': 2}]},
        {'course_id': 'CS3103', 'name': '区块链技术导论', 'semester': '2027-A',
          'time_slots': [{'day': 5, 'start': 2, 'end': 3}]},
      ];
      final r = engine.build(rec(planned: planned), cs);
      expect(r['warnings'].any((w) => w['type'] == 'time_conflict'), isTrue);
    });
  });

  group('adapters', () {
    test('parse paste', () {
      final (courses, failed) = RecordAdapter.parsePaste(
          '2023-A CS1001 程序设计基础 4.0 91\n2023-B 高等数学 5.0 80\n坏行没有学分');
      expect(courses.length, 2);
      expect(courses[0]['course_id'], 'CS1001');
      expect(courses[1]['course_id'], isNull);
      expect(failed, ['坏行没有学分']);
    });
    test('parse export csv', () {
      final (courses, _) = RecordAdapter.parseExportCsv(
          '课程代码,课程名称,学分,成绩,开课学期\nCS1001,程序设计基础,4.0,91,2023-秋\nGS1004,体育（基础）,1.0,89,2024-春');
      expect(courses.length, 2);
      expect(courses[0]['semester'], '2023-A');
      expect(courses[1]['semester'], '2024-B');
    });
    test('main error on empty', () {
      expect(RecordAdapter.run(recordText: '完全不是成绩单的一行文字').containsKey('error'), isTrue);
    });
  });

  group('golden consistency', () {
    test('prereq refs exist', () {
      for (final p in [cs, se]) {
        final ids = (p['courses'] as List).map((c) => c['course_id']).toSet();
        for (final c in (p['courses'] as List).cast<Map<String, dynamic>>()) {
          for (final pre in (c['prereq'] as List)) {
            expect(ids.contains(pre), isTrue, reason: '${c['course_id']} -> $pre');
          }
        }
      }
    });
    test('credits step', () {
      for (final p in [cs, se]) {
        for (final c in (p['courses'] as List).cast<Map<String, dynamic>>()) {
          final d = (c['credits'] as num).toDouble();
          expect(d > 0, isTrue);
          expect((d * 2) % 1, closeTo(0, 1e-9));
        }
      }
    });
  });

  group('end to end', () {
    test('demo sample full report', () {
      final rec1 = json.decode(File('assets/samples/demo1_cs_full.json').readAsStringSync())
          as Map<String, dynamic>;
      final r = engine.build(rec1, cs);
      final types = r['warnings'].map((w) => w['type']).toSet();
      for (final t in ['prereq_gap', 'prereq_same_semester', 'time_conflict',
        'graduation_risk', 'failed_recheck', 'unmatched_courses', 'offering_closed']) {
        expect(types.contains(t), isTrue, reason: t);
      }
      expect(r['disclaimer'], '本报告仅供与导师沟通参考，正式认定以教务系统为准。');
    });
    test('se sample colors', () {
      final rec3 = json.decode(File('assets/samples/demo3_se_full.json').readAsStringSync())
          as Map<String, dynamic>;
      final r = engine.build(rec3, se);
      expect(_module(r, 'general_required')['earned'], 21.0);
      expect(_module(r, 'major_core')['color'], 'yellow');
    });
  });

  // ===== 跨引擎金标：把 Dart 输出落盘，由 CI 与 Python 产物逐字段比对 =====
  test('emit dart report for parity check', () {
    final out = engine.main(json.decode(File('assets/samples/demo1_cs_full.json').readAsStringSync()));
    File('test/golden_dart_report.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out['report']));
  });
}

Map<String, dynamic> _module(Map<String, dynamic> report, String id) =>
    (report['summary'] as List).cast<Map<String, dynamic>>().firstWhere((m) => m['module_id'] == id);
