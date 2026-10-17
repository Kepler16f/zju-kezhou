/// engine/plan_audit_adapter.dart — 培养方案 PDF 解析结果（data/plan_pdf_parse.dart）
/// → 审计引擎 PlanFile（engine/audit.dart build() 可直接消费）的适配器。
///
/// 背景：审计此前用「方案摘要」（只有专业核心/实践/前沿三类课）构建 PlanFile，
/// 大量已修课程因不在摘要里而报「未匹配到方案」。官方方案 PDF 经
/// parsePlanPdfText 解析后带有完整课程表与真实板块树；本适配器把它转成
/// PlanFile，使「方案」页展示的板块与审计报告的三色达成度一一对应。
///
/// 类别数据流（打通「学分看板未分类」；三个视图共用同一类别事实源 = 方案板块）：
///   培养方案板块（PDF 解析板块树 / 内置 golden 模块）
///     → 本适配器 / 内置 JSON 产出 modules[].module_path
///       （PDF 口径为 ' · ' 连接的上级全路径，golden 为 '通识教育/通识必修' 式路径）
///     → AuditEngine.build 经 engine/matching.dart 匹配「成绩单行 → 方案课程」
///     → 本文件 coursesCategoryMap / applyPlanCategories：用同一匹配口径把
///       module_path 末段（tailCategory）补成成绩单行的 category（只补空值）
///     → 学分看板 Analytics.creditByCategory 按 category 聚合（根因：教务成绩单
///       xscjcx 实测无 kcxzmc/kclbmc 字段、样例亦无 category，此前全落「未分类」）；
///       方案页板块高亮（并行链路）与审计三色模块同样锚定这套 module_path。
///
/// 另两处专项修复：
///  * #12 尾：「至少修读N门…」子规则板块（creditsUnit='门'）的数字是门数不是
///    学分，绝不计入 required_credits——门规则板块不独立成模块，其课程表并入
///    上级学分板块核算（totals.required 不因门数虚增，也不高于父板块标注）；
///  * #13：认定类板块（美育/劳育/创新创业/心理健康，PDF 无课程表）保留为模块
///    并按说明抽要求学分；certifiedCategoryOf 按关键词把成绩单同类课归入对应
///    认定类别（applyPlanCategories 第二路兜底 + planFileFromPdf 挂课计 earned）。
///
/// 纪律：纯函数、零 IO、不抛异常（含空输入）。
library;

import '../data/plan_pdf_parse.dart';
import 'matching.dart' show matchRecordToPlan;

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

// ── 认定类课程归类（用户反馈 #13）─────────────────────────────────────────
// 「五、其他必修环节（认定型学分）」的四类板块（美育/劳育/创新创业/心理健康）
// 在方案 PDF 里只有说明文字、没有课程表（实测 2026 级食品方案：「要求学生修读
// 2学分心理健康类课程，详见本科生院公布的心理健康类课程清单。」），成绩单里的
// 同类课（如「大学生心理适应与发展」）因此无法归位。以下按关键词归类。

/// 关键词词表：从真实方案说明文本抽取（2026 级浙大方案各认定类的
/// 「要求学生修读…课程。可修读……课程清单」句），宁缺勿猜、误归类比不归类更糟：
///  * 心理健康：说明只提「心理健康类」；成绩单课名常作「心理…」「…适应与发展」，
///    「心理」即可覆盖（「心理健康」是其子串，不必单列）。
///  * 美育：说明列「文艺审美类、博雅技艺中艺术类、艺术类专业课程」→ 收
///    「美术/音乐/艺术/审美/戏剧/书法/舞蹈/美育」；不收裸「文艺」（如
///    「文艺学」属中文专业课）。
///  * 创新创业：说明只提「创新创业类」→ 收「创新创业/创业/创新训练/大创」；
///    裸「创新」太泛（「创新设计」等专业课），不收。
///  * 劳育：说明提「劳动教育类课程/公共劳动平台/专业实践劳动课程」→ 收
///    「劳动/劳育/农事/耕读/实践劳动/志愿服务」；**刻意不收裸「实践」**——
///    社会实践、生产实习、思政课「新时代实践教育」等普通课均含之，误吸面太大，
///    用「实践劳动」这类复合词限定。
const _certifiedKeywords = <String, List<String>>{
  '心理健康类': ['心理', '适应与发展'],
  '美育类': ['美术', '音乐', '艺术', '审美', '戏剧', '书法', '舞蹈', '美育'],
  '创新创业类': ['创新创业', '创业', '创新训练', '大创'],
  '劳育类': ['劳动', '劳育', '农事', '耕读', '实践劳动', '志愿服务'],
};

/// 多类同命中时的确定性优先级（写死顺序、可测）：心理健康 > 美育 > 创新创业 >
/// 劳育。心理健康最专（词几乎只出现在心理课），故最优先；劳育词面最宽，最后。
/// 纯函数：contains 任一关键词即归该类；无命中返回 null（宁缺勿猜）。
String? certifiedCategoryOf(String courseName) {
  final n = courseName.trim();
  if (n.isEmpty) return null;
  for (final entry in _certifiedKeywords.entries) {
    for (final k in entry.value) {
      if (n.contains(k)) return entry.key;
    }
  }
  return null;
}

/// 认定类**板块**判据：level≤3 且标题命中类别名干词（比课程词表更窄——
/// 板块标题就是「美育类/劳育类/创新创业类/心理健康类」本身；普通课名式标题
/// 如「艺术类课程」不会出现在这里，因为再要求标题 ≤12 字且不含「门」，避免
/// 把普通「至少修读1门美育类课程」式规则行误判成认定板块）。纯函数可单测。
const _certifiedStemCategory = <String, String>{
  '美育': '美育类',
  '劳育': '劳育类',
  '创新创业': '创新创业类',
  '心理健康': '心理健康类',
};

String? certifiedSectionCategory(PdfModuleSection s) {
  final t = s.title.trim();
  if (s.level > 3 || s.isCountRule || t.isEmpty || t.length > 12) return null;
  for (final entry in _certifiedStemCategory.entries) {
    if (t.contains(entry.key)) return entry.value;
  }
  return null;
}

/// 认定类板块说明 → 要求学分：抽「（要求学生）修读N学分」里的 N；
/// 抽不到记 0（如劳育类「要求学生修读32**学时**劳动教育类课程」——学时不是
/// 学分，正则要求「学分」字面，天然排除）。纯函数、不抛异常。
double certifiedRequiredCredits(List<String> notes) {
  final m = RegExp(r'修读\s*([\d.]+)\s*学分').firstMatch(notes.join('\n'));
  return m == null ? 0.0 : (double.tryParse(m.group(1)!) ?? 0.0);
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

// ── 板块取舍（叶子优先，防父子重复计费）────────────────────────────────────
// 旧规则「有课程 || (level≤2 且有学分标注)」会同时保留父板块与其子板块
// （如 一、通识课程 72.5学分 与 1.通识必修 62学分 + 2.通识选修 10.5学分），
// 而 AuditEngine 把各模块 required_credits 求和 → totals.required = 72.5+62+10.5
// 对子板块学分重复计费（用户反馈「三色学分存在重复计费」）。PDF 里父子板块
// 学分是包含关系，审计口径必须只计一次 → 见 keptSectionFlags。

/// 板块 [i] 之下是否还有**被保留为模块**的板块（含更深层：课程挂在 L4、
/// 要求标在 L1 的方案里，L1 的学分是包含关系）。父子按 parentPath 前缀判定
/// （parse 结果里子板块 parentPath = 祖先链，label = parentPath · 自身标题）。
bool _hasKeptDescendant(PlanPdfSections ps, int i, List<bool> kept) {
  final label = ps.sections[i].label;
  final prefix = '$label · ';
  for (var j = 0; j < ps.sections.length; j++) {
    if (j == i || !kept[j]) continue;
    final p = ps.sections[j].parentPath;
    if (p == label || p.startsWith(prefix)) return true;
  }
  return false;
}

/// 板块保留判定（叶子优先，独立纯函数便于单测）。
///
/// 规则：
///  * 有直属课程的板块 → 保留（课程挂进该模块，其直属课程仍计入审计）；
///  * 无直属课程 → 仅当「其下没有其它被保留的板块」（即它是当前保留集合的
///    叶子）且带学分标注才保留——它是真正的 rollup 终点，要求不再被子板块包含；
///    有被保留子板块的父板块只作路径展示（module_path 层级仍在子板块路径里），
///    不再单独计入总学分；
///  * 无课且无学分标注 → 丢弃（既无可计课程也无独立要求，宁缺勿凑数）。
///
/// 「是否保留」与「子板块是否保留」互相依赖，故从全假出发做不动点迭代：
/// 父子关系由 parentPath 前缀构成无环偏序（label 长度沿链严格递增），至多
/// 板块数轮收敛；不依赖文档顺序（解析器保证父先于子，合成数据亦安全）。
///
/// 另两条判据（与 UI/审计口径联动，见 planFileFromPdf）：
///  * 「N门」子规则板块（isCountRule，creditsRaw 数字是门数不是学分）一律
///    不保留为模块——其数字绝不能计入 required_credits（用户反馈 #12 尾）；
///    带课程表的门规则板块课程在 planFileFromPdf 里并入最近上级学分板块。
///  * 认定类板块（美育/劳育/创新创业/心理健康，level≤3 标题命中）即使无课、
///    无学分标注也保留——审计要能对该类算 earned（用户反馈 #13）。
List<bool> keptSectionFlags(PlanPdfSections ps) {
  final n = ps.sections.length;
  var kept = List<bool>.filled(n, false);
  for (var round = 0; round <= n; round++) {
    final next = List<bool>.generate(n, (i) {
      final s = ps.sections[i];
      if (s.isCountRule) return false; // 门数不是学分：门规则板块不独立成模块
      if (certifiedSectionCategory(s) != null) return true; // 认定类板块保留
      if (s.courses.isNotEmpty) return true; // 直属课程仍要挂进审计模块
      if (s.creditsRaw.trim().isEmpty) return false; // 无课无标注：无独立要求
      return !_hasKeptDescendant(ps, i, kept); // 有被保留子板块 → 仅作 rollup
    });
    var stable = true;
    for (var i = 0; i < n; i++) {
      if (next[i] != kept[i]) {
        stable = false;
        break;
      }
    }
    kept = next;
    if (stable) break;
  }
  return kept;
}

// ── 主适配器 ───────────────────────────────────────────────────────────────

/// 「门」规则板块（isCountRule）最近的非「门」祖先板块下标；顶层门规则无祖先
/// 返回 null。parentPath 链从最深一级向上找（label = 祖先链 join(' · ')），
/// 跳过同为「门」单位的祖先（嵌套门规则罕见但防御）。
int? _nearestCreditAncestorIndex(PlanPdfSections ps, int i) {
  final segs = ps.sections[i].parentPath
      .split(' · ')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  for (var k = segs.length; k >= 1; k--) {
    final label = segs.take(k).join(' · ');
    for (var j = 0; j < ps.sections.length; j++) {
      final t = ps.sections[j];
      if (t.label == label && !t.isCountRule) return j;
    }
  }
  return null;
}

/// 方案 PDF 解析结果 → 审计引擎 PlanFile（AuditEngine.build() 直接消费）。
///
/// 板块取舍（叶子优先，防父子重复计费，判定见 [keptSectionFlags]）：
/// 有直属课程的板块全部成模块；无直属课程的板块仅当为「有效叶子」（其下没有
/// 被保留的子板块且带学分标注）才保留。父板块的学分标注是包含关系
/// （一、通识课程 72.5 ⊇ 1.通识必修 62 + 2.通识选修 10.5），不再单独成为
/// 审计模块，其层级经子板块 module_path 的「 · 」全路径体现（UI 对应关系依赖）。
/// 混合父板块（自身直接挂课且仍有被保留子板块）：保留且直属课程仍计，但
/// required_credits 只取直属课程学分和——板块标注学分含子板块，照抄会重复计费。
/// 课程挂在其所在 section（即模块）；course_id 用 PDF 课程号（与成绩单同源于
/// 教务，精确匹配命中率最高）；名称差异由 engine/matching.dart 以相似度 ≥0.85 兜底。
///
/// 「N门」子规则板块（#12 尾）：creditsRaw 里的数字是**门数不是学分**，绝不
/// 计入 required_credits。0 课程的门规则板块（如「至少修读1门通识核心课程」，
/// 课在别处）直接不成模块——修复前它以 required=1.0 计入 totals 并因无课
/// 恒报红「延毕风险」；带课程表的门规则板块（如「博雅技艺」下 4 门大学写作）
/// 课程表并入最近上级学分板块（通识选修 10.5）核算——该上级板块自身标注
/// 学分恰是含这些课的总额，门规则本身 0 学分要求，totals.required 不会高于
/// 父板块标注。仅当无可用上级（顶层门规则 / 上级被丢弃）才自建 required=0
/// 模块保课程可匹配（count_rule: true 标记）。
///
/// 认定类板块（#13）：美育/劳育/创新创业/心理健康（level≤3 标题命中）即使
/// creditsRaw 与课程表皆空也保留为模块，required_credits 取说明「修读N学分」
/// 抽出的 N（抽不到记 0，如劳育「32学时」）；[transcript] 中未命中任何方案
/// 课程且 [certifiedCategoryOf] 命中的行，作为课程挂进对应认定模块（credits 用
/// 成绩单学分），使 AuditEngine 能对该类累加 earned。
///
/// meta.total_credits：[totalCredits] 缺省时取全部保留模块 required_credits 之和
/// （与 AuditEngine totals.required 同口径，二者严格相等）。
///
/// 永不抛异常；[ps] 为空时返回结构完整的空 PlanFile。
Map<String, dynamic> planFileFromPdf(
  PlanPdfSections ps, {
  required String major,
  required String grade,
  double? totalCredits,
  String? sourceDoc,
  List<Map<String, dynamic>> transcript = const [],
}) {
  final flags = keptSectionFlags(ps);
  final kept = List<bool>.of(flags);
  final modules = <Map<String, dynamic>>[];
  final courses = <Map<String, dynamic>>[];
  final takenIds = <String>{};
  var requiredSum = 0.0; // 与审计 totals.required 同口径（total_credits 兜底）
  final mixedTitles = <String>[]; // 混合父板块（要求改按直属课程和计），如实上报

  // 「门」规则板块课程的家：并入最近可用的上级学分板块；并入不了（无祖先 /
  // 祖先被丢弃）的自建 required 0 模块，保证课程不丢、可被成绩单匹配。
  final countHome = <int, int>{}; // 门规则板块下标 → 上级板块下标
  final countOrphans = <int>[];
  for (var i = 0; i < ps.sections.length; i++) {
    final s = ps.sections[i];
    if (!s.isCountRule || s.courses.isEmpty) continue;
    final home = _nearestCreditAncestorIndex(ps, i);
    if (home != null && flags[home]) {
      countHome[i] = home;
    } else {
      countOrphans.add(i);
    }
  }

  for (var i = 0; i < ps.sections.length; i++) {
    if (!flags[i]) continue;
    final s = ps.sections[i];
    final mixed = _hasKeptDescendant(ps, i, kept);
    // 「门」规则板块的课程表并入本板块核算（上级学分板块标注含这部分课）
    final ownCourses = <PdfCourseRow>[
      ...s.courses,
      for (final e in countHome.entries)
        if (e.value == i) ...ps.sections[e.key].courses,
    ];
    final certified = certifiedSectionCategory(s);
    // 混合父板块的标注学分（如 30）是含子板块的总额，只按直属课程和计要求；
    // 叶子板块按标注首数字段（'3-6'→3，下限口径不变）。认定类板块无学分标注
    // 时从说明「要求学生修读N学分」抽（抽不到 0）；「门」板块绝不取 creditsRaw
    // （数字是门数，keptSectionFlags 已保证其不成模块，此处按 0 防御）。
    final double requiredCredits;
    if (s.isCountRule) {
      requiredCredits = 0.0;
    } else if (mixed) {
      requiredCredits =
          ownCourses.fold<double>(0, (a, c) => a + c.credits);
    } else if (certified != null && s.creditsRaw.trim().isEmpty) {
      requiredCredits = certifiedRequiredCredits(s.notes);
    } else {
      requiredCredits = requiredCreditsFrom(s.creditsRaw);
    }
    if (mixed && s.creditsRaw.trim().isNotEmpty) mixedTitles.add(s.title);
    requiredSum += requiredCredits;

    final moduleId = uniqueSlug(moduleSlug(s.title, i), takenIds);
    final courseIds = <String>[];
    for (final c in ownCourses) {
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
      // 认定类板块把自身标题纳入路径末段：coursesCategoryMap/学分看板按
      // module_path 末段取类别，末段必须是类别名（心理健康类）而非桶标题。
      'module_path': certified == null
          ? modulePathOf(s)
          : (s.parentPath.isEmpty ? s.title : '${s.parentPath} · ${s.title}'),
      'required_credits': requiredCredits,
      'course_ids': courseIds,
      // 展示/后续审计用的附加信息（AuditEngine.build() 不读取，不影响其计算）：
      'title': s.title,
      'level': s.level,
      'notes': s.notes,
      if (rule != null) 'choice_rule': rule.toJson(),
      if (alt != null) 'alternative': alt.toJson(),
      if (certified != null) 'certified_category': certified,
      if (s.isCountRule) 'count_rule': true,
    });
  }

  // 0 学分自建模块：上级不可用的「门」规则板块（保课程可匹配，不虚增要求）
  for (final i in countOrphans) {
    final s = ps.sections[i];
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
    modules.add(<String, dynamic>{
      'module_id': moduleId,
      'module_path': modulePathOf(s),
      'required_credits': 0.0,
      'course_ids': courseIds,
      'title': s.title,
      'level': s.level,
      'notes': s.notes,
      'count_rule': true,
    });
  }

  // 成绩单归位（#13）：未命中任何方案课程的行，certifiedCategoryOf 命中认定类
  // 时挂进对应认定模块（credits 用成绩单学分）。审计侧 matchRecordToPlan 对同一
  // 份 courses 匹配 → 通过课自然累加进该模块 earned；未通过课匹配但不计分。
  // 匹配口径与审计完全一致（course_id 精确优先、名称相似度 ≥0.85 兜底）。
  final certModuleByCat = <String, Map<String, dynamic>>{
    for (final m in modules)
      if (m['certified_category'] is String) m['certified_category'] as String: m,
  };
  if (transcript.isNotEmpty && certModuleByCat.isNotEmpty) {
    // matchRecordToPlan 的名称兜底要求行 name 为 String（as String 直取），
    // 先过滤异常行：无名称/名称非字符串的一律不参与（宁缺勿猜，不抛异常）。
    final safeRows = <Map<String, dynamic>>[
      for (final r in transcript)
        if (r['name'] is String && (r['name'] as String).trim().isNotEmpty) r,
    ];
    if (safeRows.isNotEmpty) {
      final (_, unmatched) =
          matchRecordToPlan(safeRows, <String, dynamic>{'courses': courses});
      final usedIds = <String>{};
      for (final row in unmatched) {
        final name = (row['name'] as String).trim();
        final cat = certifiedCategoryOf(name);
        if (cat == null) continue;
        final mod = certModuleByCat[cat];
        if (mod == null) continue;
        final cid = row['course_id'] == null ? name : '${row['course_id']}';
        if (!usedIds.add(cid)) continue; // 重修同名课只挂一次
        final cr = row['credits'];
        (mod['course_ids'] as List<String>).add(cid);
        courses.add(<String, dynamic>{
          'course_id': cid,
          'name': name,
          'credits': cr is num && cr > 0 ? cr.toDouble() : 0.0,
          'module_id': mod['module_id'],
          'nature': '必修',
          'offered': null,
          'grade_cycle': null,
          'offered_years': null,
          'prereq': <String>[],
          'source': <String, dynamic>{'page': ''},
        });
      }
    }
  }

  // total_credits 缺省兜底：直接取保留模块 required_credits 之和——与
  // AuditEngine totals.required 完全同口径（叶子优先后不存在父子重复计）。
  final hasCertified = certModuleByCat.isNotEmpty;
  final quality = <String>[
    ...ps.qualityNotes,
    '课程清单来自官方培养方案 PDF 解析（${modules.length} 个板块 / '
        '${courses.length} 门课程）；「至少N门/二选一」等约束见各板块说明',
    '板块取舍叶子优先：父板块学分标注是包含关系，不再单独计入总学分，'
        '层级由子板块 module_path（「 · 」全路径）体现',
    '板块要求学分取标注首个数字段（区间如“3-6”按下限计）；'
        '「以下N种模块中的一种」等并列可选板块按各自学分单独核算，满足其一即可',
    '「至少修读N门」子规则的门数不是学分：不据此计应修学分（修复前会虚增'
        '应修总量并误报延毕风险）；带课程表的并入上级学分板块核算',
    if (hasCertified)
      '认定类板块（美育/劳育/创新创业/心理健康）在 PDF 中无课程表，要求学分取'
          '说明「要求学生修读N学分」（抽不到记 0）；成绩单同类课程已归入对应认定模块',
    if (mixedTitles.isNotEmpty)
      '${mixedTitles.join('、')}同时含直属课程与子板块，要求学分按其直属课程'
          '学分和计（板块标注为含子板块的总额，照抄会重复计费）',
  ];

  return <String, dynamic>{
    'meta': <String, dynamic>{
      'major': major,
      'grade': grade,
      'source_doc': (sourceDoc == null || sourceDoc.trim().isEmpty)
          ? '培养方案 PDF 解析（教务 zdbk 官方方案）'
          : sourceDoc,
      'total_credits': totalCredits ?? requiredSum,
      'extracted_by': 'engine/plan_audit_adapter.planFileFromPdf',
      'verified': false,
      'quality': quality,
    },
    'modules': modules,
    'courses': courses,
  };
}

/// [ps] 中 [s]（下标 [i]）的直接子板块（parentPath == s.label）。
List<PdfModuleSection> _childrenOf(PlanPdfSections ps, int i) {
  final label = ps.sections[i].label;
  return [
    for (var j = 0; j < ps.sections.length; j++)
      if (j != i && ps.sections[j].parentPath == label) ps.sections[j]
  ];
}

// ── 课程类别打通（学分看板「未分类」修复，任务数据流见文件头注释）──────────

/// module_path → 类别末段：「 · 」与 '/' 都是层级分隔符（两套方案口径都兼容）。
/// '通识课程 · 通识必修课程 · 思政类' → '思政类'；'通识教育/通识必修' → '通识必修'；
/// '集中实践' → '集中实践'；空 / 纯分隔符 → ''（宁缺勿猜，调用方保持「未分类」）。
String tailCategory(String path) {
  final segs = path
      .split(RegExp('[·/]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  return segs.isEmpty ? '' : segs.last;
}

/// 成绩单课程 → 方案板块类别映射（纯函数，可脱离 Flutter 页面单测）。
/// 复用 engine/matching.dart 的 matchRecordToPlan（与审计完全同一匹配口径：
/// course_id 精确优先、名称相似度 ≥0.85 兜底），把匹配到的方案课程所属模块
/// module_path 末段作为该成绩单课程名的类别。同名课程取首个命中（重修课
/// 归属同一板块，先后无差）；无匹配或末段为空则不进映射。
/// 防御：方案缺 courses/modules、行既无名称也无法精确命中、元素形态不符——
/// 一律滤掉返回空映射，绝不抛异常（宁缺勿猜）。
Map<String, String> coursesCategoryMap(
    List<Map<String, dynamic>> courses, Map<String, dynamic> plan) {
  final pathByModule = <String, String>{};
  final mods = plan['modules'];
  if (mods is List) {
    for (final m in mods) {
      if (m is Map && m['module_id'] != null) {
        pathByModule['${m['module_id']}'] = '${m['module_path'] ?? ''}';
      }
    }
  }
  final raw = plan['courses'];
  if (raw is! List || courses.isEmpty) return const {};
  final planCourses = <Map<String, dynamic>>[
    for (final c in raw)
      if (c is Map<String, dynamic>) c,
  ];
  if (planCourses.isEmpty) return const {};
  // 行必须有可判同性的键（名称，或能精确命中方案的 course_id）——
  // matchRecordToPlan 的名称兜底会对 null 名称抛类型错，先滤掉。
  final planIds = <String>{
    for (final c in planCourses)
      if (c['course_id'] != null) '${c['course_id']}',
  };
  final safe = <Map<String, dynamic>>[
    for (final r in courses)
      if ('${r['name'] ?? ''}'.trim().isNotEmpty ||
          (r['course_id'] != null && planIds.contains('${r['course_id']}')))
        r,
  ];
  if (safe.isEmpty) return const {};
  // matchRecordToPlan 只读 plan['courses']；传净化副本避免懒 cast 遇脏元素抛错。
  final (matched, _) = matchRecordToPlan(
      safe, <String, dynamic>{...plan, 'courses': planCourses});
  final out = <String, String>{};
  for (final pair in matched) {
    final row = pair[0] as Map<String, dynamic>;
    final c = pair[1] as Map<String, dynamic>;
    final mid = c['module_id'];
    final cat = tailCategory(mid == null ? '' : (pathByModule['$mid'] ?? ''));
    final name = '${row['name'] ?? ''}'.trim();
    if (cat.isEmpty || name.isEmpty) continue;
    out.putIfAbsent(name, () => cat);
  }
  return out;
}

/// 展示链路类别补全：就地改写 [courses] 各行的 category，返回补全条数。
/// 只补空 /「未分类」的行，绝不覆盖教务自带的 kcxzmc 类别；无匹配不动。
/// 调用时机（main.dart _runAudit）：审计报告已算完，此处改写只影响展示链路
/// （学业页学分看板）与随后 _saveSession 落盘的会话缓存。
///
/// 两路兜底顺序：
///  1. 方案板块匹配（coursesCategoryMap，与审计同口径）——主路径；
///  2. 认定类关键词（certifiedCategoryOf，#13）——当行未出现在任何方案模块的
///     匹配结果里（方案外/认定类课，如「大学生心理适应与发展」）时，按关键词
///     归入心理健康/美育/创新创业/劳育。认定类词表专指性强，命中才补、宁缺勿猜。
int applyPlanCategories(
    List<Map<String, dynamic>> courses, Map<String, dynamic> plan) {
  final byName = coursesCategoryMap(courses, plan);
  var filled = 0;
  for (final c in courses) {
    final cur = '${c['category'] ?? ''}'.trim();
    if (cur.isNotEmpty && cur != '未分类') continue;
    final name = '${c['name'] ?? ''}'.trim();
    final cat = byName[name];
    if (cat == null || cat.isEmpty) {
      // 第二路：方案模块未命中（name 不在匹配结果里）→ 认定类关键词归类。
      final certified = certifiedCategoryOf(name);
      if (certified == null) continue;
      c['category'] = certified;
    } else {
      c['category'] = cat;
    }
    filled++;
  }
  return filled;
}
