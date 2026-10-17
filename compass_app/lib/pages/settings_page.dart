/// pages/settings_page.dart — 设置页（Helechron Option 风格）：分组卡片列表。
/// 组：登录（教务网账号）/ 数据（数据源+方案+学期+运行）/ AI 解读 /
/// 关于（版本·致谢·数据与合规·登录诊断日志）。
/// 通用组已解散（任务 11）：诊断与合规入口并入「关于」组，
/// 登录组里的诊断/日志类信息默认折叠、点开可见。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/ai_config.dart';
import '../data/ai_prompts.dart';
import '../data/app_version.dart';
import '../data/diagnostic_log.dart';
import '../data/semester.dart';

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

  /// 分享给导师：导出脱敏学业分享包（realName 可选实名，默认匿名）。
  /// 返回导出结果提示文本（含课程数与落盘路径），失败返回原因。
  final Future<String> Function({bool realName})? onExportSharePack;

  /// 切换到导师审阅模式（审阅学生分享的包；本页签/教务会话保持不变，仅切视图）。
  final VoidCallback? onEnterTeacherMode;

  const SettingsPage(
      {super.key, required this.mode, required this.onModeChange,
      required this.major, required this.onMajorChange,
      required this.current, required this.onCurrentChange,
      required this.majors, required this.userCtl, required this.passCtl,
      required this.pasteCtl, required this.busy, required this.onRun,
      this.notice, this.loggedInAs, this.lastDataAt, required this.onClearData,
      required this.aiConfig, required this.onAiConfigChange,
      required this.onTestAi, this.onExportSharePack, this.onEnterTeacherMode});

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

  /// 「分享给导师」：实名导出选项 + 上次导出结果提示（本机内存态，不落盘）。
  bool _shareRealName = false;
  String? _shareHint;
  bool _shareBusy = false;

  Future<void> _doExportShare() async {
    final fn = widget.onExportSharePack;
    if (fn == null) return;
    setState(() {
      _shareBusy = true;
      _shareHint = null;
    });
    try {
      final msg = await fn(realName: _shareRealName);
      if (mounted) setState(() => _shareHint = msg);
    } catch (e) {
      if (mounted) setState(() => _shareHint = '导出失败：$e');
    } finally {
      if (mounted) setState(() => _shareBusy = false);
    }
  }

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
        _AiCard(config: aiConfig, onSave: onAiConfigChange, onTest: onTestAi),
        _groupHeader('分享给导师'),
        Card(
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Text('把当前审计结果导出为「学业档案分享包」（JSON）：'
                    '自动脱敏——不含学号、分数、绩点与教务凭证，默认匿名。'
                    '发送方式：复制后粘贴到聊天工具即可。',
                    style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.5)),
              ),
              CheckboxListTile(
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: _shareRealName,
                onChanged: (v) => setState(() => _shareRealName = v ?? false),
                title: const Text('实名导出（默认匿名同学）',
                    style: TextStyle(fontSize: 13)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _shareBusy || widget.onExportSharePack == null
                          ? null
                          : _doExportShare,
                      icon: _shareBusy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.share_outlined, size: 18),
                      label: const Text('导出到剪贴板'),
                    ),
                    const SizedBox(width: 8),
                    if (widget.onEnterTeacherMode != null)
                      OutlinedButton.icon(
                        onPressed: widget.onEnterTeacherMode,
                        icon: const Icon(Icons.school_outlined, size: 18),
                        label: const Text('导师审阅模式'),
                      ),
                  ],
                ),
              ),
              if (_shareHint != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(_shareHint!,
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ),
            ],
          ),
        ),
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
  const _AiCard(
      {required this.config, required this.onSave, required this.onTest});

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
  bool _obscure = true;
  String? _result;
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
      final preset = AiConfig.preset(p);
      if (preset.baseUrl.isNotEmpty && _base.text.trim().isEmpty) {
        _base.text = preset.baseUrl;
      }
      if (preset.model.isNotEmpty && _model.text.trim().isEmpty) {
        _model.text = preset.model;
      }
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
                Text(kAiSendNotice, style: TextStyle(fontSize: 11, color: Colors.grey)),
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
                decoration: const InputDecoration(
                    labelText: '模型名（例：deepseek-chat / claude-opus-5-5；Dify 可留空）',
                    border: OutlineInputBorder()),
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
