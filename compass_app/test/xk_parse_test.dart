// test/xk_parse_test.dart — 选课解析层回归（纯 Dart；对应 docs/选课模块接入说明.md）。
// 时间串 14 类边界来自设计评审B清单；首页 onclick 4/5 参形态来自评审A1。
import 'package:test/test.dart';

import 'package:compass_app/data/xk_models.dart';
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

    test('枚举连排三节（LIVE 实证晚间课）：第11,12,13节 合并为 11-13 单槽', () {
      final r = parseSksj('周二第11,12,13节');
      expect(r.slots.length, 1);
      expect(r.slots.first['start'], 11);
      expect(r.slots.first['end'], 13);
      // 非连续枚举不臆造中间节：1,3 → 两槽（1-1 与 3-3）
      final g = parseSksj('周二第1,3节');
      expect(g.slots.length, 2);
      expect(g.slots.map((s) => s['start']).toList(), [1, 3]);
      // 三节连排叠加周次标注同样成立（此前「周一第6,7,8节{单周}」整段被丢弃）
      final o = parseSksj('周一第6,7,8节{1-16周}');
      expect(o.slots.length, 1);
      expect(o.slots.first['start'], 6);
      expect(o.slots.first['end'], 8);
      expect(o.slots.first['week_end'], 16);
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
      expect(r.rounds[0].extraArgs, ['1']); // 第 3 起实参只透传不臆测（#4）
      expect(r.rounds[1].kklxdm, '09');
      expect(r.rounds[1].label, '通识选修');
      expect(r.rounds[1].extraArgs, ['2020', '2021']);
    });

    test('浙大 ghb 下拉：重名「全部课程」带出父类别（displayLabel）', () {
      const html = ''
          '<ul class="nav nav-tabs">'
          '<li class="leaf" kclbmc="本类(专业)选课" title="本类(专业)选课">'
          '<a class="category" data-dl="xk_1" data-lx="bl" '
          'onclick="categroyClick(this,\'xk_1\',\'bl\')">本类(专业)</a></li>'
          '<li class="leaf" kclbmc="通识必修课程" title="通识必修课程">'
          '<a class="dropdown-toggle">通识必修课程</a>'
          '<ul class="dropdown-menu">'
          '<li kclbmc="全部课程" title="全部课程">'
          '<a class="category" data-dl="xk_b" data-lx="bl" '
          'onclick="categroyClick(this,\'xk_b\',\'bl\')">全部课程</a></li>'
          '<li kclbmc="军体类" title="军体类">'
          '<a class="category" data-dl="EB" data-lx="zl" '
          'onclick="categroyClick(this,\'EB\',\'zl\')">军体类</a></li>'
          '</ul></li></ul>';
      final r = parseXkIndexHtml(html);
      final byId = {for (final x in r.rounds) x.xkkzId: x};
      expect(byId['xk_b']!.group, '通识必修课程');
      expect(byId['xk_b']!.displayLabel, '通识必修课程'); // 重名→父类
      expect(byId['EB']!.group, '通识必修课程');
      expect(byId['EB']!.displayLabel, '军体类'); // 本身不重名，保留原标签
      expect(byId['xk_1']!.group, isEmpty); // 顶层无父类
      expect(byId['xk_1']!.displayLabel, '本类(专业)');
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

    test('浙大自主选课页（zzxkGhb）：入口=课程类别 dl，标记 zjuGhb', () {
      const html = '<input type="hidden" name="nj" value="2026"/>'
          '<input type="hidden" name="xn" value="2026-2027"/>'
          '<input type="hidden" name="xq" value="1"/>'
          '<input type="hidden" name="zydm" value="1321"/>'
          '<a class="category" data-dl="xk_1" data-lx="bl" '
          'onclick="categroyClick(this,\'xk_1\',\'bl\')">本类(专业)</a>'
          '<a class="category" data-dl="EA" data-lx="bl" '
          'onclick="categroyClick(this,\'EA\',\'bl\')">思政类</a>'
          '<a class="category" data-dl="EA" data-lx="bl" '
          'onclick="categroyClick(this,\'EA\',\'bl\')">必修课程</a>'; // 同 dl 去重
      final r = parseXkIndexHtml(html);
      expect(r.zjuGhb, isTrue);
      expect(r.queryCourseHits, 0); // 浙大页没有 queryCourse
      expect(r.rounds.map((e) => e.xkkzId), ['xk_1', 'EA']);
      expect(r.rounds[1].label, '思政类'); // 同类别多次出现只留首个
      expect(r.xkxnm, '2026-2027'); // 浙大隐藏域 xn/xq
      expect(r.xkxqm, '1');
      expect(r.issues.any((i) => i.contains('浙大自主选课')), isTrue);
    });

    test('浙大页无类别锚点（不在开放期）→ 如实说明开放期', () {
      const html = 'zzxkGhb 页面 categroyClick(this) 但无 data-dl 锚点';
      final r = parseXkIndexHtml(html);
      expect(r.rounds, isEmpty);
      expect(r.issues.any((i) => i.contains('开放')), isTrue);
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

    test('浙大 JxbList 行 rs=「余量/容量」→ cap/selected（LIVE 实证 41/43）', () {
      final row = {
        'kcdm': '03121740',
        'kcmc': '中外教育改革专题研究',
        'jsxm': '商丽浩<br>刘海峰',
        'rs': '41/43',
        'sfxz': '0',
        'xkkh': '(2026-2027-1)-03121740-0090223-1',
      };
      final c = parseXkCourseList('[${_json(row)}]', xkkzId: 'xk_4')
          .courses
          .single;
      expect(c.cap, 43);
      expect(c.selected, 2); // 容量 - 余量
      expect(c.teacher, '商丽浩 / 刘海峰');
    });

    test('rs 非法形态（--/非数字）→ 不硬造容量', () {
      final row = {'kcdm': 'X', 'kcmc': '课', 'rs': '--'};
      final c = parseXkCourseList('[${_json(row)}]', xkkzId: 'R').courses.single;
      expect(c.cap, isNull);
      expect(c.selected, isNull);
    });

    test('浙大 KcList：裸数组 + kcxx 学分 + xxq 子学期 + 类别标签', () {
      final row = {
        'kcdm': 'MATH1135G',
        'kcmc': '微积分（甲）Ⅰ',
        'kcxx': '0~5.0~4.0-2.0',
        'kcxz': '通识',
        'kclb': '通识',
        'xkkh': 'T(2026-2027-1)-MATH1135G',
        'xxq': '秋冬',
      };
      final r = parseXkCourseList('[${_json(row)}]', xkkzId: 'xk_1', label: '本类(专业)');
      expect(r.state, 'data'); // 裸数组信封
      final c = r.courses.single;
      expect(c.xf, 5.0); // 学分从 kcxx 中段取
      expect(c.subTerm, '秋冬');
      expect(c.tags, containsAll(['通识', '本类(专业)']));
      expect(c.kch, 'MATH1135G');
      expect(c.raw['xkkh'], 'T(2026-2027-1)-MATH1135G');
    });

    test('浙大 KcList：不在开放期返回 [] → empty（不是 unavailable）', () {
      expect(parseXkCourseList('[]', xkkzId: 'xk_1').state, 'empty');
    });

    test('kcxx 形态不符 → 不猜学分（xf 保持 null）', () {
      final r = parseXkCourseList(
          '[${_json({'kcmc': '怪课', 'kcxx': 'abc'})}]', xkkzId: 'R');
      expect(r.courses.single.xf, isNull);
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

    test('blocked 标志：风控/HTML 登录页=软封禁信号；结构陌生/usable:false 不算', () {
      // 用户反馈"网页正常、App 突然看不到"的判据：只有反爬类响应才置 blocked，
      // 上层据此进入冷却窗停止轰炸（普通结构差异不触发冷却，避免误伤）。
      expect(parseXkCourseList('{"captcha_error":"x"}', xkkzId: 'R').blocked, isTrue);
      expect(
          parseXkCourseList(
                  '<html>location.href="login_slogin.html"</html>', xkkzId: 'R')
              .blocked,
          isTrue);
      // 空响应体不等于风控：只判 unavailable，避免整批类别被中止。
      expect(parseXkCourseList('', xkkzId: 'R').blocked, isFalse);
      // 非 JSON 且无登录/风控特征 → 结构未知，不置 blocked
      expect(parseXkCourseList('not json at all', xkkzId: 'R').blocked, isFalse);
      // usable:false（权限语义，非反爬）不置 blocked
      expect(parseXkCourseList('{"usable":false}', xkkzId: 'R').blocked, isFalse);
      // 正常数据更不该 blocked
      expect(
          parseXkCourseList('{"tmpList":[${_json(fullRow())}]}', xkkzId: 'R').blocked,
          isFalse);
    });

    test('三态：无已知信封 = unavailable；缺名但有课程号 = 占位保留', () {
      final noEnv = parseXkCourseList('{"foo":1}', xkkzId: 'R');
      expect(noEnv.state, 'unavailable');
      final noName = parseXkCourseList(
          '{"tmpList":[{"kch":"C1"},{"kch":"C2"}]}', xkkzId: 'R');
      expect(noName.state, 'data');
      expect(noName.courses.length, 2);
      expect(noName.courses.first.kcmc, contains('未命名课程'));
      expect(noName.dropped, 0);
    });

    test('缺名但有课程号的行占位保留并留痕', () {
      final r = parseXkCourseList(
          '{"tmpList":[${_json(fullRow())},{"kch":"X"}]}', xkkzId: 'R');
      expect(r.courses.length, 2);
      expect(r.dropped, 0);
      expect(r.issues.any((i) => i.contains('占位')), isTrue);
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

    test('真实已选行：<br> 多值清洗 + 地点取 skdd + 课程号取 kcdm', () {
      // 字段名/分隔符取自 zdbk 实测已选列表（用户反馈：放大卡未解析教师/时间/地点）
      const row = '{"tmpList":[{"kcmc":"大学物理（甲）I",'
          '"kcdm":"PHYS1001G","xf":"4.0","zxs":"64",'
          '"jsxm":"谭芸<br>祝一虹",'
          '"sksj":"星期一第1-2节{第1-16周}<br>星期三第3-4节{第1-16周}",'
          '"skdd":"紫金港东1-101<br>紫金港东1-102","xkkh":"(2026-2027-1)-PHYS1001G-01"}]}';
      final r = parseXkCourseList(row, xkkzId: 'choosed');
      final c = r.courses.single;
      expect(c.kch, 'PHYS1001G');
      expect(c.xf, 4.0);
      expect(c.teacher, '谭芸 / 祝一虹');
      expect(c.sksj, contains('星期一第1-2节'));
      expect(c.sksj, contains(' / '));
      expect(c.sksj, isNot(contains('<')));
      expect(c.cdmc, '紫金港东1-101 / 紫金港东1-102');
      expect(c.cdmc, isNot(contains('<')));
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

    test('真实形态行（kcb/djj/skcd/dsz/xxq）→ 时隙 + 结构化行', () {
      // 结构对齐 LIVE 取证样本（虚构课程名，无真实身份信息）
      final r = parseXskbListToSlots([
        {
          'kcb': '线性代数（甲）<br>秋冬{第1-8周|1节/周}<br>示例教师甲<br>示例楼A-203zwf2027年01月10日(08:00-10:00)zwf',
          'xqj': '1',
          'djj': '9',
          'skcd': '1',
          'dsz': '2',
          'xxq': '秋冬',
        },
        {
          'kcb': '大学写作<br>秋{第1-8周|2节/周}<br>示例教师乙<br>示例楼B-101zwfzwf',
          'xqj': '4',
          'djj': '11',
          'skcd': '2',
          'dsz': '2',
          'xxq': '秋',
        },
      ]);
      expect(r.rows.length, 2);
      final a = r.rows[0];
      expect(a.name, '线性代数（甲）');
      expect(a.teacher, '示例教师甲');
      expect(a.place, '示例楼A-203');
      expect(a.day, 1);
      expect(a.start, 9);
      expect(a.end, 9); // skcd=1 单节
      expect(a.weekStart, 1);
      expect(a.weekEnd, 8);
      expect(a.parity, 0); // dsz=2 全周
      expect(a.subTerm, '秋冬');
      expect(r.rows[1].end, 12); // skcd=2 → 11-12
      expect(r.rows[1].subTerm, '秋');
      expect(r.slots.length, 2);
      expect(r.courses, containsAll(['线性代数（甲）', '大学写作']));
    });

    test('单双周行（dsz=1/3）→ parity 逐周展开（与冲突口径一致）', () {
      final r = parseXskbListToSlots([
        {
          'kcb': '体育课<br>秋冬{第2-16周|1节/周}<br>示例教师丙<br>操场zwfzwf',
          'xqj': '3',
          'djj': '1',
          'skcd': '1',
          'dsz': '1', // 单周
          'xxq': '秋冬',
        },
      ]);
      expect(r.rows.every((e) => e.parity == 1), isTrue);
      expect(r.slots.length, 7); // 2-16 单周共 7 周（3,5,7,9,11,13,15）
    });

    group('认定型课程与多类别标签（#10/#11）', () {
      // 认定型子入口 lx 的真实码值待探针确认（docs §9）：解析层不预设码值，
      // 测试里的 'rd' 只代表「与 bl 不同的任意 lx」——同 dl 跨 lx 子入口不得被去重吞掉。
      test('同 dl 多个 lx 子入口不去重（认定型子入口整类可见）', () {
        const html = '<a class="category" data-dl="50" data-lx="bl" '
                'onclick="categroyClick(this,\'50\',\'bl\')">美育类选修课程</a>'
            '<a class="category" data-dl="50" data-lx="rd" '
            'onclick="categroyClick(this,\'50\',\'rd\')">美育类通识必修课程</a>';
        final r = parseXkIndexHtml(html);
        expect(r.zjuGhb, isTrue);
        expect(r.rounds.length, 2);
        expect(r.rounds[0].xkkzId, '50');
        expect(r.rounds[0].kklxdm, 'bl');
        expect(r.rounds[0].label, '美育类选修课程');
        expect(r.rounds[1].xkkzId, '50');
        expect(r.rounds[1].kklxdm, 'rd');
        expect(r.rounds[1].label, '美育类通识必修课程');
      });

      test('仅 data-dl/data-lx 无 categroyClick 的锚点也能解析为入口', () {
        const html =
            '<a class="category" data-dl="51" data-lx="rd">劳育类通识必修课程</a>';
        final r = parseXkIndexHtml(html);
        expect(r.zjuGhb, isTrue);
        expect(r.rounds.single.xkkzId, '51');
        expect(r.rounds.single.kklxdm, 'rd');
        expect(r.rounds.single.label, '劳育类通识必修课程');
      });

      test('认定型课程行（无教学班/无时间/无容量）仍解析保留，类别入口进 categories', () {
        final row = {'kch': 'ART1100G', 'kcmc': '艺术与审美', 'xxq': '秋冬'};
        final r = parseXkCourseList('[${_json(row)}]',
            xkkzId: '50', label: '美育类通识必修课程');
        expect(r.state, 'data');
        final c = r.courses.single;
        expect(c.identityTier, 3); // 无教学班标识：档3聚合，仍展示
        expect(c.categories, ['美育类通识必修课程']);
        expect(c.tags, contains('美育类通识必修课程')); // tags 兼容口径保留入口名
        expect(c.cap, isNull); // 认定型页无容量列 → 未知，不当 0
        expect(c.raw['kch'], 'ART1100G');
      });

      test('多类别合并（诉求 #11）：categories 跨入口去重保序，tags 并集不变', () {
        final a = parseXkCourseList('[{"kcmc":"中国书法","kch":"ART1101"}]',
                xkkzId: '50', label: '美育类通识必修课程')
            .courses
            .single;
        final b = parseXkCourseList('[{"kcmc":"中国书法","kch":"ART1101"}]',
                xkkzId: 'zhct', label: '中华传统（演示）')
            .courses
            .single;
        final merged = mergeXkCourses([a, b]).courses.single;
        expect(merged.categories, ['美育类通识必修课程', '中华传统（演示）']); // 保序
        expect(merged.tags.toSet(), {'美育类通识必修课程', '中华传统（演示）'}); // 兼容并集
      });

      test('同类别重复观测：categories 不重复', () {
        final a = parseXkCourseList('[{"kcmc":"中国书法"}]',
                xkkzId: '50', label: '美育类通识必修课程')
            .courses
            .single;
        final b = parseXkCourseList('[{"kcmc":"中国书法"}]',
                xkkzId: '50', label: '美育类通识必修课程')
            .courses
            .single;
        final merged = mergeXkCourses([a, b]).courses.single;
        expect(merged.categories, ['美育类通识必修课程']);
      });

      test('无入口 label 的行：categories 为空，不硬造', () {
        final r =
            parseXkCourseList('[{"kcmc":"中国书法"}]', xkkzId: '50');
        expect(r.courses.single.categories, isEmpty);
      });

      // ── #4 思政/军体等认定型大类空白：入口全参数捕获与透传 ──
      // 根因链：解析层此前只取 categroyClick 前两参 + data-dl/data-lx，锚点上的
      // 第三参/其余 data-* 属性（认定标志等）被静默丢弃；取数层只发固定参数集，
      // 认定型入口缺参 → 服务端回 [] → 分类视图空白。静态无法确认真实键名
      //（docs §9 待 LIVE 探针），本组只钉死「全参捕获 + 原样透传、绝不臆测语义」。
      group('入口全参数透传（#4，认定型大类）', () {
        test('categroyClick 第三参原样进 extraArgs，dl/lx 语义不变', () {
          const html = '<a class="category" data-dl="EA" data-lx="bl" '
                  'onclick="categroyClick(this,\'EA\',\'bl\',\'rd\')">思政类</a>';
          final r = parseXkIndexHtml(html);
          expect(r.zjuGhb, isTrue);
          final round = r.rounds.single;
          expect(round.xkkzId, 'EA');
          expect(round.kklxdm, 'bl');
          expect(round.label, '思政类');
          expect(round.extraArgs, ['rd']);
        });

        test('data-dl/lx 之外的 data-* 属性进 attrs（键小写、去前缀）', () {
          const html = '<a class="category" data-dl="EB" data-lx="bl" '
                  'Data-Sfrdk="1" onclick="categroyClick(this,\'EB\',\'bl\')">军体类</a>';
          final r = parseXkIndexHtml(html);
          final round = r.rounds.single;
          expect(round.attrs['sfrdk'], '1');
          expect(round.attrs.containsKey('dl'), isFalse); // dl/lx 走专用字段不重复
          expect(round.attrs.containsKey('lx'), isFalse);
          expect(round.extraArgs, isEmpty);
        });

        test('非 <a> 元素挂 data-dl（类别树变体）同样解析为入口', () {
          const html = '<li class="cat" data-dl="EB" data-lx="bl">军体类</li>';
          final r = parseXkIndexHtml(html);
          expect(r.zjuGhb, isTrue);
          expect(r.rounds.single.xkkzId, 'EB');
          expect(r.rounds.single.kklxdm, 'bl');
          expect(r.rounds.single.label, '军体类');
        });

        test('同 (dl,lx) 多锚点：属性/实参并集，先到 label 保留', () {
          const html = '<a data-dl="50" data-lx="bl">美育类</a>'
              '<a data-dl="50" data-lx="bl" data-kcbs="1">美育类</a>';
          final r = parseXkIndexHtml(html);
          expect(r.rounds.length, 1);
          final round = r.rounds.single;
          expect(round.label, '美育类');
          expect(round.attrs['kcbs'], '1');
        });

        test('军体/认定型行样式：无教学班列/无时间/容量空 → 保留，类别以入口 label 兜底', () {
          final row = {'kcmc': '军事理论', 'kch': 'MIL1101', 'kcxzmc': ''};
          final r =
              parseXkCourseList('[${_json(row)}]', xkkzId: 'EB', label: '军体类');
          expect(r.state, 'data');
          final c = r.courses.single;
          expect(c.identityTier, 3); // 无教学班标识：档3聚合，仍展示
          expect(c.jxbmc, isEmpty);
          expect(c.teacher, isEmpty);
          expect(c.sksj, isEmpty);
          expect(c.slots, isEmpty);
          expect(c.cap, isNull); // 认定型页无容量列 → 未知，不当 0
          expect(c.selected, isNull);
          expect(c.categories, ['军体类']);
          expect(c.tags, contains('军体类')); // tags 兼容口径保留入口名（引擎类别推断消费）
        });

        // ── 2026-10-18 LIVE 实测根因：类别真源在每行 kcgs/rdlb 字段（服务器自带，
        // 多标签以 \ 或 ，、/| 分隔），入口 dl 查询对思政/军体/外语恒空 ──
        test('服务器类别字段进 categories：kcgs 多标签（\\ 与逗号分隔）+ rdlb 认定类别', () {
          // 真实样本（live_probe_xk_test 抓于全部课程池）：
          //   中国改革开放史 kcgs=思政类； 经济法 kcgs=当代社会；
          //   思政类\军体类 = 一门课双归属； rdlb=心理健康类。
          final r = parseXkCourseList(
              '[{"kcmc":"军事理论","kch":"MIL1","kcgs":"思政类\\\\军体类"},'
              '{"kcmc":"体育与心理健康","kch":"EDU6","rdlb":"心理健康类","kcgs":"生命探索"},'
              '{"kcmc":"某课","kch":"X1","kcgs":"美育类,心理健康类"},'
              '{"kcmc":"脏行","kch":"X2","kcgs":"-","rdlb":"null"}]',
              xkkzId: 'xk_b',
              label: '全部课程');
          final cs = r.courses;
          expect(cs[0].categories, ['全部课程', '思政类', '军体类']); // 双归属拆分（#11/#2）
          expect(cs[1].categories, ['全部课程', '生命探索', '心理健康类']); // kcgs+rdlb 并集
          expect(cs[2].categories, ['全部课程', '美育类', '心理健康类']); // 逗号分隔
          // 「-」/「null」占位与脏值不进类别；入口 label 保留
          expect(cs[3].categories, ['全部课程']);
        });

        test('kcgs 兜底不依赖入口 label 存在（全部课程池行自带类别）', () {
          final r = parseXkCourseList('[{"kcmc":"大学英语","kch":"F1","kcgs":"外语类"}]',
              xkkzId: 'F');
          expect(r.courses.single.categories, ['外语类']);
          expect(r.courses.single.tags, contains('外语类'));
        });

        test('入口 label 与服务器类别重复时不重复计入 categories', () {
          final r = parseXkCourseList('[{"kcmc":"书法","kch":"W1","kcgs":"美育类"}]',
              xkkzId: 'xk_rdxkc',
              label: '美育类');
          expect(r.courses.single.categories, ['美育类']);
        });

        // 分类视图客户端回退（LIVE 实测：思政/军体/外语子入口恒空，池里按 kcgs 归类）
        test('deriveCategoryFromPool：空类别 tab 从全部课程池按 kcgs 归类回填', () {
          final pool = parseXkCourseList(
              '[{"kcmc":"军事理论","kch":"M1","kcgs":"思政类\\\\军体类"},'
              '{"kcmc":"大学英语","kch":"E1","kcgs":"外语类"},'
              '{"kcmc":"高等数学","kch":"M2","kcgs":"自然科学通识类"}]',
              xkkzId: 'xk_b',
              label: '全部课程')
              .courses;
          // 思政类 tab：命中双归属行（思政类\军体类）
          expect(deriveCategoryFromPool(pool, '思政类').map((c) => c.kcmc),
              ['军事理论']);
          // 军体类 tab：同一门双归属课也在军体桶出现（两边都计，诉求 #11）
          expect(deriveCategoryFromPool(pool, '军体类').map((c) => c.kcmc),
              ['军事理论']);
          expect(deriveCategoryFromPool(pool, '外语类').map((c) => c.kcmc),
              ['大学英语']);
          // 池里没有的类别 → 空（保持"该类别暂无课程"，不臆造）
          expect(deriveCategoryFromPool(pool, '人工智能类'), isEmpty);
          // 归一匹配：入口 label 带（演示）/括号后缀仍可命中
          expect(
              deriveCategoryFromPool(pool, '外语类（演示）').map((c) => c.kcmc),
              ['大学英语']);
        });

        test('思政/军体桶：kcxzmc 为空的认定型行跨入口合并后类别齐全', () {
          final sz = parseXkCourseList('[{"kcmc":"思想道德与法治","kch":"SZ1101"}]',
                  xkkzId: 'EA', label: '思政类')
              .courses
              .single;
          final jt = parseXkCourseList('[{"kcmc":"军事理论","kch":"MIL1101"}]',
                  xkkzId: 'EB', label: '军体类')
              .courses
              .single;
          final merged = mergeXkCourses([sz, jt]).courses;
          expect(merged.length, 2);
          expect(merged.map((m) => m.categories.first).toSet(), {'思政类', '军体类'});
        });

        test('时间列是占位符（"--"）的认定型行：slots 为空、行保留、留痕', () {
          final r = parseXkCourseList('[{"kcmc":"形势与政策Ⅰ","kch":"SZ1201","sksj":"--"}]',
              xkkzId: 'EA', label: '思政类');
          expect(r.state, 'data');
          expect(r.courses.single.slots, isEmpty);
          expect(r.issues, isNotEmpty);
        });
      });
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
