// test/live_probe_test.dart — 真实教务网链路实测探针（用户授权，用自己沙箱凭证）。
// 默认跳过；显式开启（是本文件头注释的历史笔误更正：判定条件是 ==true，不是 =1）：
//   flutter test --dart-define=LIVE=true test/live_probe_test.dart
// 沙箱目录：优先 --dart-define=SANDBOX_DIR=...；缺省用 %APPDATA%\edu.zju.compass\compass_app\compass
// （换机不再改代码；Windows 端 Sandbox 路径由 windows/runner/Runner.rc 的 CompanyName 决定）。
// flutter test 运行在带 dart:ui 的完整 VM 上（纯 dart run 因 path_provider→flutter→dart:ui
// 传递依赖无法启动），故探针以此形式存在；沙箱目录经构造函数注入，不触发插件通道。
// 打印规则：绝不输出密码/票据；学号只露首二尾二；选课原始样本落盘仅含课程行（无 su/无 URL）。
// ignore_for_file: avoid_print — 本文件是手动实测探针，print 是有意的实时进度输出。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/credential_store.dart';
import 'package:compass_app/data/diagnostic_log.dart';
import 'package:compass_app/data/pdf_text_extractor.dart';
import 'package:compass_app/data/plan_pdf_parse.dart';
import 'package:compass_app/data/zju_client.dart';
import 'package:compass_app/data/zju_parse.dart';

void main() {
  if (const bool.fromEnvironment('LIVE') != true) {
    test('教务网真实链路（跳过：未设 --dart-define=LIVE=true）', () {});
    return;
  }

  test('教务网真实链路：登录→会话→成绩/专业/考试/方案/选课', () async {
    const sandboxOverride = String.fromEnvironment('SANDBOX_DIR');
    final dir = Directory(sandboxOverride.isNotEmpty
        ? sandboxOverride
        : '${Platform.environment['APPDATA']}\\edu.zju.compass\\compass_app\\compass');
    print('沙箱目录: ${dir.path}');
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

    // ── 学籍画像 → 方案目录 → 匹配 → 课程表/PDF（0.10.7 新链路）──
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
      if (pdf != null) {
        final sections = parsePlanPdfText(extractPdfText(pdf));
        print('PDF 解析: ${sections.topCount} 个一级板块 / '
            '${sections.sections.length} 个层级条目 / ${sections.courseCount} 门课程');
        for (final s in sections.sections.take(6)) {
          print('  [L${s.level}] ${s.label} ${s.creditsRaw}学分 '
              '课程${s.courses.length}门 说明${s.notes.length}条');
        }
      }
    }

    // ── 选课(xsxk)探针（docs/选课模块接入说明.md「待探针确认」项的一手校准）──
    final xkIndex = await client.fetchXkIndex();
    print('选课入口: 命中 ${xkIndex.queryCourseHits} 处 / 入口 ${xkIndex.rounds.length} 个'
        '${xkIndex.xkxnm != null ? '｜学年 ${xkIndex.xkxnm}-${xkIndex.xkxqm}' : '｜学年未标注'}'
        '${xkIndex.issues.isEmpty ? '' : '｜${xkIndex.issues.first}'}');
    for (final r in xkIndex.rounds.take(4)) {
      print('  · ${r.label}（kklxdm=${r.kklxdm}）');
    }
    // 探前两轮次（按需改 take(n)）：状态 / 条数 / 首行关键字段 + 原始样本脱敏落盘
    for (final r in xkIndex.rounds.take(2)) {
      final list = await client.fetchXkCourses(
          round: r,
          hiddenFields: xkIndex.hiddenFields,
          xkxnm: xkIndex.xkxnm,
          xkxqm: xkIndex.xkxqm);
      print('入口[${r.label}] 状态=${list.state} 课程=${list.courses.length}'
          '${list.issues.isEmpty ? '' : '｜${list.issues.take(2).join('；')}'}');
      if (list.courses.isNotEmpty) {
        final c = list.courses.first;
        print('  首行: kch=${c.kch} kcmc=${c.kcmc} jxb长度=${c.jxbId.length} '
            '教师=${c.teacher} 时间=${c.sksj} 容量=${c.cap} 已选=${c.selected} '
            '身份档=${c.identityTier} 时隙=${c.slots.length}');
        // 安全截断：xkkz_id 只保证非空，短 id 直接 substring 会抛 RangeError 中断整个探针（L4）
        final shortId =
            r.xkkzId.length > 6 ? r.xkkzId.substring(0, 6) : r.xkkzId;
        final dump = File('${dir.path}\\xk_probe_$shortId.json');
        dump.writeAsStringSync(const JsonEncoder.withIndent('  ')
            .convert(list.courses.take(2).map((c) => c.raw).toList()));
        print('  原始样本已落盘（仅课程行，无 su/无 URL）: ${dump.path}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }
    final tt = await client.fetchTimetableSlots();
    print('当前课表: ${tt.courses.length} 门 / ${tt.slots.length} 时隙'
        '${tt.issues.isEmpty ? '' : '｜${tt.issues.take(2).join('；')}'}');

    for (final e in DiagnosticLog.instance.entries) {
      print(e.format());
    }

    expect(client.zdbkLoggedIn, isTrue, reason: '教务网会话未建立');
    expect(courses, isNotEmpty, reason: '成绩为空（isolate 载荷回归若未修好，这里会抛或降级缓存）');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
