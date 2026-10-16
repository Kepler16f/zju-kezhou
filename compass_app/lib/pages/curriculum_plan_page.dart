/// pages/curriculum_plan_page.dart — 培养方案页（应用内查看）。
///
/// 链路：学籍画像（课表接口，给出专业名/学院/行政班→年级）
///  → 方案目录（正方"培养方案查询"列表接口 N153020，一次拿全校方案）
///  → 客户端匹配（专业全称 × 年级；命中多条一律交给用户点选，绝不替用户猜）
///  → 结构化展示（培养目标/要求、专业核心课、学分与课堂要求）
///  → 课程明细（多端点 best-effort）+ 官方培养方案 PDF（下载/系统阅读器打开）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../data/credential_store.dart';
import '../data/pdf_text_extractor.dart';
import '../data/plan_models.dart';
import '../data/plan_pdf_parse.dart';
import '../data/zju_client.dart';

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

  const CurriculumPlanPage({
    super.key,
    required this.client,
    required this.store,
    required this.loggedIn,
    required this.onGoSettings,
    this.transcript = const [],
  });

  @override
  State<CurriculumPlanPage> createState() => _CurriculumPlanPageState();
}

class _CurriculumPlanPageState extends State<CurriculumPlanPage> {
  final _searchCtl = TextEditingController();
  StudentProfile _profile = const StudentProfile();
  PlanMatchResult _match = PlanMatchResult.empty;
  PlanSummary? _selected;
  List<PlanCourseRow> _courseTable = const [];
  List<PlanSummary> _searchHits = const [];
  String? _pdfPath;
  String? _error;
  String? _courseHint;
  bool _loading = false;
  bool _loadingCourses = false;
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
        _courseTable = const [];
        _searchHits = const [];
        _pdfPath = null;
        _pdfSections = null;
        _collapsedSecs.clear();
        _notesOpen.clear();
        _error = null;
        _courseHint = null;
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
      _courseHint = null;
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
        _courseTable = const [];
        _pdfPath = null;
        _pdfSections = null;
        _collapsedSecs.clear();
        _notesOpen.clear();
      });
      if (best != null) {
        await _loadCourses(best);
        unawaited(_ensurePdfSections(best)); // 各板块修读要求：自动拉取解析
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 课程明细（多端点 best-effort，拿不到就提示看 PDF）。
  Future<void> _loadCourses(PlanSummary plan) async {
    final wanted = plan.id;
    setState(() {
      _loadingCourses = true;
      _courseHint = null;
    });
    try {
      final rows = await widget.client.fetchPlanCourseTable(plan);
      if (!mounted || _selected?.id != wanted) return;
      setState(() {
        _courseTable = rows;
        if (rows.isEmpty) {
          _courseHint = '教务未开放逐门课程表（学生端该功能属教师菜单），'
              '完整课程表请下载下方 PDF 查看。';
        }
      });
    } catch (e) {
      if (mounted && _selected?.id == wanted) {
        setState(() => _courseHint = '课程表获取异常：$e');
      }
    } finally {
      if (mounted) setState(() => _loadingCourses = false);
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
        _courseTable = const [];
        _courseHint = null;
        _pdfPath = null;
        _pdfSections = null;
        _collapsedSecs.clear();
        _notesOpen.clear();
        _searchHits = const [];
        _searchCtl.text = '';
      });
    await widget.client.selectPlan(plan);
    await _loadCourses(plan);
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

  // ── 视图 ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (!widget.loggedIn) return _notLoggedIn();
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
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
        const SizedBox(height: 8),
        const Text('培养方案为教务网只读查询结果，仅用于本人学业规划参考；'
            '以教务系统展示为准。',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }

  Widget _notLoggedIn() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
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
                if (_selected != null)
                  OutlinedButton.icon(
                    onPressed: _loadingCourses
                        ? null
                        : () => _loadCourses(_selected!),
                    icon: const Icon(Icons.list_alt_outlined, size: 18),
                    label: const Text('刷新课程表'),
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
    final passed = widget.transcript
        .map((c) => (c['name'] ?? '').toString().trim())
        .where((n) => n.isNotEmpty)
        .toSet();
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
          const Text('高亮=你的成绩单里已出现同名课程；逐门学分/学期见课程表或 PDF。',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
        ]),
      if (p.zyhxsjkc.isNotEmpty)
        _card('专业核心实践课程（${p.zyhxsjkc.length} 门）',
            [_chips(p.zyhxsjkc, passed)]),
      if (p.qywkc.isNotEmpty)
        _card('前沿与荣誉课程（${p.qywkc.length} 门）', [_chips(p.qywkc, passed)]),
      _courseCard(),
      if (_pdfSections != null && _pdfSections!.sections.isNotEmpty)
        _pdfSectionsCard(),
      if (p.bz.isNotEmpty) _expandCard('辅修/微辅修说明', p.bz),
      _pdfCard(p),
    ];
  }

  Widget _courseCard() {
    if (_loadingCourses) {
      return _card('课程表', [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ]);
    }
    if (_courseTable.isEmpty) {
      return _card('课程表', [
        Text(_courseHint ?? '暂无课程明细',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ]);
    }
    return _card('课程表（${_courseTable.length} 门）', [
      for (final r in _courseTable) _courseTile(r),
    ]);
  }

  Widget _courseTile(PlanCourseRow r) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(r.name, style: const TextStyle(fontSize: 12.5)),
            ),
            if (r.semester.isNotEmpty)
              Text(' ${r.semester} ',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            if (r.nature.isNotEmpty)
              Text(' ${r.nature} ',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            Text(r.credits == null ? '—' : '${_num(r.credits!)} 分',
                style: const TextStyle(fontSize: 12)),
          ],
        ),
      );

  /// 各板块修读要求（PDF 解析）：每个一级板块一张独立卡片。
  /// 大标题在卡片外（去掉括号内容）、点大标题整卡收起/展开；
  /// 卡片内课程 chips 优先展示，修读说明默认收起、点「展开完整修读说明」再看；
  /// 子板块同样可收起展开。
  Widget _pdfSectionsCard() {
    final ps = _pdfSections!;
    final passed = widget.transcript
        .map((c) => (c['name'] ?? '').toString().trim())
        .where((n) => n.isNotEmpty)
        .toSet();
    final roots = _buildSectionTree(ps.sections);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 4, 4, 0),
          child: Text('各板块修读要求',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 2, 4, 0),
          child: Text('来自官方培养方案 PDF · 高亮=成绩单已出现同名课程',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
        ),
        if (ps.qualityNotes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Text('⚠️ ${ps.qualityNotes.join('；')}',
                style: TextStyle(
                    fontSize: 11, color: Theme.of(context).colorScheme.error)),
          ),
        for (final node in roots) _moduleBlock(node, passed),
      ],
    );
  }

  /// 一级板块：大标题（卡片外）+ 可收起卡片（课程 chips 在前）。
  Widget _moduleBlock(_SecNode node, Set<String> passed) {
    final s = node.section;
    final open = !_collapsedSecs.contains(node.index);
    final courses = _countCourses(node);
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _toggleCollapsed(node.index),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 12, 2, 4),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: open ? 0 : -0.25,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(Icons.expand_more, size: 22, color: primary),
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Text(_stripParens(s.title),
                      style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          height: 1.25)),
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
        if (open)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 2),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (s.courses.isNotEmpty) ...[
                    _courseChips(s.courses, passed),
                    const SizedBox(height: 6),
                  ],
                  for (final k in node.children) _subBlock(k, passed),
                  ..._notesBlock(s, node.index),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 二级及更深板块：卡片内的可收起小节。
  Widget _subBlock(_SecNode node, Set<String> passed) {
    final s = node.section;
    final open = !_collapsedSecs.contains(node.index);
    final courses = _countCourses(node);
    final primary = Theme.of(context).colorScheme.primary;
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
                    child: Text(_stripParens(s.title),
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w700)),
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
                  '${c.semester.isNotEmpty ? ' ${c.semester}' : ''}',
                  style: const TextStyle(fontSize: 11)),
            ),
        ],
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
