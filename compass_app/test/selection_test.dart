// test/selection_test.dart — 选课候选分析回归（确定性，手算断言）。
// 护栏：offered 缺失=未知（绝不回显关闭语义）、课表未知=未检查（不代表无冲突）。
import 'package:test/test.dart';

import 'package:compass_app/data/xk_models.dart';
import 'package:compass_app/engine/selection.dart';

Map<String, dynamic> pc(String id, String name, double credits,
        {List<String>? offered, List<String> prereq = const [], int page = 10}) =>
    {
      'course_id': id,
      'name': name,
      'credits': credits,
      if (offered != null) 'offered': offered,
      if (offered == null) 'offered': null,
      'prereq': prereq,
      'source': {'page': page},
    };

XkCourse xc(String kcmc,
        {String kch = '',
        String kchId = '',
        String jxbId = '',
        String sksj = '',
        double? xf,
        int? cap,
        int? selected,
        List<Map<String, dynamic>> slots = const []}) =>
    XkCourse(
      kcmc: kcmc,
      kch: kch,
      kchId: kchId,
      jxbId: jxbId,
      sksj: sksj,
      xf: xf,
      cap: cap,
      selected: selected,
      slots: slots,
      xkkzId: 'R1',
    );

XkMergedCourse mc(XkCourse base) =>
    XkMergedCourse(base: base, byRound: const {}, roundOrder: const ['R1']);

final plan = [
  pc('CS1001', '程序设计基础', 4.0, offered: ['秋', '春'], page: 8),
  pc('CS2001', '数据结构与算法', 4.0, offered: ['秋'], prereq: ['CS1001'], page: 23),
  pc('CS3101', '人工智能导论', 3.0, page: 24), // offered 缺失（runtime 方案常态）
];

final transcript = [
  {'course_id': 'CS1001', 'name': '程序设计基础', 'credits': 4.0, 'grade': 90},
];

void main() {
  test('缺口课程：exact 匹配 + 开课季匹配 + 时间冲突', () {
    final r = buildSelectionAdvice(SelectionRequest(
      candidates: [
        mc(xc('数据结构与算法', kch: 'CS2001', jxbId: 'B1', kchId: 'A1',
            sksj: '星期一第3-4节{1-16周}',
            slots: const [
              {'day': 1, 'start': 3, 'end': 4, 'week_start': 1, 'week_end': 16}
            ])),
      ],
      transcript: transcript,
      planCourses: plan,
      currentSemester: '2026-A',
      currentTimetableKnown: true,
      currentTimetableSlots: const [
        {'day': 1, 'start': 4, 'end': 5, 'week_start': 1, 'week_end': 16}
      ],
    ));
    final a = r.candidates.single;
    expect(a.role, 'gap');
    expect(a.matchConfidence, 'exact');
    expect(a.offeredMatch, 'yes');
    expect(a.prereqIncomplete, isFalse);
    expect(a.conflictTexts.single, '与当前课表重叠：周一 第4节（第1-16周）');
    expect(r.counts['conflict'], 1);
    expect(r.warnings.any((w) => w['type'] == 'xk_time_conflict'), isTrue);
    expect(r.disclaimer, '本报告仅供与导师沟通参考，正式认定以教务系统为准。');
  });

  test('offered 缺失 = 未知，绝不当作不开课', () {
    final r = buildSelectionAdvice(SelectionRequest(
      candidates: [mc(xc('人工智能导论', kch: 'CS3101', jxbId: 'B2', kchId: 'A2'))],
      transcript: transcript,
      planCourses: plan,
      currentSemester: '2026-A',
      currentTimetableKnown: true,
    ));
    final a = r.candidates.single;
    expect(a.offeredMatch, 'unknown');
    expect(a.notes.any((n) => n.contains('未标注开课季')), isTrue);
    expect(r.warnings, isEmpty);
  });

  test('先修未完成：标记 + 告警', () {
    final r = buildSelectionAdvice(SelectionRequest(
      candidates: [mc(xc('数据结构与算法', kch: 'CS2001', jxbId: 'B1', kchId: 'A1'))],
      transcript: const [], // CS1001 未修
      planCourses: plan,
      currentSemester: '2026-A',
      currentTimetableKnown: true,
    ));
    final a = r.candidates.single;
    expect(a.prereqIncomplete, isTrue);
    expect(a.notes.any((n) => n.contains('先修未完成') && n.contains('程序设计基础')), isTrue);
    final w = r.warnings.firstWhere((w) => w['type'] == 'xk_prereq_incomplete');
    expect('${w['refs']}'.contains('CS2001@p23'), isTrue);
  });

  test('已修课程：passed；方案外课程：extra', () {
    final r = buildSelectionAdvice(SelectionRequest(
      candidates: [
        mc(xc('程序设计基础', kch: 'CS1001', jxbId: 'B3', kchId: 'A3')),
        mc(xc('大学物理', kch: 'PHY101', jxbId: 'B4', kchId: 'A4')),
      ],
      transcript: transcript,
      planCourses: plan,
      currentSemester: '2026-A',
      currentTimetableKnown: true,
    ));
    expect(r.candidates[0].role, 'passed');
    expect(r.candidates[0].notes.any((n) => n.contains('已修读')), isTrue);
    expect(r.candidates[1].role, 'extra');
    expect(r.candidates[1].matchConfidence, 'none');
    expect(r.counts['passed'], 1);
    expect(r.counts['extra'], 1);
  });

  test('kch 为空走名称 fuzzy 匹配', () {
    final r = buildSelectionAdvice(SelectionRequest(
      candidates: [mc(xc('数据结构与算法', jxbId: 'B1', kchId: 'A1'))],
      transcript: transcript,
      planCourses: plan,
      currentSemester: '2026-A',
      currentTimetableKnown: true,
    ));
    expect(r.candidates.single.matchConfidence, 'fuzzy');
    expect(r.candidates.single.role, 'gap');
  });

  test('课表未知：声明未检查，绝不渲染成无冲突', () {
    final r = buildSelectionAdvice(SelectionRequest(
      candidates: [mc(xc('人工智能导论', kch: 'CS3101', jxbId: 'B2', kchId: 'A2'))],
      transcript: transcript,
      planCourses: plan,
      currentSemester: '2026-A',
      currentTimetableKnown: false,
    ));
    expect(r.notes.any((n) => n.contains('未做时间冲突检查')), isTrue);
    expect(r.candidates.single.conflictTexts, isEmpty);
    expect(r.counts['conflict'], 0);
  });

  test('时隙缺失但有原文：留痕「冲突未检查」', () {
    final r = buildSelectionAdvice(SelectionRequest(
      candidates: [
        mc(xc('人工智能导论', kch: 'CS3101', jxbId: 'B2', kchId: 'A2', sksj: '见教务网'))
      ],
      transcript: transcript,
      planCourses: plan,
      currentSemester: '2026-A',
      currentTimetableKnown: true,
      currentTimetableSlots: const [
        {'day': 1, 'start': 1, 'end': 2}
      ],
    ));
    expect(r.candidates.single.notes.any((n) => n.contains('冲突未检查')), isTrue);
  });

  test('学期未知：不做出结论 + 开课季未知', () {
    final r = buildSelectionAdvice(SelectionRequest(
      candidates: [mc(xc('数据结构与算法', kch: 'CS2001', jxbId: 'B1', kchId: 'A1'))],
      transcript: transcript,
      planCourses: plan,
      currentTimetableKnown: true,
    ));
    expect(r.notes.any((n) => n.contains('当前学期未知')), isTrue);
    expect(r.candidates.single.offeredMatch, 'unknown');
  });

  test('空输入不崩 + 提示', () {
    final r = buildSelectionAdvice(const SelectionRequest(candidates: []));
    expect(r.candidates, isEmpty);
    expect(r.notes.any((n) => n.contains('尚无候选选课数据')), isTrue);
  });

  test('adviceToPromptJson 仅含白名单字段，不含成绩/身份', () {
    final r = buildSelectionAdvice(SelectionRequest(
      candidates: [
        mc(xc('数据结构与算法', kch: 'CS2001', jxbId: 'B1', kchId: 'A1',
            sksj: '星期一第3-4节{1-16周}', cap: 60, selected: 45, xf: 4.0))
      ],
      transcript: transcript,
      planCourses: plan,
      currentSemester: '2026-A',
      currentTimetableKnown: true,
    ));
    final j = adviceToPromptJson(r);
    final text = '$j';
    expect(text.contains('数据结构与算法'), isTrue);
    expect(text.contains('grade'), isFalse);
    expect(text.contains('学号'), isFalse);
    expect(text.contains('程序设计基础'), isFalse); // 已修明细不进 payload
    expect((j['candidates'] as List).single['capacity'], 60);
    expect(j['disclaimer'], r.disclaimer);
  });
}
