// test/ai_compliance_test.dart — AI 发送/输出边界的回归护栏（对抗评审发现的问题固化）。
// 护栏：审计告警原文不得携带成绩数字；越界拦截不得被空格拆分绕过；输出侧有第二道防线；
// 回显型网关的裸密钥必须被结构性洗掉；漏写 scheme 直接判未配置（防软锁死）。
import 'package:test/test.dart';

import 'package:compass_app/data/ai_client.dart';
import 'package:compass_app/data/ai_config.dart';
import 'package:compass_app/data/ai_prompts.dart';
import 'package:compass_app/engine/selection.dart';

Map<String, dynamic> failedReport() => {
      'totals': {'required': 100.0, 'earned': 60.0, 'gap': 40.0},
      'summary': [
        {
          'module_path': '专业教育/专业核心',
          'required': 40.0,
          'earned': 30.0,
          'gap': 10.0,
          'status': 'yellow',
          'missing_courses': [
            {'name': '编译原理', 'credits': 3.0, 'offered': ['秋']}
          ],
        }
      ],
      'warnings': [
        {'type': 'failed_recheck', 'text': '《计算机组成原理》成绩 55 未通过，需重修或补考'},
        {'type': 'unmatched_courses', 'text': '以下 1 门课程未在培养方案中匹配到：创业实践'},
        {'type': 'prereq_gap', 'text': '《编译原理》需先修《数据结构与算法》'},
      ],
    };

void main() {
  test('auditSubsetOf 过滤 failed_recheck/unmatched：成绩数字绝不出境（critical 回归）', () {
    final subset = auditSubsetOf(failedReport())!;
    final text = '$subset';
    expect(text.contains('55'), isFalse, reason: '不及格分数不得出现在发送子集');
    expect(text.contains('未通过'), isFalse);
    expect(text.contains('创业实践'), isFalse);
    expect(text.contains('编译原理'), isTrue); // 白名单类型的课程名允许发送

    final payload = buildUserPayload(
        advice: buildSelectionAdvice(const SelectionRequest(candidates: [])),
        auditReport: failedReport(),
        question: '请解释这份建议卡');
    expect(payload.contains('55'), isFalse);
    expect(payload.contains('failed'), isFalse);
    expect(payload.contains('成绩'), isFalse, reason: '整条载荷不得出现成绩字样');
  });

  test('findBoundaryTriggers：空格拆分/变体不得绕过；正常问题不误拦', () {
    expect(findBoundaryTriggers('帮 我 选'), isNotEmpty);
    expect(findBoundaryTriggers('排一下课表'), isNotEmpty);
    expect(findBoundaryTriggers('给我个选课建议'), isNotEmpty);
    expect(findBoundaryTriggers('哪门课比较好'), isNotEmpty);
    expect(findBoundaryTriggers('解释这份建议卡'), isEmpty);
    expect(findBoundaryTriggers('这门课为什么标记了冲突'), isEmpty);
    expect(findBoundaryTriggers('帮我整理与导师核对的问题'), isEmpty);
  });

  test('sanitizeAiOutput：输出侧第二道防线', () {
    expect(sanitizeAiOutput('建议选《数据结构与算法》。'), kAiBoundaryFallback);
    expect(sanitizeAiOutput('推荐优先选 01 班。'), kAiBoundaryFallback);
    expect(sanitizeAiOutput('给你一份选课方案：选 A、B、C 三门'), kAiBoundaryFallback);
    // 引用既有 JSON 的冲突复述与核对清单不受影响
    const legit = '与当前课表重叠：周一 第3-4节（第1-16周）。'
        '核对清单：请与教务确认该教学班是否面向你的年级开放？';
    expect(sanitizeAiOutput(legit), legit);
  });

  test('密钥脱敏：回显型网关把裸键写进 400 正文也会被结构性洗掉', () async {
    const key = 'sk-test-abcdef123456';
    const cfg = AiConfig(
        provider: AiProvider.openai,
        baseUrl: 'https://example.invalid/v1',
        apiKey: key,
        model: 'm');
    final client = AiClient(cfg,
        sender: (_) async =>
            AiHttpReply(400, '{"error":"invalid token $key without bearer prefix"}'));
    final out = await client.chat(system: 's', messages: const [
      {'role': 'user', 'content': 'q'}
    ]);
    expect(out, isA<AiFailure>());
    expect((out as AiFailure).message.contains(key), isFalse);
    expect(out.message.contains('***'), isTrue);
    // 引号紧贴 Bearer / app- 前缀键 / 键含 +/ 等类外字符（正则第二层）
    final client2 = AiClient(cfg,
        sender: (_) async => AiHttpReply(422,
            'bad "Bearer app-1a2b3c4d5e6f7890" and Authorization: Bearer abc+def/gh123456'));
    final out2 = await client2.chat(system: 's', messages: const [
      {'role': 'user', 'content': 'q'}
    ]);
    final msg2 = (out2 as AiFailure).message;
    expect(msg2.contains('1a2b3c4d5e6f7890'), isFalse);
    expect(msg2.contains('abc+def'), isFalse);
  });

  test('enabled 要求 http(s):// 前缀：漏写 scheme 直接判未配置（防软锁死）', () async {
    const bad = AiConfig(
        provider: AiProvider.openai,
        baseUrl: 'api.example.com',
        apiKey: 'sk-123456',
        model: 'm');
    expect(bad.enabled, isFalse);
    final out = await AiClient(bad).chat(system: 's', messages: const [
      {'role': 'user', 'content': 'q'}
    ]);
    expect((out as AiFailure).kind, AiFailKind.notConfigured);
  });
}
