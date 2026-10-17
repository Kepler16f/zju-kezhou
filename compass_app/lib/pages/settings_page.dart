/// pages/settings_page.dart — 设置页（Helechron Option 风格）：分组卡片列表。
/// 组：登录（教务网账号）/ 数据（数据源+方案+学期+运行）/ AI 解读 /
/// 关于（版本·致谢·数据与合规·登录诊断日志）。
/// 通用组已解散（任务 11）：诊断与合规入口并入「关于」组，
/// 登录组里的诊断/日志类信息默认折叠、点开可见。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/ai_config.dart';
import '../data/ai_models.dart';
import '../data/ai_prompts.dart';
import '../data/app_version.dart';
import '../data/diagnostic_log.dart';
import '../data/plan_models.dart';
import '../data/semester.dart';
import '../data/xk_parse.dart';
import '../engine/analytics.dart';

enum DataMode { sample, paste, zju }

class SettingsPage extends StatefulWidget {
  final DataMode mode;
  final ValueChanged<DataMode> onModeChange;
  final String major;
  final ValueChanged<String?> onMajorChange;
  final String current;
  final ValueChanged<String?> onCurrentChange;
  final Map<String, String> majors;
  final TextEditingController userCtl;
  final TextEditingController passCtl;
  final TextEditingController pasteCtl;
  final bool busy;
  final VoidCallback onRun;
  final String? notice;
  final String? loggedInAs; // 已记住的学号（自动登录状态）
  final DateTime? lastDataAt; // 上次成功拉取数据的时间
  final VoidCallback onClearData;
  final AiConfig aiConfig; // AI 解读配置（出厂无存档时默认公益端点）
  final Future<void> Function(AiConfig config) onAiConfigChange;
  final Future<String> Function(AiConfig config) onTestAi;
  final Future<AiModelsResult> Function(AiConfig config) onListAiModels;

  // 数据概览 / 我的培养方案（诉求 #10/#11）
  final List<Map<String, dynamic>> courses;
  final XkListParseResult? choosed;
  final MatchedPlanInfo? matchedPlan;
  final String? planNote;
  final VoidCallback onGoPlan;

  const SettingsPage(
      {super.key, required this.mode, required this.onModeChange,
      required this.major, required this.onMajorChange,
      required this.current, required this.onCurrentChange,
      required this.majors, required this.userCtl, required this.passCtl,
      required this.pasteCtl, required this.busy, required this.onRun,
      this.notice, this.loggedInAs, this.lastDataAt, required this.onClearData,
      required this.aiConfig, required this.onAiConfigChange,
      required this.onTestAi, required this.onListAiModels,
      this.courses = const [],
      this.choosed,
      this.matchedPlan,
      this.planNote,
      required this.onGoPlan});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 已登录时默认收起学号/密码输入区（需求 #2：不用一直开着）。
  /// null = 跟随登录状态（已登录收起、未登录展开）；true/false = 用户手动切换。
  bool? _credsExpanded;

  bool get _showCreds => _credsExpanded ?? (widget.loggedInAs == null);

  /// 诊断/日志类信息默认折叠（任务 11）：登录卡里只留一行开关，
  /// 点开才见上次取数时间等运行信息（_showCreds 同款 bool 模式）。
  bool _diagOpen = false;

  static const _semesters = [
    '2023-A','2023-B','2024-A','2024-B','2025-A','2025-B',
    '2026-A','2026-B','2027-A','2027-B',
  ];

  @override
  Widget build(BuildContext context) {
    final mode = widget.mode;
    final loggedInAs = widget.loggedInAs;
    final notice = widget.notice;
    final busy = widget.busy;
    final major = widget.major;
    final current = widget.current;
    final majors = widget.majors;
    final userCtl = widget.userCtl;
    final passCtl = widget.passCtl;
    final pasteCtl = widget.pasteCtl;
    final onRun = widget.onRun;
    final onModeChange = widget.onModeChange;
    final onMajorChange = widget.onMajorChange;
    final onCurrentChange = widget.onCurrentChange;
    final lastDataAt = widget.lastDataAt;
    final aiConfig = widget.aiConfig;
    final onAiConfigChange = widget.onAiConfigChange;
    final onTestAi = widget.onTestAi;
    final onListAiModels = widget.onListAiModels;
    final courses = widget.courses;
    final choosed = widget.choosed;
    final matchedPlan = widget.matchedPlan;
    final planNote = widget.planNote;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        _groupHeader('登录'),
        Card(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    const Icon(Icons.account_circle_outlined, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(loggedInAs != null
                          ? '已记住学号 $loggedInAs（启动自动登录，手动刷新免输密码）'
                          : '未登录（教务网模式输入学号密码后自动记住）',
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ),
              // 任务 11：诊断/日志类信息默认隐藏，点「诊断与日志」才展开
              // （_showCreds 同款 bool 模式，不让运行细节常驻首屏）。
              if (lastDataAt != null) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: Row(
                    children: [
                      TextButton.icon(
                        onPressed: () => setState(() => _diagOpen = !_diagOpen),
                        icon: Icon(
                            _diagOpen
                                ? Icons.keyboard_arrow_up
                                : Icons.keyboard_arrow_down,
                            size: 18),
                        label: const Text('诊断与日志',
                            style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
                if (_diagOpen)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Row(
                      children: [
                        const Icon(Icons.schedule, size: 16),
                        const SizedBox(width: 8),
                        Text('上次数据：${_fmt(lastDataAt)}',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                  ),
              ],
              // 需求 #2：已登录时收起学号/密码输入区，点"修改"才展开。
              if (loggedInAs != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Row(
                    children: [
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () =>
                            setState(() => _credsExpanded = !_showCreds),
                        icon: Icon(
                            _showCreds
                                ? Icons.keyboard_arrow_up
                                : Icons.keyboard_arrow_down,
                            size: 18),
                        label: Text(_showCreds ? '收起' : '修改账号 / 密码',
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              if (_showCreds) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: TextField(
                    controller: userCtl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: '学号', border: OutlineInputBorder()),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: TextField(
                    controller: passCtl,
                    obscureText: true,
                    decoration: const InputDecoration(
                        labelText: '统一身份认证密码（留空则用记住的密码）',
                        border: OutlineInputBorder()),
                  ),
                ),
              ],
            ],
          ),
        ),
        _groupHeader('数据'),
        Card(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: SegmentedButton<DataMode>(
                  segments: const [
                    ButtonSegment(
                        value: DataMode.sample,
                        label: Text('样例'),
                        icon: Icon(Icons.science_outlined)),
                    ButtonSegment(
                        value: DataMode.paste,
                        label: Text('粘贴'),
                        icon: Icon(Icons.content_paste_outlined)),
                    ButtonSegment(
                        value: DataMode.zju,
                        label: Text('教务网'),
                        icon: Icon(Icons.school_outlined)),
                  ],
                  selected: {mode},
                  onSelectionChanged: (s) => onModeChange(s.first),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: _selector('培养方案', major, majors, onMajorChange),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _selector(
                          '当前学期',
                          current,
                          {
                            // 值保持引擎编码 'YYYY-A/B'，显示用日历标签（诉求 #8）
                            for (final s in _semesters) s: termCodeLabel(s)
                          },
                          onCurrentChange),
                    ),
                  ],
                ),
              ),
              _dataAndPlanBlock(context,
                  courses: courses,
                  choosed: choosed,
                  matchedPlan: matchedPlan,
                  planNote: planNote),
              if (mode == DataMode.paste)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    controller: pasteCtl,
                    minLines: 3,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      labelText: '粘贴成绩单（每行：学期 课程代码 课程名 学分 成绩）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: busy ? null : onRun,
                    icon: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.checklist),
                    label: Text(switch (mode) {
                      DataMode.sample => '运行样例审计',
                      DataMode.paste => '解析并审计',
                      DataMode.zju => '登录教务网并拉取',
                    }),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (notice != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(notice,
                style: const TextStyle(color: Colors.red, fontSize: 13)),
          ),
        _groupHeader('AI 解读'),
        _AiCard(
            config: aiConfig,
            onSave: onAiConfigChange,
            onTest: onTestAi,
            onListModels: onListAiModels),
        _groupHeader('关于'),
        // 通用组已解散（任务 11）：「数据与合规」「登录诊断日志」两个入口
        // 并入关于组，标题保持原名（main.dart 崩溃引导文案指名「登录诊断日志」）。
        Card(
          child: Column(
            children: [
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('课舟 v$kAppVersion'),
                subtitle: Text('培养方案结构化与选课风险审计；学分/缺口/冲突全部在本机计算；AI 仅做文字解读（可选、可关闭）',
                    style: TextStyle(fontSize: 11)),
              ),
              const Divider(height: 1, indent: 16),
              const ListTile(
                leading: Icon(Icons.favorite_outline),
                title: Text('开源致谢'),
                subtitle: Text('字体 Noto Sans SC（OFL）；教务协议参考开源社区成果',
                    style: TextStyle(fontSize: 11)),
              ),
              const Divider(height: 1, indent: 16),
              ListTile(
                leading: const Icon(Icons.privacy_tip_outlined),
                title: const Text('数据与合规'),
                subtitle: const Text('凭证沙箱存储、Cookie 仅内存、只读通道；AI 开箱即用（公益端点）',
                    style: TextStyle(fontSize: 11)),
                onTap: () => _showCompliance(context),
              ),
              const Divider(height: 1, indent: 16),
              ListTile(
                leading: const Icon(Icons.bug_report_outlined),
                title: const Text('登录诊断日志'),
                subtitle: const Text('逐步记录登录/取数卡点（不含密码）',
                    style: TextStyle(fontSize: 11)),
                onTap: () => _showDiagnostics(context),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _fmt(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    return '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Widget _groupHeader(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
        child: Text(title,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade700)),
      );

  Widget _selector(String label, String value, Map<String, String> items,
      ValueChanged<String?> onChanged) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          menuMaxHeight: 360,
          items: [
            for (final e in items.entries)
              DropdownMenuItem(
                  value: e.key,
                  child: Text(e.value, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }

  /// 数据概览 + 我的培养方案（诉求 #10/#11）。
  /// 教务模式显示真实匹配方案；样例/粘贴模式明确标注为内置样例，绝不冒充。
  Widget _dataAndPlanBlock(
    BuildContext context, {
    required List<Map<String, dynamic>> courses,
    required XkListParseResult? choosed,
    required MatchedPlanInfo? matchedPlan,
    required String? planNote,
  }) {
    final isZju = widget.mode == DataMode.zju;
    final earned =
        (Analytics.overall(courses)['earned_credits'] ?? 0).toDouble();
    final choosedCredits = choosed == null
        ? 0.0
        : choosed.courses.fold<double>(0, (s, c) => s + (c.xf ?? 0));
    final builtinName = widget.majors[widget.major] ?? widget.major;
    final builtin = MatchedPlanInfo.builtin(
      builtinName,
      grade: widget.current.length >= 4
          ? widget.current.substring(0, 4)
          : '',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1, indent: 16),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text('我的数据',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        ),
        if (courses.isNotEmpty)
          _dataLine('成绩单',
              '${courses.length} 门 · 已取得 ${_num(earned)} 学分'),
        if (choosed != null) _choosedLine(choosed, choosedCredits),
        const SizedBox(height: 2),
        if (isZju) ...[
          if (matchedPlan == null)
            _dataWarn('尚未匹配到本人培养方案：登录教务网并拉取数据后自动匹配，'
                '也可到「方案」页手动选择')
          else ...[
            _dataLine(
                '我的培养方案',
                '${matchedPlan.zymc}'
                '${matchedPlan.gradeLabel.isEmpty ? '' : '（${matchedPlan.gradeLabel}）'}'),
            if (matchedPlan.subtitle.isNotEmpty)
              _dataLine('方案信息', matchedPlan.subtitle),
            _dataLine(
                '匹配结果',
                '${matchedPlan.level.label} · '
                '${matchedPlan.candidateCount > 1 ? '候选 ${matchedPlan.candidateCount} 条' : '唯一匹配'}'),
            if (matchedPlan.id.isNotEmpty)
              _dataLine('教学计划号', matchedPlan.id),
            if (matchedPlan.ambiguous)
              _dataWarn('有多条相近方案，请到「方案」页确认本人方案'),
          ],
        ] else ...[
          _dataLine(
              '当前方案',
              '${builtin.zymc}'
              '${builtin.gradeLabel.isEmpty ? '' : '（${builtin.gradeLabel}）'}'),
          _dataLine('方案来源', '内置样例方案（非教务实时方案）'),
        ],
        if (planNote != null && planNote.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
            child: Text(planNote,
                style: TextStyle(
                    fontSize: 11, color: Colors.grey.shade700, height: 1.4)),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: widget.onGoPlan,
            icon: const Icon(Icons.open_in_new, size: 16),
            label: Text(isZju && matchedPlan == null ? '去匹配' : '查看方案'),
          ),
        ),
      ],
    );
  }

  Widget _choosedLine(XkListParseResult choosed, double credits) {
    if (choosed.state == 'data') {
      return _dataLine('本学期已选',
          '${choosed.courses.length} 门 · ${_num(credits)} 学分（在修，未出成绩）');
    }
    if (choosed.state == 'unavailable') {
      return _dataLine(
          '本学期已选',
          '暂不可用${choosed.issues.isEmpty ? '' : '：${choosed.issues.first}'}');
    }
    return _dataLine('本学期已选', '0 门');
  }

  Widget _dataLine(String label, String value) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 84,
                child: Text(label,
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade700))),
            Expanded(
                child: Text(value, style: const TextStyle(fontSize: 12))),
          ],
        ),
      );

  Widget _dataWarn(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 11.5, color: Colors.orange.shade800, height: 1.4)),
      );

  String _num(num v) {
    final d = v.toDouble();
    return (d - d.roundToDouble()).abs() < 1e-9
        ? '${d.round()}'
        : d.toStringAsFixed(1);
  }

  void _showDiagnostics(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('登录/取数诊断日志'),
        content: SizedBox(
          width: 460,
          height: 360,
          child: SingleChildScrollView(
            child: SelectableText(
              DiagnosticLog.instance.entries.isEmpty
                  ? '（暂无记录——用"教务网"模式登录即可产生步骤日志）'
                  : DiagnosticLog.instance.dump(),
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 12, height: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(
                  ClipboardData(text: DiagnosticLog.instance.dump()));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('复制并关闭'),
          ),
          TextButton(
            onPressed: () {
              DiagnosticLog.instance.clear();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }

  void _showCompliance(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('数据与合规'),
        // AI 段引用 ai_prompts.dart 的唯一常量（禁止在本页另写一份，文案分叉即事故）
        content: const Text('凭证存储：App 沙箱私有文件（用户态隔离，混淆编码）；'
            '会话 Cookie 仅驻内存，退出即清除；教务通道只读、无任何写操作。\n\n'
            '$kAiComplianceDataNote'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          FilledButton.tonalIcon(
            onPressed: () {
              widget.onClearData();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            icon: const Icon(Icons.delete_outline),
            label: const Text('一键清除全部本地数据'),
          ),
        ],
      ),
    );
  }
}

/// AI 解读配置卡（自持编辑状态；保存/测试经回调上抛，密钥输入默认遮蔽）。
/// 文案（标题/发送范围）统一来自 ai_prompts.dart 常量，禁止在本页另写一份（合规一致性）。
class _AiCard extends StatefulWidget {
  final AiConfig config;
  final Future<void> Function(AiConfig config) onSave;
  final Future<String> Function(AiConfig config) onTest;
  final Future<AiModelsResult> Function(AiConfig config) onListModels;
  const _AiCard(
      {required this.config,
      required this.onSave,
      required this.onTest,
      required this.onListModels});

  @override
  State<_AiCard> createState() => _AiCardState();
}

class _AiCardState extends State<_AiCard> {
  late AiProvider _provider = widget.config.provider;
  late final TextEditingController _base =
      TextEditingController(text: widget.config.baseUrl);
  late final TextEditingController _key =
      TextEditingController(text: widget.config.apiKey);
  late final TextEditingController _model =
      TextEditingController(text: widget.config.model);
  bool _busy = false;
  bool _loadingModels = false;
  bool _obscure = true;
  String? _result;
  AiModelInfo? _pickedModel; // 从模型列表选中的条目（用于展示上下文大小）
  late AiConfig _synced = widget.config;

  @override
  void didUpdateWidget(covariant _AiCard old) {
    super.didUpdateWidget(old);
    // 外部配置变化（启动加载 / 保存回写 / 一键清除）必须同步回编辑框。
    // 少做这一步：清除数据后卡片仍持有旧密钥，用户只按一次"保存"就把密钥复活
    // （评审实测的"一键清除不闭环"路径）；清除时 config 归 none，此处即清空输入。
    if (!identical(widget.config, _synced)) {
      _synced = widget.config;
      _provider = widget.config.provider;
      _base.text = widget.config.baseUrl;
      _key.text = widget.config.apiKey;
      _model.text = widget.config.model;
      _pickedModel = null;
    }
  }

  @override
  void dispose() {
    _base.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  AiConfig _collect() => _provider == AiProvider.pollinations
      // 公益端点形状固定（地址/模型内置、无 Key）：不读输入框——切走再切回时
      // 隐藏字段可能残留旧值，直接用预设保证存下去的配置永远可用。
      ? AiConfig.preset(AiProvider.pollinations)
      : AiConfig(
          provider: _provider,
          baseUrl: AiConfig.normalizeBaseUrl(_base.text),
          apiKey: _key.text.trim(),
          model: _model.text.trim(),
        );

  Future<void> _save() async {
    final cfg = _collect();
    await widget.onSave(cfg);
    _synced = cfg; // 保存即视为已同步，避免 didUpdateWidget 回写输入框
    if (mounted) {
      setState(() => _result = cfg.enabled
          ? '已保存并启用'
          : '已保存（尚未启用：需填写以 http(s):// 开头的接口地址与 API Key）');
    }
  }

  Future<void> _test() async {
    final cfg = _collect();
    await widget.onSave(cfg); // 测试即保存：避免"测了一个没存下来的配置"
    _synced = cfg;
    if (mounted) {
      setState(() {
        _busy = true;
        _result = null;
      });
    }
    final r = await widget.onTest(cfg);
    if (mounted) {
      setState(() {
        _busy = false;
        _result = r;
      });
    }
  }

  void _onProviderChanged(AiProvider p) {
    setState(() {
      _provider = p;
      _pickedModel = null;
      final preset = AiConfig.preset(p);
      if (preset.baseUrl.isNotEmpty && _base.text.trim().isEmpty) {
        _base.text = preset.baseUrl;
      }
      if (preset.model.isNotEmpty && _model.text.trim().isEmpty) {
        _model.text = preset.model;
      }
    });
  }

  /// 拉取模型列表并让用户选择（自定义 Key 场景）。
  /// 选中后只回填模型名；模型列表里的上下文大小在当前卡片内展示。
  Future<void> _fetchModels() async {
    if (_busy || _loadingModels) return;
    final cfg = _collect();
    if (cfg.provider == AiProvider.dify) {
      setState(() => _result = 'Dify 不提供模型列表接口，请手动填写模型名');
      return;
    }
    if (!cfg.enabled) {
      setState(() => _result = '请先填写接口地址与 API Key，再拉取模型列表');
      return;
    }
    setState(() {
      _loadingModels = true;
      _result = null;
    });
    AiModelsResult result;
    try {
      result = await widget.onListModels(cfg);
    } catch (_) {
      result = AiModelsResult.failure('请求异常（请检查接口地址格式后重试）');
    }
    if (!mounted) return;
    setState(() => _loadingModels = false);
    if (!result.ok) {
      setState(() => _result = '拉取模型失败：${result.error}');
      return;
    }
    final picked = await showDialog<AiModelInfo>(
      context: context,
      builder: (ctx) =>
          _ModelPickerDialog(models: result.models, note: result.note),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _model.text = picked.id;
      _pickedModel = picked;
      _result = '已选择模型 ${picked.id}'
          '（上下文 ${picked.contextLabel}${picked.maxOutputTokens == null ? '' : '，最大输出 ${picked.outputLabel}'}）';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 2),
            child: Text(kAiPanelTitle,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child:
                Text(kAiChatSendNotice,
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            // 五个段落在窄屏（360dp 手机）会超宽，套横向滚动兜底。
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<AiProvider>(
                segments: const [
                  ButtonSegment(value: AiProvider.none, label: Text('关闭')),
                  ButtonSegment(value: AiProvider.pollinations, label: Text('公益免费')),
                  ButtonSegment(value: AiProvider.openai, label: Text('OpenAI 兼容')),
                  ButtonSegment(value: AiProvider.anthropic, label: Text('Anthropic')),
                  ButtonSegment(value: AiProvider.dify, label: Text('Dify')),
                ],
                selected: {_provider},
                onSelectionChanged: (s) => _onProviderChanged(s.first),
              ),
            ),
          ),
          if (_provider == AiProvider.pollinations)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                  '内置公益端点（text.pollinations.ai，模型 openai），'
                  '无需接口地址与 API Key。免费通道偶有限流，'
                  '高峰期回复可能变慢或失败，可随时切回自建接口。',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            )
          else if (_provider != AiProvider.none) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _base,
                decoration: const InputDecoration(
                    labelText: '接口地址（例：https://api.deepseek.com/v1 或 https://api.anthropic.com）',
                    border: OutlineInputBorder()),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _key,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'API Key（仅存本机沙箱）',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                        _obscure ? Icons.visibility_off : Icons.visibility,
                        size: 18),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _model,
                decoration: InputDecoration(
                  labelText: '模型名（例：deepseek-chat / claude-opus-5-5；Dify 可留空）',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: '拉取模型列表',
                    onPressed: (_busy || _loadingModels) ? null : _fetchModels,
                    icon: _loadingModels
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.cloud_download_outlined, size: 18),
                  ),
                ),
              ),
            ),
            if (_pickedModel != null && _model.text.trim() == _pickedModel!.id)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  '上下文：${_pickedModel!.contextLabel}'
                  '${_pickedModel!.maxOutputTokens == null ? '' : ' · 最大输出：${_pickedModel!.outputLabel}'}'
                  '${_pickedModel!.sourceNote == null ? '' : ' · ${_pickedModel!.sourceNote}'}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _save,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('保存'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: (_busy || _provider == AiProvider.none) ? null : _test,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.network_check, size: 18),
                  label: const Text('测试连接'),
                ),
              ],
            ),
          ),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(_result!,
                  style: TextStyle(
                      fontSize: 12,
                      color: _result!.contains('正常') ? Colors.green : Colors.grey)),
            ),
        ],
      ),
    );
  }
}

/// 模型选择弹窗：搜索 + 列表（显示 id、显示名、上下文大小、最大输出）。
class _ModelPickerDialog extends StatefulWidget {
  const _ModelPickerDialog({required this.models, this.note});

  final List<AiModelInfo> models;
  final String? note;

  @override
  State<_ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends State<_ModelPickerDialog> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<AiModelInfo> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.models;
    return widget.models.where((m) {
      return m.id.toLowerCase().contains(q) ||
          (m.displayName?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    final note = widget.note?.trim() ?? '';
    return AlertDialog(
      title: Text('选择模型（共 ${widget.models.length} 个）'),
      content: SizedBox(
        width: double.maxFinite,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '搜索模型 id / 显示名',
                prefixIcon: Icon(Icons.search, size: 18),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            if (note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(note,
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: list.isEmpty
                  ? const Center(
                      child: Text('没有匹配的模型',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                    )
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final m = list[i];
                        final parts = <String>[
                          if (m.displayName != null &&
                              m.displayName!.trim().isNotEmpty &&
                              m.displayName != m.id)
                            m.displayName!,
                          '上下文 ${m.contextLabel}',
                          if (m.maxOutputTokens != null)
                            '最大输出 ${m.outputLabel}',
                          if (m.sourceNote != null) m.sourceNote!,
                        ];
                        return ListTile(
                          dense: true,
                          title: Text(m.id,
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 13)),
                          subtitle: Text(parts.join(' · '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11)),
                          onTap: () => Navigator.pop(context, m),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
