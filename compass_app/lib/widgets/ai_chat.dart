/// widgets/ai_chat.dart — 全局 AI 对话抽屉（诉求 #9：接入的 AI 做成用户对话窗口）。
///
/// 职责：把 AiClient 的单次问答包装成「多轮对话 + 可全局唤起」的底部抽屉——
/// 任何页面都能通过 [showAiChat] 呼出，与选课页里一次性「解读」面板互不影响。
/// 本组件只做「拼接与对话」这一件事：
///  - 链路：AiChatController（历史/忙碌/错误状态）→ AiClient.chat → 气泡渲染；
///  - 未配置（provider==none 或 !enabled）时只显示引导空态与「去设置」按钮，
///    发送入口禁用，绝不发起任何请求（AiClient 侧还有 config.enabled 兜底，
///    未配置直接返回 AiFailure(notConfigured)，不触网）；
///  - 零新依赖：只用 flutter/material、dart:math 与仓库内既有 data 层。
///
/// 脱敏契约（合规红线，违反即事故）：
///  - 发送给 AI 的内容绝不含姓名、学号、教务凭证、Cookie、原始成绩单/方案原文：
///    脱敏是**调用方**的职责——[AiChatSheet.contextSummary] 必须是调用方
///    用 ai_prompts 的白名单工具（如 buildAiContextJson）预先清洗好的
///    **已脱敏摘要**；本组件不校验、不清洗上下文内容，拿到什么就拼什么。
///    全局助手按产品口径会携带课程名/学分/成绩，用于回答学业问题；
///    不得在此文件里"顺手"塞入页面原始数据或身份字段。
///  - 上下文摘要与识屏 OCR 只进 system 消息，**不渲染、不写入 history**，
///    用户气泡只显示原始提问；识屏首次发送前必须弹同意框，可随时关闭自动识屏。
///  - 渲染侧兜底：assistant 气泡显示前一律过 sanitizeAiOutput（输出侧第二道
///    防线），命中越界措辞即整条替换为边界文案。注意这只作用于「显示」——
///    历史里存的仍是原文，下一轮 messages 会携带原文，故上面第一条同样约束
///    注入的上下文与用户自由输入（输入框提示语即为此而设）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/ai_client.dart';
import '../data/ai_config.dart';
import '../data/ai_knowledge.dart';
import '../data/ai_prompts.dart';
import '../data/screen_ocr.dart';

/// 屏幕文字识别的注入缝：默认真机截屏（Windows 内置 OCR）；
/// 测试注入假实现，避免 widget test 起 powershell 子进程扫真实桌面。
typedef ScreenTextCapture = Future<ScreenOcrResult> Function();

/// 历史截断上限（消息条数，user/assistant 各算一条）。
const int kAiChatHistoryLimit = 12;

/// 发送前裁剪历史：最多保留最近 [kAiChatHistoryLimit] 条，并保证首条是 user。
///
/// 为什么必须以 user 开头：多轮消息若以 assistant 开头，部分严格的 OpenAI 兼容
/// 网关会以「消息序列非法」拒绝（400），而且开头一段无人提问的独白没有语境价值。
/// 截断保留的是**原列表的尾段**（最近对话），若尾段首条是 assistant 就丢弃它，
/// 直至重新以 user 开头（最坏情况返回空表，本轮仅剩新 user 消息）。
List<Map<String, String>> trimHistory(List<Map<String, String>> h) {
  var kept = h.length <= kAiChatHistoryLimit
      ? List<Map<String, String>>.of(h)
      : h.sublist(h.length - kAiChatHistoryLimit);
  while (kept.isNotEmpty && kept.first['role'] != 'user') {
    kept = kept.sublist(1);
  }
  return kept;
}

/// 拼接单条 user 消息：结构化上下文（调用方负责脱敏，见文件头契约）与用户问题
/// 分节，让模型能区分「附带数据」与「要回答的问题」。context 为空则原样返回问题。
String composeUserMessage(String? context, String text) {
  final ctx = context?.trim() ?? '';
  if (ctx.isEmpty) return text;
  return '[上下文]\n$ctx\n[问题]\n$text';
}

/// 屏幕指代触发词：命中即认为用户在问“屏幕上/当前页面里的东西”。
/// 刻意不收裸词「这个」——太容易把普通问题误判成识屏请求。
const List<String> kScreenQuestionTriggers = <String>[
  '屏幕',
  '当前页面',
  '这个页面',
  '页面上',
  '界面上',
  '上面写的',
  '上面这个',
  '图中',
  '截图',
  '这张图',
  '列表里',
  '屏幕里',
  '这里写的',
];

/// 判断一句话是否在指代屏幕内容（纯函数，供 UI 与单测使用）。
bool looksLikeScreenQuestion(String text) {
  final compact = text.replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty) return false;
  for (final t in kScreenQuestionTriggers) {
    if (compact.contains(t)) return true;
  }
  return false;
}

/// 全局 AI 对话的会话状态：历史、忙碌标记与最近一次失败文案。
///
/// 由接线层创建并长期持有（如 ValueNotifier<AiChatController> 或直接字段），
/// 跨页面复用同一份对话；本组件不监听它，抽屉打开时才 setState 重绘。
class AiChatController {
  AiChatController({
    AiKnowledgeBase? knowledgeBase,
    AiClient Function(AiConfig config)? clientFactory,
  })  : knowledgeBase = knowledgeBase ?? const EmptyAiKnowledgeBase(),
        _clientFactory = clientFactory ?? ((cfg) => AiClient(cfg));

  /// 知识库检索接口（默认空实现；收到语料后替换即可）。
  final AiKnowledgeBase knowledgeBase;

  /// 客户端工厂（单测注入假 sender 用；生产走默认 AiClient）。
  final AiClient Function(AiConfig config) _clientFactory;

  /// 历史截断上限（同 [kAiChatHistoryLimit]）。
  static const int kHistoryLimit = kAiChatHistoryLimit;

  /// 对话历史（不含 system），元素形状 {'role': 'user'|'assistant', 'content': '...'}。
  /// 只存用户原始问题与模型回答——上下文摘要进 system，不落历史、不出现在气泡里。
  final List<Map<String, String>> history = <Map<String, String>>[];

  /// 是否有一次请求在途（抽屉 UI 据此转圈并禁用输入/发送）。
  bool busy = false;

  /// 最近一次失败的中文可读文案（AiClient 已保证不含密钥；null 表示无错误）。
  String? lastError;

  /// 本次会话是否已确认发送范围（公益免费端点默认开启后，首次发送仍需确认一次）。
  bool consented = false;

  /// 自动识屏：提问里出现「屏幕/当前页面/截图」等词时，自动读取屏幕文字。
  /// 首次发送屏幕内容前仍会弹一次 [kAiScreenNotice] 同意框。
  bool autoScreen = true;

  /// 本次会话是否已同意发送屏幕文字（清空会话时重置）。
  bool screenConsent = false;

  /// 清空会话（抽屉标题行的「清空」按钮调用）。忙碌中清空不安全，先判 busy。
  void clear() {
    if (busy) return;
    history.clear();
    lastError = null;
    consented = false; // 会话重置：发送范围确认也重来（与清除历史同语义）
    screenConsent = false;
  }

  /// 发送一轮对话：trimHistory(history) + 本轮 user 一起提交。
  ///
  /// [contextSummary] 是调用方已脱敏的本机数据摘要，会拼进 system 消息；
  /// [screenText] 是本次识屏 OCR 文本，同样只进 system。两者都不会写入 history，
  /// 也不会出现在用户气泡里（需求：补充上下文不展示）。
  /// [onDelta] 非空时走流式请求，每段增量回调一次。
  ///
  /// 返回本次 assistant 回复文本；输入为空白、已有请求在途、或调用失败时返回
  /// null——失败只设 [lastError]，**不写入 history**，保证下一轮 messages 与
  /// 模型实际见过的内容一致，也让用户原样重发不会变成「回答自己的重复提问」。
  Future<String?> send(
    AiConfig cfg,
    String userText, {
    String? contextSummary,
    String? screenText,
    void Function(String delta)? onDelta,
  }) async {
    final content = userText.trim();
    if (content.isEmpty || busy) return null;
    busy = true;
    lastError = null;
    try {
      // 知识库检索失败不得阻断对话：答疑是增强能力。
      var knowledge = const <AiKnowledgeSnippet>[];
      try {
        knowledge = await knowledgeBase.retrieve(content);
      } catch (_) {/* 忽略：按无知识库片段继续 */}
      final system = buildChatSystemPrompt(
        contextJson: contextSummary,
        screenText: screenText,
        knowledge: knowledge,
      );
      final messages = trimHistory(history)
        ..add(<String, String>{'role': 'user', 'content': content});
      final outcome = await _clientFactory(cfg)
          .chat(system: system, messages: messages, onDelta: onDelta);
      if (outcome is AiReply) {
        history
          ..add(<String, String>{'role': 'user', 'content': content})
          ..add(<String, String>{'role': 'assistant', 'content': outcome.text});
        return outcome.text;
      }
      lastError = (outcome as AiFailure).message;
      return null;
    } on Exception catch (e) {
      // chat() 已把 Exception 翻译成 AiFailure，走到这里说明是意外（如注入的
      // 假 sender 抛异常）；兜底成可读文案，绝不让忙碌态软锁死。Error 不捕——
      // 编程缺陷应暴露（与 ai_client.dart 红线一致）。
      lastError = '请求异常（$e）';
      return null;
    } finally {
      busy = false;
    }
  }
}

/// 打开全局 AI 对话抽屉。任何页面（悬浮按钮、菜单、卡片）都可直接调用。
///
/// [contextSummary] 必须是调用方已脱敏的结构化摘要（见文件头契约）。
/// 键盘适配：isScrollControlled 放开高度限制后，抽屉本体用
/// MediaQuery.viewInsetsOf(context).bottom 垫底并等量让出高度——输入行始终
/// 贴在键盘上沿，标题与顶部内容不位移（不用 sheet 的默认键盘避让，
/// 因为默认避让只顶内容不缩高度，大输入框会顶穿屏幕）。
Future<void> showAiChat(
  BuildContext context, {
  required AiChatController controller,
  required AiConfig config,
  VoidCallback? onGoSettings,
  String? contextSummary,
  String? Function()? contextProvider,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // 键盘 inset 自行处理，安全区（导航条/侧割）也并入 padding，避免双重让位。
    useSafeArea: false,
    enableDrag: false, // 列表滚动手势优先，关闭走标题栏按钮
    builder: (sheetContext) {
      final mq = MediaQuery.of(sheetContext);
      final inset = math.max(mq.viewInsets.bottom, mq.viewPadding.bottom);
      final body = mq.size.height * 0.8 - inset;
      return Padding(
        padding: EdgeInsets.only(bottom: inset),
        child: SizedBox(
          height: math.max(body, 200.0),
          child: AiChatSheet(
            controller: controller,
            config: config,
            onGoSettings: onGoSettings,
            contextSummary: contextSummary,
            contextProvider: contextProvider,
          ),
        ),
      );
    },
  );
}

/// AI 对话抽屉主体（多轮对话；「去设置」回调交给接线层决定跳转方式）。
class AiChatSheet extends StatefulWidget {
  const AiChatSheet({
    super.key,
    required this.controller,
    required this.config,
    this.onGoSettings,
    this.contextSummary,
    this.contextProvider,
    this.capture = captureScreenText,
  });

  final AiChatController controller;
  final AiConfig config;

  /// 屏幕识别注入缝（默认真机截屏；测试传假实现，不起 powershell）。
  final ScreenTextCapture capture;

  /// 未配置时「去设置页开启 AI」按钮的回调；由接线层实现跳转。
  final VoidCallback? onGoSettings;

  /// 本次对话附带的结构化数据摘要。
  ///
  /// **调用方必须传入已脱敏摘要**（文件头契约）：不得包含姓名、学号、教务凭证等
  /// 个人信息；推荐用 ai_prompts 的白名单工具构造（如 [buildAiContextJson]）。
  /// 非空时注入每一轮的 system 消息，**不展示给用户**，也不写入历史气泡。
  final String? contextSummary;

  /// 每轮发送前重新生成上下文摘要（优先于 [contextSummary]）。
  /// 这样聊天过程中页面数据更新后，AI 能读到最新课程/方案/已选数据。
  final String? Function()? contextProvider;

  @override
  State<AiChatSheet> createState() => _AiChatSheetState();
}

class _AiChatSheetState extends State<AiChatSheet> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// 在途请求对应的 user 气泡文本（历史里成功才有，失败即撤，与 lastError 呼应）。
  String? _pendingUserText;

  /// 流式回复的已收到片段（只在当前请求在途时渲染；成功后转入 history）。
  String? _streamingText;

  /// 识屏状态提示（只显示“正在读取/已读取”等状态，不显示屏幕正文）。
  String? _screenNote;

  /// 屏幕识别进行中（按钮转圈 + 禁用），完成后把文字填进输入框待用户确认。
  bool _capturing = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _configured => widget.config.enabled;
  bool get _busy => widget.controller.busy;

  /// 识别屏幕文字 → 填入输入框（用户可编辑/清空后再发送，绝不自动外发）。
  /// 屏幕内容可能含密码/个人信息，发送确认权始终在用户手里（文件头红线）。
  Future<void> _captureOcr() async {
    if (_capturing || _busy) return;
    setState(() => _capturing = true);
    final r = await widget.capture();
    if (!mounted) return;
    setState(() {
      _capturing = false;
      if (r.isSuccess) {
        final t = r.text.trim();
        if (t.isEmpty) {
          widget.controller.lastError = '屏幕上没识别到文字';
        } else {
          _input.text = _input.text.trim().isEmpty
              ? '[屏幕内容]\n$t'
              : '${_input.text}\n\n[屏幕内容]\n$t';
          _input.selection =
              TextSelection.collapsed(offset: _input.text.length);
        }
      } else {
        widget.controller.lastError = r.error;
      }
    });
  }

  /// 滚到底部（放在帧尾，等 ListView 完成布局）。
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final ctrl = widget.controller;
    if (ctrl.busy || !_configured || _capturing) return;
    final raw = _input.text.trim();
    if (raw.isEmpty) return;
    // 首次发送前确认发送范围（会话内一次；与选课页 _aiPanel 同口径——
    // 公益免费端点出厂即启用后，合规上仍要保证"用户知道发出去的是什么"）。
    if (!ctrl.consented) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('发送范围确认'),
          // 全局助手会读取学业/方案/选课三块数据，口径与选课页一次性解读不同。
          content: const Text(kAiChatSendNotice),
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
      if (ok != true || !mounted) return;
      ctrl.consented = true;
    }

    // 识屏：提问指代屏幕时自动读取。首次必须显式同意；内容只进 system。
    String? screenText;
    var screenNote = '';
    if (ctrl.autoScreen && looksLikeScreenQuestion(raw)) {
      var allow = ctrl.screenConsent;
      if (!allow) {
        final choice = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('识屏发送确认'),
            content: const Text(kAiScreenNotice),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('不读取，直接发送')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('读取并发送')),
            ],
          ),
        );
        if (!mounted || choice == null) return;
        if (choice) {
          ctrl.screenConsent = true;
          allow = true;
        }
      }
      if (allow) {
        setState(() {
          _capturing = true;
          _screenNote = '正在读取屏幕…';
        });
        final r = await widget.capture();
        if (!mounted) return;
        setState(() => _capturing = false);
        if (!r.isSuccess) {
          ctrl.lastError = r.error;
          setState(() => _screenNote = null);
          return;
        }
        final t = r.text.trim();
        if (t.isEmpty) {
          screenNote = '屏幕上没有识别到文字';
        } else {
          screenText = t;
          screenNote = '已读取屏幕文字（仅本次发送）';
        }
      }
    }

    _pendingUserText = raw;
    _streamingText = '';
    _screenNote = screenNote.isEmpty ? null : screenNote;
    setState(() {}); // 立刻渲染 user 气泡 + 转圈
    final freshContext =
        widget.contextProvider?.call() ?? widget.contextSummary;
    final reply = await ctrl.send(
      widget.config,
      raw,
      contextSummary: freshContext,
      screenText: screenText,
      onDelta: (delta) {
        if (!mounted) return;
        setState(() => _streamingText = '${_streamingText ?? ''}$delta');
        _scrollToBottom();
      },
    );
    if (!mounted) return; // 等待期间抽屉可能已被关闭
    setState(() {
      _pendingUserText = null;
      _streamingText = null;
      if (reply != null) _input.clear();
    });
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final theme = Theme.of(context);
    // 气泡列表 = 历史 + 在途提问 + 流式回复片段。
    // 数据摘要只进 system，永远不在这里渲染（需求：补充上下文不展示给用户）。
    final bubbles = <(String, String)>[
      for (final m in ctrl.history)
        (m['role'] ?? '', m['content'] ?? ''),
      if (_pendingUserText != null) ('user', _pendingUserText!),
      if ((_streamingText ?? '').isNotEmpty) ('assistant', _streamingText!),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _titleBar(theme),
        Expanded(
          child: !_configured
              ? _notConfiguredCard(theme)
              : bubbles.isEmpty
                  ? Center(
                      child: Text('有什么关于培养方案或选课的问题，可以直接问课舟。',
                          style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant)),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                      itemCount: bubbles.length,
                      itemBuilder: (_, i) =>
                          _bubble(theme, bubbles[i].$1, bubbles[i].$2),
                    ),
        ),
        if (ctrl.lastError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(ctrl.lastError!,
                style: TextStyle(fontSize: 12, color: theme.colorScheme.error)),
          ),
        if (_screenNote != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(_screenNote!,
                style: TextStyle(
                    fontSize: 11, color: theme.colorScheme.primary)),
          ),
        _inputRow(theme),
      ],
    );
  }

  Widget _titleBar(ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
        child: Row(
          children: [
            Icon(Icons.smart_toy_outlined,
                size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('AI 助手',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            IconButton(
              tooltip: '清空对话',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => setState(widget.controller.clear),
            ),
            IconButton(
              tooltip: '关闭',
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );

  /// 未配置空态卡：只引导去设置，不发起任何请求（发送按钮同步禁用）。
  Widget _notConfiguredCard(ThemeData theme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 36, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 10),
              Text('还没有开启 AI 服务', style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text('在设置页「AI 解读」中配置提供方、接口地址与 API Key 后，'
                  '即可在这里与课舟对话。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: widget.onGoSettings,
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: const Text('去设置页开启 AI'),
              ),
            ],
          ),
        ),
      );

  Widget _inputRow(ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: widget.controller.autoScreen
                  ? '自动识屏已开启：提问提到屏幕/当前页面时自动读取（点击关闭）'
                  : '自动识屏已关闭（点击开启）',
              onPressed: (_configured && !_busy && !_capturing)
                  ? () => setState(() =>
                      widget.controller.autoScreen =
                          !widget.controller.autoScreen)
                  : null,
              icon: Icon(
                Icons.screen_search_desktop,
                size: 20,
                color: widget.controller.autoScreen
                    ? theme.colorScheme.primary
                    : theme.disabledColor,
              ),
            ),
            IconButton(
              tooltip: '识别屏幕文字填入输入框（Windows 内置离线 OCR，不上传；'
                  '识别结果需你手动确认后发送）',
              onPressed: (_configured && !_busy && !_capturing)
                  ? _captureOcr
                  : null,
              icon: _capturing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.crop_free),
            ),
            Expanded(
              child: TextField(
                key: const Key('aiChatInput'),
                controller: _input,
                enabled: _configured && !_busy,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(), // 回车即发送
                decoration: InputDecoration(
                  hintText: _configured ? '提问（请勿输入个人信息）' : '未配置 AI，暂不可发送',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 56,
              height: 40,
              child: _busy
                  // busy 时按钮位换成圈（尺寸锁定，避免行高跳动）。
                  ? Center(
                      child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: theme.colorScheme.primary)))
                  : FilledButton(
                      onPressed: _configured && !_busy && !_capturing
                          ? _send
                          : null,
                      child: const Text('发送')),
            ),
          ],
        ),
      );

  /// 单条气泡：user 靠右 primary 底、assistant 靠左 surface 底；
  /// assistant 显示前过 sanitizeAiOutput（输出侧第二道防线，见文件头契约）。
  Widget _bubble(ThemeData theme, String role, String content) {
    final isUser = role == 'user';
    final text = isUser ? content : sanitizeAiOutput(content);
    final scheme = theme.colorScheme;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        // 两侧留白：窄屏上两个 0.86 相加会顶破屏幕。
        margin: EdgeInsets.only(
            bottom: 8, left: isUser ? 44 : 0, right: isUser ? 0 : 44),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color:
              isUser ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(isUser ? 12 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 12),
          ),
        ),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
        child: SelectableText(text,
            style: const TextStyle(fontSize: 14, height: 1.5)),
      ),
    );
  }
}
