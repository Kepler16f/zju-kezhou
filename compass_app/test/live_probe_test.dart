// test/live_probe_test.dart — 真实教务网链路实测探针（用户授权，用自己沙箱凭证）。
// 默认跳过；显式开启：
//   cd compass_app && dart --enable-asserts ... 或 flutter test --dart-define=LIVE=1
// flutter test 运行在带 dart:ui 的完整 VM 上（纯 dart run 因 path_provider→flutter→dart:ui
// 传递依赖无法启动），故探针以此形式存在；沙箱目录经构造函数注入，不触发插件通道。
// 打印规则：绝不输出密码/票据；学号只露首二尾二。
// ignore_for_file: avoid_print — 本文件是手动实测探针，print 是有意的实时进度输出。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/credential_store.dart';
import 'package:compass_app/data/diagnostic_log.dart';
import 'package:compass_app/data/zju_client.dart';
import 'package:compass_app/data/zju_parse.dart';

void main() {
  if (const bool.fromEnvironment('LIVE') != true) {
    test('教务网真实链路（跳过：未设 --dart-define=LIVE=true）', () {});
    return;
  }

  test('教务网真实链路：登录→会话→成绩/专业/考试/方案', () async {
    final dir = Directory(
        'C:/Users/USER/AppData/Roaming/edu.zju.compass/compass_app/compass');
    final store = CredentialStore(dir);
    final cred = await store.loadCredentials();
    expect(cred, isNotNull, reason: '沙箱无凭证，请先在 App 内登录一次');
    final u = cred!.$1;
    print('学号 ${u.substring(0, 2)}**${u.substring(u.length - 2)}');

    final client = ZjuClient(store);
    final sw = Stopwatch()..start();
    await client.login(u, cred.$2);
    print('登录成功（${sw.elapsedMilliseconds}ms）');

    await client.ensureZdbkSession();
    print('教务网会话: ${client.zdbkLoggedIn ? '已建立' : '失败'}');

    final courses = await client.fetchTranscript();
    print('成绩 ${courses.length} 门: '
        '${courses.take(2).map((c) => '${c['name']}/${c['semester']}').join('，')}');

    final major = await client.fetchStudentMajor();
    print('专业识别: $major');

    final exams = await client.fetchExams();
    print('考试 ${exams.length} 场: '
        '${exams.isNotEmpty ? exams.first.name : '-'}');

    final practice = await client.fetchPracticeScores();
    print('课堂分: $practice');

    if (major != null) {
      final plans = await client.fetchPlansForMajor(
          majorName: major, grade: inferGradeFromStudentId(u));
      print('培养方案候选 ${plans.length} 条: '
          '${plans.isNotEmpty ? plans.first['pyfamc'] : '-'}');
    }

    // ── 0.10.7 新链路：学籍画像 → 方案目录 → 匹配 → 课程表/PDF ──
    final profile = await client.fetchStudentProfile(refresh: true);
    print('学籍画像: 专业=${profile.majorName} 学院=${profile.college} '
        '行政班=${profile.adminClass} 年级=${profile.grade ?? "?"}');

    final catalog = await client.fetchPlanCatalog(refresh: true);
    print('方案目录: ${catalog.length} 条'
        '${client.lastPlanFromCache ? '（缓存）' : '（实时）'}');

    final match = await client.matchStudentPlan(profile: profile, refresh: false);
    print('方案匹配: 候选 ${match.candidates.length} 条'
        '${match.candidates.isNotEmpty ? '，最佳=${match.best!.plan.zymc} ${match.best!.plan.synj} 级'
            '（${match.best!.reason}）' : ''}');
    for (final n in match.notes) {
      print('  匹配提示: $n');
    }

    if (match.best != null) {
      final table = await client.fetchPlanCourseTable(match.best!.plan);
      print('方案课程表: ${table.length} 门'
          '${table.isNotEmpty ? '，示例=${table.take(3).map((c) => c.name).join("，")}' : ''}');
      final pdf = await client.fetchPlanPdf(match.best!.plan);
      print('方案PDF: ${pdf == null ? "未获取" : "${pdf.length} 字节"}');

      // 假设1：先打开列表页（建菜单上下文）再取打印页
      final htmlWarm = await client.debugPlanPrintHtml(match.best!.plan,
          warmupListPage: true);
      print('[预热后]打印页 HTML 长度: ${htmlWarm.length}');
      final html = htmlWarm.isNotEmpty
          ? htmlWarm
          : await client.debugPlanPrintHtml(match.best!.plan);
      print('打印页 HTML 长度: ${html.length}');
      if (html.isNotEmpty) File('D:/compass/_diag_print.html').writeAsStringSync(html);
      final modLines = RegExp(
              r'(通识必修|通识选修|大类基础|学科基础|专业必修|专业核心|专业选修|专业限选|任意选修|集中实践|毕业设计|毕业论文|创新创业|公共选修)[^\n]{0,24}?\d{1,3}(?:\.\d+)?\s*学分')
          .allMatches(html.replaceAll(RegExp(r'<[^>]+>'), ' '))
          .take(20)
          .toList();
      print('模块声明行命中: ${modLines.length}');
      for (final m in modLines) {
        print('  MODULE: ${m.group(0)?.replaceAll(RegExp(r'\s+'), ' ').trim()}');
      }

      // 假设2：课程修读地图附件（列表字段 kcxddt 的 uid）
      final uid = (match.best!.plan.raw['kcxddt'] ?? '').toString();
      print('课程修读地图附件 uid: $uid');
      await client.debugDumpPlanPages(match.best!.plan);
    }
    for (final e in DiagnosticLog.instance.entries) {
      print(e.format());
    }

    expect(client.zdbkLoggedIn, isTrue, reason: '教务网会话未建立');
    expect(courses, isNotEmpty, reason: '成绩为空（isolate 载荷回归若未修好，这里会抛或降级缓存）');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
