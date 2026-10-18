// test/ai_chat_test.dart — 全局 AI 对话组件单测：控制器状态机 / 历史裁剪 /
// 消息拼接 / 抽屉冒烟。全程零网络：假 streamSender 直接回放 SSE 行，不触网。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/ai_client.dart';
import 'package:compass_app/data/ai_config.dart';
import 'package:compass_app/widgets/ai_chat.dart';

const AiConfig _cfg = AiConfig(
  provider: AiProvider.openai,
  baseUrl: 'https://api.example.com/v1',
  apiKey: 'k-123456',
  model: 'm-1',
);

Stream<AiStreamEvent> _replyStream(String text) async* {
  yield const AiStreamMeta(200);
  yield AiStreamLine('data: ${jsonEncode(<String, Object?>{
        'choices': [
          {
            'delta': {'content': text}
          }
        ]
      })}');
}

Stream<AiStreamEvent> _statusStream(int status, [String body = '{}']) async* {
  yield AiStreamMeta(status);
  yield AiStreamLine(body);
}

void main() {
  group('AiChatController.send（未配置零网络红线）', () {
    test('未配置：返回 null、lastError 非空、失败 user 保留但 history 为空', () async {
      final ctrl = AiChatController();
      const unconfigured = AiConfig(); // provider==none，enabled==false
      final reply = await ctrl.send(unconfigured, 'hi');
      expect(reply, isNull);
      expect(ctrl.lastError, isNotNull);
      expect(ctrl.lastError, isNotEmpty);
      expect(ctrl.history, isEmpty);
      // 需求：失败不丢消息，user 气泡保留并标记 failed。
      expect(ctrl.messages, hasLength(1));
      expect(ctrl.messages.single.isUser, isTrue);
      expect(ctrl.messages.single.status, AiChatMessageStatus.failed);
      expect(ctrl.messages.single.error, ctrl.lastError);
      expect(ctrl.busy, isFalse); // 失败也必须复位忙碌态，防 UI 软锁死
    });

    test('空文本直接返回 null，不产生消息', () async {
      final ctrl = AiChatController();
      expect(await ctrl.send(const AiConfig(), '   '), isNull);
      expect(ctrl.messages, isEmpty);
      expect(ctrl.history, isEmpty);
      expect(ctrl.lastError, isNull);
    });

    test('clear 清空消息与错误；busy 时拒绝清空', () async {
      final gate = StreamController<AiStreamEvent>();
      final ctrl = AiChatController(
        clientFactory: (c) => AiClient(c, streamSender: (_) => gate.stream),
      );
      final pending = ctrl.send(_cfg, '在途问题');
      await Future<void>.delayed(Duration.zero);
      expect(ctrl.busy, isTrue);
      ctrl.clear();
      expect(ctrl.messages, isNotEmpty); // 在途请求未完成前不许清
      ctrl.cancelActive();
      await pending;
      expect(ctrl.busy, isFalse);
      ctrl.clear();
      expect(ctrl.messages, isEmpty);
      expect(ctrl.history, isEmpty);
      expect(ctrl.lastError, isNull);
      unawaited(gate.close());
    });
  });

  group('AiChatController：上下文与流式', () {
    test('contextSummary 只进 system，不写入用户气泡/历史', () async {
      String? capturedSystem;
      final ctrl = AiChatController(
        clientFactory: (c) => AiClient(c, streamSender: (req) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final messages = body['messages'] as List;
          capturedSystem = (messages.first as Map)['content'] as String;
          return _replyStream('回答');
        }),
      );
      final reply =
          await ctrl.send(_cfg, '我的问题', contextSummary: '{"学业":{"绩点":4.2}}');
      expect(reply, '回答');
      expect(capturedSystem, contains('"绩点":4.2'));
      expect(capturedSystem, isNot(contains('我的问题')));
      expect(ctrl.history.first['content'], '我的问题');
      expect(ctrl.history.first['content'], isNot(contains('绩点')));
      expect(ctrl.history.last['content'], '回答');
    });

    test('流式：onDelta 逐段回调，历史写入完整回答', () async {
      final deltas = <String>[];
      final ctrl = AiChatController(
        clientFactory: (c) => AiClient(c, streamSender: (req) async* {
          yield const AiStreamMeta(200);
          yield const AiStreamLine(
              'data: {"choices":[{"delta":{"content":"你"}}]}');
          yield const AiStreamLine(
              'data: {"choices":[{"delta":{"content":"好"}}]}');
        }),
      );
      final reply = await ctrl.send(_cfg, '打个招呼', onDelta: deltas.add);
      expect(reply, '你好');
      expect(deltas.join(), '你好');
      expect(ctrl.history.last['content'], '你好');
      expect(ctrl.messages.last.status, AiChatMessageStatus.done);
    });

    test('screenText 只进 system，不写入用户气泡/历史', () async {
      String? capturedSystem;
      final ctrl = AiChatController(
        clientFactory: (c) => AiClient(c, streamSender: (req) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final messages = body['messages'] as List;
          capturedSystem = (messages.first as Map)['content'] as String;
          return _replyStream('看到了');
        }),
      );
      final reply = await ctrl.send(_cfg, '屏幕上这个课是什么', screenText: '课程名：高等数学');
      expect(reply, '看到了');
      expect(capturedSystem, contains('课程名：高等数学'));
      expect(ctrl.history.first['content'], '屏幕上这个课是什么');
      expect(ctrl.history.first['content'], isNot(contains('高等数学')));
    });

    test('失败保留半截回答并标记 incomplete', () async {
      final ctrl = AiChatController(
        clientFactory: (c) => AiClient(c, streamSender: (req) async* {
          yield const AiStreamMeta(200);
          yield const AiStreamLine(
              'data: {"choices":[{"delta":{"content":"半截"}}]}');
          yield const AiStreamError('连接断开');
        }),
      );
      final reply = await ctrl.send(_cfg, '会失败的问题');
      expect(reply, isNull);
      expect(ctrl.messages, hasLength(2));
      final user = ctrl.messages.first;
      final assistant = ctrl.messages.last;
      expect(user.status, AiChatMessageStatus.failed);
      expect(user.error, contains('连接断开'));
      expect(assistant.content, '半截');
      expect(assistant.status, AiChatMessageStatus.incomplete);
      expect(assistant.error, contains('连接断开'));
      expect(ctrl.history, isEmpty);
    });

    test('status=401 失败不重试且错误文案在 user 消息上', () async {
      var calls = 0;
      final ctrl = AiChatController(
        clientFactory: (c) => AiClient(c, streamSender: (req) {
          calls++;
          return _statusStream(401, '{"error":{"message":"bad key"}}');
        }),
      );
      final reply = await ctrl.send(_cfg, 'q');
      expect(reply, isNull);
      expect(calls, 1);
      expect(ctrl.messages.single.status, AiChatMessageStatus.failed);
      expect(ctrl.messages.single.error, contains('认证失败'));
    });
  });

  group('AiChatController：撤回/重发/队列', () {
    test('撤回 queued 消息会出队并回填 draft', () async {
      final gate = StreamController<AiStreamEvent>();
      final ctrl = AiChatController(
        clientFactory: (c) => AiClient(c, streamSender: (_) => gate.stream),
      );
      final first = ctrl.send(_cfg, 'A');
      await Future<void>.delayed(Duration.zero);
      final second = ctrl.send(_cfg, 'B');
      await Future<void>.delayed(Duration.zero);
      expect(ctrl.queuedCount, 1);
      final b = ctrl.messages.firstWhere((m) => m.content == 'B');
      expect(b.status, AiChatMessageStatus.queued);
      expect(ctrl.withdraw(b.id), 'B');
      expect(ctrl.draft, 'B');
      expect(ctrl.queuedCount, 0);
      expect(ctrl.messages.any((m) => m.content == 'B'), isFalse);
      expect(await second, isNull);
      ctrl.cancelActive();
      await first;
      unawaited(gate.close());
    });

    test('撤回 failed 消息成功并清除它', () async {
      final ctrl = AiChatController(
        clientFactory: (c) =>
            AiClient(c, streamSender: (_) => _statusStream(401)),
      );
      await ctrl.send(_cfg, '坏问题');
      final failed = ctrl.messages.single;
      expect(failed.isRetryable, isTrue);
      expect(ctrl.withdraw(failed.id), '坏问题');
      expect(ctrl.draft, '坏问题');
      expect(ctrl.messages, isEmpty);
      expect(ctrl.withdraw(failed.id), isNull); // 已移除，幂等返回 null
    });

    test('重试原地复用 user 气泡，回答插在该消息之后', () async {
      var calls = 0;
      final ctrl = AiChatController(
        clientFactory: (c) => AiClient(c, streamSender: (_) {
          calls++;
          return calls == 1 ? _statusStream(401) : _replyStream('重试成功');
        }),
      );
      await ctrl.send(_cfg, '原问题');
      final user = ctrl.messages.single;
      expect(user.status, AiChatMessageStatus.failed);

      final retried = await ctrl.retry(user.id);
      expect(retried, '重试成功');
      expect(calls, 2);
      expect(ctrl.messages.where((m) => m.isUser), hasLength(1));
      expect(ctrl.messages.where((m) => m.isAssistant), hasLength(1));
      expect(ctrl.messages.first.id, user.id);
      expect(ctrl.messages.first.status, AiChatMessageStatus.done);
      expect(ctrl.messages[1].content, '重试成功');
      expect(ctrl.history, hasLength(2));
    });

    test('busy 时 FIFO 排队，prioritize 只调整下一条不抢占在途', () async {
      final pending = <String, StreamController<AiStreamEvent>>{};
      final started = <String>[];
      final ctrl = AiChatController(
        clientFactory: (c) => AiClient(c, streamSender: (req) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final messages = body['messages'] as List;
          final question = (messages.last as Map)['content'] as String;
          started.add(question);
          final gate = StreamController<AiStreamEvent>();
          pending[question] = gate;
          return gate.stream;
        }),
      );

      final a = ctrl.send(_cfg, 'A');
      await Future<void>.delayed(Duration.zero);
      final b = ctrl.send(_cfg, 'B');
      final cMessage = ctrl.send(_cfg, 'C');
      await Future<void>.delayed(Duration.zero);
      expect(started, <String>['A']); // 在途请求未被抢占
      expect(ctrl.queuedCount, 2);

      final cBubble = ctrl.messages.firstWhere((m) => m.content == 'C');
      expect(ctrl.prioritize(cBubble.id), isTrue);
      expect(ctrl.queuedCount, 2);

      pending['A']!
        ..add(const AiStreamMeta(200))
        ..add(const AiStreamLine(
            'data: {"choices":[{"delta":{"content":"a"}}]}'));
      await pending['A']!.close();
      expect(await a, 'a');
      await Future<void>.delayed(Duration.zero);
      expect(started, <String>['A', 'C']); // C 置顶后先于 B
      expect(ctrl.queuedCount, 1);

      pending['C']!
        ..add(const AiStreamMeta(200))
        ..add(const AiStreamLine(
            'data: {"choices":[{"delta":{"content":"c"}}]}'));
      await pending['C']!.close();
      expect(await cMessage, 'c');
      await Future<void>.delayed(Duration.zero);
      expect(started, <String>['A', 'C', 'B']);

      pending['B']!
        ..add(const AiStreamMeta(200))
        ..add(const AiStreamLine(
            'data: {"choices":[{"delta":{"content":"b"}}]}'));
      await pending['B']!.close();
      expect(await b, 'b');
    });
  });

  group('AiChatController：未读计数', () {
    test('关闭时每条回复/失败最多 +1，打开清零，关闭消耗一条', () async {
      var failNext = false;
      final ctrl = AiChatController(
        clientFactory: (c) => AiClient(c, streamSender: (_) {
          return failNext ? _statusStream(401) : _replyStream('ok');
        }),
      );
      await ctrl.send(_cfg, 'q1');
      expect(ctrl.unreadCount, 1);
      await ctrl.send(_cfg, 'q2');
      expect(ctrl.unreadCount, 2);

      ctrl.markSheetOpened();
      expect(ctrl.unreadCount, 0);
      await ctrl.send(_cfg, 'q3');
      expect(ctrl.unreadCount, 0); // 打开期间不累计

      ctrl.markSheetClosed();
      expect(ctrl.unreadCount, 0);

      failNext = true;
      await ctrl.send(_cfg, 'q4'); // 关闭时失败也 +1
      expect(ctrl.unreadCount, 1);
      ctrl.markSheetClosed();
      expect(ctrl.unreadCount, 0);
    });
  });

  group('AiCancelToken / AiClient', () {
    test('取消流式后返回 cancelled，迟到 delta 被丢弃', () async {
      final gate = StreamController<AiStreamEvent>();
      final deltas = <String>[];
      final token = AiCancelToken();
      final client = AiClient(_cfg, streamSender: (_) => gate.stream);
      final future = client.chat(
        system: 's',
        messages: const [
          {'role': 'user', 'content': 'q'}
        ],
        onDelta: deltas.add,
        cancelToken: token,
      );
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      final outcome = await future;
      expect((outcome as AiFailure).kind, AiFailKind.cancelled);

      gate.add(
          const AiStreamLine('data: {"choices":[{"delta":{"content":"迟到"}}]}'));
      await Future<void>.delayed(Duration.zero);
      expect(deltas, isEmpty); // subscription.cancel 后不再回调
      unawaited(gate.close());
    });

    test('旧请求取消后启动新请求，旧流迟到事件不污染新消息', () async {
      final gates = <StreamController<AiStreamEvent>>[];
      final ctrl = AiChatController(
        clientFactory: (c) => AiClient(c, streamSender: (_) {
          final gate = StreamController<AiStreamEvent>();
          gates.add(gate);
          return gate.stream;
        }),
      );
      final oldFuture = ctrl.send(_cfg, '旧问题');
      await Future<void>.delayed(Duration.zero);
      gates[0].add(const AiStreamLine(
          'data: {"choices":[{"delta":{"content":"旧片段"}}]}'));
      await Future<void>.delayed(Duration.zero);
      ctrl.cancelActive();
      await oldFuture;
      final oldAssistant =
          ctrl.messages.firstWhere((m) => m.isAssistant && m.content == '旧片段');
      expect(oldAssistant.status, AiChatMessageStatus.incomplete);

      final newFuture = ctrl.send(_cfg, '新问题');
      await Future<void>.delayed(Duration.zero);
      gates[0].add(
          const AiStreamLine('data: {"choices":[{"delta":{"content":"污染"}}]}'));
      gates[1].add(const AiStreamMeta(200));
      gates[1].add(const AiStreamLine(
          'data: {"choices":[{"delta":{"content":"新回答"}}]}'));
      await gates[1].close();
      expect(await newFuture, '新回答');
      expect(ctrl.messages.any((m) => m.content.contains('污染')), isFalse);
      expect(ctrl.messages.last.content, '新回答');
      unawaited(gates[0].close());
    });
  });

  group('looksLikeScreenQuestion', () {
    test('屏幕/页面/截图等指代命中', () {
      expect(looksLikeScreenQuestion('屏幕上这个课是什么'), isTrue);
      expect(looksLikeScreenQuestion('当前页面里的学分怎么算'), isTrue);
      expect(looksLikeScreenQuestion('帮我看一下这张图'), isTrue);
      expect(looksLikeScreenQuestion('列表里第三门课'), isTrue);
    });

    test('普通问题不误判；裸「这个」不收', () {
      expect(looksLikeScreenQuestion('帮我解释培养方案'), isFalse);
      expect(looksLikeScreenQuestion('这门课怎么样'), isFalse);
      expect(looksLikeScreenQuestion('这个课是什么'), isFalse);
      expect(looksLikeScreenQuestion('   '), isFalse);
    });
  });

  group('trimHistory', () {
    test('20 条：≤12、以 user 开头、保留的是最近段', () {
      // 构造 20 条 user/assistant 交替（索引偶数=user）。20 截尾 12 条 = 索引 8..19，
      // 索引 8 是偶数（user），首条无需丢弃——保留的是「最近段」而非开头段。
      final h = <Map<String, String>>[
        for (var i = 0; i < 20; i++)
          {'role': i.isEven ? 'user' : 'assistant', 'content': 'm$i'},
      ];
      final kept = trimHistory(h);
      expect(kept.length, lessThanOrEqualTo(12));
      expect(kept.first['role'], 'user');
      expect(kept.length, 12);
      expect(kept.first['content'], 'm8');
      expect(kept.last['content'], 'm19');
    });

    test('截断尾段以 assistant 开头时丢弃它', () {
      // 13 条：索引 0..12，截尾 12 条从索引 1 开始（奇数=assistant）→ 再丢 1 条，
      // 剩 11 条且首条为索引 2（user）。
      final h = <Map<String, String>>[
        for (var i = 0; i < 13; i++)
          {'role': i.isEven ? 'user' : 'assistant', 'content': 'm$i'},
      ];
      final kept = trimHistory(h);
      expect(kept.length, 11);
      expect(kept.first['role'], 'user');
      expect(kept.first['content'], 'm2');
    });

    test('不超上限且以 user 开头时原样保留', () {
      final h = [
        {'role': 'user', 'content': 'a'},
        {'role': 'assistant', 'content': 'b'},
      ];
      expect(trimHistory(h), h);
    });

    test('空表返回空表', () => expect(trimHistory([]), isEmpty));
  });

  group('composeUserMessage', () {
    test('上下文为空 → 原文', () {
      expect(composeUserMessage(null, '怎么查学分'), '怎么查学分');
      expect(composeUserMessage('', 'q'), 'q');
      expect(composeUserMessage('   ', 'q'), 'q'); // 纯空白也算空上下文
    });

    test('有上下文 → [上下文]/[问题] 两段', () {
      final msg = composeUserMessage('缺口 6 分', '还差多少');
      expect(msg, '[上下文]\n缺口 6 分\n[问题]\n还差多少');
      expect(msg.contains('[上下文]'), isTrue);
      expect(msg.contains('[问题]'), isTrue);
    });
  });

  group('AiChatSheet 冒烟（未配置）', () {
    testWidgets('未配置：出现去设置按钮与输入框，不渲染气泡列表', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 420,
              height: 600,
              child: AiChatSheet(
                controller: AiChatController(),
                config: const AiConfig(),
                onGoSettings: () {},
              ),
            ),
          ),
        ),
      ));
      expect(find.text('AI 助手'), findsOneWidget);
      expect(find.textContaining('去设置'), findsOneWidget);
      expect(find.byKey(const Key('aiChatInput')), findsOneWidget);
      // 未配置空态：无任何请求痕迹（无 busy 圈）。
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('已配置空会话：显示引导文案与发送按钮', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 420,
              height: 600,
              child: AiChatSheet(
                controller: AiChatController(),
                config: _cfg,
                contextSummary: '模块A 缺口 3 分',
              ),
            ),
          ),
        ),
      ));
      // 需求：补充上下文不展示给用户（只进 system 消息）。
      expect(find.textContaining('本次对话附带数据摘要'), findsNothing);
      expect(find.textContaining('模块A 缺口 3 分'), findsNothing);
      expect(find.text('发送'), findsOneWidget);
    });

    testWidgets('失败消息渲染重发/撤回操作', (tester) async {
      final ctrl = AiChatController(
        clientFactory: (c) =>
            AiClient(c, streamSender: (_) => _statusStream(401)),
      );
      await ctrl.send(_cfg, '失败问题');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 420,
              height: 600,
              child: AiChatSheet(controller: ctrl, config: _cfg),
            ),
          ),
        ),
      ));
      expect(find.text('失败问题'), findsOneWidget);
      expect(find.text('重发'), findsOneWidget);
      expect(find.text('撤回'), findsOneWidget);
      expect(find.textContaining('认证失败'), findsWidgets);
    });
  });
}
