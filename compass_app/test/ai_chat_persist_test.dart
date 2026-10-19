// test/ai_chat_persist_test.dart — AI 对话历史持久化（用户反馈 #14）。
//
// 锁定：export→import 往返一致（角色/内容/状态/错误保留）；脏 JSON 逐条跳过
// 且不抛；恢复后零网络（clientFactory 一次都不调用）、busy=false。
import 'dart:async';
import 'dart:convert';

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

Stream<AiStreamEvent> _statusStream(int status) async* {
  yield AiStreamMeta(status);
  yield AiStreamLine('{}');
}

void main() {
  test('成功对话往返：user+assistant 内容/状态保留，再导出等价', () async {
    final ctrl = AiChatController(
      clientFactory: (c) => AiClient(c, streamSender: (_) => _replyStream('回答')),
    );
    await ctrl.send(_cfg, '问题一');
    final exported = ctrl.exportHistory();

    final restored = AiChatController(
      clientFactory: (_) => throw StateError('恢复后不得触网'),
    );
    restored.importHistory(exported);
    expect(restored.messages, hasLength(2));
    expect(restored.messages.first.role, AiChatMessageRole.user);
    expect(restored.messages.first.content, '问题一');
    expect(restored.messages.first.status, AiChatMessageStatus.done);
    expect(restored.messages.last.role, AiChatMessageRole.assistant);
    expect(restored.messages.last.content, '回答');
    expect(restored.messages.last.status, AiChatMessageStatus.done);
    expect(restored.busy, isFalse);
    // 往返等价（状态/内容/顺序一致）
    expect(restored.exportHistory(), exported);
  });

  test('失败消息往返：failed 状态与 error 文案保留', () async {
    final ctrl = AiChatController(
      clientFactory: (c) => AiClient(c, streamSender: (_) => _statusStream(401)),
    );
    await ctrl.send(_cfg, '坏问题');
    final restored = AiChatController(
      clientFactory: (_) => throw StateError('恢复后不得触网'),
    );
    restored.importHistory(ctrl.exportHistory());
    expect(restored.messages, hasLength(1));
    expect(restored.messages.single.status, AiChatMessageStatus.failed);
    expect(restored.messages.single.error, isNotNull);
    expect(restored.messages.single.error, contains('认证失败'));
    expect(restored.busy, isFalse);
  });

  test('脏数据逐条跳过、绝不抛', () {
    final ctrl = AiChatController(
      clientFactory: (_) => throw StateError('根本不该构造客户端'),
    );
    for (final dirty in <String?>[
      null,
      '',
      '   ',
      '{坏JSON',
      '[]',
      '{}',
      '[1,2,3]',
      '[{"role":"user"}]', // 缺 content
      '[{"content":"x"}]', // 缺 role
      '[{"role":"tool","content":"x"}]', // 未知角色
      '[{"role":"user","content":"  "}]', // 空白内容
    ]) {
      expect(() => ctrl.importHistory(dirty), returnsNormally, reason: '$dirty');
    }
    expect(ctrl.messages, isEmpty);
    expect(ctrl.busy, isFalse);
  });

  test('导入不触发网络：clientFactory 计数为 0', () async {
    var built = 0;
    final ctrl = AiChatController(
      clientFactory: (_) {
        built++;
        return AiClient(_cfg);
      },
    );
    ctrl.importHistory(jsonEncode([
      {'role': 'user', 'content': '历史问题', 'status': 'done'},
      {'role': 'assistant', 'content': '历史回答', 'status': 'done'},
    ]));
    await Future<void>.delayed(Duration.zero);
    expect(built, 0);
    expect(ctrl.busy, isFalse);
  });
}
