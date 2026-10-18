/// pages/course_select_page.dart — 选课页：轮次入口 / 跨轮次汇总 / 与方案和课表匹配 / AI 解读。
///
/// 红线与策略（设计评审结论，改动前先读）：
///  - 只读：仅调用选课查询接口；提交/退课等写操作绝不调用（docs/选课模块接入说明.md）；
///  - 拉取策略（评审A8；2026-10-18 需求 #5 改口径）：进入本页且已登录才拉取入口；
///    入口列表加载成功后**自动**对全部入口串行拉取（复用聚合逻辑：间隔 ≥1.1s、
///    可取消、软封禁即停），页面默认呈现合并视图；「汇总全部入口」按钮保留为
///    手动重新聚合入口；单轮点选即拉；仍禁止启动期扇出（IndexedStack 保活下以
///    active 门控，自动聚合随页面激活触发而非 App 启动触发）；
///  - 三态文案（评审A6）：「已开放有数据 / 已开放但无结果 / 未开放或状态未知」三种如实显示；
///  - AI 解读（评审C）：出厂默认公益免费端点（无存档时），可切自有服务/关闭；首次发送前确认发送范围；越界提问直接回退固定文案；
///    输出页脚（kAiFooter）与免责声明（kDisclaimer）由本页硬拼接，模型无权删改。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/ai_client.dart';
import '../data/ai_config.dart';
import '../data/ai_prompts.dart';
import '../data/credential_store.dart';
import '../data/semester.dart';
import '../data/xk_models.dart';
import '../data/xk_parse.dart';
import '../data/zju_client.dart';
import '../engine/disclaimer.dart';
import '../engine/selection.dart';
import '../engine/timeline.dart';

enum _View { rounds, merged, advice }

class CourseSelectPage extends StatefulWidget {
  final ZjuClient client;
  final CredentialStore store;
  final bool loggedIn;
  final bool active; // 当前是否为选中页签（IndexedStack 保活，禁止启动期联网）
  final String currentSemester;
  final List<Map<String, dynamic>> transcript;
  final Map<String, dynamic>? plan; // 当前审计所用方案（runtime 或内置 golden）
  final Map<String, dynamic>? report; // 最近一次审计报告（AI 解读的缺口数字来源）
  final XkListParseResult? choosed; // 本学期已选（在修，未出成绩）
  final TimetableParseResult? timetable; // 本学期课表（主状态缓存）
  final AiConfig aiConfig;
  final int resetToken; // 父级"一键清除"自增令牌：变化即清空本页 AI 会话态
  final VoidCallback onGoSettings;

  /// 把本页已合并的选课候选发布给全局 AI 助手（脱敏摘要，不含个人信息）。
  /// 全局助手由 main.dart 的悬浮按钮呼出，拿不到本页局部状态，故用回调上抛。
  final ValueChanged<Map<String, dynamic>?>? onAiContext;

  /// 需求 #12：学生把本页 AI 选课咨询问答一键导出给指导教师审阅
  /// （main.dart 实现：并入脱敏分享包并复制到剪贴板 + 落沙箱 share/）。
  final void Function(List<Map<String, String>> advice)? onExportAdvice;

  const CourseSelectPage({
    super.key,
    required this.client,
    required this.store,
    required this.loggedIn,
    required this.active,
    required this.currentSemester,
    required this.transcript,
    required this.plan,
    required this.report,
    this.choosed,
    this.timetable,
    required this.aiConfig,
    required this.resetToken,
    required this.onGoSettings,
    this.onAiContext,
    this.onExportAdvice,
  });

  static const String tabLabel = '选课';
  static const IconData tabIcon = Icons.how_to_vote_outlined;
  static const IconData tabIconSelected = Icons.how_to_vote;

  @override
  State<CourseSelectPage> createState() => _CourseSelectPageState();
}

class _CourseSelectPageState extends State<CourseSelectPage> {
  XkIndexParseResult? _index;

  /// 入口复合键：xkkzId + lx。浙大页同一 dl 可挂多个 lx 子入口（认定型，#10），
  /// 通用页也存在同 xkkz_id 跨类别复用——只按 xkkzId 键控会让这些入口的列表
  /// 互相覆盖/互斥加载，必须用全身份做键。
  String _rk(XkRound r) => '${r.xkkzId}\u0000${r.kklxdm}';

  final Map<String, XkListParseResult> _lists = {}; // 入口复合键 -> 列表结果
  String? _selectedRoundId; // 存入口复合键（_rk），不再裸 xkkzId
  TimetableParseResult? _timetable;
  bool _demoLoaded = false; // 演示数据已加载：真实刷新成功时必须清掉演示残留，防混显

  bool _loadingIndex = false;
  final Set<String> _loadingRounds = {}; // 按入口复合键维护（快速切 chip 不再互相丢弃请求）
  bool _loadingTimetable = false;
  String? _timetableError; // 课表失败原因：失败不写 _timetable（保留可重试），错误单独记账
  bool _aggregating = false;
  bool _cancelAggregate = false;
  int _aggregateDone = 0;
  String? _error;
  final Map<String, String> _roundErrors = {}; // 入口复合键 -> 失败原因（不写 _lists，可重试）
  int _listGeneration = 0; // 入口刷新/登出换代：旧世代在飞结果一律作废（防陈旧写回）
  int _listsVersion = 0; // _lists 每次变更自增（合并结果按版本缓存，避免每帧重算）
  bool _softBlocked = false; // 本轮遇到软封禁（风控/HTML 登录页）：停止继续轰炸，提示稍后重试
  List<XkMergedCourse>? _mergedCache;
  List<String>? _mergedNotesCache;
  int _mergedCacheVersion = -1;

  _View _view = _View.rounds;
  final _searchCtl = TextEditingController();

  // AI 解读面板状态
  final _aiCtl = TextEditingController();
  final List<(String q, String a)> _aiHistory = [];
  bool _aiBusy = false;
  String? _aiError;
  bool _sendNoticeAck = false;
  String? _aiStreaming; // 流式回复的已收到片段
  String? _aiPendingQuestion; // 在途提问（用于渲染流式气泡）

  @override
  void initState() {
    super.initState();
    if (widget.active) _onActivated();
  }

  @override
  void didUpdateWidget(covariant CourseSelectPage old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _onActivated();
    // 父级一键清除：清掉 AI 问答历史/发送确认（上一账号的课程名与解读文本不得残留）
    if (widget.resetToken != old.resetToken) {
      _aiHistory.clear();
      _aiCtl.clear();
      _aiError = null;
      _sendNoticeAck = false;
      _aiStreaming = null;
      _aiPendingQuestion = null;
    }
    if (!widget.loggedIn && old.loggedIn) {
      // 登出：清空教务相关状态 + AI 会话态（AI 配置本身不动）
      setState(() {
        _index = null;
        _lists.clear();
        _roundErrors.clear();
        _timetable = null;
        _timetableError = null;
        _selectedRoundId = null;
        _error = null;
        _demoLoaded = false;
        _aiHistory.clear();
        _aiCtl.clear();
        _aiError = null;
        _sendNoticeAck = false;
        _aiStreaming = null;
        _aiPendingQuestion = null;
      });
      widget.onAiContext?.call(null); // 全局助手不得继续持有上一账号的选课数据
    }
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    _aiCtl.dispose();
    super.dispose();
  }

  /// 首次进入本页：只做一次入口拉取（不做跨轮扇出）。
  void _onActivated() {
    if (_loadingIndex || !widget.loggedIn) return;
    if (_demoLoaded) {
      // 演示数据 → 已登录：主动用真实数据替换演示（否则演示一直顶着真实登录态）。
      // 用"事实"（登录 + 演示在场）判定，不依赖"登录发生在哪一帧"的竞态（评审L1）。
      _loadIndex(refresh: true);
      return;
    }
    if (_index != null) return;
    _loadIndex();
  }

  /// 加载离线演示数据（合成样例，即录屏场景 6 的固化输入）。
  /// 演示模式下不触碰网络；「刷新入口」等按钮在未登录时被守卫拦截。
  Future<void> _loadDemoData() async {
    try {
      final raw =
          await rootBundle.loadString('assets/samples/xk_demo_candidates.json');
      final obj = json.decode(raw) as Map<String, dynamic>;
      final rounds = <XkRound>[];
      final lists = <String, XkListParseResult>{};
      for (final r in (obj['rounds'] as List? ?? const [])) {
        if (r is! Map) continue;
        final id = '${r['xkkz_id']}';
        if (id.isEmpty) continue;
        final label = '${r['label'] ?? id}';
        final round = XkRound(xkkzId: id, label: label);
        rounds.add(round);
        // 与真实链路同键（_rk）：演示列表也按入口复合键存取，选中态才能对上
        lists[_rk(round)] = parseXkCourseList(
            json.encode({'tmpList': r['rows'] ?? const []}),
            xkkzId: id,
            label: label);
      }
      final tt = obj['timetable'];
      if (!mounted) return;
      setState(() {
        _index = XkIndexParseResult(
          rounds: rounds,
          xkxnm: '${obj['xkxnm'] ?? ''}',
          xkxqm: '${obj['xkxqm'] ?? ''}',
          issues: const ['演示数据（合成样例，非教务实时数据）'],
          queryCourseHits: rounds.length,
        );
        _lists
          ..clear()
          ..addAll(lists);
        _listsVersion++;
        _roundErrors.clear();
        _selectedRoundId = rounds.isNotEmpty ? _rk(rounds.first) : null;
        _error = null;
        _demoLoaded = true;
        // 需求 #5：演示数据同样默认全量（全部入口列表已就位）→ 默认呈现合并视图
        _view = _View.merged;
        if (tt is Map) {
          _timetable = TimetableParseResult(
            slots: (tt['slots'] as List? ?? const [])
                .whereType<Map>()
                .map((m) => m.cast<String, dynamic>())
                .toList(),
            courses: ((tt['courses'] as List? ?? const [])).map((e) => '$e').toList(),
          );
        }
      });
      _publishAiContext();
    } catch (e) {
      if (mounted) setState(() => _error = '演示数据加载失败：$e');
    }
  }

  Future<void> _loadIndex({bool refresh = false}) async {
    if (!widget.loggedIn) return; // 演示数据模式：未登录不触碰教务接口
    if (_loadingIndex) return;
    setState(() {
      _loadingIndex = true;
      _error = null;
    });
    try {
      final r = await widget.client.fetchXkIndex(refresh: refresh);
      if (!mounted || !widget.loggedIn) return; // 登出/清除与在飞请求的竞态守卫
      // 演示数据在场而真实入口不可用（缓存降级/空结果）：保留演示，绝不销毁且不可回退
      if (_demoLoaded && (r.fromCache || r.rounds.isEmpty)) {
        setState(() {
          _loadingIndex = false;
          _error = '教务入口刷新失败（${r.issues.isNotEmpty ? r.issues.first : '无数据'}）：'
              '仍显示演示数据，可稍后重试';
        });
        return;
      }
      _listGeneration++; // 换代：旧世代在飞的单轮请求此后写回一律作废
      setState(() {
        _index = r;
        _loadingIndex = false;
        if (_demoLoaded) {
          // 真实数据接管：清掉演示残留（列表/选中/课表），防止演示与真实混显
          _lists.clear();
          _listsVersion++;
          _roundErrors.clear();
          _selectedRoundId = null;
          _timetable = null;
          _timetableError = null;
          _demoLoaded = false;
        }
        // 显式刷新：丢掉空结果/缓存结果，强制重新请求（否则旧 empty 会一直粘住）。
        if (refresh) {
          _lists.removeWhere(
              (_, value) => value.state == 'empty' || value.fromCache);
          _roundErrors.clear();
          _listsVersion++;
        }
        // 换批次/换学期后，修剪已不在新入口列表中的旧列表缓存（失败记账一并清理）
        final validIds = r.rounds.map(_rk).toSet();
        final removed = _lists.keys.where((k) => !validIds.contains(k)).toList();
        for (final k in removed) {
          _lists.remove(k);
        }
        if (removed.isNotEmpty) _listsVersion++;
        _roundErrors.removeWhere((k, _) => !validIds.contains(k));
        if (r.rounds.isNotEmpty) {
          final first = r.rounds.first;
          _selectedRoundId ??= _rk(first);
        }
      });
      // 默认拉一次首入口的列表（单次请求）；课表时隙后台拉取（冲突检测用）
      final first = _index?.rounds.isNotEmpty == true ? _index!.rounds.first : null;
      final firstCached = first == null ? null : _lists[_rk(first)];
      if (first != null &&
          (firstCached == null ||
              refresh ||
              firstCached.state == 'empty' ||
              firstCached.fromCache)) {
        await _loadRound(first, refresh: refresh || firstCached != null);
      }
      if (_timetable == null && !_loadingTimetable) {
        _loadTimetable();
      }
      _publishAiContext(); // 入口刷新/清理后同步给全局助手
      // 需求 #5（默认全量加载）：入口列表就绪即自动对全部入口串行拉取（复用
      // _aggregateAll 的节流/退避纪律：间隔 ≥1.1s、可取消、软封禁即停），页面默认
      // 呈现合并视图，加载中显示"已加载 x/y"；「汇总全部入口」保留为手动重新聚合。
      if (r.rounds.isNotEmpty && mounted && widget.loggedIn && !_demoLoaded) {
        setState(() => _view = _View.merged);
        await _aggregateAll(auto: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingIndex = false;
          _error = '选课入口获取失败：$e';
        });
      }
    }
  }

  Future<void> _loadTimetable({bool refresh = false}) async {
    if (!widget.loggedIn) return;
    if (_loadingTimetable) return;
    setState(() => _loadingTimetable = true);
    try {
      final t = await widget.client.fetchTimetableSlots(refresh: refresh);
      if (!mounted || !widget.loggedIn) return;
      setState(() {
        if (t.slots.isEmpty) {
          // 失败/空不写入 _timetable（保留可重试的"未检查"语义），错误单独记账
          _timetable = null;
          _timetableError =
              t.issues.isNotEmpty ? t.issues.first : '课表获取失败：冲突检测将不可用';
        } else {
          _timetable = t;
          _timetableError = null;
        }
      });
      _publishAiContext();
    } catch (e) {
      if (mounted) {
        setState(() {
          _timetable = null;
          _timetableError = '课表获取失败：冲突检测将不可用';
        });
      }
    } finally {
      if (mounted) setState(() => _loadingTimetable = false);
    }
  }

  Future<void> _loadRound(XkRound round, {bool refresh = false}) async {
    if (!widget.loggedIn) return;
    final rk = _rk(round);
    if (_loadingRounds.contains(rk)) return;
    setState(() => _loadingRounds.add(rk));
    final gen = _listGeneration;
    try {
      final r = await widget.client.fetchXkCourses(
        round: round,
        hiddenFields: _index?.hiddenFields ?? const {},
        xkxnm: _index?.xkxnm,
        xkxqm: _index?.xkxqm,
        zjuGhb: _index?.zjuGhb ?? false,
        refresh: refresh,
      );
      if (!mounted || !widget.loggedIn) return;
      if (gen != _listGeneration) return; // 入口已换代：旧结果不写回（防陈旧入口复活）
      setState(() {
        _softBlocked = r.blocked && r.state == 'unavailable';
        if (r.state == 'data' || r.state == 'empty') {
          _lists[rk] = r;
          _roundErrors.remove(rk);
        } else {
          // unavailable 不写入 _lists：否则会被当作"已拉取"而永久跳过重试（评审L1）
          _roundErrors[rk] = r.issues.isNotEmpty
              ? r.issues.first
              : '状态未知（未开放/会话受限/接口未返回数据）';
        }
        _listsVersion++;
      });
      _publishAiContext();
    } catch (e) {
      if (mounted) {
        setState(() {
          _roundErrors[rk] = '课程列表获取失败：$e';
        });
      }
    } finally {
      if (mounted) setState(() => _loadingRounds.remove(rk));
    }
  }

  /// 入口复合键 → 展示名（失败清单/重试按钮用；找不到原入口时如实显示复合键）。
  String _roundLabel(String rk) {
    for (final r in _index?.rounds ?? const <XkRound>[]) {
      if (_rk(r) == rk) return r.label.isEmpty ? r.xkkzId : r.label;
    }
    return rk;
  }

  /// 单入口重试（需求 #5：失败入口逐个标注、可单独重试；不整批重发）。
  void _retryRound(String rk) {
    for (final r in _index?.rounds ?? const <XkRound>[]) {
      if (_rk(r) == rk) {
        _loadRound(r, refresh: true);
        return;
      }
    }
  }

  /// 跨轮汇总：入口加载后自动触发（需求 #5，auto=true），也可显式按钮重新聚合。
  /// 串行拉取 + 间隔，可取消（评审A8）；并发纪律（评审L1）：汇总期间只用开始时的
  /// 参数快照；入口刷新换代即中止；分片等待让"取消"能及时生效；用户取消时不强制
  /// 切换视图；自动聚合在开始时已切到合并视图，结束时不再回切（不劫持用户浏览）。
  Future<void> _aggregateAll({bool auto = false}) async {
    final rounds = _index?.rounds ?? const [];
    if (rounds.isEmpty || _aggregating || _loadingIndex) return;
    if (!widget.loggedIn) {
      setState(() => _view = _View.merged); // 演示数据：直接切汇总视图（数据已在本地）
      return;
    }
    final hf = _index?.hiddenFields ?? const <String, String>{};
    final xnm = _index?.xkxnm;
    final xqm = _index?.xkxqm;
    final zhb = _index?.zjuGhb ?? false;
    final gen = _listGeneration;
    setState(() {
      _aggregating = true;
      _cancelAggregate = false;
      _aggregateDone = 0;
      _softBlocked = false;
    });
    for (final r in rounds) {
      if (_cancelAggregate || !mounted) break;
      if (gen != _listGeneration) break; // 刷新换代：中止本轮（避免旧轮配新参数写回）
      if (_softBlocked) break; // 已触发软封禁：继续逐入口拉取只会延长封锁（网页正常、App 看不到），停手等冷却
      final existing = _lists[_rk(r)];
      if (existing == null ||
          existing.state == 'empty' ||
          existing.fromCache) {
        final res = await widget.client.fetchXkCourses(
            round: r,
            hiddenFields: hf,
            xkxnm: xnm,
            xkxqm: xqm,
            zjuGhb: zhb,
            refresh: existing != null);
        if (!mounted) break;
        if (res.blocked && res.state == 'unavailable') _softBlocked = true;
        if (gen == _listGeneration) {
          setState(() {
            if (res.state == 'data' || res.state == 'empty') {
              _lists[_rk(r)] = res;
              _roundErrors.remove(_rk(r));
            } else {
              _roundErrors[_rk(r)] = res.issues.isNotEmpty
                  ? res.issues.first
                  : '状态未知（未开放/会话受限/接口未返回数据）';
            }
            _listsVersion++;
          });
        }
        if (_softBlocked) break; // 立刻停，不等下一轮间隔
        // 请求间隔 ≥1s：跨轮拉取属于"批量"，比日常查询更克制（评审A8）；分片等待以便取消
        for (var i = 0; i < 11 && !_cancelAggregate; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      if (mounted) setState(() => _aggregateDone++);
    }
    if (mounted) {
      setState(() {
        _aggregating = false;
        // 手动聚合结束切合并视图；自动聚合开始时已切过，且不劫持用户随后的浏览选择
        if (!_cancelAggregate && !auto) _view = _View.merged;
      });
      _publishAiContext();
    }
  }

  /// 合并结果按 _lists 版本缓存（评审L1：避免每帧/每击键重复全量合并）。
  (List<XkMergedCourse>, List<String>) _mergedAll() {
    if (_mergedCacheVersion != _listsVersion || _mergedCache == null) {
      final all = <XkCourse>[];
      for (final r in _lists.values) {
        if (r.state == 'data') all.addAll(r.courses);
      }
      final result = mergeXkCourses(all);
      _mergedCache = result.courses;
      _mergedNotesCache = result.notes;
      _mergedCacheVersion = _listsVersion;
    }
    return (_mergedCache!, _mergedNotesCache!);
  }

  List<XkMergedCourse> get _merged => _mergedAll().$1;

  List<String> get _mergeNotes => _mergedAll().$2;

  /// 各来源留痕聚合（汇总/建议视图的过期与降级标注，评审L1）。
  List<String> get _allIssues {
    final seen = <String>{};
    final out = <String>[];
    for (final r in _lists.values) {
      for (final i in r.issues) {
        if (seen.add(i) && out.length < 4) out.add(i);
      }
    }
    final te = _timetableError;
    if (te != null && seen.add(te) && out.length < 5) out.add(te);
    return out;
  }

  bool get _anyCacheFromLocal =>
      (_index?.fromCache ?? false) || _lists.values.any((r) => r.fromCache);

  /// 把本页选课数据（已脱敏）发布给全局 AI 助手。
  /// 只发课程名/学分/教师/时间/容量等公开字段；不含学号、成绩、Cookie。
  void _publishAiContext() {
    final cb = widget.onAiContext;
    if (cb == null) return;
    try {
      final data = selectionCandidatesSubsetOf(_merged) ??
          <String, dynamic>{};
      final tt = _timetable;
      if (tt != null) data['课表'] = timetableSubsetOf(tt);
      cb(data.isEmpty ? null : data);
    } catch (_) {
      cb(null); // 摘要构造失败绝不能影响选课主流程
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.loggedIn && _index == null) return _loginGuide();
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        _headerCard(),
        const SizedBox(height: 8),
        _viewSwitch(),
        const SizedBox(height: 8),
        switch (_view) {
          _View.rounds => _roundsView(),
          _View.merged => _mergedView(),
          _View.advice => _adviceView(),
        },
        const SizedBox(height: 12),
        Text(kDisclaimer, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }

  Widget _loginGuide() => Center(
        child: Card(
          margin: const EdgeInsets.all(28),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.school_outlined, size: 40),
                const SizedBox(height: 8),
                const Text('登录教务网后可查看选课入口与课程',
                    style: TextStyle(fontSize: 14)),
                const SizedBox(height: 4),
                const Text('仅只读查询：不会进行任何选课/退课提交',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: widget.onGoSettings,
                  icon: const Icon(Icons.login),
                  label: const Text('去设置页登录'),
                ),
                const SizedBox(height: 4),
                TextButton.icon(
                  onPressed: _loadDemoData,
                  icon: const Icon(Icons.science_outlined, size: 18),
                  label: const Text('加载演示数据（合成样例）'),
                ),
                if (_error != null) ...[
                  // 演示数据加载失败等错误必须可见（此前该状态被登录引导吞掉，评审L1）
                  const SizedBox(height: 6),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11, color: Colors.red)),
                ],
              ],
            ),
          ),
        ),
      );

  Widget _headerCard() => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('课程选择',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  if (_loadingIndex)
                    const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  TextButton.icon(
                    // 演示模式（未登录）与汇总中禁用：不发无意义请求（评审L1 反馈缺失）
                    onPressed: (_loadingIndex || _aggregating || !widget.loggedIn)
                        ? null
                        : () {
                            _loadIndex(refresh: true);
                            if (_timetable == null && !_loadingTimetable) {
                              _loadTimetable(refresh: true); // 课表失败后随刷新入口一并重试
                            }
                          },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('刷新入口'),
                  ),
                ],
              ),
              if (_index != null) ...[
                const SizedBox(height: 4),
                Text(
                  '按当前学期 ${termCodeLabel(widget.currentSemester)} 匹配'
                  '${_index!.xkxnm != null && _index!.xkxqm != null ? '｜教务学期 ${_prettyXkTerm(_index!.xkxnm!, _index!.xkxqm!)}' : '｜教务学期未标注'}'
                  '${_index!.fromCache ? '｜入口读取自缓存（可能过期）' : ''}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                if (_index!.issues.isNotEmpty)
                  Text(_index!.issues.first,
                      style: const TextStyle(fontSize: 11, color: Colors.orange)),
              ],
              if (_error != null)
                Text(_error!, style: const TextStyle(fontSize: 12, color: Colors.red)),
            ],
          ),
        ),
      );

  Widget _viewSwitch() => SegmentedButton<_View>(
        segments: const [
          ButtonSegment(value: _View.rounds, label: Text('分类视图')),
          ButtonSegment(value: _View.merged, label: Text('所有课程')),
          ButtonSegment(value: _View.advice, label: Text('建议卡')),
        ],
        selected: {_view},
        onSelectionChanged: (s) => setState(() => _view = s.first),
      );

  // ── 轮次入口视图 ──────────────────────────────────────────────

  Widget _roundsView() {
    final rounds = _index?.rounds ?? const <XkRound>[];
    if (_loadingIndex && rounds.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('正在获取选课入口…')),
      );
    }
    if (rounds.isEmpty) {
      return _emptyCard('暂未发现选课入口',
          _index?.issues.isNotEmpty == true ? _index!.issues.first : '可能尚未开放选课，或页面结构变化。');
    }
    final selected = rounds.firstWhere(
        (r) => _rk(r) == _selectedRoundId,
        orElse: () => rounds.first);
    final list = _lists[_rk(selected)];
    final roundError = _roundErrors[_rk(selected)];
    final loadingThis = _loadingRounds.contains(_rk(selected));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_softBlocked)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
            ),
            child: const Text(
                '已触发教务访问频率保护（网页端不受影响）。为避免延长封锁，'
                '选课列表已自动冷却，约 1~2 分钟后自动恢复；'
                '也可稍后点「刷新入口」重试。',
                style: TextStyle(fontSize: 12, color: Colors.orange, height: 1.4)),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final r in rounds)
              ChoiceChip(
                // 需求 #5：失败入口在分类视图也逐个标注（错误图标），点入即见重试按钮
                avatar: _roundErrors.containsKey(_rk(r))
                    ? const Icon(Icons.error_outline, size: 14, color: Colors.orange)
                    : null,
                label: Text(r.label.isEmpty ? '入口' : r.label),
                selected: _rk(r) == _rk(selected),
                // 汇总期间冻结轮切换：避免与批量拉取并发打同一入口（评审L1）
                onSelected: _aggregating
                    ? null
                    : (_) {
                        final existing = _lists[_rk(r)];
                        setState(() => _selectedRoundId = _rk(r));
                        if (existing == null ||
                            existing.state == 'empty' ||
                            existing.fromCache) {
                          _loadRound(r,
                              refresh: existing != null ||
                                  _roundErrors.containsKey(_rk(r)));
                        }
                      },
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (loadingThis)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: Text('加载课程列表…')),
          ),
        if (list != null) ...[
          _stateBanner(list, selected, loading: loadingThis),
          const SizedBox(height: 4),
          ..._courseCards(list.courses),
        ] else if (roundError != null) ...[
          Text('该入口状态未知（未开放/会话受限/接口未返回数据），不代表没有课程',
              style: const TextStyle(fontSize: 11, color: Colors.orange)),
          Text(roundError, style: const TextStyle(fontSize: 11, color: Colors.orange)),
          TextButton.icon(
            onPressed: loadingThis ? null : () => _loadRound(selected, refresh: true),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重试该入口'),
          ),
        ],
      ],
    );
  }

  Widget _stateBanner(XkListParseResult list, XkRound round,
      {bool loading = false}) {
    final (text, color) = switch (list.state) {
      'data' => (
          '该分类共 ${list.courses.length} 条课程（只读查询快照）'
              '${list.fromCache ? '｜读取自缓存（可能过期，请刷新）' : ''}',
          Colors.grey
        ),
      'empty' => (
          '该分类当前查询结果为空（可能是真无课、未开放或参数缺失；'
              '空结果只缓存 5 分钟，可手动刷新）',
          Colors.grey
        ),
      _ => (
          '该分类状态未知（未开放/会话受限/接口未返回数据），不代表没有课程',
          Colors.orange
        ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: TextStyle(fontSize: 11, color: color)),
        if (list.issues.isNotEmpty)
          Text(list.issues.first,
              style: const TextStyle(fontSize: 11, color: Colors.orange)),
        TextButton.icon(
          onPressed: loading ? null : () => _loadRound(round, refresh: true),
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('刷新该分类'),
        ),
      ],
    );
  }

  // ── 跨轮汇总视图 ──────────────────────────────────────────────

  Widget _mergedView() {
    final merged = _merged;
    final fetched = _lists.length; // 只统计 data/empty（unavailable 记到 _roundErrors，不当"已拉取"）
    final total = _index?.rounds.length ?? 0;
    final failed = _roundErrors.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // 需求 #5：默认自动全量聚合——加载中显示"已加载 x/y"
                  _aggregating
                      ? '正在自动汇总全部入口：已加载 $_aggregateDone/$total…（可取消）'
                      : '已加载 $fetched/$total 个入口'
                          '${failed > 0 ? '（$failed 个暂不可用，可在下方或「分类视图」单独重试）' : ''}',
                  style: const TextStyle(fontSize: 12),
                ),
                if (_aggregating) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                      value: total > 0 ? _aggregateDone / total : null),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: (_aggregating || _loadingIndex) ? null : _aggregateAll,
                      icon: const Icon(Icons.merge_type, size: 18),
                      label: const Text('汇总全部入口'),
                    ),
                    const SizedBox(width: 8),
                    if (_aggregating)
                      TextButton(
                        onPressed: () => setState(() => _cancelAggregate = true),
                        child: const Text('取消'),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text('同一教学班按 课程+教学班 身份跨轮对齐；容量与已选为查询时刻快照。',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
                const Text(kCandidatesOrderNote,
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
                if (_anyCacheFromLocal)
                  const Text('含本地缓存数据（可能过期，请点「刷新入口」后重试）',
                      style: TextStyle(fontSize: 11, color: Colors.orange)),
                // 需求 #5：失败入口逐个标注 + 单独重试（汇总中不显示，避免与串行队列并发重发）
                if (!_aggregating && _roundErrors.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  for (final e in _roundErrors.entries)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const Icon(Icons.error_outline,
                              size: 14, color: Colors.orange),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text('${_roundLabel(e.key)}：${e.value}',
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.orange)),
                          ),
                          TextButton.icon(
                            onPressed: _loadingRounds.contains(e.key)
                                ? null
                                : () => _retryRound(e.key),
                            icon: const Icon(Icons.refresh, size: 14),
                            label: const Text('重试', style: TextStyle(fontSize: 11)),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _searchCtl,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: '搜索课程（按课程名/课程号，跨分类查找）',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        if (merged.isEmpty)
          _aggregating
              ? _emptyCard('正在逐入口拉取课程…',
                  '已加载 $_aggregateDone/$total 个入口；触发教务频率保护时会自动暂停，'
                      '可点「取消」停止本轮。')
              : _emptyCard(
                  failed > 0 && fetched == 0 ? '全部入口暂不可用' : '暂无汇总数据',
                  failed > 0 && fetched == 0
                      ? '已尝试拉取但均未成功（${_roundErrors.values.first}）。点上方按钮重新聚合。'
                      : '点上方「汇总全部入口」重新聚合各入口课程。')
        else
          ..._mergedCards(merged),
        if (_mergeNotes.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final n in _mergeNotes)
            Text(n, style: const TextStyle(fontSize: 11, color: Colors.orange)),
        ],
        if (_allIssues.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final n in _allIssues)
            Text(n, style: const TextStyle(fontSize: 11, color: Colors.orange)),
        ],
        const SizedBox(height: 4),
        Text(kCapacityNote, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }

  List<Widget> _mergedCards(List<XkMergedCourse> merged) {
    final q = _searchCtl.text.trim();
    final filtered = q.isEmpty
        ? merged
        : merged
            .where((m) =>
                m.base.kcmc.contains(q) ||
                m.base.kch.contains(q) ||
                m.base.teacher.contains(q))
            .toList();
    // 排序只按课程代码（评审C：排序不代表推荐；UI 明确脚注）
    final sorted = [...filtered]
      ..sort((a, b) => (a.base.kch.isEmpty ? a.base.kcmc : a.base.kch)
          .compareTo(b.base.kch.isEmpty ? b.base.kcmc : b.base.kch));
    final selectedKeys = _selectedCourseKeys();
    final ttSlots = (_timetable ?? widget.timetable)?.slots ?? const [];
    return [
      LayoutBuilder(builder: (context, cons) {
        final maxW = cons.maxWidth.isFinite ? cons.maxWidth : 320.0;
        return Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final m in sorted)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxW),
                child: CourseBubble(
                  course: m.base,
                  conflict: ttSlots.isNotEmpty &&
                      Timeline.slotsConflict(m.slots, ttSlots) != null,
                  selected: _isCourseSelected(m.base, selectedKeys),
                  // 诉求 #11：跨入口合并后的全部类别（去重保序）逐枚出 Chip
                  categories: m.categories,
                  extraTags: m.tags,
                  extraDetails: _mergedDetails(m),
                ),
              ),
          ],
        );
      }),
      if (filtered.length != merged.length)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('筛选出 ${filtered.length}/${merged.length} 条',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ),
    ];
  }

  String? _mergedDetails(XkMergedCourse m) {
    final b = m.base;
    final obs = m.byRound.values
        .where((o) => o.cap != null || o.selected != null)
        .toList();
    final lines = <String>[
      if (m.roundOrder.length > 1) '出现在 ${m.roundOrder.length} 个分类入口',
      if (b.kch.isNotEmpty) '课程号 ${b.kch}',
      if (b.xf != null) '学分 ${b.xf}',
      if (b.teacher.isNotEmpty) '教师 ${b.teacher}',
      if (b.sksj.isNotEmpty) '时间 ${b.sksj}',
      if (b.cdmc.isNotEmpty) '地点 ${b.cdmc}',
      if (obs.isNotEmpty)
        '容量/已选快照：${obs.map((o) => '${o.cap ?? '-'}/${o.selected ?? '-'}').join(' → ')}',
      ...m.notes,
      if (b.identityTier == 3) '该条目缺少教学班标识，无法区分平行班',
    ];
    return lines.isEmpty ? null : lines.join('\n');
  }

  // ── 建议卡视图 ──────────────────────────────────────────────

  Widget _adviceView() {
    final merged = _merged;
    final planCourses = (widget.plan?['courses'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final planModules = (widget.plan?['modules'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    // 方案未加载（重启后未跑审计的常态）时如实标注：绝不把分类缺失渲染成"全部方案外"
    final planMissing = planCourses.isEmpty;
    final timetable = _timetable ?? widget.timetable;
    final selectedRows = selectedRowsOf(widget.choosed);
    final selectedSlots = <Map<String, dynamic>>[
      for (final c in widget.choosed?.courses ?? const <XkCourse>[])
        ...c.slots,
    ];
    final timetableSlots = <Map<String, dynamic>>[
      ...(timetable?.slots ?? const <Map<String, dynamic>>[]),
      ...selectedSlots,
    ];
    final advice = buildSelectionAdvice(SelectionRequest(
      candidates: merged,
      transcript: widget.transcript,
      planCourses: planCourses,
      planModules: planModules,
      currentSemester: widget.currentSemester,
      currentTimetableSlots: timetableSlots,
      currentTimetableKnown: (timetable?.slots.isNotEmpty ?? false) ||
          selectedSlots.isNotEmpty,
      selectedCourses: selectedRows,
    ));
    // 诉求 #9：建议卡只显示“可选取且满足培养方案要求”的课程；
    // 方案未加载时保留全量（否则无法分类，页面会显示明确提示）。
    final visibleCandidates = planMissing
        ? advice.candidates
        : advice.candidates.where(isSelectableForPlan).toList();
    final hiddenCount = advice.candidates.length - visibleCandidates.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (merged.isEmpty)
          _emptyCard('暂无可分析的候选课程', '请先在「所有课程」拉取课程数据。'),
        if (merged.isNotEmpty) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('建议卡（本机确定性计算）',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    '缺口课程 ${advice.counts['gap'] ?? 0}'
                    '｜已取得 ${advice.counts['passed'] ?? 0}'
                    '｜本学期已选 ${advice.counts['selected'] ?? 0}'
                    '｜方案外 ${advice.counts['extra'] ?? 0}'
                    '｜与课表冲突 ${advice.counts['conflict'] ?? 0}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (!planMissing)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '可选取且符合方案 ${visibleCandidates.length} 门'
                        '${hiddenCount > 0 ? '（未显示 $hiddenCount 门：已取得/已选/方案外/冲突/先修未完成/已满）' : ''}',
                        style: const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ),
                  if (planMissing)
                    const Text('培养方案未加载：缺口/已修分类暂不可用，以上按“未匹配”统计；'
                        '请先在设置页完成一次教务拉取或样例审计。',
                        style: TextStyle(fontSize: 11, color: Colors.orange)),
                  if (_timetableError != null)
                    Text(_timetableError!,
                        style: const TextStyle(fontSize: 11, color: Colors.orange)),
                  if (_anyCacheFromLocal)
                    const Text('含本地缓存数据（可能过期，请点「刷新入口」后重试）',
                        style: TextStyle(fontSize: 11, color: Colors.orange)),
                  for (final n in advice.notes)
                    Text(n,
                        style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          ..._candidateCards(visibleCandidates),
          if (visibleCandidates.isEmpty && !planMissing)
            _emptyCard('没有可选取且符合培养方案的课程',
                '已取得、本学期已选、方案外、时间冲突、先修未完成或已满的课程未显示。'),
        ],
        const SizedBox(height: 8),
        _aiPanel(advice),
      ],
    );
  }

  /// 建议卡列表：与课程列表同一套响应式网格（同一 gridColumns 断点、6 间距）。
  List<Widget> _candidateCards(List<CandidateAnalysis> candidates) {
    if (candidates.isEmpty) return const [];
    return [
      LayoutBuilder(
        builder: (context, cons) {
          final maxW = cons.maxWidth.isFinite ? cons.maxWidth : 320.0;
          final cols = gridColumns(maxW);
          const gap = 6.0;
          final cardW = (maxW - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final a in candidates)
                SizedBox(width: cardW, child: _candidateCard(a)),
            ],
          );
        },
      ),
    ];
  }

  /// 建议卡紧凑版（网格单元）：数据源/状态色沿用原口径，仅排版收紧。
  Widget _candidateCard(CandidateAnalysis a) {
    final b = a.course.base;
    final roleText = switch (a.role) {
      'gap' => '培养方案缺口课程',
      'passed' => '已取得',
      'selected' => '本学期已选',
      'extra' => '方案外课程',
      _ => '匹配状态未知',
    };
    final offeredText = switch (a.offeredMatch) {
      'yes' => '与方案标注开课季一致',
      'no' => '与方案标注开课季不符',
      _ => '开课季未标注',
    };
    return Card(
      margin: EdgeInsets.zero, // 间距统一交给外层 Wrap（卡间距 6）
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: b.kcmc,
                    child: Text(b.kcmc,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 4),
                _tag(
                    roleText,
                    a.role == 'gap'
                        ? Colors.blue
                        : a.role == 'selected'
                            ? Colors.deepPurple
                            : Colors.grey),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              [
                if (b.teacher.isNotEmpty) '教师 ${b.teacher}',
                if (b.sksj.isNotEmpty) '时间 ${b.sksj.replaceAll('星期', '')}',
                if (b.cap != null || b.selected != null)
                  '容量 ${b.cap ?? '-'}/已选 ${b.selected ?? '-'}',
                offeredText,
              ].join('｜'),
              style: const TextStyle(fontSize: 11),
            ),
            if (a.planCategory != null || b.tags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 2,
                  children: [
                    if (a.planCategory != null)
                      _tag(
                        '类别：${a.planCategory}'
                        '${a.categoryBasis == 'tag' ? '（按标签推断）' : ''}',
                        a.categoryBasis == 'tag'
                            ? Colors.orange.shade800
                            : Theme.of(context).colorScheme.primary,
                      ),
                    for (final t in b.tags) _tag(t, Colors.teal),
                  ],
                ),
              ),
            for (final c in a.conflictTexts)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(c,
                    style: const TextStyle(fontSize: 11, color: Colors.red)),
              ),
            for (final n in a.notes)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(n,
                    style: const TextStyle(fontSize: 10.5, color: Colors.grey)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(text, style: TextStyle(fontSize: 11, color: color)),
      );

  /// 教务学期号（xkxnm='2026-2027' × xkxqm=1 秋冬/2 春夏/3 短）→ 日历标签。
  /// 无法解析原样返回「学年-学期」。
  static String _prettyXkTerm(String xkxnm, String xkxqm) {
    final y = RegExp(r'^(\d{4})').firstMatch(xkxnm)?.group(1);
    if (y == null) return '$xkxnm-$xkxqm';
    final n = int.parse(y);
    switch (xkxqm) {
      case '1':
        return '$n秋冬';
      case '2':
        return '${n + 1}春夏';
      case '3':
        return '${n + 1}短';
      default:
        return '$xkxnm-$xkxqm';
    }
  }

  // ── AI 解读面板（默认关闭；合规文案来自 ai_prompts.dart，勿在此另写）──

  Widget _aiPanel(SelectionAdvice advice) {
    final cfg = widget.aiConfig;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(kAiPanelTitle,
                      style:
                          TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                ),
                if (!cfg.enabled)
                  TextButton(
                    onPressed: widget.onGoSettings,
                    child: const Text('去设置'),
                  ),
              ],
            ),
            if (!cfg.enabled)
              const Text('未启用：建议卡为本机计算，无需 AI 即可使用。要获得文字解读，请在设置页「AI 解读」中配置。',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            if (cfg.enabled) ...[
              Text(kAiSendNotice,
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  for (final q in kAiQuickQuestions)
                    ActionChip(
                      label: Text(q, style: const TextStyle(fontSize: 12)),
                      onPressed: _aiBusy ? null : () => _sendAi(q, advice),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _aiCtl,
                      decoration: const InputDecoration(
                        labelText: '追问（勿输入个人信息）',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _sendAi(_aiCtl.text, advice),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _aiBusy ? null : () => _sendAi(_aiCtl.text, advice),
                    child: _aiBusy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('发送'),
                  ),
                ],
              ),
              if (_aiError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_aiError!,
                      style: const TextStyle(fontSize: 12, color: Colors.red)),
                ),
              // 流式回复：先显示在途提问与已收到的片段，成功后移入 _aiHistory。
              if (_aiBusy && _aiPendingQuestion != null) ...[
                const Divider(height: 20),
                Text('问：$_aiPendingQuestion',
                    style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                SelectableText(
                    sanitizeAiOutput(_aiStreaming ?? '正在思考…'),
                    style: const TextStyle(fontSize: 13, height: 1.5)),
              ],
              for (final (q, a) in _aiHistory) ...[
                const Divider(height: 20),
                Text('问：$q', style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                SelectableText(a, style: const TextStyle(fontSize: 13, height: 1.5)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text('（$kAiFooter）',
                        style: const TextStyle(fontSize: 10, color: Colors.grey)),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () {
                        // 复制内容必须拼接页脚（评审C：免责声明不得被复制丢弃）
                        _copyToClipboard('$a\n\n$kAiFooter');
                      },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('复制'),
                    ),
                  ],
                ),
              ],
              // 需求 #12：整段 AI 选课咨询一键导出为脱敏分享包供指导教师审阅
              // （随当前审计数据打包；无审计时 main 侧返回引导文案）。
              if (_aiHistory.isNotEmpty && widget.onExportAdvice != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('共 ${_aiHistory.length} 轮问答可随分享包导出',
                            style: const TextStyle(fontSize: 11, color: Colors.grey)),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _aiBusy
                            ? null
                            : () => widget.onExportAdvice!(
                                [
                                  for (final (q, a) in _aiHistory) {'q': q, 'a': a},
                                ]),
                        icon: const Icon(Icons.group_outlined, size: 16),
                        label: const Text('导出给指导教师'),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> _sendAi(String question, SelectionAdvice advice) async {
    final q = question.trim();
    if (q.isEmpty || _aiBusy) return;
    // 输入侧越界拦截：命中直接回退固定文案，不发请求（评审C 第2/3/4条的第一道防线）
    final hits = findBoundaryTriggers(q);
    if (hits.isNotEmpty) {
      setState(() {
        _aiHistory.add((q, kAiBoundaryFallback));
        _aiCtl.clear();
      });
      return;
    }
    // 首次发送前确认发送范围（会话内一次）
    if (!_sendNoticeAck) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('发送范围确认'),
          content: const Text(kAiSendNotice),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('同意并发送')),
          ],
        ),
      );
      if (!mounted) return; // 对话框期间页面可能被销毁（窗口关闭/清数据重建）
      if (ok != true) return;
      _sendNoticeAck = true;
    }
    // 数据放 system、历史问答放 messages：多轮追问不再每轮重复整段数据，
    // 且模型能真正看到上一轮的问答（此前只发当前一句 → 追问失忆）。
    final system =
        '${buildGuidanceSystemPrompt()}\n\n[结构化数据（已脱敏）]\n'
        '${buildSelectionDataPayload(advice: advice, auditReport: widget.report)}';
    final messages = <Map<String, String>>[];
    for (final (pq, pa) in _aiHistory) {
      messages
        ..add(<String, String>{'role': 'user', 'content': pq})
        ..add(<String, String>{'role': 'assistant', 'content': pa});
    }
    if (messages.length > 12) {
      messages.removeRange(0, messages.length - 12);
    }
    messages.add(<String, String>{'role': 'user', 'content': q});

    setState(() {
      _aiBusy = true;
      _aiError = null;
      _aiPendingQuestion = q;
      _aiStreaming = '';
    });
    try {
      final client = AiClient(widget.aiConfig);
      final out = await client.chat(
        system: system,
        messages: messages,
        onDelta: (delta) {
          if (!mounted) return;
          setState(() => _aiStreaming = '${_aiStreaming ?? ''}$delta');
        },
      );
      if (!mounted) return;
      setState(() {
        _aiBusy = false;
        _aiPendingQuestion = null;
        _aiStreaming = null;
        switch (out) {
          case AiReply(:final text):
            // 输出侧第二道防线（评审定稿）：命中禁用倾向词/组合句式即整段回退边界文案
            _aiHistory.add((q, sanitizeAiOutput(text)));
            _aiCtl.clear();
          case AiFailure(:final message):
            _aiError = message;
        }
      });
    } catch (_) {
      // AiClient 有意只捕 Exception（Error 属编程缺陷应暴露）；但 UI 不能因此软锁死：
      // 未知错误也必须复位忙碌态并给可读提示（评审实测：漏写 scheme 的地址会抛 Error）
      if (mounted) {
        setState(() {
          _aiBusy = false;
          _aiPendingQuestion = null;
          _aiStreaming = null;
          _aiError = '请求异常（请检查接口地址等配置后重试）';
        });
      }
    }
  }

  Widget _emptyCard(String title, String sub) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text(title, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 4),
              Text(sub,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        ),
      );

  /// 课程列表：全部展示，每门课一个按名称自适应宽度的气泡，Wrap 排列节省空间。
  /// 冲突/已满/余量/已选/课程性质标签全部附在气泡上（详情在 Tooltip）。
  List<Widget> _courseCards(List<XkCourse> courses) {
    if (courses.isEmpty) return const [];
    final ttSlots = (_timetable ?? widget.timetable)?.slots ?? const [];
    final selectedKeys = _selectedCourseKeys();
    return [
      LayoutBuilder(
        builder: (context, cons) {
          final maxW = cons.maxWidth.isFinite ? cons.maxWidth : 320.0;
          return Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in courses)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxW),
                  child: CourseBubble(
                    course: c,
                    conflict: ttSlots.isNotEmpty &&
                        Timeline.slotsConflict(c.slots, ttSlots) != null,
                    selected: _isCourseSelected(c, selectedKeys),
                    categories: c.categories, // 单轮列表同样显示类别 Chip（诉求 #11）
                  ),
                ),
            ],
          );
        },
      ),
    ];
  }

  Set<String> _selectedCourseKeys() {
    final keys = <String>{};
    for (final c in widget.choosed?.courses ?? const <XkCourse>[]) {
      if (c.kch.isNotEmpty) keys.add('k:${c.kch}');
      final name = c.kcmc.trim();
      if (name.isNotEmpty) keys.add('n:$name');
    }
    return keys;
  }

  bool _isCourseSelected(XkCourse c, Set<String> keys) =>
      (c.kch.isNotEmpty && keys.contains('k:${c.kch}')) ||
      keys.contains('n:${c.kcmc.trim()}');
}

// ───────────────────────── 课程网格（任务3：响应式多列） ─────────────────────────

/// 课程网格列数（顶层纯函数，test/course_grid_test.dart 直连断言）：
/// 每列目标最小 260px、最多 3 列；宽度不足一列保底 1 列（手机窄屏自动退一列）。
int gridColumns(double availableWidth) {
  final n = availableWidth ~/ 260;
  return n < 1 ? 1 : (n > 3 ? 3 : n);
}

/// 课程气泡：宽度随课程名自适应，Wrap 排列；标签在第二行，详情在 Tooltip。
/// 所有抓到的课程都要展示，因此不再有 120 条上限。
class CourseBubble extends StatelessWidget {
  final XkCourse course;
  final bool conflict;
  final bool selected;
  final List<String> categories; // 类别标签（诉求 #11：可多枚，全部显示）
  final List<String> extraTags;
  final String? extraDetails;

  const CourseBubble({
    super.key,
    required this.course,
    this.conflict = false,
    this.selected = false,
    this.categories = const [],
    this.extraTags = const [],
    this.extraDetails,
  });

  @override
  Widget build(BuildContext context) {
    final c = course;
    final isFull =
        c.cap != null && c.selected != null && c.selected! >= c.cap!;
    final left =
        c.cap != null && c.selected != null ? c.cap! - c.selected! : null;
    final allTags = <String>{...c.tags, ...extraTags};
    // Chip 去重（诉求 #11）：类别名在 tags 兼容口径里也会出现，同一文本只出一枚；
    // 类别 Chip 用独立色并放在最前，剩余标签按原有顺序跟上。
    final seen = {...categories};
    final tags = <Widget>[
      for (final t in categories) _miniTag(t, Colors.indigo),
      if (c.jxbmc.isNotEmpty && seen.add(c.jxbmc))
        _miniTag(c.jxbmc, Colors.blueGrey),
      if (conflict && seen.add('冲突')) _miniTag('冲突', Colors.red),
      if (selected && seen.add('本学期已选'))
        _miniTag('本学期已选', Colors.blue),
      if (isFull && seen.add('已满'))
        _miniTag('已满', Colors.orange)
      else if (left != null && seen.add('余 $left'))
        _miniTag('余 $left', Colors.teal),
      for (final t in allTags)
        if (seen.add(t)) _miniTag(t, Colors.teal),
    ];
    final details = <String>[
      if (c.kch.isNotEmpty) '课程号 ${c.kch}',
      if (c.xf != null) '学分 ${c.xf}',
      if (c.teacher.isNotEmpty) '教师 ${c.teacher}',
      if (c.sksj.isNotEmpty) '时间 ${c.sksj}',
      if (c.cdmc.isNotEmpty) '地点 ${c.cdmc}',
      if (c.cap != null || c.selected != null)
        '容量 ${c.cap ?? '-'}/已选 ${c.selected ?? '-'}',
      if (extraDetails != null && extraDetails!.trim().isNotEmpty)
        extraDetails!.trim(),
    ].join('\n');
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: details,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? scheme.tertiaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: conflict ? Colors.red : scheme.outlineVariant,
            width: conflict ? 1.2 : 0.8,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(c.kcmc,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.bold)),
            if (tags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Wrap(
                  spacing: 3,
                  runSpacing: 2,
                  children: tags,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _miniTag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        // maxLines:1（诉求 #11）：类别名可能很长（如「美育类通识必修课程」），
        // 每枚 Chip 截断保单行，长标签不撑破 Wrap 行高（全称仍可在 Tooltip 查看）
        child: Tooltip(
          message: text,
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9.5, color: color)),
        ),
      );
}

/// 选课课程紧凑小卡（响应式网格单元，任务3）：
/// 行1 课程名（粗体 12.5，ellipsis + Tooltip 全称）+ 状态小标签（冲突/已满/余量）；
/// 行2 教师｜时间（缩写：去「星期」字样）；行3 容量/已选（仅快照可得时显示）。
/// 状态色沿用本页既有口径：冲突=红、已满=橙、余量=青；不新增任何网络请求。
class CourseMiniCard extends StatelessWidget {
  final XkCourse course;

  /// 与当前课表时隙冲突（页面用 Timeline.slotsConflict 判定；课表未知时恒 false）。
  final bool conflict;

  const CourseMiniCard({super.key, required this.course, this.conflict = false});

  @override
  Widget build(BuildContext context) {
    final c = course;
    final fullName = '${c.kcmc}${c.jxbmc.isEmpty ? '' : '（${c.jxbmc}）'}';
    final isFull =
        c.cap != null && c.selected != null && c.selected! >= c.cap!;
    final left =
        c.cap != null && c.selected != null ? c.cap! - c.selected! : null;
    final meta = [
      if (c.teacher.isNotEmpty) c.teacher,
      if (c.sksj.isNotEmpty) c.sksj.replaceAll('星期', ''),
    ].join('｜');
    String? tagText;
    Color? tagColor;
    if (conflict) {
      tagText = '冲突';
      tagColor = Colors.red;
    } else if (isFull) {
      tagText = '已满';
      tagColor = Colors.orange;
    } else if (left != null) {
      tagText = '余 $left';
      tagColor = Colors.teal;
    }
    return Card(
      margin: EdgeInsets.zero, // 间距统一交给外层 Wrap（卡间距 6）
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: fullName,
                    child: Text(
                      fullName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                if (tagText != null) ...[
                  const SizedBox(width: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: tagColor!.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(tagText,
                        style: TextStyle(fontSize: 10, color: tagColor)),
                  ),
                ],
              ],
            ),
            if (meta.isNotEmpty)
              Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5),
              ),
            if (c.cap != null || c.selected != null)
              Text(
                '容量 ${c.cap ?? '-'}/已选 ${c.selected ?? '-'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            if (conflict)
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Text('与当前课表冲突',
                    style: TextStyle(fontSize: 11, color: Colors.red)),
              ),
          ],
        ),
      ),
    );
  }
}
