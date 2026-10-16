/// engine/plan_audit_adapter.dart — 培养方案 PDF 解析结果（data/plan_pdf_parse.dart）
/// → 审计引擎 PlanFile（engine/audit.dart build() 可直接消费）的适配器。
///
/// 背景：审计此前用「方案摘要」（只有专业核心/实践/前沿三类课）构建 PlanFile，
/// 大量已修课程因不在摘要里而报「未匹配到方案」。官方方案 PDF 经
/// parsePlanPdfText 解析后带有完整课程表与真实板块树；本适配器把它转成
/// PlanFile，使「方案」页展示的板块与审计报告的三色达成度一一对应。
///
/// 纪律：纯函数、零 IO、不抛异常（含空输入）。
library;

import '../data/plan_pdf_parse.dart';

// ── 结果对象 ────────────────────────────────────────────────────────────────

/// 板块说明里识别出的「修读选择约束」（二选一 / N 选 M / 至少 X 门 / 至少 Y 学分）。
class ChoiceRule {
  final String text; // 命中的原文片段（多个片段以「；」连接）
  final double? minCredits; // 「至少修读Y学分」
  final int? minCourses; // 「至少修读X门」，或 N 选 M 的 M
  final int? pickFrom; // 「N 选 M」的 N（二选一 → 2）

  const ChoiceRule({
    required this.text,
    this.minCredits,
    this.minCourses,
    this.pickFrom,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'text': text,
        'min_credits': minCredits,
        'min_courses': minCourses,
        'pick_from': pickFrom,
      };
}

/// 「以下 N 种模块中的一种」信号：板块说明表明其子板块并列可选、
/// 满足其一即可（诉求 #11）。本适配器只提供识别；如何计入达成度由 UI/后续审计决定。
class AlternativeSignal {
  final int optionCount; // 说明里声明的可选模块种数
  final String text; // 命中原文片段
  final List<String> optionTitles; // 该板块的直接子板块标题（并行选项）

  const AlternativeSignal({
    required this.optionCount,
    required this.text,
    this.optionTitles = const [],
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'text': text,
        'option_count': optionCount,
        'option_titles': optionTitles,
      };
}

// ── 纯函数小工具（单独可测）────────────────────────────────────────────────

/// 板块 creditsRaw → 要求学分：取首个数字段（'3-6'→3、'+4'→4、''→0）。
double requiredCreditsFrom(String creditsRaw) {
  final m = RegExp(r'\d+(?:\.\d+)?').firstMatch(creditsRaw);
  return m == null ? 0.0 : (double.tryParse(m.group(0)!) ?? 0.0);
}

/// module_path：parentPath 空则用自身 title，否则用 parentPath（' · ' 连接的上级链）。
String modulePathOf(PdfModuleSection s) =>
    s.parentPath.isEmpty ? s.title : s.parentPath;

/// 板块课程性质：标题含「必修」→ 必修；含「选修」或「限选」→ 选修；否则必修。
String natureFromSectionTitle(String title) {
  if (title.contains('必修')) return '必修';
  if (title.contains('选修') || title.contains('限选')) return '选修';
  return '必修';
}

/// 建议学年学期串 → 引擎开课学期（'秋'/'春'；短学期记 '夏'；空/无法判定 → null）。
/// 规则：含「短」→ ['夏']；含秋或冬 且 含春或夏 → ['秋','春']；仅秋/冬 → ['秋']；
/// 仅春/夏 → ['春']；其余（非空但无学期字）→ null，宁缺勿猜。
List<String>? offeredFromSemester(String semester) {
  final s = semester.trim();
  if (s.isEmpty) return null;
  if (s.contains('短')) return const <String>['夏'];
  final autumn = s.contains('秋') || s.contains('冬');
  final spring = s.contains('春') || s.contains('夏');
  if (autumn && spring) return const <String>['秋', '春'];
  if (autumn) return const <String>['秋'];
  if (spring) return const <String>['春'];
  return null;
}

const _cnDigits = {
  '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
  '五': 5, '六': 6, '七': 7, '八': 8, '九': 9, '十': 10,
};

int? _parseCount(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  return int.tryParse(t) ?? _cnDigits[t];
}

/// 数量词模式：阿拉伯数字或中文数字（一~十、两）。
const _cnNum = r'[0-9]+|[一二两三四五六七八九十]+';

/// 稳定 slug：`sec{文档序}-{title 去空格截断 12}`（中文可用）；纯函数，可单测。
String moduleSlug(String title, int docIndex) {
  final norm = title.replaceAll(RegExp(r'\s+'), '');
  final cut = norm.length <= 12 ? norm : norm.substring(0, 12);
  return cut.isEmpty ? 'sec$docIndex' : 'sec$docIndex-$cut';
}

/// 同名（截断后同串）重复时加序号：`base` 未占用则原样返回并登记，
/// 否则取 `base-2`、`base-3`…（结果同步登记进 [taken]）。
String uniqueSlug(String base, Set<String> taken) {
  if (!taken.contains(base)) {
    taken.add(base);
    return base;
  }
  var n = 2;
  while (taken.contains('$base-$n')) {
    n++;
  }
  final id = '$base-$n';
  taken.add(id);
  return id;
}

// ── 约束识别 ───────────────────────────────────────────────────────────────

/// 从板块说明识别修读选择约束；识别不了返回 null（宁缺勿猜）。
/// 支持：「二选一 / 三选一 / N 选 M」（N>M≥1）、「至少（修读）X 门」、
/// 「至少（修读）Y 学分」；中文数字与阿拉伯数字皆可；多类约束并存时合并为
/// 一条规则（「至少 X 门」与 N 选 M 的 M 并存时取较大者——显式下限优先）。
ChoiceRule? detectChoiceRule(String notesJoined) {
  final text = notesJoined.trim();
  if (text.isEmpty) return null;
  final fragments = <String>[];
  double? minCredits;
  int? minCourses;
  int? pickFrom;

  final pick = RegExp('($_cnNum)\\s*选\\s*($_cnNum)').firstMatch(text);
  if (pick != null) {
    final n = _parseCount(pick.group(1)!);
    final m = _parseCount(pick.group(2)!);
    if (n != null && m != null && n > m && m > 0) {
      pickFrom = n;
      minCourses = m;
      fragments.add(pick.group(0)!);
    }
  }
  final door = RegExp('至少\\s*(?:修读|修)?\\s*($_cnNum)\\s*门').firstMatch(text);
  if (door != null) {
    final x = _parseCount(door.group(1)!);
    if (x != null && x > 0) {
      minCourses = minCourses == null || x > minCourses ? x : minCourses;
      fragments.add(door.group(0)!);
    }
  }
  final credit = RegExp(r'至少\s*(?:修读|修)?\s*([\d.]+)\s*学分').firstMatch(text);
  if (credit != null) {
    final y = double.tryParse(credit.group(1)!);
    if (y != null && y > 0) {
      minCredits = y;
      fragments.add(credit.group(0)!);
    }
  }

  if (fragments.isEmpty) return null;
  return ChoiceRule(
    text: fragments.join('；'),
    minCredits: minCredits,
    minCourses: minCourses,
    pickFrom: pickFrom,
  );
}

/// 板块说明命中「以下 N 种模块中的一种」→ 返回并行可选信号（含 optionCount，N≥2）；
/// 否则 null。[siblings] 为该板块的直接子板块（并列选项，满足其一即可，诉求 #11）。
AlternativeSignal? detectAlternativeModules(
    List<PdfModuleSection> siblings, String parentNotes) {
  final m = RegExp('以下\\s*($_cnNum)\\s*种模块中的一种').firstMatch(parentNotes);
  if (m == null) return null;
  final n = _parseCount(m.group(1)!);
  if (n == null || n < 2) return null; // 「一种」不构成并列可选
  return AlternativeSignal(
    optionCount: n,
    text: m.group(0)!,
    optionTitles: siblings.map((s) => s.title).toList(),
  );
}

// ── 主适配器 ───────────────────────────────────────────────────────────────

/// [ps] 中 [s]（下标 [i]）的直接子板块（parentPath == s.label）。
List<PdfModuleSection> _childrenOf(PlanPdfSections ps, int i) {
  final label = ps.sections[i].label;
  return [
    for (var j = 0; j < ps.sections.length; j++)
      if (j != i && ps.sections[j].parentPath == label) ps.sections[j]
  ];
}

/// 板块 [i] 之下是否还有**保留为模块**的子板块（含更深层：课程挂在 L4、
/// 要求标在 L1 的方案里，L1 的学分是包含关系，不能再计入总学分）。
bool _hasKeptDescendant(PlanPdfSections ps, int i, Set<int> keptIdx) {
  final label = ps.sections[i].label;
  final prefix = '$label · ';
  for (final j in keptIdx) {
    if (j == i) continue;
    final p = ps.sections[j].parentPath;
    if (p == label || p.startsWith(prefix)) return true;
  }
  return false;
}

/// 方案 PDF 解析结果 → 审计引擎 PlanFile（AuditEngine.build() 直接消费）。
///
/// 板块取舍：有课程的板块全部成模块；level≤2 且有学分标注的板块即使课程都挂在
/// 更深层子板块，也保留为模块（板块学分要求要在「方案」页展示）。
/// 课程挂在其所在 section（即模块）；course_id 用 PDF 课程号（与成绩单同源于
/// 教务，精确匹配命中率最高）；名称差异由 engine/matching.dart 以相似度 ≥0.85 兜底。
///
/// meta.total_credits：[totalCredits] 缺省时取「无下级板块的模块」要求学分之和
/// （父子板块学分在 PDF 里是包含关系，直接求和会重复计）。
///
/// 永不抛异常；[ps] 为空时返回结构完整的空 PlanFile。
Map<String, dynamic> planFileFromPdf(
  PlanPdfSections ps, {
  required String major,
  required String grade,
  double? totalCredits,
  String? sourceDoc,
}) {
  final modules = <Map<String, dynamic>>[];
  final courses = <Map<String, dynamic>>[];
  final takenIds = <String>{};
  final keptIdx = <int>{}; // 被保留为模块的板块下标（供 total_credits 兜底用）

  for (var i = 0; i < ps.sections.length; i++) {
    final s = ps.sections[i];
    final keep = s.courses.isNotEmpty ||
        (s.level <= 2 && s.creditsRaw.trim().isNotEmpty);
    if (!keep) continue;
    keptIdx.add(i);

    final moduleId = uniqueSlug(moduleSlug(s.title, i), takenIds);
    final courseIds = <String>[];
    for (final c in s.courses) {
      courseIds.add(c.code);
      courses.add(<String, dynamic>{
        'course_id': c.code,
        'name': c.name,
        'credits': c.credits,
        'module_id': moduleId,
        'nature': natureFromSectionTitle(s.title),
        'offered': offeredFromSemester(c.semester),
        'grade_cycle': null,
        'offered_years': null,
        'prereq': <String>[],
        'source': <String, dynamic>{'page': ''},
      });
    }

    final notesJoined = s.notes.join('\n');
    final rule = detectChoiceRule(notesJoined);
    final alt = detectAlternativeModules(_childrenOf(ps, i), notesJoined);
    modules.add(<String, dynamic>{
      'module_id': moduleId,
      'module_path': modulePathOf(s),
      'required_credits': requiredCreditsFrom(s.creditsRaw),
      'course_ids': courseIds,
      // 展示/后续审计用的附加信息（AuditEngine.build() 不读取，不影响其计算）：
      'title': s.title,
      'level': s.level,
      'notes': s.notes,
      if (rule != null) 'choice_rule': rule.toJson(),
      if (alt != null) 'alternative': alt.toJson(),
    });
  }

  // total_credits 缺省兜底：只累加「保留为模块且其下无其它保留板块」的学分要求，
  // 避免父子板块（包含关系）重复计。
  final leafSum = <int>[...keptIdx]
      .where((i) => !_hasKeptDescendant(ps, i, keptIdx))
      .fold<double>(
          0, (a, i) => a + requiredCreditsFrom(ps.sections[i].creditsRaw));

  final quality = <String>[
    ...ps.qualityNotes,
    '课程清单来自官方培养方案 PDF 解析（${modules.length} 个板块 / '
        '${courses.length} 门课程）；「至少N门/二选一」等约束见各板块说明',
    '板块要求学分取标注首个数字段（区间如“3-6”按下限计）；'
        '「以下N种模块中的一种」等并列可选板块按各自学分单独核算，满足其一即可',
  ];

  return <String, dynamic>{
    'meta': <String, dynamic>{
      'major': major,
      'grade': grade,
      'source_doc': (sourceDoc == null || sourceDoc.trim().isEmpty)
          ? '培养方案 PDF 解析（教务 zdbk 官方方案）'
          : sourceDoc,
      'total_credits': totalCredits ?? leafSum,
      'extracted_by': 'engine/plan_audit_adapter.planFileFromPdf',
      'verified': false,
      'quality': quality,
    },
    'modules': modules,
    'courses': courses,
  };
}
