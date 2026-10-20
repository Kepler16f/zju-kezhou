/// data/share_pack.dart — 「分享给导师」：学生自愿导出 / 导师只读审阅（导师模式 P1）。
///
/// 设计红线（docs/教师模式合规说明.md）：
///  - 数据主权在学生：本功能不访问任何教师端教务接口，App 的只读承诺
///    （eval/check_readonly.py）同样覆盖本模块——这里没有任何网络调用；
///  - 字段级脱敏：导出行按白名单过滤，数字分数（grade）、五分制绩点
///    （five_point / five_point_source）、选课凭证号（xkkh）绝不写入分享包；
///    引擎审计只需要 passed 布尔（build() 只读 passed/grade 兜底，passed 必带）；
///    v3（2026-10-18）新增 selected_courses 段（本学期已选/模拟选课），
///    同样按白名单（selectedRowKeepFields）过滤，只带展示与匹配字段，绝不带成绩；
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
/// v3（2026-10-18）：新增可选 selected_courses 段——本学期已选/模拟选课清单
/// （白名单 selectedRowKeepFields）；教师审阅页展示课程明细，导入侧映射为
/// record.planned_courses 供引擎计入 selected_no_credit。v2 旧包向后兼容
/// （无该段视为空），parseSharePack 的「只拒 > 当前版本」口径不变。
const int sharePackVersion = 3;

/// 导出行保留白名单——审计与展示所需的最小集合。
/// 名单外字段（grade/five_point/xkkh/source/original 等）一律剔除，这是脱敏的事实源。
/// original 是教务原始成绩文本（数值型如 "90"），与「不含分数」承诺冲突，
/// 2026-10-21 评审发现后移出白名单（教师端审计只用 passed/credits，无功能损失）。
const Set<String> shareRowKeepFields = {
  'course_id', 'name', 'credits', 'passed', 'semester',
  'category', 'credit_included', 'gpa_included',
};

/// v3 选课行白名单（selected_courses 段）——导师审阅「本学期选了什么」
/// 所需的最小集合：成绩口径字段一个都不要（无 passed/grade/绩点），
/// 只带展示（teacher/sksj/cdmc）与引擎相似度匹配（course_id/name/credits）字段。
/// 名单外键（grade/xkkh/raw 等）在导出侧即被剔除，这是选课行的脱敏事实源；
/// 行形状由 engine/selection.dart 的 exportRowsFromPlanned 产出。
const Set<String> selectedRowKeepFields = {
  'course_id', 'name', 'credits', 'teacher', 'sksj', 'cdmc', 'semester',
  // v0.13.10：行状态 earned（已获学分）/ active（在修）/ simulated（模拟选课），
  // 教师端据此区分展示；缺字段视为 active（v3 旧包向后兼容）。
  'status',
};

/// 学生侧构造分享包 JSON 文本（pretty，便于学生肉眼核对内容后再外发）。
///
/// [courses] 审计报告消费的成绩单行（gradeItemToCourse 形状）；
/// [plan] 本次审计所用方案快照（可为 null：仅内置方案专业可裸包导入）；
/// [aiAdvice] 学生自愿附带导出的 AI 选课咨询问答（需求 #12）：形如
/// [{'q': 问题, 'a': 回复}]，文本已在源头过 sanitizeAiOutput；null/空 → 不写入。
/// [selectedCourses] v3：本学期已选/模拟选课清单（exportRowsFromPlanned 形状，
/// 可含 slots 等非白名单键——写入前按 selectedRowKeepFields 再过滤一遍）；
/// null/空 → 不写入该段。行缺 name 同样丢行并计入 droppedRows（宁缺勿猜）。
/// 行缺 passed 时若有 grade 则换算为 bool（>=60），两者都缺 → 丢行并计数
/// （宁缺勿猜：不把未知课伪装成未通过混进审计）。
({String jsonText, int droppedRows, int coursesCount}) buildSharePack({
  required Map<String, dynamic> student,
  required List<Map<String, dynamic>> courses,
  Map<String, dynamic>? plan,
  List<Map<String, String>>? aiAdvice,
  List<Map<String, dynamic>>? selectedCourses,
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
  // v3：选课行独立丢行计数（无 name 的行不可展示也不可匹配，宁缺勿猜），
  // 且每行写包前再过一次选课白名单——即便调用方传入了成绩口径的行，
  // grade/xkkh/raw 等也进不了包（白名单是脱敏的事实源）。
  final selRows = <Map<String, dynamic>>[];
  if (selectedCourses != null) {
    for (final c in selectedCourses) {
      final name = c['name'];
      if (name is! String || name.trim().isEmpty) {
        dropped++;
        continue;
      }
      selRows.add(<String, dynamic>{
        for (final k in selectedRowKeepFields)
          if (c.containsKey(k)) k: c[k],
        'name': name.trim(),
      });
    }
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
    if (selRows.isNotEmpty) 'selected_courses': selRows,
    if (aiAdvice != null && aiAdvice.isNotEmpty) 'ai_advice': aiAdvice,
    'privacy_notice': '本文件由学生本人在课舟 App 自愿导出：不含学号、分数、'
        '绩点与任何教务凭证；仅含课程完成状态与本学期选课清单，'
        '用于导师审阅学业达成情况。',
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
  // v3：selected_courses 为可选段——v2 旧包缺段视为空（向后兼容，不报错）；
  // 有段时逐行核 name（展示与相似度匹配的兜底键），credits 只认数字，
  // semester 若带则须符合学期格式（引擎会按学期做计划课表冲突检查）。
  final selected = pack['selected_courses'];
  if (selected != null) {
    if (selected is! List) {
      issues.add('选课清单结构非法（selected_courses 应为数组）');
    } else {
      var bad = 0;
      for (final r in selected) {
        final sem = r is Map ? r['semester'] : null;
        if (r is! Map ||
            r['name'] is! String ||
            (r['name'] as String).trim().isEmpty ||
            (r['credits'] != null && r['credits'] is! num) ||
            (sem != null &&
                (sem is! String || !_semesterFormat(sem)))) {
          bad++;
        }
      }
      if (bad > 0) issues.add('有 $bad 行选课记录缺 name / 学分非数字 / 学期格式非法');
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

/// v3：包内本学期选课清单（selected_courses）→ 展示用行（无段/v2 旧包 → 空表）。
/// 只读取出现在包内的白名单字段，绝不在此补造任何字段。
List<Map<String, dynamic>> sharePackSelected(Map<String, dynamic> pack) {
  final s = pack['selected_courses'];
  if (s is! List) return const <Map<String, dynamic>>[];
  return [
    for (final r in s)
      if (r is Map) Map<String, dynamic>.from(r),
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
    'grade', 'five_point', 'five_point_source', 'xkkh', 'original',
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
  walk(pack['selected_courses']);
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
/// v3：包内 selected_courses 映射为 record['planned_courses']（引擎按 course_id
/// 计 selected_no_credit；缺 course_id 的行保留空值，由引擎按名称做相似度匹配，
/// 绝不造假 id）。v2 旧包无该段 → 不写 planned_courses（与旧行为一致）。
Map<String, dynamic> sharePackToRecord(Map<String, dynamic> pack) {
  final selected = pack['selected_courses'];
  final planned = <Map<String, dynamic>>[
    if (selected is List)
      for (final r in selected)
        if (r is Map)
          <String, dynamic>{
            'course_id': ('${r['course_id'] ?? ''}').trim().isEmpty
                ? null
                : '${r['course_id']}'.trim(),
            'name': r['name'],
            'credits': r['credits'],
            if (r['slots'] != null) 'slots': r['slots'],
            if (r['semester'] != null) 'semester': r['semester'],
            if (r['teacher'] != null) 'teacher': r['teacher'],
            if (r['sksj'] != null) 'sksj': r['sksj'],
            if (r['cdmc'] != null) 'cdmc': r['cdmc'],
          },
  ];
  return {
    'student': Map<String, dynamic>.from(pack['student'] as Map),
    'source': 'share_pack',
    'courses': [
      for (final r in (pack['courses'] as List))
        Map<String, dynamic>.from(r as Map),
    ],
    if (planned.isNotEmpty) 'planned_courses': planned,
  };
}

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
