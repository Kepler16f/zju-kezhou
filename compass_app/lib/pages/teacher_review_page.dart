/// pages/teacher_review_page.dart — 导师模式：只读审阅学生自愿分享的学业档案。
///
/// 合规前提（docs/教师模式合规说明.md）：
///  - 教师态不登录教务、不发起任何网络请求（分享包本身即全部数据源）；
///  - 收到的包已由导出侧字段白名单脱敏（无分数/绩点/凭证），本页再校验一遍；
///  - 处理的是学生自愿提供的文件——审阅动作全在本机完成，不外传。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/share_pack.dart';
import '../widgets/report_view.dart';

/// 审阅页（纯回调注入引擎/AI/存储目录，方便 widget 测试用假引擎）。
class TeacherReviewPage extends StatefulWidget {
  /// 跑审计：注入已注册好方案的 engine（main.dart 真实引擎 / 测试假引擎）。
  final Map<String, dynamic> Function(Map<String, dynamic> record) onAudit;

  /// 注册内嵌方案快照（真实实现 = engine.registerRuntimePlan）。
  final void Function(String major, Map<String, dynamic> plan) onRegisterPlan;

  /// 持久化（沙箱缓存），用于重启恢复最近审阅；可为 null（无存储场景）。
  final Future<void> Function(String name, String content)? saveCache;
  final Future<String?> Function(String name)? readCache;

  /// AI 审阅助手（可选注入：null → 不显示 AI 按钮）。回调收到当前审阅报告，
  /// 由调用方脱敏后打开对话（发送范围/同意流程由 AI 层统一负责）。
  final void Function(Map<String, dynamic> report)? onAskAi;

  /// 沙箱 share/ 目录里已就绪的分享包路径列表（学生导出后本机可直接选取）。
  final Future<List<String>> Function()? listPacks;

  /// 按路径读包内容（listPacks 的配套通道）。
  final Future<String?> Function(String path)? readPackFile;

  const TeacherReviewPage({
    super.key,
    required this.onAudit,
    required this.onRegisterPlan,
    this.saveCache,
    this.readCache,
    this.onAskAi,
    this.listPacks,
    this.readPackFile,
  });

  @override
  State<TeacherReviewPage> createState() => _TeacherReviewPageState();
}

class _TeacherReviewPageState extends State<TeacherReviewPage> {
  static const _cacheKey = 'review_last_pack';

  final TextEditingController _pasteCtl = TextEditingController();
  Map<String, dynamic>? _pack; // 当前审阅的包（已 parse 通过）
  Map<String, dynamic>? _report; // 审计结果
  String? _error;
  List<String> _files = const [];
  String? _savedPath; // 导出审阅意见后的落盘路径

  @override
  void initState() {
    super.initState();
    _loadFiles();
    final read = widget.readCache;
    if (read != null) {
      unawaited(_restoreLast(read));
    }
  }

  @override
  void dispose() {
    _pasteCtl.dispose();
    super.dispose();
  }

  Future<void> _restoreLast(Future<String?> Function(String) read) async {
    try {
      final raw = await read(_cacheKey);
      if (raw == null || !mounted || _pack != null) return;
      final parsed = parseSharePack(raw);
      if (parsed is SharePackOk) {
        _apply(parsed.pack, silent: true);
      }
    } catch (_) {/* 恢复失败静默：首屏空态即可 */}
  }

  Future<void> _loadFiles() async {
    final list = widget.listPacks;
    if (list == null) return;
    try {
      final found = await list();
      if (mounted) setState(() => _files = found);
    } catch (_) {/* 目录不可读静默：文件通道是锦上添花，粘贴/剪贴板始终可用 */}
  }

  Future<void> _importFromPath(String path) async {
    final read = widget.readPackFile;
    if (read == null) return;
    final text = await read(path);
    if (text == null) {
      setState(() => _error = '文件读取失败：$path');
      return;
    }
    _importText(text);
  }

  /// 从剪贴板导入。
  Future<void> _importClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      setState(() => _error = '剪贴板为空：请先让学生发送分享包文件，复制其内容');
      return;
    }
    _importText(text);
  }

  /// 文本 → 校验 → 注册内嵌方案 → 跑审计 → 持久化。
  void _importText(String text) {
    final parsed = parseSharePack(text);
    switch (parsed) {
      case SharePackError(:final message):
        setState(() => _error = message);
      case SharePackOk(:final pack):
        _apply(pack);
    }
  }

  void _apply(Map<String, dynamic> pack, {bool silent = false}) {
    final major = '${(pack['student'] as Map)['major']}';
    final plan = sharePackPlan(pack);
    if (plan != null) {
      widget.onRegisterPlan(major, plan);
    }
    try {
      final report = widget.onAudit(sharePackToRecord(pack));
      if (report.containsKey('error')) {
        setState(() => _error = '审计失败：${report['error']}'
            '${plan == null ? '（分享包未内嵌方案，且本机无该专业方案缓存）' : ''}');
        return;
      }
      setState(() {
        _pack = pack;
        _report = report;
        _error = null;
        _savedPath = null;
      });
      unawaited(widget.saveCache?.call(_cacheKey, json.encode(pack)));
    } catch (e) {
      if (!silent) setState(() => _error = '审计异常：$e');
    }
  }

  Map<String, double> _totals() {
    final t = _report?['totals'] as Map<String, dynamic>?;
    if (t == null) return const {};
    return {
      'required': (t['required'] as num).toDouble(),
      'earned': (t['earned'] as num).toDouble(),
      'gap': (t['gap'] as num).toDouble(),
    };
  }

  /// 生成可复制/落盘的审阅意见文本（纯模板，数据全部来自本机审计结果。
  /// 注意：分享包无分数 → 引擎的 failed_recheck 类提醒天然不生成，
  /// 审阅意见只呈现板块缺口与结构性风险，这是脱敏设计的预期效果）。
  String _composeSummary() {
    final student = (_pack!['student'] as Map).cast<String, dynamic>();
    final t = _totals();
    final buf = StringBuffer();
    buf.writeln('课舟审阅意见（由课舟 App 导师模式生成）');
    buf.writeln('学生：${student['alias'] ?? '匿名同学'} ｜ 专业：${student['major']} '
        '｜ 入学：${student['grade']} 级 ｜ 当前学期：${student['current_semester']}');
    buf.writeln('学分达成：应修 ${_fmt(t['required'])}，'
        '已获 ${_fmt(t['earned'])}，缺口 ${_fmt(t['gap'])}。');
    final summary = (_report!['summary'] as List).cast<Map<String, dynamic>>();
    buf.writeln('板块达成：');
    for (final s in summary) {
      buf.writeln('  ${s['status'] ?? ''} ${s['module_path'] ?? s['module_id'] ?? ''}'
          '（${_fmt((s['earned'] as num?)?.toDouble())}/'
          '${_fmt((s['required'] as num?)?.toDouble())} 学分）');
    }
    final warnings = (_report!['warnings'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    if (warnings.isNotEmpty) {
      buf.writeln('风险提示：');
      for (final w in warnings) {
        buf.writeln('  · ${w['text'] ?? w['type'] ?? ''}');
      }
    }
    buf.write('（数据由学生本人自愿导出，不含分数与教务凭证；'
        '仅学业达成参考，不构成任何决定。）');
    return buf.toString();
  }

  static String _fmt(double? v) =>
      v == null ? '?' : (v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v');

  /// 审阅意见导出：复制 + 落盘到沙箱 share/ 目录（学生可带回）。
  Future<void> _exportSummary() async {
    final text = _composeSummary();
    await Clipboard.setData(ClipboardData(text: text));
    // 落盘走 saveCache 通道（真实实现会写 share/ 目录；测试环境仅回调计数）。
    await widget.saveCache?.call('review_summary_clip', text);
    if (mounted) {
      setState(() => _savedPath = '已复制到剪贴板（同时经存储通道落盘）');
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('审阅意见已复制，可直接粘贴发送给学生')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pack = _pack;
    final report = _report;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.school_outlined, size: 20),
                    const SizedBox(width: 8),
                    const Text('导师审阅模式',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text(pack == null ? '待导入' : '审阅中',
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  '仅审阅学生自愿分享的「学业档案分享包」：不登录教务、不访问任何'
                  '教师端接口；包内不含分数、绩点与教务凭证。',
                  style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.5),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        // 导入通道
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _pasteCtl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '或直接粘贴分享包 JSON 内容',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: () => _importText(_pasteCtl.text),
                      icon: const Icon(Icons.upload_file_outlined, size: 18),
                      label: const Text('导入粘贴内容'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _importClipboard,
                      icon: const Icon(Icons.content_paste_outlined, size: 18),
                      label: const Text('从剪贴板导入'),
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!,
                        style: const TextStyle(color: Colors.red, fontSize: 12)),
                  ),
                if (_files.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const Text('本机沙箱已就绪的分享包：',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  for (final p in _files)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.insert_drive_file_outlined, size: 18),
                      title: Text(p.split(RegExp(r'[/\\]')).last,
                          style: const TextStyle(fontSize: 12)),
                      trailing: const Icon(Icons.chevron_right, size: 18),
                      onTap: () => _importFromPath(p),
                    ),
                ],
              ],
            ),
          ),
        ),
        if (pack != null && report != null) ...[
          const SizedBox(height: 8),
          // 学生档案摘要（全部来自包内字段）
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${(pack['student'] as Map)['alias'] ?? '匿名同学'} 的学业档案',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('专业 ${(pack['student'] as Map)['major']} ｜ '
                      '${(pack['student'] as Map)['grade']} 级 ｜ '
                      '当前 ${(pack['student'] as Map)['current_semester']}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  Text('导出时间 ${(pack['exported_at'] ?? '').toString().substring(0, 19)}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          const SectionTitle('学业达成审计'),
          ReportSection(report: report),
          const SizedBox(height: 8),
          // 审阅意见导出 + AI 助手（可选注入）
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('审阅意见', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: _exportSummary,
                        icon: const Icon(Icons.copy_all_outlined, size: 18),
                        label: const Text('复制审阅意见'),
                      ),
                      if (widget.onAskAi != null)
                        OutlinedButton.icon(
                          onPressed: () => widget.onAskAi!(report),
                          icon: const Icon(Icons.smart_toy_outlined, size: 18),
                          label: const Text('AI 审阅助手'),
                        ),
                    ],
                  ),
                  if (_savedPath != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(_savedPath!,
                          style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    ),
                ],
              ),
            ),
          ),
        ] else ...[
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('还没有导入分享包',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  const Text(
                    '请学生：打开课舟 → 完成学业审计 → 设置页「分享给导师」→ 复制/发送文件；'
                    '你在此粘贴内容或点「从剪贴板导入」即可审阅。\n'
                    '分享包不含学号、分数、绩点与任何教务凭证（见包内 privacy_notice）。',
                    style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.6),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        const Text('审阅结果由学生提供的脱敏数据在本机计算，仅供指导参考；'
            '学籍与毕业审核以教务系统为准。',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}

/// 页内小节标题（与方案页 SectionHeader 同款字重；此处内联保持本页零跨页依赖）。
class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
        child: Text(text,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      );
}
