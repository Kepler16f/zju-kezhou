// 分享包（导师模式 P1）纯 Dart 回归：
//  1. 脱敏红线——导出结果里绝不允许出现分数/绩点/选课凭证/凭证类键；
//  2. 往返一致——导出→解析→record 后课程行可被审计引擎直接消费；
//  3. 宽容校验——版本超界/缺字段/空行都有明确拒入理由。
import 'dart:convert';
import 'dart:io';

import 'package:compass_app/data/share_pack.dart';
import 'package:compass_app/engine/audit.dart';
import 'package:test/test.dart';

Map<String, dynamic> richRow(String name, {int score = 85, bool passed = true}) =>
    {
      'course_id': 'K${name.hashCode.abs() % 10000}',
      'name': name,
      'credits': 2.0,
      'grade': score,
      'five_point': 4.0,
      'five_point_source': 'jd',
      'passed': passed,
      'credit_included': true,
      'gpa_included': true,
      'semester': '2024-A',
      'category': '通识课程',
      'original': '$score',
      'xkkh': '(2024-2025-1)-CS1001-01',
    };

void main() {
  group('buildSharePack 脱敏', () {
    test('导出文本与结构中无任何敏感键/值（分数、绩点、凭证号）', () {
      final packed = buildSharePack(
        student: {
          'alias': '本人',
          'major': 'computer_science',
          'grade': '2023',
          'current_semester': '2026-A',
        },
        courses: [richRow('数据结构'), richRow('编译原理', score: 55, passed: false)],
        plan: {'meta': {'major': 'computer_science'}, 'modules': [], 'courses': []},
      );
      final parsed = json.decode(packed.jsonText) as Map<String, dynamic>;
      expect(scanSensitiveKeys(parsed), isEmpty);
      // 值级抽查：分数文本绝不能以任何形态泄漏到行里
      for (final r in (parsed['courses'] as List).cast<Map>()) {
        expect(r.containsKey('grade'), isFalse);
        expect(r.containsKey('five_point'), isFalse);
        expect(r.containsKey('xkkh'), isFalse);
        expect(r.containsKey('original'), isFalse);
      }
      // 学生默认匿名（alias 传入「本人」→ 保留，但无学号字段）
      expect((parsed['student'] as Map).containsKey('student_id'), isFalse);
    });

    test('passed 缺失时按 grade 兜底换算；两者都缺 → 丢行并计数', () {
      final noPassed = Map<String, dynamic>.from(richRow('A'))
        ..remove('passed');
      final noBoth = Map<String, dynamic>.from(richRow('B'))
        ..remove('passed')
        ..remove('grade');
      final packed = buildSharePack(
        student: {'major': 'm', 'grade': '2023', 'current_semester': '2026-A'},
        courses: [noPassed, noBoth],
        plan: null,
      );
      final parsed = json.decode(packed.jsonText) as Map<String, dynamic>;
      final rows = parsed['courses'] as List;
      expect(rows.length, 1);
      expect(rows[0]['passed'], true); // 85 → 通过
      expect(packed.droppedRows, 1);
    });

    test('plan=null 的裸包合法（专业内置方案可导入）', () {
      final packed = buildSharePack(
        student: {'major': 'computer_science', 'grade': '2023', 'current_semester': '2026-A'},
        courses: [richRow('高等数学')],
        plan: null,
      );
      expect(packed.droppedRows, 0);
      final ok = parseSharePack(packed.jsonText);
      expect(ok, isA<SharePackOk>());
    });
  });

  group('parseSharePack 校验', () {
    String goodJson() => buildSharePack(
          student: {'major': 'cs', 'grade': '2023', 'current_semester': '2026-A'},
          courses: [richRow('C语言')],
          plan: null,
        ).jsonText;

    test('非 JSON / 非课舟包 / 版本超界：各自明确拒入', () {
      expect(parseSharePack('hello'), isA<SharePackError>());
      expect(parseSharePack('{}'), isA<SharePackError>());
      final future = json.decode(goodJson()) as Map<String, dynamic>
        ..['version'] = sharePackVersion + 1;
      final r = parseSharePack(json.encode(future));
      expect((r as SharePackError).message, contains('版本'));
    });

    test('空课程行 / 缺 required 学生字段 → 拒入并列出问题', () {
      final empty = json.decode(goodJson()) as Map<String, dynamic>
        ..['courses'] = [];
      expect((parseSharePack(json.encode(empty)) as SharePackError).message,
          contains('课程行为空'));
      final noSem = json.decode(goodJson()) as Map<String, dynamic>;
      (noSem['student'] as Map)['current_semester'] = '秋季';
      expect((parseSharePack(json.encode(noSem)) as SharePackError).message,
          contains('学生信息'));
    });

    test('合法包往返：record 形状与课程行可被引擎直接消费', () {
      final text = goodJson();
      final ok = parseSharePack(text) as SharePackOk;
      final record = sharePackToRecord(ok.pack);
      expect(record['source'], 'share_pack');
      final first = (record['courses'] as List).first as Map;
      expect(first['name'], 'C语言');
      expect(first['passed'], true);
      expect(first['credits'], 2.0);
    });
  });

  group('引擎兼容性（真实引擎端到端）', () {
    test('分享包 record + 内嵌方案 → AuditEngine.build 直接出三色报告', () {
      final plan = <String, dynamic>{
        'meta': {'major': 'cs', 'grade': '2023'},
        'modules': [
          {'module_id': 'm1', 'title': '专业课', 'required_credits': 4.0}
        ],
        'courses': [
          {
            'course_id': 'K1', 'name': 'C语言', 'credits': 2.0,
            'module_id': 'm1', 'nature': '必修',
            'offered': ['秋'], 'grade_cycle': 4, 'offered_years': null,
            'prereq': <String>[], 'source': {'page': '1'},
          },
          {
            'course_id': 'K2', 'name': '操作系统', 'credits': 2.0,
            'module_id': 'm1', 'nature': '必修',
            'offered': ['春'], 'grade_cycle': 4, 'offered_years': null,
            'prereq': <String>[], 'source': {'page': '1'},
          },
        ],
      };
      final packed = buildSharePack(
        student: {'major': 'cs', 'grade': '2023', 'current_semester': '2026-A'},
        courses: [
          {
            'course_id': 'K1', 'name': 'C语言', 'credits': 2.0,
            'grade': 90, 'passed': true, 'semester': '2024-A',
            'category': '', 'original': '90', 'xkkh': 'secret',
          }
        ],
        plan: plan,
      );
      final ok = parseSharePack(packed.jsonText) as SharePackOk;
      final record = sharePackToRecord(ok.pack);
      final embedded = sharePackPlan(ok.pack)!;

      final engine = AuditEngine({});
      engine.registerRuntimePlan('cs', embedded);
      final out = engine.main(record);
      expect(out.containsKey('error'), false, reason: '${out['error']}');
      final report = out['report'] as Map<String, dynamic>;
      final totals = report['totals'] as Map<String, dynamic>;
      // 已修 2 学分（K1 passed），K2 缺口 2 → 待补/红，由引擎判定
      expect(totals['required'], 4.0);
      expect(totals['earned'], 2.0);
      expect(totals['gap'], 2.0);
      // 脱敏后引擎仍能判定通过（passed 布尔随包带出，grade 缺失不影响 build）
      expect((report['summary'] as List).isNotEmpty, true);
      // 内嵌方案不含学生分数（方案本来就没有，双保险走一遍扫描）
      expect(scanSensitiveKeys(ok.pack), isEmpty);
    });
  });

  group('文件通道', () {
    test('writeSharePack + listSharePackFiles 往返（临时目录）', () async {
      final dir = await Directory.systemTemp.createTemp('kez_share_test');
      try {
        final text = buildSharePack(
          student: {'major': 'cs', 'grade': '2023', 'current_semester': '2026-A'},
          courses: [richRow('线性代数')],
          plan: null,
        ).jsonText;
        final path = await writeSharePack(dir.path, text);
        expect(File(path).existsSync(), true);
        // 文件内容可再解析（UTF-8 完整写出）
        final back = parseSharePack(await File(path).readAsString());
        expect(back, isA<SharePackOk>());
        final listed = await listSharePackFiles(dir.path);
        expect(listed, [path]);
        // 混入非法文件不影响列表
        await File('${dir.path}${Platform.pathSeparator}share${Platform.pathSeparator}junk.json')
            .writeAsString('{"format":"other"}');
        final listed2 = await listSharePackFiles(dir.path);
        expect(listed2.length, 1);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
