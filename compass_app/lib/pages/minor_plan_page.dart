/// pages/minor_plan_page.dart — 微辅修独立页（用户诉求 #10）。
///
/// 微辅修面向其他专业学生，不与本人主修培养方案混排：独立入口 →
/// 用户搜索并点选目标专业 → 拉该专业培养方案 PDF（缓存优先，与培养方案页
/// 共用同一份 planpdf_* 缓存）→ parsePlanPdfText 解析板块 →
/// [pickMinorSections] 只挑「微辅修」相关板块 → 展示微辅修总学分与课程清单
/// （成绩单同名课程标亮为已修，口径同培养方案页）。
///
/// 纯 UI + 取数，零新依赖；客户端是否已登录由调用方保证。
library;

import 'package:flutter/material.dart';

import '../data/credential_store.dart';
import '../data/pdf_text_extractor.dart';
import '../data/plan_models.dart';
import '../data/plan_pdf_parse.dart';
import '../data/semester.dart';
import '../data/zju_client.dart';

/// 从板块全集中挑出「微辅修」相关板块（纯函数、不抛异常，可单测）。
///
/// 判定（满足其一即入选；结果保持文档序）：
///  1. title 含「微辅修」——含「微辅修：N学分」冒号式条目（解析器记 level=2）；
///  2. parentPath 含「微辅修」——解析期已挂好的祖先链；
///  3. 文档序上位于某个微辅修锚点之后、且层级更深（同一支的子板块：
///     微辅修的课程表/子项都挂在该支内）——一旦出现层级不深于锚点的
///     其他板块，该支结束；锚点取本支内出现过的最浅层级。
List<PdfModuleSection> pickMinorSections(List<PdfModuleSection> all) {
  final out = <PdfModuleSection>[];
  int? anchorLevel;
  for (final s in all) {
    if (s.title.contains('微辅修') || s.parentPath.contains('微辅修')) {
      out.add(s);
      final l = anchorLevel;
      if (l == null || s.level < l) anchorLevel = s.level;
      continue;
    }
    if (anchorLevel != null && s.level > anchorLevel) {
      out.add(s); // 微辅修支的子板块
      continue;
    }
    anchorLevel = null; // 离开了微辅修支
  }
  return out;
}

/// 微辅修独立页。
class MinorPlanPage extends StatefulWidget {
  final ZjuClient client;
  final CredentialStore store;
  final bool loggedIn;

  /// 已修课程（成绩单），用于把微辅修课程标亮为已修
  /// （口径同培养方案页：取 transcript 里课程 name trim 成 Set）。
  final List<Map<String, dynamic>> transcript;
  final VoidCallback onGoSettings;

  const MinorPlanPage({
    super.key,
    required this.client,
    required this.store,
    required this.loggedIn,
    required this.onGoSettings,
    required this.transcript,
  });

  @override
  State<MinorPlanPage> createState() => _MinorPlanPageState();
}

class _MinorPlanPageState extends State<MinorPlanPage> {
  final _searchCtl = TextEditingController();
  List<PlanSummary> _catalog = const []; // 全校方案目录（首次搜索拉一次）
  bool _catalogFromCache = false; // 目录是否取自缓存（提示"离线数据"）
  List<PlanSummary> _searchHits = const [];
  PlanSummary? _selected;
  List<PdfModuleSection> _minorSections = const [];
  bool _searching = false;
  bool _loadingPlan = false;
  String? _error; // 行内错误（目录/PDF 获取、解析失败）
  String? _notice; // 如实提示（方案未列出微辅修课程等）

  @override
  void didUpdateWidget(covariant MinorPlanPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 设置页清除数据/退出登录后，本页跟着切回未登录空态（否则要重启应用才刷新）。
    if (!widget.loggedIn && oldWidget.loggedIn) {
      setState(() {
        _catalog = const [];
        _catalogFromCache = false;
        _searchHits = const [];
        _selected = null;
        _minorSections = const [];
        _error = null;
        _notice = null;
        _searchCtl.clear();
      });
    }
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  /// 已修课程名集合（口径同培养方案页）。
  Set<String> get _passed => widget.transcript
      .map((c) => (c['name'] ?? '').toString().trim())
      .where((n) => n.isNotEmpty)
      .toSet();

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── 取数 ────────────────────────────────────────────────────────────────

  /// 搜索专业：目录一次拉全量（客户端有缓存），匹配在客户端做（同培养方案页）。
  Future<void> _search(String keyword) async {
    final q = keyword.trim();
    if (q.isEmpty) {
      setState(() => _searchHits = const []);
      return;
    }
    setState(() => _searching = true);
    try {
      if (_catalog.isEmpty) {
        _catalog = await widget.client.fetchPlanCatalog();
        _catalogFromCache = widget.client.lastPlanFromCache;
      }
      if (!mounted) return;
      final hits = searchPlans(_catalog, q, limit: 60);
      setState(() {
        _searchHits = hits;
        _error = null;
      });
      if (hits.isEmpty) _snack('方案库里没有匹配「$q」的专业');
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '搜索失败：$e';
          _searchHits = const [];
        });
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _pick(PlanSummary plan) async {
    setState(() {
      _selected = plan;
      _minorSections = const [];
      _notice = null;
      _error = null;
      _searchHits = const [];
      _searchCtl.clear();
    });
    await _loadMinorSections(plan);
  }

  /// 拉取选中专业的方案 PDF（缓存优先，与培养方案页同一份缓存文件）
  /// 并解析出微辅修板块；全程 try/catch，失败行内提示不崩。
  Future<void> _loadMinorSections(PlanSummary plan) async {
    final wanted = plan.id;
    final id = plan.jxjhh.isNotEmpty ? plan.jxjhh : plan.id;
    final name =
        'planpdf_${id.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '')}.pdf';
    setState(() => _loadingPlan = true);
    try {
      List<int>? bytes = await widget.store.readBinaryCache(name);
      if (bytes == null) {
        bytes = await widget.client.fetchPlanPdf(plan);
        if (bytes != null) await widget.store.saveBinaryCache(name, bytes);
      }
      if (!mounted || _selected?.id != wanted) return;
      if (bytes == null) {
        setState(() {
          _error = '教务未返回该专业方案 PDF（可能未上传或当前账号无预览权限），'
              '无法解析微辅修板块';
        });
        return;
      }
      final parsed = parsePlanPdfText(extractPdfText(bytes));
      final minors = pickMinorSections(parsed.sections);
      if (!mounted || _selected?.id != wanted) return;
      setState(() {
        _minorSections = minors;
        _notice = minors.isEmpty
            ? '该专业方案未列出微辅修课程（可能不接收微辅修或 PDF 未包含此节）'
            : null;
      });
    } catch (e) {
      if (mounted && _selected?.id == wanted) {
        setState(() => _error = '微辅修板块获取失败：$e');
      }
    } finally {
      if (mounted) setState(() => _loadingPlan = false);
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
        _searchSection(),
        if (_loadingPlan)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (!_loadingPlan && _selected != null) ..._minorResult(_selected!),
        const SizedBox(height: 8),
        const Text(
            '微辅修板块来自该专业官方培养方案 PDF（教务网只读查询），'
            '以教务系统展示为准；修读申请以开设微辅修专业的通知为准。',
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
              const Icon(Icons.school_outlined, size: 44),
              const SizedBox(height: 12),
              const Text('登录教务网后可查看其他专业的微辅修方案',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('微辅修面向其他专业学生：登录后在此搜索目标专业，'
                  '即可查看其培养方案中的微辅修学分要求与课程清单。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: widget.onGoSettings,
                icon: const Icon(Icons.settings_outlined),
                label: const Text('去设置'),
              ),
            ],
          ),
        ),
      );

  Widget _header() => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.school_outlined, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('微辅修',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              ),
              if (_catalogFromCache)
                const Text('目录来自缓存',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        ),
      );

  Widget _errorCard(String message) => Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.error_outline, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(message, style: const TextStyle(fontSize: 12))),
            ],
          ),
        ),
      );

  Widget _searchSection() => _card('选择专业（微辅修面向其他专业学生）', [
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
        const Text('输入想微辅修的专业名，拉取该专业培养方案里的微辅修部分。',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
        if (_searching)
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
        if (_searchHits.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final p in _searchHits) _tile(p),
        ],
      ]);

  Widget _tile(PlanSummary plan) {
    final selected = _selected?.id == plan.id;
    return InkWell(
      onTap: _loadingPlan ? null : () => _pick(plan),
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
                  if (plan.wfxxf != null)
                    Text('方案标注微辅修 ${_num(plan.wfxxf!)} 学分',
                        style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.primary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 选中专业的微辅修结果：概览卡（总学分/课程数）+ 各微辅修板块卡片。
  List<Widget> _minorResult(PlanSummary p) {
    if (_minorSections.isEmpty) {
      return [
        _card('微辅修板块', [
          Text(
              _notice ??
                  '该专业方案未列出微辅修课程（可能不接收微辅修或 PDF 未包含此节）',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _loadingPlan ? null : () => _loadMinorSections(p),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重新获取'),
          ),
        ]),
      ];
    }
    // 总学分：取微辅修锚点（「微辅修：N学分」冒号条目）声明的学分，子板块学分不重复计。
    final total = _minorSections
        .map((s) => s.creditsRaw)
        .firstWhere((c) => c.isNotEmpty, orElse: () => '');
    final courseCount =
        _minorSections.fold<int>(0, (n, s) => n + s.courses.length);
    return [
      _card('微辅修 · ${p.zymc}${p.synj.isEmpty ? '' : ' ${p.synj} 级'}', [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (total.isNotEmpty) _stat('微辅修总学分', '$total 学分'),
            if (p.wfxxf != null) _stat('方案标注微辅修学分', '${_num(p.wfxxf!)} 学分'),
            _stat('识别到课程', '$courseCount 门'),
          ],
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _loadingPlan ? null : () => _loadMinorSections(p),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('重新获取'),
        ),
      ]),
      for (final s in _minorSections) _minorSectionBlock(s),
    ];
  }

  /// 一个微辅修板块：标题 + 学分 + 课程 chips + 修读说明。
  Widget _minorSectionBlock(PdfModuleSection s) {
    final primary = Theme.of(context).colorScheme.primary;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 2),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(_stripParens(s.title),
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.bold)),
                ),
                if (s.creditsRaw.isNotEmpty)
                  Text('${s.creditsRaw} 学分',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: primary)),
              ],
            ),
            if (s.parentPath.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(s.parentPath,
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ),
            const SizedBox(height: 8),
            if (s.courses.isNotEmpty) ...[
              _courseChips(s.courses),
              const SizedBox(height: 6),
              const Text('高亮=你的成绩单里已出现同名课程。',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ] else
              const Text('PDF 中未列出该板块的课程表。',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            for (final n in s.notes)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text('· $n',
                    style: const TextStyle(fontSize: 11.5, height: 1.4)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _courseChips(List<PdfCourseRow> courses) {
    final passed = _passed;
    return Wrap(
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
              '${c.code.isEmpty ? '' : '${c.code} '}'
              '${c.name} ${_num(c.credits)}分'
              '${c.semester.isEmpty ? '' : ' ${prettySemester(c.semester, gradeYear: _selected?.gradeYear ?? 0)}'}',
              style: const TextStyle(fontSize: 11),
            ),
          ),
      ],
    );
  }

  // ── 小组件 ──────────────────────────────────────────────────────────────

  Widget _card(String title, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
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

  /// 「其他必修环节（认定型学分）」→「其他必修环节」（口径同培养方案页）。
  static final RegExp _parenRe = RegExp(r'[（(][^（（）)]*[）)]');
  String _stripParens(String title) {
    final t = title.replaceAll(_parenRe, '').trim();
    return t.isEmpty ? title : t;
  }

  static String _num(double v) => (v - v.roundToDouble()).abs() < 1e-9
      ? v.roundToDouble().toString()
      : v.toString();
}
