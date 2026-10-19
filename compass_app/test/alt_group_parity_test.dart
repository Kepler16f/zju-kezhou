// test/alt_group_parity_test.dart — 并列选项组（三选一）双引擎口径夹具。
//
// 背景（用户 #8 + v1.7 复核）：「本专业进阶 / 跨专业学习（微辅修）/ 学生自主修读」
// 任选其一，只计一次要求学分；选项模块行不得进 totals，落选选项的缺口警告
// 必须清除，组行仍红时只报一条组级风险。golden 样例方案里没有 alternative_groups，
// 所以既有 parity 覆盖不到这条路径——本文件用真实方案形状（2026 级食品
// 「个性修读课程」三选一）做夹具：断言 + 落盘 Dart 侧报告，
// 由 eval/cross_engine_parity.py 与 Python engine 逐字段比对。
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:compass_app/engine/audit.dart';

Map<String, dynamic> _load(String rel) =>
    json.decode(File(rel).readAsStringSync()) as Map<String, dynamic>;

// 纯 Dart 测试的工作目录是 compass_app。
final altPlan = _load('../data/golden_alt/alt_group_demo.json');
final altRec = _load('../data/samples/demo4_alt_group.json');

void main() {
  group('并列选项组（三选一）口径', () {
    final report = AuditEngine({}).build(altRec, altPlan);
    final summary = (report['summary'] as List).cast<Map<String, dynamic>>();
    final group = summary.firstWhere((r) => r['alternative_group'] == true);
    final totals = report['totals'] as Map;
    final warnings = (report['warnings'] as List).cast<Map<String, dynamic>>();

    test('选项模块行不单独进 summary，只留组行一个', () {
      expect(summary.map((r) => r['module_id']),
          containsAll(<String>['core', 'sec33-个性修读课程-alt']));
      for (final id in ['sec34-本专业进阶模块', 'sec35-跨专业学习模块', 'sec36-学生自主修读模块']) {
        expect(summary.map((r) => r['module_id']), isNot(contains(id)));
      }
      expect(group['option_count'], 3);
      expect((group['options'] as List).length, 3);
    });

    test('totals 只计一次并列要求（module_required 20 而非 65）', () {
      expect(totals['module_required'], 20.0);
      expect(totals['required'], 20.0);
      expect(totals['earned'], 6.5); // core 3.0 + 最优选项 3.5
      expect(totals['gap'], 13.5);
      expect(totals['total_basis'], 'plan_declared');
    });

    test('组行按最优选项达成度：15 分要求已获 3.5，缺口 11.5', () {
      expect(group['required'], 15.0);
      expect(group['earned'], 3.5);
      expect(group['gap'], 11.5);
      expect(group['color'], 'red'); // 剩余课程开课窗口已过（学籍年限内补不上）
      final options = (group['options'] as List).cast<Map<String, dynamic>>();
      expect(options.first['title'], '本专业进阶模块');
      expect(options.first['earned'], 3.5);
    });

    test('落选选项缺口警告清除，组行只报一条组级风险', () {
      final riskTexts = warnings
          .where((w) => w['type'] == 'graduation_risk')
          .map((w) => '${w['text']}')
          .toList();
      expect(riskTexts, hasLength(1));
      expect(riskTexts.single, contains('「个性修读课程」'));
      expect(riskTexts.single, isNot(contains('本专业进阶模块')));
      expect((report['caliber_notes'] as List).join(), contains('并列模块口径'));
    });

    test('组行 plan_courses 汇总最优选项明细', () {
      final courses = (group['plan_courses'] as List).cast<Map<String, dynamic>>();
      expect(courses.map((c) => c['course_id']),
          containsAll(<String>['BEFS2051M', 'BEFS2056M', 'BEFS3058M']));
      expect(courses.where((c) => c['passed'] == true).length, 2);
    });

    // 落盘 Dart 侧输出，供 eval/cross_engine_parity.py 与 Python 引擎逐字段比对。
    test('emit alt-group dart report for parity check', () {
      File('test/golden_dart_report_alt.json').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(report));
    });
  });
}
