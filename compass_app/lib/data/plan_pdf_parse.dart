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
  final String parentPath; // "通识课程 · 通识必修课程"（上级链，不含自身）
  final List<String> notes; // 修读要求说明
  final List<PdfCourseRow> courses; // 该板块课程表

  const PdfModuleSection({
    required this.title,
    required this.level,
    this.creditsRaw = '',
    this.parentPath = '',
    this.notes = const [],
    this.courses = const [],
  });

  /// 数字学分（"3-6" 取 3、" +4" 取 4、无声明为 0）。
  double get credits {
    final m = RegExp(r'\d+(?:\.\d+)?').firstMatch(creditsRaw);
    return m == null ? 0 : (double.tryParse(m.group(0)!) ?? 0);
  }

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

/// 四级：`1)必修课程 12学分`（要求以学分收尾，避免吃到"1)至少修读1门…"）。
final _lvl4Re = RegExp(r'^(\d+)\)\s*(\S.*?)\s+([\d.+\-]+)\s*学分$');

/// 冒号式：`微辅修：12.5学分`。
final _colonRe = RegExp(r'^([^：:]{2,20})[：:]\s*([\d.+\-]+)\s*学分$');

/// 课程行：`MARX1004G 大学生思想文化素养 2.0 2.0-0.0 32 一(秋冬)`。
/// 学分之后的部分（周学时/总学时/学期）自由解析；无学期行（如耕读课程）也匹配。
/// 课程号前缀实测 2-6 位字母（CS1006G / ME1001F / MARX1004G）。
final _courseRe =
    RegExp(r'^([A-Z]{2,6}\d{4}[A-Z]?)\s+(.+?)\s+(\d{1,2}(?:\.\d)?)\b\s*(.*)$');

/// 表格头行（进入表格区的标志）。
final _tableHeadRe = RegExp(r'^课程号\s+课程名称\s+学分');

/// 需整行忽略的标题行（注意：表格头"课程号 课程名称…"另行处理，不能在此吞掉）。
final _ignoreRe = RegExp(
    r'^(浙江大学\s*Zhejiang University|课程设置与学分分布|培养阶段课程结构图|'
    r'培养方案修读指导性计划|类别\s+课程号|类别\s+项目序号|'
    r'第[一二三四]学年|微辅修$|A\.跨专业课程至少1门)');

/// 复位标记：辅修段与正文培养方案无继承关系。
final _auxResetRe = RegExp(r'^辅修培养方案[：:]?$');

/// 终止标记：其后是"修读指导性计划"（按学年重排的重复课程表）。
final _stopRe = RegExp(r'^培养方案修读指导性计划$');

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
  ({String title, int level, String credits})? sectionOf(String line) {
    var m = _lvl1Re.firstMatch(line);
    if (m != null) return (title: _cleanTitle(m.group(1)!), level: 1, credits: (m.group(2) ?? '').trim());
    m = _lvl2Re.firstMatch(line);
    if (m != null) return (title: _cleanTitle(m.group(1)!), level: 2, credits: m.group(2)!);
    m = _colonRe.firstMatch(line);
    if (m != null) return (title: _cleanTitle(m.group(1)!), level: 2, credits: m.group(2)!);
    m = _lvl3Re.firstMatch(line);
    if (m != null) return (title: _cleanTitle(m.group(2)!), level: 3, credits: (m.group(3) ?? '').trim());
    m = _lvl4Re.firstMatch(line);
    if (m != null) return (title: _cleanTitle(m.group(2)!), level: 4, credits: m.group(3)!);
    return null;
  }

  /// 落地待定说明：提到新板块名的归新板块（双栏排版下说明先于标题出现），
  /// 其余留在上一板块（preIdx 为推入新板块之前的板块下标）。
  void flushPending(({String title, int level, String credits})? incoming, int preIdx) {
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

  void pushSection(({String title, int level, String credits}) s) {
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
      final cm = _courseRe.firstMatch(line);
      if (cm != null && curIndex >= 0) {
        final name = cm.group(2)!.trim();
        final credits = double.tryParse(cm.group(3)!) ?? 0;
        if (name.isNotEmpty && credits > 0 && credits <= 30 && !_isGarbled(name)) {
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
          continue;
        }
        // 非课程行：像正文章节的（有标点/数字/够长）落回说明区，其余当折行碎片丢弃
        if (_looksLikeProse(line)) {
          inTable = false;
          pending.add(line);
        }
        continue;
      }
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

/// 表格区内的行是否像正文（修读要求说明），而非课程名折行碎片。
bool _looksLikeProse(String line) {
  if (line.length >= 8) return true;
  return RegExp(r'[，。；：（）]|\d').hasMatch(line);
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
