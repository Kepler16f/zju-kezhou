// test/live_probe_jxb_test.dart — 教学班（JxbList）端点 LIVE 探针（用户授权，只读）。
// 目的：确认 zzxkghb_cxZzxkGhbJxbList.html 的路径/参数/响应形状，校准
// docs/选课模块接入说明.md §1.1 的「教学班」待确认项。
// 运行：flutter test --dart-define=LIVE=true test/live_probe_jxb_test.dart
// 纪律：只打 1 个教学班请求（不批量），失败即停，不做重试轰炸。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/credential_store.dart';
import 'package:compass_app/data/zju_client.dart';

void main() {
  if (const bool.fromEnvironment('LIVE') != true) {
    test('教学班 LIVE（跳过：未设 --dart-define=LIVE=true）', () {});
    return;
  }

  test('教学班端点实测', () async {
    const sandboxOverride = String.fromEnvironment('SANDBOX_DIR');
    final dir = Directory(sandboxOverride.isNotEmpty
        ? sandboxOverride
        : '${Platform.environment['APPDATA']}\\edu.zju.compass\\compass');
    final store = CredentialStore(dir);
    final cred = await store.loadCredentials();
    expect(cred, isNotNull, reason: '沙箱无凭证');
    final u = cred!.$1;
    print('学号 ${u.substring(0, 2)}**${u.substring(u.length - 2)}');

    final client = ZjuClient(store);
    await client.login(u, cred.$2);
    await client.ensureZdbkSession();
    expect(client.zdbkLoggedIn, isTrue, reason: '教务网会话未建立');

    final index = await client.fetchXkIndex(refresh: true);
    print('入口 ${index.rounds.length} 个，zjuGhb=${index.zjuGhb}，'
        '学期=${index.xkxnm}-${index.xkxqm}');
    if (index.rounds.isEmpty) {
      print('!! 无入口，停止');
      return;
    }
    final round = index.rounds.firstWhere(
        (r) => r.label.contains('全部') || r.xkkzId == 'xk_n',
        orElse: () => index.rounds.first);
    final list = await client.fetchXkCourses(
        round: round,
        hiddenFields: index.hiddenFields,
        xkxnm: index.xkxnm,
        xkxqm: index.xkxqm,
        zjuGhb: index.zjuGhb);
    print('列表 state=${list.state} 课程=${list.courses.length}');
    if (list.courses.isEmpty) {
      print('!! 无课程，停止');
      return;
    }
    final c = list.courses.first;
    print('探测课程：${c.kcmc} kch=${c.kch} xkkh=${c.raw['xkkh']}');

    final jxb = await client.fetchXkJxbList(
        round: round,
        course: c,
        hiddenFields: index.hiddenFields,
        xkxnm: index.xkxnm,
        xkxqm: index.xkxqm,
        zjuGhb: index.zjuGhb,
        refresh: true);
    print('教学班 state=${jxb.state} 条数=${jxb.courses.length} '
        'issues=${jxb.issues.take(3).join(";")}');
    for (final j in jxb.courses.take(5)) {
      print('  教学班: ${j.jxbmc}｜教师=${j.teacher}｜时间=${j.sksj}｜'
          '地点=${j.cdmc}｜容量=${j.cap}/${j.selected}｜xkkh=${j.raw['xkkh']}');
      final keys = j.raw.keys.toList()..sort();
      print('  row keys: $keys');
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
