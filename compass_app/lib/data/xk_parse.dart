/// data/xk_parse.dart — 选课(xsxk)页面与接口的纯解析（零 IO、不抛异常）。
///
/// 三条纪律（评审结论，勿回退）：
/// - 首页 onclick 只锚定 queryCourse( 与前两个字符串参数，参数个数不假设（公开实例有 4/5 参两种形态）；
/// - 解析失败一律空结果 + issues 留痕，绝不静默、绝不猜；
/// - 上课时间解析失败返回 []（由调用方决定降级），含单双周时逐周展开为 parity-aware 时隙，
///   对齐 Timeline.slotsConflict 消费 schema（day/start/end/week_start/week_end，全部 int）。
library;

import 'dart:convert';

import 'xk_models.dart';

// ───────────────────────── 上课时间文本解析 ─────────────────────────

class SksjParseResult {
  final List<Map<String, dynamic>> slots;
  final List<String> issues;
  const SksjParseResult({required this.slots, this.issues = const []});
}

/// 解析正方上课时间文本 → Timeline 消费的时隙列表。
/// 支持形态（对抗评审后加固，边界见 test/xk_parse_test.dart）：
/// - 星期：星期一/周X/礼拜X/周天；节次：第3-4节/第3,4节/第3、4节/第3~4节/第3—4节/第3–4节/第9节；
/// - 周次：{1-16周}/(1-16周)/第1周至第16周/{1-8,10-16周}/{1-16}纯数字/单双周（逐周展开）；
/// - 同段多节次各自成槽；多天共享节次（"周一、周三第1-2节"）合并处理；
/// - 全角归一、破折号族归一；解析失败返回 [] + issues（绝不静默、绝不猜）。
SksjParseResult parseSksj(String text) {
  final issues = <String>[];
  final out = <Map<String, dynamic>>[];
  var t = _half(text);
  if (t.trim().isEmpty) return const SksjParseResult(slots: []);
  // 破折号族归一为 "-"（波浪/全角波浪/en dash/U+2212 减号/长横），
  // 再把「第a周至第b周」归一成「第a-b周」。U+2212 在源码里用 \u 转义写（GB2312 纪律，L4）
  t = t.replaceAll(RegExp('[~～–\u2212—]'), '-');
  t = t.replaceAllMapped(
      RegExp(r'第?\s*(\d{1,2})\s*周\s*(?:至|-)\s*第?\s*(\d{1,2})\s*周'),
      (m) => '第${m[1]}-${m[2]}周');

  // 切段：以星期标记为界；**首段从 0 开始**（"单周星期一…"的前导标注归属首段），
  // 段间文本归前段（"…{1-16周}紫金港"的场地不会落入下一段）
  final dayRe = RegExp(r'(?:星期|礼拜|周)\s*([一二三四五六日天]|[1-7])');
  final matches = dayRe.allMatches(t).toList();
  if (matches.isEmpty) {
    return SksjParseResult(slots: const [], issues: ['未识别到星期信息：${_short(text)}']);
  }
  final segs = <String>[];
  for (var i = 0; i < matches.length; i++) {
    final start = i == 0 ? 0 : matches[i].start;
    final end = i + 1 < matches.length ? matches[i + 1].start : t.length;
    segs.add(t.substring(start, end));
  }
  // 多天共享节次（"周一、周三第1-2节"）：无节次的段并入下一段；整段尾部残留 → 留痕
  final mergedSegs = <String>[];
  var carry = '';
  for (final s in segs) {
    if (RegExp(r'第\s*\d{1,2}\s*(?:[-至、,]\s*\d{1,2})?\s*节').hasMatch(s)) {
      mergedSegs.add(carry + s);
      carry = '';
    } else {
      carry += s;
    }
  }
  if (carry.isNotEmpty) issues.add('时间片段缺少节次：${_short(carry)}');

  for (final seg in mergedSegs) {
    final slots = _parseSegment(seg, issues);
    if (slots == null) {
      issues.add('时间片段无法解析：${_short(seg)}');
    } else {
      out.addAll(slots);
    }
  }
  if (out.isEmpty) issues.add('上课时间解析失败（原文：${_short(text)}）');
  return SksjParseResult(slots: out, issues: issues);
}

int _parityOf(String s) {
  if (s.contains('单双')) return 0;
  if (s.contains('单')) return 1;
  if (s.contains('双')) return 2;
  return 0;
}

bool _looksLikeWeeks(String c) =>
    c.contains('周') ||
    (RegExp(r'\d').hasMatch(c) &&
        RegExp(r'^[\d\s,，、\-至单双（）()【】]+$').hasMatch(c));

List<Map<String, dynamic>>? _parseSegment(String seg, List<String> issues) {
  final dayMatches =
      RegExp(r'(?:星期|礼拜|周)\s*([一二三四五六日天]|[1-7])').allMatches(seg).toList();
  if (dayMatches.isEmpty) return null;
  final days = <int>[];
  for (final m in dayMatches) {
    final d = _dayOf(m.group(1)!);
    if (d != null && !days.contains(d)) days.add(d);
  }
  if (days.isEmpty) return null;
  // 段内**所有**节次各自成槽（"第1-2节,第3-4节" 不再静默丢第二段）
  final secMatches =
      RegExp(r'第\s*(\d{1,2})\s*(?:[-至、,]\s*(\d{1,2}))?\s*节').allMatches(seg).toList();
  if (secMatches.isEmpty) return null;

  // 周次来源：{…} 组优先（闭括号允许含 ')'，如 "{1-16(单)周}"），其次 (…) 组，再回退整段
  final braceM = RegExp(r'\{([^}]{1,48})\}').firstMatch(seg);
  final parenM = RegExp(r'[\（(]([^\）)]{1,48})[\）)]').firstMatch(seg);
  String? content;
  if (braceM != null && _looksLikeWeeks(braceM.group(1)!)) {
    content = braceM.group(1)!;
  } else if (parenM != null && _looksLikeWeeks(parenM.group(1)!)) {
    content = parenM.group(1)!;
  } else if (braceM != null && RegExp(r'\d').hasMatch(braceM.group(1)!)) {
    content = braceM.group(1)!; // 有数字但不像周次：也取来解析（失败会给误导 issue 提供原文）
  }

  // 奇偶判定顺序：括号内容 → 段首前导（"单周星期一…"）→ 括号后尾注（"…（单周）"）
  var parity = content != null ? _parityOf(content) : 0;
  if ((content == null || parity == 0)) {
    final firstDayStart = dayMatches.first.start;
    if (firstDayStart > 0) {
      final lead = seg.substring(0, firstDayStart);
      final p = _parityOf(lead);
      if (p != 0) parity = p;
    }
  }
  if (parity == 0 && content != null && braceM != null) {
    final tail = seg.substring(braceM.end);
    final p = _parityOf(tail);
    if (p != 0) parity = p;
  }
  if (parity == 0 && content == null) parity = _parityOf(seg);

  final weeksSrc = content ?? seg;
  final ranges = <List<int>>[];
  _collectRanges(weeksSrc, ranges, issues);
  if (ranges.isEmpty) {
    final hadText = content != null || RegExp(r'\d\s*周').hasMatch(seg);
    issues.add(hadText
        ? '周次区间未能解析，按 1-16 周处理：${_short(seg)}'
        : '未标注周次，按 1-16 周处理：${_short(seg)}');
    ranges.add([1, 16]);
  }

  final out = <Map<String, dynamic>>[];
  for (final sm in secMatches) {
    final start = int.parse(sm.group(1)!);
    final end = sm.group(2) != null ? int.parse(sm.group(2)!) : start;
    if (start < 1 || end < start || end > 13) {
      issues.add('节次超出合理范围，已跳过：${_short(seg)}');
      continue;
    }
    for (final day in days) {
      if (parity != 0) {
        // 单双周逐周展开（parity-aware；不压缩成整段，避免与另一奇偶周课程假冲突）
        for (final r in ranges) {
          for (var w = r[0]; w <= r[1]; w++) {
            if (parity == 1 && w.isEven) continue;
            if (parity == 2 && w.isOdd) continue;
            out.add({'day': day, 'start': start, 'end': end, 'week_start': w, 'week_end': w});
          }
        }
      } else {
        for (final r in ranges) {
          out.add({'day': day, 'start': start, 'end': end, 'week_start': r[0], 'week_end': r[1]});
        }
      }
    }
  }
  return out.isEmpty ? null : out;
}

/// 周次区间提取（评审L2 加固）：只接受**紧邻「周」的数字/区间（可逗号串联）**，
/// 裸数字对（"东2-303" 这类教室号）不再参与；整串为纯数字形态时按周次直解；
/// 上限 8 段，截断必留痕。
void _collectRanges(String src, List<List<int>> ranges, List<String> issues) {
  var found = 0;
  void eat(String part) {
    final rm = RegExp(r'^(\d{1,2})(?:\s*-\s*(\d{1,2}))?$').firstMatch(part.trim());
    if (rm == null) return;
    final a = int.parse(rm.group(1)!);
    final b = rm.group(2) != null ? int.parse(rm.group(2)!) : a;
    if (a < 1 || b < a || b > 30) return;
    if (ranges.length >= 8) {
      issues.add('周次区间过多，已截断：${_short(src)}');
      return;
    }
    ranges.add([a, b]);
    found++;
  }

  for (final m in RegExp(r'((?:\d{1,2}(?:\s*-\s*\d{1,2})?\s*[,，、]?\s*)+)\s*周')
      .allMatches(src)) {
    for (final part in m.group(1)!.split(RegExp(r'[,，、]'))) {
      eat(part);
    }
  }
  if (found == 0) {
    // 纯数字形态（"{1-16}" 花括号无「周」字）：整串按周次直解
    final pure = src.replaceAll(RegExp(r'[单双（）()【】\s]'), '');
    if (RegExp(r'^[\d,，、\-]+$').hasMatch(pure) && RegExp(r'\d').hasMatch(pure)) {
      for (final part in pure.split(RegExp(r'[,，、]'))) {
        eat(part);
      }
    }
  }
  if (found == 0) {
    // 兜底：单点「第N周」（多段形式已被上游归一为区间）
    final m = RegExp(r'第?\s*(\d{1,2})\s*周').firstMatch(src);
    if (m != null) {
      final a = int.parse(m.group(1)!);
      if (a >= 1 && a <= 30) ranges.add([a, a]);
    }
  }
}

int? _dayOf(String s) {
  switch (s) {
    case '一':
      return 1;
    case '二':
      return 2;
    case '三':
      return 3;
    case '四':
      return 4;
    case '五':
      return 5;
    case '六':
      return 6;
    case '日':
    case '天':
      return 7;
  }
  final n = int.tryParse(s);
  return (n != null && n >= 1 && n <= 7) ? n : null;
}

// ───────────────────────── 选课首页（轮次/入口发现）─────────────────────────

class XkIndexParseResult {
  final List<XkRound> rounds;
  final String? xkxnm; // 学年（隐藏域，best-effort）
  final String? xkxqm; // 学期（隐藏域，best-effort）
  final String? firstXkkzId;
  final List<String> issues;
  final int queryCourseHits; // onclick 原始命中次数（区分「无入口」与「解析失败」）
  final Map<String, String> hiddenFields; // 首页全部 input[name]=value（查询参数以首页为准的载体）
  final bool fromCache; // 本次结果是否来自本地缓存（由客户端置位）
  final int fetchedAtMillis; // 拉取时刻（缓存回读时保留原值；0=未知）
  const XkIndexParseResult({
    required this.rounds,
    this.xkxnm,
    this.xkxqm,
    this.firstXkkzId,
    this.issues = const [],
    this.queryCourseHits = 0,
    this.hiddenFields = const {},
    this.fromCache = false,
    this.fetchedAtMillis = 0,
  });
}

/// 解析选课首页 HTML：泛化抓取 queryCourse 前两个字符串参数（评审A1），
/// 默认入口按 onclick 首条（公开证据 onclick 优先于 firstXkkzId）；
/// 同时收集全部 input 键值对（正方查询参数以首页表单为准，别校证据显示参数集不完整
/// 会拿到空数据，评审A2）。
XkIndexParseResult parseXkIndexHtml(String html) {
  final issues = <String>[];
  final rounds = <XkRound>[];
  final seen = <String>{};
  var hits = 0;
  // 先解码常见 HTML 实体引号：部分实例把 onclick 里的引号写成 &#39;/&quot;，
  // 不解码会整体漏配（且误报"页面结构变化"，评审L2）。
  html = html
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&#34;', '"');
  final re = RegExp(
      r"""queryCourse\s*\(\s*this\s*,\s*['"]([^'"]*)['"]\s*,\s*['"]([^'"]*)['"]""",
      caseSensitive: false);
  for (final m in re.allMatches(html)) {
    hits++;
    final kklxdm = _unescape(m.group(1) ?? '');
    final xkkz = _unescape(m.group(2) ?? '');
    // 去重键带类别：同 xkkz_id 跨类别复用是合法形态，只按 id 去重会静默丢入口（评审L2）
    if (xkkz.isEmpty || !seen.add('$xkkz\u0000$kklxdm')) continue;
    final label = _labelAfter(html, m.end);
    rounds.add(XkRound(
      xkkzId: xkkz,
      kklxdm: kklxdm,
      xklc: null, // 参数位无证据，不臆取（评审A1）
      label: label.isEmpty ? '入口${rounds.length + 1}' : label,
    ));
  }
  final hidden = <String, String>{};
  for (final m in RegExp(r'<input\b[^>]*>', caseSensitive: false).allMatches(html)) {
    if (hidden.length >= 60) break;
    final tag = m.group(0)!;
    final name = _tagAttr(tag, 'name') ?? _tagAttr(tag, 'id');
    if (name == null || name.isEmpty) continue;
    hidden.putIfAbsent(name, () => _tagAttr(tag, 'value') ?? '');
  }
  String? pick(String key) {
    // 空串按"未知"处理：空值绝不当作有效默认入口/学期（评审L2：空 firstXkkzId 幻影入口）
    final v = hidden[key];
    if (v != null && v.isNotEmpty) return v;
    return _hiddenValue(html, key);
  }

  final firstXkkzId = pick('firstXkkzId');
  if (rounds.isEmpty && firstXkkzId != null) {
    rounds.add(XkRound(xkkzId: firstXkkzId, label: '默认入口'));
    issues.add('未找到选课入口菜单，仅发现默认入口（firstXkkzId），页面结构可能变化。');
  } else if (rounds.isEmpty) {
    issues.add('未发现选课入口（queryCourse 命中 0 次）：可能未开放选课、页面结构变化或需要登录。');
  }
  return XkIndexParseResult(
    rounds: rounds,
    xkxnm: pick('xkxnm'),
    xkxqm: pick('xkxqm'),
    firstXkkzId: firstXkkzId,
    issues: issues,
    queryCourseHits: hits,
    hiddenFields: hidden,
  );
}

/// 标签属性提取（评审L2 加固）：属性名带词边界（不命中 data-value/data-name），
/// 并按引号类型配对闭合（值里含异种引号不再被截断）。
String? _tagAttr(String tag, String attr) {
  for (final q in const ['"', "'"]) {
    final m = RegExp(
            '(?:^|\\s)${RegExp.escape(attr)}\\s*=\\s*$q([^$q]*)$q',
            caseSensitive: false)
        .firstMatch(tag);
    final v = m?.group(1);
    if (v != null) return _unescape(v);
  }
  return null;
}

String _labelAfter(String html, int from) {
  final end = (from + 240).clamp(0, html.length);
  if (from >= end) return '';
  final tail = html.substring(from, end);
  final gt = tail.indexOf('>'); // onclick 所在标签的开标签结束位
  if (gt < 0) return '';
  // 标签内容截止到该元素的闭合标签（</a / </li），绝不越界抓取后续入口的文本
  final content = tail.substring(gt + 1);
  var stop = content.length;
  for (final closer in const ['</a', '</li']) {
    final i = content.indexOf(closer);
    if (i >= 0 && i < stop) stop = i;
  }
  final scope = content.substring(0, stop);
  // 元素内可能嵌套 <span> 图标/角标：取**最长**的像名字段（含 ≥2 个连续中英文字符），
  // 纯数字/符号/单字跳过（评审L2：图标字"图标"会赢过"取第一个"，长度优先让"第一轮"胜出）
  String best = '';
  for (final m in RegExp(r'(?:^|>)\s*([^<>{}]{1,60}?)\s*(?=<|$)').allMatches(scope)) {
    final label = _unescape(m.group(1)!).trim();
    if (label.contains('queryCourse') || label.contains('javascript')) continue;
    // 汉字区间用 \u 转义（裸字上界字符超出 GB2312；源码字符纪律见 docs §10）
    if (!RegExp('[\u4e00-\u9fffA-Za-z]{2}').hasMatch(label)) continue;
    if (label.length > best.length) best = label;
  }
  return best;
}

String? _hiddenValue(String html, String name) {
  final n = RegExp.escape(name);
  final p1 = RegExp('(?:name|id)\\s*=\\s*["\']$n["\'][^>]{0,240}?value\\s*=\\s*["\']([^"\']*)["\']',
      caseSensitive: false);
  final p2 = RegExp('value\\s*=\\s*["\']([^"\']*)["\'][^>]{0,240}?(?:name|id)\\s*=\\s*["\']$n["\']',
      caseSensitive: false);
  final m = p1.firstMatch(html) ?? p2.firstMatch(html);
  final v = m?.group(1);
  return (v == null || v.isEmpty) ? null : v;
}

// ───────────────────────── 课程列表（PartDisplay 响应）─────────────────────────

class XkListParseResult {
  final List<XkCourse> courses;
  final String state; // 'data' | 'empty' | 'unavailable'（评审A6 三态）
  final List<String> issues;
  final int dropped; // 因缺课程名等被丢弃的行数
  final bool fromCache; // 本次结果是否来自本地缓存（由客户端置位）
  final int fetchedAtMillis; // 拉取时刻（缓存回读时保留原值；0=未知）
  const XkListParseResult({
    required this.courses,
    required this.state,
    this.issues = const [],
    this.dropped = 0,
    this.fromCache = false,
    this.fetchedAtMillis = 0,
  });
}

/// 解析课程列表响应。三态语义：data=有数据；empty=接口明确返回空列表；
/// unavailable=无信封/非 JSON/usable:false/验证码（绝不当作「无课」，不落缓存）。
XkListParseResult parseXkCourseList(String body,
    {required String xkkzId, String? xklc, String label = ''}) {
  final text = body.trim();
  if (text.isEmpty) {
    return const XkListParseResult(courses: [], state: 'unavailable', issues: ['响应为空']);
  }
  // 风控判定只认特征字段；"验证码"三个字出现在课程名/备注里绝不误杀（评审L2）
  if (text.contains('captcha_error')) {
    return const XkListParseResult(
        courses: [], state: 'unavailable', issues: ['响应含风控提示（captcha_error），请稍后再试']);
  }
  Object? decoded;
  try {
    decoded = json.decode(text);
  } catch (_) {
    // 非 JSON（HTML 页）：此处才允许按关键词识别风控/登录页
    final isCaptcha = text.contains('验证码') || text.contains('captcha');
    final isLogin = text.contains('login_slogin') ||
        text.contains('统一身份认证') ||
        text.contains('<html');
    return XkListParseResult(
      courses: const [],
      state: 'unavailable',
      issues: [
        isCaptcha
            ? '返回风控页（可能需要验证码），请稍后再试'
            : (isLogin ? '返回登录页/HTML（会话失效或接口变更）' : '非 JSON 响应')
      ],
    );
  }
  List? rows;
  if (decoded is Map) {
    if (decoded['usable'] == false) {
      return const XkListParseResult(
          courses: [], state: 'unavailable', issues: ['接口返回 usable=false（权限或接口未开放）']);
    }
    final candidate = decoded['tmpList'] ?? decoded['items'] ?? decoded['rows'];
    if (candidate == null) {
      return const XkListParseResult(
          courses: [], state: 'unavailable', issues: ['未找到课程列表字段（tmpList/items），按状态未知处理']);
    }
    if (candidate is! List) {
      return const XkListParseResult(
          courses: [], state: 'unavailable', issues: ['课程列表字段类型异常']);
    }
    rows = candidate;
  } else if (decoded is List) {
    rows = decoded;
  } else {
    return const XkListParseResult(courses: [], state: 'unavailable', issues: ['响应结构未知']);
  }
  if (rows.isEmpty) {
    return const XkListParseResult(courses: [], state: 'empty');
  }

  final courses = <XkCourse>[];
  var dropped = 0;
  final slotIssues = <String>{};
  for (final r in rows) {
    if (r is! Map) {
      dropped++;
      continue;
    }
    final m = <String, dynamic>{};
    r.forEach((k, v) => m[k.toString()] = v);
    final kcmc = _pick(m, const ['kcmc', 'courseName', 'kc_name']).trim();
    if (kcmc.isEmpty) {
      dropped++;
      continue;
    }
    final sksj = _pick(m, const ['sksj', 'skTime', 'time']).trim();
    var slots = <Map<String, dynamic>>[];
    if (sksj.isNotEmpty) {
      final sp = parseSksj(sksj);
      slots = sp.slots;
      for (final i in sp.issues.take(2)) {
        if (slotIssues.length < 8) slotIssues.add(i);
      }
    }
    courses.add(XkCourse(
      kcmc: kcmc,
      kch: _pick(m, const ['kch', 'xk_kch', 'kcdm', 'courseCode']).trim(),
      kchId: _pick(m, const ['kch_id', 'kchId']).trim(),
      xf: _num(_pick(m, const ['xf', 'credit', 'kcxf'])),
      jxbId: _pick(m, const ['jxb_id', 'jxbId']).trim(),
      jxbmc: _pick(m, const ['jxbmc', 'jxb']).trim(),
      teacher: _pick(m, const ['jsxx', 'jsxm', 'teacher', 'skjs']).trim(),
      sksj: sksj,
      cdmc: _pick(m, const ['cdmc', 'place']).trim(),
      xqjmc: _pick(m, const ['xqjmc', 'campus']).trim(),
      tags: _collectTags(m),
      cap: _int(_pick(m, const ['jxbrl', 'capacity'])),
      selected: _int(_pick(m, const ['yxzrs', 'selected_number', 'yxrs'])),
      slots: slots,
      xkkzId: xkkzId,
      xklc: xklc,
      raw: m,
    ));
  }
  final issues = <String>[];
  if (dropped > 0) issues.add('有 $dropped 行缺少课程名被跳过');
  if (courses.isEmpty) {
    return XkListParseResult(
      courses: const [],
      state: 'unavailable',
      issues: [...issues, '全部行字段缺失（可能字段名变更）'],
      dropped: dropped,
    );
  }
  issues.addAll(slotIssues);
  return XkListParseResult(courses: courses, state: 'data', issues: issues, dropped: dropped);
}

// ───────────────────────── 当前课表（xskbcx kbList）→ 时隙 ─────────────────────────

class TimetableParseResult {
  final List<Map<String, dynamic>> slots;
  final List<String> courses; // 课程名（去重，供 AI 上下文与展示）
  final List<String> issues;
  final bool fromCache;
  final int fetchedAtMillis;
  const TimetableParseResult({
    required this.slots,
    this.courses = const [],
    this.issues = const [],
    this.fromCache = false,
    this.fetchedAtMillis = 0,
  });
}

/// 把课表接口的 kbList 行转换成时隙（复用 parseSksj，避免第二套周次/节次语义）。
/// 行字段（多键容错）：kcmc/xqj(星期)/jcs 或 jc(节次，如 "3-4")/zcd(周次，如 "1-16")。
TimetableParseResult parseXskbListToSlots(Object? kbList) {
  final slots = <Map<String, dynamic>>[];
  final courses = <String>{};
  final issues = <String>[];
  if (kbList is! List) {
    return const TimetableParseResult(slots: [], issues: ['课表数据不是列表']);
  }
  for (final r in kbList) {
    if (r is! Map) continue;
    final m = <String, dynamic>{};
    r.forEach((k, v) => m[k.toString()] = v);
    final kcmc = _pick(m, const ['kcmc', 'courseName']).trim();
    final xqj = _pick(m, const ['xqj', 'xingqi', 'weekday']).trim();
    final jcs = _pick(m, const ['jcs', 'jc', 'jcor']).trim();
    final zcd = _pick(m, const ['zcd', 'zcmc', 'weeks']).trim();
    if (kcmc.isEmpty || xqj.isEmpty || jcs.isEmpty) continue;
    final zcdClean = zcd.replaceAll('周', '').trim();
    final composed =
        '星期$xqj第$jcs节${zcdClean.isEmpty ? '' : '{$zcdClean周}'}';
    final sp = parseSksj(composed);
    for (final i in sp.issues) {
      // 缺周次等解析留痕必须传递（曾漏传，见本文件回归用例）
      if (issues.length < 8) issues.add(i);
    }
    if (sp.slots.isEmpty) continue;
    slots.addAll(sp.slots);
    courses.add(kcmc);
  }
  return TimetableParseResult(slots: slots, courses: courses.toList(), issues: issues);
}

// ───────────────────────── 工具 ─────────────────────────

String _pick(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v == null || v is bool) continue; // bool 不是有效字段文本（jsxx:false 不得变 'false'）
    if (v is List) {
      final parts =
          v.map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty && s != 'null');
      if (parts.isNotEmpty) return parts.join('，');
      continue;
    }
    if (v is Map) {
      // 嵌套对象（如 jsxx:{jsxm:张三}）只递归取常见姓名键，绝不 toString 拼贴（评审L2）
      final nested = _pick(
          v.map((k2, v2) => MapEntry('$k2', v2)),
          const ['jsxm', 'xm', 'name', 'mc', 'jsxx']);
      if (nested.isNotEmpty) return nested;
      continue;
    }
    final s = v.toString();
    if (s.isNotEmpty && s != 'null') return s;
  }
  return '';
}

double? _num(String s) {
  if (s.isEmpty) return null;
  final d = double.tryParse(s);
  return d;
}

/// 教务列表行的「课程标签/性质」多键收集（诉求 #5：标签→培养方案课程类别）。
/// 候选键为 zdbk 各接口实测/文档中出现过的类别字段（kcxz 课程性质 / kclb 课程类别 /
/// kcbq 课程标签 / kkxs 开课形式…）；值按常见分隔符拆成多个标签，去重去空。
/// 纯数字（如代码 03）与超长串（>16 字符，多为说明文本）不作为标签。
List<String> _collectTags(Map<String, dynamic> m) {
  const tagKeys = [
    'kcxzmc', 'kcxz', 'kclbmc', 'kclb', 'kcbq', 'bq', 'courseType', 'category',
  ];
  final out = <String>[];
  for (final k in tagKeys) {
    final v = m[k];
    if (v == null || v is bool || v is Map) continue;
    final parts = v is List
        ? v.map((e) => e?.toString() ?? '')
        : v.toString().split(RegExp(r'[,，、;；/|]'));
    for (final p in parts) {
      final s = p.trim();
      if (s.isEmpty || s == 'null') continue;
      if (s.length > 16) continue;
      if (RegExp(r'^[\d.\-]+$').hasMatch(s)) continue;
      if (!out.contains(s)) out.add(s);
    }
  }
  return out;
}

int? _int(String s) {
  if (s.isEmpty) return null;
  final i = int.tryParse(s);
  if (i != null) return i;
  final d = double.tryParse(s);
  return d?.toInt();
}

String _half(String s) {
  final buf = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0xFF01 && r <= 0xFF5E) {
      buf.writeCharCode(r - 0xFEE0);
    } else if (r == 0x3000) {
      buf.write(' ');
    } else {
      buf.writeCharCode(r);
    }
  }
  return buf.toString();
}

String _short(String s) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length <= 40 ? t : '${t.substring(0, 40)}…';
}

String _unescape(String s) => s
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'");
