// test/exam_test.dart — 考试冲刺引擎单测（解析/窗口/冲突/连考/倒计时，手算对照）。
import 'package:test/test.dart';

import 'package:compass_app/engine/exam.dart';

ExamInfo ex(String name, String startIso, int minutes,
        {String loc = '紫金港校区 东1A-201', String seat = '12'}) =>
    ExamInfo(
        name: name,
        start: DateTime.parse(startIso),
        end: DateTime.parse(startIso).add(Duration(minutes: minutes)),
        location: loc,
        seat: seat);

void main() {
  group('examFromRow（正方行解析）', () {
    test('完整区间字段（kssj 含日期）', () {
      final e = examFromRow({
        'kcmc': '数据结构',
        'kssj': '2026-01-20 08:00~10:00',
        'jsmc': '紫金港校区 东1A-201',
        'zwh': '07',
      });
      expect(e, isNotNull);
      expect(e!.name, '数据结构');
      expect(e.start, DateTime(2026, 1, 20, 8));
      expect(e.end, DateTime(2026, 1, 20, 10));
      expect(e.location, '紫金港校区 东1A-201');
      expect(e.seat, '07');
    });
    test('拆分字段（ksrq + kssj）与 "-" 区间符、单数月日', () {
      final e = examFromRow(
          {'ksmc': '高等数学', 'ksrq': '2026-1-5', 'kssj': '14:00-15:50'});
      expect(e!.start, DateTime(2026, 1, 5, 14));
      expect(e.end, DateTime(2026, 1, 5, 15, 50));
    });
    test('无结束时间默认 2 小时；缺课程名/时间返回 null', () {
      expect(
          examFromRow({'kcmc': '体育', 'ksrq': '2026-01-20', 'kssj': '09:00'})!
              .end,
          DateTime(2026, 1, 20, 11));
      expect(examFromRow({'ksrq': '2026-01-20', 'kssj': '09:00'}), isNull);
      expect(examFromRow({'kcmc': '数据结构'}), isNull);
    });
    test('examsFromRows 排序与脏行过滤', () {
      final es = examsFromRows([
        {'kcmc': 'B', 'kssj': '2026-01-21 09:00~11:00'},
        'dirty-row',
        {'kcmc': 'A', 'kssj': '2026-01-20 08:00~10:00'},
        {'no-name': 1},
      ]);
      expect(es.map((e) => e.name).toList(), ['A', 'B']);
    });
  });

  group('examsFromHtmlTable（HTML 兜底）', () {
    test('两行表格解析（名称/时间/地点/座位）', () {
      const html = '''
      <table>
        <tr><th>课程</th><th>时间</th><th>地点</th><th>座位</th></tr>
        <tr><td>数据结构</td><td>2026-01-20 08:00~10:00</td><td>紫金港 东1A-201</td><td>7</td></tr>
        <tr><td>操作系统</td><td>2026-01-22 14:00-16:00</td><td>紫金港 东2-301</td><td>33</td></tr>
      </table>''';
      final es = examsFromHtmlTable(html);
      expect(es.length, 2);
      expect(es[0].name, '数据结构');
      expect(es[0].location, '紫金港 东1A-201');
      expect(es[0].seat, '7');
      expect(es[1].start, DateTime(2026, 1, 22, 14));
      expect(es[1].end, DateTime(2026, 1, 22, 16));
    });
    test('无时间列的表被整表跳过', () {
      expect(
          examsFromHtmlTable(
              '<tr><td>只是普通表格</td><td>没有时间</td></tr>'),
          isEmpty);
    });
  });

  group('examSprint（窗口/冲突/连考）', () {
    final now = DateTime(2026, 1, 10, 12);
    test('21 天窗口过滤 + 最近一场置顶', () {
      final r = examSprint([
        ex('远期', '2026-02-20 09:00', 120), // 41 天后，出窗
        ex('过期', '2026-01-01 09:00', 120), // 已结束
        ex('下一场', '2026-01-11 09:00', 120),
        ex('次场', '2026-01-15 09:00', 120),
      ], now);
      expect(r.upcoming.map((e) => e.name).toList(), ['下一场', '次场']);
      expect(r.next!.name, '下一场');
    });
    test('排考时间重叠 → 冲突对（不另判连考）', () {
      final r = examSprint([
        ex('甲', '2026-01-11 09:00', 120),
        ex('乙', '2026-01-11 10:00', 120),
      ], now);
      expect(r.conflicts.length, 1);
      expect(r.conflicts[0].$1.name, '甲');
      expect(r.conflicts[0].$2.name, '乙');
      expect(r.sameDayRush, isEmpty);
    });
    test('同日连考（间隔 < 90 分钟）', () {
      final r = examSprint([
        ex('甲', '2026-01-11 09:00', 120), // 09:00-11:00
        ex('乙', '2026-01-11 12:00', 120), // 间隔 60 分钟
        ex('丙', '2026-01-12 14:00', 120), // 隔日，不判连考
      ], now);
      expect(r.conflicts, isEmpty);
      expect(r.sameDayRush.length, 1);
      expect(r.sameDayRush[0].$1.name, '甲');
      expect(r.sameDayRush[0].$2.name, '乙');
    });
    test('间隔 ≥ 90 分钟不判连考', () {
      final r = examSprint([
        ex('甲', '2026-01-11 09:00', 120), // 09:00-11:00
        ex('乙', '2026-01-11 12:31', 60), // 间隔 91 分钟
      ], now);
      expect(r.sameDayRush, isEmpty);
    });
    test('空输入安全', () {
      final r = examSprint(const [], now);
      expect(r.upcoming, isEmpty);
      expect(r.next, isNull);
      expect(r.conflicts, isEmpty);
      expect(r.sameDayRush, isEmpty);
    });
  });

  group('countdownText', () {
    test('分档文案', () {
      expect(countdownText(const Duration(days: 2, hours: 14)), '2 天 14 小时');
      expect(countdownText(const Duration(hours: 3, minutes: 5)), '3 小时 5 分');
      expect(countdownText(const Duration(minutes: 45)), '45 分钟');
      expect(countdownText(const Duration(minutes: -5)), '已开考');
    });
  });

  group('ExamInfo.locationFull', () {
    test('缺省兜底文案', () {
      expect(ex('甲', '2026-01-11 09:00', 60, loc: '', seat: '').locationFull,
          '考场待公布');
      expect(ex('甲', '2026-01-11 09:00', 60, loc: '', seat: '8').locationFull,
          '考场待公布（座位 8）');
    });
  });
}
