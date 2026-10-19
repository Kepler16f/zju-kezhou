// test/live_probe_xk_test.dart — 选课专项 LIVE 探针（用户授权真实凭证，只读查询）。
// 目的：验证「分类视图里军体类/思政类等入口到底有没有课程返回」——一手校准
// docs/选课模块接入说明.md §9 的待确认项（lx 码值 / 认定型子入口）。
// 运行：flutter test --dart-define=LIVE=true test/live_probe_xk_test.dart
// 纪律：每入口之间间隔 1.2s，绝不轰炸；任一入口触发软封禁即停后续批量。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/credential_store.dart';
import 'package:compass_app/data/zju_client.dart';

void main() {
  if (const bool.fromEnvironment('LIVE') != true) {
    test('选课专项 LIVE（跳过：未设 --dart-define=LIVE=true）', () {});
    return;
  }

  test('选课入口全量实测：每个类别入口的课程数与状态', () async {
    const sandboxOverride = String.fromEnvironment('SANDBOX_DIR');
    final dir = Directory(sandboxOverride.isNotEmpty
        ? sandboxOverride
        : '${Platform.environment['APPDATA']}\\edu.zju.compass\\compass_app\\compass');
    final store = CredentialStore(dir);
    final cred = await store.loadCredentials();
    expect(cred, isNotNull, reason: '沙箱无凭证');
    final u = cred!.$1;
    print('学号 ${u.substring(0, 2)}**${u.substring(u.length - 2)}');

    final client = ZjuClient(store);
    await client.login(u, cred.$2);
    await client.ensureZdbkSession();
    expect(client.zdbkLoggedIn, isTrue, reason: '教务网会话未建立');

    // 会话体检：先拉一次成绩（走 jwglxt 另一接口）。若这里也为空/非 JSON，
    // 说明是软封禁/会话问题而非选课端点差异，须区分后再解读选课结果。
    final probe = await client.fetchTranscript();
    print('会话体检·成绩 ${probe.length} 门（>0 表示会话正常，选课若仍空才是端点问题）');

    final xkIndex = await client.fetchXkIndex(refresh: true);
    print('选课入口: 命中 ${xkIndex.queryCourseHits} 处 / '
        '入口 ${xkIndex.rounds.length} 个'
        '${xkIndex.xkxnm != null ? '｜${xkIndex.xkxnm}-${xkIndex.xkxqm}' : ''}'
        '${xkIndex.issues.isEmpty ? '' : '｜${xkIndex.issues.join('；')}'}');
    for (final r in xkIndex.rounds) {
      print('  入口: ${r.label} dl=${r.xkkzId} lx=${r.kklxdm} '
          'attrs=${r.attrs} extraArgs=${r.extraArgs}');
    }

    // 定向探针（遵守软封禁教训，不逐入口轰炸）：只测军体/外语/美育 + 一个对照，
    // 间隔 2.5s。其余入口与军体类同构（同 dl/lx/attrs 形态），不必重复打。
    final targets = <String>{'军体类', '外语类', '美育类', '全部课程'};
    final report = <String>[];
    for (final r in xkIndex.rounds) {
      if (!targets.contains(r.label)) continue;
      final list = await client.fetchXkCourses(
          round: r,
          hiddenFields: xkIndex.hiddenFields,
          xkxnm: xkIndex.xkxnm,
          xkxqm: xkIndex.xkxqm,
          zjuGhb: xkIndex.zjuGhb, // 与 course_select_page 同参：浙大页走 zzxkGhb KcList
          refresh: true);
      final line = '入口[${r.label}] dl=${r.xkkzId} lx=${r.kklxdm} '
          '→ state=${list.state} courses=${list.courses.length}'
          '${list.issues.isNotEmpty ? ' issues=${list.issues.take(2).join(";")}' : ''}';
      print(line);
      report.add(line);
      if (list.courses.isNotEmpty) {
        final c = list.courses.first;
        print('  首行: kcmc=${c.kcmc} 教师=${c.teacher} 时间=${c.sksj} '
            '容量=${c.cap} 已选=${c.selected} 类别=${c.categories}');
      }
      if (list.blocked) {
        print('!! 触发软封禁，停止批量（避免延长封锁）');
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 2500));
    }

    // 缓存复读（refresh:false，data 态缓存无 TTL → 零新请求）：统计全部课程池里
    // kcgs（课程归属）字段取值分布 —— 这是服务器自带的"类别"标签，客户端按它过滤
    // 才是军体/思政等非认定型大类正确的填充方式（服务器端 dl=EB/F 查询恒空）。
    for (final r in xkIndex.rounds) {
      if (r.label != '全部课程' || r.xkkzId != 'xk_n') continue;
      final list = await client.fetchXkCourses(
          round: r,
          hiddenFields: xkIndex.hiddenFields,
          xkxnm: xkIndex.xkxnm,
          xkxqm: xkIndex.xkxqm,
          zjuGhb: xkIndex.zjuGhb);
      final dist = <String, int>{};
      for (final c in list.courses) {
        final g = '${c.raw['kcgs'] ?? ''}'.trim();
        if (g.isNotEmpty) dist[g] = (dist[g] ?? 0) + 1;
      }
      print('kcgs 取值分布（${list.courses.length} 门 / 全部课程 dl=xk_n）:');
      final entries = dist.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      for (final e in entries) {
        print('  ${e.key} = ${e.value}');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
