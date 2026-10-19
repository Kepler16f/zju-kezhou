/// data/plan_pdf_parse.dart — 方案 PDF 文本 → 培养方案板块结构（纯函数，可单测）。
///
/// 输入：pdf_text_extractor 的字体感知 + 布局还原文本（zdbk 官方培养方案 PDF）。
/// 输出：四级板块树 + 每板块修读要求说明 + 各板块课程表，供「方案」页展示
/// 用户诉求的"各板块修读要求（含通识课程）"。
///
/// 版式（实测 2026 级食品科学与工程方案）：
/// ```
/// 一、通识课程                      72.5学分      ← 一级
/// 1.通识必修课程                    62学分         ← 二级
/// (1)思政类                        14学分          ← 三级
///    1)必修课程                    12学分           ← 四级（带课程表）
/// 课程号 课程名称 学分 周学时 总学时 建议学年学期     ← 表格头
/// MARX1004G 大学生思想文化素养 2.0 2.0-0.0 32 一(秋冬) ← 课程行
///    2)选修课程                    2学分
///     在思政类"选择性必修课程"中至少修读2学分，…       ← 修读要求（缩进正文）
/// ```
/// 规则：
///  - 层级行：中文序号 `一、` / `1.` / `(1)` / `1)`，以"…学分"收尾；
///    四级行也接受「…N门」收尾（通识选修的子修读规则行：数字是要求门数，
///    记入 creditsUnit='门'，上层按 isCountRule 区分）；
///  - 「…：N学分」行（微辅修/辅修专业）也识别为二级条目；
///  - 表格头之后、下一个层级行之前的课程号行归当前板块；
///  - 非表格区、非层级行的正文归当前板块的修读要求；
///  - 修读要求若提到紧随其后的板块名（PDF 双栏排版导致先出现），归后一板块；
///  - 到「培养方案修读指导性计划」为止（后面是按学年重排的同一批课程）。
library;

/// 一个板块（任意层级）。
class PdfModuleSection {
  final String title; // "思政类" / "必修课程"
  final int level; // 1-4；「：N学分」式条目记 2
  final String creditsRaw; // "12" / "3-6" / "+4" / ""（无学分声明）
  /// 修读数量单位：'学分'（默认）或 '门'。
  /// 四级「…N门」子规则行（通识选修的"至少修读N门…"）记 '门'，
  /// 此时 creditsRaw 里的数字是"要求门数"而非学分。
  final String creditsUnit;
  final String parentPath; // "通识课程 · 通识必修课程"（上级链，不含自身）
  final List<String> notes; // 修读要求说明
  final List<PdfCourseRow> courses; // 该板块课程表

  const PdfModuleSection({
    required this.title,
    required this.level,
    this.creditsRaw = '',
    this.creditsUnit = '学分',
    this.parentPath = '',
    this.notes = const [],
    this.courses = const [],
  });

  /// 数字学分（"3-6" 取 3、" +4" 取 4、无声明为 0）。
  /// 注意：isCountRule 为 true 时该数字是"要求门数"，不是学分。
  double get credits {
    final m = RegExp(r'\d+(?:\.\d+)?').firstMatch(creditsRaw);
    return m == null ? 0 : (double.tryParse(m.group(0)!) ?? 0);
  }

  /// 认定类板块（美育/劳育/创新创业/心理健康）要求：方案 PDF 把这类板块的
  /// 学分写在板块修读说明里（「要求学生修读2学分××类课程」），层级标题行
  /// 「(1)美育类」本身没有学分标注 → creditsRaw 恒为空，标题行显示不出学分
  /// （用户反馈 #6「其他必修环节学分没和其他模块一样样式的解析显示出来」）。
  /// 这里只读不改写 creditsRaw：审计适配器按自己的口径从说明抽数
  /// （plan_audit_adapter.certifiedRequiredCredits，正则同源），若改写
  /// creditsRaw 会使 keptSectionFlags/requiredCreditsFrom 两处口径漂移。
  /// 学时数字不认（劳育类「修读32学时」是学时不是学分）；isCountRule 板块
  /// （creditsRaw 是门数）返回 null，绝不冒充。
  String? get declaredCreditsFromNotes {
    if (isCountRule || creditsRaw.trim().isNotEmpty) return null;
    for (final n in notes) {
      final m = RegExp(r'修读\s*(\d+(?:\.\d+)?)\s*学分').firstMatch(n);
      if (m != null) return m.group(1);
    }
    return null;
  }

  /// 单位为「门」的子规则：credits 是"要求修读门数"而非学分。
  /// 上层审计/展示据此区分，勿把该数字直接当 required_credits 用。
  bool get isCountRule => creditsUnit == '门';

  String get label => parentPath.isEmpty ? title : '$parentPath · $title';
}

/// 一门课程（方案课程表行）。
class PdfCourseRow {
  final String code; // "MARX1004G"
  final String name; // "大学生思想文化素养"
  final double credits; // 2.0
  final String hours; // "2.0-0.0" / "+3" / ""
  final String semester; // "一(秋冬)" / ""
  const PdfCourseRow({
    required this.code,
    required this.name,
    required this.credits,
    this.hours = '',
    this.semester = '',
  });
}

/// 解析结果。
class PlanPdfSections {
  final List<PdfModuleSection> sections; // 文档顺序
  final List<String> qualityNotes;
  const PlanPdfSections({this.sections = const [], this.qualityNotes = const []});

  bool get isEmpty => sections.isEmpty;
  int get courseCount =>
      sections.fold(0, (n, s) => n + s.courses.length);
  /// 一级板块数（一、二、三…）。
  int get topCount => sections.where((s) => s.level == 1).length;
}

// ── 行级正则 ───────────────────────────────────────────────────────────────

/// 一级：`一、通识课程 72.5学分` / `五、其他必修环节（认定型学分）`（无学分）。
final _lvl1Re = RegExp(r'^[一二三四五六七八九十]+、\s*(.+?)(?:\s+([\d.+\-]+)\s*学分)?$');

/// 二级：`1.通识必修课程 62学分`。
final _lvl2Re = RegExp(r'^\d+\.\s*(\S.*?)\s+([\d.+\-]+)\s*学分$');

/// 三级：`(1)思政类 14学分` / `(1)美育类`（无学分）。
final _lvl3Re = RegExp(r'^\((\d+)\)\s*(.+?)(?:\s+([\d.+\-]+)\s*学分)?$');

/// 四级：`1)必修课程 12学分`；通识选修的子修读规则行 `1)至少修读1门通识核心课程 1门`
/// 也接受（以"N学分"或"N门"收尾；"门"单位时数字是要求门数，记入 creditsUnit）。
final _lvl4Re = RegExp(r'^(\d+)\)\s*(\S.*?)\s+([\d.+\-]+)\s*(学分|门)$');

/// 冒号式：`微辅修：12.5学分`。
final _colonRe = RegExp(r'^([^：:]{2,20})[：:]\s*([\d.+\-]+)\s*学分$');

/// 课程行：`MARX1004G 大学生思想文化素养 2.0 2.0-0.0 32 一(秋冬)`。
/// 学分之后的部分（周学时/总学时/学期）自由解析；无学期行（如耕读课程）也匹配。
/// 课程号前缀实测 2-6 位字母（CS1006G / ME1001F / MARX1004G），
/// 尾缀可能两位（荣誉课 H：MARX2004GH / CS1012GH）。
final _courseRe =
    RegExp(r'^([A-Z]{2,6}\d{4}[A-Z]{0,2})\s+(.+?)\s+(\d{1,2}(?:\.\d)?)\b\s*(.*)$');

/// 表格头行（进入表格区的标志）。
final _tableHeadRe = RegExp(r'^课程号\s+课程名称\s+学分');

/// 需整行忽略的标题行（注意：表格头"课程号 课程名称…"另行处理，不能在此吞掉）。
final _ignoreRe = RegExp(
    r'^(浙江大学\s*Zhejiang University|课程设置与学分分布|培养阶段课程结构图|'
    r'培养方案修读指导性计划|类别\s+课程号|类别\s+项目序号|'
    r'第[一二三四]学年|微辅修$)');

/// 复位标记：辅修段与正文培养方案无继承关系。
final _auxResetRe = RegExp(r'^辅修培养方案[：:]?$');

/// 终止标记：其后是"修读指导性计划"（按学年重排的重复课程表）。
final _stopRe = RegExp(r'^培养方案修读指导性计划$');

/// 标题行归一化（用户反馈 #1：军体类被并进思政类、劳育类被并进美育类）。
/// 实测方案 PDF 会用全角括号写标题与学分：`（2）军体类（8学分）`、
/// `1.通识必修课程（62学分）`。旧正则只认 `(2)军体类 8学分`（半角括号 +
/// 空格分隔的尾部学分），识别不了时该标题会落进正文说明，后续课程全部挂到
/// 上一个板块——于是军体课混进思政类、劳育课混进美育类。
/// 归一化只做两件事：全角括号转半角；把尾部 `（N学分）/（N门）` 改写成
/// ` N学分/N门`（与既有正则的尾部约定一致）。正文里的括号不受影响。
String _normalizeHeadingLine(String line) {
  var s = line.replaceAll('（', '(').replaceAll('）', ')');
  s = s.replaceAllMapped(
      RegExp(r'\(\s*([\d.+\-]+)\s*学分\s*\)'), (m) => ' ${m.group(1)}学分');
  s = s.replaceAllMapped(
      RegExp(r'\(\s*(\d+)\s*门\s*\)'), (m) => ' ${m.group(1)}门');
  return s;
}

// ── 解析 ──────────────────────────────────────────────────────────────────

/// 从布局还原文本解析培养方案板块结构。
PlanPdfSections parsePlanPdfText(String text) {
  final lines = text.split('\n');
  final sections = <PdfModuleSection>[];

  final titles = <int, String>{}; // level → 最近标题
  var curIndex = -1;
  var inTable = false;
  var pending = <String>[]; // 尚未落地归属的说明行
  final notesAcc = <int, List<String>>{};
  final coursesAcc = <int, List<PdfCourseRow>>{};

  // 提取一行里的层级信息（若有）。
  // 层级样式自适应：有的方案顶层用「一、」（2026 版），
  // 有的直接顶层就是「1.通识课程」（2025 及更早版，无中文序号）。
  // 没有「一、」时整体上移一级：1.→1 级、(1)→2 级、1)→3 级。
  final hasHanziTop = lines.any((l) {
    final m = _lvl1Re.firstMatch(l.trim());
    if (m == null) return false;
    final t = _cleanTitle(m.group(1)!);
    return t.length <= 16 && !RegExp(r'[。；，]').hasMatch(t);
  });
  final levelShift = hasHanziTop ? 0 : -1;

  ({String title, int level, String credits, String unit})? sectionOf(String line) {
    final l = _normalizeHeadingLine(line);
    var m = _lvl1Re.firstMatch(l);
    if (m != null) {
      final t = _cleanTitle(m.group(1)!);
      // 正文段落常以「一、……。……」开头（培养理念等），并非板块标题；
      // 标题不含句读、且长度有限，超过即拒。
      if (t.length > 16 || RegExp(r'[。；，]').hasMatch(t)) return null;
      // 无中文序号体系时，「一、」多是正文误报；真出现也按 2 级处理
      return (
        title: t,
        level: hasHanziTop ? 1 : 2,
        credits: (m.group(2) ?? '').trim(),
        unit: '学分',
      );
    }
    m = _lvl2Re.firstMatch(l);
    if (m != null) {
      return (
        title: _cleanTitle(m.group(1)!),
        level: 2 + levelShift,
        credits: m.group(2)!,
        unit: '学分',
      );
    }
    m = _colonRe.firstMatch(l);
    if (m != null) {
      return (
        title: _cleanTitle(m.group(1)!),
        level: 2 + levelShift,
        credits: m.group(2)!,
        unit: '学分',
      );
    }
    m = _lvl3Re.firstMatch(l);
    if (m != null) {
      return (
        title: _cleanTitle(m.group(2)!),
        level: 3 + levelShift,
        credits: (m.group(3) ?? '').trim(),
        unit: '学分',
      );
    }
    m = _lvl4Re.firstMatch(l);
    if (m != null) {
      final unit = m.group(4)!;
      final t = _cleanTitle(m.group(2)!);
      // 「…N门」子规则行防护：真实规则行整行短、标题无句读（。/，），
      // 以"N门"收尾的正文说明句（带句读或过长）不识别，宁缺勿猜。
      // （；与书名号在真实规则标题中出现，如"博雅技艺"类，不拒。）
      if (unit == '门' && (t.length > 60 || RegExp(r'[。，]').hasMatch(t))) {
        return null;
      }
      return (title: t, level: 4 + levelShift, credits: m.group(3)!, unit: unit);
    }
    return null;
  }

  /// 落地待定说明：提到新板块名的归新板块（双栏排版下说明先于标题出现），
  /// 其余留在上一板块（preIdx 为推入新板块之前的板块下标）。
  void flushPending(({String title, int level, String credits, String unit})? incoming, int preIdx) {
    if (pending.isEmpty) return;
    final newIdx = incoming == null ? -1 : sections.length - 1;
    for (final n in pending) {
      final toNew = incoming != null &&
          incoming.title.length >= 2 &&
          n.contains(incoming.title);
      final idx = toNew ? newIdx : preIdx;
      if (idx >= 0) (notesAcc[idx] ??= []).add(n);
    }
    pending = <String>[];
  }

  void pushSection(({String title, int level, String credits, String unit}) s) {
    final preIdx = curIndex;
    // 相邻重复条目（如同一"微辅修：12.5学分"出现两次）合并到前一条
    if (preIdx >= 0) {
      final p = sections[preIdx];
      if (p.level == s.level && p.title == s.title && p.creditsRaw == s.credits) {
        flushPending(null, preIdx);
        curIndex = preIdx;
        inTable = false;
        return;
      }
    }
    final chain = <String>[];
    for (var l = 1; l < s.level; l++) {
      final t = titles[l];
      if (t != null) chain.add(t);
    }
    sections.add(PdfModuleSection(
        title: s.title,
        level: s.level,
        creditsRaw: s.credits,
        creditsUnit: s.unit,
        parentPath: chain.join(' · ')));
    titles[s.level] = s.title;
    for (var l = s.level + 1; l <= 4; l++) {
      titles.remove(l);
    }
    curIndex = sections.length - 1;
    inTable = false;
    flushPending(s, preIdx);
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    if (_stopRe.hasMatch(line)) break;

    if (_auxResetRe.hasMatch(line)) {
      titles.clear();
      inTable = false;
      flushPending(null, curIndex);
      continue;
    }

    if (_ignoreRe.hasMatch(line)) {
      inTable = false;
      continue;
    }

    final sec = sectionOf(line);
    if (sec != null) {
      pushSection(sec);
      continue;
    }

    if (_tableHeadRe.hasMatch(line)) {
      flushPending(null, curIndex);
      inTable = true;
      continue;
    }

    if (inTable) {
      // 一行可能含多门课（PDF 紧凑排版把相邻两行粘一起，如
      // "…二(秋冬)MARX2005GH 中国共产党历史与理论…"）：按课程号切段逐个解析。
      var matchedPattern = false;
      var parsedAny = false;
      for (final segment in _splitCourseSegments(line)) {
        final cm = _courseRe.firstMatch(segment.trim());
        if (cm == null) continue;
        matchedPattern = true;
        final name = cm.group(2)!.trim();
        final credits = double.tryParse(cm.group(3)!) ?? 0;
        if (name.isEmpty || credits <= 0 || credits > 30 || _isGarbled(name)) {
          continue;
        }
        final rest = cm.group(4) ?? '';
        final rm = RegExp(
                r'^([\d.+\-]+)?\s*(?:\d{1,4})?\s*([一二三四]\([^)]*\)(?:/[一二三四]\([^)]*\))?)?')
            .firstMatch(rest);
        (coursesAcc[curIndex] ??= []).add(PdfCourseRow(
          code: cm.group(1)!,
          name: name,
          credits: credits,
          hours: (rm?.group(1) ?? '').trim(),
          semester: (rm?.group(2) ?? '').trim(),
        ));
        parsedAny = true;
      }
      if (parsedAny) continue;
      // 匹配了课程模式但被拒（乱码/学分非法）：像正文章节的落回说明区，
      // 其余当折行碎片丢弃——都视为「表格内的杂行」，表格状态保留。
      if (matchedPattern) {
        if (_looksLikeProse(line)) {
          inTable = false;
          pending.add(line);
        }
        continue;
      }
      // 完全不匹配课程模式：保持表格状态，落到下方统一收进说明区
    }

    if (line.length >= 2) pending.add(line);
  }
  flushPending(null, curIndex);

  // 组装（说明/课程挂回板块）
  final merged = <PdfModuleSection>[];
  for (var i = 0; i < sections.length; i++) {
    final s = sections[i];
    merged.add(PdfModuleSection(
      title: s.title,
      level: s.level,
      creditsRaw: s.creditsRaw,
      creditsUnit: s.creditsUnit,
      parentPath: s.parentPath,
      notes: _mergeWrapped(notesAcc[i] ?? const []),
      courses: coursesAcc[i] ?? const [],
    ));
  }

  final q = <String>[];
  if (merged.isEmpty) q.add('未识别到板块层级行');
  if (merged.fold<int>(0, (n, s) => n + s.courses.length) == 0) {
    q.add('未识别到课程表行');
  }
  return PlanPdfSections(sections: merged, qualityNotes: q);
}

/// 把一行切成若干"课程段"：以课程号（字母2-6位+4数字+可选字母）为界。
/// 单课程行原样返回；多课程粘连行被切开，各段再各自解析。
Iterable<String> _splitCourseSegments(String line) sync* {
  final codeRe = RegExp(r'[A-Z]{2,6}\d{4}[A-Z]{0,2}(?=\s)');
  final matches = codeRe.allMatches(line).toList();
  // 课程号必须从行首或空白/右括号后开始，避免把名称里的字母数字误当分割点
  final starts = <int>[
    for (final m in matches)
      if (m.start == 0 ||
          RegExp(r'[\s)）]').hasMatch(line[m.start - 1])) m.start
  ];
  if (starts.length <= 1) {
    yield line;
    return;
  }
  for (var i = 0; i < starts.length; i++) {
    final end = i + 1 < starts.length ? starts[i + 1] : line.length;
    yield line.substring(starts[i], end);
  }
}

/// 表格区内的行是否像正文（修读要求说明），而非课程名折行碎片。
bool _looksLikeProse(String line) {
  if (line.length >= 8) return true;
  return RegExp(r'[，。；：（）]|\d').hasMatch(line);
}

/// 总体要求（整章/全局口径段落）判据（用户反馈 #3：「各板块修读要求前面
/// 多出来那么多总体要求统统隐藏，从课程修读要求开始」）：
/// 章节开头的毕业总学分口径、指导性总述等全局段落，经 pending→flush 被
/// 误归到每个板块 notes 头部。展示层（_moduleBlock/_subBlock/_notesBlock）
/// 据此过滤，只留板块级的课程修读要求。
///
/// 启发式（宁缺勿猜——拿不准一律返回 false 保留为修读要求，绝不误删
/// 真实课程要求；引擎审计仍读完整 notes，本判据只影响方案页展示）：
///  1. 总括口径词：出现「总学分 / 学分合计 / 合计学分 / 共计 / 毕业要求」
///     「毕业总 / 以上各类 / 以上各 / 各类课程」等把多个板块合并计数的表述；
///     「以上」「共计」单独也命中——它们是典型的"回指全章"的总结句开头。
///  2. 章节号开头：以「一、二、…、十、」这类中文序号起头且整条较长 →
///     是 PDF 还原文本里混进 notes 的整章总述行（板块自身的层级标题不会
///     以这种形态落进 notes，落到这里的多是指导性计划的段落序号）。
///  3. 异常长概述：长度 ≥ 80 且不含任何"本板块怎么修"的动作词（修读/选修/
///     必修/应修/限选/任选/认定/成绩/课程清单）→ 视为总述；含动作词则保留。
///     阈值取 80：真实板块说明最长约 70 字（美育类整条 68 字），总述段
///     （二/三/四课堂口径段合并后普遍 100+）。
bool isOverallRequirement(String note) {
  final s = note.trim();
  if (s.isEmpty) return false;
  // 1) 总括口径词（合并计数/回指全章的表述）。
  if (RegExp(
          r'总学分|学分合计|合计学分|共计|总要求|毕业要求|毕业总学分|最低毕业学分|以上各类|以上各|各类课程')
      .hasMatch(s)) {
    return true;
  }
  // 「以上」「共计」单独出现即是回指句；但「修读2学分以上」这类板块级
  // 下限要求也含"以上"——须它不是紧跟在学分数字之后才算总括。
  final yishang = RegExp(r'以上').firstMatch(s);
  if (yishang != null &&
      yishang.start > 0 &&
      !RegExp(r'[\d.]\s*(?:学分|门|学时|课程)\s*$').hasMatch(s.substring(0, yishang.start))) {
    return true;
  }
  // 2) 中文序号起头的整章总述（「一、…」且非短标题行）。
  if (RegExp(r'^[一二三四五六七八九十]+、').hasMatch(s) && s.length >= 30) {
    return true;
  }
  // 3) 异常长且无任何板块级修读动作词 → 总述。
  if (s.length >= 80 &&
      !RegExp(r'修读|选修|必修|应修|限选|任选|认定|成绩|课程清单|记点')
          .hasMatch(s)) {
    return true;
  }
  return false;
}

String _cleanTitle(String t) {
  var s = t.trim();
  // 去掉行的层级前缀残留与尾部冒号
  s = s.replaceAll(RegExp(r'^[：:]\s*'), '').replaceAll(RegExp(r'[：:]\s*$'), '');
  return s.trim();
}

/// 折行合并：上一行不以句读结尾且长度接近整行 → 与下一行拼接。
List<String> _mergeWrapped(List<String> notes) {
  final out = <String>[];
  for (final n in notes) {
    if (out.isNotEmpty &&
        out.last.length >= 30 &&
        !RegExp(r'[。；：！？，、）]$').hasMatch(out.last) &&
        !RegExp(r'^[（(0-9]').hasMatch(n)) {
      out[out.length - 1] = out.last + n;
    } else {
      out.add(n);
    }
  }
  return out;
}

/// 检测乱码：名称中非 CJK/ASCII/常用标点的字符占比过高。
bool _isGarbled(String name) {
  var valid = 0;
  final total = name.runes.length;
  for (final ch in name.runes) {
    if ((ch >= 0x4E && ch <= 0x9FFF) || // CJK
        (ch >= 0x30 && ch <= 0x39) ||
        (ch >= 0x41 && ch <= 0x5A) ||
        (ch >= 0x61 && ch <= 0x7A) ||
        ch == 0x28 || ch == 0x29 || ch == 0xFF08 || ch == 0xFF09 ||
        ch == 0x00B7 || ch == 0x2014) {
      valid++;
    }
  }
  return total > 0 && valid < total * 2 ~/ 3;
}
