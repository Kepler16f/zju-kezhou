/// 课舟 App 主入口：底部导航四页（学业/审计/工具/设置）。
/// 数据流：设置页选源运行 → 状态持有 courses/report/practice → 各页消费。
/// 持久化：凭证沙箱存储（启动自动登录）；最近会话缓存（重启即恢复数据）。
/// 崩溃兜底：ErrorWidget → 友好错误卡（不再出现灰屏）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'data/credential_store.dart';
import 'data/diagnostic_log.dart';
import 'data/zju_client.dart';
import 'data/zju_parse.dart';
import 'data/zju_parse_ext.dart';
import 'engine/adapters.dart';
import 'engine/audit.dart';
import 'engine/course_marks.dart';
import 'engine/exam.dart';
import 'pages/audit_page.dart';
import 'pages/curriculum_plan_page.dart';
import 'pages/scholar_page.dart';
import 'pages/settings_page.dart';
import 'widgets/gpa_tools_view.dart';

void main(List<String> args) async {
  // 崩溃自动恢复标记（RegisterApplicationRestart 重启时带 --crashed）
  _crashRecovered = args.contains('--crashed');
  WidgetsFlutterBinding.ensureInitialized();
  // 仅桌面（Windows/macOS/Linux）启用 window_manager：它是 Windows resize 崩溃的
  // 规避手段（PiliPlus 同款）。移动端（iOS/Android/ohos）无此插件实现，调用即崩。
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
  final _store = CredentialStore();
  late final ZjuClient _client = ZjuClient(_store);
  AuditEngine? _engine;
  late final Future<void> _assetsReady; // 启动资产加载完成信号（运行审计前等待）
  int _tabIndex = 0;

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
  bool _busy = false;
  String? _notice;

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
      'saved_at': DateTime.now().toIso8601String(),
    }));
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
    setState(() {
      _report = out['report'] as Map<String, dynamic>;
      _courses = (record['courses'] as List).cast<Map<String, dynamic>>();
      _notice = null;
      _lastDataAt = DateTime.now();
      _tabIndex = 2; // 审计完成后自动切到审计页
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
    });
    await _runAudit(rec);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _fromPaste() async {
    setState(() => _busy = true);
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

      // 专业识别 → 培养方案（方案列表接口 + 客户端匹配；歧义留给「方案」页点选）
      var auditMajor = _major;
      var quality = '';
      if (majorName != null) {
        final builtinKey = matchPlanKey(majorName, majors.keys.toList());
        try {
          final profile = await _client.fetchStudentProfile();
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
    } on AuthException catch (e) {
      if (!auto) setState(() => _notice = e.message);
    } catch (e) {
      if (!auto) {
        setState(() => _notice = '教务网访问异常：$e（校园网外无法直连 zju.edu.cn）');
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _clearData() async {
    await _store.deleteCredentials();
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
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tabIndex,
        children: [
          ScholarPage(
            courses: _coursesViewed,
            practice: _practice,
            exams: _exams,
            marks: _marks,
            onMark: _setMark,
            sourceLabel: _recordSourceLabel,
            onGoSettings: () => setState(() => _tabIndex = 4),
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
            onGoSettings: () => setState(() => _tabIndex = 4),
          ),
          AuditPage(report: _report, planQuality: _planQuality),
          GpaToolsView(courses: _coursesViewed),
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
          ),
        ],
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
              icon: Icon(Icons.fact_check_outlined),
              selectedIcon: Icon(Icons.fact_check),
              label: '审计'),
          NavigationDestination(
              icon: Icon(Icons.trending_up_outlined),
              selectedIcon: Icon(Icons.trending_up),
              label: '工具'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '设置'),
        ],
      ),
    );
  }
}
