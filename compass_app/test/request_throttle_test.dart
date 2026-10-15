// test/request_throttle_test.dart — 限频器单测：限频识别/FIFO/并发上限/间隔削峰/指数退避。
import 'dart:async';

import 'package:test/test.dart';

import 'package:compass_app/data/request_throttle.dart';

void main() {
  group('looksRateLimited（限频/风控识别，对齐 Helechron）', () {
    test('429 无条件限频', () {
      expect(looksRateLimited(429, ''), isTrue);
      expect(looksRateLimited(429, 'anything'), isTrue);
    });
    test('403/503 需命中 WAF/限频/验证码拦截特征才判限频', () {
      expect(looksRateLimited(403, 'Too Many Requests'), isTrue);
      expect(looksRateLimited(403, '访问过于频繁'), isTrue);
      expect(looksRateLimited(403, '<html>WAF blocked</html>'), isTrue);
      expect(looksRateLimited(403, '/jwglxt/xtgl/dl_loginCaptcha.html'), isTrue);
      expect(looksRateLimited(503, '限频'), isTrue);
    });
    test('裸 403 = 认证语义（会话失效），不是限频', () {
      expect(looksRateLimited(403, ''), isFalse);
      expect(looksRateLimited(403, '{"error":"session expired"}'), isFalse);
    });
    test('铁律：HTTP 200 永不判限频（CAS 登录页是 200 且 DOM 含验证码字样）', () {
      // 上一版把这类误判限频，直接杀死登录第一步并污染全局限频冷却——回归测试。
      expect(
          looksRateLimited(200, 'window.location="/jwglxt/xtgl/dl_loginCaptcha.html"'),
          isFalse);
      expect(looksRateLimited(200, '<html>请输入验证码 用户名 密码</html>'), isFalse);
      expect(looksRateLimited(200, 'Too Many Requests'), isFalse);
      expect(looksRateLimited(200, '{"items":[]}'), isFalse);
    });
    test('与会话失效区分（重定向/401 归 looksAuthFailure 管）', () {
      expect(looksRateLimited(302, 'cas/login'), isFalse);
      expect(looksRateLimited(401, ''), isFalse);
      expect(looksRateLimited(200, ''), isFalse);
    });
  });

  group('FIFO 与并发上限', () {
    test('maxInFlight=1 时严格先到先执行', () async {
      final t = RequestThrottle(
          maxInFlight: 1,
          minInterval: Duration.zero,
          jitter: Duration.zero);
      final order = <int>[];
      await Future.wait([
        for (var i = 0; i < 5; i++)
          t.run(() async {
            order.add(i);
          }),
      ]);
      expect(order, [0, 1, 2, 3, 4]);
    });

    test('并发不超过上限，队列正常清空', () async {
      final t = RequestThrottle(
          maxInFlight: 3,
          minInterval: Duration.zero,
          jitter: Duration.zero);
      var inFlight = 0, peak = 0;
      final gate =
          List.generate(6, (_) => Completer<void>());
      final done = <Future<void>>[];
      for (var i = 0; i < 6; i++) {
        done.add(t.run(() async {
          inFlight++;
          peak = peak > inFlight ? peak : inFlight;
          await gate[i].future;
          inFlight--;
        }));
      }
      // 泵异步放行：留足事件循环余量
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(t.inFlight, 3);
      expect(peak, 3);
      expect(t.queued, 3);
      for (final g in gate) {
        g.complete();
      }
      await Future.wait(done);
      expect(t.inFlight, 0);
      expect(t.queued, 0);
    });

    test('最小启动间隔削峰（相邻请求间隔 ≥ minInterval）', () async {
      final t = RequestThrottle(
          maxInFlight: 3,
          minInterval: const Duration(milliseconds: 40),
          jitter: Duration.zero);
      final starts = <DateTime>[];
      await Future.wait([
        for (var i = 0; i < 3; i++)
          t.run(() async => starts.add(DateTime.now())),
      ]);
      expect(starts.length, 3);
      for (var i = 1; i < starts.length; i++) {
        expect(starts[i].difference(starts[i - 1]).inMilliseconds,
            greaterThanOrEqualTo(35)); // 5ms 时钟余量
      }
    });
  });

  group('指数退避冷却', () {
    test('penalize 后下一次 run 等待冷却，成功即复位', () async {
      final t = RequestThrottle(
          minInterval: Duration.zero,
          jitter: Duration.zero,
          backoffBase: const Duration(milliseconds: 80),
          backoffCap: const Duration(milliseconds: 200));
      expect(t.coolingDown, isFalse);
      t.penalize();
      expect(t.coolingDown, isTrue);
      final sw = Stopwatch()..start();
      await t.run(() async {});
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(70)); // ≥80ms 冷却
      expect(t.coolingDown, isFalse); // 成功即复位
      sw
        ..reset()
        ..start();
      await t.run(() async {});
      expect(sw.elapsedMilliseconds, lessThan(50)); // 无冷却，立即执行
    });

    test('连续触发指数增长并封顶（2^(n-1)×base → cap）', () {
      final t = RequestThrottle(
          minInterval: Duration.zero,
          jitter: Duration.zero,
          backoffBase: const Duration(milliseconds: 50),
          backoffCap: const Duration(milliseconds: 300));
      Duration waitAfterPenalize() {
        t.penalize();
        return DateTime.now().difference(t.coolingUntil).abs();
      }

      expect(waitAfterPenalize().inMilliseconds, closeTo(50, 25));
      expect(waitAfterPenalize().inMilliseconds, closeTo(100, 30));
      expect(waitAfterPenalize().inMilliseconds, closeTo(200, 40));
      expect(waitAfterPenalize().inMilliseconds, closeTo(300, 50)); // 封顶
    });
  });
}
