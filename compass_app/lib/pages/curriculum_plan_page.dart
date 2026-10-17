/// pages/curriculum_plan_page.dart — 培养方案页（应用内查看）。
///
/// 链路：学籍画像（课表接口，给出专业名/学院/行政班→年级）
///  → 方案目录（正方"培养方案查询"列表接口 N153020，一次拿全校方案）
///  → 客户端匹配（专业全称 × 年级；命中多条一律交给用户点选，绝不替用户猜）
///  → 结构化展示（培养目标/要求、专业核心课、学分与课堂要求）
///  + 官方培养方案 PDF（下载/系统阅读器打开，各板块修读要求解析后内嵌展示）。
/// 另内嵌：学业达成审计区（原「审计」页签并入，诉求 #13/#14/#2/#11）、
/// 本学期已选计数（诉求 #8）、本学期课表周视图（诉求 #16）。
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
import '../data/xk_parse.dart';
import '../data/zju_client.dart';
import '../engine/plan_audit_adapter.dart';
// getCloseMatches 实际定义在 engine/timeline.dart（difflib 移植，纯函数）；
// engine/matching.dart 只是引用方且未 re-export，引擎文件本任务不可改。
import '../engine/timeline.dart' show getCloseMatches;
import '../widgets/report_view.dart';
import '../widgets/scholar_cards.dart' show SectionHeader;
import '../widgets/timetable_view.dart';
import 'minor_plan_page.dart';

class CurriculumPlanPage extends StatefulWidget {
  /// 底部导航用（main.dart 只引用这里，不散落中文标签）。
  static const String tabLabel = '方案';
  static const IconData tabIcon = Icons.menu_book_outlined;
  static const IconData tabIconSelected = Icons.menu_book;

  final ZjuClient client;
  final CredentialStore store;
  final bool loggedIn;

  /// 已修课程（学业页的 _courses），用于把课程名标成"已修/未修"。
  final List<Map<String, dynamic>> transcript;
  final VoidCallback onGoSettings;

  /// 审计报告（main 持有）：非空时页面顶部内嵌「学业达成审计」区（诉求 #13）。
  final Map<String, dynamic>? report;

  /// 本学期已选课程（在修未出成绩，诉求 #8）：state=='data' 时展示计数行。
  final XkListParseResult? choosed;

  /// 本学期课表（诉求 #16）：非空时页面底部内嵌周视图。
  final TimetableParseResult? timetable;

  const CurriculumPlanPage({
    super.key,
    required this.client,
    required this.store,
    required this.loggedIn,
    required this.onGoSettings,
    this.transcript = const [],
    this.report,
    this.choosed,
    this.timetable,
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
    await widget.client.selectPlan(plan);
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

  /// 成绩单课程名集合（trim 去空）：「已修」标定的对照基准。
  Set<String> _transcriptNames() => widget.transcript
      .map((c) => (c['name'] ?? '').toString().trim())
      .where((n) => n.isNotEmpty)
      .toSet();

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

  /// 学业达成审计区：SectionHeader + 报告本体（totals 卡下带本学期已选计数行）。
  List<Widget> _auditSection(Map<String, dynamic> report) => [
        const SectionHeader('学业达成审计'),
        ReportSection(report: report, belowTotals: _choosedLine()),
      ];

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

  /// 本学期已选（在修未出成绩）计数行（诉求 #8）：仅教务模式拉到已选列表时展示。
  Widget? _choosedLine() {
    final c = widget.choosed;
    if (c == null || c.state != 'data') return null;
    final xf = c.courses.fold<double>(0, (n, x) => n + (x.xf ?? 0));
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              text: '本学期已选（在修，未出成绩）',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
              children: [
                TextSpan(
                  text: '${c.courses.length} 门 / ${xf.toStringAsFixed(1)} 学分',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface),
                ),
              ],
            ),
          ),
          const Text('已获得学分开自成绩单，两者分开计。',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
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
    // 「已修」标定（配合任务 5）：成绩单全等命中 + 名称相似度 ≥0.85 模糊命中。
    // 一次性解析成集合：chips 随收起/展开频繁重建，查表 O(1)，避免重复算相似度。
    final passed = resolvePassedNames([
      ...p.zyhxkc,
      ...p.zyhxsjkc,
      ...p.qywkc,
    ], _transcriptNames());
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
          _chips(p.zyhxkc, passed),
          const SizedBox(height: 6),
          const Text('高亮=你的成绩单里已出现同名或相近课程；逐门学分/学期见各板块修读要求或官方 PDF。',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
        ]),
      if (p.zyhxsjkc.isNotEmpty)
        _card('专业核心实践课程（${p.zyhxsjkc.length} 门）',
            [_chips(p.zyhxsjkc, passed)]),
      if (p.qywkc.isNotEmpty)
        _card('前沿与荣誉课程（${p.qywkc.length} 门）', [_chips(p.qywkc, passed)]),
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
    // 「已修」标定与 _planSections 同口径（全等 + 模糊 ≥0.85），对 PDF 全部
    // 板块的课程名一次性解析，收起/展开重绘时只做查表。
    final passed = resolvePassedNames(
      [for (final s in ps.sections) ...s.courses.map((c) => c.name)],
      _transcriptNames(),
    );
    final roots = _buildSectionTree(ps.sections);
    // 微辅修板块整支剔除（诉求 #10）：索引保持文档序，收起/展开状态键不受影响。
    _pruneMinorSections(roots);
    if (roots.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('各板块修读要求',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const Text('来自官方培养方案 PDF · 高亮=成绩单已出现同名或相近课程',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            if (ps.qualityNotes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('⚠️ ${ps.qualityNotes.join('；')}',
                    style: TextStyle(
                        fontSize: 11, color: Theme.of(context).colorScheme.error)),
              ),
            for (var i = 0; i < roots.length; i++) ...[
              if (i > 0) const Divider(height: 16), // 一级板块之间的分隔
              _moduleBlock(roots[i], passed),
            ],
          ],
        ),
      ),
    );
  }

  /// 一级板块：标题行（带 ▾ 整块收起/展开、橙色「N选M」规则徽章）+ 内容；
  /// 不再各套 Card（诉求 #14），说明命中「以下 N 种模块中的一种」时在
  /// 标题下加灰字并行选项提示（诉求 #11）。
  Widget _moduleBlock(_SecNode node, Set<String> passed) {
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
                if (s.creditsRaw.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text('${s.creditsRaw} 学分',
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
        if (alt != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 2, 4),
            child: Text('以下 ${alt.optionCount} 类为并行选项，满足其一即可',
                style: const TextStyle(fontSize: 11.5, color: Colors.grey)),
          ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 2, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (s.courses.isNotEmpty) ...[
                  _courseChips(s.courses, passed),
                  const SizedBox(height: 6),
                ],
                ..._certifiedChipBlock(s, passed),
                for (final k in node.children) _subBlock(k, passed),
                ..._notesBlock(s, node.index),
              ],
            ),
          ),
      ],
    );
  }

  /// 二级及更深板块：卡内的可收起小节（同样带「N选M」规则徽章）。
  Widget _subBlock(_SecNode node, Set<String> passed) {
    final s = node.section;
    final open = !_collapsedSecs.contains(node.index);
    final courses = _countCourses(node);
    final primary = Theme.of(context).colorScheme.primary;
    final badge = choiceBadgeText(s);
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
                  if (s.creditsRaw.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text('${s.creditsRaw} 学分',
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
          if (open)
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (s.courses.isNotEmpty) ...[
                    _courseChips(s.courses, passed),
                    const SizedBox(height: 6),
                  ],
                  ..._certifiedChipBlock(s, passed),
                  for (final k in node.children) _subBlock(k, passed),
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
    if (s.notes.isEmpty) return const [];
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
              Text(open ? '收起修读说明' : '展开完整修读说明（${s.notes.length} 条）',
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
              for (final n in s.notes)
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

  Widget _courseChips(List<PdfCourseRow> courses, Set<String> passed) => Wrap(
        spacing: 5,
        runSpacing: 4,
        children: [
          for (final c in courses)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                color: passed.contains(c.name)
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
              child: Text(
                  '${c.name} ${_num(c.credits)}分'
                  '${c.semester.isNotEmpty ? ' ${prettySemester(c.semester, gradeYear: _selected?.gradeYear ?? 0)}' : ''}',
                  style: const TextStyle(fontSize: 11)),
            ),
        ],
      );

  /// 认定类板块（美育/劳育/创新创业/心理健康，#13）在 PDF 里只有说明文字、
  /// 无课程表：把成绩单里同类课程（certifiedCategoryOf 命中该板块类别）显示为
  /// 「已修」标亮 chips。板块自带课程表时 certifiedRowsForSection 返回空，不重复。
  List<Widget> _certifiedChipBlock(PdfModuleSection s, Set<String> passed) {
    final rows = certifiedRowsForSection(s, widget.transcript);
    if (rows.isEmpty) return const [];
    // chips 本身取自成绩单，直接并入已修集合（与 _transcriptNames 同口径）
    return [
      _courseChips(rows, passed.union(_transcriptNames())),
      const SizedBox(height: 6),
    ];
  }

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

  Widget _chips(List<String> names, Set<String> passed) => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final n in names)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                color: passed.contains(n)
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
              child: Text(n, style: const TextStyle(fontSize: 12)),
            ),
        ],
      );

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
  return rule == null ? null : '规则：${rule.text}';
}

/// 「微辅修」板块判据（顶层纯函数，供 UI 与单测共用；诉求 #10 / 任务 7）：
/// 板块标题或上级链（parentPath，含全部祖先标题）出现「微辅修」即命中。
/// 理由：本专业方案 PDF 里的微辅修清单是面向其他专业学生的修读要求，
/// 与本人修读无关，故整支（含其子块）不渲染；「其他专业微辅修」入口卡
/// （MinorPlanPage 跳转卡）保留不动。
bool isMinorElectiveSection(PdfModuleSection s) =>
    s.title.contains('微辅修') || s.parentPath.contains('微辅修');

/// 方案课程名「已修」解析（顶层纯函数，供 UI 与单测共用；配合任务 5）：
/// 返回 names 中视为已修的子集（保留原写法，chips 构建时直接查表）——
/// 成绩单全等命中优先，另用 difflib 风格相似度（getCloseMatches，cutoff 0.85）
/// 兜底：成绩单与方案的写法略有出入（如「大学英语（II）」vs「大学英语II」）
/// 也算已修。纯函数、不抛异常、宁缺勿猜：无命中一律视为未修。
Set<String> resolvePassedNames(
    Iterable<String> names, Set<String> transcriptNames) {
  if (transcriptNames.isEmpty) return const {};
  final possibilities = transcriptNames.toList();
  final out = <String>{};
  for (final raw in names) {
    final n = raw.trim();
    if (n.isEmpty) continue;
    if (transcriptNames.contains(n) ||
        getCloseMatches(n, possibilities, n: 1, cutoff: 0.85).isNotEmpty) {
      out.add(raw);
    }
  }
  return out;
}

/// 认定类板块无课程表时，从成绩单里找可标亮「已修」的课程行（顶层纯函数，
/// 供 UI 与单测共用；#13）。判定与引擎适配器同源：certifiedSectionCategory
/// 认板块（level≤3、标题命中美育/劳育/创新创业/心理健康），certifiedCategoryOf
/// 认课程；板块自带课程表时不重复补（宁缺勿猜），同名课（重修）只取一次。
List<PdfCourseRow> certifiedRowsForSection(
    PdfModuleSection s, List<Map<String, dynamic>> transcript) {
  final cat = certifiedSectionCategory(s);
  if (cat == null || s.courses.isNotEmpty) return const [];
  final out = <PdfCourseRow>[];
  final used = <String>{};
  for (final r in transcript) {
    final name = '${r['name'] ?? ''}'.trim();
    if (name.isEmpty || !used.add(name)) continue;
    if (certifiedCategoryOf(name) != cat) continue;
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

/// 微辅修板块整支剔除（诉求 #10，判据见 isMinorElectiveSection）：命中板块
/// 连同其全部子块一并移除；节点 index 保持文档序，收起/展开状态键不受影响。
/// 就地修改并返回传入列表（_buildSectionTree 每次构建新建节点，无共享风险）。
List<_SecNode> _pruneMinorSections(List<_SecNode> nodes) {
  nodes.removeWhere((n) => isMinorElectiveSection(n.section));
  for (final n in nodes) {
    _pruneMinorSections(n.children);
  }
  return nodes;
}
