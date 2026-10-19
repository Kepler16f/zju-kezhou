/// widgets/ai_chat.dart — 全局 AI 对话抽屉（诉求 #9：接入的 AI 做成用户对话窗口）。
///
/// 职责：把 AiClient 的单次问答包装成「多轮对话 + 可全局唤起」的底部抽屉——
/// 任何页面都能通过 [showAiChat] 呼出，与选课页里一次性「解读」面板互不影响。
/// 本组件只做「拼接与对话」这一件事：
///  - 链路：AiChatController（历史/忙碌/错误状态）→ AiClient.chat → 气泡渲染；
///  - 未配置（provider==none 或 !enabled）时只显示引导空态与「去设置」按钮，
///    发送入口禁用，绝不发起任何请求（AiClient 侧还有 config.enabled 兜底，
///    未配置直接返回 AiFailure(notConfigured)，不触网）；
///    开关的「开启」动作由接线层的入口弹窗完成（main.dart 写存档后以启用态
///    config 唤起本组件即可正常对话）；本组件只按传入 config 渲染，不写配置。
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
///  - 渲染侧兜底：assistant 气泡显示前一律过 sanitizeChatOutput（需求 #6：全局
///    助手允许给具体候选与方向性建议，仅拦"替用户拍板成品课表/断言选上/越权
///    承诺选课"三条硬红线）。注意这只作用于「显示」——
///    历史里存的仍是原文，下一轮 messages 会携带原文，故上面第一条同样约束
///    注入的上下文与用户自由输入（输入框提示语即为此而设）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/ai_client.dart';
import '../data/ai_config.dart';
import '../data/ai_knowledge.dart';
import '../data/ai_prompts.dart';
import '../data/screen_ocr.dart';
import 'ai_message_body.dart';

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
/// 由接线层创建并长期持有，跨页面复用同一份对话；sheet 通过 ChangeNotifier
/// 只监听、不持有在途文本，因此关闭抽屉不会中断请求。
/// 单条消息的角色。
enum AiChatMessageRole { user, assistant }

/// 单条消息的生命周期。
///
/// queued：已入 FIFO 队列，等待当前请求结束；
/// sending：用户消息正在请求（对应的 assistant 占位在生成中）；
/// streaming：助手已被流式写入部分文本；
/// done：完整成功；failed：用户消息发送失败（保留，可重试/撤回）；
/// incomplete：请求中断后保留的半截助手回答。
enum AiChatMessageStatus {
  queued,
  sending,
  streaming,
  done,
  failed,
  incomplete
}

/// 对话中的一条稳定消息。
///
/// id 在重试时保持不变的是 user 消息；每次尝试的 assistant 消息使用新 id。
/// 状态与 content 由 [AiChatController] 单线程更新，sheet 只读渲染。
class AiChatMessage {
  AiChatMessage._({
    required this.id,
    required this.role,
    required this.content,
    required this.status,
    this.error,
  });

  final String id;
  final AiChatMessageRole role;
  String content;
  AiChatMessageStatus status;
  String? error;

  bool get isUser => role == AiChatMessageRole.user;
  bool get isAssistant => role == AiChatMessageRole.assistant;
  bool get isFailed => status == AiChatMessageStatus.failed;
  bool get isQueued => status == AiChatMessageStatus.queued;
  bool get isWithdrawable => isUser && (isQueued || isFailed);
  bool get isRetryable => isUser && isFailed;
  bool get isPrioritizable => isUser && isQueued;

  Map<String, String> get historyEntry =>
      <String, String>{'role': role.name, 'content': content};
}

/// 一次发送所需的不可变参数（重试沿用首次发送时的配置/上下文）。
class _AiChatRequestMeta {
  const _AiChatRequestMeta({
    required this.config,
    this.contextSummary,
    this.screenText,
    this.onDelta,
  });

  final AiConfig config;
  final String? contextSummary;
  final String? screenText;
  final void Function(String delta)? onDelta;
}

/// 全局 AI 对话的会话状态：消息、队列、在途请求与未读计数。
///
/// 由接线层创建并长期持有（main.dart 里已有 `final _aiCtrl = AiChatController()`），
/// 抽屉关闭后 controller 仍持有全部消息与流式文本，重新打开即可立即渲染。
///
/// 未读计数（父级 Badge 接线用）：
///  - [unreadCount] 是 ChangeNotifier 上的计数；抽屉关闭时，每条助手回复或每次
///    请求失败最多 +1（同一消息 id 只计一次）；
///  - [markSheetOpened] 清零；[markSheetClosed] 按需求消耗一条计数（>0 时 -1）；
///  - 父级只需 `AnimatedBuilder(animation: controller, ...)` / `ListenableBuilder`
///    监听 controller，并把 [unreadCount] 接到 Badge 即可，无需改本组件。
class AiChatController extends ChangeNotifier {
  AiChatController({
    AiKnowledgeBase? knowledgeBase,
    AiClient Function(AiConfig config)? clientFactory,
  })  : knowledgeBase = knowledgeBase ?? const EmptyAiKnowledgeBase(),
        _clientFactory = clientFactory ?? ((cfg) => AiClient(cfg));

  /// 知识库检索接口（默认空实现）。资产加载完成后由接线层替换
  /// （需求 #6：内置浙大选课知识库，rootBundle 读 assets/knowledge/）。
  AiKnowledgeBase knowledgeBase;

  /// 客户端工厂（单测注入假 sender 用；生产走默认 AiClient）。
  final AiClient Function(AiConfig config) _clientFactory;

  /// 历史截断上限（同 [kAiChatHistoryLimit]）。
  static const int kHistoryLimit = kAiChatHistoryLimit;

  final List<AiChatMessage> _messages = <AiChatMessage>[];
  final List<String> _queue = <String>[];
  final Map<String, _AiChatRequestMeta> _requestMeta =
      <String, _AiChatRequestMeta>{};
  final Map<String, Completer<String?>> _waiters =
      <String, Completer<String?>>{};
  final Map<String, String> _assistantByUser = <String, String>{};
  final Set<String> _unreadCounted = <String>{};

  String? _activeId;
  AiCancelToken? _activeCancel;
  int _activeEpoch = 0;
  int _sequence = 0;
  bool _sheetOpen = false;
  int _unreadCount = 0;
  String? _lastError;
  String _draft = '';
  bool _consented = false;
  bool _autoScreen = true;
  bool _screenConsent = false;

  /// 只读消息快照（按时间顺序，含排队/失败/未完成消息）。
  List<AiChatMessage> get messages =>
      List<AiChatMessage>.unmodifiable(_messages);

  /// 已成功完成的历史派生视图（OpenAI messages 形状）。
  ///
  /// 失败/排队/未完成的 user 消息仍保留在 [messages] 里供撤回或重试，但不会进入
  /// 下一次请求的上下文；只有 done 的 user/assistant 才构成真正的多轮历史。
  List<Map<String, String>> get history =>
      List<Map<String, String>>.unmodifiable(<Map<String, String>>[
        for (final m in _messages)
          if (m.status == AiChatMessageStatus.done) m.historyEntry,
      ]);

  /// 导出可持久化的对话快照（JSON 字符串，用户反馈 #14：重开 App 历史不丢）。
  ///
  /// 只导可见消息；在途态（queued/sending/streaming）不导——重开时假装还在
  /// 请求会误导用户。失败消息保留 error 文案（可撤回/重发）。
  String exportHistory() {
    final rows = <Map<String, String>>[];
    for (final m in _messages) {
      if (m.status == AiChatMessageStatus.queued ||
          m.status == AiChatMessageStatus.sending ||
          m.status == AiChatMessageStatus.streaming) {
        continue;
      }
      if (m.content.trim().isEmpty && m.status != AiChatMessageStatus.failed) {
        continue;
      }
      rows.add(<String, String>{
        'role': m.role.name,
        'content': m.content,
        'status': m.status.name,
        if (m.error != null) 'error': m.error!,
      });
    }
    return jsonEncode(rows);
  }

  /// 恢复 [exportHistory] 的快照：坏 JSON/非 List/缺字段逐条跳过，绝不抛异常；
  /// 恢复的消息不触发任何网络（不调 clientFactory），busy 恒为 false。
  /// assistant 的 failed 态降级为 incomplete（失败状态只属于 user 气泡的语义）。
  void importHistory(String? serialized) {
    final raw = serialized?.trim() ?? '';
    if (raw.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! List) return;
    final restored = <AiChatMessage>[];
    for (final row in decoded) {
      if (row is! Map) continue;
      final roleName = '${row['role'] ?? ''}';
      final role = roleName == 'user'
          ? AiChatMessageRole.user
          : roleName == 'assistant'
              ? AiChatMessageRole.assistant
              : null;
      final content = '${row['content'] ?? ''}';
      if (role == null || content.trim().isEmpty) continue;
      var status = AiChatMessageStatus.done;
      switch ('${row['status'] ?? ''}') {
        case 'failed':
          status = AiChatMessageStatus.failed;
          break;
        case 'incomplete':
          status = AiChatMessageStatus.incomplete;
          break;
        default:
          status = AiChatMessageStatus.done;
      }
      if (role == AiChatMessageRole.assistant &&
          status == AiChatMessageStatus.failed) {
        status = AiChatMessageStatus.incomplete;
      }
      final err = row['error'];
      restored.add(AiChatMessage._(
        id: 'h${++_sequence}',
        role: role,
        content: content,
        status: status,
        error: err is String && err.isNotEmpty ? err : null,
      ));
    }
    _messages
      ..clear()
      ..addAll(restored);
    _queue.clear();
    _requestMeta.clear();
    _assistantByUser.clear();
    _activeId = null;
    _activeCancel = null;
    notifyListeners();
  }

  /// 是否有一次请求在途（输入框不再因 busy 禁用，只用于标题栏 spinner/停止按钮）。
  bool get busy => _activeId != null;

  /// 等待发送的 FIFO 消息条数。
  int get queuedCount => _queue.length;

  /// 抽屉未打开期间累计的未读数（父级 Badge 数据源）。
  int get unreadCount => _unreadCount;

  /// 当前页面草稿（撤回时自动回填，sheet 读取后写入输入框）。
  String get draft => _draft;
  set draft(String value) {
    if (_draft == value) return;
    _draft = value;
    notifyListeners();
  }

  /// 最近一次失败的中文可读文案（AiClient 已保证不含密钥；null 表示无错误）。
  String? get lastError => _lastError;
  set lastError(String? value) {
    if (_lastError == value) return;
    _lastError = value;
    notifyListeners();
  }

  /// 本次会话是否已确认发送范围（公益免费端点经入口弹窗开启后，首次发送仍需确认一次）。
  bool get consented => _consented;
  set consented(bool value) {
    if (_consented == value) return;
    _consented = value;
    notifyListeners();
  }

  /// 自动识屏：提问里出现「屏幕/当前页面/截图」等词时，自动读取屏幕文字。
  /// 首次发送屏幕内容前仍会弹一次 [kAiScreenNotice] 同意框。
  bool get autoScreen => _autoScreen;
  set autoScreen(bool value) {
    if (_autoScreen == value) return;
    _autoScreen = value;
    notifyListeners();
  }

  /// 本次会话是否已同意发送屏幕文字（清空会话时重置）。
  bool get screenConsent => _screenConsent;
  set screenConsent(bool value) {
    if (_screenConsent == value) return;
    _screenConsent = value;
    notifyListeners();
  }

  /// 抽屉打开：清零未读。父级可在 showAiChat 前后调用（showAiChat 已自动调用）。
  void markSheetOpened() {
    _sheetOpen = true;
    _unreadCount = 0;
    notifyListeners();
  }

  /// 抽屉关闭：按需求消耗一条未读计数（没有未读时保持 0）。
  void markSheetClosed() {
    _sheetOpen = false;
    if (_unreadCount > 0) _unreadCount--;
    notifyListeners();
  }

  /// 清空会话（抽屉标题行的「清空」按钮调用）。忙碌中清空不安全，先判 busy。
  void clear() {
    if (busy) return;
    for (final waiter in _waiters.values) {
      if (!waiter.isCompleted) waiter.complete(null);
    }
    _messages.clear();
    _queue.clear();
    _requestMeta.clear();
    _waiters.clear();
    _assistantByUser.clear();
    _unreadCounted.clear();
    _lastError = null;
    _unreadCount = 0;
    _draft = '';
    _consented = false; // 会话重置：发送范围确认也重来（与清除历史同语义）
    _screenConsent = false;
    notifyListeners();
  }

  /// 发送一轮对话。空闲时立即开始；请求在途时进入 FIFO 队列并显示 queued。
  ///
  /// 返回本次 user 消息对应的 assistant 文本（成功）或 null（失败/撤回）。
  /// 调用方不必等待：controller 会在请求完成时更新消息并通过 ChangeNotifier 通知。
  Future<String?> send(
    AiConfig cfg,
    String userText, {
    String? contextSummary,
    String? screenText,
    void Function(String delta)? onDelta,
  }) {
    final content = userText.trim();
    if (content.isEmpty) return Future<String?>.value(null);
    final id = 'u${++_sequence}';
    final message = AiChatMessage._(
      id: id,
      role: AiChatMessageRole.user,
      content: content,
      status: AiChatMessageStatus.queued,
    );
    final waiter = Completer<String?>();
    _messages.add(message);
    _requestMeta[id] = _AiChatRequestMeta(
      config: cfg,
      contextSummary: contextSummary,
      screenText: screenText,
      onDelta: onDelta,
    );
    _waiters[id] = waiter;
    _queue.add(id);
    notifyListeners();
    unawaited(_pump());
    return waiter.future;
  }

  /// 把队列中的消息移到队首。当前在途请求不被抢占，完成后优先发它。
  bool prioritize(String messageId) {
    final index = _queue.indexOf(messageId);
    if (index < 0) return false;
    if (index == 0) return true;
    _queue.removeAt(index);
    _queue.insert(0, messageId);
    notifyListeners();
    return true;
  }

  /// 撤回 queued/failed 的 user 消息，返回原文并写入 [draft] 供 sheet 回填输入框。
  ///
  /// 同时从发送队列移除；失败请求留下的半截 assistant 回答也一并移除，避免出现
  /// 没有提问的孤立回答。成功消息不可撤回。
  String? withdraw(String messageId) {
    final message = _find(messageId);
    if (message == null || !message.isUser || !message.isWithdrawable) {
      return null;
    }
    _queue.remove(messageId);
    _messages.remove(message);
    final assistantId = _assistantByUser.remove(messageId);
    if (assistantId != null) {
      final assistant = _find(assistantId);
      if (assistant != null &&
          assistant.status == AiChatMessageStatus.incomplete) {
        _messages.remove(assistant);
      }
    }
    _requestMeta.remove(messageId);
    _completeWaiter(messageId, null);
    _draft = message.content;
    notifyListeners();
    return message.content;
  }

  /// 原地重试 failed 的 user 消息：不新增重复气泡，成功后 assistant 插在它后面。
  ///
  /// 请求在途时进入队列；[prioritize] 仍可继续调整它的位置。
  Future<String?> retry(String messageId) {
    final message = _find(messageId);
    if (message == null || !message.isRetryable) {
      return Future<String?>.value(null);
    }
    final meta = _requestMeta[messageId];
    if (meta == null) return Future<String?>.value(null);
    final waiter = Completer<String?>();
    _completeWaiter(messageId, null);
    _waiters[messageId] = waiter;
    message.status = AiChatMessageStatus.queued;
    message.error = null;
    if (!_queue.contains(messageId)) _queue.add(messageId);
    notifyListeners();
    unawaited(_pump());
    return waiter.future;
  }

  /// 停止当前在途请求。流式订阅会立即 cancel；迟到回调按 token/epoch 丢弃。
  void cancelActive() {
    _activeCancel?.cancel();
  }

  AiChatMessage? _find(String id) {
    for (final m in _messages) {
      if (m.id == id) return m;
    }
    return null;
  }

  bool _isActiveEpoch(String id, int epoch) =>
      _activeId == id && _activeEpoch == epoch;

  void _completeWaiter(String id, String? value) {
    final waiter = _waiters.remove(id);
    if (waiter != null && !waiter.isCompleted) waiter.complete(value);
  }

  void _countUnreadOnce(String key) {
    if (_sheetOpen) return;
    if (!_unreadCounted.add(key)) return;
    _unreadCount++;
  }

  List<Map<String, String>> _historyBefore(AiChatMessage message) {
    final index = _messages.indexOf(message);
    if (index < 0) return <Map<String, String>>[];
    return <Map<String, String>>[
      for (final m in _messages.take(index))
        if (m.status == AiChatMessageStatus.done) m.historyEntry,
    ];
  }

  Future<void> _pump() async {
    if (_activeId != null) return;
    // 每轮都重新检查 active：notifyListeners 的同步监听者若再次 send，可能已启动
    // 新的 _pump；这里必须让位，避免两个循环同时消费队列。
    while (_activeId == null && _queue.isNotEmpty) {
      final id = _queue.removeAt(0);
      final message = _find(id);
      if (message == null || message.status != AiChatMessageStatus.queued) {
        continue;
      }
      await _run(id);
    }
  }

  Future<void> _run(String id) async {
    final user = _find(id);
    final meta = _requestMeta[id];
    if (user == null || meta == null) {
      _completeWaiter(id, null);
      return;
    }
    _activeId = id;
    _activeEpoch++;
    final epoch = _activeEpoch;
    final cancelToken = AiCancelToken();
    _activeCancel = cancelToken;
    user.status = AiChatMessageStatus.sending;
    user.error = null;
    _lastError = null;

    // 重试前移除上一次尝试留下的未完成回答，成功结果仍插在 user 原位之后。
    final oldAssistantId = _assistantByUser.remove(id);
    if (oldAssistantId != null) {
      final oldAssistant = _find(oldAssistantId);
      if (oldAssistant != null &&
          oldAssistant.status == AiChatMessageStatus.incomplete) {
        _messages.remove(oldAssistant);
      }
    }

    final assistant = AiChatMessage._(
      id: 'a${++_sequence}',
      role: AiChatMessageRole.assistant,
      content: '',
      status: AiChatMessageStatus.streaming,
    );
    final userIndex = _messages.indexOf(user);
    _messages.insert(userIndex + 1, assistant);
    _assistantByUser[id] = assistant.id;
    notifyListeners();

    bool assistantStillPresent() => _messages.contains(assistant);

    void settleFailure(String message) {
      user.status = AiChatMessageStatus.failed;
      user.error = message;
      _lastError = message;
      if (assistant.content.trim().isEmpty) {
        _messages.remove(assistant);
        _assistantByUser.remove(id);
        _countUnreadOnce(user.id);
      } else {
        assistant.status = AiChatMessageStatus.incomplete;
        assistant.error = message;
        _countUnreadOnce(assistant.id);
      }
      _completeWaiter(id, null);
      notifyListeners();
    }

    try {
      // 知识库检索失败不得阻断对话：答疑是增强能力。
      var knowledge = const <AiKnowledgeSnippet>[];
      try {
        knowledge = await knowledgeBase.retrieve(user.content);
      } catch (_) {/* 忽略：按无知识库片段继续 */}
      if (!_isActiveEpoch(id, epoch)) {
        _completeWaiter(id, null);
        return;
      }
      if (cancelToken.isCancelled) {
        settleFailure('已取消本次回答');
        return;
      }
      final system = buildChatSystemPrompt(
        contextJson: meta.contextSummary,
        screenText: meta.screenText,
        knowledge: knowledge,
      );
      final messages = trimHistory(_historyBefore(user))
        ..add(<String, String>{'role': 'user', 'content': user.content});
      final outcome = await _clientFactory(meta.config).chat(
        system: system,
        messages: messages,
        cancelToken: cancelToken,
        onDelta: (delta) {
          // 关键：旧 epoch / 已取消请求的迟到 delta 绝不写入新消息。
          if (!_isActiveEpoch(id, epoch) || cancelToken.isCancelled) return;
          if (!assistantStillPresent()) return;
          assistant.content += delta;
          assistant.status = AiChatMessageStatus.streaming;
          notifyListeners();
          meta.onDelta?.call(delta);
        },
      );
      if (!_isActiveEpoch(id, epoch)) {
        _completeWaiter(id, null);
        return;
      }
      if (outcome is AiReply) {
        assistant.content = outcome.text;
        assistant.status = AiChatMessageStatus.done;
        assistant.error = null;
        user.status = AiChatMessageStatus.done;
        user.error = null;
        _lastError = null;
        _requestMeta.remove(id);
        _completeWaiter(id, outcome.text);
        _countUnreadOnce(assistant.id);
        notifyListeners();
        return;
      }
      final failure = outcome as AiFailure;
      settleFailure(failure.message);
    } on Exception catch (e) {
      if (_isActiveEpoch(id, epoch)) {
        // chat() 已把 Exception 翻译成 AiFailure，走到这里说明是意外（如注入的
        // 假 sender 抛异常）；兜底成可读文案，绝不让忙碌态软锁死。Error 不捕——
        // 编程缺陷应暴露（与 ai_client.dart 红线一致）。
        settleFailure('请求异常（$e）');
      } else {
        _completeWaiter(id, null);
      }
    } finally {
      if (_isActiveEpoch(id, epoch)) {
        _activeId = null;
        _activeCancel = null;
        notifyListeners();
      }
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
  controller.markSheetOpened();
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
  ).whenComplete(controller.markSheetClosed);
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

  /// 识屏状态提示（只显示“正在读取/已读取”等状态，不显示屏幕正文）。
  String? _screenNote;

  /// 屏幕识别进行中（按钮转圈 + 禁用），完成后把文字填进输入框待用户确认。
  bool _capturing = false;

  /// 正在走发送前的确认/识屏流程，防止重复触发；不阻塞在途请求。
  bool _preparingSend = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant AiChatSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 抽屉只监听 controller：关闭后请求继续，重新打开直接看到已产生消息/流式文本。
  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    _scrollToBottom();
  }

  bool get _configured => widget.config.enabled;
  bool get _busy => widget.controller.busy;

  /// 识别屏幕文字 → 填入输入框（用户可编辑/清空后再发送，绝不自动外发）。
  /// 屏幕内容可能含密码/个人信息，发送确认权始终在用户手里（文件头红线）。
  Future<void> _captureOcr() async {
    if (_capturing) return;
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
    if (!_configured || _capturing || _preparingSend) return;
    final raw = _input.text.trim();
    if (raw.isEmpty) return;
    _preparingSend = true;
    try {
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

      final freshContext =
          widget.contextProvider?.call() ?? widget.contextSummary;
      // 不 await：请求在途时也允许继续输入并排队；结果由 controller 通知。
      unawaited(ctrl.send(
        widget.config,
        raw,
        contextSummary: freshContext,
        screenText: screenText,
      ));
      if (_input.text.trim() == raw) _input.clear();
      if (!mounted) return;
      setState(() => _screenNote = screenNote.isEmpty ? null : screenNote);
      _scrollToBottom();
    } finally {
      _preparingSend = false;
    }
  }

  void _withdraw(AiChatMessage message) {
    final text = widget.controller.withdraw(message.id);
    if (text == null) return;
    setState(() {
      _input.text = text;
      _input.selection = TextSelection.collapsed(offset: text.length);
    });
  }

  void _retry(AiChatMessage message) {
    unawaited(widget.controller.retry(message.id));
  }

  String? _statusLabel(AiChatMessage message) {
    final error = message.error;
    switch (message.status) {
      case AiChatMessageStatus.queued:
        return '排队中';
      case AiChatMessageStatus.sending:
        return '发送中…';
      case AiChatMessageStatus.streaming:
        return message.content.isEmpty ? '正在生成…' : '生成中…';
      case AiChatMessageStatus.failed:
        return error == null ? '发送失败' : '发送失败：$error';
      case AiChatMessageStatus.incomplete:
        return error == null ? '未完成' : '未完成：$error';
      case AiChatMessageStatus.done:
        return null;
    }
  }

  Widget _actionButton(ThemeData theme, String label, VoidCallback onTap) =>
      TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      );

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final theme = Theme.of(context);
    // 唯一数据源是 controller.messages：不再把在途文本存在 State 里，
    // 因此关闭抽屉后请求继续，重新打开即可看到完整进度。
    final bubbles = ctrl.messages;
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
                      itemCount: bubbles.length + 1,
                      itemBuilder: (_, i) => i < bubbles.length
                          ? _bubble(theme, bubbles[i])
                          // 页脚硬拼接（需求 #6：全局助手可给建议，免责不可被模型删改）
                          : Padding(
                              padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                              child: Text(kAiChatFooter,
                                  style: TextStyle(
                                      fontSize: 10.5,
                                      color:
                                          theme.colorScheme.onSurfaceVariant)),
                            ),
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
                style:
                    TextStyle(fontSize: 11, color: theme.colorScheme.primary)),
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
            // 标题标签单行省略（移动端窄屏适配：不放任换行挤压按钮）。
            const Expanded(
              child: Text('AI 助手',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            if (widget.controller.queuedCount > 0)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text('${widget.controller.queuedCount} 条排队',
                    style: TextStyle(
                        fontSize: 11, color: theme.colorScheme.primary)),
              ),
            // 生成中 spinner 固定在标题栏，不再占用发送按钮。
            if (_busy) ...[
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              IconButton(
                tooltip: '停止生成',
                icon: const Icon(Icons.stop_circle_outlined, size: 20),
                onPressed: widget.controller.cancelActive,
              ),
            ],
            IconButton(
              tooltip: '清空对话',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => widget.controller.clear(),
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
              Text(
                  '在设置页「AI 解读」中配置提供方、接口地址与 API Key 后，'
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
              onPressed: (_configured && !_capturing)
                  ? () => setState(() => widget.controller.autoScreen =
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
              onPressed: (_configured && !_capturing) ? _captureOcr : null,
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
                // busy 不再禁用输入：发送会进入 FIFO 队列。
                enabled: _configured && !_capturing,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(), // 回车即发送
                decoration: InputDecoration(
                  hintText: !_configured
                      ? '未配置 AI，暂不可发送'
                      : _busy
                          ? '可继续输入，发送后排队'
                          : '提问（请勿输入个人信息）',
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
              child: FilledButton(
                onPressed: _configured && !_capturing ? _send : null,
                child: const Text('发送'),
              ),
            ),
          ],
        ),
      );

  /// 单条气泡：user 靠右 primary 底、assistant 靠左 surface 底；
  /// assistant 显示前过 sanitizeChatOutput（需求 #6：全局助手可给具体选项与
  /// 方向性建议，只拦"替用户拍板课表/断言选上/越权承诺选课"三条硬红线；
  /// 与选课页一次性解读的严格中立 sanitizeAiOutput 分口径）。
  Widget _bubble(ThemeData theme, AiChatMessage message) {
    final isUser = message.isUser;
    final text = isUser ? message.content : sanitizeChatOutput(message.content);
    final scheme = theme.colorScheme;
    final status = _statusLabel(message);
    final actions = <Widget>[
      if (message.isPrioritizable)
        _actionButton(
            theme, '置顶', () => widget.controller.prioritize(message.id)),
      if (message.isRetryable)
        _actionButton(theme, '重发', () => _retry(message)),
      if (message.isWithdrawable)
        _actionButton(theme, '撤回', () => _withdraw(message)),
    ];
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (isUser)
              SelectableText(
                text.isEmpty ? '…' : text,
                style: const TextStyle(fontSize: 14, height: 1.5),
              )
            else if (text.trim().isEmpty)
              const Text('…')
            else
              // 用户反馈 #14：AI 回复支持 Markdown 与公式（降级渲染）；
              // 用户气泡保持纯文本（用户输入不应当作 Markdown 解释）。
              AiMessageBody(text),
            if (status != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(status,
                    style: TextStyle(
                      fontSize: 11,
                      color: (message.isFailed ||
                              message.status == AiChatMessageStatus.incomplete)
                          ? scheme.error
                          : scheme.primary,
                    )),
              ),
            if (actions.isNotEmpty)
              Wrap(
                alignment: isUser ? WrapAlignment.end : WrapAlignment.start,
                spacing: 2,
                children: actions,
              ),
          ],
        ),
      ),
    );
  }
}
