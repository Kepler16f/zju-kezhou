// test/live_probe_index_html_test.dart — 选课首页原始 HTML 探针（用户授权，只读）。
// 运行：flutter test --dart-define=LIVE=true test/live_probe_index_html_test.dart
// 目的：取真实入口锚点的上级标题结构（「全部课程」归哪类）与状态标签文案。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/credential_store.dart';
import 'package:compass_app/data/zju_client.dart';

void main() {
  if (const bool.fromEnvironment('LIVE') != true) {
    test('索引 HTML LIVE（跳过：未设 --dart-define=LIVE=true）', () {});
    return;
  }

  test('选课首页 HTML 落盘', () async {
    const sandboxOverride = String.fromEnvironment('SANDBOX_DIR');
    final dir = Directory(sandboxOverride.isNotEmpty
        ? sandboxOverride
        : '${Platform.environment['APPDATA']}\\edu.zju.compass\\compass');
    final store = CredentialStore(dir);
    final cred = await store.loadCredentials();
    expect(cred, isNotNull, reason: '沙箱无凭证');
    final client = ZjuClient(store);
    await client.login(cred!.$1, cred.$2);
    await client.ensureZdbkSession();
    final index = await client.fetchXkIndex(refresh: true);
    print('rounds=${index.rounds.length} zjuGhb=${index.zjuGhb}');
    final html = client.lastXkIndexHtml ?? '';
    print('html len=${html.length}');
    final out = File('${Directory.current.path}/tool/_index_live.html');
    out.writeAsStringSync(html);
    print('written ${out.path}');
    for (final r in index.rounds.take(8)) {
      print('round: ${r.label} | dl=${r.xkkzId} | lx=${r.kklxdm} | attrs=${r.attrs}');
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
