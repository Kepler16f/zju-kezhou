// 分享包 v3 回归（任务 #12）：本学期已选/模拟选课清单进入教师分享包。
//  1. buildSharePack → validateSharePack → sharePackToRecord 往返：selected_courses
//     映射为 record.planned_courses（course_id/name/credits/slots 对齐引擎口径）；
//  2. v2 旧包向后兼容：无 selected_courses 段视为空，record 不带 planned_courses；
//  3. 敏感键扫描覆盖 selected_courses（成绩字段被白名单挡在包外）；
//  4. exportRowsFromPlanned：XkCourse → 白名单展示行（空字段不写入）。
import 'dart:convert';

import 'package:compass_app/data/share_pack.dart';
import 'package:compass_app/data/xk_models.dart';
import 'package:compass_app/data/xk_parse.dart';
import 'package:compass_app/engine/selection.dart';
import 'package:test/test.dart';

Map<String, dynamic> _student() => {
      'alias': '匿名同学',
      'major': 'computer_science',
      'grade': '2024',
      'current_semester': '2026-A',
    };

void main() {
  group('sharePack v3 selected_courses', () {
    test('往返：导出→校验→record，planned_courses 字段对齐引擎形状', () {
      final packed = buildSharePack(
        student: _student(),
        courses: [
          {'name': '数据结构', 'credits': 4.0, 'passed': true},
        ],
        plan: null,
        selectedCourses: [
          {
            'course_id': 'CS2001',
            'name': '编译原理',
            'credits': 3.0,
            'teacher': '王教授',
            'sksj': '周一 3-4',
            'cdmc': '玉泉1-101',
            'semester': '2026-A',
          },
          {'name': '算法设计'}, // 无 id：留给引擎名称相似度匹配
        ],
      );
      final parsed = json.decode(packed.jsonText) as Map<String, dynamic>;
      expect(parsed['version'], 3);
      expect(validateSharePack(parsed), isEmpty);
      final record = sharePackToRecord(parsed);
      final planned = record['planned_courses'] as List;
      expect(planned, hasLength(2));
      final first = planned.first as Map;
      expect(first['course_id'], 'CS2001');
      expect(first['name'], '编译原理');
      expect(first['credits'], 3.0);
      expect(first['teacher'], '王教授');
      expect(first['sksj'], '周一 3-4');
      expect(first['cdmc'], '玉泉1-101');
      // 第二行无 id：不造假，留 null 供名称匹配
      expect((planned[1] as Map)['course_id'], isNull);
    });

    test('白名单强制：调用方塞成绩字段也进不了 selected_courses', () {
      final packed = buildSharePack(
        student: _student(),
        courses: [],
        selectedCourses: [
          {
            'name': '毛概',
            'grade': 91, // 越权字段：必须被白名单过滤
            'xkkh': '(2026-2027-1)-MK-01',
            'raw': {'secret': 1},
          },
        ],
      );
      final parsed = json.decode(packed.jsonText) as Map<String, dynamic>;
      final sel = (parsed['selected_courses'] as List).cast<Map>();
      expect(sel.single.keys.toSet(), {'name'});
      // 有 name 的行被保留（越权字段由白名单滤掉而非丢行），不计 droppedRows
      expect(packed.droppedRows, 0);
      expect(scanSensitiveKeys(parsed), isEmpty);
    });

    test('无 name 的选课行丢行计数（宁缺勿猜）', () {
      final packed = buildSharePack(
        student: _student(),
        courses: [],
        selectedCourses: [
          {'course_id': 'X1'},
          {'name': '  '},
        ],
      );
      expect(packed.droppedRows, 2);
      final parsed = json.decode(packed.jsonText) as Map<String, dynamic>;
      expect(parsed.containsKey('selected_courses'), isFalse);
    });

    test('v2 旧包向后兼容：无段合法且 record 不带 planned_courses', () {
      final packed = buildSharePack(
        student: _student(),
        courses: [
          {'name': '数据结构', 'credits': 4.0, 'passed': true},
        ],
      );
      final parsed = json.decode(packed.jsonText) as Map<String, dynamic>;
      final legacy = Map<String, dynamic>.from(parsed)..['version'] = 2;
      expect(validateSharePack(legacy), isEmpty);
      final record = sharePackToRecord(legacy);
      expect(record.containsKey('planned_courses'), isFalse);
      expect(sharePackSelected(legacy), isEmpty);
    });

    test('selected_courses 里的敏感键被扫描拒入', () {
      final packed = buildSharePack(
        student: _student(),
        courses: [],
        selectedCourses: [
          {'name': 'A', 'course_id': 'K1'},
        ],
      );
      final parsed = json.decode(packed.jsonText) as Map<String, dynamic>;
      // 模拟被篡改的包：手工塞 grade 进选课行
      (((parsed['selected_courses'] as List).first) as Map)['grade'] = 90;
      expect(scanSensitiveKeys(parsed), contains('grade'));
    });

    test('高版本包被拒', () {
      final packed = buildSharePack(
        student: _student(),
        courses: [],
      );
      final parsed = json.decode(packed.jsonText) as Map<String, dynamic>;
      parsed['version'] = sharePackVersion + 1;
      expect(validateSharePack(parsed), isNotEmpty);
    });
  });

  group('exportRowsFromPlanned', () {
    test('XkCourse → 白名单展示行；空字段与未知学分不写入', () {
      final res = XkListParseResult(
        state: 'data',
        courses: [
          const XkCourse(
            kcmc: '编译原理',
            kch: 'CS2001',
            xf: 3.0,
            teacher: '王教授',
            sksj: '周一 3-4',
            cdmc: '玉泉1-101',
          ),
          const XkCourse(kcmc: '算法设计'), // 其余字段全空
        ],
      );
      final rows = exportRowsFromPlanned(res, semester: '2026-A');
      expect(rows, hasLength(2));
      expect(rows.first.keys.toSet(),
          {'course_id', 'name', 'credits', 'teacher', 'sksj', 'cdmc', 'semester'});
      expect(rows[1].keys.toSet(), {'course_id', 'name', 'semester'});
      expect(rows[1]['course_id'], ''); // 无课号留空，不造假
    });

    test('同一（课号,课名）多行去重；非 data 态返回空', () {
      final dup = XkListParseResult(
        state: 'data',
        courses: [
          const XkCourse(kcmc: 'A课', kch: 'K1', xf: 2),
          const XkCourse(kcmc: 'A课', kch: 'K1', xf: 2),
        ],
      );
      expect(exportRowsFromPlanned(dup), hasLength(1));
      expect(exportRowsFromPlanned(null), isEmpty);
      expect(
          exportRowsFromPlanned(
              XkListParseResult(state: 'empty', courses: const [])),
          isEmpty);
    });
  });
}
