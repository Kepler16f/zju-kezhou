/// 课舟 App 主入口：底部导航四页签（学业/方案/选课/设置；审计并入方案页，原「工具」页签并入学业页）。
/// 数据流：设置页选源运行 → 状态持有 courses/report/practice/choosed/timetable → 各页消费。
/// 持久化：凭证沙箱存储（启动自动登录）；最近会话缓存（重启即恢复数据）；AI 解读配置（出厂默认公益免费端点）。
/// 崩溃兜底：ErrorWidget → 友好错误卡（不再出现灰屏）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, rootBundle;

import 'data/ai_client.dart';
import 'data/ai_config.dart';
import 'data/ai_prompts.dart';
import 'data/credential_store.dart';
import 'data/diagnostic_log.dart';
import 'data/share_pack.dart';
import 'data/xk_parse.dart' show TimetableParseResult, XkListParseResult;
import 'data/zju_client.dart';
import 'data/zju_parse.dart';
import 'data/zju_parse_ext.dart';
import 'engine/adapters.dart';
import 'engine/audit.dart';
import 'engine/course_marks.dart';
import 'engine/exam.dart';
// 课程类别打通（学分看板「未分类」修复）：用审计方案板块补全展示链路的 category。
import 'engine/plan_audit_adapter.dart' show applyPlanCategories;
import 'pages/course_select_page.dart';
import 'pages/curriculum_plan_page.dart';
import 'pages/scholar_page.dart';
import 'pages/settings_page.dart';
import 'pages/teacher_review_page.dart';
import 'widgets/ai_chat.dart';
import 'widgets/boat_icon.dart';

void main(List<String> args) async {
  // 崩溃自动恢复标记（RegisterApplicationRestart 重启时带 --crashed）
  _crashRecovered = args.contains('--crashed');
  // PiliPlus 同款窗口管理：异步就绪后显示（绕开引擎默认显示/resize 路径）。
  // 仅桌面（Windows/macOS/Linux）启用：移动端（iOS/Android/ohos）无此插件实现，
  // 调用即 MissingPluginException 崩溃。
  WidgetsFlutterBinding.ensureInitialized();
  if (_isDesktopWindowed) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1280, 720),
      minimumSize: Size(400, 300),
      title: '课舟',
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
    });
  }
  ErrorWidget.builder = (details) {
    DiagnosticLog.instance
        .record('界面异常', level: 'error', detail: '${details.exception}');
    return _FriendlyError(details: details);
  };
  runApp(const KeZhouApp());
}

bool _crashRecovered = false;

/// 仅桌面三平台启用 window_manager（Windows/macOS/Linux）；
/// 移动端与 ohos 无该插件实现，调用会 MissingPluginException。
bool get _isDesktopWindowed {
  try {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  } catch (_) {
    return false; // 未知平台（如某些 ohos 分支）保守关闭
  }
}

class _FriendlyError extends StatelessWidget {
  final FlutterErrorDetails details;
  const _FriendlyError({required this.details});

  @override
  Widget build(BuildContext context) => Material(
        child: Center(
          child: Card(
            margin: const EdgeInsets.all(28),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.error_outline,
                          color: Theme.of(context).colorScheme.error),
                      const SizedBox(width: 8),
                      const Text('页面渲染遇到问题',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('请到「设置」页点"登录诊断日志"复制反馈。\n'
                      '通常重新拉取一次数据即可恢复。',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        ),
      );
}

class KeZhouApp extends StatelessWidget {
  const KeZhouApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '课舟',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1D4ED8)),
        useMaterial3: true,
        fontFamily: 'NotoSansSC',
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF60A5FA), brightness: Brightness.dark),
        useMaterial3: true,
        fontFamily: 'NotoSansSC',
      ),
      // 引擎无障碍桥崩溃规避：Windows 引擎的
      // AccessibilityBridge::CreateRemoveReparentedNodesUpdate() 在 release 下会解引用
      // 无父节点的 AXNode（accessibility_bridge.cc:229，assert 被 NDEBUG 编译掉），
      // 只要语义树被读屏器/自动化工具启用、且发生节点重新挂载，进程即被
      // 0xc000041d 强杀。这里让应用不产出语义树，重新挂载无从发生。
      // 代价：读屏器读不到本应用内容，属临时规避，待上游修掉该空指针后移除。
      builder: (context, child) => ExcludeSemantics(child: child!),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  // 页签索引常量（评审B：插入/调序只改这里，禁止散落裸数字）。
  // 顺序：0 学业 / 1 方案 / 2 选课 / 3 设置（审计并入方案页，原「工具」页签并入学业页）
  static const int tabScholar = 0;
  static const int tabPlan = 1;
  static const int tabSelect = 2;
  static const int tabSettings = 3;

  final _store = CredentialStore();
  late final ZjuClient _client = ZjuClient(_store);
  // 全局 AI 对话（诉求 #9）：悬浮入口唤起抽屉；history 跨页签常驻。
  final _aiCtrl = AiChatController();
  AuditEngine? _engine;
  late final Future<void> _assetsReady; // 启动资产加载完成信号（运行审计前等待）
  int _tabIndex = tabScholar;

  DataMode _mode = DataMode.sample;
  String _major = 'computer_science'; // 始终为内置 key（下拉框合法值）
  String _current = '2026-A';
  final _userCtl = TextEditingController();
  final _passCtl = TextEditingController();
  final _pasteCtl = TextEditingController();
  String? _loggedInAs; // 已记住的学号（自动登录状态展示）
  DateTime? _lastDataAt; // 上次成功拉取数据的时间（会话缓存时间戳）

  Map<String, dynamic>? _report;
  List<Map<String, dynamic>> _courses = [];
  Map<String, double> _practice = {};
  List<ExamInfo> _exams = [];
  Map<String, Map<String, bool>> _marks = {}; // 本地排除标记（仅学业视图）
  String? _planQuality;
  String? _recordSourceLabel;
  XkListParseResult? _choosed; // 本学期已选（在修未出成绩，诉求 #8；仅教务模式有值）
  TimetableParseResult? _timetable; // 本学期课表（诉求 #16；方案页底部周视图数据源）
  bool _busy = false;
  String? _notice;
  Map<String, dynamic>? _auditPlan; // 当前审计所用方案（选课页做缺口/先修/开课季匹配用）
  AiConfig _aiConfig = const AiConfig(); // AI 解读配置（出厂无存档时默认公益端点，见 initState）
  int _aiSessionReset = 0; // 一键清除时自增：通知选课页清掉 AI 问答历史等会话态
  bool _teacherMode = false; // 导师审阅模式（只读审阅学生分享包；不登录教务）
  Map<String, dynamic>? _lastStudent; // 最近一次审计的 student 段（分享包导出复用其 grade/学期）
  String? _studentName; // 教务档案姓名（仅实名导出时使用，默认匿名路径不碰它）

  static const majors = {
    'computer_science': '计算机科学与技术（样例方案）',
    'software_engineering': '软件工程（样例方案）',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // resize 感知 → 暂停网络
    _assetsReady = _loadAssets().catchError((Object e, StackTrace _) {
      DiagnosticLog.instance.record('资产加载', level: 'error', detail: '$e');
    });
    _restoreSession(); // 先恢复上次会话（即时展示），再后台自动登录刷新
  }

  @override
  void didChangeMetrics() {
    _client.onMetricsChanged(); // 窗口尺寸变化：网络请求等待窗口稳定
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _userCtl.dispose();
    _passCtl.dispose();
    _pasteCtl.dispose();
    super.dispose();
  }

  Future<void> _loadAssets() async {
    final plans = <String, String>{};
    for (final m in majors.keys) {
      plans[m] = await rootBundle.loadString('assets/golden/$m.json');
    }
    _engine = AuditEngine.fromJsonAssets(plans);
  }

  /// 恢复上次会话：凭证 → 学号回填 + 自动登录；会话缓存 → 数据即时展示。
  Future<void> _restoreSession() async {
    final cred = await _store.loadCredentials();
    if (cred != null && mounted) {
      setState(() {
        _userCtl.text = cred.$1;
        _loggedInAs = cred.$1;
        _mode = DataMode.zju;
      });
    }
    // AI 解读配置：出厂从未存过配置 → 默认「公益免费」端点（开箱即用，诉求 #4：
    // 免 Key、有限额）；用户显式保存过（含选「关闭」）后完全尊重其选择。
    // 缺失/损坏回落 none 同样按未存过处理（下次开机仍是免费端点）。
    final aiCfg = await _store.loadAiConfig();
    final firstRun =
        aiCfg.provider == AiProvider.none && !await _store.hasStoredAiConfig();
    if (mounted) {
      setState(() => _aiConfig =
          firstRun ? AiConfig.preset(AiProvider.pollinations) : aiCfg);
    }
    // 本地排除标记随会话恢复（不依赖登录，粘贴/样例模式同样生效）
    final marksRaw = await _store.readCache('course_marks');
    final marks = parseMarks(marksRaw);
    if (marks.isNotEmpty && mounted) setState(() => _marks = marks);
    // 会话缓存先展示（重启不白屏）
    final cached = await _store.readCache('last_session');
    if (cached != null && mounted) {
      try {
        final s = json.decode(cached) as Map<String, dynamic>;
        setState(() {
          _report = s['report'] as Map<String, dynamic>?;
          _lastStudent = (s['student'] as Map?)?.cast<String, dynamic>();
          _teacherMode = s['teacher_mode'] as bool? ?? false;
          _courses = (s['courses'] as List? ?? const [])
              .cast<Map<String, dynamic>>();
          _practice = (s['practice'] as Map? ?? const {})
              .map((k, v) => MapEntry(k.toString(), (v as num).toDouble()));
          _planQuality = s['plan_quality'] as String?;          _recordSourceLabel = (s['source_label'] as String?) ?? '上次会话数据';
          _lastDataAt = (s['saved_at'] as String?) != null
              ? DateTime.tryParse(s['saved_at'] as String)
              : null;
        });
      } catch (_) {/* 缓存损坏则忽略 */}
    }
    // 崩溃自动恢复（RegisterApplicationRestart 带 --crashed）：跳过自动登录
    // 防崩循环，显示恢复提示；用户手动刷新时再走网络。
    final crashed = _crashRecovered;
    if (crashed) {
      if (mounted) {
        setState(() => _notice = '上次窗口调整时遇到引擎异常已自动恢复（数据为上次缓存）。'
            '如需刷新数据，请在设置页手动拉取。');
      }
      DiagnosticLog.instance.record('崩溃恢复', detail: '检测到 --crashed，跳过自动登录');
    } else if (cred != null) {
      unawaited(_autoLogin(cred.$1, cred.$2));
    }
  }

  Future<void> _autoLogin(String username, String password) async {
    try {
      await _client.login(username, password);
      DiagnosticLog.instance.record('自动登录', detail: '启动凭证登录成功');
      setState(() => _notice = null);
      await _fromZju(auto: true);
    } catch (e) {
      DiagnosticLog.instance
          .record('自动登录', level: 'warn', detail: '$e（校园网外属正常）');
      // 可见但不打扰：提示当前为缓存数据、手动刷新免输密码
      if (mounted) {
        setState(() => _notice = '自动登录未成功（可能不在校园网）——当前展示缓存数据；'
            '回到校园网后在设置页点"登录教务网并拉取"即可直接刷新（无需输密码）');
      }
    }
  }

  Future<void> _saveSession() async {
    await _store.saveCache('last_session', json.encode({
      'report': _report,
      'courses': _courses,
      'practice': _practice,
      'plan_quality': _planQuality,
      'source_label': _recordSourceLabel,
      'teacher_mode': _teacherMode,
      'student': _lastStudent,
      'saved_at': DateTime.now().toIso8601String(),
    }));
  }

  /// 「分享给导师」导出（诉求：导师模式 P1）：当前审计数据 → 脱敏分享包。
  /// 剪贴板 + 沙箱 share/ 双通道；实名选项默认关（alias 保持匿名）。
  /// 返回提示文本（行数/路径），失败返回原因——设置页直接展示。
  Future<String> _exportSharePack({bool realName = false}) async {
    if (_courses.isEmpty || _report == null) {
      return '尚未完成学业审计：先在设置页运行一次审计（登录教务或样例均可）';
    }
    final prev = _lastStudent ?? const <String, dynamic>{};
    final student = <String, dynamic>{
      'alias': realName ? (_studentName ?? '本人') : '匿名同学',
      'major': prev['major']?.toString() ??
          (_auditPlan != null
              ? (_auditPlan!['meta']?['major'] ?? _major).toString()
              : _major),
      'grade': prev['grade']?.toString() ?? _current.substring(0, 4),
      'current_semester': prev['current_semester']?.toString() ?? _current,
    };
    final packed = buildSharePack(
      student: student,
      courses: _courses,
      plan: _auditPlan,
    );
    await Clipboard.setData(ClipboardData(text: packed.jsonText));
    String pathNote;
    try {
      final dir = await _store.sandboxDirPath();
      pathNote = '文件：${await writeSharePack(dir, packed.jsonText)}';
    } catch (e) {
      pathNote = '文件落盘失败（$e），内容已在剪贴板';
    }
    DiagnosticLog.instance.record('分享导出',
        detail: '${packed.coursesCount} 门课程随包导出'
            '（${realName ? '实名' : '匿名'}，${packed.droppedRows} 行因缺字段未入包）');
    final drop = packed.droppedRows > 0 ? '（${packed.droppedRows} 行缺关键字段未入包）' : '';
    return '分享包已复制（${packed.coursesCount} 门课程$drop）——粘贴发送给学生/导师即可。$pathNote';
  }

  /// 学业视图用的课程列表：原始记录 + 本地排除标记。
  /// 审计始终吃原始 _courses（报告 §3.1：排除标记不污染审计口径）。
  List<Map<String, dynamic>> get _coursesViewed =>
      applyCourseMarks(_courses, _marks);

  /// 标记变更：内存态立即生效，持久化到沙箱 cache（失败静默——只是体验优化）。
  Future<void> _setMark(String key, String kind, bool value) async {
    setState(() {
      final m = Map<String, Map<String, bool>>.of(_marks);
      final row = Map<String, bool>.of(m[key] ?? const {});
      row[kind] = value;
      if (!(row['excludeCredit'] ?? false) && !(row['excludeGpa'] ?? false)) {
        m.remove(key);
      } else {
        m[key] = row;
      }
      _marks = m;
    });
    await _store.saveCache('course_marks', json.encode(_marks));
  }

  Future<void> _runAudit(Map<String, dynamic> record) async {
    // 培养方案为启动期异步资产：早期点击先等加载完成，而不是直接报"尚未加载"。
    await _assetsReady;
    final engine = _engine;
    if (engine == null) {
      setState(() => _notice = '培养方案尚未加载完成，请稍候重试');
      return;
    }
    final out = engine.main(record);
    if (out.containsKey('error')) {
      setState(() => _notice = out['error'].toString());
      return;
    }
    // 记录本次审计所用方案（runtime 优先；未知专业静默跳过——选课页对此按"无方案"降级）
    Map<String, dynamic>? auditPlan;
    try {
      auditPlan = engine.findPlan(record['student']['major'] as String);
    } catch (_) {}
    // 类别打通（学分看板「未分类」修复）：报告已在 engine.main 里算完，此处
    // 改写 record 课程行只影响展示链路（学业页学分看板）与 _saveSession 落盘。
    // 以审计方案的板块为唯一类别事实源，只补空/「未分类」，教务自带 kcxzmc 不动。
    if (auditPlan != null) {
      final filled = applyPlanCategories(
          (record['courses'] as List).cast<Map<String, dynamic>>(), auditPlan);
      if (filled > 0) {
        DiagnosticLog.instance.record('课程类别',
            detail: '按培养方案板块补全 $filled 门课程的类别（展示链路）');
      }
    }
    setState(() {
      _report = out['report'] as Map<String, dynamic>;
      _lastStudent = (record['student'] as Map?)?.cast<String, dynamic>();
      _courses = (record['courses'] as List).cast<Map<String, dynamic>>();
      _auditPlan = auditPlan;
      _notice = null;
      _lastDataAt = DateTime.now();
      _tabIndex = tabPlan; // 审计完成后自动切到方案页（审计区已并入方案页，诉求 #13）
    });
    unawaited(_saveSession());
  }

  Future<void> _fromSample() async {
    final name = _major == 'computer_science' ? 'demo1_cs_full.json' : 'demo3_se_full.json';
    final rec = json.decode(await rootBundle.loadString('assets/samples/$name'))
        as Map<String, dynamic>;
    setState(() {
      _busy = true;
      _recordSourceLabel = '内置样例（$name）';
      _planQuality = null;
      _choosed = null; // 样例无已选/课表数据，切源即清（方案页对应区块不展示）
      _timetable = null;
    });
    await _runAudit(rec);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _fromPaste() async {
    setState(() {
      _busy = true;
      _choosed = null; // 粘贴模式无已选/课表数据
      _timetable = null;
    });
    final res = RecordAdapter.run(
        recordText: _pasteCtl.text,
        studentJson: json.encode({
          'alias': '本地同学',
          'major': _major,
          'grade': _current.substring(0, 4),
          'current_semester': _current,
        }));
    if (res.containsKey('error')) {
      setState(() {
        _notice = res['error'].toString();
        _busy = false;
      });
      return;
    }
    final rec = json.decode(res['record_json'] as String) as Map<String, dynamic>;
    setState(() => _recordSourceLabel = '粘贴成绩（${(rec['courses'] as List).length} 条）');
    await _runAudit(rec);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _fromZju({bool auto = false}) async {
    if (!auto) setState(() => _busy = true);
    try {
      if (_client.ssoTicket == null) {
        // 凭证优先级：输入框 > 记住的凭证（Helechron 同款体验：手动刷新免输密码）
        var username = _userCtl.text.trim();
        var password = _passCtl.text;
        if (password.isEmpty) {
          final saved = await _store.loadCredentials();
          if (saved != null) {
            password = saved.$2;
            if (username.isEmpty) username = saved.$1;
          }
        }
        if (username.isEmpty || password.isEmpty) {
          setState(() {
            _notice = '请输入学号与统一身份认证密码（登录后会自动记住）';
            _busy = false;
          });
          return;
        }
        await _client.login(username, password);
        setState(() => _loggedInAs = username);
      }
      // 并行拉取：成绩（必须）+ 专业/课堂分/考试安排（尽力而为，失败不阻断）。
      // 四路并发经 RequestThrottle 主机级限频（FIFO + 最小间隔削峰），不会触发 zdbk 风控。
      final majorTask = _client.fetchStudentMajor().catchError((_) => null);
      final practiceTask =
          _client.fetchPracticeScores().catchError((_) => <String, double>{});
      final examTask = _client.fetchExams().catchError((_) => <ExamInfo>[]);
      final courses = await _client.fetchTranscript();
      final majorName = await majorTask;
      final practice = await practiceTask;
      final exams = await examTask;
      setState(() {
        _practice = practice;
        _exams = exams;
      });

      // 本学期已选（在修未出成绩，诉求 #8）：best-effort，失败静默；
      // 仅 SSO 会话可用时调用（样例/粘贴模式不联网拉此数据）。
      try {
        final xnXq = _xnXqOf(_current);
        if (_client.ssoTicket != null && xnXq != null) {
          final choosed =
              await _client.fetchXkChoosedCourses(xn: xnXq.$1, xq: xnXq.$2);
          if (mounted) setState(() => _choosed = choosed);
        }
      } catch (_) {/* 静默：已选计数只是辅助信息，失败不阻断审计 */}

      // 专业识别 → 培养方案（方案列表接口 + 客户端匹配；歧义留给「方案」页点选）
      var auditMajor = _major;
      var quality = '';
      if (majorName != null) {
        final builtinKey = matchPlanKey(majorName, majors.keys.toList());
        try {
          final profile = await _client.fetchStudentProfile();
          if (profile.name.isNotEmpty) {
            // 姓名仅本机留存，供「实名导出」选项使用；匿名路径绝不触碰。
            _studentName = profile.name;
          }
          final resolved = await _client.resolveAuditPlan(
              majorName: majorName,
              grade: profile.grade ??
                  inferGradeFromStudentId(_userCtl.text.trim()),
              transcript: courses);
          final planFile = resolved.planFile;
          if (planFile != null) {
            final key = builtinKey ?? 'zdbk:$majorName';
            _engine?.registerRuntimePlan(key, planFile);
            auditMajor = key;
            final qs = (planFile['meta']['quality'] as List).cast<String>();
            quality = resolved.quality +
                (qs.isEmpty ? '' : '｜⚠️ ${qs.join('；')}');
          } else {
            quality = resolved.quality;
          }
        } catch (e) {
          DiagnosticLog.instance.record('方案获取', level: 'warn', detail: '$e');
        }
        if (quality.isEmpty && builtinKey == null) {
          quality = '教务方案未获取到，且内置方案库无「$majorName」，'
              '审计将使用当前选择器方案（结果仅供参考）';
        }
      }
      setState(() => _planQuality = quality.isEmpty ? null : quality);

      // 学期/年级自动推断（学期选择器值保持合法：仅接受标准格式）
      final sem = currentSemesterFrom(courses);
      final grade = inferGradeFromStudentId(_userCtl.text.trim());
      final student = <String, dynamic>{
        'alias': '本人',
        'major': auditMajor,
        'grade': grade ?? _current.substring(0, 4),
        'current_semester': _current,
      };
      if (sem != null) {
        student['current_semester'] = sem;
        if (RegExp(r'^20\d{2}-[AB]$').hasMatch(sem)) {
          setState(() => _current = sem);
        }
      }
      final rec = <String, dynamic>{
        'student': student,
        'source': 'xuezaizheda_api',
        'courses': courses,
      };
      setState(() {
        _recordSourceLabel = '教务网只读（${courses.length} 条'
            '${_client.lastFromCache ? '，⚠️ 已降级展示缓存' : '，会话仅内存'}）'
            '${majorName != null ? '｜$majorName' : ''}';
      });
      await _runAudit(rec);
      // 本学期课表（诉求 #16）：审计成功后异步拉取（失败静默），方案页底部展示周视图。
      unawaited(_loadTimetable());
    } on AuthException catch (e) {
      if (!auto) setState(() => _notice = e.message);
    } catch (e) {
      if (!auto) {
        setState(() => _notice = '教务网访问异常：$e（校园网外无法直连 zju.edu.cn）');
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  /// 学期选择器值 → 已选课程接口的 xn/xq（诉求 #8）：
  /// '2026-A'→('2026-2027','1')、'-B'→'2'、'-C'→'3'（短学期）。
  /// 非标准格式返回 null（宁缺勿猜）。
  static (String, String)? _xnXqOf(String current) {
    final m = RegExp(r'^(\d{4})-([ABC])$').firstMatch(current.trim());
    if (m == null) return null;
    final xn = '${m.group(1)}-${int.parse(m.group(1)!) + 1}';
    final xq = switch (m.group(2)) { 'A' => '1', 'B' => '2', _ => '3' };
    return (xn, xq);
  }

  /// 本学期课表（诉求 #16）：best-effort，未登录/失败静默跳过（方案页有数据才展示）。
  Future<void> _loadTimetable() async {
    if (_client.ssoTicket == null) return;
    try {
      final tt = await _client.fetchTimetableSlots();
      if (mounted) setState(() => _timetable = tt);
    } catch (_) {/* 静默：课表是辅助视图，失败不打扰 */}
  }

  /// AI 配置保存（沙箱落盘 + 内存态刷新）。
  Future<void> _setAiConfig(AiConfig cfg) async {
    await _store.saveAiConfig(cfg);
    if (mounted) setState(() => _aiConfig = cfg);
  }

  /// AI 连接测试：最小请求验证密钥/地址（不携带任何教务数据）。
  /// 全 catch 兜底：AiClient 有意只捕 Exception（Error 属编程缺陷）；但测试按钮
  /// 不能因此软锁死，任何意外都要回落成可读文案（评审实测：漏写 scheme 会抛 Error）。
  Future<String> _testAi(AiConfig cfg) async {
    try {
      final client = AiClient(cfg);
      final out = await client.chat(
        system: '你是连接测试助手。',
        messages: const [
          {'role': 'user', 'content': '请只回复：连接正常'}
        ],
        // claude-opus-5-5 自适应思考计入 max_tokens，给小了对端可能只思考不吐字
        maxTokens: 4096,
      );
      return switch (out) {
        AiReply(:final text) => '连接正常（模型：${text.trim()}）',
        AiFailure(:final message) => '连接失败：$message',
      };
    } catch (_) {
      return '连接失败：请求异常（请检查接口地址格式后重试）';
    }
  }

  /// 给 AI 对话抽屉的上下文摘要：审计报告的脱敏子集（auditSubsetOf 白名单，
  /// 不含姓名/学号/成绩明细）；无报告时返回 null（抽屉显示无附加上下文）。
  String? _aiAuditSummary() {
    final sub = auditSubsetOf(_report);
    if (sub == null) return null;
    return const JsonEncoder.withIndent('  ').convert(sub);
  }

  Future<void> _clearData() async {
    await _store.deleteCredentials();
    await _store.deleteAiConfig(); // AI 密钥属"全部本地数据"，必须一并删除（合规承诺）
    await _store.clearCache();
    _store.clearMemory();
    _client.disposeClient();
    _engine?.clearRuntimePlans();
    DiagnosticLog.instance.clear();
    setState(() {
      _report = null;
      _courses = [];
      _practice = {};
      _exams = [];
      _marks = {};
      _planQuality = null;
      _recordSourceLabel = null;
      _loggedInAs = null;
      _lastDataAt = null;
      _notice = null;
      _auditPlan = null;
      _choosed = null;
      _timetable = null;
      _aiConfig = const AiConfig();
      _aiSessionReset++; // 让选课页清掉 AI 问答历史（含上一账号的课程名/解读文本）
    });
  }

  @override
  Widget build(BuildContext context) {
    // 导师审阅模式：整页审阅台形态——无四页签、无 AI 悬浮帆、不建教务会话。
    // 退出入口固定在顶部条（防"进去出不来"）；学生数据与审阅包数据完全隔离。
    if (_teacherMode) {
      return Scaffold(
        body: SafeArea(
          top: true,
          bottom: true,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    const Text('导师审阅模式',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () {
                        setState(() => _teacherMode = false);
                        unawaited(_saveSession());
                      },
                      icon: const Icon(Icons.exit_to_app_outlined, size: 18),
                      label: const Text('返回学生模式'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: TeacherReviewPage(
                  onAudit: (record) {
                    final engine = _engine;
                    if (engine == null) {
                      return {'error': '培养方案引擎尚未加载，请稍候重试'};
                    }
                    return engine.main(record);
                  },
                  onRegisterPlan: (major, plan) =>
                      _engine?.registerRuntimePlan(major, plan),
                  saveCache: _store.saveCache,
                  readCache: _store.readCache,
                  onAskAi: _aiConfig.enabled
                      ? (report) {
                          final sub = auditSubsetOf(report);
                          showAiChat(
                            context,
                            controller: _aiCtrl,
                            config: _aiConfig,
                            onGoSettings: () {},
                            contextSummary: sub == null
                                ? null
                                : const JsonEncoder.withIndent('  ').convert(sub),
                          );
                        }
                      : null,
                  listPacks: () async {
                    final dir = await _store.sandboxDirPath();
                    return listSharePackFiles(dir);
                  },
                  readPackFile: (path) async {
                    try {
                      return await File(path).readAsString();
                    } catch (_) {
                      return null;
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      // 无 AppBar：手机上不包 SafeArea 会把首屏内容画进状态栏（遮挡修复 #3）。
      // bottom=false，底部由 NavigationBar 自行占位。
      body: SafeArea(
        top: true,
        bottom: false,
        child: IndexedStack(
        index: _tabIndex,
        children: [
          ScholarPage(
            courses: _coursesViewed,
            practice: _practice,
            exams: _exams,
            marks: _marks,
            onMark: _setMark,
            sourceLabel: _recordSourceLabel,
            onGoSettings: () => setState(() => _tabIndex = tabSettings),
            // 快捷卡两入口（诉求 #16）：培养方案 / 我的课表（课表周视图在方案页底部，
            // 两卡暂都跳方案页签，不新增页签）。
            onGoPlan: () => setState(() => _tabIndex = tabPlan),
            onGoTimetable: () => setState(() => _tabIndex = tabPlan),
            onRefresh: () async => switch (_mode) {
              DataMode.sample => _fromSample(),
              DataMode.paste => _fromPaste(),
              DataMode.zju => _fromZju(),
            },
          ),
          CurriculumPlanPage(
            client: _client,
            store: _store,
            loggedIn: _loggedInAs != null,
            transcript: _courses,
            onGoSettings: () => setState(() => _tabIndex = tabSettings),
            report: _report,
            choosed: _choosed,
            timetable: _timetable,
          ),
          CourseSelectPage(
            client: _client,
            store: _store,
            loggedIn: _loggedInAs != null,
            active: _tabIndex == tabSelect,
            currentSemester: _current,
            transcript: _courses,
            plan: _auditPlan,
            report: _report,
            aiConfig: _aiConfig,
            resetToken: _aiSessionReset,
            onGoSettings: () => setState(() => _tabIndex = tabSettings),
          ),
          SettingsPage(
            mode: _mode,
            onModeChange: (m) => setState(() => _mode = m),
            major: _major,
            onMajorChange: (v) => setState(() => _major = v ?? _major),
            current: _current,
            onCurrentChange: (v) => setState(() => _current = v ?? _current),
            majors: majors,
            userCtl: _userCtl,
            passCtl: _passCtl,
            pasteCtl: _pasteCtl,
            busy: _busy,
            onRun: switch (_mode) {
              DataMode.sample => _fromSample,
              DataMode.paste => _fromPaste,
              DataMode.zju => () => _fromZju(),
            },
            notice: _notice,
            loggedInAs: _loggedInAs,
            lastDataAt: _lastDataAt,
            onClearData: _clearData,
            aiConfig: _aiConfig,
            onAiConfigChange: _setAiConfig,
            onTestAi: _testAi,
            onExportSharePack: ({bool realName = false}) =>
                _exportSharePack(realName: realName),
            onEnterTeacherMode: () {
              setState(() => _teacherMode = true);
              unawaited(_saveSession());
            },
          ),
        ],
        ),
      ),
      // 全局 AI 对话悬浮入口（诉求 #9）。上下文摘要走 auditSubsetOf 脱敏子集
      //（不含姓名/学号/成绩明细），符合"仅发送最小字段"的对外口径。
      floatingActionButton: FloatingActionButton(
        onPressed: () => showAiChat(
          context,
          controller: _aiCtrl,
          config: _aiConfig,
          onGoSettings: () => setState(() => _tabIndex = tabSettings),
          contextSummary: _aiAuditSummary(),
        ),
        tooltip: 'AI 助手',
        child: const BoatIcon(size: 26),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: '学业'),
          NavigationDestination(
              icon: Icon(CurriculumPlanPage.tabIcon),
              selectedIcon: Icon(CurriculumPlanPage.tabIconSelected),
              label: CurriculumPlanPage.tabLabel),
          NavigationDestination(
              icon: Icon(CourseSelectPage.tabIcon),
              selectedIcon: Icon(CourseSelectPage.tabIconSelected),
              label: CourseSelectPage.tabLabel),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '设置'),
        ],
      ),
    );
  }
}
