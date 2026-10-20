// test/jxb_status_test.dart — 教学班五态判定（zdbk 图例对齐）回归。
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/xk_models.dart';
import 'package:compass_app/engine/jxb_status.dart';

void main() {
  XkCourse mk({
    String xkkh = 'X1',
    String sfxz = '0',
    int? cap,
    int? selected,
    List<Map<String, dynamic>> slots = const [],
  }) =>
      XkCourse(
        kcmc: '测试课',
        kch: 'T1',
        teacher: '张三',
        cap: cap,
        selected: selected,
        slots: slots,
        raw: {'xkkh': xkkh, 'sfxz': sfxz},
      );

  const slot = {
    'day': 2,
    'start': 1,
    'end': 2,
    'week_start': 1,
    'week_end': 16
  };

  group('classifyJxb', () {
    test('已选：sfxz=1 或 xkkh 命中已选清单', () {
      expect(
          classifyJxb(mk(sfxz: '1'),
              chosenXkkh: const {}, busySlots: const []),
          JxbStatus.selected);
      expect(
          classifyJxb(mk(xkkh: 'K9'),
              chosenXkkh: const {'K9'}, busySlots: const []),
          JxbStatus.selected);
    });

    test('余量不足：已选人数 ≥ 容量', () {
      expect(
          classifyJxb(mk(cap: 43, selected: 43, slots: [slot]),
              chosenXkkh: const {}, busySlots: const []),
          JxbStatus.insufficient);
      expect(
          classifyJxb(mk(cap: 43, selected: 2, slots: [slot]),
              chosenXkkh: const {}, busySlots: const []),
          isNot(JxbStatus.insufficient));
    });

    test('冲突：与占用时隙重叠', () {
      expect(
          classifyJxb(mk(cap: 43, selected: 2, slots: [slot]),
              chosenXkkh: const {}, busySlots: const [slot]),
          JxbStatus.conflict);
    });

    test('未选：无时间信息（无法判断可选性）', () {
      expect(
          classifyJxb(mk(), chosenXkkh: const {}, busySlots: const []),
          JxbStatus.unselected);
    });

    test('可选：有余量、无冲突、有时间', () {
      expect(
          classifyJxb(mk(cap: 43, selected: 2, slots: [slot]),
              chosenXkkh: const {}, busySlots: const []),
          JxbStatus.available);
    });

    test('canSimulateJxb：仅可选/未选允许模拟', () {
      expect(canSimulateJxb(JxbStatus.available), isTrue);
      expect(canSimulateJxb(JxbStatus.unselected), isTrue);
      expect(canSimulateJxb(JxbStatus.selected), isFalse);
      expect(canSimulateJxb(JxbStatus.insufficient), isFalse);
      expect(canSimulateJxb(JxbStatus.conflict), isFalse);
    });

    test('标签文案与 zdbk 图例一致', () {
      expect(jxbStatusLabel(JxbStatus.available), '可选');
      expect(jxbStatusLabel(JxbStatus.conflict), '冲突');
      expect(jxbStatusLabel(JxbStatus.insufficient), '余量不足');
      expect(jxbStatusLabel(JxbStatus.unselected), '未选');
      expect(jxbStatusLabel(JxbStatus.selected), '已选');
    });
  });
}
