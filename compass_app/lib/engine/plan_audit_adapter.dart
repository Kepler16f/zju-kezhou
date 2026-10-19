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
import 'cache_versions.dart' show kPlanBuilderVersion;
import 'matching.dart' show matchRecordToPlan;

// ── 结果对象 ────────────────────────────────────────────────────────────────

/// 板块说明里识别出的「修读选择约束」（二选一 / N 选 M / 至少 X 门 / 至少 Y 学分）。
class ChoiceRule {
  final String text; // 命中的原文片段（多个片段以「；」连接）
  final double? minCredits; // 「至少修读Y学分」
  final int? minCourses; // 「至少修读X门」，或 N 选 M 的 M
  final int? pickFrom; // 「N 选 M」的 N（二选一 → 2）

  /// 「多选一 / 任选其一 / 只选一门」：单门成组——选 1 门即整个模块达成，
  /// 要求学分按最便宜的一门折算（用户反馈 #3，不把整组学分全部相加）。
  final bool singlePick;

  const ChoiceRule({
    required this.text,
    this.minCredits,
    this.minCourses,
    this.pickFrom,
    this.singlePick = false,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'text': text,
        'min_credits': minCredits,
        'min_courses': minCourses,
        'pick_from': pickFrom,
        'single_pick': singlePick,
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

/// 关键词词表（带特异性权重）：从真实方案说明文本抽取（2026 级浙大方案各认定类
/// 「要求学生修读…课程。可修读……课程清单」句），宁缺勿猜、误归类比不归类更糟。
/// #5（2026-10-18 修正混类）：用户反馈「心理健康类和军体类不是一回事，美育类和
/// 劳育类不是一回事」，且此前「民乐演奏」被归错。旧实现是「纯 contains + 写死
/// 优先级取第一个命中」，泛词（实践/服务/教育/创新/训练…）与心理健康排最前共同
/// 造成 心理吃军体、劳育吃美育/创新创业。现改为**特异性计分**：
///  * 权重 3 = 类专属名词（军事/国防/军训→军体；心理→心理健康；劳动/农事/
///    耕读/志愿服务→劳育；音乐/美术/书法/戏剧/舞蹈/民乐/审美→美育…），
///    权重 2 = 次专属复合词（演奏/演唱/篆刻/摄影/体能/志愿…），
///    每类得分 = 命中词权重求和（同类多词命中互相加强）；
///  * 泛化词一律**不收**：裸「实践」（社会实践/生产实习/「新时代实践教育」误吸
///    面太大，用「实践劳动」式复合词或直接靠「劳动」覆盖）、裸「服务」、裸
///    「教育」、裸「创新」（「创新设计」属专业课）、裸「训练」、裸「文艺」
///    （「文艺学」属中文专业课）、裸「运动」（运动训练/运动解剖歧义大，宁缺勿猜）。
/// 各类词面要点：
///  * 心理健康：仅「心理」即覆盖「心理健康/心理咨询」等（「心理健康」是其子串，
///    不必单列；「适应与发展」泛化，删——「大学生心理适应与发展」靠「心理」命中）。
///  * 军体类（#1）：体育/军训/军事/国防/体质/体测；「军体」为类别名干词，供
///    成绩单 category 字符串（如「军体类」）回环认同。
///  * 思政类（#1）：与军体分桶——军事理论/军训归军体不归思政；「思政」为类别名
///    干词（回环同上）。
///  * 美育类：补「民乐/器乐/声乐/绘画/美学/影视/戏曲」；「民乐演奏」此前无任何
///    词命中（「音乐」不含「民乐」）而漏归/被别类捡走，即用户反馈的直接案例。
///  * 创新创业：创新创业/创业/创新训练/大创；不收裸「创新」。
///  * 劳育：劳动/劳育/农事/耕读/志愿服务（复合「志愿」降权 2）；不收裸「实践」。
/// 纯函数、不抛异常；任何词都不命中返回 null（宁缺勿猜）。
const _certifiedKeywords = <String, Map<String, int>>{
  '心理健康类': {'心理': 3},
  '军体类': {
    '体育': 3, '军事': 3, '国防': 3, '军训': 3, '体质': 3, '体测': 3,
    '军体': 3, '体能': 2,
  },
  '思政类': {
    '思想政治': 3, '思政': 3, '马克思主义': 3, '毛泽东思想': 3, '习近平': 3,
    '思想道德': 3, '道德与法治': 3, '近现代史': 3, '形势与政策': 3,
  },
  '美育类': {
    '艺术': 3, '美术': 3, '音乐': 3, '民乐': 3, '器乐': 3, '声乐': 3,
    '绘画': 3, '书法': 3, '戏剧': 3, '戏曲': 3, '舞蹈': 3, '影视': 3,
    '审美': 3, '美学': 3, '美育': 3, '演奏': 2, '演唱': 2, '篆刻': 2,
    '摄影': 2,
  },
  '创新创业类': {'创新创业': 3, '创业': 3, '创新训练': 3, '大创': 3},
  '劳育类': {'劳动': 3, '劳育': 3, '农事': 3, '耕读': 3, '志愿服务': 3, '志愿': 2},
};

/// 认定类别名集合（课程名纠正只允许在板块类别本身也是认定类时生效，
/// 见 coursesCategoryMap #1 修正版注释）。
const Set<String> _certifiedCategoryValues = {
  '心理健康类', '军体类', '思政类', '美育类', '创新创业类', '劳育类',
};

/// 特异性并列时的兜底优先级（写死顺序、可测）：心理健康 > 军体 > 思政 > 美育 >
/// 创新创业 > 劳育。心理健康/军体/思政分列前三，确保「心理健康类和军体类不是一
/// 回事」（#5）；劳育词面最宽放最后。**仅当两类得分完全并列时才按此序取先**，
/// 不再无条件按表序取第一个命中（旧口径 心理吃军体、劳育吃美育的根因）。
const List<String> _certifiedTiePriority = [
  '心理健康类', '军体类', '思政类', '美育类', '创新创业类', '劳育类',
];

/// 纯函数：按 [_certifiedKeywords] 权重计分归类——每类得分 = 课名命中该类
/// 各关键词的权重之和（类专属名词 3 分 > 次专属复合词 2 分，多词命中叠加）。
/// 取最高分对应类别；**得分并列**时按 [_certifiedTiePriority] 兜底，仍无并列
/// 之外的确定性则取词表序最前者；无任何命中返回 null（宁缺勿猜、不抛异常）。
/// 调用方（coursesCategoryMap / applyPlanCategories / 页面 certifiedRowsForSection）
/// 签名与返回类型不变。
String? certifiedCategoryOf(String courseName) {
  final n = courseName.trim();
  if (n.isEmpty) return null;
  var bestScore = 0;
  final best = <String>[]; // 并列最高分的类别（按词表序）
  for (final entry in _certifiedKeywords.entries) {
    // 先收集该类命中的关键词，再剔除「被同类另一命中词包含」的子串词
    //（如「创业」⊂「创新创业」、「志愿」⊂「志愿服务」）：否则复合词与其子串
    // 叠加抬高该类分数，会压过本该并列的对手类（#5 回归：艺术与创新创业 曾被
    // 误判创新创业类）。去重后每类得分 = 互不包含的命中词权重之和。
    final hit = <String, int>{
      for (final kw in entry.value.entries)
        if (n.contains(kw.key)) kw.key: kw.value,
    };
    if (hit.isEmpty) continue;
    var score = 0;
    for (final e in hit.entries) {
      if (hit.keys.any((o) => o != e.key && o.contains(e.key))) continue;
      score += e.value;
    }
    if (score == 0) continue;
    if (score > bestScore) {
      bestScore = score;
      best
        ..clear()
        ..add(entry.key);
    } else if (score == bestScore) {
      best.add(entry.key);
    }
  }
  if (best.isEmpty) return null;
  if (best.length == 1) return best.single;
  for (final cat in _certifiedTiePriority) {
    if (best.contains(cat)) return cat;
  }
  return best.first;
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

/// 板块自身是否没有实质内容（用户反馈 #3）：无课程、无学分标注、非认定类。
///
/// 2026 级方案 PDF 开头 12 条「工程知识：…」「分析问题：…」是毕业要求条目，
/// 解析器按层级行识别后成了无课程、无学分、无子块的顶层块。UI 只对「无子块」
/// 且命中本判据的节点做展示剔除；认定类板块虽无课表但有要求学分，必须保留。
/// 纯函数可单测。
bool isContentlessSection(PdfModuleSection s) =>
    s.courses.isEmpty &&
    s.creditsRaw.trim().isEmpty &&
    certifiedSectionCategory(s) == null;

/// 认定类板块说明 → 要求学分：优先抽「（要求学生）修读N学分」里的 N；
/// 只有学时（劳育类「要求学生修读32学时」）时按 16 学时 = 1 学分换算；
/// 都抽不到记 0。纯函数、不抛异常。
double certifiedRequiredCredits(List<String> notes) {
  final text = notes.join('\n');
  final m = RegExp(r'修读\s*([\d.]+)\s*学分').firstMatch(text);
  if (m != null) return double.tryParse(m.group(1)!) ?? 0.0;
  final h = RegExp(r'修读\s*([\d.]+)\s*学时').firstMatch(text);
  final hours = h == null ? null : double.tryParse(h.group(1)!);
  if (hours == null || hours <= 0) return 0.0;
  return double.parse((hours / 16).toStringAsFixed(2));
}

/// module_path：培养方案板块的完整路径（含自身标题）。
/// 关键：必须包含自身 title，否则同一父板块下的「必修课程」「选修课程」会
/// 得到完全相同的路径，报告里出现看似重复的行（军体类/通识必修的常见现场）。
String modulePathOf(PdfModuleSection s) => s.label;

const Set<String> _genericSectionTitles = <String>{
  '必修课程',
  '选修课程',
  '选择性必修课程',
  '限选课程',
  '任选课程',
  '必修',
  '选修',
  '本类',
};

bool _isGenericSectionTitle(String title) {
  final t = title.trim();
  if (t.isEmpty) return true;
  if (_genericSectionTitles.contains(t)) return true;
  if (t.contains('至少修读')) return true;
  if (RegExp(r'\d+\s*选\s*\d+').hasMatch(t)) return true;
  if (t.endsWith('门') && t.length <= 40) return true;
  return false;
}

/// 课程名多数派认定的类别（军体/思政/美育/劳育…）：至少 2 门且占比 ≥60%。
/// 用于纠正「板块标题漏识别导致课程并块」——军体课落进思政类、劳育课落进
/// 美育类时，课程名多数派能把类别改回正确值（#1）。
String? _dominantCertifiedCategory(List<PdfCourseRow> courses) {
  if (courses.length < 2) return null;
  final counts = <String, int>{};
  var hits = 0;
  for (final c in courses) {
    final cat = certifiedCategoryOf(c.name);
    if (cat == null) continue;
    counts[cat] = (counts[cat] ?? 0) + 1;
    hits++;
  }
  if (hits == 0) return null;
  final best = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
  if (best.value < 2 || best.value * 10 < courses.length * 6) return null;
  return best.key;
}

/// 板块标题是否本身就是类别名（「思政类」「军体类」「美育类」…）。
bool _isCategoryTitle(String title) {
  final t = title.trim();
  if (t.isEmpty) return false;
  if (_certifiedKeywords.containsKey(t)) return true;
  if (RegExp(r'类$').hasMatch(t) && t.length <= 12) return true;
  return false;
}

/// 模块类别：优先认定类关键词，其次自身标题（level<=3 且非泛化规则），
/// 最后沿 parentPath 从深到浅找最近的非泛化段。
/// 这样报告路径可以是完整 `s.label`，学分看板类别仍落在「军体类/思政类」。
/// 标题与课程名多数派冲突时以课程为准（#1：军体/思政、美育/劳育不再并桶）。
String categoryOfSection(PdfModuleSection s, String? certified) {
  if (certified != null) return certified;
  final byCourse = _dominantCertifiedCategory(s.courses);
  final title = s.title.trim();
  if (_isCategoryTitle(title)) {
    if (byCourse != null && byCourse != title) return byCourse;
    return title;
  }
  if (s.level <= 3 && !_isGenericSectionTitle(title)) return title;
  if (byCourse != null) return byCourse;
  final segments = s.parentPath
      .split(' · ')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  for (var i = segments.length - 1; i >= 0; i--) {
    if (!_isGenericSectionTitle(segments[i])) return segments[i];
  }
  return s.title;
}

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

  // #3：「多选一 / 任选其一 / 只选一门」= 选一门即满足整个模块。
  // 不能退化成裸「任选」前缀——「任意选修」不是数量约束
  // （test/engine_audit_test.dart 有反例守护）。
  var singlePick = false;
  final one = RegExp(r'(多选一|任选其一|任选一门|只选一门|选择其中一门|选其中一门)')
      .firstMatch(text);
  if (one != null) {
    singlePick = true;
  } else {
    final pickN =
        RegExp('(?:任选|只选|选择其中)\\s*($_cnNum)\\s*门').firstMatch(text);
    final n = pickN == null ? null : _parseCount(pickN.group(1)!);
    if (n == 1) singlePick = true;
  }
  if (singlePick) {
    if (minCourses == null) minCourses = 1;
    fragments.add(one?.group(0) ?? '任选1门');
  }

  if (fragments.isEmpty) return null;
  return ChoiceRule(
    text: fragments.join('；'),
    minCredits: minCredits,
    minCourses: minCourses,
    pickFrom: pickFrom,
    singlePick: singlePick,
  );
}

/// 板块说明命中「以下 N 种模块中的一种」→ 返回并行可选信号（含 optionCount，N≥2）；
/// 否则 null。[siblings] 为该板块的直接子板块（并列选项，满足其一即可，诉求 #11）。
///
/// v1.5（任务 #8 三选一断链修复）识别走「notes 关键词 + title 关键词」双路：
///  * 第一路（原有）：模块级句式说明（「以下N种模块中的一种」等）；
///  * 第二路（新增）：直接子板块名命中 [_altOptionTitlePattern] ≥2 个——浙大
///    「个性修读」三选一（本专业进阶 / 跨专业学习（微辅修）/ 学生自主修读）在
///    方案 JSON / 解析摘要里常常只有并列板块名、没有任选句式说明，旧口径因
///    缺这一路而从未成组（缺口 ×3 重复计算的根因之一）。
AlternativeSignal? detectAlternativeModules(
    List<PdfModuleSection> siblings, String parentNotes) {
  final text = parentNotes.trim();
  String? hit;
  int? declared;
  if (text.isNotEmpty) {
    // 模块级句式（必须出现「模块」二字，避免把「本组课程多选一」这类
    // 课程级规则误升级成模块级并列选项）：
    //  * 以下 N 种/个模块中的一种
    //  * 以下 N 个模块（中）任选其一 / 任选一个
    //  * 三个模块任选其一 / 多选一 / 只选一个
    final patterns = <RegExp>[
      RegExp('以下\\s*($_cnNum)\\s*(?:种|个)\\s*模块(?:中|里)?(?:的)?\\s*(?:一种|任选(?:其)?一|任选一个)'),
      RegExp('($_cnNum)\\s*(?:种|个)\\s*模块(?:中|里)?(?:任选|选择|选)\\s*(?:其)?一'),
      RegExp(r'模块.{0,12}(?:多选一|任选其一|任选一个|只选一个|选择一个模块)'),
      RegExp(r'(?:多选一|任选其一|任选一个模块|只选一个模块)'),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(text);
      if (m == null) continue;
      hit = m.group(0);
      if (m.groupCount >= 1) declared = _parseCount(m.group(1) ?? '');
      break;
    }
    if (hit != null && text.contains('模块')) {
      final n = declared ?? siblings.length;
      if (n >= 2 || siblings.length >= 2) {
        return AlternativeSignal(
          optionCount: n < 2 ? siblings.length : n,
          text: hit,
          optionTitles: siblings.map((s) => s.title).toList(),
        );
      }
    }
  }
  // 第二路：并列选项板块名（≥2 个直接子板块命中）。宁缺勿猜：单个命中
  // 不成组（「微辅修」单独出现可能只是辅修子块，非并列语义）。
  final altTitles = <String>[
    for (final s in siblings)
      if (_altOptionTitlePattern.hasMatch(s.title)) s.title.trim(),
  ];
  if (altTitles.length >= 2) {
    return AlternativeSignal(
      optionCount: siblings.length,
      text: '并列模块名（${altTitles.join('、')}）任选其一',
      optionTitles: siblings.map((s) => s.title).toList(),
    );
  }
  return null;
}

/// 三选一并列选项板块名模式（任务 #8 用户明确口径：本专业进阶/跨专业学习/
/// 学生自主修读应当三选一）。含「微辅修/个性化修读/个性修读」变体写法。
final RegExp _altOptionTitlePattern = RegExp(
    r'本专业进阶|跨专业学习|自主修读|微辅修|个性化修读|个性修读');

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
/// 「微辅修」独立板块判据（与 UI 的 isMinorElectiveSection 同口径）：
/// 标题或上级链命中「微辅修」。本专业方案末尾附的微辅修清单是面向其他专业
/// 学生的开班列表，不属于本人毕业要求，必须整支剔出审计（否则 12.5 学分
/// 会被计入应修）。例外见 [_dropStandaloneMinorSections]：作为三选一选项
/// （「跨专业学习模块 = 修读其他专业的微辅修」）出现时必须保留。
bool _isMinorSection(PdfModuleSection s) =>
    s.title.contains('微辅修') || s.parentPath.contains('微辅修');

/// 剔除独立微辅修板块（含子树），但保留并列选项组内的选项。
///
/// 用户口径（2026-10-19）：微辅修与「跨专业学习模块」是同一件事，跨专业
/// 学习就是修读其他专业的微辅修；三选一里的该选项必须保留并参与组内折算。
/// 只有不归属任何已识别选项组的微辅修板块（本专业给外专业开的清单）剔除。
List<bool> _dropStandaloneMinorSections(PlanPdfSections ps, List<bool> flags) {
  final n = ps.sections.length;
  final altOwned = List<bool>.filled(n, false);
  for (var i = 0; i < n; i++) {
    final kids = _childIndicesOf(ps, i);
    if (kids.length < 2) continue;
    final keptOptions = <int>[
      for (final j in kids)
        if (flags[j]) j,
    ];
    if (keptOptions.length < 2) continue;
    final signal = detectAlternativeModules(
      [for (final j in kids) ps.sections[j]],
      [
        ...ps.sections[i].notes,
        for (final j in kids) ...ps.sections[j].notes,
      ].join('\n'),
    );
    if (signal == null) continue;
    for (final root in keptOptions) {
      for (var k = 0; k < n; k++) {
        if (_isSelfOrDescendant(ps, k, root)) altOwned[k] = true;
      }
    }
  }
  final out = List<bool>.of(flags);
  for (var i = 0; i < n; i++) {
    if (!out[i] || altOwned[i] || !_isMinorSection(ps.sections[i])) continue;
    for (var k = 0; k < n; k++) {
      if (_isSelfOrDescendant(ps, k, i)) out[k] = false;
    }
  }
  return out;
}

/// 方案说明里的「最低毕业学分 N（+M）」声明值。教务方案摘要接口缺
/// zdbyxf 时（离线缓存/异形方案）按 PDF 原文兜底，避免把模块求和当成
/// 毕业总要求而虚增（如 148.5 被算成 167.5）。+M 是第二/三/四课堂附加分，
/// 由审计引擎按 practice 模块另行相加，这里只取基准 N。
double? declaredTotalFromNotes(PlanPdfSections ps) {
  for (final s in ps.sections) {
    for (final n in s.notes) {
      final m = RegExp(r'最低毕业学分\s*([\d.]+)(?:\s*\+\s*[\d.]+)?').firstMatch(n);
      if (m == null) continue;
      final v = double.tryParse(m.group(1)!);
      if (v != null && v > 0) return v;
    }
  }
  return null;
}

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
  return _dropStandaloneMinorSections(ps, kept);
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
  // 方案声明总学分优先用调用方值（教务摘要 zdbyxf），缺失时读 PDF 原文
  // 「最低毕业学分 148.5+8」的基准值；两者都没有才回落模块求和。
  final declaredTotal = totalCredits ?? declaredTotalFromNotes(ps);
  final kept = List<bool>.of(flags);
  final modules = <Map<String, dynamic>>[];
  final courses = <Map<String, dynamic>>[];
  final takenIds = <String>{};
  var requiredSum = 0.0; // 与审计 totals.required 同口径（total_credits 兜底）
  final mixedTitles = <String>[]; // 混合父板块（要求改按直属课程和计），如实上报

  // 模块 id 先按文档序一次性分配：并列选项组在父板块处出现，必须提前引用
  // 各选项子树的模块 id（主循环边生成边引用会取不到）。
  final moduleIds = <int, String>{};
  for (var i = 0; i < ps.sections.length; i++) {
    if (!flags[i]) continue;
    moduleIds[i] = uniqueSlug(moduleSlug(ps.sections[i].title, i), takenIds);
  }

  // 并列选项组（用户反馈 #4：本专业进阶模块 / 跨专业学习模块（微辅修）/
  // 学生自主修读模块 三选一）。识别信号是模块级说明（「以下N种模块中的一种」
  // 「三个模块任选其一」「多选一」），不是课程级「N选M」。
  // 组内各选项模块标 counts_toward_totals=false，由 AuditEngine 合成一条
  // 组行（取最优选项计一次），避免 20+20+20 被加成 60。
  final alternativeGroups = <Map<String, dynamic>>[];
  final altMarkers = <int, Map<String, dynamic>>{};
  for (var i = 0; i < ps.sections.length; i++) {
    final childIdx = _childIndicesOf(ps, i);
    if (childIdx.length < 2) continue;
    final keptOptions = <int>[
      for (final j in childIdx)
        if (flags[j]) j,
    ];
    if (keptOptions.length < 2) continue;
    final signal = detectAlternativeModules(
      [for (final j in childIdx) ps.sections[j]],
      [
        ...ps.sections[i].notes,
        for (final j in childIdx) ...ps.sections[j].notes,
      ].join('\n'),
    );
    if (signal == null) continue;
    final parent = ps.sections[i];
    final groupId = '${moduleIds[i] ?? moduleSlug(parent.title, i)}-alt';
    final declared = requiredCreditsFrom(parent.creditsRaw);
    final optionReq = <double>[
      for (final j in keptOptions) requiredCreditsFrom(ps.sections[j].creditsRaw),
    ];
    final groupRequired = declared > 0
        ? declared
        : optionReq.isEmpty
            ? 0.0
            : optionReq.reduce((a, b) => a > b ? a : b);
    final options = <Map<String, dynamic>>[];
    for (var k = 0; k < keptOptions.length; k++) {
      final root = keptOptions[k];
      final rootSec = ps.sections[root];
      final ids = <String>[];
      for (final e in moduleIds.entries) {
        if (!_isSelfOrDescendant(ps, e.key, root)) continue;
        ids.add(e.value);
        altMarkers[e.key] = <String, dynamic>{
          'alternative_group_id': groupId,
          'alternative_group_path': parent.label,
          'alternative_group_required': groupRequired,
          'alternative_option_index': k,
          'alternative_option_count': keptOptions.length,
          'alternative_option_title': rootSec.title,
          'counts_toward_totals': false,
        };
      }
      options.add(<String, dynamic>{
        'title': rootSec.title,
        'required_credits': requiredCreditsFrom(rootSec.creditsRaw),
        'module_ids': ids,
      });
    }
    alternativeGroups.add(<String, dynamic>{
      'group_id': groupId,
      'title': parent.title,
      'path': parent.label,
      'required_credits': groupRequired,
      'option_count': keptOptions.length,
      'declared_option_count': signal.optionCount,
      'options': options,
    });
  }

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
    // 最深板块优先：同一课程同时出现在父板块与子板块课程表时，归子板块
    // （父板块只按剩余直属课程计要求，避免父子重复计费）。
    final ownCourses = <PdfCourseRow>[
      for (final c in s.courses)
        if (!_claimedByKeptDescendant(ps, flags, i, c)) c,
      for (final e in countHome.entries)
        if (e.value == i) ...ps.sections[e.key].courses,
    ];
    final certified = certifiedSectionCategory(s);
    final rule = detectChoiceRule(s.notes.join('\n'));
    // 混合父板块的标注学分（如 30）是含子板块的总额，只按直属课程和计要求；
    // 叶子板块按标注首数字段（'3-6'→3，下限口径不变）。认定类板块无学分标注
    // 时从说明「要求学生修读N学分」抽（抽不到 0）；「门」板块绝不取 creditsRaw
    // （数字是门数，keptSectionFlags 已保证其不成模块，此处按 0 防御）。
    var requiredCredits = 0.0;
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
    // 「多选一 / 任选其一」：选 1 门即满足整个模块，要求学分只按最便宜的
    // 一门折算（#3）；标注若偏大，照抄会把已达成的模块误报缺口。
    if (rule?.singlePick == true && rule?.minCourses == 1) {
      var cheapest = double.infinity;
      for (final c in ownCourses) {
        if (c.credits > 0 && c.credits < cheapest) cheapest = c.credits;
      }
      if (cheapest.isFinite && cheapest < requiredCredits) {
        requiredCredits = cheapest;
      }
    }
    // 父板块直属课程全部被更深板块认领（且无自己的选择规则）：不再生成
    // 一个「有要求、无课程」的空模块，避免审计恒红（#3/#4 重复计费修复）。
    if (mixed && ownCourses.isEmpty && rule == null) continue;
    if (mixed && s.creditsRaw.trim().isNotEmpty) mixedTitles.add(s.title);
    requiredSum += requiredCredits;

    final moduleId = moduleIds[i]!;
    final courseIds = <String>[];
    final seenInModule = <String>{};
    for (final c in ownCourses) {
      final key = c.code.isNotEmpty ? c.code : c.name.trim();
      // 只在本模块内去重：同一课程多标签归属多个模块时按各模块分别计分
      // （v1.4 口径，跨模块重复交给审计的 memberships 处理）。
      if (key.isNotEmpty && !seenInModule.add(key)) continue;
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
    final children = _childrenOf(ps, i);
    final alt = detectAlternativeModules(children, notesJoined);
    final subRules = <Map<String, dynamic>>[
      for (final child in children)
        if (child.title.trim().isNotEmpty)
          <String, dynamic>{
            'title': child.title,
            'level': child.level,
            'credits_raw': child.creditsRaw,
            'credits_unit': child.isCountRule ? '门' : '学分',
            'notes': child.notes,
            if (detectChoiceRule(child.notes.join('\n')) != null)
              'choice_rule':
                  detectChoiceRule(child.notes.join('\n'))!.toJson(),
          },
    ];
    modules.add(<String, dynamic>{
      'module_id': moduleId,
      // 完整路径含自身标题：兄弟模块不再共享同一行文案。
      'module_path': modulePathOf(s),
      'category': categoryOfSection(s, certified),
      'required_credits': requiredCredits,
      'course_ids': courseIds,
      // 展示/后续审计用的附加信息（AuditEngine.build() 不读取，不影响其计算）：
      'title': s.title,
      'level': s.level,
      'notes': s.notes,
      'plan_credits_raw': s.creditsRaw,
      'plan_credits_unit': s.isCountRule ? '门' : '学分',
      if (subRules.isNotEmpty) 'sub_requirements': subRules,
      if (rule != null) 'choice_rule': rule.toJson(),
      if (alt != null) 'alternative': alt.toJson(),
      if (altMarkers[i] != null) ...altMarkers[i]!,
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

  // 全局去重：PDF 两栏排版/辅修段/非相邻重复都会产生相同 module_path 的模块。
  // 不去重时报告会出现两行同名板块，且 required 被重复计入 totals。
  final dedupedModules = <Map<String, dynamic>>[];
  final byPath = <String, Map<String, dynamic>>{};
  final moduleRemap = <String, String>{};
  for (final m in modules) {
    final path = '${m['module_path'] ?? ''}'.trim();
    final kept = byPath[path];
    if (kept == null) {
      byPath[path] = m;
      dedupedModules.add(m);
      continue;
    }
    final fromId = '${m['module_id']}';
    final toId = '${kept['module_id']}';
    if (fromId.isNotEmpty && fromId != toId) moduleRemap[fromId] = toId;
    final a = (kept['required_credits'] as num?)?.toDouble() ?? 0;
    final b = (m['required_credits'] as num?)?.toDouble() ?? 0;
    if (b > a) kept['required_credits'] = b;
    final keptIds = (kept['course_ids'] as List?)?.cast<String>() ?? <String>[];
    for (final id in (m['course_ids'] as List? ?? const [])) {
      final s = '$id';
      if (s.isNotEmpty && !keptIds.contains(s)) keptIds.add(s);
    }
    kept['course_ids'] = keptIds;
    final keptNotes = (kept['notes'] as List?)?.cast<String>() ?? <String>[];
    for (final n in (m['notes'] as List? ?? const [])) {
      final s = '$n';
      if (s.isNotEmpty && !keptNotes.contains(s)) keptNotes.add(s);
    }
    kept['notes'] = keptNotes;
    final keptSubs =
        (kept['sub_requirements'] as List?)?.cast<Map<String, dynamic>>() ??
            <Map<String, dynamic>>[];
    for (final r in (m['sub_requirements'] as List? ?? const [])) {
      if (r is Map) keptSubs.add(r.cast<String, dynamic>());
    }
    if (keptSubs.isNotEmpty) kept['sub_requirements'] = keptSubs;
  }
  if (moduleRemap.isNotEmpty) {
    for (final c in courses) {
      final to = moduleRemap['${c['module_id']}'];
      if (to != null) c['module_id'] = to;
    }
    modules
      ..clear()
      ..addAll(dedupedModules);
    for (final g in alternativeGroups) {
      final options = (g['options'] as List?) ?? const [];
      for (final o in options) {
        if (o is! Map) continue;
        final ids = (o['module_ids'] as List?) ?? const [];
        o['module_ids'] = <String>{
          for (final id in ids) moduleRemap['$id'] ?? '$id',
        }.toList();
      }
    }
  }

  // 并列选项组：组只计一次（组要求 + 组外模块），选项模块不再求和。
  if (alternativeGroups.isNotEmpty) {
    var sum = 0.0;
    for (final m in modules) {
      if (m['counts_toward_totals'] == false) continue;
      sum += (m['required_credits'] as num).toDouble();
    }
    for (final g in alternativeGroups) {
      sum += (g['required_credits'] as num?)?.toDouble() ?? 0;
    }
    requiredSum = sum;
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
        final cid = row['course_id'] == null ||
                '${row['course_id']}'.trim().isEmpty
            ? name
            : '${row['course_id']}';
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
    if (alternativeGroups.isNotEmpty)
      '${alternativeGroups.length} 组并列模块（任选其一）按组计一次要求学分：'
          '组内各选项不同时求和，达成度取最优选项',
  ];

  return <String, dynamic>{
    'meta': <String, dynamic>{
      'major': major,
      'grade': grade,
      'source_doc': (sourceDoc == null || sourceDoc.trim().isEmpty)
          ? '培养方案 PDF 解析（教务 zdbk 官方方案）'
          : sourceDoc,
      'total_credits': declaredTotal ?? requiredSum,
      'extracted_by': 'engine/plan_audit_adapter.planFileFromPdf',
      'builder_version': kPlanBuilderVersion,
      'verified': false,
      'quality': quality,
    },
    'modules': modules,
    'courses': courses,
    if (alternativeGroups.isNotEmpty) 'alternative_groups': alternativeGroups,
  };
}

/// [ps] 中板块 [i] 的直接子板块下标（parentPath == label）。
List<int> _childIndicesOf(PlanPdfSections ps, int i) {
  final label = ps.sections[i].label;
  return <int>[
    for (var j = 0; j < ps.sections.length; j++)
      if (j != i && ps.sections[j].parentPath == label) j,
  ];
}

/// [idx] 是否就是 [root] 或位于其子树内（用于并列选项组归属）。
bool _isSelfOrDescendant(PlanPdfSections ps, int idx, int root) {
  if (idx == root) return true;
  final label = ps.sections[root].label;
  final p = ps.sections[idx].parentPath;
  return p == label || p.startsWith('$label · ');
}

String _courseKey(PdfCourseRow c) => c.code.isNotEmpty ? c.code : c.name.trim();

/// 课程行是否已被某个**被保留的下级板块**认领（最深板块优先，防父子重复）。
bool _claimedByKeptDescendant(
    PlanPdfSections ps, List<bool> flags, int i, PdfCourseRow row) {
  final key = _courseKey(row);
  if (key.isEmpty) return false;
  final label = ps.sections[i].label;
  final prefix = '$label · ';
  for (var j = 0; j < ps.sections.length; j++) {
    if (j == i || !flags[j]) continue;
    final p = ps.sections[j].parentPath;
    if (p != label && !p.startsWith(prefix)) continue;
    for (final c in ps.sections[j].courses) {
      if (_courseKey(c) == key) return true;
    }
  }
  return false;
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
  final categoryByModule = <String, String>{};
  final mods = plan['modules'];
  if (mods is List) {
    for (final m in mods) {
      if (m is Map && m['module_id'] != null) {
        final mid = '${m['module_id']}';
        pathByModule[mid] = '${m['module_path'] ?? ''}';
        final cat = '${m['category'] ?? ''}'.trim();
        if (cat.isNotEmpty) categoryByModule[mid] = cat;
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
      if (c['course_id'] is String &&
          (c['course_id'] as String).trim().isNotEmpty)
        c['course_id'] as String,
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
    final category = mid == null ? '' : (categoryByModule['$mid'] ?? '');
    final cat = category.trim().isNotEmpty
        ? category
        : tailCategory(mid == null ? '' : (pathByModule['$mid'] ?? ''));
    final name = '${row['name'] ?? ''}'.trim();
    if (cat.isEmpty || name.isEmpty) continue;
    // #1（2026-10-18 修正版）：仅当板块类别**本身也是认定类值**时才用课程名纠正
    //（板块漏识别把军体课并进思政类、劳育课并进美育类的场景）；板块路径是明确
    // 结构类别（通识必修/专业核心…）时不拿课名覆盖——「思想道德与法治」属通识
    // 必修板块，不能被关键词拉成思政类（否则学分看板与旧口径双双漂移）。
    final refined = _certifiedCategoryValues.contains(cat)
        ? (certifiedCategoryOf(name) ?? cat)
        : cat;
    out.putIfAbsent(name, () => refined);
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
    final name = '${c['name'] ?? ''}'.trim();
    final cat = byName[name];
    final hasPlan = cat != null && cat.isNotEmpty;
    final needsFill = cur.isEmpty || cur == '未分类';
    // 旧缓存/旧解析把认定类标错（军训被标成心理健康类）：当前值本身是认定类
    // 且方案给出另一个认定类时允许纠正；教务自带的结构类别（通识必修等）
    // 与任意 kcxzmc 仍绝不覆盖。
    final fixCertified = _certifiedCategoryValues.contains(cur) &&
        hasPlan &&
        _certifiedCategoryValues.contains(cat) &&
        cat != cur;
    if (!needsFill && !fixCertified) continue;
    if (hasPlan) {
      // 主路：方案板块匹配结果（认定类板块的军体/思政纠正已在 coursesCategoryMap
      // 内完成，此处直接用）。板块给出明确类别即采信，不再拿课名覆盖结构类别。
      c['category'] = cat;
    } else {
      // 第二路：方案模块未命中（name 不在匹配结果里）→ 认定类关键词归类（#13）。
      final certified = certifiedCategoryOf(name);
      if (certified == null) continue;
      c['category'] = certified;
    }
    filled++;
  }
  return filled;
}
