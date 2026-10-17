/// data/zju_parse_ext.dart — 教务页面解析扩展：专业识别、培养方案获取、课堂分看板。
/// 端点与解析模式对齐 Helechron 实战验证（学业生涯页 N105515 / 培养方案列表 N153020 /
/// 打印页 dyPyfaxs / 实践分主源=素质拓展平台 sztz.zju.edu.cn/dekt 的 getSqjl+getMyInfo、
/// 遗留兜底=教务网 N108001 第二三四课堂）。课程表 HTML→PlanFile 为 best-effort，
/// 正方页面版式多样，解析结果附带"数据质量"报告，UI 如实展示，绝不静默出错。
library;

import 'dart:convert';

String _clean(String s) =>
    s.replaceAll(RegExp(r'[\s\u3000]+'), '').replaceAll('&nbsp;', '');

/// Bootstrap 静态表单/表格键值对提取（对齐 Helechron parseHtmlFormFields 四模式）。
/// 正方页面版式混杂：学业生涯页(N105515)用 <label>…</label>…<p class="form-control-static">，
/// 部分信息页用 <th>…</th>…<td>，仅靠 <tr> 相邻单元格会整体抓空——这是"抓不到专业"根因之一。
Map<String, String> _parseBootstrapFormFields(String html) {
  final result = <String, String>{};
  void grab(RegExp re, int ki, int vi) {
    for (final m in re.allMatches(html)) {
      final k = (m.group(ki) ?? '').trim();
      final v = (m.group(vi) ?? '').trim().replaceAll('&nbsp;', '');
      if (k.isNotEmpty && v.isNotEmpty && k.length <= 24 &&
          !result.containsKey(k)) {
        result[k] = v;
      }
    }
  }

  // 1. <label>Key</label> … <p class="…form-control-static…">Value</p>
  grab(
      RegExp(
          r'<label[^>]*>\s*([^<:：\s]+?)\s*[:：]?\s*</label>[\s\S]*?<p[^>]*class=["\x27][^"\x27]*form-control-static[^"\x27]*["\x27][^>]*>\s*([^<]+?)\s*</p>',
          caseSensitive: false),
      1,
      2);
  // 2. <label>Key</label> … <p>Value</p>（宽松兜底）
  grab(
      RegExp(
          r'<label[^>]*>\s*([^<:：\s]+?)\s*[:：]?\s*</label>[\s\S]*?<p[^>]*>\s*([^<]+?)\s*</p>',
          caseSensitive: false),
      1,
      2);
  // 3. <th>Key</th> … <td>Value</td>（跨行相邻）
  grab(
      RegExp(
          r'<th[^>]*>\s*([^<:：\s]+?)\s*[:：]?\s*</th>[\s\S]*?<td[^>]*>\s*([^<]+?)\s*</td>',
          caseSensitive: false),
      1,
      2);
  return result;
}

/// 从 HTML 提取键值对：Bootstrap label/p + th/td + 表格行相邻单元格 + input[name][value]。
Map<String, String> parseHtmlKeyValuePairs(String html) {
  final out = _parseBootstrapFormFields(html);
  final tagRe = RegExp(r'<[^>]+>');
  final rowRe = RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true, caseSensitive: false);
  final cellRe = RegExp(r'<t[hd][^>]*>(.*?)</t[hd]>', dotAll: true, caseSensitive: false);
  for (final row in rowRe.allMatches(html)) {
    final cells = cellRe
        .allMatches(row.group(1) ?? '')
        .map((m) => (m.group(1) ?? '').replaceAll(tagRe, '').replaceAll('&nbsp;', ' ').trim())
        .where((s) => s.isNotEmpty)
        .toList();
    for (var i = 0; i + 1 < cells.length; i++) {
      final k = cells[i], v = cells[i + 1];
      if (k.length <= 20 && v.isNotEmpty) out.putIfAbsent(k, () => v);
    }
  }
  final inputRe = RegExp(
      r'''<input[^>]+(?:name|id)=["']([^"']+)["'][^>]+value=["']([^"']*)["']''',
      caseSensitive: false);
  for (final m in inputRe.allMatches(html)) {
    out.putIfAbsent(m.group(1)!, () => m.group(2) ?? '');
  }
  return out;
}

// 实测课舟用户（正方新实例）课表接口把学籍平铺顶层：zy=专业 xy=学院 xh=学号 xm=姓名。
const _majorKeys = ['专业名称', '专业', '主修专业', '专业（类）', '专业(类)', '大类名称',
  '大类', '专业方向', 'zyfxmc', 'evalMajor', 'zszymc', 'zymc', 'ZYMC', 'zy'];

String? majorFromKeyValuePairs(Map<String, String> pairs) {
  for (final key in _majorKeys) {
    final v = pairs[key]?.trim();
    if (v == null || v.isEmpty || v == '未知' || v == '无') continue;
    if (v.contains('&nbsp;') || v.endsWith('学院') || v.endsWith('学园') ||
        v.endsWith('学部') || v.endsWith('系')) {
      continue;
    }
    return v;
  }
  final cls = pairs['班级'] ?? pairs['班级名称'] ?? pairs['bjmc'] ??
      pairs['BJMC'] ?? pairs['className'];
  return (cls != null && cls.isNotEmpty) ? majorFromClassName(cls) : null;
}

String? majorFromClassName(String className) {
  var s = className.trim().replaceAll('&nbsp;', '');
  if (s.isEmpty || s == '未知' || s == '无') return null;
  // 去校区/学园括号标注，如 (丹青)/(云峰)/(蓝田)/(竺院)
  s = s.replaceAll(RegExp(r'[\(（](?:丹青|云峰|蓝田|竺院)[\)）]'), '').trim();
  s = s.replaceAll('（', '(').replaceAll('）', ')');
  s = s.replaceFirst(RegExp(r'^\d{2,4}级'), '');
  s = s.replaceFirst(RegExp(r'\d+班?$'), '').trim(); // 末尾班号："软工2201班"→"软工"
  if (s.endsWith('班') && !s.contains('试验班')) {
    s = s.substring(0, s.length - 1).trim(); // 非试验班的尾"班"
  }
  if (s.length < 2) return null;
  return normalizeMajorName(s);
}

const _abbrev = {
  '计科': '计算机科学与技术', '计算机': '计算机科学与技术',
  '软工': '软件工程', '软件': '软件工程', '信工': '信息工程', '信电': '信息工程',
  '光电': '光电信息科学与工程', '微电': '微电子科学与工程',
  '自动化': '自动化', '机械': '机械工程', '电气': '电气工程及其自动化',
  // 大类/试验班简称（ZJU 新生多以试验班入学，班级/专业字段常填简称）
  '工信': '工科试验班(信息)', '工信大类': '工科试验班(信息)',
  '信息大类': '工科试验班(信息)', '工科试验班(工信)': '工科试验班(信息)',
  '工科试验班(信息)': '工科试验班(信息)', '工科': '工科试验班',
  '社科': '社会科学试验班', '人文': '人文科学试验班', '理试': '理科试验班',
};

String normalizeMajorName(String name) {
  var s = name.trim().replaceAll('（', '(').replaceAll('）', ')');
  s = s.replaceFirst(RegExp(r'^\d{2,4}级'), '').trim(); // 头部年级前缀
  s = s.replaceFirst(RegExp(r'\d+班?$'), '').trim(); // 尾部班号
  if (s.endsWith('班') && !s.contains('试验班')) {
    s = s.substring(0, s.length - 1).trim();
  }
  return _abbrev[s] ?? s;
}

/// 专业名 → 内置方案 key。内置 key 是英文 id，需带中文名对照表；
/// 匹配规则：中文名相等或互相包含（归一化后）。
String? matchPlanKey(String majorName, List<String> availableKeys) {
  const keyNames = {
    'computer_science': '计算机科学与技术',
    'software_engineering': '软件工程',
  };
  final a = _clean(normalizeMajorName(majorName));
  if (a.isEmpty) return null;
  for (final k in availableKeys) {
    final b = _clean(keyNames[k] ?? normalizeMajorName(k));
    if (a == b || a.contains(b) || b.contains(a)) return k;
  }
  return null;
}

/// 括号变体列表（教务系统中英文括号不一致时兜底查询用）。
List<String> majorNameVariants(String major) {
  final v = <String>{major};
  if (major.contains('(')) v.add(major.replaceAll('(', '（').replaceAll(')', '）'));
  if (major.contains('（')) v.add(major.replaceAll('（', '(').replaceAll('）', ')'));
  return v.toList();
}

/// 方案候选评分（对齐 Helechron：专业名完全=100、包含=80、方案名包含=70、
/// 去"试验班/大类/班"核心名包含=50，否则不参选；年级完美+60，往届按差距+30-diff*5，
/// 未来年级-20）。低于 0 分丢弃。
double planScore(Map<String, dynamic> item, {String? targetMajor, String? targetGrade}) {
  String norm(String s) => s.trim().replaceAll('（', '(').replaceAll('）', ')').toLowerCase();
  final zymc = norm((item['zymc'] ?? item['ZYMC'] ?? item['专业名称'] ?? '').toString());
  final pyfamc = norm((item['pyfamc'] ?? item['方案名称'] ?? '').toString());
  final itemGrade = (item['synj'] ?? item['njdm_id'] ?? item['nj'] ?? '').toString();
  if (targetMajor == null || targetMajor.isEmpty) {
    // 无专业约束：仅按年级给分
    var s = 10.0;
    if (targetGrade != null && targetGrade.isNotEmpty) {
      if (itemGrade == targetGrade || pyfamc.contains(targetGrade)) {
        s += 60;
      } else {
        final t = int.tryParse(targetGrade), i = int.tryParse(itemGrade);
        if (t != null && i != null) {
          s += i < t ? (30 - (t - i) * 5).clamp(0, 30).toDouble() : -20;
        }
      }
    }
    return s;
  }
  final clean = norm(targetMajor);
  final core = clean
      .replaceAll('试验班', '').replaceAll('大类', '').replaceAll('班', '')
      .replaceAll('(', '').replaceAll(')', '').trim();
  double score;
  if (zymc.isEmpty) {
    score = 0;
  } else if (zymc == clean) {
    score = 100;
  } else if (zymc.contains(clean) || clean.contains(zymc)) {
    score = 80;
  } else if (pyfamc.contains(clean)) {
    score = 70;
  } else if (core.isNotEmpty && (zymc.contains(core) || pyfamc.contains(core))) {
    score = 50;
  } else {
    return -1; // 完全无关，绝不参选
  }
  if (targetGrade != null && targetGrade.isNotEmpty) {
    if (itemGrade == targetGrade || pyfamc.contains(targetGrade)) {
      score += 60;
    } else {
      final t = int.tryParse(targetGrade), i = int.tryParse(itemGrade);
      if (t != null && i != null) {
        score += i < t ? (30 - (t - i) * 5).clamp(0, 30).toDouble() : -20;
      }
    }
  }
  return score;
}

/// 培养方案列表 → 评分最高一条；无正分匹配返回 null（绝不回退到 first）。
Map<String, dynamic>? pickBestPlan(List<Map<String, dynamic>> items,
    {String? majorName, String? grade}) {
  Map<String, dynamic>? best;
  double bestScore = 0;
  for (final it in items) {
    final id = (it['pyfaxx_id'] ?? it['pyfa_id'] ?? it['jxjhh'] ?? it['id'] ?? '').toString();
    if (id.isEmpty) continue;
    final s = planScore(it, targetMajor: majorName, targetGrade: grade);
    if (s > bestScore) {
      bestScore = s;
      best = it;
    }
  }
  return best;
}

/// 打印页 HTML → PlanFile（best-effort：总学分声明 + 模块声明 + 课程表行）。
Map<String, dynamic> parsePlanPrintHtml(String html,
    {required String pyfaId, String majorName = '', String grade = ''}) {
  final text = _htmlToText(html);
  double? totalCredits;
  for (final re in [
    RegExp(r'(?:最低毕业学分|毕业要求最低学分|毕业最低学分|最低学分要求|毕业总学分)[^\d]{0,25}(\d{2,3}(?:\.\d+)?)'),
    RegExp(r'(\d{2,3}(?:\.\d+)?)\s*学分[^\w]{0,10}(?:毕业|最低)'),
  ]) {
    final m = re.firstMatch(text);
    if (m != null) {
      final v = double.tryParse(m.group(1)!);
      if (v != null && v >= 100 && v <= 300) {
        totalCredits = v;
        break;
      }
    }
  }

  final moduleRe = RegExp(
      r'(通识必修|通识选修|大类基础|学科基础|专业必修|专业核心|专业选修|专业限选|任意选修|集中实践|毕业设计|毕业论文|创新创业|公共选修)[^\n]{0,20}?(\d{1,3}(?:\.\d+)?)\s*学分');
  final declared = <String, double>{};
  const titleToId = {
    '通识必修': 'general_required', '通识选修': 'general_elective',
    '大类基础': 'major_core', '学科基础': 'major_core',
    '专业必修': 'major_core', '专业核心': 'major_core',
    '专业选修': 'major_limited', '专业限选': 'major_limited',
    '任意选修': 'free_elective', '公共选修': 'free_elective', '创新创业': 'free_elective',
    '集中实践': 'intensive_practice', '毕业设计': 'intensive_practice', '毕业论文': 'intensive_practice',
  };
  for (final m in moduleRe.allMatches(text)) {
    final id = titleToId[m.group(1)!];
    final v = double.tryParse(m.group(2)!);
    if (id != null && v != null && v > 0) declared.putIfAbsent(id, () => v);
  }

  final rows = parsePlanCourseRows(html);
  final names = {
    'general_required': '通识教育/通识必修', 'major_core': '专业教育/专业核心',
    'major_limited': '专业教育/专业限选', 'intensive_practice': '集中实践',
    'free_elective': '任意选修', 'general_elective': '通识选修',
  };
  final byModule = <String, List<Map<String, dynamic>>>{};
  for (final r in rows) {
    byModule.putIfAbsent(r['module'] as String, () => []).add(r);
  }
  final modules = <Map<String, dynamic>>[];
  final courses = <Map<String, dynamic>>[];
  for (final id in names.keys) {
    final cs = byModule[id] ?? [];
    if (cs.isEmpty && !declared.containsKey(id)) continue;
    final sum = cs.fold<double>(0, (s, c) => s + (c['credits'] as double));
    modules.add({
      'module_id': id, 'module_path': names[id],
      'required_credits': declared[id] ?? sum,
    });
    for (final c in cs) {
      courses.add({
        'course_id': c['name'], 'name': c['name'], 'credits': c['credits'],
        'module_id': id, 'nature': c['nature'], 'offered': c['offered'],
        'grade_cycle': null, 'offered_years': null, 'prereq': <String>[],
        'source': {'page': c['page']},
      });
    }
  }

  final quality = <String>[
    if (totalCredits == null) '未识别"最低毕业学分"（页面版式可能不同，模块要求用课程求和近似）',
    if (courses.isEmpty) '未识别到课程表行',
    if (courses.isNotEmpty && courses.length < 15) '仅识别到 ${courses.length} 门课程，疑似不完整',
    if (moduleRe.firstMatch(text) == null && courses.isNotEmpty) '未识别到模块学分声明行',
  ];

  return {
    'meta': {
      'major': majorName.isEmpty ? pyfaId : majorName,
      'grade': grade, 'source_doc': '教务网培养方案 $pyfaId（实时获取）',
      'total_credits': totalCredits ??
          modules.fold<double>(0, (s, m) => s + m['required_credits']),
      'extracted_by': 'zdbk 打印页解析', 'verified': quality.isEmpty,
      'quality': quality,
    },
    'modules': modules, 'courses': courses,
  };
}

String _htmlToText(String html) => html
    .replaceAll(RegExp(r'<style.*?</style>|<script.*?</script>', dotAll: true), '')
    .replaceAll(RegExp(r'<br\s*/?>|</p>|</div>|</h[1-6]>|</tr>'), '\n')
    .replaceAll(RegExp(r'</td>|</th>'), ' | ')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&gt;', '>')
    .replaceAll('&lt;', '<')
    .replaceAll('&amp;', '&');

String? _moduleOf(String name) {
  if (RegExp(r'体育|军事|国防|安全教育|思想|道德|法治|概论|史纲|形势|政策|英语|读写|交流|劳动|心理|创新创业|国家安全').hasMatch(name)
      && !name.contains('专业')) {
    return RegExp(r'创新创业|选修').hasMatch(name) ? 'general_elective' : 'general_required';
  }
  if (RegExp(r'实验|实习|设计|实践|毕业论文|毕业设计|训练|研讨').hasMatch(name)) return 'intensive_practice';
  if (RegExp(r'限选|选修').hasMatch(name)) return 'major_limited';
  return 'major_core';
}

/// 课程表行解析：≥3 单元格、"名称+学分"成立。名称含"限选/选修/实验"辅助模块判定。
List<Map<String, dynamic>> parsePlanCourseRows(String html) {
  final tagRe = RegExp(r'<[^>]+>');
  final trRe = RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true, caseSensitive: false);
  final cellRe = RegExp(r'<t[hd][^>]*>(.*?)</t[hd]>', dotAll: true, caseSensitive: false);
  final headerWords = {'序号', '课程代码', '课程名称', '学分', '学时', '备注', '小计', '合计', '先修课程', '开课学期', '课程性质', '考核方式'};
  final rows = <String, Map<String, dynamic>>{};
  for (final tr in trRe.allMatches(html)) {
    final cells = cellRe
        .allMatches(tr.group(1) ?? '')
        .map((m) => (m.group(1) ?? '').replaceAll(tagRe, '').replaceAll('&nbsp;', ' ').trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (cells.length < 3) continue;
    int? creditIdx;
    for (var i = 1; i < cells.length; i++) {
      final c = double.tryParse(cells[i]);
      if (c != null && c > 0 && c <= 20 && (c * 2) % 1 == 0) {
        creditIdx = i;
        break;
      }
    }
    if (creditIdx == null || creditIdx < 1) continue;
    final name = cells[creditIdx - 1];
    if (name.isEmpty || name.length > 40 || headerWords.contains(name)) continue;
    if (RegExp(r'^[\d\s|\.]+$').hasMatch(name)) continue;
    final offered = <String>{};
    for (final cell in cells) {
      if (cell == '秋' || cell == '1' || cell == '上') offered.add('秋');
      if (cell == '春' || cell == '2' || cell == '下') offered.add('春');
    }
    final mod = _moduleOf(name);
    final merged = rows[name];
    final rec = {
      'name': name,
      'credits': double.parse(cells[creditIdx]),
      'offered': offered.isEmpty ? ['秋', '春'] : (offered.toList()..sort()),
      'nature': mod == 'major_limited' || mod == 'free_elective' || mod == 'general_elective'
          ? '限选' : mod == 'intensive_practice' ? '实践' : '必修',
      'module': mod,
      'page': 1,
    };
    if (merged == null || (rec['credits'] as double) > (merged['credits'] as double)) {
      rows[name] = rec;
    }
  }
  return rows.values.toList();
}

/// 实践分 HTML → 第二/三/四课堂分数（对齐 Helechron 主+兜底模式）。
/// 一个课堂值都没解析到（登录页/404/改版/仅有标题无数据/未开通）→ 返回**空 Map**，
/// 上游如实显示"未获取"，绝不把没数据渲染成 0 分（用户反馈 #12：二三四课堂分数要接
/// 真实素拓看板，宁缺勿假）。解析到真实 0.0 时保留 0.0（那是成绩，不是缺数据）。
Map<String, double> parsePracticeScores(String html) {
  final scores = <String, double>{};
  final trRe = RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true, caseSensitive: false);
  final cellRe = RegExp(r'<t[hd][^>]*>(.*?)</t[hd]>', dotAll: true, caseSensitive: false);
  final tagRe = RegExp(r'<[^>]+>');
  const keys = ['第二课堂', '第三课堂', '第四课堂'];
  for (final tr in trRe.allMatches(html)) {
    final cells = cellRe
        .allMatches(tr.group(1) ?? '')
        .map((m) => (m.group(1) ?? '').replaceAll(tagRe, '').trim())
        .where((s) => s.isNotEmpty)
        .toList();
    for (var i = 0; i + 1 < cells.length; i++) {
      final val = double.tryParse(cells[i + 1]);
      if (val == null) continue;
      for (final k in keys) {
        if (cells[i].contains(k)) scores[k] = val;
      }
    }
  }
  // 兜底：值缺失（未在某行配对）的课堂，再按「<td>课堂</td>…<td>数字</td>」相邻补一次。
  for (final k in keys) {
    if (scores.containsKey(k)) continue;
    final alt = RegExp('<td[^>]*>$k</td>.*?<td[^>]*>([0-9.]+)</td>', dotAll: true)
        .firstMatch(html);
    final v = alt == null ? null : double.tryParse(alt.group(1)!);
    if (v != null) scores[k] = v;
  }
  // 一个都没解析到 → 无数据（不是 0 分）；补齐三键为 0 反而误导，直接返回空 Map。
  if (scores.isEmpty) return const {};
  // 部分缺失（如只拿到二课堂）：其余键如实 0（对齐"三键都在"的 UI 消费），但补一句留痕。
  return {
    '第二课堂': scores['第二课堂'] ?? 0.0,
    '第三课堂': scores['第三课堂'] ?? 0.0,
    '第四课堂': scores['第四课堂'] ?? 0.0,
  };
}

// ── 素质拓展平台（sztz.zju.edu.cn/dekt）JSON 解析（对齐 Helechron Sztz 实战）──
// 平台返回 {success:true, code:0, ...} 形态；HTTP 200 也可能仍是登录页 HTML 或匿名壳，
// 一切不符合业务约束的响应一律返回 null/false（纯函数、不抛异常、宁缺勿猜）。

/// /dekt/ctx 响应 → 是否已确认非匿名业务身份（对齐 Helechron isAuthenticatedCtxResponse）。
/// data 是 Base64 编码的 JSON 业务上下文，需同时满足：anonymous 明确为 false、
/// userId 非空且非 ANONYMOUS、roles 不含 ANONYMOUS_USER_ROLE。任一不成立即 false。
bool parseSztzCtxOk(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return false; // 登录页 HTML 等非 JSON 内容
  }
  if (decoded is! Map) return false;
  if (decoded['success'] != true) return false;
  final code = decoded['code'];
  if (code != 0 && code != '0') return false;
  final data = decoded['data'];
  if (data is! String || data.isEmpty) return false;
  Object? ctx;
  try {
    ctx = jsonDecode(
        utf8.decode(base64Decode(base64.normalize(data)), allowMalformed: false));
  } catch (_) {
    return false;
  }
  if (ctx is! Map) return false;
  final anon = ctx['anonymous'];
  // anonymous 字段必须明确为 false（缺失/异常/true 一律不信任）
  if (!(anon == false || anon == 'false' || anon == 0 || anon == '0')) {
    return false;
  }
  final userId = '${ctx['userId'] ?? ''}'.trim();
  if (userId.isEmpty || userId.toUpperCase() == 'ANONYMOUS') return false;
  return !_sztzContainsAnonymousRole(ctx['roles']);
}

bool _sztzContainsAnonymousRole(Object? roles) {
  if (roles is List) return roles.any(_sztzContainsAnonymousRole);
  if (roles is Map) return roles.values.any(_sztzContainsAnonymousRole);
  final role = roles?.toString() ?? '';
  return role
      .split(RegExp(r'[\s,;]+'))
      .any((v) => v.trim().toUpperCase() == 'ANONYMOUS_USER_ROLE');
}

/// /dekt/student/home/getMyInfo 响应 → 三课堂官方记点汇总。
/// 结构 {code:0, extend:{myInfo:{xh, dektJf, dsktJf, dsiktJf, ...}}}（Helechron
/// PracticeScoreSummary.fromMyInfoJson）：dekt/dskt/dsikt 分别对应第二/三/四课堂。
/// 缺单个记点字段按 0；三个字段全缺、code 非 0、extend.myInfo 缺失或
/// xh 与 expectStudentId 不一致（账号隔离）→ null。
Map<String, double>? parseSztzMyInfoTotals(String body,
    {String? expectStudentId}) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final code = decoded['code'];
  if (code != 0 && code != '0') return null;
  final extend = decoded['extend'];
  final myInfo = extend is Map ? extend['myInfo'] : null;
  if (myInfo is! Map) return null;
  // xh 存在且与当前账号不符 → 拒绝（宁缺勿猜，绝不渲染他人记点）
  final xh = '${myInfo['xh'] ?? ''}'.trim();
  if (xh.isNotEmpty &&
      expectStudentId != null &&
      expectStudentId.isNotEmpty &&
      xh != expectStudentId) {
    return null;
  }
  const jfFields = {
    '第二课堂': 'dektJf',
    '第三课堂': 'dsktJf',
    '第四课堂': 'dsiktJf',
  };
  final parsed = <String, double>{};
  var anyField = false;
  for (final e in jfFields.entries) {
    final raw = myInfo[e.value];
    if (raw == null || (raw is String && raw.trim().isEmpty)) continue;
    final v = double.tryParse('$raw'.trim());
    if (v == null || !v.isFinite) return null; // 有字段但解不出 → 整包不信任
    parsed[e.key] = v;
    anyField = true;
  }
  if (!anyField) return null; // 三个记点字段全缺 → 匿名壳/改版，不算数据
  return {
    '第二课堂': parsed['第二课堂'] ?? 0.0,
    '第三课堂': parsed['第三课堂'] ?? 0.0,
    '第四课堂': parsed['第四课堂'] ?? 0.0,
  };
}

/// /dekt/student/home/getSqjl 响应 → 按"审核通过且未删除"合计的三课堂记点。
/// 结构 {success:true, code:0, data:[...], totalPages}；每条记录：id、jd（本人实得
/// 记点）、sfsc（是否删除）、cyrshzt:{value,label}（value==5 或 label=='审核通过'
/// 即通过）、xm:{mc, xmfl:{id,mc}（分类：1/2/3=第二/三/四课堂）}（对齐 Helechron
/// PracticeScoreItem.fromSztzJson）。单条格式异常跳过，不使整批失效；缺 id 的记录
/// 整条丢弃（去重依据）；data 为空列表 → 三键全 0（真实"暂无记录"）；非业务 JSON → null。
Map<String, double>? parseSztzSqjlTotals(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  if (decoded['success'] != true) return null;
  final code = decoded['code'];
  if (code != 0 && code != '0') return null;
  final data = decoded['data'];
  if (data is! List) return null;
  const keyOf = {1: '第二课堂', 2: '第三课堂', 3: '第四课堂'};
  final totals = <String, double>{'第二课堂': 0, '第三课堂': 0, '第四课堂': 0};
  final seenIds = <int>{};
  for (final raw in data) {
    if (raw is! Map) continue;
    final id = int.tryParse('${raw['id'] ?? ''}'.trim());
    if (id == null || !seenIds.add(id)) continue; // 缺 id 或重复记录 → 丢弃
    final deleted = raw['sfsc'] == true || raw['sfsc'] == 'true' ||
        raw['sfsc'] == 1 || raw['sfsc'] == '1';
    if (deleted) continue;
    final st = raw['cyrshzt'];
    final stValue = st is Map ? int.tryParse('${st['value'] ?? ''}'.trim()) : null;
    final stLabel = st is Map ? '${st['label'] ?? ''}'.trim() : '';
    final approved = stValue == 5 || stLabel == '审核通过';
    if (!approved) continue;
    final v = double.tryParse('${raw['jd'] ?? ''}'.trim());
    if (v == null || !v.isFinite || v < 0) continue; // jd 缺失/非法不计入
    final xm = raw['xm'];
    final xmfl = xm is Map ? xm['xmfl'] : null;
    var cat = xmfl is Map ? int.tryParse('${xmfl['id'] ?? ''}'.trim()) ?? 0 : 0;
    if (cat == 0) {
      // 旧响应缺分类 id 时按中文名映射（Helechron 同款兼容）
      final mc = xmfl is Map ? '${xmfl['mc'] ?? ''}'.trim() : '';
      cat = mc == '第二课堂' ? 1 : mc == '第三课堂' ? 2 : mc == '第四课堂' ? 3 : 0;
    }
    final key = keyOf[cat];
    if (key == null) continue; // 非二三四课堂（类别 0/越界）不计入
    totals[key] = totals[key]! + v;
  }
  return totals;
}

/// 结构化课程行（培养方案课程明细接口解析结果）→ PlanFile。
/// 与 [parsePlanPrintHtml] 同构（同一套模块 id 与中文路径），差别只是输入已是结构化行：
/// 用于"学生端方案列表 + 课程明细接口"这条链路（打印页 HTML 在学生账号上常被 910 拦掉）。
Map<String, dynamic> planFileFromCourseRows(
  List<Map<String, dynamic>> rows, {
  required String majorName,
  String grade = '',
  String sourceDoc = '',
  double? totalCredits,
}) {
  const names = {
    'general_required': '通识教育/通识必修', 'major_core': '专业教育/专业核心',
    'major_limited': '专业教育/专业限选', 'intensive_practice': '集中实践',
    'free_elective': '任意选修', 'general_elective': '通识选修',
  };
  final byModule = <String, List<Map<String, dynamic>>>{};
  for (final r in rows) {
    final declared = (r['module'] ?? '').toString().trim();
    final id = declared.isNotEmpty
        ? declared
        : (_moduleOf((r['name'] ?? '').toString()) ?? 'major_core');
    byModule.putIfAbsent(id, () => []).add(r);
  }

  final modules = <Map<String, dynamic>>[];
  final courses = <Map<String, dynamic>>[];
  for (final id in names.keys) {
    final cs = byModule[id];
    if (cs == null || cs.isEmpty) continue;
    var sum = 0.0;
    var added = 0;
    for (final c in cs) {
      final credit = ((c['credits'] as num?) ?? 0).toDouble();
      final name = (c['name'] ?? '').toString();
      if (name.isEmpty) continue;
      sum += credit;
      courses.add({
        'course_id': name,
        'name': name,
        'credits': credit,
        'module_id': id,
        'nature': (c['nature'] ?? '必修').toString(),
        'offered': c['offered'],
        'grade_cycle': null, 'offered_years': null, 'prereq': <String>[],
        'source': {'page': c['page'] ?? 1},
      });
      added++;
    }
    if (added == 0) continue; // 本模块一门都没解析出来 → 不登记空模块
    modules.add({
      'module_id': id, 'module_path': names[id], 'required_credits': sum,
    });
  }

  final quality = <String>[
    if (courses.isEmpty) '课程明细接口未解析到课程行',
    if (totalCredits == null && courses.isNotEmpty)
      '未识别"最低毕业学分"（模块要求用课程学分求和近似）',
  ];

  return {
    'meta': {
      'major': majorName,
      'grade': grade,
      'source_doc': sourceDoc.isEmpty ? '教务网培养方案（课程明细接口，实时获取）' : sourceDoc,
      'total_credits': totalCredits ??
          modules.fold<double>(0, (s, m) => s + (m['required_credits'] as double)),
      'extracted_by': 'zdbk 课程明细解析', 'verified': quality.isEmpty,
      'quality': quality,
    },
    'modules': modules, 'courses': courses,
  };
}
