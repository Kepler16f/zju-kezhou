/// data/zju_client.dart — 浙大统一身份认证 + 正方教务网（zdbk）只读客户端。
///
/// 实现来源说明：登录与取数链路的每个细节对齐 Helechron/Celechron（GPL-3.0）被实战验证的行为
/// （execution 表单、RSA 裸 modPow、CAS service 双跳、JSESSIONID+route 成对、xkkh 学期切片、
///   空提交体、Connection:close、portal 证书容忍、校内域直连、票据短 TTL、会话过期自动重登、
///   网络抖动重试），传输层代码为本项目独立编写。
///
/// 关键（上一版登录失败的根因修复）：
///  - 必须 badCertificateCallback 容忍校园 portal 自签名证书；
///  - 必须 *.zju.edu.cn 强制 DIRECT 直连，绕过系统代理/TUN/Fake-IP；
///  - 必须用 dart:io HttpClient（resp.cookies 给出可靠的 Cookie 对象，且能设上述两项）；
///  - 空闲连接 15s 超时，双栈回退 12s 建连超时。
/// 合规：仅只读查询；Cookie 仅内存；凭证沙箱存储；限流+退避；一键清除。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../engine/exam.dart';
import 'credential_store.dart';
import 'diagnostic_log.dart';
import 'plan_models.dart';
import 'request_throttle.dart';
import 'xk_models.dart';
import 'xk_parse.dart';
import 'zju_parse.dart';
import 'zju_parse_ext.dart';

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

class _Resp {
  final int status;
  final String body;
  final Map<String, String> cookies;
  final String? location;
  final bool redirected;
  _Resp(this.status, this.body, this.cookies, this.location, this.redirected);
}

/// isolate 载荷：全部为可序列化类型（String/Map/String?/bool）。
class _HttpReq {
  final String method;
  final String url;
  final Map<String, String> headers;
  final Map<String, String> cookies;
  final String? body;
  final bool follow;
  const _HttpReq(this.method, this.url, this.headers, this.cookies, this.body,
      this.follow);
}

/// 顶层函数：其 isolate 闭包的 Context 仅含本函数的参数 r，绝不捕获 ZjuClient。
/// （0.10.5 实测：闭包内嵌实例方法 _send 时与引用 this 的兄弟闭包共享 Context，
/// 序列化连带 _sessionTask(Future) → unsendable → 全部取数请求降级缓存。）
Future<_Resp> _httpInIsolate(_HttpReq r) => Isolate.run(() async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12)
        ..idleTimeout = const Duration(seconds: 15)
        ..badCertificateCallback = ((cert, host, port) => true)
        ..findProxy = (uri) {
          final host = uri.host.toLowerCase();
          if (host.endsWith('.zju.edu.cn') || host == 'zju.edu.cn') {
            return 'DIRECT';
          }
          return HttpClient.findProxyFromEnvironment(uri);
        };
      try {
        final uri = Uri.parse(r.url);
        final HttpClientRequest req = r.method == 'POST'
            ? await client.postUrl(uri)
            : await client.getUrl(uri);
        req.followRedirects = r.follow;
        req.headers.set('User-Agent', ZjuClient._ua);
        req.headers.set('Connection', 'close');
        r.headers.forEach((k, v) => req.headers.set(k, v));
        r.cookies.forEach((k, v) {
          req.cookies.add(Cookie(k, v)
            ..domain = 'zju.edu.cn'
            ..path = '/');
        });
        final b = r.body;
        if (b != null) {
          req.headers.contentType =
              ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
          req.add(utf8.encode(b));
        }
        final resp = await req.close().timeout(const Duration(seconds: 15));
        final bytes = <int>[];
        await for (final chunk in resp) {
          bytes.addAll(chunk);
        }
        return _Resp(
          resp.statusCode,
          utf8.decode(bytes, allowMalformed: true),
          {for (final c in resp.cookies) c.name: c.value},
          resp.headers.value(HttpHeaders.locationHeader),
          resp.isRedirect,
        );
      } finally {
        client.close(force: true);
      }
    });

/// 二进制响应（PDF 下载专用）：正文绝不做 utf8 解码，否则字节会被 U+FFFD 替换掉。
class _BytesResp {
  final int status;
  final List<int> bytes;
  final Map<String, String> cookies;
  final String? contentType;
  _BytesResp(this.status, this.bytes, this.cookies, this.contentType);
}

/// 二进制请求的 isolate 载荷：连接策略与 [_httpInIsolate] 完全一致，只是不解码正文。
Future<_BytesResp> _httpBytesInIsolate(_HttpReq r) => Isolate.run(() async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12)
        ..idleTimeout = const Duration(seconds: 15)
        ..badCertificateCallback = ((cert, host, port) => true)
        ..findProxy = (uri) {
          final host = uri.host.toLowerCase();
          if (host.endsWith('.zju.edu.cn') || host == 'zju.edu.cn') {
            return 'DIRECT';
          }
          return HttpClient.findProxyFromEnvironment(uri);
        };
      try {
        final uri = Uri.parse(r.url);
        final HttpClientRequest req = r.method == 'POST'
            ? await client.postUrl(uri)
            : await client.getUrl(uri);
        req.followRedirects = r.follow;
        req.headers.set('User-Agent', ZjuClient._ua);
        req.headers.set('Connection', 'close');
        r.headers.forEach((k, v) => req.headers.set(k, v));
        r.cookies.forEach((k, v) {
          req.cookies.add(Cookie(k, v)
            ..domain = 'zju.edu.cn'
            ..path = '/');
        });
        final b = r.body;
        if (b != null) {
          req.headers.contentType =
              ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
          req.add(utf8.encode(b));
        }
        final resp = await req.close().timeout(const Duration(seconds: 30));
        final bytes = <int>[];
        await for (final chunk in resp) {
          bytes.addAll(chunk);
        }
        return _BytesResp(
          resp.statusCode,
          bytes,
          {for (final c in resp.cookies) c.name: c.value},
          resp.headers.value(HttpHeaders.contentTypeHeader),
        );
      } finally {
        client.close(force: true);
      }
    });
/// 会话过期/认证失败特征（参考正方与 CAS 的多种回跳形态）
bool looksAuthFailure(String body, {String? location}) {
  final h = body.toLowerCase();
  if (location != null) {
    final l = location.toLowerCase();
    if (l.contains('identity.zju.edu.cn') || l.contains('cas/login') ||
        l.contains('login_ssologin') || l.contains('auth/realms/zju')) {
      return true;
    }
  }
  return h.contains('cas/login') || h.contains('login_ssologin') ||
      h.contains('统一身份认证') || h.contains('未登录') || h.contains('请先登录') ||
      h.contains('登录已失效') || h.contains('认证失败') ||
      h.contains('"kickout":1') || h.contains('"kickout":"1"') ||
      (h.contains('<html') && h.contains('name="username"'));
}

class ZjuClient {
  static const _zjuam = 'https://zjuam.zju.edu.cn';
  static const _zdbk = 'https://zdbk.zju.edu.cn';
  static const _service =
      '$_zjuam/cas/login?service=https%3A%2F%2Fzdbk.zju.edu.cn%2Fjwglxt%2Fxtgl%2Flogin_ssologin.html';
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _ticketTtl = Duration(minutes: 2);

  final CredentialStore store;
  ZjuClient(this.store);

  DateTime? _ticketAt;
  bool lastFromCache = false;

  // 限频防御管道（对齐 Helechron RequestThrottle 实战参数）：
  // FIFO 公平队列 + 相邻启动最小间隔 250ms±抖动 + 并发 3 上限；
  // 403/429/滑块验证码触发指数退避冷却窗（penalize），任一请求成功即复位。
  final _throttle = RequestThrottle();

  // resize 暂停门：窗口尺寸变化期间暂停网络请求（引擎在"网络回调+resize"
  // 并发时会内核级强杀 0xc000041d，应用层不可拦截——只能时序错开）。
  DateTime _lastMetricsAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 由 UI 层（WidgetsBindingObserver.didChangeMetrics）调用。
  void onMetricsChanged() => _lastMetricsAt = DateTime.now();

  /// 等待窗口稳定（最后一次尺寸变化后 500ms）再发请求。
  Future<void> _waitForStableWindow() async {
    while (DateTime.now().difference(_lastMetricsAt) <
        const Duration(milliseconds: 500)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  /// 兼容保留：网络已全部走后台 Isolate（每请求独立 HttpClient），
  /// 此处仅清理会话内存（清除数据时调用）。
  void disposeClient() {
    store.clearMemory();
  }

  // ── 限频防御 + 网络重试（最多 3 次，凭证错误不重试）──────────────────
  // 旧实现为随机忙等抢占（轮询 _inFlight + 每请求 0~150ms 随机前置延迟），
  // 现改为主机级 FIFO 限频器：排队耗时不计入请求超时预算，见 request_throttle.dart。
  Future<T> _guard<T>(Future<T> Function() action) =>
      _throttle.run(action);

  /// 单次 HTTP 请求在后台 Isolate 执行（关键修复：dart:io 的 socket IO 与引擎
  /// 消息循环并发时，Windows ARM64 引擎在窗口 resize 会原生崩溃 0xc0000005；
  /// 网络挪出主 isolate 后，resize 期间主 isolate 空闲，崩溃路径消除）。
  /// Cookie 以纯字符串跨 isolate 传递；HttpClient 每请求新建即关（Connection:close 语义不变）。
  /// ⚠️ isolate 载荷必须放 static 方法（_httpInIsolate）：0.10.5 实测回归——
  /// 闭包直接内嵌在实例方法 _send 里时与引用 this 的外层共享 Context，
  /// 序列化连带 ZjuClient（含 Future 字段 _sessionTask）→ unsendable，
  /// 所有取数请求抛异常降级缓存（登录成功但成绩/专业/考试全灭）。
  Future<_Resp> _send(String method, String url,
      {Map<String, String> headers = const {},
      Map<String, String> cookies = const {},
      String? body,
      bool follow = false}) {
    return _guard(() async {
      await _waitForStableWindow(); // resize 活跃期暂停网络（防内核强杀）
      Object? lastError;
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          final resp = await _httpInIsolate(
              _HttpReq(method, url, headers, cookies, body, follow));
          // 限频感知（报告 §7）：403/429/滑块验证码 ≠ 会话失效——重登无益且火上浇油。
          // 惩罚 → 指数退避冷却窗；本请求直接上抛（调用方降级缓存），后续请求排队等冷却结束。
          if (looksRateLimited(resp.status, resp.body)) {
            _throttle.penalize();
            _log('限频退避', level: 'warn',
                detail: 'HTTP ${resp.status} 命中风控特征，进入退避冷却窗');
            throw RateLimitedException(
                '教务网限频保护中（HTTP ${resp.status}），已自动退避，请稍候再试');
          }
          return resp;
        } on TimeoutException {
          lastError = AuthException('请求超时（校园网波动，第 $attempt 次尝试）');
        } on SocketException catch (e) {
          lastError = AuthException('网络连接失败：${e.osError?.message ?? e.message}'
              '（校园网外无法直连 zju.edu.cn）');
        } on HandshakeException catch (e) {
          lastError = AuthException('TLS 握手失败：${e.message}');
        }
        if (attempt < 3) {
          await Future.delayed(Duration(milliseconds: 600 * attempt));
        }
      }
      throw lastError!;
    });
  }

  Map<String, String> _jarCookies(Map<String, String> jar) => jar;

  static void _log(String step, {String level = 'ok', String detail = ''}) =>
      DiagnosticLog.instance.record(step, level: level, detail: detail);

  // ── ZJUAM 登录 ──────────────────────────────────────────────────────
  String? get ssoTicket => store.memory('iPlanetDirectoryPro');
  bool get _ticketFresh =>
      ssoTicket != null && _ticketAt != null &&
      DateTime.now().difference(_ticketAt!) < _ticketTtl;

  Future<void> login(String username, String password) async {
    final t0 = DateTime.now();
    _log('ZJUAM 登录开始', detail: '学号尾号 **${username.length > 2 ? username.substring(username.length - 2) : '??'}（不含完整学号/密码）');
    if (username.trim().isEmpty || password.isEmpty) {
      _log('ZJUAM 输入校验', level: 'error', detail: '学号或密码为空');
      throw AuthException('请输入学号与统一身份认证密码');
    }
    // 1. 登录页 → execution + 初始 Cookie（同一 CAS 表单会话）
    final page = await _send('GET', '$_zjuam/cas/login');
    final execution = RegExp(r'name="execution" value="(.*?)"')
        .firstMatch(page.body)
        ?.group(1);
    if (execution == null) {
      _log('登录页', level: 'error',
          detail: 'HTTP ${page.status}，execution=${page.body.contains('execution') ? '存在但正则未中' : '不存在'}，长度=${page.body.length}');
      throw AuthException('登录页解析失败：未找到 execution 令牌'
          '（HTTP ${page.status}；可能网络被 portal 拦截或 CAS 表单已改版）');
    }
    _log('登录页', detail: 'HTTP ${page.status}，execution 已获取，Cookie=${page.cookies.keys.join(",")}');
    // 2. RSA 公钥（沿用登录页 Cookie）
    final pk = await _send('GET', '$_zjuam/cas/v2/getPubKey',
        cookies: _jarCookies(page.cookies));
    final key = json.decode(pk.body) as Map<String, dynamic>;
    final modulus = (key['modulus'] ?? '').toString();
    final exponent = (key['exponent'] ?? '').toString();
    if (modulus.isEmpty || exponent.isEmpty) {
      _log('公钥', level: 'error', detail: 'HTTP ${pk.status}，modulus 长度=${modulus.length}');
      throw AuthException('无法获取认证公钥（HTTP ${pk.status}）');
    }
    _log('公钥', detail: 'modulus ${modulus.length} hex，exponent ${exponent.length} hex');
    // 3. 密码加密：裸 modPow，padLeft 128 hex（与 ZJUAM 前端 JS 一致）
    final modInt = BigInt.parse(modulus, radix: 16);
    final expInt = BigInt.parse(exponent, radix: 16);
    final pwdInt = BigInt.parse(
        utf8.encode(password).map((e) => e.toRadixString(16)).join(), radix: 16);
    final pwdEnc = pwdInt.modPow(expInt, modInt).toRadixString(16).padLeft(128, '0');
    // 4. 提交登录
    final jar1 = {...page.cookies, ...pk.cookies};
    final submit = await _send('POST', '$_zjuam/cas/login',
        headers: {'Referer': '$_zjuam/cas/login'},
        cookies: _jarCookies(jar1),
        body: Uri(queryParameters: {
          'username': username.trim(),
          'password': pwdEnc,
          'execution': execution,
          '_eventId': 'submit',
          'rememberMe': 'true',
        }).query);
    final sso = submit.cookies['iPlanetDirectoryPro'];
    if (sso == null || sso.isEmpty) {
      final hint = looksAuthFailure(submit.body, location: submit.location)
          ? '回跳登录页'
          : 'HTTP ${submit.status}';
      _log('登录提交', level: 'error', detail: '$hint；${DateTime.now().difference(t0).inMilliseconds}ms');
      throw AuthException('统一身份认证失败：学号或密码错误，或认证会话已失效（$hint）');
    }
    store.setMemory('iPlanetDirectoryPro', sso);
    store.setMemory('student_id', username.trim()); // 培养方案/实践分接口需 su=本人学号
    _ticketAt = DateTime.now();
    await store.saveCredentials(username.trim(), password);
    _log('ZJUAM 登录成功', detail: '票据已签发，${DateTime.now().difference(t0).inMilliseconds}ms');
  }

  // ── 正方教务会话 ────────────────────────────────────────────────────
  bool get zdbkLoggedIn =>
      store.memory('JSESSIONID') != null && store.memory('route') != null;

  Future<void>? _sessionTask; // 重登单飞：并发任务共享一次会话重建（防互踩风暴）
  int _sessionFailures = 0;

  /// 确保 zdbk 会话可用：SSO 票据过期则用存储的凭证重新登录（自动重登）。
  /// 关键防崩设计：并发调用共享同一次重建（单飞），避免多任务各自 clearMemory
  /// 互踩会话导致的"重登风暴"（高频请求与窗口 resize 并发会触发引擎原生崩溃）。
  Future<void> ensureZdbkSession({bool force = false}) async {
    if (zdbkLoggedIn && !force) return;
    final pending = _sessionTask;
    if (pending != null) {
      await pending; // 已有重建在进行：等待并复用结果
      return;
    }
    final task = _rebuildZdbkSession();
    _sessionTask = task;
    try {
      await task;
    } finally {
      _sessionTask = null;
    }
  }

  Future<void> _rebuildZdbkSession() async {
    // 只失效旧的 zdbk 会话 cookie（JSESSIONID/route）——保留仍新鲜的 SSO 票据与
    // student_id（对齐 Helechron：iPlanetDirectoryPro 独立于教务会话存活）。
    // 旧实现无条件 clearMemory 会抹掉刚签发的票据，令下方 _ticketFresh 判定失效、
    // 白白重登一次（实测确认）；student_id 是 su= 参数来源，绝不能被会话重建清掉。
    store.removeMemory('JSESSIONID');
    store.removeMemory('route');
    // 连续失败退避：防止会话持续失效时的高频重登循环
    final backoff = _sessionFailures * 2;
    if (backoff > 0) {
      _log('教务网会话', detail: '第 $_sessionFailures 次连续失败，退避 ${backoff}s');
      await Future.delayed(Duration(seconds: backoff.clamp(1, 30)));
    }
    if (!_ticketFresh) {
      final cred = await store.loadCredentials();
      if (cred == null) throw AuthException('请先登录统一身份认证');
      await login(cred.$1, cred.$2); // login 内部会签发新 iPlanetDirectoryPro
    }
    // 双跳：CAS service → Location → 业务站签发 JSESSIONID+route（必须成对）
    final first = await _send('GET', _service,
        cookies: {'iPlanetDirectoryPro': ssoTicket!});
    var location = first.location;
    if (!first.redirected || location == null) {
      store.clearMemory();
      _ticketAt = null;
      _sessionFailures++;
      _log('教务网会话', level: 'error',
          detail: '未回跳 HTTP ${first.status}，票据可能失效（SSO ${_ticketFresh ? "新鲜" : "过期"}）');
      throw AuthException('教务网登录：统一身份认证凭据无效（HTTP ${first.status}'
          '${location == null ? '' : '；Location $location'}），请重新登录');
    }
    if (location.startsWith('http://')) location = 'https://${location.substring(7)}';
    final second = await _send('GET', location);
    if (looksAuthFailure(second.body)) {
      store.clearMemory();
      _ticketAt = null;
      _sessionFailures++;
      _log('教务网会话', level: 'error', detail: '业务站被重定向回认证页 HTTP ${second.status}');
      throw AuthException('教务网登录被重定向到认证页，请重新登录');
    }
    final js = second.cookies['JSESSIONID'], rt = second.cookies['route'];
    if (js == null || rt == null) {
      _sessionFailures++;
      _log('教务网会话', level: 'error',
          detail: 'JSESSIONID=${js != null}, route=${rt != null}，HTTP ${second.status}');
      throw AuthException('教务网会话建立失败（缺少 JSESSIONID/route，HTTP ${second.status}）');
    }
    store.setMemory('JSESSIONID', js);
    store.setMemory('route', rt);
    // 会话初始化：正方业务页要求先访问一次菜单页（否则业务查询被判"未登录"）
    try {
      await _send('GET', '$_zdbk/jwglxt/xtgl/index_initMenu.html', headers: {
        'Referer': '$_zdbk/jwglxt/xtgl/login_ssologin.html',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      }, cookies: {'JSESSIONID': js, 'route': rt});
    } catch (_) {/* 初始化失败不阻断——业务请求会自行重试 */}
    _sessionFailures = 0;
    _log('教务网会话', detail: 'JSESSIONID+route 已建立（含菜单页初始化）');
  }

  /// 成绩拉取（只读）。网络/会话异常降级返回缓存并标记 lastFromCache。
  Future<List<Map<String, dynamic>>> fetchTranscript() async {
    List<Map<String, dynamic>>? items;
    try {
      await ensureZdbkSession();
      items = await _postJwgl('cxdy/xscjcx_cxXscjIndex.html');
      await store.saveCache('transcript', json.encode(items));
      lastFromCache = false;
      _log('成绩拉取', detail: '${items.length} 条原始记录');
    } on RateLimitedException {
      final cached = await _loadCachedCourses();
      if (cached == null) rethrow;
      lastFromCache = true;
      _log('成绩拉取', level: 'warn', detail: '限频退避，降级返回缓存 ${cached.length} 条');
      return cached;
    } on AuthException {
      final cached = await _loadCachedCourses();
      if (cached == null) rethrow;
      lastFromCache = true;
      _log('成绩拉取', level: 'warn', detail: '认证失败，降级返回缓存 ${cached.length} 条');
      return cached;
    } catch (_) {
      final cached = await _loadCachedCourses();
      if (cached == null) rethrow;
      lastFromCache = true;
      _log('成绩拉取', level: 'warn', detail: '网络异常，降级返回缓存 ${cached.length} 条');
      return cached;
    }
    final courses = items.map(gradeItemToCourse).whereType<Map<String, dynamic>>().toList();
    if (courses.isEmpty) {
      _log('成绩解析', level: 'error', detail: '${items.length} 条原始记录解析后为空（字段名可能变更）');
      throw AuthException('教务网返回的成绩为空或格式变更');
    }
    return courses;
  }

  Future<List<Map<String, dynamic>>?> _loadCachedCourses() async {
    final cached = await store.readCache('transcript');
    if (cached == null) return null;
    try {
      final list = (json.decode(cached) as List).cast<Map<String, dynamic>>();
      return list.map(gradeItemToCourse).whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return null;
    }
  }

  /// 正方教务查询 POST：参数在 query string、提交体为空（对齐实战）；会话过期自动重建重试一次。
  Future<List<Map<String, dynamic>>> _postJwgl(String path, {bool retried = false}) async {
    final uri = Uri.parse('$_zdbk/jwglxt/$path').replace(queryParameters: {
      'doType': 'query',
      'queryModel.showCount': '5000',
    });
    final resp = await _send('POST', uri.toString(), headers: {
      'Referer': '$_zdbk/jwglxt/xtgl/index_initMenu.html',
      'Accept': 'application/json, text/javascript, */*; q=0.01',
      'X-Requested-With': 'XMLHttpRequest',
    }, cookies: _jarCookies({
      'JSESSIONID': store.memory('JSESSIONID')!,
      'route': store.memory('route')!,
    }));
    // 裸 403（非限频型）= 会话失效：限频型 403 已在 _send 内 penalize+抛，走不到这里。
    final expired = resp.redirected || resp.status == 401 || resp.status == 403 ||
        looksAuthFailure(resp.body, location: resp.location);
    if (expired) {
      if (retried) throw AuthException('教务会话持续失效，请稍后再试');
      await ensureZdbkSession(force: true); // 单飞重建（不手动 clear，防并发互踩）
      return _postJwgl(path, retried: true);
    }
    final payload = json.decode(resp.body);
    if (payload is! Map) throw StateError('成绩接口返回非预期格式（HTTP ${resp.status}）');
    return (payload['items'] as List? ?? const []).cast<Map<String, dynamic>>();
  }

  /// 通用：带提交体的查询（培养方案列表用），返回响应文本。
  Future<String> _postQuery(Uri uri, Map<String, String>? formBody,
      {bool retried = false, String? referer}) async {
    final resp = await _send('POST', uri.toString(), headers: {
      'Referer': referer ?? '$_zdbk/jwglxt/xtgl/index_initMenu.html',
      'Accept': 'application/json, text/javascript, */*; q=0.01',
      'X-Requested-With': 'XMLHttpRequest',
    }, cookies: _jarCookies({
      'JSESSIONID': store.memory('JSESSIONID')!,
      'route': store.memory('route')!,
    }), body: formBody?.entries
            .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
            .join('&'));
    // 裸 403（非限频型）= 会话失效：限频型 403 已在 _send 内 penalize+抛，走不到这里。
    final expired = resp.redirected || resp.status == 401 || resp.status == 403 ||
        looksAuthFailure(resp.body, location: resp.location);
    if (expired) {
      if (retried) throw AuthException('教务会话持续失效，请稍后再试');
      await ensureZdbkSession(force: true);
      return _postQuery(uri, formBody, retried: true, referer: referer);
    }
    return resp.body;
  }

  /// 通用 GET HTML 页面（学业生涯/打印页/实践分）。
  /// referer：部分正方页面（方案打印/查看）要求来源为方案列表页，否则回错误页。
  Future<String> _getHtml(String path,
      {bool retried = false, String? referer}) async {
    final resp = await _send('GET', '$_zdbk/jwglxt/$path', headers: {
      'Referer': referer ?? '$_zdbk/jwglxt/xtgl/index_initMenu.html',
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    }, cookies: _jarCookies({
      'JSESSIONID': store.memory('JSESSIONID')!,
      'route': store.memory('route')!,
    }));
    // 裸 403（非限频型）= 会话失效：限频型 403 已在 _send 内 penalize+抛，走不到这里。
    final expired = resp.redirected || resp.status == 401 || resp.status == 403 ||
        looksAuthFailure(resp.body, location: resp.location);
    if (expired) {
      if (retried) throw AuthException('教务会话持续失效（$path），请稍后再试');
      await ensureZdbkSession(force: true);
      return _getHtml(path, retried: true, referer: referer);
    }
    return resp.body;
  }

  /// 探针/诊断专用：原始 GET HTML / POST JSON（只读；不记正文、不落盘、App 业务 UI 不调用）。
  /// 用于接口形态回归取证（如选课入口结构变化）。
  Future<String> rawGetHtmlForProbe(String path) => _getHtml(path);

  Future<String> rawPostForProbe(String path, Map<String, String> form) =>
      _postQuery(Uri.parse('$_zdbk/jwglxt/$path'), form);

  // ── 业务接口：专业识别 / 培养方案 / 实践分 ─────────────────────────
  /// 本人学号（正方部分接口不带 su= 会返回空数据，登录时已存）。
  String? get _studentId => store.memory('student_id');
  String get _suParam {
    final su = _studentId;
    return (su == null || su.isEmpty) ? '' : '&su=$su';
  }

  /// 从 JSON 或 HTML 响应体提取专业（对齐 Helechron：先按 JSON 解析再按 HTML 键值对）。
  String? _majorFromBody(String body) {
    try {
      final decoded = json.decode(body);
      if (decoded is Map) {
        // 学生信息接口常把字段包在 DataBody/Map 里
        for (final m in [decoded, decoded['DataBody'], decoded['Map']]) {
          if (m is Map<String, dynamic>) {
            final v = majorFromKeyValuePairs(
                m.map((k, val) => MapEntry(k, val?.toString() ?? '')));
            if (v != null) return v;
          }
        }
      }
    } catch (_) {}
    final pairs = parseHtmlKeyValuePairs(body);
    final v = majorFromKeyValuePairs(pairs);
    if (v != null) return v;
    final alert =
        RegExp(r'(?:专业|主修|大类)[：:]\s*([^\s<",，]+)').firstMatch(body);
    final av = alert?.group(1)?.trim();
    if (av != null && av.length >= 2) return av;
    return null;
  }

  /// 解析落空时的紧凑结构探针（进诊断日志，辅助定位页面版式差异）。
  /// 只记录解析到的键名与"专业/大类"字样附近片段，绝不含完整姓名/学号。
  static String _majorProbe(String body) {
    final keys = parseHtmlKeyValuePairs(body).keys.take(12).toList();
    final frag = RegExp(r'专业|主修|大类|班级').firstMatch(body);
    var ctx = '';
    if (frag != null) {
      final start = frag.start > 40 ? frag.start - 10 : 0;
      ctx = body
          .substring(start, (frag.start + 60).clamp(0, body.length))
          .replaceAll(RegExp(r'<[^>]+>'), '·')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (ctx.length > 50) ctx = ctx.substring(0, 50);
    }
    // 壳页判别：去标签后的主体文本（脱敏：≥8 位数字串打码），用于区分
    // "空壳页需二次 POST 查询"与"该生暂无记录"。
    var text = body
        .replaceAll(RegExp(r'<script[\s\S]*?</script>|<style[\s\S]*?</style>',
            caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    text = text.replaceAll(RegExp(r'\d{8,}'), '****');
    if (text.length > 160) text = text.substring(0, 160);
    return 'keys=${keys.join(",")} 片段="$ctx" 正文="$text"';
  }

  /// 学生主修专业名。来源优先级对齐 Helechron：主修成绩 JSON（xszgkc，行内直接带
  /// zymc，最可靠）→ 学业生涯 N105515 → 学生信息 N100801（JSON+HTML 双解）→
  /// 学籍维护 → 学生证补办卡面（N106005）。任一命中即缓存并返回。
  Future<String?> fetchStudentMajor() async {
    await ensureZdbkSession();
    // 0) 主修成绩接口（Helechron getMajorGrade 同款）：items[].zymc 直接是专业全称。
    try {
      final items =
          await _postJwgl('zycjtj/xszgkc_cxXsZgkcIndex.html');
      _log('专业识别',
          detail: '主修成绩接口返回 ${items.length} 行'
              '${items.isNotEmpty ? '；首行键=${items.first.keys.take(10).join(",")}' : ''}');
      for (final it in items) {
        final major = majorFromKeyValuePairs(
            it.map((k, v) => MapEntry(k, v?.toString() ?? '')));
        if (major != null) {
          final normalized = normalizeMajorName(major);
          _log('专业识别', detail: '$normalized（主修成绩接口）');
          await store.saveCache('major', normalized);
          return normalized;
        }
      }
    } catch (e) {
      _log('专业识别', level: 'warn', detail: '主修成绩接口: $e');
    }
    // 1) 课表接口（Helechron getTimetable 主力来源）：响应 JSON 的 xsxx 字段直接带
    //    zymc/学院/班级学籍信息。实测本机三个 GET 信息页 404、主修成绩 0 行时，
    //    这条 POST 接口是唯一对新生可用的专业来源（xqm：3=秋、12=春）。
    final now = DateTime.now();
    final isAutumn = now.month >= 8;
    final yearStart = isAutumn ? now.year : now.year - 1;
    final kbCandidates = [
      ['$yearStart-${yearStart + 1}', isAutumn ? '3' : '12'],
      ['$yearStart-${yearStart + 1}', isAutumn ? '12' : '3'],
      ['${yearStart - 1}-$yearStart', '12'],
    ];
    for (final c in kbCandidates) {
      try {
        final body = await _postQuery(
            Uri.parse('$_zdbk/jwglxt/kbcx/xskbcx_cxXsKb.html'),
            {'xnm': c[0], 'xqm': c[1]});
        if (body.contains('captcha_error')) {
          _log('专业识别', level: 'warn', detail: '${c[0]}-${c[1]} 需验证码，跳过');
          continue;
        }
        final payload = json.decode(body);
        final xsxx = payload is Map ? payload['xsxx'] : null;
        if (xsxx is Map) {
          final major = majorFromKeyValuePairs(
              xsxx.map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')));
          _log('专业识别',
              detail: '课表 ${c[0]}-${c[1]}：xsxx 键=${xsxx.keys.take(10).join(",")} 解析=$major');
          if (major != null) {
            final normalized = normalizeMajorName(major);
            await store.saveCache('major', normalized);
            return normalized;
          }
        } else {
          final topKeys = payload is Map
              ? payload.keys.join(",")
              : payload is List
                  ? 'List(${payload.length})'
                  : '${payload.runtimeType}';
          _log('专业识别', level: 'warn',
              detail: '课表 ${c[0]}-${c[1]}：响应无 xsxx（长度 ${body.length}；顶层键=$topKeys）');
          // xsxx 之外的顶层键里也可能藏学籍（实例差异），尝试整包 map 提取
          if (payload is Map) {
            final major = majorFromKeyValuePairs(
                payload.map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')));
            if (major != null) {
              _log('专业识别', detail: '课表 ${c[0]}-${c[1]}：顶层键命中=$major');
              final normalized = normalizeMajorName(major);
              await store.saveCache('major', normalized);
              return normalized;
            }
          }
        }
      } catch (e) {
        _log('专业识别', level: 'warn', detail: '课表 ${c[0]}-${c[1]}: $e');
      }
    }
    final sources = <String>[
      'GET:xsxy/xsxyqk_cxXsxyqkIndex.html?gnmkdm=N105515&layout=default$_suParam',
      'GET:xsxxxggl/xsxxwh_cxCkDgxsxx.html?gnmkdm=N100801$_suParam',
      'GET:xsxxxggl/xsgrxxwh_cxXsgrxx.html?gnmkdm=N100801&layout=default$_suParam',
    ];
    for (final src in sources) {
      final path = src.substring(4);
      final tag = path.split('?').first.split('/').last;
      try {
        final body = await _getHtml(path);
        final major = _majorFromBody(body);
        if (major != null) {
          final normalized = normalizeMajorName(major);
          _log('专业识别', detail: '$normalized（$tag）');
          await store.saveCache('major', normalized);
          return normalized;
        }
        _log('专业识别', level: 'warn',
            detail: '$tag 解析落空（长度 ${body.length}）${_majorProbe(body)}');
      } catch (e) {
        _log('专业识别', level: 'warn', detail: '$tag: $e');
      }
    }
    // 卡面兜底（N106005 学生证补办信息里有专业）
    try {
      final uri = Uri.parse(
          '$_zdbk/jwglxt/xszbbgl/xszbbgl_cxXszbbsqIndex.html?doType=details&gnmkdm=N106005$_suParam');
      final text = await _postQuery(uri, {
        'offDetails': '1',
        'gnmkdm': 'N106005',
        'czdmKey': '00',
      });
      final major = _majorFromBody(text);
      if (major != null) {
        _log('专业识别', detail: '${normalizeMajorName(major)}（卡面）');
        return normalizeMajorName(major);
      }
    } catch (_) {}
    return null;
  }

  /// 培养方案查询（保留旧签名）：一次全量目录 + 客户端匹配。
  /// 旧实现会对专业名每个变体各发一次全量请求（单次响应可达十几 MB），既慢又招风控。
  Future<List<Map<String, dynamic>>> fetchPlansForMajor(
      {required String majorName, String? grade}) async {
    final tried = <String>{};
    final all = <Map<String, dynamic>>[];
    Future<void> attempt(String? qMajor, String? qGrade) async {
      final key = '${qMajor ?? ""}|${qGrade ?? ""}';
      if (tried.contains(key)) return;
      tried.add(key);
      try {
        final items = await fetchPlanList(majorName: qMajor, grade: qGrade);
        all.addAll(items);
      } catch (e) {
        _log('方案列表', level: 'warn', detail: 'q=$key: $e');
      }
    }

    // 一次全量目录 + 客户端匹配（旧实现对每个变体各发一次全量请求，既慢又招风控）。
    await attempt(majorName, grade);
    // 去重（同一 pyfa_id 会被多次查询带回来）
    final seen = <String>{};
    return all.where((it) {
      final id = (it['pyfa_id'] ?? it['id'] ?? '').toString();
      return id.isNotEmpty && seen.add(id);
    }).toList();
  }

  /// 培养方案列表（保留旧签名，新链路见 [resolveAuditPlan]）。
  /// ⚠️ 参数已按实测修正：服务端只认 synj(年级)/zydm(专业代码)/xydm(学院)/jxjhh(教学计划号)，
  /// 旧实现发的 zymc/njdm_id 会让正方直接回 HTML 错误页（json.decode 抛错）。
  /// 专业名过滤改在客户端做（见 [matchPlans]）。
  Future<List<Map<String, dynamic>>> fetchPlanList(
      {String? majorName, String? grade}) async {
    await ensureZdbkSession();
    final pageUrl =
        '$_zdbk/jwglxt/pyfagl/pyfaxxcx_cxPyfaxscxIndex.html?gnmkdm=N153020&layout=default$_suParam';
    final uri = Uri.parse('$_zdbk/jwglxt/pyfagl/pyfaxxcx_cxPyfaxscxIndex.html')
        .replace(queryParameters: {'doType': 'query', 'gnmkdm': 'N153020'});
    final body = <String, String>{
      'queryModel.showCount': '5000',
      'queryModel.currentPage': '1',
      '_search': 'false',
      // ⚠️ 服务端只认 synj(年级)/zydm(专业代码)/xydm(学院)/jxjhh(教学计划号)：
      // 旧实现发的是 zymc/njdm_id，正方直接回 HTML 错误页 → json.decode 抛错，
      // 这就是"应用取不到培养方案"的根因（参数名见 jwglxt/js/.../pyfaxscx.js）。
      if (grade != null && grade.isNotEmpty) 'synj': grade,
    };
    final text = await _postQuery(
        Uri.parse('$uri$_suParam'), body, referer: pageUrl);
    dynamic decoded;
    try {
      decoded = json.decode(text);
    } catch (e) {
      // 实例差异诊断：正方某些模块 action 未映射会回 HTML 404 页。
      final flat = text
          .replaceAll(RegExp(r'<script[\s\S]*?</script>|<style[\s\S]*?</style>',
              caseSensitive: false), ' ')
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim()
          .replaceAll(RegExp(r'\d{6,}'), '****');
      _log('方案列表', level: 'warn',
          detail: '响应非 JSON（长度 ${text.length}）：${flat.substring(0, flat.length > 160 ? 160 : flat.length)}');
      rethrow;
    }
    final items =
        (decoded is Map ? decoded['items'] : decoded) as List? ?? const [];
    var rows = items.whereType<Map<String, dynamic>>().toList();
    // 服务端没有"专业名"查询项：拿回列表后在此收敛（顺序即匹配强度，见 matchPlans）。
    if (majorName != null && majorName.trim().isNotEmpty) {
      final matched = matchPlans(rows.map(PlanSummary.fromRow).toList(),
          majorName: majorName, grade: grade, maxCandidates: 40);
      rows = matched.candidates.map((c) => c.plan.raw).toList();
    }
    _log('方案列表',
        detail: 'zymc=${majorName ?? "-"} nj=${grade ?? "-"} → ${rows.length} 条');
    return rows;
  }

  /// 培养方案打印页 → PlanFile（老链路，保留兼容）。
  /// 学生账号上 dyPyfaxs/cxPyfaxsView 多回 HTTP 910（这两个 action 属教师菜单），
  /// 现在的主链路是 [resolveAuditPlan]（列表接口摘要 / 课程明细）。
  Future<Map<String, dynamic>?> fetchPlanDetail(String pyfaId,
      {String majorName = '', String grade = ''}) async {
    await ensureZdbkSession();
    // 先取缓存的结构化结果（Helechron 同款 key 策略）
    final cached = await store.readCache('plan_$pyfaId');
    if (cached != null) {
      try {
        return json.decode(cached) as Map<String, dynamic>;
      } catch (_) {}
    }
    // 打印/查看页要求 Referer=方案列表页（默认菜单页 Referer 会回错误页，实测）
    final planReferer =
        '$_zdbk/jwglxt/$_planListPath?gnmkdm=$_planMenu&layout=default$_suParam';
    for (final path in [
      'pyfagl/pyfaxxcx_dyPyfaxs.html?pyfa_id=$pyfaId&gnmkdm=N153020$_suParam',
      'pyfagl/pyfaxxcx_cxPyfaxsView.html?pyfa_id=$pyfaId&gnmkdm=N153020$_suParam',
    ]) {
      try {
        final html = await _getHtml(path, referer: planReferer);
        if (html.length < 500) continue;
        final plan = parsePlanPrintHtml(html,
            pyfaId: pyfaId, majorName: majorName, grade: grade);
        _log('方案解析',
            detail: '${(plan['courses'] as List).length} 门课'
                '，质量提示 ${(plan['meta']['quality'] as List).length} 条');
        await store.saveCache('plan_$pyfaId', json.encode(plan));
        return plan;
      } catch (e) {
        _log('方案解析', level: 'warn', detail: '$path: $e');
      }
    }
    return null;
  }

  // ── 业务接口：学籍画像 / 培养方案 ───────────────────────────────────────────
  // 实测结论（勿回退）：
  //  * 学生端"培养方案查询" = 菜单 N153020 的方案列表接口 + PDF 预览；
  //  * 列表接口 showCount=5000 时一次拿全校方案（totalPage=1），故"匹配"放客户端做；
  //  * 打印页/查看页/课程明细在学生账号上回 HTTP 910（无该功能权限：usable=false），
  //    因此课程明细走多端点 best-effort，全部落空时用方案摘要兜底；
  //  * 旧实现的专业识别链在本实例上是死的（N105515→404、N100801→910、
  //    学籍信息页→404），课表接口是唯一活着的学籍来源。

  /// 上次方案目录是否取自缓存（UI 据此提示"离线数据"）。
  bool lastPlanFromCache = false;

  static const _planListPath = 'pyfagl/pyfaxxcx_cxPyfaxscxIndex.html';
  static const _planMenu = 'N153020';

  static String _cacheSafe(String? s) =>
      (s ?? '').replaceAll(RegExp(r'[^0-9A-Za-z]'), '');

  /// 学籍画像：课表接口把学籍平铺在响应顶层
  /// （zy 专业 / xy 学院 / xzb 行政班 / xh 学号 / xm 姓名），顺带给出年级。
  /// 行政班尾四位 = 年级 + 班号（如"工科试验班（计算机）2606" → 2026 级）。
  Future<StudentProfile> fetchStudentProfile({bool refresh = false}) async {
    if (!refresh) {
      final cached = await store.readCache('student_profile');
      if (cached != null) {
        try {
          final p =
              StudentProfile.fromJson(json.decode(cached) as Map<String, dynamic>);
          if (!p.isEmpty) return p;
        } catch (_) {/* 缓存损坏则重新拉取 */}
      }
    }
    await ensureZdbkSession();
    final now = DateTime.now();
    final isAutumn = now.month >= 8;
    final y0 = isAutumn ? now.year : now.year - 1;
    final candidates = <List<String>>[
      ['$y0-${y0 + 1}', isAutumn ? '3' : '12'],
      ['$y0-${y0 + 1}', isAutumn ? '12' : '3'],
      ['${y0 - 1}-$y0', '12'],
      ['${y0 - 1}-$y0', '3'],
      ['${y0 + 1}-${y0 + 2}', '3'],
    ];
    for (final c in candidates) {
      try {
        final body = await _postQuery(
            Uri.parse('$_zdbk/jwglxt/kbcx/xskbcx_cxXsKb.html?gnmkdm=N2151$_suParam'),
            {'xnm': c[0], 'xqm': c[1]});
        final t = body.trim();
        if (!t.startsWith('{')) continue;
        final profile =
            StudentProfile.fromJson(json.decode(t) as Map<String, dynamic>);
        if (profile.isEmpty) continue;
        await store.saveCache('student_profile', json.encode(profile.toJson()));
        _log('学籍画像', detail: '${profile.majorName}｜${profile.college}｜'
            '${profile.adminClass}（学期 ${c[0]}-${c[1]}）');
        return profile;
      } catch (e) {
        _log('学籍画像', level: 'warn', detail: '学期 ${c[0]}-${c[1]}: $e');
      }
    }
    _log('学籍画像', level: 'error', detail: '课表接口未返回学籍信息（可能不在校园网）');
    return const StudentProfile();
  }

  /// 培养方案目录。默认一次拉全量并缓存（方案总量不大，客户端匹配省往返也少招风控）；
  /// 传 grade/majorCode 时走服务端精确过滤（synj/zydm）。
  Future<List<PlanSummary>> fetchPlanCatalog({
    String? grade,
    String? majorCode,
    String? collegeCode,
    String? jxjhh,
    bool refresh = false,
  }) async {
    final filtered =
        [grade, majorCode, collegeCode, jxjhh].any((v) => (v ?? '').trim().isNotEmpty);
    final cacheKey = filtered
        ? 'plan_catalog_${_cacheSafe(grade)}_${_cacheSafe(majorCode)}'
            '_${_cacheSafe(collegeCode)}_${_cacheSafe(jxjhh)}'
        : 'plan_catalog';
    if (!refresh && !filtered) {
      final cached = await store.readCache(cacheKey);
      if (cached != null) {
        final rows = _decodePlanRows(cached);
        if (rows.isNotEmpty) {
          lastPlanFromCache = true;
          _log('方案目录', detail: '命中缓存 ${rows.length} 条');
          return rows;
        }
      }
    }
    await ensureZdbkSession();
    final body = <String, String>{
      'queryModel.showCount': '5000',
      'queryModel.currentPage': '1',
      '_search': 'false',
      // ⚠️ 实测：只有这组参数被接受（showCount + currentPage + _search，外加
      // synj/zydm/xydm/jxjhh 过滤项）。少一个会因为服务端走另一条分支而回 HTML 错误页。
      if ((grade ?? '').trim().isNotEmpty) 'synj': grade!.trim(),
      if ((majorCode ?? '').trim().isNotEmpty) 'zydm': majorCode!.trim(),
      if ((collegeCode ?? '').trim().isNotEmpty) 'xydm': collegeCode!.trim(),
      if ((jxjhh ?? '').trim().isNotEmpty) 'jxjhh': jxjhh!.trim(),
    };
    final referer =
        '$_zdbk/jwglxt/$_planListPath?gnmkdm=$_planMenu&layout=default$_suParam';
    final text = await _postQuery(
        Uri.parse(
            '$_zdbk/jwglxt/$_planListPath?doType=query&gnmkdm=$_planMenu$_suParam'),
        body,
        referer: referer);
    final rows = _decodePlanRows(text);
    if (rows.isEmpty) {
      throw AuthException('培养方案列表为空或返回异常'
          '${filtered ? '（服务端过滤 synj=${grade ?? "-"} zydm=${majorCode ?? "-"} 无结果）' : '（全量查询无结果）'}');
    }
    if (!filtered) {
      lastPlanFromCache = false;
      await store.saveCache(
          cacheKey, json.encode(rows.map((r) => r.raw).toList()));
    }
    _log('方案目录', detail: '${rows.length} 条'
        '${filtered ? '（服务端过滤 synj=${grade ?? "-"} zydm=${majorCode ?? "-"}）' : '（全量，已缓存）'}');
    return rows;
  }

  /// 响应正文 → 方案行（非 JSON / 解析失败 / 无 items 都安全降级为空表并留痕）。
  List<PlanSummary> _decodePlanRows(String text) {
    final t = text.trim();
    if (t.isEmpty || (!t.startsWith('{') && !t.startsWith('['))) {
      _log('方案目录', level: 'warn',
          detail: '响应非 JSON（长度 ${t.length}）：${_flattenForLog(t)}');
      return const [];
    }
    dynamic decoded;
    try {
      decoded = json.decode(t);
    } catch (e) {
      _log('方案目录', level: 'warn', detail: 'JSON 解析失败：$e');
      return const [];
    }
    final raw = decoded is Map ? decoded['items'] : decoded;
    if (raw is! List) {
      _log('方案目录', level: 'warn',
          detail: '响应无 items 字段（顶层键 ${decoded is Map ? decoded.keys.join(",") : decoded.runtimeType}）');
      return const [];
    }
    final out = <PlanSummary>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final row = <String, dynamic>{};
      item.forEach((k, v) => row[k.toString()] = v);
      final plan = PlanSummary.fromRow(row);
      if (plan.id.isNotEmpty) out.add(plan);
    }
    return out;
  }

  /// 诊断用：响应压平成一行（去脚本/标签、压空白、长数字打码）。
  static String _flattenForLog(String text) {
    final flat = text
        .replaceAll(
            RegExp(r'<script[\s\S]*?</script>|<style[\s\S]*?</style>',
                caseSensitive: false),
            ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\d{8,}'), '****');
    return flat.length > 200 ? '${flat.substring(0, 200)}…' : flat;
  }

  /// 按学籍（专业名 × 年级）匹配培养方案；歧义（多条相近）交给 UI 请用户点选。
  /// 上次手动选定的方案会优先沿用（只在它仍属于候选时）。
  Future<PlanMatchResult> matchStudentPlan({
    StudentProfile? profile,
    String? majorName,
    String? grade,
    bool refresh = false,
  }) async {
    final p = profile ?? await fetchStudentProfile(refresh: refresh);
    final name = (majorName ?? p.majorName).trim();
    final g = (grade ?? p.grade ?? '').trim();
    if (name.isEmpty) {
      return const PlanMatchResult(majorName: '', notes: [
        '未识别到专业名称：请到设置页登录教务网后重试，或在本页手动搜索专业',
      ]);
    }
    final catalog = await fetchPlanCatalog(refresh: refresh);
    final result = matchPlans(catalog, majorName: name, grade: g.isEmpty ? null : g);
    final savedId = await savedPlanId();
    if (savedId != null && result.candidates.length > 1) {
      final idx = result.candidates
          .indexWhere((c) => c.plan.id == savedId || c.plan.jxjhh == savedId);
      if (idx > 0) {
        final reordered = [...result.candidates];
        final picked = reordered.removeAt(idx);
        reordered.insert(0, picked);
        return PlanMatchResult(
          majorName: result.majorName,
          grade: result.grade,
          candidates: reordered,
          notes: [
            ...result.notes,
            '已沿用你上次选定的方案：${picked.plan.zymc} ${picked.plan.synj} 级',
          ],
        );
      }
    }
    return result;
  }

  /// 记住用户选定的方案（下次自动沿用；只存非敏感标识与名称）。
  Future<void> selectPlan(PlanSummary plan) async {
    await store.saveCache(
        'plan_selection',
        json.encode({
          'jxjhh': plan.jxjhh,
          'pyfaxx_id': plan.pyfaxxId,
          'zymc': plan.zymc,
          'synj': plan.synj,
          'zydm': plan.zydm,
          'selected_at': DateTime.now().toIso8601String(),
        }));
  }

  /// 上次选定的方案 id（教学计划号优先）。
  Future<String?> savedPlanId() async {
    final raw = await store.readCache('plan_selection');
    if (raw == null) return null;
    try {
      final m = json.decode(raw) as Map<String, dynamic>;
      final id = (m['jxjhh'] ?? m['pyfaxx_id'] ?? '').toString().trim();
      return id.isEmpty ? null : id;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearPlanSelection() async =>
      store.saveCache('plan_selection', '{}');

  /// 方案课程明细（多端点 best-effort）：任一端点给出课程行即返回；全部落空返回空表。
  Future<List<PlanCourseRow>> fetchPlanCourseTable(PlanSummary plan) async {
    final jxjhh = plan.jxjhh.trim(), pid = plan.pyfaxxId.trim();
    if (jxjhh.isEmpty && pid.isEmpty) return const [];
    final id = pid.isNotEmpty ? pid : jxjhh;
    final planReferer =
        '$_zdbk/jwglxt/$_planListPath?gnmkdm=$_planMenu&layout=default$_suParam';
    final attempts = <String, Future<List<PlanCourseRow>> Function()>{
      '课程列表(jxjhh)': () => _kcListPost('jxjhh', jxjhh),
      '课程列表(pyfaxx_id)': () => _kcListPost('pyfaxx_id', pid),
      '方案详情(ckPyfaJbxx)': () => _kcRowsFromHtml(
          // 列表页 JS 实测：查看按钮 GET pyfaxxwh_ckPyfaJbxx.html?pyfaxx_id=<ids>
          'pyfagl/pyfaxxwh_ckPyfaJbxx.html?pyfaxx_id=$id&gnmkdm=$_planMenu$_suParam',
          referer: planReferer),
      '方案查看(cxPyfaxsView)': () => _kcRowsFromHtml(
          'pyfagl/pyfaxxcx_cxPyfaxsView.html?pyfa_id=$id&gnmkdm=$_planMenu$_suParam',
          referer: planReferer),
      '方案打印(dyPyfaxs)': () => _kcRowsFromHtml(
          'pyfagl/pyfaxxcx_dyPyfaxs.html?pyfa_id=$id&gnmkdm=$_planMenu$_suParam',
          referer: planReferer),
    };
    for (final entry in attempts.entries) {
      try {
        final rows = await entry.value();
        if (rows.isNotEmpty) {
          _log('方案课程表', detail: '${entry.key} 命中 ${rows.length} 门');
          return rows;
        }
      } catch (e) {
        _log('方案课程表', level: 'warn', detail: '${entry.key}: $e');
      }
    }
    _log('方案课程表', level: 'warn',
        detail: '全部端点无课程明细（学生端该功能多属教师菜单，HTTP 910）');
    return const [];
  }

  Future<List<PlanCourseRow>> _kcListPost(String key, String value) async {
    if (value.trim().isEmpty) return const [];
    final text = await _postQuery(
      Uri.parse(
          '$_zdbk/jwglxt/pyfagl/pyfaxxcx_cxPyfaxsKcList.html?doType=query&gnmkdm=$_planMenu$_suParam'),
      {
        key: value,
        'queryModel.showCount': '1000',
        'queryModel.currentPage': '1',
        '_search': 'false',
      },
      referer:
          '$_zdbk/jwglxt/$_planListPath?gnmkdm=$_planMenu&layout=default$_suParam',
    );
    return _rowsFromPayload(text);
  }

  Future<List<PlanCourseRow>> _kcRowsFromHtml(String path,
      {String? referer}) async {
    final html = await _getHtml(path, referer: referer);
    if (html.length < 400) return const [];
    return _rowsFromPayload(html);
  }

  /// 课程明细响应 → 课程行。JSON items 与 HTML 表格都吃；
  /// 权限不足/会话失效的正方回包（usable=false、status=0）必须当"取不到"，
  /// 否则会被误判成"这门方案没有课程"。
  List<PlanCourseRow> _rowsFromPayload(String text) {
    final t = text.trim();
    if (t.startsWith('{') || t.startsWith('[')) {
      if (t.contains('"usable":false') || t.contains('"status":0')) return const [];
      dynamic decoded;
      try {
        decoded = json.decode(t);
      } catch (_) {
        return const [];
      }
      final raw = decoded is Map ? decoded['items'] : decoded;
      if (raw is! List) return const [];
      final out = <PlanCourseRow>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final row = <String, dynamic>{};
        item.forEach((k, v) => row[k.toString()] = v);
        final r = PlanCourseRow.fromRow(row);
        if (!r.isEmpty) out.add(r);
      }
      return out;
    }
    if (t.contains('<tr') || t.contains('<table')) {
      return parsePlanCourseRows(t)
          .map((r) => PlanCourseRow(
                name: (r['name'] ?? '').toString(),
                credits: (r['credits'] as num?)?.toDouble(),
                nature: (r['nature'] ?? '').toString(),
                module: (r['module'] ?? '').toString(),
                raw: r,
              ))
          .where((r) => !r.isEmpty)
          .toList();
    }
    return const [];
  }

  /// 教务课程模块 → PlanFile 模块 id（无映射时按课程性质粗分）。
  static String _moduleIdOf(PlanCourseRow r) {
    final m = '${r.module}${r.nature}';
    if (m.contains('通识') || m.contains('公共') || m.contains('校定')) {
      return 'general_required';
    }
    if (m.contains('实践') || m.contains('实习') || m.contains('设计') ||
        m.contains('论文')) {
      return 'intensive_practice';
    }
    if (m.contains('选')) return 'major_limited';
    return 'major_core';
  }

  /// 培养方案 PDF（学生端列表"预览"按钮同款端点，id=教学计划号）：
  ///   `GET /jwglxt/pyfagl/pyfayl_cxPyfaylPdf.html?id=<jxjhh>&doType=query`
  /// 返回原始字节（调用方自行校验 %PDF / 落盘）；拿不到返回 null。
  Future<List<int>?> fetchPlanPdf(PlanSummary plan) async {
    for (final id in [plan.jxjhh.trim(), plan.pyfaxxId.trim()]) {
      if (id.isEmpty) continue;
      final bytes = await _fetchPdfBytes(id);
      if (bytes != null) return bytes;
    }
    return null;
  }

  Future<List<int>?> _fetchPdfBytes(String id) async {
    await ensureZdbkSession();
    final url = '$_zdbk/jwglxt/pyfagl/pyfayl_cxPyfaylPdf.html'
        '?id=${Uri.encodeQueryComponent(id)}&doType=query&gnmkdm=$_planMenu$_suParam';
    Future<_BytesResp> once() => _sendBytes(url, headers: {
          'Referer':
              '$_zdbk/jwglxt/$_planListPath?gnmkdm=$_planMenu&layout=default$_suParam',
          'Accept': 'application/pdf,*/*',
        }, cookies: _jarCookies({
          'JSESSIONID': store.memory('JSESSIONID')!,
          'route': store.memory('route')!,
        }));
    var resp = await once();
    if (resp.status == 401 || resp.status == 403 || resp.status == 910) {
      await ensureZdbkSession(force: true);
      resp = await once();
    }
    final bytes = resp.bytes;
    if (bytes.length >= 4 &&
        bytes[0] == 0x25 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x44 &&
        bytes[3] == 0x46) {
      _log('方案PDF', detail: 'PDF ${bytes.length} 字节（id=$id）');
      return bytes;
    }
    _log('方案PDF', level: 'warn',
        detail: '非 PDF 响应 HTTP ${resp.status} ct=${resp.contentType} '
            'len=${bytes.length}：'
            '${_flattenForLog(utf8.decode(bytes.take(160).toList(), allowMalformed: true))}');
    return null;
  }

  /// 二进制下载（PDF）：与 [_send] 同一条限频/重试管道，但不解码正文。
  Future<_BytesResp> _sendBytes(String url,
      {Map<String, String> headers = const {},
      Map<String, String> cookies = const {}}) {
    return _guard(() async {
      await _waitForStableWindow();
      Object? lastError;
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          return await _httpBytesInIsolate(
              _HttpReq('GET', url, headers, cookies, null, true));
        } on TimeoutException {
          lastError = AuthException('方案下载超时（校园网波动，第 $attempt 次尝试）');
        } on SocketException catch (e) {
          lastError = AuthException(
              '网络连接失败：${e.osError?.message ?? e.message}（校园网外无法直连 zju.edu.cn）');
        } on HandshakeException catch (e) {
          lastError = AuthException('TLS 握手失败：${e.message}');
        }
        if (attempt < 3) {
          await Future.delayed(Duration(milliseconds: 600 * attempt));
        }
      }
      throw lastError!;
    });
  }

  /// 审计用：一次给出"方案摘要 + PlanFile + 课程表 + 质量说明"。
  /// 课程明细拿得到就用明细建模块，拿不到就按方案摘要（核心课/实践课/前沿课）建，
  /// 并在 notes 里如实说明——绝不假装方案完备。
  Future<ResolvedPlan> resolveAuditPlan({
    required String majorName,
    String? grade,
    List<Map<String, dynamic>> transcript = const [],
    bool refresh = false,
  }) async {
    PlanMatchResult result;
    try {
      result = await matchStudentPlan(
          majorName: majorName, grade: grade, refresh: refresh);
    } on AuthException catch (e) {
      return ResolvedPlan(notes: ['培养方案获取失败：${e.message}']);
    }
    final best = result.best;
    if (best == null) {
      return ResolvedPlan(
          notes: result.notes.isEmpty
              ? ['教务方案库中没有与「$majorName」匹配的方案']
              : result.notes);
    }
    final plan = best.plan;
    final notes = <String>[...result.notes];
    if (result.ambiguous) {
      notes.add('有 ${result.candidates.length} 条相近方案，可在「培养方案」页切换确认');
    }

    var table = const <PlanCourseRow>[];
    try {
      table = await fetchPlanCourseTable(plan);
    } catch (e) {
      _log('方案课程表', level: 'warn', detail: '$e');
    }

    Map<String, dynamic> planFile;
    if (table.isNotEmpty) {
      planFile = planFileFromCourseRows(
        table
            .map((r) => <String, dynamic>{
                  'name': r.name,
                  'credits': r.credits ?? 0.0,
                  'nature': r.nature,
                  'module': _moduleIdOf(r),
                  'offered': const ['秋', '春'],
                  'page': 1,
                })
            .toList(),
        majorName: plan.zymc,
        grade: plan.synj,
        totalCredits: plan.zdbyxf,
        sourceDoc: '教务网培养方案 ${plan.zymc} ${plan.synj} 级'
            '（教学计划号 ${plan.jxjhh}｜课程明细接口实时获取）',
      );
      notes.add('课程明细来自教务接口，共 ${table.length} 门');
    } else {
      planFile =
          planFileFromSummary(plan, grade: plan.synj, transcript: transcript);
      notes.add('教务未开放逐门课程表（学生端只有 PDF 预览），'
          '已按方案摘要（专业核心课/核心实践课/前沿与荣誉课程）构建');
    }
    await selectPlan(plan);
    _log('培养方案', detail: '${plan.zymc} ${plan.synj} 级'
        '（${plan.id}）｜课程 ${table.length} 门｜学分 ${plan.creditsLabel}');
    return ResolvedPlan(
      summary: plan,
      planFile: planFile,
      courseTable: table,
      notes: notes,
      matched: true,
    );
  }
  /// 实践分/课堂分（第二三四课堂，N108001 + su=）。
  Future<Map<String, double>> fetchPracticeScores() async {
    await ensureZdbkSession();
    try {
      final html = await _getHtml(
          'dessktgl/dessktcx_cxDessktcxIndex.html?gnmkdm=N108001&layout=default$_suParam');
      final scores = parsePracticeScores(html);
      _log('课堂分', detail: scores.entries.map((e) => '${e.key}=${e.value}').join(' '));
      return scores;
    } catch (e) {
      _log('课堂分', level: 'warn', detail: '$e');
      return {};
    }
  }

  /// 考试安排（只读，尽力而为，报告 §6 考试冲刺的数据源）：正方 N305505 考试查询。
  /// JSON 行解析失败回退 HTML 表格兜底；任何异常降级返回缓存（无缓存返回空数组），
  /// 绝不阻断学业主链路。
  Future<List<ExamInfo>> fetchExams() async {
    Future<List<ExamInfo>?> fromCache() async {
      final cached = await store.readCache('exams');
      if (cached == null) return null;
      try {
        return examsFromRows(json.decode(cached) as List);
      } catch (_) {
        return null;
      }
    }

    try {
      await ensureZdbkSession();
      final uri = Uri.parse('$_zdbk/jwglxt/ksgl/xskscx_cxXsksxxIndex.html')
          .replace(queryParameters: {'doType': 'query', 'gnmkdm': 'N305505'});
      final text = await _postQuery(Uri.parse('$uri$_suParam'), const {
        'queryModel.showCount': '200',
        'queryModel.currentPage': '1',
        '_search': 'false',
      });
      List<ExamInfo> exams;
      try {
        final decoded = json.decode(text);
        final rows = decoded is Map
            ? (decoded['items'] as List? ?? const [])
            : decoded is List
                ? decoded
                : const [];
        exams = examsFromRows(rows);
      } catch (_) {
        exams = examsFromHtmlTable(text);
      }
      if (exams.isNotEmpty) {
        await store.saveCache(
            'exams', json.encode([for (final e in exams) _examToCacheRow(e)]));
      }
      _log('考试安排', detail: '${exams.length} 场');
      return exams;
    } on RateLimitedException {
      final cached = await fromCache();
      _log('考试安排', level: 'warn',
          detail: '限频退避，${cached == null ? '无缓存' : '降级缓存 ${cached.length} 条'}');
      return cached ?? const [];
    } catch (e) {
      final cached = await fromCache();
      _log('考试安排', level: 'warn',
          detail: '$e（降级${cached == null ? '为空' : '缓存 ${cached.length} 条'}）');
      return cached ?? const [];
    }
  }

  /// ExamInfo → 缓存行（沿用 kcmc/ksrq/kssj/jsmc/zwh 规范字段，回读走 examFromRow）。
  Map<String, dynamic> _examToCacheRow(ExamInfo e) {
    String p2(int v) => v.toString().padLeft(2, '0');
    return {
      'kcmc': e.name,
      'ksrq': '${e.start.year}-${p2(e.start.month)}-${p2(e.start.day)}',
      'kssj': '${p2(e.start.hour)}:${p2(e.start.minute)}~'
          '${p2(e.end.hour)}:${p2(e.end.minute)}',
      if (e.location.isNotEmpty) 'jsmc': e.location,
      if (e.seat.isNotEmpty) 'zwh': e.seat,
    };
  }

  // ── 业务接口：选课(xsxk)（只读；提交/退课等写接口绝不调用，见 docs/选课模块接入说明.md）──
  // 两套页面形态（LIVE 取证 2026-10-16）：
  //  - 通用正方：zzxkyzb_cxZzxkYzbIndex.html?gnmkdm=N253512（入口=轮次×类别 xkkz_id）；
  //  - 浙大：zzxkghb_cxZzxkGhbIndex.html?gnmkdm=N253530（入口=课程类别 dl，列表走 KcList）。
  // 浙大实例 N253512 路径直接 404，故双路径都试，以能解出入口者为准。

  static const _xkIndexPath = 'xsxk/zzxkyzb_cxZzxkYzbIndex.html';
  static const _xkListPath = 'xsxk/zzxkyzb_cxZzxkYzbPartDisplay.html';
  static const _xkMenu = 'N253512';
  static const _xkGhbIndexPath = 'xsxk/zzxkghb_cxZzxkGhbIndex.html';
  static const _xkGhbListPath = 'xsxk/zzxkghb_cxZzxkGhbKcList.html';
  static const _xkGhbMenu = 'N253530';

  /// 缓存键分量编码：base64url（去掉 '='）保住原值，避免 _cacheSafe 把不同 xkkzId
  /// 清洗成同一个键（如 'AB-CD' 与 'ABCD' 撞键，评审L2）。
  static String _cacheToken(String s) =>
      base64Url.encode(utf8.encode(s)).replaceAll('=', '');

  /// 上次选课入口是否来自缓存（UI 据此提示"离线/可能过期"）。
  bool lastXkIndexFromCache = false;

  /// 选课首页：入口（类别×轮次）发现 + 查询参数采集（隐藏域）。
  /// 轮次信息内嵌于页面 onclick（无独立轮次接口，评审A1）；xklc 拿不到就留空，不臆取。
  /// 缓存策略（评审L2 改口径）：**缓存优先**——回读带「可能过期」标注，「刷新入口」走直连；
  /// xkkz_id 随选课批次变化，缓存可能过期是已知事实（UI 已如实标注）。
  Future<XkIndexParseResult> fetchXkIndex({bool refresh = false}) async {
    const cacheKey = 'xk_index';
    Future<XkIndexParseResult?> fromCache() async {
      final cached = await store.readCache(cacheKey);
      if (cached == null) return null;
      try {
        final obj = json.decode(cached);
        if (obj is! Map) return null;
        final rounds = <XkRound>[];
        for (final r in (obj['rounds'] as List? ?? const [])) {
          if (r is Map && '${r['xkkz_id'] ?? ''}'.isNotEmpty) {
            rounds.add(XkRound(
              xkkzId: '${r['xkkz_id']}',
              kklxdm: '${r['kklxdm'] ?? ''}',
              xklc: '${r['xklc'] ?? ''}'.isEmpty ? null : '${r['xklc']}',
              label: '${r['label'] ?? ''}',
            ));
          }
        }
        if (rounds.isEmpty) return null;
        return XkIndexParseResult(
          rounds: rounds,
          xkxnm: obj['xkxnm']?.toString(),
          xkxqm: obj['xkxqm']?.toString(),
          firstXkkzId: obj['firstXkkzId']?.toString(),
          issues: const ['读取自本地缓存（可能过期，请刷新）'],
          queryCourseHits: (obj['hits'] as num?)?.toInt() ?? rounds.length,
          zjuGhb: obj['zju_ghb'] == true,
          hiddenFields: {
            for (final e in ((obj['hidden'] as Map?) ?? const {}).entries)
              '${e.key}': '${e.value}',
          },
          fromCache: true,
          fetchedAtMillis: (obj['fetched_at'] as num?)?.toInt() ?? 0,
        );
      } catch (_) {
        return null;
      }
    }

    if (!refresh) {
      final cached = await fromCache();
      if (cached != null) {
        lastXkIndexFromCache = true;
        return cached;
      }
    }
    lastXkIndexFromCache = false;
    try {
      await ensureZdbkSession();
      var html =
          await _getHtml('$_xkIndexPath?gnmkdm=$_xkMenu&layout=default$_suParam');
      var parsed = parseXkIndexHtml(html);
      // 浙大实例：通用路径 404/无入口 → 改打浙大自主选课页（zzxkGhb）。
      final is404 = html.contains('HTTP Status 404');
      if (parsed.rounds.isEmpty && !parsed.zjuGhb) {
        final hbHtml = await _getHtml(
            '$_xkGhbIndexPath?gnmkdm=$_xkGhbMenu&layout=default$_suParam');
        final hbParsed = parseXkIndexHtml(hbHtml);
        if (hbParsed.rounds.isNotEmpty) {
          parsed = hbParsed;
          html = hbHtml;
        } else if (is404) {
          // 两页都不通：保留通用路径的 issues，但如实提到 404
          parsed = XkIndexParseResult(
              rounds: const [],
              hiddenFields: parsed.hiddenFields,
              issues: [...parsed.issues, ...hbParsed.issues]);
        }
      }
      if (parsed.rounds.isNotEmpty) {
        await store.saveCache(
            cacheKey,
            json.encode({
              'fetched_at': DateTime.now().millisecondsSinceEpoch,
              'xkxnm': parsed.xkxnm,
              'xkxqm': parsed.xkxqm,
              'firstXkkzId': parsed.firstXkkzId,
              'hits': parsed.queryCourseHits,
              'zju_ghb': parsed.zjuGhb,
              'hidden': parsed.hiddenFields,
              'rounds': [
                for (final x in parsed.rounds)
                  {
                    'xkkz_id': x.xkkzId,
                    'kklxdm': x.kklxdm,
                    'xklc': x.xklc,
                    'label': x.label,
                  }
              ],
            }));
      }
      _log('选课入口',
          detail: '命中 ${parsed.queryCourseHits} 处｜入口 ${parsed.rounds.length} 个'
              '${parsed.issues.isEmpty ? '' : '｜${parsed.issues.first}'}');
      return parsed;
    } on RateLimitedException {
      final cached = await fromCache();
      lastXkIndexFromCache = cached != null;
      _log('选课入口', level: 'warn',
          detail: '限频退避，${cached == null ? '无缓存' : '降级缓存'}');
      return cached ??
          const XkIndexParseResult(rounds: [], issues: ['限频退避且无缓存，请稍后再试']);
    } catch (e) {
      final cached = await fromCache();
      lastXkIndexFromCache = cached != null;
      _log('选课入口', level: 'warn', detail: '$e${cached == null ? '' : '（降级缓存）'}');
      return cached ??
          XkIndexParseResult(rounds: const [], issues: ['选课入口获取失败：$e']);
    }
  }

  /// 上次课程列表是否来自缓存（UI 据此提示"离线/可能过期"）。
  bool lastXkListFromCache = false;

  /// 某入口（xkkz_id）的课程列表（只读）。
  /// 参数策略（评审A2）：以首页采集的 hiddenFields 为底 + 本次 xkkz_id/kklxdm + 防缓存
  /// nd/time；正方对缺参数回空数据而不报错（更难发现），所以参数宁全勿缺。
  /// 三态（评审A6）：data/empty 才落缓存；unavailable 绝不落缓存、绝不当「无课」。
  /// 缓存策略（评审L2）：缓存优先（issues/dropped 原样随缓存落盘回读；回读重解析若降级为
  /// unavailable 视同无缓存）；键用 base64url 编码分量，防清洗撞键。
  Future<XkListParseResult> fetchXkCourses({
    required XkRound round,
    Map<String, String> hiddenFields = const {},
    String? xkxnm,
    String? xkxqm,
    bool zjuGhb = false, // 浙大自主选课页形态（入口=课程类别 dl）
    bool refresh = false,
  }) async {
    final term =
        ((xkxnm ?? '').isNotEmpty && (xkxqm ?? '').isNotEmpty) ? '$xkxnm-$xkxqm' : '';
    final cacheKey = 'xk_${_cacheToken(term)}_${_cacheToken(round.xkkzId)}';
    Future<XkListParseResult?> fromCache() async {
      final cached = await store.readCache(cacheKey);
      if (cached == null) return null;
      try {
        final obj = json.decode(cached);
        if (obj is! Map) return null;
        final state = '${obj['state'] ?? ''}';
        final at = (obj['fetched_at'] as num?)?.toInt() ?? 0;
        // 原始 issues/dropped 随缓存落盘并原样回读（重解析会丢"有 N 行被跳过"这类留痕，评审L2）
        final storedIssues =
            (obj['issues'] as List? ?? const []).map((e) => '$e').toList();
        final storedDropped = (obj['dropped'] as num?)?.toInt() ?? 0;
        if (state == 'empty') {
          return XkListParseResult(
              courses: const [],
              state: 'empty',
              issues: [...storedIssues, '读取自本地缓存（可能过期，请刷新）'],
              fromCache: true,
              fetchedAtMillis: at);
        }
        final rows = obj['rows'] as List? ?? const [];
        final parsed = parseXkCourseList(json.encode({'tmpList': rows}),
            xkkzId: round.xkkzId, xklc: round.xklc, label: round.label);
        // 回读重解析若降级为 unavailable（行损坏/字段名变更）：视同无缓存，交给网络刷新
        if (parsed.state == 'unavailable') return null;
        return XkListParseResult(
          courses: parsed.courses,
          state: parsed.state,
          issues: [...storedIssues, '读取自本地缓存（可能过期，请刷新）'],
          dropped: storedDropped,
          fromCache: true,
          fetchedAtMillis: at,
        );
      } catch (_) {
        return null;
      }
    }

    if (!refresh) {
      final cached = await fromCache();
      if (cached != null) {
        lastXkListFromCache = true;
        return cached;
      }
    }
    lastXkListFromCache = false;
    try {
      await ensureZdbkSession();
      final now = DateTime.now().millisecondsSinceEpoch;
      final String text;
      if (zjuGhb) {
        // 浙大 zzxkGhb：入口=类别 dl，参数来自首页隐藏域（xn/xq/nj/zydm）。
        // 不在开放期 KcList 返回空数组 → empty（不是 unavailable，如实呈现"本学期该类别暂无可选课程"）。
        final xn = hiddenFields['xn'] ?? xkxnm ?? '';
        final xq = hiddenFields['xq'] ?? xkxqm ?? '1';
        final uri = Uri.parse('$_zdbk/jwglxt/$_xkGhbListPath')
            .replace(queryParameters: {
          'gnmkdm': _xkGhbMenu,
          if ((_studentId ?? '').isNotEmpty) 'su': _studentId!,
          'nd': '$now',
          'time': '0',
        });
        text = await _postQuery(uri, {
          'dl': round.xkkzId,
          'lx': round.kklxdm,
          'xkmc': '',
          'kcbs': '',
          'nj': hiddenFields['nj'] ?? '',
          'xn': xn,
          'xq': xq,
          'zydm': hiddenFields['zydm'] ?? '',
          'jxjhh': '',
          'xnxq': '($xn-$xq)-',
          'kspage': '1',
          'jspage': '100',
        });
      } else {
        final query = <String, String>{
          ...hiddenFields,
          'gnmkdm': _xkMenu,
          'xkkz_id': round.xkkzId,
          if (round.kklxdm.isNotEmpty) 'kklxdm': round.kklxdm,
          if (term.isNotEmpty) 'xkxnm': xkxnm!,
          if (term.isNotEmpty) 'xkxqm': xkxqm!,
          'nd': '$now',
          'time': '0',
        };
        final su = _studentId;
        if (su != null && su.isNotEmpty) query['su'] = su;
        final uri =
            Uri.parse('$_zdbk/jwglxt/$_xkListPath').replace(queryParameters: query);
        text = await _postQuery(uri, {
          'xkkz_id': round.xkkzId,
          if (round.kklxdm.isNotEmpty) 'kklxdm': round.kklxdm,
          if (term.isNotEmpty) 'xkxnm': xkxnm!,
          if (term.isNotEmpty) 'xkxqm': xkxqm!,
          'kspage': '1',
          'jspage': '1',
        });
      }
      final parsed = parseXkCourseList(text,
          xkkzId: round.xkkzId, xklc: round.xklc, label: round.label);
      if (parsed.state == 'data' || parsed.state == 'empty') {
        await store.saveCache(
            cacheKey,
            json.encode({
              'fetched_at': now,
              'state': parsed.state,
              'label': round.label,
              'issues': parsed.issues,
              'dropped': parsed.dropped,
              'rows': [for (final c in parsed.courses) c.raw],
            }));
      }
      // 日志只记 入口/状态/条数/首条 issue —— 绝不记完整 URL（含 su）与响应正文（评审A11）
      _log('选课列表',
          detail: '${round.label.isEmpty ? round.xkkzId : round.label}｜${parsed.state}'
              '｜${parsed.courses.length} 条'
              '${parsed.issues.isEmpty ? '' : '｜${parsed.issues.first}'}');
      return parsed;
    } on RateLimitedException {
      final cached = await fromCache();
      lastXkListFromCache = cached != null;
      _log('选课列表', level: 'warn',
          detail: '限频退避，${cached == null ? '无缓存' : '降级缓存'}');
      return cached ??
          const XkListParseResult(
              courses: [], state: 'unavailable', issues: ['限频退避且无缓存，请稍后再试']);
    } catch (e) {
      final cached = await fromCache();
      lastXkListFromCache = cached != null;
      _log('选课列表', level: 'warn', detail: '$e${cached == null ? '' : '（降级缓存）'}');
      return cached ??
          XkListParseResult(
              courses: const [], state: 'unavailable', issues: ['课程列表获取失败：$e']);
    }
  }

  /// 上次课表时隙是否来自缓存。
  bool lastTimetableFromCache = false;

  /// 当前课表时隙（xskbcx kbList 解析；选课冲突检测的数据源，只读）。
  /// 学期候选与 fetchStudentProfile 同款（同端点同参数，仅取 kbList）。
  /// 学期一致性（评审L2）：响应回显学期与请求不符的候选一律不接受；缓存按学期归属校验，
  /// 不符视同无缓存；第一候选（本学期）明确返回空课表＝真实空，不再向后猜学期。
  Future<TimetableParseResult> fetchTimetableSlots({bool refresh = false}) async {
    const cacheKey = 'timetable_slots';
    final now = DateTime.now();
    final isAutumn = now.month >= 8;
    final y0 = isAutumn ? now.year : now.year - 1;
    // 学期码（LIVE 取证）：xnm='YYYY-YYYY+1'，xqm='1' 秋冬 / '2' 春夏；
    // 子学期细分参数是 '1|秋'/'1|冬'/'1|短'/'1|暑'/'2|春'/'2|夏'（默认主学期即覆盖全部）。
    final candidates = <List<String>>[
      ['$y0-${y0 + 1}', '1'],
      ['$y0-${y0 + 1}', '2'],
      ['${y0 - 1}-$y0', '1'],
      ['${y0 - 1}-$y0', '2'],
    ];
    Future<TimetableParseResult?> fromCache() async {
      final cached = await store.readCache(cacheKey);
      if (cached == null) return null;
      try {
        final obj = json.decode(cached) as Map<String, dynamic>;
        // 学期归属校验：缓存学期必须等于本机当前学期第一候选，否则视同无缓存
        final cxnm = obj['xnm']?.toString() ?? '';
        final cxqm = obj['xqm']?.toString() ?? '';
        if (cxnm != candidates[0][0] || cxqm != candidates[0][1]) return null;
        final slots = (obj['slots'] as List? ?? const [])
            .whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList();
        if (slots.isEmpty) return null;
        return TimetableParseResult(
          slots: slots,
          courses: ((obj['courses'] as List? ?? const [])).map((e) => '$e').toList(),
          issues: const ['读取自本地缓存（可能过期，请刷新）'],
          fromCache: true,
          fetchedAtMillis: (obj['fetched_at'] as num?)?.toInt() ?? 0,
        );
      } catch (_) {
        return null;
      }
    }

    if (!refresh) {
      final cached = await fromCache();
      if (cached != null) {
        lastTimetableFromCache = true;
        return cached;
      }
    }
    lastTimetableFromCache = false;
    await ensureZdbkSession(); // 评审L2：选课段唯一漏调会话的入口（冷会话下 4 连败）
    for (final c in candidates) {
      try {
        final body = await _postQuery(
            Uri.parse('$_zdbk/jwglxt/kbcx/xskbcx_cxXsKb.html?gnmkdm=N2151$_suParam'),
            {'xnm': c[0], 'xqm': c[1]});
        final t = body.trim();
        if (!t.startsWith('{')) continue;
        final decoded = json.decode(t) as Map<String, dynamic>;
        // 学期回显校验：回显与请求不符 → 该候选不接受（防把别的学期课表当本学期）
        final echoXnm = decoded['xnm']?.toString() ?? '';
        final echoXqm = decoded['xqm']?.toString() ?? '';
        if ((echoXnm.isNotEmpty && echoXnm != c[0]) ||
            (echoXqm.isNotEmpty && echoXqm != c[1])) {
          _log('当前课表', level: 'warn',
              detail: '学期回显不一致（请求 ${c[0]}-${c[1]}，回显 $echoXnm-$echoXqm），跳过');
          continue;
        }
        final parsed = parseXskbListToSlots(decoded['kbList']);
        if (parsed.courses.isEmpty) {
          // 本学期明确返回空课表（且回显一致）：如实表现为"未排课/未检查"，不向后猜学期
          if (identical(c, candidates.first)) {
            return const TimetableParseResult(
                slots: [], issues: ['本学期课表为空（尚未排课？）：冲突检测按未检查处理']);
          }
          continue;
        }
        await store.saveCache(
            cacheKey,
            json.encode({
              'fetched_at': DateTime.now().millisecondsSinceEpoch,
              'xnm': c[0],
              'xqm': c[1],
              'slots': parsed.slots,
              'courses': parsed.courses,
            }));
        _log('当前课表',
            detail: '学期 ${c[0]}-${c[1]}｜${parsed.courses.length} 门｜'
                '${parsed.slots.length} 个时隙');
        return parsed;
      } catch (e) {
        _log('当前课表', level: 'warn', detail: '学期 ${c[0]}-${c[1]}: $e');
      }
    }
    final cached = await fromCache();
    lastTimetableFromCache = cached != null;
    _log('当前课表', level: 'warn',
        detail: '课表接口未返回课程表${cached == null ? '' : '（降级缓存）'}');
    return cached ??
        const TimetableParseResult(slots: [], issues: ['课表获取失败：冲突检测将不可用']);
  }
}
