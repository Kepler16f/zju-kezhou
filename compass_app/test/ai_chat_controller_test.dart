// test/ai_chat_controller_test.dart — 纯 Dart 的 controller 状态机测试。
//
// 与 ai_chat_test.dart 互补：这里不依赖 flutter_test / widget binding，可在
// 受限沙箱的单进程 shim 中直接执行，覆盖未读、队列、撤回、重发与取消隔离。
import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';

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

Stream<AiStreamEvent> _statusStream(int status) async* {
  yield AiStreamMeta(status);
  yield const AiStreamLine('{}');
}

void main() {
  test('未读：关闭时回复/失败 +1，打开清零，关闭消耗一条', () async {
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
    expect(ctrl.unreadCount, 0);

    ctrl.markSheetClosed();
    failNext = true;
    await ctrl.send(_cfg, 'q4');
    expect(ctrl.unreadCount, 1);
    ctrl.markSheetClosed();
    expect(ctrl.unreadCount, 0);
  });

  test('队列：在途不抢占，prioritize 调整 FIFO 下一条', () async {
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
    expect(started, <String>['A']);
    expect(ctrl.queuedCount, 2);

    final cBubble = ctrl.messages.firstWhere((m) => m.content == 'C');
    expect(ctrl.prioritize(cBubble.id), isTrue);
    pending['A']!
      ..add(const AiStreamMeta(200))
      ..add(
          const AiStreamLine('data: {"choices":[{"delta":{"content":"a"}}]}'));
    await pending['A']!.close();
    expect(await a, 'a');
    await Future<void>.delayed(Duration.zero);
    expect(started, <String>['A', 'C']);

    pending['C']!
      ..add(const AiStreamMeta(200))
      ..add(
          const AiStreamLine('data: {"choices":[{"delta":{"content":"c"}}]}'));
    await pending['C']!.close();
    expect(await cMessage, 'c');
    await Future<void>.delayed(Duration.zero);
    expect(started, <String>['A', 'C', 'B']);

    pending['B']!
      ..add(const AiStreamMeta(200))
      ..add(
          const AiStreamLine('data: {"choices":[{"delta":{"content":"b"}}]}'));
    await pending['B']!.close();
    expect(await b, 'b');
  });

  test('撤回：queued 出队并回填 draft', () async {
    final gate = StreamController<AiStreamEvent>();
    final ctrl = AiChatController(
      clientFactory: (c) => AiClient(c, streamSender: (_) => gate.stream),
    );
    final first = ctrl.send(_cfg, 'A');
    await Future<void>.delayed(Duration.zero);
    final second = ctrl.send(_cfg, 'B');
    final b = ctrl.messages.firstWhere((m) => m.content == 'B');
    expect(b.status, AiChatMessageStatus.queued);
    expect(ctrl.withdraw(b.id), 'B');
    expect(ctrl.draft, 'B');
    expect(ctrl.queuedCount, 0);
    expect(await second, isNull);
    ctrl.cancelActive();
    await first;
    unawaited(gate.close());
  });

  test('重发：复用 user 气泡，成功回答紧随其后', () async {
    var calls = 0;
    final ctrl = AiChatController(
      clientFactory: (c) => AiClient(c, streamSender: (_) {
        calls++;
        return calls == 1 ? _statusStream(401) : _replyStream('重试成功');
      }),
    );
    await ctrl.send(_cfg, '原问题');
    final user = ctrl.messages.single;
    final retried = await ctrl.retry(user.id);
    expect(retried, '重试成功');
    expect(ctrl.messages.where((m) => m.isUser), hasLength(1));
    expect(ctrl.messages.first.id, user.id);
    expect(ctrl.messages[1].content, '重试成功');
    expect(ctrl.history, hasLength(2));
  });

  test('失败保留半截回答，状态为 incomplete', () async {
    final ctrl = AiChatController(
      clientFactory: (c) => AiClient(c, streamSender: (_) async* {
        yield const AiStreamMeta(200);
        yield const AiStreamLine(
            'data: {"choices":[{"delta":{"content":"半截"}}]}');
        yield const AiStreamError('连接断开');
      }),
    );
    expect(await ctrl.send(_cfg, 'q'), isNull);
    expect(ctrl.messages, hasLength(2));
    expect(ctrl.messages.first.status, AiChatMessageStatus.failed);
    expect(ctrl.messages.last.content, '半截');
    expect(ctrl.messages.last.status, AiChatMessageStatus.incomplete);
    expect(ctrl.history, isEmpty);
  });

  test('取消后旧请求迟到事件不污染新回答', () async {
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
    gates[0].add(
        const AiStreamLine('data: {"choices":[{"delta":{"content":"旧片段"}}]}'));
    await Future<void>.delayed(Duration.zero);
    ctrl.cancelActive();
    await oldFuture;

    final newFuture = ctrl.send(_cfg, '新问题');
    await Future<void>.delayed(Duration.zero);
    gates[0].add(
        const AiStreamLine('data: {"choices":[{"delta":{"content":"污染"}}]}'));
    gates[1]
      ..add(const AiStreamMeta(200))
      ..add(const AiStreamLine(
          'data: {"choices":[{"delta":{"content":"新回答"}}]}'));
    await gates[1].close();
    expect(await newFuture, '新回答');
    expect(ctrl.messages.any((m) => m.content.contains('污染')), isFalse);
    unawaited(gates[0].close());
  });

  test('AiCancelToken：流式取消返回 cancelled 且丢弃迟到 delta', () async {
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
    expect(deltas, isEmpty);
    unawaited(gate.close());
  });
}
