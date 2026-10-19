// test/proxy_policy_test.dart — 代理选择策略回归（任务 #13，纯函数，不发真实网络）。
// 覆盖：findProxyDirectiveFor 纯函数两态；AiHttpRequest.direct 的默认值与传递。
import 'package:test/test.dart';

import 'package:compass_app/data/ai_client.dart';

void main() {
  group('findProxyDirectiveFor（AI 直连开关 -> findProxy 指令）', () {
    test('direct=true -> DIRECT（绕过系统/环境变量代理）', () {
      expect(findProxyDirectiveFor(direct: true), 'DIRECT');
    });

    test('direct=false -> null（不设 findProxy，维持默认走系统代理）', () {
      expect(findProxyDirectiveFor(direct: false), isNull);
    });
  });

  group('AiHttpRequest.direct（isolate 载荷的直连标志载体）', () {
    test('缺省 false：既有构造点行为不变（向后兼容的红线）', () {
      const req = AiHttpRequest(url: 'https://api.example.com/v1/chat/completions');
      expect(req.direct, isFalse);
    });

    test('显式传 true 时字段保留', () {
      const req = AiHttpRequest(
        url: 'https://api.example.com/v1/chat/completions',
        direct: true,
      );
      expect(req.direct, isTrue);
    });
  });
}
