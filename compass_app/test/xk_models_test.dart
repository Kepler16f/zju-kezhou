// test/xk_models_test.dart — 选课身份键与跨轮次合并回归（纯 Dart）。
// 护栏：身份三档降级链与「疑似同班不静默合并」是评审A3/A4结论，勿回退。
import 'package:test/test.dart';

import 'package:compass_app/data/xk_models.dart';

XkCourse c({
  String kcmc = '数据结构',
  String kch = 'CS101',
  String kchId = 'A1',
  String jxbId = 'B1',
  String teacher = '',
  String sksj = '',
  double? xf,
  int? cap,
  int? selected,
  String xkkz = 'R1',
  String? xklc,
}) =>
    XkCourse(
      kcmc: kcmc,
      kch: kch,
      kchId: kchId,
      jxbId: jxbId,
      teacher: teacher,
      sksj: sksj,
      xf: xf,
      cap: cap,
      selected: selected,
      xkkzId: xkkz,
      xklc: xklc,
    );

void main() {
  group('身份三档降级链', () {
    test('档1：kch_id + jxb_id + 课程名（三段均归一化，评审L2）', () {
      final x = c();
      expect(x.identityTier, 1);
      expect(x.identityKey, 'j|a1|b1|数据结构');
      // 大小写差异不得把同一教学班拆成两张卡
      final up = c(kchId: '', kch: 'MATH1131', jxbId: 'B1', kcmc: '高等数学');
      final low = c(kchId: '', kch: 'math1131', jxbId: 'B1', kcmc: '高等数学');
      expect(up.identityKey, low.identityKey);
    });

    test('档2：无 jxb_id 但有教师+时间 → 指纹', () {
      final x = c(jxbId: '', teacher: '张三', sksj: '星期一第1-2节{1-16周}');
      expect(x.identityTier, 2);
      expect(x.identityKey, startsWith('f|'));
    });

    test('档3：两者皆无 → 仅课程聚合', () {
      final x = c(jxbId: '', teacher: '张三', sksj: '');
      expect(x.identityTier, 3);
      expect(x.identityKey, 'c|cs101');
    });

    test('指纹归一化：空白/全角/大小写等价', () {
      final a = c(jxbId: '', teacher: ' 张 三 ', sksj: '星期一 第1-2节{1-16周}');
      final b = c(jxbId: '', teacher: '张三', sksj: '星期一第1-2节｛1-16周｝');
      expect(a.identityKey, b.identityKey);
      final c1 = c(jxbId: '', teacher: 'ＡＢＣ', sksj: '星期一第1-2节{1-16周}');
      final c2 = c(jxbId: '', teacher: 'abc', sksj: '星期一第1-2节{1-16周}');
      expect(c1.identityKey, c2.identityKey);
    });

    test('轮次不参与身份键（xkkz/xklc 变化不影响）', () {
      final a = c(xkkz: 'R1', xklc: '1');
      final b = c(xkkz: 'R2', xklc: null);
      expect(a.identityKey, b.identityKey);
    });
  });

  group('跨轮次合并', () {
    test('同教学班跨轮合并，观测按入口归并', () {
      final r = mergeXkCourses([
        c(xkkz: 'R1', cap: 60, selected: 45),
        c(xkkz: 'R2', cap: 55, selected: 52),
      ]);
      expect(r.courses.length, 1);
      final m = r.courses.single;
      expect(m.byRound.keys.toSet(), {'R1', 'R2'});
      expect(m.roundOrder, ['R1', 'R2']);
      expect(m.latest?.cap, 55); // 取最后拉取的有值观测
      expect(m.byRound['R1']!.selected, 45);
    });

    test('档3聚合标注「无法区分平行班」', () {
      final r = mergeXkCourses([
        c(jxbId: '', teacher: '', sksj: '', xkkz: 'R1'),
        c(jxbId: '', teacher: '', sksj: '', xkkz: 'R2'),
      ]);
      expect(r.courses.length, 1);
      expect(r.notes.any((n) => n.contains('无法区分平行班')), isTrue);
    });

    test('疑似同班（同指纹不同 jxb_id）：不合并 + 双方留痕', () {
      final r = mergeXkCourses([
        c(jxbId: 'B1', teacher: '张三', sksj: '星期一第1-2节{1-16周}', xkkz: 'R1'),
        c(jxbId: 'B2', teacher: '张三', sksj: '星期一第1-2节{1-16周}', xkkz: 'R2'),
      ]);
      expect(r.courses.length, 2); // 不静默合并
      for (final m in r.courses) {
        expect(m.notes.any((n) => n.contains('疑似')), isTrue);
      }
    });

    test('同 jxb_id 不同课程名：数据异常留痕且分开', () {
      final r = mergeXkCourses([
        c(jxbId: 'B1', kcmc: '数据结构'),
        c(jxbId: 'B1', kcmc: '数据结构（双语）'),
      ]);
      expect(r.courses.length, 2);
      expect(r.notes.any((n) => n.contains('同一教学班标识')), isTrue);
    });

    test('展示主体取字段最全的一次观测', () {
      final r = mergeXkCourses([
        c(xkkz: 'R1', teacher: '张三'),
        c(xkkz: 'R2', teacher: '张三', sksj: '星期一第1-2节{1-16周}', cap: 50, xf: 4.0),
      ]);
      final m = r.courses.single;
      expect(m.base.cap, 50);
      expect(m.base.sksj, isNotEmpty);
      expect(m.base.xf, 4.0);
    });

    test('同入口多行：累计 count 并留痕（不再静默覆盖）', () {
      final r = mergeXkCourses([
        c(xkkz: 'R1', cap: 60, selected: 45),
        c(xkkz: 'R1', cap: 60, selected: 52),
      ]);
      expect(r.courses.length, 1);
      final m = r.courses.single;
      expect(m.byRound['R1']!.count, 2);
      expect(m.byRound['R1']!.selected, 52); // 快照取最后一行
      expect(m.notes.any((n) => n.contains('多行')), isTrue);
    });

    test('空输入不崩', () {
      final r = mergeXkCourses(const []);
      expect(r.courses, isEmpty);
      expect(r.notes, isEmpty);
    });
  });

  group('weekdayLabel', () {
    test('1-7 与越界', () {
      expect(weekdayLabel(1), '周一');
      expect(weekdayLabel(7), '周日');
      expect(weekdayLabel(0), '');
      expect(weekdayLabel(8), '');
    });
  });
}
