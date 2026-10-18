/// 课舟 App 主入口：底部导航五页签（学业/方案/选课/工具/设置；审计并入方案页，
/// 2026-10-18 需求 #1：学期走势与 GPA 模拟器自学业页拆出，恢复独立「工具」页签）。
/// 数据流：设置页选源运行 → 状态持有 courses/report/practice/choosed/timetable → 各页消费。
/// 持久化：凭证沙箱存储（启动自动登录）；最近会话缓存（重启即恢复数据）；AI 解读配置（出厂默认关闭，悬浮入口点击时引导开启）。
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
import 'data/ai_knowledge.dart';
import 'data/ai_models.dart';
import 'data/ai_prompts.dart';
import 'data/credential_store.dart';
import 'data/diagnostic_log.dart';
import 'data/plan_models.dart';
import 'data/share_pack.dart';
import 'data/xk_parse.dart'
    show TimetableParseResult, XkListParseResult, parseXkCourseList;
import 'data/zju_client.dart';
import 'data/zju_parse.dart';
import 'data/zju_parse_ext.dart';
import 'engine/adapters.dart';
import 'engine/audit.dart';
import 'engine/course_marks.dart';
import 'engine/exam.dart';
// 课程类别打通（「未分类」修复）：用审计方案板块补全展示链路的 category。
import 'engine/plan_audit_adapter.dart' show applyPlanCategories;
import 'pages/course_select_page.dart';
import 'pages/curriculum_plan_page.dart';
import 'pages/scholar_page.dart';
import 'pages/settings_page.dart';
import 'pages/teacher_review_page.dart';
import 'pages/tools_page.dart';
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
    // 仅 Windows 启用"关闭收起到托盘"：托盘图标只由 windows/runner 实现，
    // 其它桌面平台若也拦截关闭，用户关窗后再也找不回窗口（只能杀进程）。
    if (_supportsTray) {
      _windowCloseToTray = await CredentialStore().loadCloseToTray();
      await windowManager.setPreventClose(_windowCloseToTray);
      windowManager.addListener(_trayCloseListener);
    }
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

/// 退到托盘依赖 Windows runner 里的 Shell_NotifyIcon 实现；
/// macOS / Linux（含鸿蒙桌面）没有托盘入口，一律走"关窗即退出"。
bool get _supportsTray {
  try {
    return Platform.isWindows;
  } catch (_) {
    return false; // 未知平台保守关闭
  }
}

/// 当前生效的"关闭窗口收起到托盘"开关：设置页切换与启动读档都会改写它。
bool _windowCloseToTray = true;

/// 点窗口关闭按钮且开了"收起到托盘"时把窗口藏起来（C++ 侧随即挂出托盘图标）；
/// 关掉开关则什么都不做，窗口正常关闭、进程退出。
class _TrayCloseListener with WindowListener {
  @override
  void onWindowClose() {
    if (_windowCloseToTray && _isDesktopWindowed) {
      unawaited(windowManager.hide());
    }
  }
}

final _trayCloseListener = _TrayCloseListener();

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
                  Text('请重新拉取一次数据；若仍出现，请把操作步骤反馈给我们。\n'
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
  // 顺序：0 学业 / 1 方案 / 2 选课 / 3 工具 / 4 设置
  // （审计并入方案页；2026-10-18 需求 #1：走势+模拟器独立成「工具」页签）。
  static const int tabScholar = 0;
  static const int tabPlan = 1;
  static const int tabSelect = 2;
  static const int tabTools = 3;
  static const int tabSettings = 4;

  final _store = CredentialStore();
  late final ZjuClient _client = ZjuClient(_store);
  // 全局 AI 对话（诉求 #9）：悬浮入口唤起抽屉；history 跨页签常驻。
  final _aiCtrl = AiChatController();
  AuditEngine? _engine;
  late final Future<void> _assetsReady; // 启动资产加载完成信号（运行审计前等待）
  int _tabIndex = tabScholar;
  // 2026-10-18 需求 #9：底栏元素排序 + 启动默认首页。规范索引固定
  // 0=学业 1=方案 2=选课 3=工具 4=设置；_tabOrder 存"显示第 k 位放哪个规范索引"。
  String _tabOrder = '0,1,2,3,4';
  int _defaultTab = tabScholar;
  bool _userNavigated = false; // 用户点过底栏后，启动默认页不再抢占当前页
  int _teacherTab = 0; // 选课指导模式内页签：0=指导 1=设置（需求 #13：可进设置）
  // 需求 #5：外语类等级（学生自选折算口径）。null=未选择（引擎按方案原要求算，
  // trace 注明）；'L1'/'L2'/'L3' → 要求学分封顶 6/4.5/3。持久化在 ui.cfg。
  String? _foreignLevel;
  Map<String, dynamic>? _lastRecord; // 最近一次审计的完整 record（改等级后重算用）

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
  MatchedPlanInfo? _matchedPlan; // 本次数据匹配命中的本人培养方案（设置页展示）
  Map<String, dynamic>? _selectionSummary; // 选课页上抛的脱敏候选摘要（全局 AI 用）
  AiConfig _aiConfig = const AiConfig(); // AI 解读配置（出厂默认关闭；悬浮入口点击时弹窗引导开启，见 _openAiChat）
  bool _closeToTray = true; // 桌面端：关闭窗口是否收起到托盘（设置页开关镜像）
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
    // 内置选课知识库（需求 #6）：加载失败只降级为无知识库，不阻断引擎就绪。
    try {
      final kbJson =
          await rootBundle.loadString('assets/knowledge/zju_course_selection_2026.json');
      _aiCtrl.knowledgeBase =
          InMemoryAiKnowledgeBase.fromJson(json.decode(kbJson));
    } catch (e) {
      DiagnosticLog.instance.record('知识库加载', level: 'error', detail: '$e');
    }
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
    // AI 解读配置（2026-10-18 需求）：出厂默认「关闭」——首次安装不再预启用任何
    // 端点；悬浮 AI 入口首次点击时会弹窗引导开启公益免费模型（见 _openAiChat）。
    // 用户显式保存过（含选「关闭」或自填 Key 的自有服务）后一切按存档走；
    // 缺失/损坏回落 none 同样视为关闭，绝不猜提供方。
    final aiCfg = await _store.loadAiConfig();
    if (mounted) setState(() => _aiConfig = aiCfg);
    // 底栏排序与启动默认首页（2026-10-18 需求 #9）：损坏/缺省回落 '0,1,2,3,4'/学业；
    // 旧版「4 页签」存档（0..3 全排列）由 CredentialStore.loadTabOrder 自动迁移。
    final tabOrder = await _store.loadTabOrder();
    final defaultTab = await _store.loadDefaultTab();
    // 外语等级（需求 #5）：缺省 null（未选择，按方案原要求核算）。
    final foreignLevel = await _store.loadForeignLevel();
    if (mounted) {
      setState(() {
        _tabOrder = tabOrder;
        _defaultTab = defaultTab;
        _foreignLevel = foreignLevel;
        // 仅在用户还没手动切页时应用启动默认页，避免异步加载覆盖正在浏览的页。
        if (!_userNavigated) _tabIndex = defaultTab;
      });
    }
    // 桌面端："关闭收起到托盘"偏好（默认开）——main() 已按存档设置关闭拦截，
    // 这里把同一值同步到设置页开关，避免两处状态不一致。
    final closeToTray = await _store.loadCloseToTray();
    _windowCloseToTray = closeToTray;
    if (mounted) setState(() => _closeToTray = closeToTray);
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
          _planQuality = s['plan_quality'] as String?;
          _recordSourceLabel =
              (s['source_label'] as String?) ?? '上次会话数据';
          _lastDataAt = (s['saved_at'] as String?) != null
              ? DateTime.tryParse(s['saved_at'] as String)
              : null;
          // 已选课程与审计方案随会话恢复：重启后方案页/选课页/设置页
          // 仍能显示“本学期已选”和培养方案对应关系，不必等重新联网。
          final ch = s['choosed'];
          if (ch is Map) {
            final state = '${ch['state'] ?? ''}';
            final rows = (ch['rows'] as List? ?? const []);
            final issues = <String>[
              for (final e in (ch['issues'] as List? ?? const [])) '$e'
            ];
            if (state == 'empty') {
              _choosed = const XkListParseResult(
                  courses: [], state: 'empty', fromCache: true);
            } else if (state == 'unavailable') {
              _choosed = XkListParseResult(
                  courses: const [],
                  state: 'unavailable',
                  issues: issues.isEmpty ? const ['已选课程暂不可用'] : issues,
                  fromCache: true);
            } else if (rows.isNotEmpty) {
              try {
                final parsed =
                    parseXkCourseList(json.encode(rows), xkkzId: 'choosed');
                _choosed = XkListParseResult(
                  courses: parsed.courses,
                  state: parsed.state,
                  issues: issues.isEmpty ? parsed.issues : issues,
                  dropped: parsed.dropped,
                  blocked: parsed.blocked,
                  fromCache: true,
                );
              } catch (_) {}
            }
          }
          final ap = s['audit_plan'];
          if (ap is Map) _auditPlan = ap.cast<String, dynamic>();
        });
      } catch (_) {/* 缓存损坏则忽略 */}
    }
    // 恢复上次匹配/选定的本人培养方案（带账号校验，换号不串台）。
    if (_loggedInAs != null) {
      final selRaw = await _store.readCache('plan_selection');
      if (selRaw != null) {
        try {
          final m = json.decode(selRaw) as Map<String, dynamic>;
          final owner = (m['student_id'] ?? '').toString().trim();
          final me = _loggedInAs ?? '';
          if (owner.isEmpty || me.isEmpty || owner == me) {
            final info = MatchedPlanInfo.fromJson(m);
            if (info.zymc.isNotEmpty && mounted) {
              setState(() => _matchedPlan = info);
            }
          }
        } catch (_) {}
      }
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
      'audit_plan': _auditPlan,
      'choosed': _choosed == null
          ? null
          : {
              'state': _choosed!.state,
              'issues': _choosed!.issues,
              'rows': [for (final c in _choosed!.courses) c.raw],
            },
      'saved_at': DateTime.now().toIso8601String(),
    }));
  }

  /// 「分享给指导教师」导出（导师模式 P1 + 需求 #12）：当前审计数据 → 脱敏分享包。
  /// 剪贴板 + 沙箱 share/ 双通道；实名选项默认关（alias 保持匿名）。
  /// [aiAdvice] 为选课页「导出给指导教师」传来的 AI 咨询问答（自愿附带）。
  /// 返回提示文本（行数/路径），失败返回原因——设置页直接展示。
  Future<String> _exportSharePack(
      {bool realName = false, List<Map<String, String>>? aiAdvice}) async {
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
      aiAdvice: aiAdvice,
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
    final out = engine.main(record, action: _auditAction());
    if (out.containsKey('error')) {
      setState(() => _notice = out['error'].toString());
      return;
    }
    // 记录本次审计所用方案（runtime 优先；未知专业静默跳过——选课页对此按"无方案"降级）
    Map<String, dynamic>? auditPlan;
    try {
      auditPlan = engine.findPlan(record['student']['major'] as String);
    } catch (_) {}
    // 类别打通（「未分类」修复）：报告已在 engine.main 里算完，此处
    // 改写 record 课程行只影响展示链路与 _saveSession 落盘（含分享包）。
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
      _lastRecord = record;
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
      _matchedPlan = null; // 样例模式不冒充教务匹配方案
      _choosed = null; // 样例无已选/课表数据，切源即清（方案页对应区块不展示）
      _timetable = null;
    });
    await _runAudit(rec);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _fromPaste() async {
    setState(() {
      _busy = true;
      _planQuality = null;
      _matchedPlan = null; // 粘贴模式不冒充教务匹配方案
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
        final previous = _loggedInAs;
        await _client.login(username, password);
        setState(() {
          if (previous != null && previous != username) {
            // 换号：上一账号的方案/已选/课表一律不得残留。
            _matchedPlan = null;
            _choosed = null;
            _timetable = null;
          }
          _loggedInAs = username;
        });
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
          final choosed = await _client.fetchXkChoosedCourses(
              xn: xnXq.$1, xq: xnXq.$2,
              refresh: !auto); // 手动刷新必须拿新快照，不能吃旧缓存
          if (mounted) setState(() => _choosed = choosed);
        }
      } catch (e) {
        // 失败不能保留上一学期的旧已选（会显示成当前学期）。
        if (mounted) {
          setState(() => _choosed = XkListParseResult(
              courses: const [],
              state: 'unavailable',
              issues: ['已选课程获取失败：$e']));
        }
      }

      // 专业识别 → 培养方案（方案列表接口 + 客户端匹配；歧义留给「方案」页点选）
      var auditMajor = _major;
      var quality = '';
      MatchedPlanInfo? matchedNew;
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
          final summary = resolved.summary;
          if (summary != null) {
            matchedNew = MatchedPlanInfo.fromSummary(
              summary,
              level: resolved.matchLevel,
              ambiguous: resolved.ambiguous,
              candidateCount: resolved.candidateCount,
            );
          }
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
      setState(() {
        _planQuality = quality.isEmpty ? null : quality;
        _matchedPlan = matchedNew; // 匹配失败即清空，避免残留上一账号/上一次方案
      });

      // 学期/年级自动推断（学期选择器值保持合法：仅接受标准格式）
      final sem = currentSemesterFrom(courses);
      final grade = inferGradeFromStudentId(_userCtl.text.trim());
      final student = <String, dynamic>{
        'alias': '本人',
        'major': auditMajor,
        'grade': grade ?? _current.substring(0, 4),
        'current_semester': _current,
      };
      // 注意：不要把 _current 覆盖成成绩单最晚学期——否则下一次刷新已选课程
      // 会去查错学期（历史 bug）。sem 只用于本次审计的 student 记录。
      if (sem != null) {
        student['current_semester'] = sem;
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

  /// 全局 AI 入口统一开闸（2026-10-18 需求）：AI 未启用时先弹窗询问「是否开启
  /// AI 解读？」，同意则写入公益免费端点并存档后再唤起对话；已启用（含用户在
  /// 设置里自填 Key 的自有服务）一律按当前存档直开抽屉，不弹任何窗——
  /// 「我目前选的是什么就是什么」。取消开启时不写入配置，仍打开抽屉：里面是
  /// 「去设置」引导空态，用户可自行配置后进入。
  ///
  /// 发送范围提示复用 ai_prompts 的全局口径常量 [kAiChatSendNotice]，不另写文案
  /// （刻意不用选课页一次性解读的 kAiSendNotice：那份口径写着「不发送成绩」，
  /// 而全局助手按仓库约定会读取已修课程成绩，用它反而是合规误述）。
  ///
  /// 刻意不收 BuildContext 参数：两个调用点（悬浮帆/导师审阅）都在本 State 的
  /// build 闭包里，直接用 State.context + mounted 守卫，避免跨 async gap 用
  /// 外来 context 触发 use_build_context_synchronously。
  Future<void> _openAiChat({
    String? contextSummary,
    String? Function()? contextProvider,
    VoidCallback? onGoSettings,
  }) async {
    if (!_aiConfig.enabled) {
      final enable = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('是否开启 AI 解读？'),
          content: const Text(kAiChatSendNotice),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('开启（公益免费模型）')),
          ],
        ),
      );
      if (enable == true && mounted) {
        await _setAiConfig(AiConfig.preset(AiProvider.pollinations));
      }
      if (!mounted) return;
    }
    unawaited(showAiChat(
      context,
      controller: _aiCtrl,
      config: _aiConfig,
      onGoSettings:
          onGoSettings ?? () => setState(() => _tabIndex = tabSettings),
      contextSummary: contextSummary,
      contextProvider: contextProvider,
    ));
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

  /// 给全局 AI 对话的上下文摘要：学业（成绩概览+课程）+ 培养方案 + 审计报告 +
  /// 选课（候选/课表/已选）。不含学号、姓名、凭证；摘要只进 system，不展示给用户。
  String? _aiContextSummary() {
    try {
      final summary = buildAiContextJson(
        transcript: _courses,
        practice: _practice,
        exams: _exams,
        report: _report,
        plan: _auditPlan,
        matchedPlan: _matchedPlan,
        timetable: _timetable,
        choosed: _choosed,
        selection: _selectionSummary,
      );
      return summary.trim().isEmpty ? null : summary;
    } catch (_) {
      // 摘要构造失败不应阻断 AI 对话：按无上下文继续（模型会提示数据不足）。
      return null;
    }
  }

  /// 拉取模型列表（设置页「拉取模型」按钮）。异常兜底成可读文案。
  Future<AiModelsResult> _listAiModels(AiConfig cfg) async {
    try {
      return await AiClient(cfg).listModels();
    } catch (_) {
      return AiModelsResult.failure('请求异常（请检查接口地址格式后重试）');
    }
  }

  Future<void> _clearData() async {
    await _store.deleteCredentials();
    await _store.deleteUiPrefs(); // 窗口偏好也属本地数据；下面恢复出厂默认（收起到托盘）
    await _store.deleteAiConfig(); // AI 密钥属"全部本地数据"，必须一并删除（合规承诺）
    await _store.deleteNavPrefs(); // 底栏排序/默认首页同属本地偏好（需求 #9）
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
      _matchedPlan = null;
      _selectionSummary = null;
      _choosed = null;
      _timetable = null;
      _aiConfig = const AiConfig();
      _closeToTray = true;
      _aiSessionReset++; // 让选课页清掉 AI 问答历史（含上一账号的课程名/解读文本）
    });
  }

  /// 切换"关闭窗口收起到托盘"：写盘 → 同步 C++ 关闭拦截 → 刷新开关。
  Future<void> _setCloseToTray(bool value) async {
    _windowCloseToTray = value;
    await _store.saveCloseToTray(value);
    if (_supportsTray) {
      try {
        await windowManager.setPreventClose(value);
      } catch (_) {/* 插件缺失时保持默认关窗行为 */}
    }
    if (mounted) setState(() => _closeToTray = value);
  }

  /// 彻底退出：解除关闭拦截后销毁窗口（托盘菜单"退出课舟"走同一条路径）。
  Future<void> _quitApp() async {
    if (!_isDesktopWindowed) return;
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {/* 插件缺失（非桌面）时无事可做 */}
  }

  /// 设置页（学生态 / 选课指导模式共用；需求 #13：指导模式也能进设置）。
  /// 底栏排序与启动默认首页的状态在此接线（需求 #9）。
  Widget _settingsPage() {
    return SettingsPage(
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
      onListAiModels: _listAiModels,
      courses: _courses,
      choosed: _choosed,
      matchedPlan: _matchedPlan,
      planNote: _planQuality,
      onGoPlan: () => setState(() => _tabIndex = tabPlan),
      closeToTray: _closeToTray,
      onCloseToTrayChange: _supportsTray ? _setCloseToTray : null,
      onQuit: _isDesktopWindowed ? _quitApp : null,
      onExportSharePack: ({bool realName = false}) =>
          _exportSharePack(realName: realName),
      onEnterTeacherMode: () {
        setState(() {
          _teacherMode = true;
          _teacherTab = 0;
        });
        unawaited(_saveSession());
      },
      tabOrder: _tabOrder,
      onTabOrderChange: (o) {
        setState(() => _tabOrder = o);
        unawaited(_store.saveTabOrder(o));
      },
      defaultTab: _defaultTab,
      onDefaultTabChange: (i) {
        setState(() {
          _defaultTab = i;
          // 用户在本会话已手动切过页则不抢当前页；未切过则立即生效所见即所得。
          if (!_userNavigated) _tabIndex = i;
        });
        unawaited(_store.saveDefaultTab(i));
        // 同步落一份当前页签序（新格式：五个 0..4 索引）：nav.cfg 里 tabOrder 的
        // 形状兼作版本标记——loadDefaultTab 靠它区分存档 defaultTab==3 是
        // 旧版「设置」（迁移为新索引 4）还是新版「工具」（原样保留）。
        unawaited(_store.saveTabOrder(_tabOrder));
      },
      teacherMode: _teacherMode,
      foreignLevel: _foreignLevel,
      onForeignLevelChange: (v) {
        setState(() => _foreignLevel = v);
        unawaited(_store.saveForeignLevel(v));
        unawaited(_recomputeAudit());
      },
    );
  }

  /// 审计动作参数（需求 #5）：仅在学生选定了外语等级时传入；null → 引擎按方案原要求。
  /// 审计动作参数（需求 #5 改版）：_foreignLevel 可能是档位串 L1/L2/L3（向后
  /// 兼容，映射 caps 作默认）或用户自选的正分数串（如 '5.5'，走 foreign_lang_credits）；
  /// 两者都缺 → null，引擎按方案原要求核算。
  Map<String, dynamic>? _auditAction() {
    final v = _foreignLevel;
    if (v == null) return null;
    final n = double.tryParse(v);
    if (n != null && n > 0) return {'foreign_lang_credits': n};
    return {'foreign_lang_level': v};
  }

  /// 外语等级变更后用同一份记录重算审计（无记录则跳过——首次审计自然带新值）。
  Future<void> _recomputeAudit() async {
    final rec = _lastRecord;
    if (rec == null) return;
    await _runAudit(rec);
  }

  @override
  Widget build(BuildContext context) {
    // 显示位 ↔ 规范索引映射（需求 #9）：_tabOrder[k] = 规范索引；
    // IndexedStack 永远按规范索引排，NavigationBar 按显示位排，点击时反查。
    final order = _tabOrder.split(',').map(int.parse).toList();
    final displayIndex = order.indexOf(_tabIndex);

    // 选课指导模式（原导师审阅，需求 #3/#13）：不再是"整页弹窗"式孤岛——
    // 独立底栏（指导/设置/返回学生），审阅台可用 AI 入口（点击未启用时
    // 同样走 _openAiChat 开闸弹窗）。学生数据与审阅包数据依旧完全隔离。
    if (_teacherMode) {
      return Scaffold(
        body: SafeArea(
          top: true,
          bottom: false,
          child: IndexedStack(
            index: _teacherTab,
            children: [
              TeacherReviewPage(
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
                // #13：AI 常开可达——未启用时 _openAiChat 弹窗引导，不再隐藏入口。
                onAskAi: (report) {
                  final sub = auditSubsetOf(report);
                  unawaited(_openAiChat(
                    contextSummary: sub == null
                        ? null
                        : const JsonEncoder.withIndent('  ').convert(sub),
                    onGoSettings: () => setState(() => _teacherTab = 1),
                  ));
                },
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
              _settingsPage(),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _teacherTab,
          onDestinationSelected: (i) {
            if (i == 2) {
              setState(() {
                _teacherMode = false;
                _teacherTab = 0;
              });
              unawaited(_saveSession());
              return;
            }
            setState(() => _teacherTab = i);
          },
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.groups_outlined),
                selectedIcon: Icon(Icons.groups),
                label: '指导'),
            NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: '设置'),
            NavigationDestination(
                icon: Icon(Icons.exit_to_app_outlined),
                selectedIcon: Icon(Icons.exit_to_app),
                label: '返回学生'),
          ],
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
            choosed: _choosed,
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
            plan: _auditPlan,
            onPlanSelected: (info) =>
                setState(() => _matchedPlan = info),
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
            choosed: _choosed,
            timetable: _timetable,
            aiConfig: _aiConfig,
            resetToken: _aiSessionReset,
            onGoSettings: () => setState(() => _tabIndex = tabSettings),
            onAiContext: (s) => _selectionSummary = s,
            // 需求 #12：选课页「导出给指导教师」→ 当前审计 + AI 问答合并成分享包。
            onExportAdvice: (advice) async {
              final messenger = ScaffoldMessenger.of(context); // await 前先捕获
              final msg = await _exportSharePack(aiAdvice: advice);
              if (mounted) {
                setState(() => _notice = msg);
                messenger.showSnackBar(
                    SnackBar(content: Text(msg), duration: const Duration(seconds: 4)));
              }
            },
          ),
          ToolsPage(
            courses: _coursesViewed,
            marks: _marks,
            onGoSettings: () => setState(() => _tabIndex = tabSettings),
            onRefresh: () async => switch (_mode) {
              DataMode.sample => _fromSample(),
              DataMode.paste => _fromPaste(),
              DataMode.zju => _fromZju(),
            },
          ),
          _settingsPage(),
        ],
        ),
      ),
      // 全局 AI 对话悬浮入口（诉求 #9）。上下文摘要由 buildAiContextJson 汇总
      // 学业/方案/审计/选课的脱敏子集（不含姓名/学号/凭证），只进 system 消息。
      // 未启用时入口先弹「是否开启 AI 解读」弹窗（_openAiChat 统一开闸）。
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openAiChat(
          // 每一轮发送前重新生成，聊天过程中数据更新后 AI 也能读到最新值。
          contextProvider: _aiContextSummary,
        ),
        tooltip: 'AI 助手',
        child: const BoatIcon(size: 26),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: displayIndex < 0 ? 0 : displayIndex,
        onDestinationSelected: (i) => setState(() {
          _tabIndex = order[i];
          _userNavigated = true;
        }),
        // 需求 #9：底栏元素顺序按 _tabOrder 重排（内容/图标仍属规范索引）。
        destinations: [
          for (final canon in order)
            switch (canon) {
              1 => NavigationDestination(
                  icon: const Icon(CurriculumPlanPage.tabIcon),
                  selectedIcon: const Icon(CurriculumPlanPage.tabIconSelected),
                  label: CurriculumPlanPage.tabLabel),
              2 => NavigationDestination(
                  icon: const Icon(CourseSelectPage.tabIcon),
                  selectedIcon: const Icon(CourseSelectPage.tabIconSelected),
                  label: CourseSelectPage.tabLabel),
              3 => NavigationDestination(
                  icon: const Icon(Icons.build_outlined),
                  selectedIcon: const Icon(Icons.build),
                  label: '工具'),
              4 => NavigationDestination(
                  icon: const Icon(Icons.settings_outlined),
                  selectedIcon: const Icon(Icons.settings),
                  label: '设置'),
              _ => NavigationDestination(
                  icon: const Icon(Icons.dashboard_outlined),
                  selectedIcon: const Icon(Icons.dashboard),
                  label: '学业'),
            },
        ],
      ),
    );
  }
}
