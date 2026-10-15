/// data/request_throttle.dart — 主机级请求限频器（对齐 Helechron request_throttle 实战参数）。
/// 背景：zdbk 部署了敏感的反爬限频，首页多路并发（Future.wait 课表/成绩/考试/信息）
/// 极易触发 HTTP 403/429 拦截或重定向到滑块验证码页（dl_loginCaptcha.html）。
/// 设计要点（报告 §7）：
///  - FIFO 公平队列：先到先得，不做随机忙等抢占；
///  - 相邻请求最小启动间隔 250ms + 0~200ms 抖动（削峰）；
///  - 最大并发 3；排队耗时不计入请求超时预算（拿到许可后调用方才开表）；
///  - 限频响应 → 指数退避冷却窗（2^(n-1)×base，封顶 cap），任一请求成功即复位；
///  - 许可释放在 finally 中执行，杜绝队列死锁。
library;

import 'dart:async';
import 'dart:math';

/// 限频/风控响应特征（对齐 Helechron request_throttle.isRateLimitedResponse）。
/// 铁律：**HTTP 200 永不判限频**——CAS 正常登录页就是 200 且 DOM 含"验证码"字样，
/// 若按正文关键词判限频会误杀第一步登录（旧实现的回归教训）。仅：
///  - 429 无条件限频；
///  - 403/503 且正文命中 WAF/限频/滑块拦截特征才判限频（裸 403 是认证语义，归 looksAuthFailure）。
bool looksRateLimited(int status, String body) {
  if (status == 429) return true;
  if (status != 403 && status != 503) return false;
  final h = body.toLowerCase();
  return h.contains('rate limit') ||
      h.contains('too many requests') ||
      h.contains('限频') ||
      h.contains('访问频繁') ||
      h.contains('访问过于频繁') ||
      h.contains('请求过于频繁') ||
      h.contains('waf') ||
      h.contains('dl_logincaptcha') ||
      h.contains('captcha_error') ||
      h.contains('验证码');
}

class RateLimitedException implements Exception {
  final String message;
  RateLimitedException(this.message);
  @override
  String toString() => message;
}

class RequestThrottle {
  RequestThrottle({
    this.maxInFlight = 3,
    this.minInterval = const Duration(milliseconds: 250),
    this.jitter = const Duration(milliseconds: 200),
    this.backoffBase = const Duration(seconds: 2),
    this.backoffCap = const Duration(seconds: 30),
    Random? rand,
  }) : _rand = rand ?? Random();

  final int maxInFlight;
  final Duration minInterval;
  final Duration jitter;
  final Duration backoffBase;
  final Duration backoffCap;
  final Random _rand;

  final List<Completer<void>> _waiters = []; // FIFO：队尾进，队首出
  bool _pumping = false;
  int _inFlight = 0;
  DateTime _lastStart = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _coolingUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int _strikes = 0;

  int get inFlight => _inFlight;
  int get queued => _waiters.length;
  bool get coolingDown => DateTime.now().isBefore(_coolingUntil);
  DateTime get coolingUntil => _coolingUntil; // 诊断/测试用

  /// 排队拿许可 → 执行 → finally 释放。排队等待不占用调用方的超时预算。
  Future<T> run<T>(Future<T> Function() action) async {
    await _acquire();
    try {
      final r = await action();
      _onSuccess();
      return r;
    } finally {
      _release();
    }
  }

  /// 限频惩罚：第 n 次连续触发 → 2^(n-1)×base 冷却窗（封顶 cap）。
  void penalize() {
    _strikes++;
    final shift = (_strikes - 1).clamp(0, 20);
    final d = backoffBase * (1 << shift);
    _coolingUntil = DateTime.now().add(d > backoffCap ? backoffCap : d);
  }

  void _onSuccess() {
    _strikes = 0;
    _coolingUntil = DateTime.fromMillisecondsSinceEpoch(0);
  }

  Future<void> _acquire() {
    final c = Completer<void>();
    _waiters.add(c);
    _pump();
    return c.future;
  }

  void _release() {
    _inFlight--;
    _pump();
  }

  /// 单泵串行放行：入队期间泵若在等待（冷却/间隔/并发），由循环自身消化新入队者。
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_waiters.isNotEmpty) {
        final cool = _coolingUntil.difference(DateTime.now());
        if (cool > Duration.zero) {
          await Future<void>.delayed(cool);
          continue;
        }
        final gap = DateTime.now().difference(_lastStart);
        if (gap < minInterval) {
          final j = jitter > Duration.zero
              ? Duration(microseconds: _rand.nextInt(jitter.inMicroseconds + 1))
              : Duration.zero;
          await Future<void>.delayed(minInterval - gap + j);
          continue;
        }
        if (_inFlight >= maxInFlight) {
          // 等待释放；释放路径也会调 _pump，此处轮询兜底
          await Future<void>.delayed(const Duration(milliseconds: 15));
          continue;
        }
        _waiters.removeAt(0).complete();
        _inFlight++;
        _lastStart = DateTime.now();
      }
    } finally {
      _pumping = false;
    }
  }
}
