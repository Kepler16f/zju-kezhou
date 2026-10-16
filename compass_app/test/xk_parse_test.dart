// test/xk_parse_test.dart — 选课解析层回归（纯 Dart；对应 docs/选课模块接入说明.md）。
// 时间串 14 类边界来自设计评审B清单；首页 onclick 4/5 参形态来自评审A1。
import 'package:test/test.dart';

import 'package:compass_app/data/xk_parse.dart';
import 'package:compass_app/engine/timeline.dart';

void main() {
  group('parseSksj 上课时间', () {
    test('标准形态 {1-16周}', () {
      final r = parseSksj('星期一第3-4节{1-16周}');
      expect(r.slots.length, 1);
      final s = r.slots.first;
      expect(s, {'day': 1, 'start': 3, 'end': 4, 'week_start': 1, 'week_end': 16});
    });

    test('星期变体 周日/礼拜三/周1', () {
      expect(parseSksj('星期日第5节{1-8周}').slots.first['day'], 7);
      expect(parseSksj('星期天第5节{1-8周}').slots.first['day'], 7);
      expect(parseSksj('礼拜三第5节{1-8周}').slots.first['day'], 3);
      expect(parseSksj('周1第5节{1-8周}').slots.first['day'], 1);
    });

    test('全角数字与符号', () {
      final r = parseSksj('星期一第３－４节｛１－１６周｝');
      expect(r.slots.first, {'day': 1, 'start': 3, 'end': 4, 'week_start': 1, 'week_end': 16});
    });

    test('缺周次按缺省 1-16 并留痕', () {
      final r = parseSksj('星期四第5-6节');
      expect(r.slots.first['week_start'], 1);
      expect(r.slots.first['week_end'], 16);
      expect(r.issues.any((i) => i.contains('未标注周次')), isTrue);
    });

    test('多段（分号/逗号分隔）', () {
      final r = parseSksj('星期一第1-2节{1-8周}；星期三第3-4节{9-16周}');
      expect(r.slots.length, 2);
      expect(r.slots[0]['day'], 1);
      expect(r.slots[1]['day'], 3);
      expect(r.slots[1]['week_start'], 9);
    });

    test('单双周逐周展开且与相反奇偶不冲突', () {
      final odd = parseSksj('星期一第1-2节{1-16周单}').slots;
      final even = parseSksj('星期一第1-2节{1-16周双}').slots;
      final all = parseSksj('星期一第1-2节{1-16周}').slots;
      expect(odd.length, 8);
      expect(even.length, 8);
      // 单周与双周：同一格但周次不相交 → 不冲突
      expect(Timeline.slotsConflict(odd, even), isNull);
      // 单周与全周：奇数周相交 → 冲突
      expect(Timeline.slotsConflict(odd, all), isNotNull);
      // 括号内标注形态 {1-15周(单)}
      final odd2 = parseSksj('星期一第1-2节{1-15周(单)}').slots;
      expect(odd2.length, 8);
      expect(Timeline.slotsConflict(odd2, even), isNull);
    });

    test('不连续区间 {1-8,10-16周}', () {
      final r = parseSksj('星期二第1-2节{1-8,10-16周}');
      expect(r.slots.length, 2);
      expect(r.slots[0], {'day': 2, 'start': 1, 'end': 2, 'week_start': 1, 'week_end': 8});
      expect(r.slots[1], {'day': 2, 'start': 1, 'end': 2, 'week_start': 10, 'week_end': 16});
    });

    test('非 1 起始周次 {3-17周}', () {
      final r = parseSksj('星期三第9节{3-17周}');
      expect(r.slots.first['week_start'], 3);
      expect(r.slots.first['week_end'], 17);
      expect(r.slots.first['start'], 9);
      expect(r.slots.first['end'], 9);
    });

    test('节次分隔符变体', () {
      for (final t in ['第3、4节', '第3,4节', '第3~4节', '第3—4节', '第3至4节']) {
        final r = parseSksj('星期一$t{1-16周}');
        expect(r.slots.first['start'], 3, reason: t);
        expect(r.slots.first['end'], 4, reason: t);
      }
    });

    test('教室数字不误吞', () {
      final r = parseSksj('星期一第3-4节{1-16周}紫金港东2-303');
      expect(r.slots.length, 1);
      expect(r.slots.first['week_end'], 16);
    });

    test('垃圾/空串 → 空结果且留痕', () {
      expect(parseSksj('').slots, isEmpty);
      expect(parseSksj('   ').slots, isEmpty);
      final junk = parseSksj('详见教务系统');
      expect(junk.slots, isEmpty);
      expect(junk.issues, isNotEmpty);
      final half = parseSksj('星期一 吃饭'); // 有星期但无节次
      expect(half.slots, isEmpty);
      expect(half.issues, isNotEmpty);
    });

    test('全角空格与类型/范围断言', () {
      final r = parseSksj('星期一　第3-4节　｛1-16周｝');
      expect(r.slots, isNotEmpty);
      for (final s in r.slots) {
        expect(s['day'], isA<int>());
        expect(s['start'], isA<int>());
        expect(s['end'], isA<int>());
        expect(s['week_start'], isA<int>());
        expect(s['week_end'], isA<int>());
        expect((s['day'] as int) >= 1 && (s['day'] as int) <= 7, isTrue);
        expect((s['start'] as int) <= (s['end'] as int), isTrue);
        expect((s['week_start'] as int) <= (s['week_end'] as int), isTrue);
      }
    });

    test('空时隙喂给 slotsConflict 不崩', () {
      expect(Timeline.slotsConflict(const [], const [{'day': 1, 'start': 1, 'end': 2}]), isNull);
    });

    test('节次越界/畸形不产出时隙', () {
      expect(parseSksj('星期一第0-4节{1-16周}').slots, isEmpty);
      expect(parseSksj('星期一第9-4节{1-16周}').slots, isEmpty);
      expect(parseSksj('星期一第3-20节{1-16周}').slots, isEmpty);
    });
  });

  group('parseXkIndexHtml 选课首页', () {
    test('4 参与 5 参 onclick 均可解析，取前两参', () {
      const html = ''
          '<a href="javascript:;" onclick="queryCourse(this,\'10\',\'ABC123\',\'1\')">第一轮</a>'
          '<li onclick=\'queryCourse(this,"09","DEF456","2020","2021")\'>通识选修</li>';
      final r = parseXkIndexHtml(html);
      expect(r.queryCourseHits, 2);
      expect(r.rounds.length, 2);
      expect(r.rounds[0].kklxdm, '10');
      expect(r.rounds[0].xkkzId, 'ABC123');
      expect(r.rounds[0].xklc, isNull); // 不臆取轮次编号
      expect(r.rounds[0].label, '第一轮');
      expect(r.rounds[1].kklxdm, '09');
      expect(r.rounds[1].label, '通识选修');
    });

    test('重复 xkkz_id 去重', () {
      const html = '<a onclick="queryCourse(this,\'10\',\'X1\',\'1\')">A</a>'
          '<a onclick="queryCourse(this,\'10\',\'X1\',\'1\')">A</a>';
      final r = parseXkIndexHtml(html);
      expect(r.rounds.length, 1);
    });

    test('无 onclick 时 firstXkkzId 兜底并留痕', () {
      const html = '<input type="hidden" name="firstXkkzId" value="F001"/>';
      final r = parseXkIndexHtml(html);
      expect(r.rounds.length, 1);
      expect(r.rounds.first.xkkzId, 'F001');
      expect(r.issues, isNotEmpty);
    });

    test('完全无入口 → 空 + 留痕（区分解析失败）', () {
      final r = parseXkIndexHtml('<html><body>页面错误</body></html>');
      expect(r.rounds, isEmpty);
      expect(r.queryCourseHits, 0);
      expect(r.issues.any((i) => i.contains('未发现选课入口')), isTrue);
    });

    test('学年学期隐藏域（两种属性顺序）', () {
      const html = '<input name="xkxnm" value="2026"/>'
          '<input value="3" id="xkxqm"/>';
      final r = parseXkIndexHtml(html);
      expect(r.xkxnm, '2026');
      expect(r.xkxqm, '3');
    });

    test('隐藏域全量采集（查询参数以首页为准）', () {
      const html = '<input type="hidden" name="xkxnm" value="2026"/>'
          '<input type="hidden" name="jg_id" value="01"/>'
          '<input name="blank" value=""/>';
      final r = parseXkIndexHtml(html);
      expect(r.hiddenFields['xkxnm'], '2026');
      expect(r.hiddenFields['jg_id'], '01');
      expect(r.hiddenFields.containsKey('blank'), isTrue);
    });
  });

  group('parseXkCourseList 课程列表', () {
    Map<String, dynamic> fullRow() => {
          'kch': 'CS101',
          'kch_id': 'A1',
          'kcmc': '数据结构',
          'xf': '4.0',
          'jxb_id': 'B1',
          'jxbmc': '01班',
          'jsxx': '张三',
          'sksj': '星期一第3-4节{1-16周}',
          'cdmc': '东1-101',
          'xqjmc': '紫金港',
          'jxbrl': 60,
          'yxzrs': 45,
        };

    test('完整行解析（多键/类型容错）', () {
      final r = parseXkCourseList('{"tmpList":[${_json(fullRow())}]}', xkkzId: 'R1');
      expect(r.state, 'data');
      final c = r.courses.single;
      expect(c.kcmc, '数据结构');
      expect(c.xf, 4.0);
      expect(c.cap, 60);
      expect(c.selected, 45);
      expect(c.slots.length, 1);
      expect(c.xkkzId, 'R1');
      expect(c.raw['kch'], 'CS101');
    });

    test('课程标签收集（kcxzmc/kclb 多键、逗号拆分、过滤纯数字与长文本）', () {
      final row = fullRow()
        ..['kcxzmc'] = '通识核心课程，思政类'
        ..['kclb'] = ['专业选修', '03']
        ..['kcbq'] = '说明文字超过十六个字符应当被丢弃不是标签';
      final c = parseXkCourseList('{"tmpList":[${_json(row)}]}', xkkzId: 'R')
          .courses
          .single;
      expect(c.tags, ['通识核心课程', '思政类', '专业选修']);
    });

    test('无标签字段 → 空列表，不硬造标签', () {
      final c =
          parseXkCourseList('{"tmpList":[${_json(fullRow())}]}', xkkzId: 'R')
              .courses
              .single;
      expect(c.tags, isEmpty);
    });

    test('信封兼容 items / 裸数组 / capacity 多键', () {
      expect(parseXkCourseList('{"items":[${_json(fullRow())}]}', xkkzId: 'R').state, 'data');
      expect(parseXkCourseList('[${_json(fullRow())}]', xkkzId: 'R').state, 'data');
      final alt = {'kcmc': '高数', 'capacity': 30, 'selected_number': 10, 'jsxx': ['李四']};
      final r = parseXkCourseList('{"tmpList":[${_json(alt)}]}', xkkzId: 'R');
      expect(r.courses.single.cap, 30);
      expect(r.courses.single.selected, 10);
      expect(r.courses.single.teacher, '李四');
    });

    test('三态：open 空列表 = empty', () {
      expect(parseXkCourseList('{"tmpList":[]}', xkkzId: 'R').state, 'empty');
    });

    test('三态：usable:false / 验证码 / HTML 登录页 = unavailable 不落无课', () {
      expect(parseXkCourseList('{"usable":false}', xkkzId: 'R').state, 'unavailable');
      expect(parseXkCourseList('{"captcha_error":"x"}', xkkzId: 'R').state, 'unavailable');
      final html = '<html><script>location.href="login_slogin.html"</script></html>';
      final r = parseXkCourseList(html, xkkzId: 'R');
      expect(r.state, 'unavailable');
      expect(r.issues.any((i) => i.contains('登录')), isTrue);
    });

    test('三态：无已知信封 / 全行缺课程名 = unavailable', () {
      final noEnv = parseXkCourseList('{"foo":1}', xkkzId: 'R');
      expect(noEnv.state, 'unavailable');
      final noName = parseXkCourseList('{"tmpList":[{"kch":"C1"},{"kch":"C2"}]}', xkkzId: 'R');
      expect(noName.state, 'unavailable');
      expect(noName.dropped, 2);
    });

    test('部分行缺名被跳过并计数', () {
      final r = parseXkCourseList(
          '{"tmpList":[${_json(fullRow())},{"kch":"X"}]}', xkkzId: 'R');
      expect(r.courses.length, 1);
      expect(r.dropped, 1);
      expect(r.issues.any((i) => i.contains('被跳过')), isTrue);
    });

    test('上课时间解析失败的行仍保留（slots 为空）+ issues', () {
      final row = fullRow()..['sksj'] = '见教务网';
      final r = parseXkCourseList('{"tmpList":[${_json(row)}]}', xkkzId: 'R');
      expect(r.courses.single.slots, isEmpty);
      expect(r.issues, isNotEmpty);
    });
  });

  group('对抗评审回归（L2）', () {
    test('同段多节次各自成槽', () {
      final r = parseSksj('星期一第1-2节,第3-4节{1-16周}');
      expect(r.slots.length, 2);
      expect(r.slots[0]['start'], 1);
      expect(r.slots[1]['start'], 3);
    });

    test('多天共享节次', () {
      final r = parseSksj('周一、周三第1-2节{1-16周}');
      expect(r.slots.length, 2);
      expect({r.slots[0]['day'], r.slots[1]['day']}, {1, 3});
    });

    test('花括号纯数字区间 {1-16}', () {
      expect(parseSksj('星期一第3-4节{1-16}').slots.single['week_end'], 16);
    });

    test('第1周至第16周', () {
      final s = parseSksj('星期一第3-4节 第1周至第16周').slots;
      expect(s.length, 1);
      expect(s.single['week_start'], 1);
      expect(s.single['week_end'], 16);
    });

    test('kbList 组合形态 {2-16周(单)}：奇偶与区间都按原文（不多出第 1 周）', () {
      final r = parseSksj('星期1第3-4节{2-16周(单)}');
      expect(r.slots.length, 7); // 3,5,7,9,11,13,15
      expect(r.slots.first['week_start'], 3);
      expect(r.issues.any((i) => i.contains('未标注')), isFalse, reason: '有周次文本不得误报未标注');
    });

    test('en dash 节次与周次', () {
      final s = parseSksj('星期一第3–4节{1–16周}').slots;
      expect(s.single['start'], 3);
      expect(s.single['week_end'], 16);
    });

    test('教室号与周次同括号时不被吞', () {
      final r = parseSksj('星期一第3-4节{1-16周,东2-303}');
      expect(r.slots.length, 1);
      expect(r.slots.single['week_end'], 16);
    });

    test('{单周}：默认区间 + 奇偶展开 + 留痕', () {
      final r = parseSksj('星期一第1-2节{单周}');
      expect(r.slots.length, 8);
      expect(r.issues, isNotEmpty);
    });

    test('课程名含"验证码"不误杀', () {
      final r = parseXkCourseList('{"tmpList":[{"kcmc":"验证码与信息安全","xf":2}]}',
          xkkzId: 'R');
      expect(r.state, 'data');
      expect(r.courses.single.kcmc, '验证码与信息安全');
    });

    test('onclick 实体化引号可解析', () {
      const html = '<a onclick="queryCourse(this,&#39;10&#39;,&#39;X1&#39;)">第一轮</a>';
      final r = parseXkIndexHtml(html);
      expect(r.queryCourseHits, 1);
      expect(r.rounds.single.xkkzId, 'X1');
    });

    test('同 xkkz 跨类别入口不去重', () {
      const html = '<a onclick="queryCourse(this,\'01\',\'R1\')">专业课</a>'
          '<a onclick="queryCourse(this,\'02\',\'R1\')">通识课</a>';
      expect(parseXkIndexHtml(html).rounds.length, 2);
    });

    test('label 取最长名字字段（跳过图标字）', () {
      const html = '<a onclick="queryCourse(this,\'10\',\'X9\')">'
          '<span class="ico">图标</span>第一轮</a>';
      expect(parseXkIndexHtml(html).rounds.single.label, '第一轮');
    });

    test('空 firstXkkzId 不生成幻影入口', () {
      const html = '<input type="hidden" name="firstXkkzId" value=""/>';
      final r = parseXkIndexHtml(html);
      expect(r.rounds, isEmpty);
      expect(r.firstXkkzId, isNull);
    });

    test('jsxx:false / 嵌套对象不产生伪教师', () {
      final r1 = parseXkCourseList('{"tmpList":[{"kcmc":"数据结构","jsxx":false}]}',
          xkkzId: 'R');
      expect(r1.courses.single.teacher, '');
      final r2 = parseXkCourseList(
          '{"tmpList":[{"kcmc":"数据结构","jsxx":{"jsxm":"张三"}}]}',
          xkkzId: 'R');
      expect(r2.courses.single.teacher, '张三');
    });
  });

  group('parseXskbListToSlots 当前课表', () {
    test('标准行 → 时隙 + 课程名去重', () {
      final r = parseXskbListToSlots([
        {'kcmc': '高等数学', 'xqj': '1', 'jcs': '3-4', 'zcd': '1-16'},
        {'kcmc': '高等数学', 'xqj': '3', 'jcs': '1-2', 'zcd': '1-16'},
      ]);
      expect(r.slots.length, 2);
      expect(r.slots[0]['day'], 1);
      expect(r.courses, ['高等数学']);
    });

    test('周次带“周”字与不连续区间', () {
      final r = parseXskbListToSlots([
        {'kcmc': '体育', 'xqj': '2', 'jcs': '5-6', 'zcd': '1-8,10-16周'},
      ]);
      expect(r.slots.length, 2);
      expect(r.issues, isEmpty);
    });

    test('缺 xqj/jcs 行跳过；缺 zcd 走缺省并留痕', () {
      final r = parseXskbListToSlots([
        {'kcmc': '缺时间'},
        {'kcmc': '缺周次', 'xqj': '4', 'jcs': '7-8'},
      ]);
      expect(r.courses, ['缺周次']);
      expect(r.slots.single['week_start'], 1);
      expect(r.issues, isNotEmpty);
    });

    test('非列表输入不崩', () {
      expect(parseXskbListToSlots(null).slots, isEmpty);
      expect(parseXskbListToSlots('abc').slots, isEmpty);
    });
  });
}

String _json(Map<String, dynamic> m) {
  final parts = m.entries.map((e) {
    final v = e.value;
    if (v is num) return '"${e.key}":$v';
    if (v is List) {
      return '"${e.key}":[${v.map((x) => '"$x"').join(',')}]';
    }
    return '"${e.key}":"$v"';
  });
  return '{${parts.join(',')}}';
}
