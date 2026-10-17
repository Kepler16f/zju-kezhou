// test/ai_chat_test.dart — 全局 AI 对话组件单测：控制器状态机 / 历史裁剪 /
// 消息拼接 / 抽屉冒烟。全程零网络：未配置路径在 AiClient.chat 的 enabled 检查处
// 即返回 AiFailure(notConfigured)，不触网；配置路径不在此文件覆盖（假 sender
// 属 ai_client_test 的注入机制，本组件未暴露注入缝，冒烟只验 UI 与状态机）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/ai_client.dart';
import 'package:compass_app/data/ai_config.dart';
import 'package:compass_app/widgets/ai_chat.dart';

void main() {
  group('AiChatController.send（未配置零网络红线）', () {
    test('未配置：返回 null、lastError 非空、history 不写入', () async {
      final ctrl = AiChatController();
      const unconfigured = AiConfig(); // provider==none，enabled==false
      final reply = await ctrl.send(unconfigured, 'hi');
      expect(reply, isNull);
      expect(ctrl.lastError, isNotNull);
      expect(ctrl.lastError, isNotEmpty);
      expect(ctrl.history, isEmpty);
      expect(ctrl.busy, isFalse); // 失败也必须复位忙碌态，防 UI 软锁死
    });

    test('空文本与忙碌中直接返回 null，不碰历史也不设错误', () async {
      final ctrl = AiChatController();
      expect(await ctrl.send(const AiConfig(), '   '), isNull);
      expect(ctrl.history, isEmpty);
      expect(ctrl.lastError, isNull);
      ctrl.busy = true;
      expect(await ctrl.send(const AiConfig(), '有效问题'), isNull);
      expect(ctrl.lastError, isNull); // 忙时短路不应清/写错误位
    });

    test('clear 清空历史与错误；busy 时拒绝清空', () {
      final ctrl = AiChatController()
        ..history.add({'role': 'user', 'content': 'q'})
        ..lastError = 'e';
      ctrl.busy = true;
      ctrl.clear();
      expect(ctrl.history, hasLength(1)); // 在途请求未完成前不许清
      ctrl.busy = false;
      ctrl.clear();
      expect(ctrl.history, isEmpty);
      expect(ctrl.lastError, isNull);
    });
  });

  group('AiChatController：上下文与流式', () {
    const cfg = AiConfig(
      provider: AiProvider.openai,
      baseUrl: 'https://api.example.com/v1',
      apiKey: 'k-123456',
      model: 'm-1',
    );

    test('contextSummary 只进 system，不写入用户气泡/历史', () async {
      String? capturedSystem;
      final ctrl = AiChatController(
        clientFactory: (c) => AiClient(c, sender: (req) async {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final messages = body['messages'] as List;
          capturedSystem = (messages.first as Map)['content'] as String;
          return const AiHttpReply(
              200, '{"choices":[{"message":{"content":"回答"}}]}');
        }),
      );
      final reply = await ctrl.send(cfg, '我的问题',
          contextSummary: '{"学业":{"绩点":4.2}}');
      expect(reply, '回答');
      expect(capturedSystem, contains('"绩点":4.2'));
      expect(capturedSystem, isNot(contains('我的问题')));
      expect(ctrl.history.first['content'], '我的问题');
      expect(ctrl.history.first['content'], isNot(contains('绩点')));
    });

    test('流式：onDelta 逐段回调，历史写入完整回答', () async {
      final deltas = <String>[];
      final ctrl = AiChatController(
        clientFactory: (c) => AiClient(c,
            streamSender: (req) async* {
              yield const AiStreamMeta(200);
              yield const AiStreamLine(
                  'data: {"choices":[{"delta":{"content":"你"}}]}');
              yield const AiStreamLine(
                  'data: {"choices":[{"delta":{"content":"好"}}]}');
            }),
      );
      final reply = await ctrl.send(cfg, '打个招呼', onDelta: deltas.add);
      expect(reply, '你好');
      expect(deltas.join(), '你好');
      expect(ctrl.history.last['content'], '你好');
    });

    test('screenText 只进 system，不写入用户气泡/历史', () async {
      String? capturedSystem;
      final ctrl = AiChatController(
        clientFactory: (c) => AiClient(c, sender: (req) async {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final messages = body['messages'] as List;
          capturedSystem = (messages.first as Map)['content'] as String;
          return const AiHttpReply(
              200, '{"choices":[{"message":{"content":"看到了"}}]}');
        }),
      );
      final reply = await ctrl.send(cfg, '屏幕上这个课是什么',
          screenText: '课程名：高等数学');
      expect(reply, '看到了');
      expect(capturedSystem, contains('课程名：高等数学'));
      expect(ctrl.history.first['content'], '屏幕上这个课是什么');
      expect(ctrl.history.first['content'], isNot(contains('高等数学')));
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
                config: const AiConfig(
                    provider: AiProvider.openai,
                    baseUrl: 'https://api.example.com',
                    apiKey: 'k',
                    model: 'm'),
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
  });
}
