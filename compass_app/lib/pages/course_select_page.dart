/// pages/course_select_page.dart — 选课页：轮次入口 / 跨轮次汇总 / 与方案和课表匹配 / AI 解读。
///
/// 红线与策略（设计评审结论，改动前先读）：
///  - 只读：仅调用选课查询接口；提交/退课等写操作绝不调用（docs/选课模块接入说明.md）；
///  - 拉取策略（评审A8）：进入本页且已登录才按需拉取；单轮点选即拉；跨轮汇总为显式按钮
///    （串行 + 间隔），禁止启动期扇出；IndexedStack 保活下以 active 门控；
///  - 三态文案（评审A6）：「已开放有数据 / 已开放但无结果 / 未开放或状态未知」三种如实显示；
///  - AI 解读（评审C）：默认关闭；首次发送前确认发送范围；越界提问直接回退固定文案；
///    输出页脚（kAiFooter）与免责声明（kDisclaimer）由本页硬拼接，模型无权删改。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/ai_client.dart';
import '../data/ai_config.dart';
import '../data/ai_prompts.dart';
import '../data/credential_store.dart';
import '../data/xk_models.dart';
import '../data/xk_parse.dart';
import '../data/zju_client.dart';
import '../engine/disclaimer.dart';
import '../engine/selection.dart';

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
  final AiConfig aiConfig;
  final int resetToken; // 父级"一键清除"自增令牌：变化即清空本页 AI 会话态
  final VoidCallback onGoSettings;

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
    required this.aiConfig,
    required this.resetToken,
    required this.onGoSettings,
  });

  static const String tabLabel = '选课';
  static const IconData tabIcon = Icons.how_to_vote_outlined;
  static const IconData tabIconSelected = Icons.how_to_vote;

  @override
  State<CourseSelectPage> createState() => _CourseSelectPageState();
}

class _CourseSelectPageState extends State<CourseSelectPage> {
  XkIndexParseResult? _index;
  final Map<String, XkListParseResult> _lists = {}; // xkkzId -> 列表结果
  String? _selectedRoundId;
  TimetableParseResult? _timetable;
  bool _demoLoaded = false; // 演示数据已加载：真实刷新成功时必须清掉演示残留，防混显

  bool _loadingIndex = false;
  final Set<String> _loadingRounds = {}; // 按入口维护（快速切 chip 不再互相丢弃请求）
  bool _loadingTimetable = false;
  String? _timetableError; // 课表失败原因：失败不写 _timetable（保留可重试），错误单独记账
  bool _aggregating = false;
  bool _cancelAggregate = false;
  int _aggregateDone = 0;
  String? _error;
  final Map<String, String> _roundErrors = {}; // xkkzId -> 失败原因（不写 _lists，可重试）
  int _listGeneration = 0; // 入口刷新/登出换代：旧世代在飞结果一律作废（防陈旧写回）
  int _listsVersion = 0; // _lists 每次变更自增（合并结果按版本缓存，避免每帧重算）
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
      });
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

  /// 加载离线演示数据（合成样例，video/演示固化与自检.md 场景 6 的固化输入）。
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
        rounds.add(XkRound(xkkzId: id, label: label));
        lists[id] = parseXkCourseList(
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
        _selectedRoundId = rounds.isNotEmpty ? rounds.first.xkkzId : null;
        _error = null;
        _demoLoaded = true;
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
        // 换批次/换学期后，修剪已不在新入口列表中的旧列表缓存（失败记账一并清理）
        final validIds = r.rounds.map((x) => x.xkkzId).toSet();
        final removed = _lists.keys.where((k) => !validIds.contains(k)).toList();
        for (final k in removed) {
          _lists.remove(k);
        }
        if (removed.isNotEmpty) _listsVersion++;
        _roundErrors.removeWhere((k, _) => !validIds.contains(k));
        if (r.rounds.isNotEmpty) {
          final first = r.rounds.first;
          _selectedRoundId ??= first.xkkzId;
        }
      });
      // 默认拉一次首入口的列表（单次请求）；课表时隙后台拉取（冲突检测用）
      final first = _index?.rounds.isNotEmpty == true ? _index!.rounds.first : null;
      if (first != null && !_lists.containsKey(first.xkkzId)) {
        await _loadRound(first);
      }
      if (_timetable == null && !_loadingTimetable) {
        _loadTimetable();
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
    if (_loadingRounds.contains(round.xkkzId)) return;
    setState(() => _loadingRounds.add(round.xkkzId));
    final gen = _listGeneration;
    try {
      final r = await widget.client.fetchXkCourses(
        round: round,
        hiddenFields: _index?.hiddenFields ?? const {},
        xkxnm: _index?.xkxnm,
        xkxqm: _index?.xkxqm,
        refresh: refresh,
      );
      if (!mounted || !widget.loggedIn) return;
      if (gen != _listGeneration) return; // 入口已换代：旧结果不写回（防陈旧入口复活）
      setState(() {
        if (r.state == 'data' || r.state == 'empty') {
          _lists[round.xkkzId] = r;
          _roundErrors.remove(round.xkkzId);
        } else {
          // unavailable 不写入 _lists：否则会被当作"已拉取"而永久跳过重试（评审L1）
          _roundErrors[round.xkkzId] = r.issues.isNotEmpty
              ? r.issues.first
              : '状态未知（未开放/会话受限/接口未返回数据）';
        }
        _listsVersion++;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _roundErrors[round.xkkzId] = '课程列表获取失败：$e';
        });
      }
    } finally {
      if (mounted) setState(() => _loadingRounds.remove(round.xkkzId));
    }
  }

  /// 跨轮汇总：显式按钮触发，串行拉取 + 间隔，可取消（评审A8）。
  /// 并发纪律（评审L1）：汇总期间只用开始时的参数快照；入口刷新换代即中止；
  /// 分片等待让"取消"能及时生效；用户取消时不强制切换视图。
  Future<void> _aggregateAll() async {
    final rounds = _index?.rounds ?? const [];
    if (rounds.isEmpty || _aggregating || _loadingIndex) return;
    if (!widget.loggedIn) {
      setState(() => _view = _View.merged); // 演示数据：直接切汇总视图（数据已在本地）
      return;
    }
    final hf = _index?.hiddenFields ?? const <String, String>{};
    final xnm = _index?.xkxnm;
    final xqm = _index?.xkxqm;
    final gen = _listGeneration;
    setState(() {
      _aggregating = true;
      _cancelAggregate = false;
      _aggregateDone = 0;
    });
    for (final r in rounds) {
      if (_cancelAggregate || !mounted) break;
      if (gen != _listGeneration) break; // 刷新换代：中止本轮（避免旧轮配新参数写回）
      if (!_lists.containsKey(r.xkkzId)) {
        final res = await widget.client.fetchXkCourses(
            round: r, hiddenFields: hf, xkxnm: xnm, xkxqm: xqm);
        if (!mounted) break;
        if (gen == _listGeneration) {
          setState(() {
            if (res.state == 'data' || res.state == 'empty') {
              _lists[r.xkkzId] = res;
              _roundErrors.remove(r.xkkzId);
            } else {
              _roundErrors[r.xkkzId] = res.issues.isNotEmpty
                  ? res.issues.first
                  : '状态未知（未开放/会话受限/接口未返回数据）';
            }
            _listsVersion++;
          });
        }
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
        if (!_cancelAggregate) _view = _View.merged; // 取消时不强制换视图
      });
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
                  '按当前学期 ${widget.currentSemester} 匹配'
                  '${_index!.xkxnm != null && _index!.xkxqm != null ? '｜教务学期 ${_index!.xkxnm}-${_index!.xkxqm}' : '｜教务学期未标注'}'
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
          ButtonSegment(value: _View.rounds, label: Text('轮次入口')),
          ButtonSegment(value: _View.merged, label: Text('跨轮汇总')),
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
        (r) => r.xkkzId == _selectedRoundId,
        orElse: () => rounds.first);
    final list = _lists[selected.xkkzId];
    final roundError = _roundErrors[selected.xkkzId];
    final loadingThis = _loadingRounds.contains(selected.xkkzId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final r in rounds)
              ChoiceChip(
                label: Text(r.label.isEmpty ? '入口' : r.label),
                selected: r.xkkzId == selected.xkkzId,
                // 汇总期间冻结轮切换：避免与批量拉取并发打同一入口（评审L1）
                onSelected: _aggregating
                    ? null
                    : (_) {
                        setState(() => _selectedRoundId = r.xkkzId);
                        if (!_lists.containsKey(r.xkkzId)) {
                          _loadRound(r);
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
          _stateBanner(list, selected),
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

  Widget _stateBanner(XkListParseResult list, XkRound round) {
    final (text, color) = switch (list.state) {
      'data' => (
          '该入口共 ${list.courses.length} 条课程（只读查询快照）'
              '${list.fromCache ? '｜读取自缓存（可能过期）' : ''}',
          Colors.grey
        ),
      'empty' => ('该入口已开放，当前查询结果为空（可能无面向你的课程）', Colors.grey),
      _ => (
          '该入口状态未知（未开放/会话受限/接口未返回数据），不代表没有课程',
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
                  '已拉取 $fetched/$total 个入口'
                  '${failed > 0 ? '（$failed 个暂不可用，可在「轮次入口」里重试）' : ''}'
                  '${_aggregating ? '（正在汇总 $_aggregateDone/$total…）' : ''}',
                  style: const TextStyle(fontSize: 12),
                ),
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
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _searchCtl,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: '搜索课程（按课程名/课程号，跨轮次查找）',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        if (merged.isEmpty)
          _emptyCard(
              failed > 0 && fetched == 0 ? '全部入口暂不可用' : '暂无汇总数据',
              failed > 0 && fetched == 0
                  ? '已尝试拉取但均未成功（${_roundErrors.values.first}）。点上方按钮重试。'
                  : '点上方「汇总全部入口」拉取各入口课程后在此合并。')
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
    final shown = sorted.take(120).toList(); // 与轮次视图同款截断策略（评审L1 性能）
    return [
      for (final m in shown) _mergedCard(m),
      if (sorted.length > shown.length)
        Text('仅显示前 120 条（共 ${sorted.length} 条，请用搜索缩小范围）',
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
      if (filtered.length != merged.length)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('筛选出 ${filtered.length}/${merged.length} 条',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ),
    ];
  }

  Widget _mergedCard(XkMergedCourse m) {
    final b = m.base;
    final obs = m.byRound.values.where((o) => o.cap != null || o.selected != null).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${b.kcmc}${b.jxbmc.isEmpty ? '' : '（${b.jxbmc}）'}',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.bold)),
                ),
                if (m.roundOrder.length > 1)
                  _tag('出现在 ${m.roundOrder.length} 个入口', Colors.blue),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [
                if (b.kch.isNotEmpty) '课程号 ${b.kch}',
                if (b.teacher.isNotEmpty) '教师 ${b.teacher}',
                if (b.xf != null) '学分 ${b.xf}',
                if (b.sksj.isNotEmpty) '时间 ${b.sksj}',
                if (b.cdmc.isNotEmpty) '地点 ${b.cdmc}',
              ].join('｜'),
              style: const TextStyle(fontSize: 12),
            ),
            if (obs.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '容量/已选（快照）：${obs.map((o) => '${o.cap ?? '-'}/${o.selected ?? '-'}').join('  →  ')}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
            for (final n in [...m.notes, if (b.identityTier == 3) '该条目缺少教学班标识，无法区分平行班'])
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(n,
                    style: const TextStyle(fontSize: 11, color: Colors.orange)),
              ),
          ],
        ),
      ),
    );
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
    final advice = buildSelectionAdvice(SelectionRequest(
      candidates: merged,
      transcript: widget.transcript,
      planCourses: planCourses,
      planModules: planModules,
      currentSemester: widget.currentSemester,
      currentTimetableSlots: _timetable?.slots ?? const [],
      currentTimetableKnown: _timetable != null && _timetable!.slots.isNotEmpty,
    ));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (merged.isEmpty)
          _emptyCard('暂无可分析的候选课程', '请先在「跨轮汇总」拉取课程数据。'),
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
                    '缺口课程 ${advice.counts['gap'] ?? 0}｜已修 ${advice.counts['passed'] ?? 0}'
                    '｜方案外 ${advice.counts['extra'] ?? 0}'
                    '｜与课表冲突 ${advice.counts['conflict'] ?? 0}',
                    style: const TextStyle(fontSize: 12),
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
          for (final a in advice.candidates) _candidateCard(a),
        ],
        const SizedBox(height: 8),
        _aiPanel(advice),
      ],
    );
  }

  Widget _candidateCard(CandidateAnalysis a) {
    final b = a.course.base;
    final roleText = switch (a.role) {
      'gap' => '培养方案缺口课程',
      'passed' => '已修读',
      'extra' => '方案外课程',
      _ => '匹配状态未知',
    };
    final offeredText = switch (a.offeredMatch) {
      'yes' => '与方案标注开课季一致',
      'no' => '与方案标注开课季不符',
      _ => '开课季未标注',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(b.kcmc,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.bold)),
                ),
                _tag(roleText,
                    a.role == 'gap' ? Colors.blue : Colors.grey),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [
                if (b.teacher.isNotEmpty) '教师 ${b.teacher}',
                if (b.sksj.isNotEmpty) '时间 ${b.sksj}',
                if (b.cap != null || b.selected != null)
                  '容量 ${b.cap ?? '-'}/已选 ${b.selected ?? '-'}',
                offeredText,
              ].join('｜'),
              style: const TextStyle(fontSize: 12),
            ),
            if (a.planCategory != null || b.tags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
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
                    style: const TextStyle(fontSize: 12, color: Colors.red)),
              ),
            for (final n in a.notes)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(n,
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
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
    setState(() {
      _aiBusy = true;
      _aiError = null;
    });
    try {
      final client = AiClient(widget.aiConfig);
      final out = await client.chat(
        system: buildGuidanceSystemPrompt(),
        messages: [
          {
            'role': 'user',
            'content': buildUserPayload(
                advice: advice, auditReport: widget.report, question: q),
          }
        ],
      );
      if (!mounted) return;
      setState(() {
        _aiBusy = false;
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

  List<Widget> _courseCards(List<XkCourse> courses) {
    if (courses.isEmpty) return const [];
    return [
      for (final c in courses.take(120))
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${c.kcmc}${c.jxbmc.isEmpty ? '' : '（${c.jxbmc}）'}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold)),
                Text(
                  [
                    if (c.kch.isNotEmpty) '课程号 ${c.kch}',
                    if (c.teacher.isNotEmpty) c.teacher,
                    if (c.sksj.isNotEmpty) c.sksj,
                    if (c.cap != null || c.selected != null)
                      '容量 ${c.cap ?? '-'}/已选 ${c.selected ?? '-'}',
                  ].join('｜'),
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      if (courses.length > 120)
        Text('仅显示前 120 条（共 ${courses.length} 条，请用搜索与汇总视图查看）',
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
    ];
  }
}
