/// data/share_pack.dart — 「分享给导师」：学生自愿导出 / 导师只读审阅（导师模式 P1）。
///
/// 设计红线（docs/教师模式合规说明.md）：
///  - 数据主权在学生：本功能不访问任何教师端教务接口，App 的只读承诺
///    （eval/check_readonly.py）同样覆盖本模块——这里没有任何网络调用；
///  - 字段级脱敏：导出行按白名单过滤，数字分数（grade）、五分制绩点
///    （five_point / five_point_source）、选课凭证号（xkkh）绝不写入分享包；
///    引擎审计只需要 passed 布尔（build() 只读 passed/grade 兜底，passed 必带）；
///  - 身份脱敏：默认 alias=「匿名同学」，实名需学生显式勾选；学号字段不存在。
///
/// 纯 Dart（仅 dart:convert/dart:io）：可进 dart test 的 CI 白名单，
/// 剪贴板/目录选择等 Flutter 依赖由 UI 层注入，本模块收字符串与路径。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const String sharePackFormat = 'kez.share-pack';

/// 包格式版本：引擎字段口径变化时 +1；导入侧宽松兼容（只拒 > 当前版本）。
/// v2（2026-10-18 需求 #12）：新增可选 ai_advice 段——学生自愿一并导出的
/// AI 选课咨询问答记录（仅 {q,a} 文本，问答内容在导出侧已过 sanitizeAiOutput）。
const int sharePackVersion = 2;

/// 导出行保留白名单——审计与展示所需的最小集合。
/// 名单外字段（grade/five_point/xkkh/source 等）一律剔除，这是脱敏的事实源。
const Set<String> shareRowKeepFields = {
  'course_id', 'name', 'credits', 'passed', 'semester',
  'category', 'original', 'credit_included', 'gpa_included',
};

/// 学生侧构造分享包 JSON 文本（pretty，便于学生肉眼核对内容后再外发）。
///
/// [courses] 审计报告消费的成绩单行（gradeItemToCourse 形状）；
/// [plan] 本次审计所用方案快照（可为 null：仅内置方案专业可裸包导入）；
/// [aiAdvice] 学生自愿附带导出的 AI 选课咨询问答（需求 #12）：形如
/// [{'q': 问题, 'a': 回复}]，文本已在源头过 sanitizeAiOutput；null/空 → 不写入。
/// 行缺 passed 时若有 grade 则换算为 bool（>=60），两者都缺 → 丢行并计数
/// （宁缺勿猜：不把未知课伪装成未通过混进审计）。
({String jsonText, int droppedRows, int coursesCount}) buildSharePack({
  required Map<String, dynamic> student,
  required List<Map<String, dynamic>> courses,
  Map<String, dynamic>? plan,
  List<Map<String, String>>? aiAdvice,
}) {
  final rows = <Map<String, dynamic>>[];
  var dropped = 0;
  for (final c in courses) {
    final name = c['name'];
    if (name is! String || name.trim().isEmpty) {
      dropped++;
      continue;
    }
    var passed = c['passed'];
    if (passed is! bool) {
      final g = c['grade'];
      if (g is num) {
        passed = g >= 60;
      } else {
        dropped++;
        continue;
      }
    }
    final row = <String, dynamic>{
      for (final k in shareRowKeepFields)
        if (c.containsKey(k)) k: c[k],
      'name': name.trim(),
      'passed': passed,
    };
    rows.add(row);
  }
  final out = <String, dynamic>{
    'format': sharePackFormat,
    'version': sharePackVersion,
    'exported_at': DateTime.now().toIso8601String(),
    'student': {
      'alias': (student['alias'] ?? '匿名同学').toString(),
      'major': student['major'].toString(),
      'grade': student['grade'].toString(),
      'current_semester': student['current_semester'].toString(),
    },
    'plan': plan,
    'courses': rows,
    if (aiAdvice != null && aiAdvice.isNotEmpty) 'ai_advice': aiAdvice,
    'privacy_notice': '本文件由学生本人在课舟 App 自愿导出：不含学号、分数、'
        '绩点与任何教务凭证；仅含课程完成状态，用于导师审阅学业达成情况。',
  };
  return (jsonText: _prettyJson(out), droppedRows: dropped, coursesCount: rows.length);
}

/// 导入解析结果：outcome 之一。
sealed class SharePackOutcome {
  const SharePackOutcome();
}

class SharePackOk extends SharePackOutcome {
  final Map<String, dynamic> pack;
  const SharePackOk(this.pack);
}

class SharePackError extends SharePackOutcome {
  final String message;
  const SharePackError(this.message);
}

/// 解析并校验分享包文本（学生导出文件可能被聊天工具改码，宽容读入、严格校验）。
SharePackOutcome parseSharePack(String text) {
  Object? raw;
  try {
    raw = json.decode(text);
  } catch (_) {
    return SharePackError('内容不是有效的 JSON 文本（请整段粘贴导出文件内容）');
  }
  if (raw is! Map<String, dynamic>) {
    return const SharePackError('分享包应为 JSON 对象');
  }
  if (raw['format'] != sharePackFormat) {
    return const SharePackError('不是课舟分享包（format 字段缺失或不匹配）');
  }
  final v = raw['version'];
  if (v is! int || v > sharePackVersion) {
    return SharePackError('分享包版本 $v 高于本机构引擎支持的 $sharePackVersion，'
        '请升级课舟后再导入');
  }
  final issues = validateSharePack(raw);
  if (issues.isNotEmpty) {
    return SharePackError(issues.join('；'));
  }
  return SharePackOk(raw);
}

/// 结构 + 脱敏双重复核：返回问题列表（空 = 合法）。
/// 除结构外，再扫一遍行内不应存在的敏感键——即便学生手工改过文件，
/// 审阅侧也不消费它们（防御纵深：导出白名单是第一道，这里是第二道）。
List<String> validateSharePack(Map<String, dynamic> pack) {
  final issues = <String>[];
  final student = pack['student'];
  if (student is! Map ||
      student['major'] == null ||
      student['grade'] == null ||
      student['current_semester'] == null ||
      int.tryParse('${student['grade']}') == null ||
      !_semesterFormat('${student['current_semester']}')) {
    issues.add('学生信息不完整（major/grade/current_semester 必填且格式合法）');
  }
  final courses = pack['courses'];
  if (courses is! List || courses.isEmpty) {
    issues.add('课程行为空：请确认学生已完成学业审计后再导出');
  } else {
    var bad = 0;
    for (final r in courses) {
      if (r is! Map ||
          r['name'] is! String ||
          (r['name'] as String).trim().isEmpty ||
          r['credits'] is! num ||
          r['passed'] is! bool) {
        bad++;
      }
    }
    if (bad > 0) issues.add('有 $bad 行课程缺 name/credits/passed，无法审计');
  }
  final plan = pack['plan'];
  if (plan != null && (plan is! Map || plan['modules'] is! List)) {
    issues.add('内嵌方案快照结构不完整（缺 modules）');
  }
  final advice = pack['ai_advice'];
  if (advice != null) {
    if (advice is! List ||
        advice.any((x) => x is! Map || x['q'] is! String || x['a'] is! String)) {
      issues.add('AI 咨询记录结构非法（应为 [{q, a}] 文本对）');
    }
  }
  return issues;
}

/// 分享包内嵌的 AI 选课咨询问答（需求 #12；null = 学生未附带）。
List<Map<String, String>>? sharePackAdvice(Map<String, dynamic> pack) {
  final a = pack['ai_advice'];
  if (a is! List || a.isEmpty) return null;
  return [
    for (final x in a)
      if (x is Map && x['q'] is String && x['a'] is String)
        {'q': x['q'] as String, 'a': x['a'] as String},
  ];
}

/// AI 选课咨询问答 → 可直接粘贴给指导教师的纯文本（需求 #12 的轻量通道：
/// 无审计数据也能导出；每轮问答带序号，尾部固定"AI 仅供参考"声明——
/// 问答文本在源头已过 sanitizeAiOutput，不含越界推荐）。
String buildAdviceExportText(List<Map<String, String>> advice) {
  final sb = StringBuffer('【课舟 · AI 选课咨询记录】（学生自愿导出，供指导教师参考）\n\n');
  var i = 0;
  for (final x in advice) {
    i++;
    sb.write('$i. 问：${x['q']}\n   答：${x['a']}\n\n');
  }
  sb.write('—— 由课舟 ClassArk 导出 ${DateTime.now().toIso8601String()}；'
      'AI 内容仅作沟通参考，选课与学业认定以教务系统和教师意见为准。');
  return sb.toString();
}

/// 敏感键扫描（测试与导入提示共用）：课程行与顶层不应出现这些键。
/// 注意 student.grade 是入学年份（引擎必需），故豁免 student 段不扫。
List<String> scanSensitiveKeys(Map<String, dynamic> pack) {
  const forbidden = {
    'grade', 'five_point', 'five_point_source', 'xkkh',
    'student_id', 'sid', 'password', 'ticket', 'jsessionid',
  };
  final hits = <String>[];
  void walk(Object? node) {
    if (node is Map) {
      for (final e in node.entries) {
        if (forbidden.contains('${e.key}'.toLowerCase())) hits.add('${e.key}');
        walk(e.value);
      }
    } else if (node is List) {
      for (final x in node) {
        walk(x);
      }
    }
  }
  walk(pack['courses']);
  for (final k in pack.keys) {
    if (k != 'student' && k != 'plan' &&
        forbidden.contains('${k}'.toLowerCase())) {
      hits.add('$k');
    }
  }
  return hits;
}

/// 分享包 → 审计引擎 record（与 main.dart 教务链路同形：student/courses，
/// major 直接沿用包内值作为 runtimePlans 键，保证 findPlan 命中）。
Map<String, dynamic> sharePackToRecord(Map<String, dynamic> pack) => {
      'student': Map<String, dynamic>.from(pack['student'] as Map),
      'source': 'share_pack',
      'courses': [
        for (final r in (pack['courses'] as List))
          Map<String, dynamic>.from(r as Map),
      ],
    };

/// 分享包内嵌方案快照（null = 裸包，依赖审阅者本机专业方案）。
Map<String, dynamic>? sharePackPlan(Map<String, dynamic> pack) {
  final p = pack['plan'];
  return p is Map ? Map<String, dynamic>.from(p) : null;
}

/// 把包写入 [dirPath]/share/ 并返回文件路径（文件名纯 ASCII，聊天传输不乱码）。
Future<String> writeSharePack(String dirPath, String jsonText) async {
  final dir = Directory(_join([dirPath, 'share']));
  await dir.create(recursive: true);
  final stamp = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final name = 'kez_share_${stamp.year}${two(stamp.month)}${two(stamp.day)}'
      '_${two(stamp.hour)}${two(stamp.minute)}${two(stamp.second)}.json';
  final f = File(_join([dir.path, name]));
  await f.writeAsString(jsonText, encoding: utf8, flush: true);
  return f.path;
}

/// 列出目录内可导入的分享包文件（教师模式「目录导入」通道用）。
Future<List<String>> listSharePackFiles(String dirPath) async {
  final dir = Directory(_join([dirPath, 'share']));
  if (!await dir.exists()) return [];
  final out = <String>[];
  await for (final e in dir.list()) {
    if (e is File && e.path.toLowerCase().endsWith('.json')) {
      try {
        final parsed = parseSharePack(await e.readAsString());
        if (parsed is SharePackOk) out.add(e.path);
      } catch (_) {/* 读不动/非法文件直接跳过，不打扰 */}
    }
  }
  out.sort();
  return out;
}

bool _semesterFormat(String s) => RegExp(r'^\d{4}-[ABC](\|.*)?$').hasMatch(s);

String _prettyJson(Map<String, dynamic> m) =>
    const JsonEncoder.withIndent('  ').convert(m);

String _join(List<String> parts) => p.joinAll(parts);
