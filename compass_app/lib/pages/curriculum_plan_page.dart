/// pages/curriculum_plan_page.dart — 培养方案页（应用内查看）。
///
/// 链路：学籍画像（课表接口，给出专业名/学院/行政班→年级）
///  → 方案目录（正方"培养方案查询"列表接口 N153020，一次拿全校方案）
///  → 客户端匹配（专业全称 × 年级；命中多条一律交给用户点选，绝不替用户猜）
///  → 结构化展示（培养目标/要求、专业核心课、学分与课堂要求）
///  + 官方培养方案 PDF（下载/系统阅读器打开，各板块修读要求解析后内嵌展示）。
/// 另内嵌：学业达成审计区（原「审计」页签并入，诉求 #13/#14/#2/#11）、
/// 本学期已选计数（诉求 #8）、本学期课表周视图（诉求 #16）；
/// 课程 chips 三态标色（2026-10-18 需求 #3）：绿=已修完（有成绩且通过计学分）、
/// 蓝=在修（本学期已选/成绩待录）、橙=有记录未获学分（未过/缓考/弃修，需重修）、
/// 灰=未修/未知——修复原「成绩单里出现过就标已修」把在修/未过混进已修的问题。
/// 逐门课程明细表已移除（任务 10：教务不普遍开放，且信息与 PDF 板块重复）；
/// 微辅修板块整支隐藏（诉求 #10：清单面向其他专业学生，与本人修读无关）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../data/credential_store.dart';
import '../data/pdf_text_extractor.dart';
import '../data/plan_models.dart';
import '../data/plan_pdf_parse.dart';
import '../data/semester.dart';
import '../data/xk_models.dart';
import '../data/xk_parse.dart';
import '../data/zju_client.dart';
import '../engine/course_state.dart';
import '../engine/plan_audit_adapter.dart';
import '../engine/selection.dart';
import '../widgets/report_view.dart';
// ScholarPalette：绿/蓝口径色与学业页同源（绿=已获学分、蓝=已选上）。
import '../widgets/scholar_cards.dart' show SectionHeader, ScholarPalette;
import '../widgets/timetable_view.dart';
import 'minor_plan_page.dart';

// 兼容既有单测/调用方从本页导入状态函数；实现已抽到 engine/course_state.dart。
export '../engine/course_state.dart'
    show
        PlanCourseEvidence,
        PlanCourseState,
        collectPlanCourseEvidence,
        resolvePassedNames,
        resolvePlanCourseStates,
        transcriptRowState;

class CurriculumPlanPage extends StatefulWidget {
  /// 底部导航用（main.dart 只引用这里，不散落中文标签）。
  static const String tabLabel = '方案';
  static const IconData tabIcon = Icons.menu_book_outlined;
  static const IconData tabIconSelected = Icons.menu_book;

  final ZjuClient client;
  final CredentialStore store;
  final bool loggedIn;

  /// 已修课程（学业页的 _courses，成绩单行含 passed/original/credit_included），
  /// 用于把课程名按「已修完/在修/未获学分」三态标定（2026-10-18 需求 #3）。
  final List<Map<String, dynamic>> transcript;
  final VoidCallback onGoSettings;

  /// 审计报告（main 持有）：非空时页面顶部内嵌「学业达成审计」区（诉求 #13）。
  final Map<String, dynamic>? report;

  /// 本学期已选课程（在修未出成绩，诉求 #8）：state=='data' 时展示计数行。
  final XkListParseResult? choosed;

  /// 设置页生效的「外语应修学分」（null=按方案原要求）。
  /// 用户反馈 #8：设置值必须同步到方案页各处（含外语类板块标题），
  /// 不能只改三色学分而方案卡还显示 PDF 原文「3-6学分」。
  final double? foreignRequiredCredits;

  /// 本学期课表（诉求 #16）：非空时页面底部内嵌周视图。
  final TimetableParseResult? timetable;

  /// 当前审计使用的 PlanFile（main 的 _auditPlan）：已选课程映射模块用。
  final Map<String, dynamic>? plan;

  /// 方案页手动选择后回传主状态（设置页/全局 AI 立即同步）。
  final ValueChanged<MatchedPlanInfo>? onPlanSelected;

  const CurriculumPlanPage({
    super.key,
    required this.client,
    required this.store,
    required this.loggedIn,
    required this.onGoSettings,
    this.transcript = const [],
    this.report,
    this.choosed,
    this.foreignRequiredCredits,
    this.timetable,
    this.plan,
    this.onPlanSelected,
  });

  @override
  State<CurriculumPlanPage> createState() => _CurriculumPlanPageState();
}

class _CurriculumPlanPageState extends State<CurriculumPlanPage> {
  final _searchCtl = TextEditingController();
  StudentProfile _profile = const StudentProfile();
  PlanMatchResult _match = PlanMatchResult.empty;
  PlanSummary? _selected;
  List<PlanSummary> _searchHits = const [];
  String? _pdfPath;
  String? _error;
  bool _loading = false;
  bool _loadingPdf = false;
  PlanPdfSections? _pdfSections; // PDF 解析出的各板块修读要求
  // 板块卡片的收起/展开状态（键 = 解析结果里的文档序下标；换方案时清空）。
  final Set<int> _collapsedSecs = {};
  final Set<int> _notesOpen = {}; // 展开了完整修读说明的板块

  @override
  void initState() {
    super.initState();
    if (widget.loggedIn) unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant CurriculumPlanPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 在设置页登录/清除数据后本页跟着切状态（否则要重启应用才刷新）。
    if (widget.loggedIn && !oldWidget.loggedIn) {
      unawaited(_load());
    } else if (!widget.loggedIn && oldWidget.loggedIn) {
      setState(() {
        _profile = const StudentProfile();
        _match = PlanMatchResult.empty;
        _selected = null;
        _searchHits = const [];
        _pdfPath = null;
        _pdfSections = null;
        _collapsedSecs.clear();
        _notesOpen.clear();
        _error = null;
      });
    }
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  bool get _canOpenExternal =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── 取数 ────────────────────────────────────────────────────────────────
  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profile =
          await widget.client.fetchStudentProfile(refresh: refresh);
      final match = await widget.client
          .matchStudentPlan(profile: profile, refresh: refresh);
      if (!mounted) return;
      final best = match.best?.plan;
      setState(() {
        _profile = profile;
        _match = match;
        _selected = best;
        _pdfPath = null;
        _pdfSections = null;
        _collapsedSecs.clear();
        _notesOpen.clear();
      });
      if (best != null) {
        final bestMatch = match.best;
        if (bestMatch != null) {
          widget.onPlanSelected?.call(MatchedPlanInfo.fromSummary(
            best,
            level: bestMatch.level,
            ambiguous: match.ambiguous,
            candidateCount: match.candidates.length,
          ));
        }
        unawaited(_ensurePdfSections(best)); // 各板块修读要求：自动拉取解析
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 各板块修读要求：静默拉取并解析官方 PDF（纯 Dart，全平台含鸿蒙）。
  /// 优先复用沙箱缓存的 PDF；失败不打扰用户（PDF 卡的手动按钮仍可重试）。
  Future<void> _ensurePdfSections(PlanSummary plan) async {
    final wanted = plan.id;
    final id = plan.jxjhh.isNotEmpty ? plan.jxjhh : plan.id;
    final name =
        'planpdf_${id.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '')}.pdf';
    try {
      List<int>? bytes = await widget.store.readBinaryCache(name);
      String? path;
      if (bytes == null) {
        bytes = await widget.client.fetchPlanPdf(plan);
        if (bytes != null) {
          path = await widget.store.saveBinaryCache(name, bytes);
        }
      } else {
        path = await widget.store.binaryCachePath(name);
      }
      if (!mounted || _selected?.id != wanted || bytes == null) return;
      final parsed = parsePlanPdfText(extractPdfText(bytes));
      if (!mounted || _selected?.id != wanted) return;
      setState(() {
        _pdfSections = parsed;
        _collapsedSecs.clear();
        _notesOpen.clear();
        if (path != null) _pdfPath ??= path;
      });
    } catch (_) {/* 静默：不阻塞主流程 */}
  }

  Future<void> _pick(PlanSummary plan) async {
      setState(() {
        _selected = plan;
        _pdfPath = null;
        _pdfSections = null;
        _collapsedSecs.clear();
        _notesOpen.clear();
        _searchHits = const [];
        _searchCtl.text = '';
      });
    final candidate = _match.candidates.firstWhere(
      (c) => c.plan.id == plan.id || c.plan.jxjhh == plan.jxjhh,
      orElse: () => PlanCandidate(
          plan, plan.levelFor(_profile.majorName), false, 0),
    );
    await widget.client.selectPlan(plan,
        level: candidate.level,
        ambiguous: _match.ambiguous,
        candidateCount: _match.candidates.length);
    widget.onPlanSelected?.call(MatchedPlanInfo.fromSummary(
      plan,
      level: candidate.level,
      ambiguous: _match.ambiguous,
      candidateCount: _match.candidates.length,
    ));
    unawaited(_ensurePdfSections(plan));
  }

  Future<void> _search(String keyword) async {
    final q = keyword.trim();
    if (q.isEmpty) {
      setState(() => _searchHits = const []);
      return;
    }
    try {
      final catalog = await widget.client.fetchPlanCatalog();
      if (!mounted) return;
      final hits = searchPlans(catalog, q, limit: 80);
      setState(() => _searchHits = hits);
      if (hits.isEmpty) _snack('方案库里没有匹配「$q」的方案');
    } catch (e) {
      _snack('搜索失败：$e');
    }
  }

  Future<void> _downloadPdf(PlanSummary plan) async {
    setState(() => _loadingPdf = true);
    try {
      final bytes = await widget.client.fetchPlanPdf(plan);
      if (bytes == null) {
        _snack('教务未返回 PDF（该方案可能未上传 PDF，或当前账号无预览权限）');
        return;
      }
      final id = plan.jxjhh.isNotEmpty ? plan.jxjhh : plan.id;
      final name =
          'planpdf_${id.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '')}.pdf';
      final path = await widget.store.saveBinaryCache(name, bytes);
      if (!mounted) return;
      if (path == null) {
        _snack('PDF 已下载但写入沙箱失败');
        return;
      }
      // PDF 解析：提取各板块修读要求（纯 Dart，零依赖，全平台含鸿蒙）
      final sections = parsePlanPdfText(extractPdfText(bytes));
      setState(() {
        _pdfPath = path;
        _pdfSections = sections;
        _collapsedSecs.clear();
        _notesOpen.clear();
      });
      _snack('方案 PDF 已保存（${(bytes.length / 1024).round()} KB）'
          '${sections.isEmpty ? '' : '，解析出 ${sections.topCount} 个一级板块、'
              '${sections.courseCount} 门课程'}');
    } catch (e) {
      _snack('PDF 下载失败：$e');
    } finally {
      if (mounted) setState(() => _loadingPdf = false);
    }
  }

  Future<void> _openPdf() async {
    final path = _pdfPath;
    if (path == null) return;
    if (!_canOpenExternal) {
      _snack('已保存到 $path（移动端请用系统文件管理器打开）');
      return;
    }
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (e) {
      _snack('调用系统阅读器失败：$e\n文件已保存在 $path');
    }
  }

  /// 修读状态证据（2026-10-18 需求 #3）：成绩单 + 审计 plan_courses +
  /// 本学期已选/课表一次收集；chips 随收起/展开频繁重建，先解析成
  /// 名称→状态表（resolvePlanCourseStates），构建时查表 O(1)。
  PlanCourseEvidence _courseEvidence() {
    return collectPlanCourseEvidence(
      transcript: widget.transcript,
      choosedNames: [
        for (final c in widget.choosed?.courses ?? const []) c.kcmc,
      ],
      timetableNames: [
        for (final r in widget.timetable?.rows ?? const []) r.name,
      ],
      reportPlanCourses: [
        for (final m in (widget.report?['summary'] as List? ?? const []))
          if (m is Map)
            ...(m['plan_courses'] as List? ?? const [])
                .cast<Map<String, dynamic>>(),
      ],
    );
  }

  // ── 视图 ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        // 学业达成审计区（诉求 #13）：并入方案页顶部（方案卡区之前）。
        // 样例/粘贴模式未登录也能出报告，故审计区不受 loggedIn 门控。
        if (report != null)
          ..._auditSection(report)
        else if (widget.loggedIn) _auditEmptyHint(),
        if (!widget.loggedIn) _notLoggedInCard(),
        if (widget.loggedIn) ...[
          _header(),
          if (_error != null) _errorCard(_error!),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (!_loading && _selected == null) _noMatchCard(),
          if (!_loading && _selected != null) ..._planSections(_selected!),
          if (!_loading) _pickerSection(),
          if (!_loading) _searchSection(),
        ],
        if (widget.timetable != null) _timetableSection(widget.timetable!),
        const SizedBox(height: 8),
        const Text('培养方案为教务网只读查询结果，仅用于本人学业规划参考；'
            '以教务系统展示为准。',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }

  /// 学业达成审计区（诉求 #3/#4）：整体可收起，默认收起，
  /// 收起时只显示「N 个板块 / M 条风险提示 / 缺口」。
  List<Widget> _auditSection(Map<String, dynamic> report) {
    final summary = (report['summary'] as List? ?? const []);
    final warnings = (report['warnings'] as List? ?? const []);
    final totals = (report['totals'] as Map? ?? const {});
    final trace = (report['trace'] as Map?) ?? const {};
    return [
      // 顶栏直达按钮（用户反馈 #9）：报告一长就找不到三色学分/风险提示，
      // 提供一键展开+滚动的入口；风险提示条数>0 带红角标。
      _revealBar(report),
      Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: ExpansionTile(
          key: PageStorageKey<String>('audit-${trace['plan'] ?? ''}'),
          controller: _auditTileCtl,
          title: const Text('学业达成审计',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          subtitle: Text(
            '三色学分达成度：${summary.length} 个板块 · '
            '风险提示：${warnings.length} 条 · '
            '缺口 ${totals['gap'] ?? '-'} 分',
            style: const TextStyle(fontSize: 12),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: ReportSection(
                report: report,
                belowTotals: _choosedLine(),
                courseEvidence: _courseEvidence(),
                modulesRevealToken: _revealModules,
                warningsRevealToken: _revealWarnings,
                modulesKey: _modulesKey,
                warningsKey: _warningsKey,
              ),
            ),
          ],
        ),
      ),
    ];
  }

  String? _revealModules; // 三色学分直达令牌（每次点击变化 → 瓦片重建并展开）
  String? _revealWarnings; // 风险提示直达令牌
  // 审计区外层瓦片：直达按钮经 controller 强制展开。
  // 注意：保留 ExpansionTileController（3.41+ 的 ExpansibleController 在
  // flutter-ohos 3.27 不存在，HAP CI 会编译失败——见 [[ohos-327-api-compat-trap]]）。
  // ignore: deprecated_member_use
  final ExpansionTileController _auditTileCtl = ExpansionTileController();
  final GlobalKey _modulesKey = GlobalKey(debugLabel: 'report-modules-anchor');
  final GlobalKey _warningsKey = GlobalKey(debugLabel: 'report-warnings-anchor');

  /// 顶栏两按钮行：点按 → 先展开审计区，再给对应瓦片发"直达令牌"重建展开，
  /// 下一帧 ensureVisible 滚动到位。无审计数据时整行不渲染（调用侧已门控）。
  Widget _revealBar(Map<String, dynamic> report) {
    final warnings = (report['warnings'] as List? ?? const []);
    void reveal(bool modules) {
      setState(() {
        // 外层审计瓦片先展开，目标子瓦片再收令牌重建（下帧才进树）。
        _auditTileCtl.expand();
        if (modules) {
          _revealModules = 'm${DateTime.now().microsecondsSinceEpoch}';
        } else {
          _revealWarnings = 'w${DateTime.now().microsecondsSinceEpoch}';
        }
      });
      // 空句柄重试滚动定位：外层展开 + KeyedSubtree 重建需要额外帧。
      void scroll(int attempt) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = (modules ? _modulesKey : _warningsKey).currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(ctx,
                alignment: 0.06, duration: const Duration(milliseconds: 260));
          } else if (attempt < 3) {
            scroll(attempt + 1);
          }
        });
      }

      scroll(0);
    }

    Widget chip({required String label,
        required IconData icon,
        required Color color,
        required VoidCallback onTap,
        int badge = 0}) {
      final content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ],
      );
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ActionChip(
          onPressed: onTap,
          avatar: badge > 0
              ? Badge.count(count: badge, backgroundColor: Colors.red, child: const SizedBox.shrink())
              : null,
          label: content,
          visualDensity: VisualDensity.compact,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9), side: BorderSide(color: color.withValues(alpha: 0.45))),
        ),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            chip(
                label: '三色学分',
                icon: Icons.donut_small_outlined,
                color: Colors.indigo,
                onTap: () => reveal(true)),
            chip(
                label: '风险提示',
                icon: Icons.warning_amber_rounded,
                color: Colors.red.shade700,
                badge: warnings.length,
                onTap: () => reveal(false)),
          ],
        ),
      ),
    );
  }

  /// 审计报告未生成的空态（诉求 #13）：灰字提示 + 去设置按钮。
  Widget _auditEmptyHint() => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('审计报告未生成：到「设置」页运行审计（登录教务或样例均可）',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: widget.onGoSettings,
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: const Text('去设置'),
              ),
            ],
          ),
        ),
      );

  /// 本学期已选（在修未出成绩）明细（诉求 #8/#10）：
  /// 默认收起，展开后列出课程与对应方案模块；不计入已取得学分/GPA。
  Widget? _choosedLine() {
    final c = widget.choosed;
    if (c == null) return null;
    if (c.state == 'unavailable') {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
        child: Text(
            '本学期已选暂不可用${c.issues.isEmpty ? '' : '：${c.issues.first}'}',
            style: const TextStyle(fontSize: 11, color: Colors.orange)),
      );
    }
    if (c.state == 'empty' || c.courses.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(4, 4, 4, 0),
        child: Text('本学期已选：0 门（接口明确返回空）',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
      );
    }
    final xf = c.courses.fold<double>(0, (n, x) => n + (x.xf ?? 0));
    // 用户反馈：本学期已选里既有已出分、已获学分的课，也有仅已选上的课。
    // 与成绩页共用 choosedCourseTranscriptState，两页必须同口径。
    final stateOf = <String, PlanCourseState?>{
      for (final x in c.courses)
        '${x.kch}\u0000${x.kcmc}': choosedCourseTranscriptState(
            courseId: x.kch, name: x.kcmc, transcript: widget.transcript),
    };
    PlanCourseState? stateOfCourse(XkCourse x) => stateOf['${x.kch}\u0000${x.kcmc}'];
    final earnedCourses = c.courses
        .where((x) => stateOfCourse(x) == PlanCourseState.earned)
        .toList();
    final activeCourses = c.courses
        .where((x) => stateOfCourse(x) != PlanCourseState.earned)
        .toList();
    final earnedNames = {for (final x in earnedCourses) x.kcmc};
    final earnedXf =
        earnedCourses.fold<double>(0, (n, x) => n + (x.xf ?? 0));
    final activeRows = selectedRowsOf(c)
        .where((r) => !earnedNames.contains('${r['name'] ?? ''}'))
        .toList();
    final byModule = widget.plan == null
        ? const <String, double>{}
        : selectedCreditsByModule(activeRows, widget.plan!);
    final moduleNames = <String, String>{
      for (final m in (widget.plan?['modules'] as List? ?? const []))
        if (m is Map && m['module_id'] != null)
          '${m['module_id']}': '${m['module_path'] ?? m['module_id']}',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 6),
        initiallyExpanded: false,
        title: const Text('本学期已选（已获学分与在修分开）',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        subtitle: Text(
            '${c.courses.length} 门 / ${xf.toStringAsFixed(1)} 学分'
            '${earnedCourses.isEmpty ? ' · 均为在修（未出成绩）' : ' · 已获 ${earnedCourses.length} 门 ${earnedXf.toStringAsFixed(1)} 分 / 在修 ${activeCourses.length} 门'}'),
        children: [
          for (final x in c.courses)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                stateOfCourse(x) == PlanCourseState.earned
                    ? Icons.check_circle_outline
                    : Icons.schedule,
                size: 18,
                color: stateOfCourse(x) == PlanCourseState.earned
                    ? Colors.green
                    : ScholarPalette.selectedBlue,
              ),
              title: Text(x.kcmc, style: const TextStyle(fontSize: 12.5)),
              subtitle: Text(<String>[
                choosedCreditLabel(stateOfCourse(x)),
                if (x.xf != null) '${x.xf} 学分',
                if (x.teacher.isNotEmpty) x.teacher,
                if (x.sksj.isNotEmpty) x.sksj,
                if (x.cdmc.isNotEmpty) x.cdmc,
              ].join(' · '), style: const TextStyle(fontSize: 11)),
            ),
          if (byModule.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final e in byModule.entries)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text(
                          '${moduleNames[e.key] ?? e.key} 在修 ${_num(e.value)} 分',
                          style: const TextStyle(fontSize: 10.5)),
                    ),
                ],
              ),
            ),
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text(
                '已获学分的课已计入上方成绩/已取得学分；在修课程未出分，不计入。',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  /// 未登录教务网的引导卡（审计区仍可在上方展示，见 build）。
  Widget _notLoggedInCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.menu_book_outlined, size: 44),
              const SizedBox(height: 12),
              const Text('未登录教务网，无法按学号匹配培养方案',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('到「设置」页输入学号与统一身份认证密码并拉取一次，'
                  '本页会按你的专业名与年级自动匹配培养方案。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: widget.onGoSettings,
                icon: const Icon(Icons.settings_outlined),
                label: const Text('去设置页登录'),
              ),
            ],
          ),
        ),
      );

  /// 本学期课表（诉求 #16）：教务模式拉到的周视图，内嵌方案页底部。
  /// rows 为空时显示 issues 首条或「本学期暂无课表」灰字（如实降级，不猜）。
  /// 有课表时补一行灰字说明口径（2026-10-18 需求 #3）：课表课程即「在修」，
  /// 成绩未出前不计入已取得学分（周视图自身按课程名配色，不占用三态标色）。
  Widget _timetableSection(TimetableParseResult tt) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader('本学期课表'),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: tt.rows.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: Center(
                        child: Text(
                            tt.issues.isEmpty ? '本学期暂无课表' : tt.issues.first,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey)),
                      ),
                    )
                  : TimetableView(rows: tt.rows),
            ),
          ),
          if (tt.rows.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text('课表所列均为本学期在修课程；成绩未出前不计入已取得学分。',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ),
        ],
      );

  Widget _header() {
    final parts = <String>[
      if (_profile.college.isNotEmpty) _profile.college,
      if (_profile.adminClass.isNotEmpty) _profile.adminClass,
      if (_match.grade != null) '${_match.grade} 级',
      if (widget.client.lastFromCache) '数据来自缓存',
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.menu_book, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _profile.majorName.isEmpty
                        ? '未识别到专业（点右侧重新匹配，或在下方手动搜索）'
                        : '专业：${_profile.majorName}',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            if (parts.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(parts.join(' · '),
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _loading ? null : () => _load(refresh: true),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('重新匹配'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorCard(String message) => Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.error_outline, size: 18),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(message, style: const TextStyle(fontSize: 12))),
            ],
          ),
        ),
      );

  Widget _noMatchCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('未自动匹配到培养方案',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              for (final n in _match.notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('· $n', style: const TextStyle(fontSize: 12)),
                ),
              const SizedBox(height: 4),
              const Text('可在下方搜索框直接输专业名或教学计划号手动选取。',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        ),
      );

  List<Widget> _planSections(PlanSummary p) {
    // 修读状态标定（2026-10-18 需求 #3）：绿=已修完 / 蓝=在修 / 橙=未获学分需重修，
    // 从原「已修」口径拆分（原逻辑把成绩单里出现过的课程一律标已修，
    // 在修未出分/未通过的课混在其中）。全等 + 模糊 ≥0.85 同原口径，
    // 一次性解析成 名称→状态 表：chips 随收起/展开频繁重建，查表 O(1)。
    final states = resolvePlanCourseStates([
      ...p.zyhxkc,
      ...p.zyhxsjkc,
      ...p.qywkc,
    ], _courseEvidence());
    return [
      _card('方案概览', [
        _kv('专业', p.zymc),
        if (p.zydm.isNotEmpty) _kv('专业代码', p.zydm),
        if (p.xymc.isNotEmpty) _kv('开课学院', p.xymc),
        if (p.zydlmc.isNotEmpty) _kv('专业大类', p.zydlmc),
        _kv('适用年级', p.synj.isEmpty ? '未标注' : '${p.synj} 级'),
        if (p.dlbsmc.isNotEmpty) _kv('方案类别', p.dlbsmc),
        if (p.tjzt.isNotEmpty) _kv('审核状态', p.tjzt),
        if (p.jxjhh.isNotEmpty) _kv('教学计划号', p.jxjhh),
        if (p.xkzylb.isNotEmpty) _kv('选考专业类别', p.xkzylb),
        if (p.gjzymc.isNotEmpty) _kv('国标专业名称', p.gjzymc),
        if (_profile.adminClass.isNotEmpty) _kv('行政班', _profile.adminClass),
        if (_match.notes.isNotEmpty) ...[
          const SizedBox(height: 6),
          for (final n in _match.notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text('· $n',
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.primary)),
            ),
        ],
      ]),
      _card('学分与学制', [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _stat('最低毕业学分', p.creditsLabel),
            if (p.kcdlxfyq != null)
              _stat('课程总学分要求', _num(p.kcdlxfyq!)),
            if (p.qdkcxf != null) _stat('前置课程学分', _num(p.qdkcxf!)),
            if (p.xz.isNotEmpty) _stat('学制', '${p.xz} 年'),
            if (p.syxw.isNotEmpty) _stat('授予学位', p.syxw),
            if (p.xqmc.isNotEmpty) _stat('校区', p.xqmc),
            if (p.dektxf != null) _stat('第二课堂', '${_num(p.dektxf!)} 学分'),
            if (p.dektxf3 != null) _stat('第三课堂', '${_num(p.dektxf3!)} 学分'),
            if (p.dektxf4 != null) _stat('第四课堂', '${_num(p.dektxf4!)} 学分'),
            if (p.fxxf != null) _stat('辅修学分', _num(p.fxxf!)),
            if (p.ezyxf != null) _stat('双专业学分', _num(p.ezyxf!)),
            if (p.exwxf != null) _stat('双学位学分', _num(p.exwxf!)),
            if (p.wfxxf != null) _stat('微辅修学分', _num(p.wfxxf!)),
            if (p.rs != null) _stat('计划人数', '${p.rs}'),
            if (p.sjrs != null) _stat('实际人数', '${p.sjrs}'),
          ],
        ),
      ]),
      if (p.pymb.isNotEmpty) _expandCard('培养目标', p.pymb),
      if (p.pyyq.isNotEmpty) _expandCard('培养要求', p.pyyq),
      if (p.zyhxkc.isNotEmpty)
        _card('专业核心课程（${p.zyhxkc.length} 门）', [
          _chips(p.zyhxkc, states),
          const SizedBox(height: 6),
          _stateLegend(),
        ]),
      if (p.zyhxsjkc.isNotEmpty)
        _card('专业核心实践课程（${p.zyhxsjkc.length} 门）',
            [_chips(p.zyhxsjkc, states)]),
      if (p.qywkc.isNotEmpty)
        _card('前沿与荣誉课程（${p.qywkc.length} 门）', [_chips(p.qywkc, states)]),
      if (_pdfSections != null && _pdfSections!.sections.isNotEmpty)
        _pdfSectionsCard(),
      if (p.bz.isNotEmpty) _expandCard('辅修/微辅修说明', p.bz),
      // 微辅修面向其他专业（诉求 #10）：独立窗口，选专业后拉该专业方案的微辅修部分。
      _card('其他专业微辅修', [
        const Text('微辅修是面向其他专业的迷你辅修项目。本方案只列本专业的微辅修要求；'
            '想修其他专业的微辅修，可在此搜索该专业方案并查看其微辅修课程清单。',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => MinorPlanPage(
                    client: widget.client,
                    store: widget.store,
                    loggedIn: widget.loggedIn,
                    onGoSettings: widget.onGoSettings,
                    transcript: widget.transcript,
                    choosed: widget.choosed,
                  ))),
          icon: const Icon(Icons.school_outlined),
          label: const Text('浏览其他专业的微辅修方案'),
        ),
      ]),
      _pdfCard(p),
    ];
  }

  /// 各板块修读要求（PDF 解析，诉求 #14）：整块一张 Card，去掉原先
  /// 「卡外套大标题、卡内再套卡」的嵌套。卡内首行大标题；每个一级板块是
  /// 独立可折叠块（点标题收起/展开），板块之间用 Divider 分隔；
  /// 课程 chips 优先展示，修读说明默认收起、点「展开完整修读说明」再看；
  /// 子层级保持 _subBlock 样式。
  Widget _pdfSectionsCard() {
    final ps = _pdfSections!;
    // 修读状态标定与 _planSections 同口径（全等 + 模糊 ≥0.85 → 三态，
    // 2026-10-18 需求 #3），对 PDF 全部板块的课程名一次性解析；认定类板块
    // 补出的成绩单课程名一并纳入解析范围，收起/展开重绘时只做查表。
    final certifiedNames = <String>{
      for (final s in ps.sections)
        for (final r in certifiedRowsForSection(s, widget.transcript)) r.name,
    };
    final states = resolvePlanCourseStates(
      [
        for (final s in ps.sections) ...s.courses.map((c) => c.name),
        ...certifiedNames,
      ],
      _courseEvidence(),
    );
    final roots = _buildSectionTree(ps.sections);
    // 微辅修板块整支剔除（诉求 #10）：索引保持文档序，收起/展开状态键不受影响。
    _pruneMinorSections(roots);
    // 毕业要求/章节总述伪板块剔除（用户反馈 #3）：这些块无课程、无学分标注、
    // 无子块，只是培养方案前言的总体要求文字，必须不占板块位；展示从
    // 课程修读要求开始。
    _pruneEmptyRequirementRoots(roots);
    if (roots.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('各板块修读要求',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const Text('来自官方培养方案 PDF',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            _stateLegend(),
            if (ps.qualityNotes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('⚠️ ${ps.qualityNotes.join('；')}',
                    style: TextStyle(
                        fontSize: 11, color: Theme.of(context).colorScheme.error)),
              ),
            for (var i = 0; i < roots.length; i++) ...[
              if (i > 0) const Divider(height: 16), // 一级板块之间的分隔
              _moduleBlock(roots[i], states),
            ],
          ],
        ),
      ),
    );
  }

  /// 一级板块：标题行（带 ▾ 整块收起/展开、橙色「N选M」规则徽章）+ 内容；
  /// 不再各套 Card（诉求 #14）。
  /// 2026-10-18 展示重构 #3：标题下的灰字并行选项提示与前置总述 note
  /// 一并移除（并行语义由「规则：…」徽章与下方审计达成行承载，不重复），
  /// 展开体从课程修读要求开始：课程 chips → 认定 chips → 子板块 →
  /// 过滤后的板块级修读说明。
  Widget _moduleBlock(_SecNode node, Map<String, PlanCourseState> states) {
    final s = node.section;
    final open = !_collapsedSecs.contains(node.index);
    final courses = _countCourses(node);
    final primary = Theme.of(context).colorScheme.primary;
    final badge = choiceBadgeText(s);
    final alt = node.children.isEmpty
        ? null
        : detectAlternativeModules(
            [for (final k in node.children) k.section], s.notes.join('\n'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _toggleCollapsed(node.index),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 8, 2, 4),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: open ? 0 : -0.25,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(Icons.expand_more, size: 22, color: primary),
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Wrap(
                    // 标题与徽章同行放不下时自动换行（窄屏不溢出）。
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 2,
                    children: [
                      Text(_stripParens(s.title),
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              height: 1.25)),
                      if (badge != null) _choiceBadge(badge),
                    ],
                  ),
                ),
                if (_creditsLabel(s) != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(_creditsLabel(s)!,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: primary)),
                  ),
                if (courses > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text('$courses 门',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey)),
                  ),
              ],
            ),
          ),
        ),
        // 灰字「并行选项」提示整段移除（展示重构 #3）：并行语义由
        // 「规则：…」徽章 + 审计达成行（_groupStatusLine）承载。
        if (alt != null && _groupRowFor(s) != null)
          _groupStatusLine(_groupRowFor(s)!),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 2, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (s.courses.isNotEmpty) ...[
                  _courseChips(s.courses, states),
                  const SizedBox(height: 6),
                ],
                ..._selectedOnlyChips(s, states),
                ..._certifiedChipBlock(s, states),
                for (final k in node.children) _subBlock(k, states),
                ..._notesBlock(s, node.index),
              ],
            ),
          ),
      ],
    );
  }

  /// 二级及更深板块：卡内的可收起小节（同样带「N选M」规则徽章）。
  Widget _subBlock(_SecNode node, Map<String, PlanCourseState> states) {
    final s = node.section;
    final open = !_collapsedSecs.contains(node.index);
    final courses = _countCourses(node);
    final primary = Theme.of(context).colorScheme.primary;
    final badge = choiceBadgeText(s);
    // 二级及更深的「以下 N 个模块任选其一 / 多选一」也要显式提示，
    // 否则用户只看到若干子块，不知道满足其一即可（用户反馈 #3）。
    final alt = node.children.isEmpty
        ? null
        : detectAlternativeModules(
            [for (final k in node.children) k.section],
            [
              ...s.notes,
              for (final k in node.children) ...k.section.notes,
            ].join('\n'));
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => _toggleCollapsed(node.index),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  AnimatedRotation(
                    turns: open ? 0 : -0.25,
                    duration: const Duration(milliseconds: 150),
                    child: const Icon(Icons.expand_more,
                        size: 18, color: Colors.grey),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 6,
                      runSpacing: 2,
                      children: [
                        Text(_stripParens(s.title),
                            style: const TextStyle(
                                fontSize: 13.5, fontWeight: FontWeight.w700)),
                        if (badge != null) _choiceBadge(badge),
                      ],
                    ),
                  ),
                  if (_creditsLabel(s) != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(_creditsLabel(s)!,
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: primary)),
                    ),
                  if (courses > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text('$courses 门',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey)),
                    ),
                ],
              ),
            ),
          ),
          if (alt != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 2, 4),
              child: Text('以下 ${alt.optionCount} 个模块为并行选项，满足其一即可',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ),
          if (open)
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (s.courses.isNotEmpty) ...[
                    _courseChips(s.courses, states),
                    const SizedBox(height: 6),
                  ],
                  ..._selectedOnlyChips(s, states),
                  ..._certifiedChipBlock(s, states),
                  for (final k in node.children) _subBlock(k, states),
                  ..._notesBlock(s, node.index),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 修读说明：默认收起，点「展开完整修读说明」再看（文字不大段平铺）。
  List<Widget> _notesBlock(PdfModuleSection s, int idx) {
    // 展示重构 #3：总体要求/整章总述段落不在此展示（isOverallRequirement），
    // 修读说明只留板块级课程要求；引擎审计仍读完整 notes，口径不受影响。
    final notes = [for (final n in s.notes) if (!isOverallRequirement(n)) n];
    if (notes.isEmpty) return const [];
    final open = _notesOpen.contains(idx);
    final primary = Theme.of(context).colorScheme.primary;
    return [
      InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _toggleNotes(idx),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(open ? Icons.expand_less : Icons.expand_more,
                  size: 16, color: primary),
              const SizedBox(width: 2),
              Text(open ? '收起修读说明' : '展开完整修读说明（${notes.length} 条）',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: primary)),
            ],
          ),
        ),
      ),
      if (open)
        Padding(
          padding: const EdgeInsets.only(left: 6, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final n in notes)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('· $n',
                      style: TextStyle(
                          fontSize: 11.5,
                          height: 1.45,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.72))),
                ),
            ],
          ),
        ),
    ];
  }

  /// 并列选项组的审计结果（按组 path 对齐 summary 的组行）。
  /// 用于在方案页直接显示「当前达成哪个选项」，体现选择关系（#4）。
  Map<String, dynamic>? _groupRowFor(PdfModuleSection s) {
    final summary = widget.report?['summary'];
    if (summary is! List) return null;
    for (final r in summary) {
      if (r is Map &&
          r['alternative_group'] == true &&
          '${r['module_path'] ?? ''}'.trim() == s.label.trim()) {
        return r.cast<String, dynamic>();
      }
    }
    return null;
  }

  Widget _groupStatusLine(Map<String, dynamic> g) {
    final options =
        (g['options'] as List? ?? const []).cast<Map<String, dynamic>>();
    final best = options.isEmpty ? null : options.first;
    final color = '${g['color'] ?? ''}';
    final earned = (g['earned'] as num?)?.toDouble() ?? 0;
    final required = (g['required'] as num?)?.toDouble() ?? 0;
    final c = color == 'green'
        ? ScholarPalette.earnedGreen
        : (color == 'yellow' ? const Color(0xFFF59E0B) : Colors.red);
    final text = color == 'green'
        ? '已达成：${best?['title'] ?? '其中一个选项'}（${_num(earned)}/${_num(required)} 学分）'
        : '尚未达成任一选项；最优选项「${best?['title'] ?? '-'}」还差 '
            '${_num(((g['gap'] as num?)?.toDouble() ?? 0))} 学分';
    // 用户澄清（2026-10）：跨专业学习 = 参加其他专业的微辅修，它和三选一里
    // 其余选项是「任选其一」，不是三门叠加；组内出现微辅修时补一行等价说明。
    final hasMinorOption = options.any((o) =>
        '${o['title'] ?? ''}'.contains('微辅修') ||
        '${o['title'] ?? ''}'.contains('跨专业'));
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 2, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text,
              style:
                  TextStyle(fontSize: 11.5, color: c, fontWeight: FontWeight.w600)),
          if (hasMinorOption)
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Text(
                  '跨专业学习即修读其他专业的微辅修；本组任选其一计一次要求学分，不重复计算',
                  style: TextStyle(fontSize: 10.5, color: Colors.grey)),
            ),
        ],
      ),
    );
  }

  /// 板块学分文案：外语类优先显示设置页生效值（#8），其余照方案原文；
  /// 认定类板块学分写在修读说明里（#6：「其他必修环节学分没和其他模块一样
  /// 样式显示」）——creditsRaw 为空时按 notes 声明学分兜底同款式展示。
  String? _creditsLabel(PdfModuleSection s) {
    if (s.isCountRule) {
      return s.creditsRaw.trim().isEmpty ? null : '${s.creditsRaw} 门';
    }
    final f = widget.foreignRequiredCredits;
    if (f != null && isForeignSection(s)) {
      // 0 = 免修（用户反馈 #10：2026 级起 L3 免修；方案有明确课表时以方案为准）
      return f == 0 ? '免修' : '应修 ${_num(f)} 学分';
    }
    if (s.creditsRaw.trim().isEmpty) {
      final declared = s.declaredCreditsFromNotes;
      return declared == null ? null : '应修 $declared 学分';
    }
    return '${s.creditsRaw} 学分';
  }

  /// 已选但不在方案课程表里的课程（#9）：外语类最常见（方案只写
  /// 「L1应修6学分」不给课表）。按课名/类别归入外语板块，蓝色「已选」。
  List<Widget> _selectedOnlyChips(
      PdfModuleSection s, Map<String, PlanCourseState> states) {
    final choosed = widget.choosed;
    if (choosed == null || !isForeignSection(s)) return const [];
    final planNames = <String>{for (final c in s.courses) c.name.trim()};
    final seen = <String>{};
    final chips = <Widget>[];
    for (final c in choosed.courses) {
      final n = c.kcmc.trim();
      if (n.isEmpty || planNames.contains(n) || !seen.add(n)) continue;
      final hit = n.contains('英语') ||
          n.contains('外语') ||
          c.categories.any((x) => x.contains('外语') || x.contains('英语'));
      if (!hit) continue;
      chips.add(_stateChip(
        '$n ${_num(c.xf ?? 0)}分 · 已选（方案外）',
        PlanCourseState.active,
        fontSize: 11,
        hPad: 7,
        vPad: 3,
      ));
    }
    if (chips.isEmpty) return const [];
    return [
      Wrap(spacing: 5, runSpacing: 4, children: chips),
      const SizedBox(height: 6),
    ];
  }

  /// 方案课程 chips（PDF 板块课程行）：按 名称→状态 表标色，
  /// 角标文字区分 已修完/在修/未过需重修（2026-10-18 需求 #3）。
  Widget _courseChips(
      List<PdfCourseRow> courses, Map<String, PlanCourseState> states) {
    return Wrap(
      spacing: 5,
      runSpacing: 4,
      children: [
        for (final c in courses)
          _stateChip(
            '${c.name} ${_num(c.credits)}分'
            '${c.semester.isNotEmpty ? ' ${prettySemester(c.semester, gradeYear: _selected?.gradeYear ?? 0)}' : ''}',
            states[c.name] ?? PlanCourseState.unknown,
            fontSize: 11,
            hPad: 7,
            vPad: 3,
          ),
      ],
    );
  }

  /// 认定类板块（美育/劳育/创新创业/心理健康，#13）在 PDF 里只有说明文字、
  /// 无课程表：把成绩单里同类课程（certifiedCategoryOf 命中该板块类别）显示为
  /// 补充 chips。板块自带课程表时 certifiedRowsForSection 返回空，不重复。
  /// 状态仍查 states 表（这些课程名已在 _pdfSectionsCard 纳入解析范围）：
  /// 已获学分绿 / 待录蓝 / 未获学分橙，不再一律标已修（需求 #3）。
  List<Widget> _certifiedChipBlock(
      PdfModuleSection s, Map<String, PlanCourseState> states) {
    final rows = certifiedRowsForSection(s, widget.transcript);
    if (rows.isEmpty) return const [];
    return [
      _courseChips(rows, states),
      const SizedBox(height: 6),
    ];
  }

  /// 三态图例（一行灰字，窄屏自动软换行）：与 chips 底色/角标一一对应。
  Widget _stateLegend() => const Padding(
        padding: EdgeInsets.only(top: 2),
        child: Text(
          '图例：绿=已修完（有成绩且通过计学分）· 蓝=在修（本学期已选/成绩待录）· '
          '橙=有记录未获学分（未过/缓考/弃修，需重修）· 灰=未修/未知',
          style: TextStyle(fontSize: 11, color: Colors.grey),
        ),
      );

  /// 「N选M」等修读约束的小徽章（诉求 #2/#11）：纯展示，规则识别在
  /// choiceBadgeText（引擎适配器的 detectChoiceRule），这里只负责样式。
  Widget _choiceBadge(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: Colors.orange.withValues(alpha: 0.14),
        ),
        child: Text(text,
            style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: Colors.orange)),
      );

  void _toggleCollapsed(int idx) {
    setState(() {
      if (!_collapsedSecs.remove(idx)) _collapsedSecs.add(idx);
    });
  }

  void _toggleNotes(int idx) {
    setState(() {
      if (!_notesOpen.remove(idx)) _notesOpen.add(idx);
    });
  }

  /// 「其他必修环节（认定型学分）」→「其他必修环节」。
  static final RegExp _parenRe = RegExp(r'[（(][^（（）)]*[）)]');
  String _stripParens(String title) {
    final t = title.replaceAll(_parenRe, '').trim();
    return t.isEmpty ? title : t;
  }

  int _countCourses(_SecNode node) =>
      node.section.courses.length +
      node.children.fold(0, (n, k) => n + _countCourses(k));

  Widget _pdfCard(PlanSummary p) => _card('官方培养方案 PDF', [
        const Text('教务"预览"按钮同款文件，含完整课程表与学期安排。',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: _loadingPdf ? null : () => _downloadPdf(p),
              icon: _loadingPdf
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download_outlined, size: 18),
              label: Text(_loadingPdf ? '获取中…' : '获取 PDF'),
            ),
            if (_pdfPath != null && _canOpenExternal)
              OutlinedButton.icon(
                onPressed: _openPdf,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('用系统阅读器打开'),
              ),
            if (_pdfPath != null)
              TextButton.icon(
                onPressed: () => _snack('已保存到 $_pdfPath'),
                icon: const Icon(Icons.folder_outlined, size: 18),
                label: const Text('保存路径'),
              ),
          ],
        ),
        if (_pdfPath != null) ...[
          const SizedBox(height: 6),
          SelectableText(_pdfPath!,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ]);

  /// 候选方案列表（需求 #4：可收起）。
  /// 有歧义时默认展开提醒用户确认；选定后可手动收起，只留标题行。
  Widget _pickerSection() {
    final cs = _match.candidates;
    if (cs.length <= 1) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: _match.ambiguous && _selected == null,
        dense: true,
        title: Text('候选方案（${cs.length}）· 点选即切换',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        subtitle: _selected != null
            ? Text('当前：${_selected!.zymc} ${_selected!.synj} 级',
                style: const TextStyle(fontSize: 11))
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_match.ambiguous)
                  Text('⚠️ 存在多条相近方案，已按匹配强度排序，请确认哪条是本人方案。',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.error)),
                for (final c in cs) _tile(c.plan, subtitle: c.reason),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchSection() => _card('手动搜索方案', [
        TextField(
          controller: _searchCtl,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.search, size: 18),
            hintText: '专业名 / 学院 / 专业代码 / 教学计划号',
          ),
          onSubmitted: _search,
          onChanged: (v) {
            if (v.trim().isEmpty && _searchHits.isNotEmpty) {
              setState(() => _searchHits = const []);
            }
          },
        ),
        const SizedBox(height: 6),
        const Text('方案库含全校各年级方案；找不到就换个关键词（如只输"信息安全"）。',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
        if (_searchHits.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final p in _searchHits) _tile(p),
        ],
      ]);

  Widget _tile(PlanSummary plan, {String? subtitle}) {
    final selected = _selected?.id == plan.id;
    return InkWell(
      onTap: () => _pick(plan),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: selected
              ? Theme.of(context).colorScheme.secondaryContainer
              : null,
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${plan.zymc}'
                    '${plan.synj.isEmpty ? '' : '（${plan.synj} 级）'}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  if (plan.subtitle.isNotEmpty)
                    Text(plan.subtitle,
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey)),
                  if (subtitle != null)
                    Text(subtitle,
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 小组件 ──────────────────────────────────────────────────────────────
  Widget _card(String title, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(title,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      );

  Widget _expandCard(String title, String body) => Card(
        child: ExpansionTile(
          title: Text(title,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body, style: const TextStyle(fontSize: 12, height: 1.5)),
          ],
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 108,
              child: Text(k,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
            Expanded(
                child: Text(v, style: const TextStyle(fontSize: 12.5))),
          ],
        ),
      );

  Widget _stat(String label, String value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            Text(value,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.bold)),
          ],
        ),
      );

  Widget _chips(List<String> names, Map<String, PlanCourseState> states) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final n in names)
          _stateChip(n, states[n] ?? PlanCourseState.unknown),
      ],
    );
  }

  /// 三态课程 chip（2026-10-18 需求 #3）：底色 + 文字角标区分修读状态，
  /// 口径色与学业页/审计报告一致——绿=已获学分、蓝=已选上、
  /// 橙=有记录未获学分（对齐报告三色黄 0xFFF59E0B）；灰=未修/未知（宁缺勿猜）。
  /// maxLines:1，超长省略号收尾（窄屏不撑爆卡片）。
  Widget _stateChip(
    String base,
    PlanCourseState state, {
    double fontSize = 12,
    double hPad = 8,
    double vPad = 4,
  }) {
    final (Color bg, Color fg, String mark) = switch (state) {
      PlanCourseState.earned => (
          ScholarPalette.earnedGreen.withValues(alpha: 0.15),
          ScholarPalette.earnedGreen,
          '（已修完）',
        ),
      PlanCourseState.active => (
          ScholarPalette.selectedBlue.withValues(alpha: 0.13),
          ScholarPalette.selectedBlue,
          '（在修）',
        ),
      PlanCourseState.noCredit => (
          kPlanNoCreditColor.withValues(alpha: 0.16),
          kPlanNoCreditColor,
          '（未过需重修）',
        ),
      PlanCourseState.unknown => (
          Theme.of(context).colorScheme.surfaceContainerHighest,
          Theme.of(context).colorScheme.onSurface,
          '',
        ),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: bg,
      ),
      child: Text(
        '$base$mark',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: fontSize, color: fg),
      ),
    );
  }

  static String _num(double v) => (v - v.roundToDouble()).abs() < 1e-9
      ? v.roundToDouble().toString()
      : v.toString();
}

/// 板块标题行的「N选M」徽章文案（诉求 #2/#11）：说明命中修读选择约束
/// （二选一 / N 选 M / 至少 X 门 / 至少 Y 学分）时返回「规则：…」，
/// 未命中返回 null（宁缺勿猜）。顶层纯函数，供 UI 与单测共用
/// （test/plan_page_badges_test.dart）。
String? choiceBadgeText(PdfModuleSection s) {
  final rule = detectChoiceRule(s.notes.join(' '));
  if (rule == null) return null;
  // #3：把「选一门即满足整块」说清楚，避免用户以为要把整组修完。
  if (rule.singlePick) return '规则：${rule.text}（选 1 门即满足整块）';
  return '规则：${rule.text}';
}

/// 橙=有记录未获学分（对齐审计报告三色黄 0xFFF59E0B）。
const Color kPlanNoCreditColor = Color(0xFFF59E0B);

/// 「微辅修」板块判据（顶层纯函数，供 UI 与单测共用；诉求 #10 / 任务 7）：
/// 板块标题或上级链（parentPath，含全部祖先标题）出现「微辅修」即命中。
/// 理由：本专业方案 PDF 里的微辅修清单是面向其他专业学生的修读要求，
/// 与本人修读无关，故整支（含其子块）不渲染；「其他专业微辅修」入口卡
/// （MinorPlanPage 跳转卡）保留不动。
bool isMinorElectiveSection(PdfModuleSection s) =>
    s.title.contains('微辅修') || s.parentPath.contains('微辅修');

/// 外语类板块判据（与 engine/audit.dart isForeignLangModule 同口径）：
/// 标题或上级链命中「外语/英语」。用于把设置页「外语应修学分」同步到
/// 方案页显示（#8），以及把方案外已选外语课补成蓝色 chip（#9）。
bool isForeignSection(PdfModuleSection s) =>
    s.title.contains('外语') ||
    s.title.contains('英语') ||
    s.parentPath.contains('外语') ||
    s.parentPath.contains('英语');

/// 认定类板块无课程表时，从成绩单里找可标亮「已修」的课程行（顶层纯函数，
/// 供 UI 与单测共用；#13）。判定与引擎适配器同源：certifiedSectionCategory
/// 认板块（level≤3、标题命中美育/劳育/创新创业/心理健康），certifiedCategoryOf
/// 认课程；板块自带课程表时不重复补（宁缺勿猜），同名课（重修）只取一次。
///
/// 需求 #1（2026-10-18）：认定型课程此前只按课名关键词归类，漏掉了名字里
/// 不含关键词、但成绩单 category 字段已标注该认定类的课程（如「民乐演奏」
/// 被教务归美育类却不含美育关键词）。故增加类别兜底：行的 category 归入的
/// 类别等于板块认定类别时一并纳入。
List<PdfCourseRow> certifiedRowsForSection(
    PdfModuleSection s, List<Map<String, dynamic>> transcript) {
  final cat = certifiedSectionCategory(s);
  if (cat == null || s.courses.isNotEmpty) return const [];
  final out = <PdfCourseRow>[];
  final used = <String>{};
  for (final r in transcript) {
    final name = '${r['name'] ?? ''}'.trim();
    if (name.isEmpty || !used.add(name)) continue;
    final byName = certifiedCategoryOf(name);
    final byCategory = certifiedCategoryOf('${r['category'] ?? ''}'.trim());
    if (byName != cat && byCategory != cat) continue;
    final cr = r['credits'];
    out.add(PdfCourseRow(
      code: '${r['course_id'] ?? ''}',
      name: name,
      credits: cr is num ? cr.toDouble() : 0.0,
    ));
  }
  return out;
}

/// PDF 板块树节点（_pdfSectionsCard 按层级组树后渲染）。
class _SecNode {
  final PdfModuleSection section;
  final int index; // 文档序，作收起/展开状态键
  final List<_SecNode> children = [];
  _SecNode(this.section, this.index);
}

/// 按 level 把文档序的板块列表组为树；同级/更高级弹出栈，浅一级成为其子节点。
List<_SecNode> _buildSectionTree(List<PdfModuleSection> secs) {
  final roots = <_SecNode>[];
  final stack = <_SecNode>[];
  for (var i = 0; i < secs.length; i++) {
    final node = _SecNode(secs[i], i);
    while (stack.isNotEmpty && stack.last.section.level >= secs[i].level) {
      stack.removeLast();
    }
    (stack.isEmpty ? roots : stack.last.children).add(node);
    stack.add(node);
  }
  return roots;
}

/// 毕业要求/章节级总述伪板块剔除（用户反馈 #3）。
///
/// 2026 级方案 PDF 开头 12 条「工程知识：…」「分析问题：…」是毕业要求条目，
/// 解析器按层级行识别后成了无课程、无学分、无子块的顶层块；UI 若照常渲染，
/// 用户会先看到整页总述再看到各板块修读要求。判据刻意保守：同时满足
/// 无直属课程 + 无学分标注 + 无子块 + 非认定类 才剔除；有任何一项实质内容
/// 都保留（宁缺勿删）。纯 UI 展示过滤，审计口径仍读完整板块。
void _pruneEmptyRequirementRoots(List<_SecNode> nodes) {
  nodes.removeWhere(
      (n) => n.children.isEmpty && isContentlessSection(n.section));
}

/// 微辅修板块整支剔除（诉求 #10，判据见 isMinorElectiveSection）：命中板块
/// 连同其全部子块一并移除；节点 index 保持文档序，收起/展开状态键不受影响。
/// 就地修改并返回传入列表（_buildSectionTree 每次构建新建节点，无共享风险）。
List<_SecNode> _pruneMinorSections(List<_SecNode> nodes,
    {bool keepMinor = false}) {
  // 「跨专业学习模块（微辅修）」可能正是「个性修读」三选一的一个选项：
  // 此时整支必须保留，否则用户看不到可选模块（用户反馈 #4）。
  nodes.removeWhere((n) => !keepMinor && isMinorElectiveSection(n.section));
  for (final n in nodes) {
    final alt = n.children.length < 2
        ? null
        : detectAlternativeModules(
            [for (final k in n.children) k.section],
            [
              ...n.section.notes,
              for (final k in n.children) ...k.section.notes,
            ].join('\n'));
    _pruneMinorSections(n.children, keepMinor: keepMinor || alt != null);
  }
  return nodes;
}
