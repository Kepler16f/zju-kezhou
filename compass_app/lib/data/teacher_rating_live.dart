/// data/teacher_rating_live.dart — 教师评分**实时查询**客户端（v0.13.8）。
///
/// 与 teacher_rating.dart 的分工：
///  * teacher_rating.dart = 本地种子表（零网络，随安装包更新，首帧立即显示）；
///  * 本文件 = 运行时按需向「查老师」拉取最新评分（只读 GET），本地缓存 24h，
///    失败静默回落种子表/旧缓存——评分不写死，站点更新后 App 自动跟上。
///
/// 实测（2026-10-20）站点虽停用了搜索 JS，但服务端 `/search?q=<姓名>` 仍返回
/// HTML 结果块（含 `/t/<id>/` 与姓名），详情页 `<title>毕惟红老师 9.39分 422人打分`。
/// 因此实时链路 = 姓名搜索（拿 ID）→ 详情页（拿分数/人数）：
///  * 不依赖任何预建索引，任何站点收录的教师都能实时匹配；
///  * 搜索结果必须姓名精确吻合才采用（宁缺勿猜，杜绝张冠李戴）。
///
/// 红线：只读；不登录、不提交任何内容；全局最小请求间隔 250ms；同名并发去重；
/// 超时 8s；搜索无果/站点不可达时一切降级为「暂无」，绝不阻塞选课页。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'credential_store.dart';
import 'teacher_rating.dart';

/// 详情页标题解析：`<title>毕惟红老师 9.39分 422人打分 - 查老师</title>`。
/// 纯函数（顶层可见，test/teacher_rating_live_test.dart 直连断言）。
TeacherRating? parseTeacherRatingHtml(String html) {
  final m = RegExp(
          r'<title>\s*(.+?)老师\s*([0-9]+(?:\.[0-9]+)?)分\s*([0-9]+)人打分')
      .firstMatch(html);
  if (m == null) return null;
  final name = m.group(1)!.trim();
  final avg = double.tryParse(m.group(2)!);
  final count = int.tryParse(m.group(3)!) ?? 0;
  if (name.isEmpty || avg == null || avg < 0 || avg > 10) return null;
  return TeacherRating(teacher: name, avg: avg, count: count);
}

/// 搜索结果页解析：从 `/search?q=` 的 HTML 中找**姓名精确吻合**的教师 ID。
/// 结果块形态：`<div class="item" onclick="window.location='/t/6310/'">…<h3>刘海峰</h3>`。
/// 纯函数，供测试直连。
String? parseTeacherSearchId(String html, String wantedName) {
  final want = normalizeTeacherName(wantedName);
  if (want.isEmpty) return null;
  final re = RegExp(
      r"""<div\s+class="item"\s+onclick="window\.location='/t/(\d+)/'">\s*<div\s+class="left">\s*<h3>([^<]+)</h3>""",
      caseSensitive: false);
  for (final m in re.allMatches(html)) {
    final name = m.group(2)!.trim();
    if (normalizeTeacherName(name) == want) return m.group(1)!;
  }
  return null;
}

class _CachedRating {
  final TeacherRating rating;
  final DateTime fetchedAt;
  final String? teacherId;
  const _CachedRating(this.rating, this.fetchedAt, this.teacherId);
}

class TeacherRatingLive {
  TeacherRatingLive(this._store,
      {Duration ttl = const Duration(hours: 24),
      Duration timeout = const Duration(seconds: 8),
      Duration minInterval = const Duration(milliseconds: 250)})
      : _ttl = ttl,
        _timeout = timeout,
        _minInterval = minInterval;

  static const String baseUrl = 'https://dahua309.uk';

  final CredentialStore _store;
  final Duration _ttl;
  final Duration _timeout;
  final Duration _minInterval;

  final Map<String, TeacherRating?> _mem = {};
  final Map<String, Future<TeacherRating?>> _inflight = {};
  DateTime _lastRequestAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 查一位教师的**实时**评分：内存 → 磁盘缓存（≤24h）→ 站点搜索 → 详情页。
  /// 任何失败返回 null（调用方保持种子表/暂无），绝不抛。
  Future<TeacherRating?> lookup(String teacherName) {
    final key = normalizeTeacherName(teacherName);
    if (key.isEmpty) return Future.value(null);
    if (_mem.containsKey(key)) return Future.value(_mem[key]);
    return _inflight[key] ??=
        _resolve(key, teacherName.trim()).whenComplete(() => _inflight.remove(key));
  }

  Future<TeacherRating?> _resolve(String key, String displayName) async {
    final cached = await _readCache(key);
    if (cached != null && DateTime.now().difference(cached.fetchedAt) < _ttl) {
      _mem[key] = cached.rating;
      return cached.rating;
    }
    // 24h 内查过 ID 就不再搜索（省一次请求），否则先搜姓名拿 ID。
    var id = cached?.teacherId;
    if (id == null) {
      id = await _searchId(displayName);
      if (id == null) {
        _mem[key] = cached?.rating;
        return cached?.rating;
      }
    }
    final fresh = await _fetch(id);
    if (fresh != null) {
      _mem[key] = fresh;
      await _writeCache(key, fresh, id);
      return fresh;
    }
    _mem[key] = cached?.rating;
    return cached?.rating;
  }

  Future<String?> _searchId(String name) async {
    final body = await _get('/search?q=${Uri.encodeComponent(name)}');
    if (body == null) return null;
    return parseTeacherSearchId(body, name);
  }

  Future<TeacherRating?> _fetch(String id) async {
    final body = await _get('/t/$id/');
    if (body == null) return null;
    return parseTeacherRatingHtml(body);
  }

  Future<String?> _get(String path) async {
    final since = DateTime.now().difference(_lastRequestAt);
    if (since < _minInterval) {
      await Future<void>.delayed(_minInterval - since);
    }
    _lastRequestAt = DateTime.now();
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client
          .getUrl(Uri.parse('$baseUrl$path'))
          .timeout(_timeout);
      req.headers.set(HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (compatible; ClassArk/0.13.8; +https://github.com/Kepler16f/zju-kezhou)');
      final res = await req.close().timeout(_timeout);
      if (res.statusCode != 200) return null;
      return await res.transform(utf8.decoder).join().timeout(_timeout);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  String _cacheKey(String normalized) =>
      'rating_live_${Uri.encodeComponent(normalized)}';

  Future<_CachedRating?> _readCache(String key) async {
    final src = await _store.readCache(_cacheKey(key));
    if (src == null) return null;
    try {
      final obj = jsonDecode(src);
      if (obj is! Map) return null;
      final avg = (obj['avg'] as num?)?.toDouble();
      final count = (obj['count'] as num?)?.toInt() ?? 0;
      final at = (obj['fetched_at'] as num?)?.toInt() ?? 0;
      final name = '${obj['name'] ?? key}';
      final id = obj['id'] is String ? obj['id'] as String : null;
      if (avg == null || avg < 0 || avg > 10 || at <= 0) return null;
      return _CachedRating(
        TeacherRating(teacher: name, avg: avg, count: count),
        DateTime.fromMillisecondsSinceEpoch(at),
        id,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(String key, TeacherRating r, String id) async {
    await _store.saveCache(
        _cacheKey(key),
        jsonEncode({
          'name': r.teacher,
          'avg': r.avg,
          'count': r.count,
          'id': id,
          'fetched_at': DateTime.now().millisecondsSinceEpoch,
          'source': r.source,
        }));
  }
}
