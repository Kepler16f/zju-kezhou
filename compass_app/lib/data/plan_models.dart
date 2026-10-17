/// data/plan_models.dart — 培养方案模型 + 在线匹配器（纯 Dart，可被 `dart test` 直接单测）。
///
/// 数据源（实测可用）：正方教务「培养方案查询」列表接口
///   POST /jwglxt/pyfagl/pyfaxxcx_cxPyfaxscxIndex.html?doType=query&gnmkdm=N153020&su=<学号>
///   body: queryModel.showCount=5000&queryModel.currentPage=1&_search=false[&synj=&zydm=&xydm=&jxjhh=]
/// 该接口一次返回全校方案（totalPage=1），因此"匹配"全部在客户端完成：
///   1) 学籍专业名（课表接口 zy 字段）× 年级（行政班尾四位）锁定唯一方案；
///   2) 命中多条 → 交给用户在 UI 里点选（歧义绝不猜）。
///
/// 旧实现之所以取不到方案：请求体发的是 zymc/njdm_id，而列表接口只认
/// synj/zydm/xydm/jxjhh（见 jwglxt/js/comp/jwglxt/jxjhgl/pyfagl/pyfaxscx.js 的
/// getParamData）；参数不匹配时正方回 HTML 错误页，json.decode 直接抛错。
library;

import 'zju_parse_ext.dart' show normalizeMajorName;

/// 匹配强度（由强到弱）。category 表示只命中了专业大类名。
enum PlanMatchLevel { exact, prefix, contains, category, none }

extension PlanMatchLevelX on PlanMatchLevel {
  String get label => switch (this) {
        PlanMatchLevel.exact => '专业全称',
        PlanMatchLevel.prefix => '名称前缀',
        PlanMatchLevel.contains => '名称包含',
        PlanMatchLevel.category => '专业大类',
        PlanMatchLevel.none => '不匹配',
      };

  /// 名称层权重：全称一致 > 前缀 > 包含 > 仅大类。
  double get weight => switch (this) {
        PlanMatchLevel.exact => 100,
        PlanMatchLevel.prefix => 80,
        PlanMatchLevel.contains => 55,
        PlanMatchLevel.category => 25,
        PlanMatchLevel.none => 0,
      };
}

/// 教务返回的空占位值（"未知/无/-"）统一按空串处理。
bool _isBlankValue(String s) =>
    s.isEmpty || s == '未知' || s == '无' || s == '-' || s == '--' || s == '/';

/// 课程名串 → 课程名列表。教务用 2 个以上空格分隔；也兼容顿号/逗号/分号。
List<String> splitCourseNames(String s) {
  final t = s.trim();
  if (t.isEmpty) return const [];
  final doubleSpace = RegExp(r'[\s\u3000]{2,}');
  final parts = doubleSpace.hasMatch(t)
      ? t.split(doubleSpace)
      : t.split(RegExp(r'[\s\u3000、,，;；]+'));
  return parts.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
}

/// 匹配用归一化：去年级/班号前缀、全角括号统一、去空白、小写，并展开常用简称。
String normalizePlanName(String s) => normalizeMajorName(s)
    .replaceAll(RegExp(r'[\s\u3000]+'), '')
    .replaceAll('（', '(')
    .replaceAll('）', ')')
    .toLowerCase();

/// 行政班尾四位 = 年级(2 位) + 班号(2 位)：工科试验班（计算机）2606 → 2026。
/// （0.10.6 前的实现取的是末两位，会把 2606 读成 2006，年级一错、方案全错。）
String? gradeFromClassName(String? className) {
  // 行政班写法多样："工科试验班（计算机）2606" / "信息安全2401" / "软件工程2202班"，
  // 末尾四位数字之前可能还带一个"班"字。
  final m = RegExp(r'(\d{4})\s*班?\s*$').firstMatch((className ?? '').trim());
  if (m == null) return null;
  final yy = int.tryParse(m.group(1)!.substring(0, 2));
  if (yy == null) return null;
  return (2000 + yy).toString();
}

/// 学籍画像（课表接口 xskbcx_cxXsKb 平铺返回：zy 专业 / xy 学院 / xzb 行政班 / xh / xm）。
class StudentProfile {
  final String majorName; // zy：如"信息安全"
  final String college; // xy：如"求是学院云峰学园"
  final String adminClass; // xzb：如"工科试验班（计算机）2606"
  final String studentId; // xh
  final String name; // xm
  final String semester; // 数据来源学期，如 2026-2027-3
  const StudentProfile({
    this.majorName = '',
    this.college = '',
    this.adminClass = '',
    this.studentId = '',
    this.name = '',
    this.semester = '',
  });

  bool get isEmpty =>
      majorName.isEmpty && adminClass.isEmpty && studentId.isEmpty;

  /// 年级（培养方案 synj 用同一口径）。
  String? get grade => gradeFromClassName(adminClass);

  factory StudentProfile.fromJson(Map<String, dynamic> json) {
    final xsxx = json['xsxx'];
    final merged = <String, dynamic>{
      ...json,
      if (xsxx is Map)
        ...xsxx.map((k, v) => MapEntry(k.toString(), v)),
    };
    String s(String k) => (merged[k] ?? '').toString().trim();
    String pick(String a, String b) => s(a).isNotEmpty ? s(a) : s(b);
    return StudentProfile(
      majorName: pick('zy', 'zymc'),
      college: pick('xy', 'yxmc'),
      adminClass: pick('xzb', 'bjmc'),
      studentId: s('xh'),
      name: s('xm'),
      semester: [s('xnm'), s('xqm')].where((e) => e.isNotEmpty).join('-'),
    );
  }

  Map<String, dynamic> toJson() => {
        'zy': majorName,
        'xy': college,
        'xzb': adminClass,
        'xh': studentId,
        'xm': name,
        'semester': semester,
      };
}

/// 一条培养方案（对应正方列表接口的一行；字段名与接口 JSON 一一对应）。
class PlanSummary {
  final String pyfaxxId; // pyfaxx_id：方案主键（详情/预览用）
  final String jxjhh; // 教学计划号（PDF 预览 id 用的就是它）
  final String zymc; // 专业名称
  final String zydm; // 专业代码
  final String xymc; // 开课学院名称
  final String xydm; // 开课学院代码
  final String zydlmc; // 专业大类名称
  final String zydlmc2; // 专业大类名称（第二列，通常同上）
  final String zydldm; // 专业大类代码
  final String dljxjhh; // 大类教学计划号
  final String dlbsmc; // 方案类别：专业 / 辅修 / 微辅修 …
  final String synj; // 适用年级，如 2024
  final String xz; // 学制（年）
  final String syxw; // 授予学位
  final String xqmc; // 校区
  final String gjzymc; // 国标专业名称
  final String xkzylb; // 选考专业类别
  final String tjzt; // 方案审核状态
  final String ytzgxk; // 依托专业/学科
  final double? zdbyxf; // 最低毕业学分
  final double? kcdlxfyq; // 课程总学分要求
  final double? qdkcxf; // 前置课程学分
  final double? fxxf; // 辅修学分
  final double? ezyxf; // 双专业学分
  final double? exwxf; // 双学位学分
  final double? wfxxf; // 微辅修学分
  final double? dektxf; // 第二课堂学分
  final double? dektxf3; // 第三课堂学分
  final double? dektxf4; // 第四课堂学分
  final double? bsfxf; // 不收费学分
  final double? kzymkxf; // 跨专业模块学分
  final double? gjhmkxf; // 国际化模块学分
  final int? rs; // 计划人数
  final int? sjrs; // 实际人数
  final String pymb; // 培养目标
  final String pyyq; // 培养要求
  final String bz; // 备注（微辅修/辅修/辅修学位学分说明）
  final String dektbz; // 第二课堂修读标准
  final String d3ktbz; // 第三课堂修读标准
  final String dsktbz; // 第四课堂修读标准
  final String kcxddt; // 课程修读地图附件 id
  final List<String> zyhxkc; // 专业核心课程
  final List<String> zyhxsjkc; // 专业核心实践课程
  final List<String> qywkc; // 前沿与荣誉课程
  final Map<String, dynamic> raw; // 原始行（缓存/回放用）

  const PlanSummary({
    this.pyfaxxId = '',
    this.jxjhh = '',
    this.zymc = '',
    this.zydm = '',
    this.xymc = '',
    this.xydm = '',
    this.zydlmc = '',
    this.zydlmc2 = '',
    this.zydldm = '',
    this.dljxjhh = '',
    this.dlbsmc = '',
    this.synj = '',
    this.xz = '',
    this.syxw = '',
    this.xqmc = '',
    this.gjzymc = '',
    this.xkzylb = '',
    this.tjzt = '',
    this.ytzgxk = '',
    this.zdbyxf,
    this.kcdlxfyq,
    this.qdkcxf,
    this.fxxf,
    this.ezyxf,
    this.exwxf,
    this.wfxxf,
    this.dektxf,
    this.dektxf3,
    this.dektxf4,
    this.bsfxf,
    this.kzymkxf,
    this.gjhmkxf,
    this.rs,
    this.sjrs,
    this.pymb = '',
    this.pyyq = '',
    this.bz = '',
    this.dektbz = '',
    this.d3ktbz = '',
    this.dsktbz = '',
    this.kcxddt = '',
    this.zyhxkc = const [],
    this.zyhxsjkc = const [],
    this.qywkc = const [],
    this.raw = const {},
  });

  /// 方案唯一 id：优先方案主键，其次教学计划号。
  String get id => pyfaxxId.isNotEmpty ? pyfaxxId : jxjhh;

  /// 是否主修方案（非辅修/微辅修）。
  bool get isMajorPlan => dlbsmc.isEmpty || dlbsmc.contains('专业');

  /// 年级数字（用于排序），解析不出返回 0。
  int get gradeYear => int.tryParse(synj) ?? 0;

  String get creditsLabel => zdbyxf == null ? '未标注' : '${_trimNum(zdbyxf!)} 学分';

  /// 一行式摘要（选择器/列表用）。
  String get subtitle {
    final parts = <String>[
      if (xymc.isNotEmpty) xymc,
      if (synj.isNotEmpty) '$synj 级',
      if (zydm.isNotEmpty) '代码 $zydm',
      if (zdbyxf != null) '${_trimNum(zdbyxf!)} 学分',
      if (dlbsmc.isNotEmpty && dlbsmc != '专业') dlbsmc,
    ];
    return parts.join(' · ');
  }

  factory PlanSummary.fromRow(Map<String, dynamic> row) {
    String s(String k) {
      final v = (row[k] ?? '').toString().trim().replaceAll('\u3000', ' ').trim();
      return _isBlankValue(v) ? '' : v;
    }

    double? d(String k) {
      final v = row[k];
      if (v is num) return v.toDouble();
      final t = v?.toString().trim() ?? '';
      if (t.isEmpty) return null;
      final parsed = double.tryParse(t);
      if (parsed != null) return parsed;
      return null;
    }

    int? i(String k) {
      final v = row[k];
      if (v is num) return v.toInt();
      return int.tryParse(v?.toString().trim() ?? '');
    }

    return PlanSummary(
      pyfaxxId: s('pyfaxx_id'),
      jxjhh: s('jxjhh'),
      zymc: s('zymc'),
      zydm: s('zydm'),
      xymc: s('xymc'),
      xydm: s('xydm'),
      zydlmc: s('zydlmc'),
      zydlmc2: s('zydlmc2'),
      zydldm: s('zydldm'),
      dljxjhh: s('dljxjhh'),
      dlbsmc: s('dlbsmc'),
      synj: s('synj'),
      xz: s('xz'),
      syxw: s('syxw'),
      xqmc: s('xqmc'),
      gjzymc: s('gjzymc'),
      xkzylb: s('xkzylb'),
      tjzt: s('tjzt'),
      ytzgxk: s('ytzgxk'),
      zdbyxf: d('zdbyxf'),
      kcdlxfyq: d('kcdlxfyq'),
      qdkcxf: d('qdkcxf'),
      fxxf: d('fxxf'),
      ezyxf: d('ezyxf'),
      exwxf: d('exwxf'),
      wfxxf: d('wfxxf'),
      dektxf: d('dektxf'),
      dektxf3: d('dektxf3'),
      dektxf4: d('dektxf4'),
      bsfxf: d('bsfxf'),
      kzymkxf: d('kzymkxf'),
      gjhmkxf: d('gjhmkxf'),
      rs: i('rs'),
      sjrs: i('sjrs'),
      pymb: s('pymb'),
      pyyq: s('pyyq'),
      bz: s('bz'),
      dektbz: s('dektbz'),
      d3ktbz: s('d3ktbz'),
      dsktbz: s('dsktbz'),
      kcxddt: s('kcxddt'),
      zyhxkc: splitCourseNames(s('zyhxkc')),
      zyhxsjkc: splitCourseNames(s('zyhxsjkc')),
      qywkc: splitCourseNames(s('qywkc')),
      raw: row,
    );
  }

  /// 匹配强度：专业名优先，其次大类名。
  PlanMatchLevel levelFor(String majorName) {
    final m = normalizePlanName(majorName);
    if (m.isEmpty) return PlanMatchLevel.none;
    final zy = normalizePlanName(zymc);
    if (zy.isEmpty) return PlanMatchLevel.none;
    if (zy == m) return PlanMatchLevel.exact;
    if (zy.startsWith(m) || m.startsWith(zy)) return PlanMatchLevel.prefix;
    if (zy.contains(m) || m.contains(zy)) return PlanMatchLevel.contains;
    final dl = normalizePlanName('$zydlmc$zydlmc2');
    if (dl.isNotEmpty && (dl.contains(m) || m.contains(dl))) {
      return PlanMatchLevel.category;
    }
    return PlanMatchLevel.none;
  }
}

double _trimNum(double v) =>
    (v - v.roundToDouble()).abs() < 1e-9 ? v.roundToDouble() : v;

/// 候选方案（带匹配强度/年级一致/得分，供 UI 排序与解释）。
class PlanCandidate {
  final PlanSummary plan;
  final PlanMatchLevel level;
  final bool gradeMatch; // 是否与本人年级一致
  final double score;
  const PlanCandidate(this.plan, this.level, this.gradeMatch, this.score);

  String get reason => gradeMatch
      ? '${level.label} · ${plan.synj} 级（本人年级）'
      : '${level.label} · ${plan.synj} 级（非本人年级）';
}

/// 匹配结果：候选按得分降序；[ambiguous] 为真时 UI 必须请用户点选。
class PlanMatchResult {
  final String majorName;
  final String? grade;
  final List<PlanCandidate> candidates;
  final List<String> notes;

  const PlanMatchResult({
    required this.majorName,
    this.grade,
    this.candidates = const [],
    this.notes = const [],
    this.ambiguous = false,
  });

  static const empty = PlanMatchResult(majorName: '');

  bool get isEmpty => candidates.isEmpty;
  PlanCandidate? get best => candidates.isEmpty ? null : candidates.first;
  List<PlanCandidate> get alternatives =>
      candidates.length <= 1 ? const [] : candidates.sublist(1);

  /// 是否需要用户点选确认（构造期算好，判定规则见 [matchPlans]）。
  /// 为真时 UI 必须把候选列出来让用户挑，不能替他决定。
  final bool ambiguous;
}

double _gradeScore(String itemGrade, String target) {
  if (target.isEmpty) return 0;
  if (itemGrade == target) return 60;
  final t = int.tryParse(target), i = int.tryParse(itemGrade);
  if (t == null || i == null) return 0;
  if (i < t) return (30 - (t - i) * 5).clamp(0, 30).toDouble();
  return -20; // 比本人年级还新（新方案对老生不适用）
}

/// 全量方案 → 候选排序（纯函数，便于单测）。
/// 打分 = 名称层权重 + 年级一致 60（往届按差距递减、未来年级 -20）+ 主修方案 6。
PlanMatchResult matchPlans(
  List<PlanSummary> catalog, {
  required String majorName,
  String? grade,
  int maxCandidates = 12,
}) {
  final g = (grade ?? '').trim();
  final byId = <String, PlanCandidate>{};
  for (final p in catalog) {
    final level = p.levelFor(majorName);
    if (level == PlanMatchLevel.none || p.id.isEmpty) continue;
    final gradeMatch = g.isNotEmpty && p.synj == g;
    var score = level.weight + _gradeScore(p.synj, g);
    if (p.isMajorPlan) score += 6;
    final candidate = PlanCandidate(p, level, gradeMatch, score);
    final prev = byId[p.id];
    if (prev == null || candidate.score > prev.score) byId[p.id] = candidate;
  }
  final candidates = byId.values.toList()
    ..sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byGrade = b.plan.gradeYear.compareTo(a.plan.gradeYear);
      if (byGrade != 0) return byGrade;
      return a.plan.jxjhh.compareTo(b.plan.jxjhh);
    });

  // 歧义判定（两种都要让用户自己挑，绝不替他决定）：
  //  * 前两名分差 < 20（含并列）；
  //  * 同一年级里有多条"专业全称/前缀"级命中（如 信息安全 与 信息安全（数字安全方向））。
  final strongPerGrade = <String, int>{};
  for (final c in candidates) {
    if (c.level == PlanMatchLevel.exact || c.level == PlanMatchLevel.prefix) {
      strongPerGrade[c.plan.synj] = (strongPerGrade[c.plan.synj] ?? 0) + 1;
    }
  }
  final tied =
      candidates.length > 1 && candidates[0].score - candidates[1].score < 20;
  final ambiguous = tied || strongPerGrade.values.any((n) => n > 1);

  final notes = <String>[];
  if (candidates.isEmpty) {
    notes.add('教务方案库（${catalog.length} 条）中没有「$majorName」——'
        '可能是新建专业/大类培养，可手动搜索专业名或按学院挑选。');
  } else {
    final top = candidates.first;
    if (g.isNotEmpty && !top.gradeMatch) {
      notes.add('$g 级暂无「${top.plan.zymc}」方案，已退到 ${top.plan.synj} 级'
          '（往届方案，课程与学分可能已调整，仅供参考）');
    }
    final sameAsTop = candidates
        .where((c) => c.level == top.level && c.plan.synj == top.plan.synj)
        .length;
    if (sameAsTop > 1) {
      notes.add('${top.plan.synj} 级「${top.plan.zymc}」有 $sameAsTop 条方案'
          '（学院/方向/培养类型不同），请确认选中的是本人方案');
    }
    if (!top.plan.isMajorPlan) {
      notes.add('当前方案类别为「${top.plan.dlbsmc}」，不是主修方案');
    }
    if (ambiguous) {
      final sameGrade =
          candidates.where((c) => c.plan.synj == top.plan.synj).length;
      notes.add('${top.plan.synj} 级有 $sameGrade 条相近方案'
          '（学院/方向/培养类型可能不同），请在候选列表里点选确认本人方案');
    }
  }
  return PlanMatchResult(
    majorName: majorName,
    grade: g.isEmpty ? null : g,
    candidates: candidates.take(maxCandidates).toList(),
    notes: notes,
    ambiguous: ambiguous,
  );
}

/// 按教学计划号/方案主键精确取一条（用户上次的选择、或手输 jxjhh 时用）。
PlanSummary? findPlanById(List<PlanSummary> catalog, String id) {
  final key = id.trim();
  if (key.isEmpty) return null;
  for (final p in catalog) {
    if (p.jxjhh == key || p.pyfaxxId == key) return p;
  }
  return null;
}

/// 手动搜索：专业名/学院/专业代码/教学计划号 模糊命中（大小写与空白不敏感）。
List<PlanSummary> searchPlans(
  List<PlanSummary> catalog,
  String keyword, {
  String? grade,
  int limit = 60,
}) {
  final raw = keyword.trim();
  // ⚠️ 不能只用归一化后的关键词：教学计划号/专业代码是纯数字串，
  // normalizePlanName 会把"数字+可选班字"整串吃掉（20262113100 → 空串）。
  final k = normalizePlanName(raw);
  final g = (grade ?? '').trim();
  final hits = <PlanSummary>[];
  for (final p in catalog) {
    if (g.isNotEmpty && p.synj != g) continue;
    final byCode = raw.isNotEmpty &&
        (p.zydm.contains(raw) || p.jxjhh.contains(raw) || p.id.contains(raw));
    final byName =
        k.isNotEmpty && normalizePlanName('${p.zymc}${p.xymc}${p.zydlmc}${p.gjzymc}').contains(k);
    if (raw.isEmpty || byCode || byName) hits.add(p);
  }
  hits.sort((a, b) => b.gradeYear.compareTo(a.gradeYear));
  return hits.take(limit).toList();
}

/// 培养方案 → 审计引擎 PlanFile（best-effort：摘要课程 + 成绩单同名课程补齐学分）。
///
/// 与 PDF 全量方案（engine/plan_audit_adapter.planFileFromPdf，需「叶子优先」
/// 防父子重复计费）不同：摘要口径的模块只有并列三组（专业核心/集中实践/前沿
/// 与荣誉），无父子嵌套——required_credits 是各组课程学分直和，模块要求和 ==
/// 课程学分和，不存在「父板块学分含子板块」的重复计费，AuditEngine 可直接求和。
///
/// 正方列表接口只给"专业核心课/核心实践课/前沿与荣誉课程"三类课程名，
/// 不给逐门学分与学期；因此这里：
///   * 学分优先取本人成绩单里同名课程的真实学分；
///   * 取不到时记 0 分并在 quality 里如实说明（绝不假装完备）；
///   * 模块要求学分用课程学分求和近似，另以最低毕业学分兜底。
Map<String, dynamic> planFileFromSummary(
  PlanSummary s, {
  String grade = '',
  List<Map<String, dynamic>> transcript = const [],
}) {
  final creditByName = <String, double>{};
  for (final c in transcript) {
    final name = (c['name'] ?? '').toString().trim();
    final cr = c['credits'];
    if (name.isNotEmpty && cr is num && cr > 0) {
      creditByName[name] = cr.toDouble();
    }
  }

  const moduleTitles = {
    'major_core': '专业教育/专业核心',
    'intensive_practice': '集中实践',
    'major_limited': '专业教育/专业限选',
  };
  final groups = <String, List<String>>{
    'major_core': s.zyhxkc,
    'intensive_practice': s.zyhxsjkc,
    'major_limited': s.qywkc,
  };

  final modules = <Map<String, dynamic>>[];
  final courses = <Map<String, dynamic>>[];
  var unknownCredits = 0;
  for (final entry in groups.entries) {
    final names = entry.value;
    if (names.isEmpty) continue;
    var sum = 0.0;
    for (final name in names) {
      final credit = creditByName[name] ?? 0.0;
      if (!creditByName.containsKey(name)) unknownCredits++;
      sum += credit;
      courses.add({
        'course_id': name,
        'name': name,
        'credits': credit,
        'module_id': entry.key,
        'nature': entry.key == 'major_limited' ? '选修' : '必修',
        'offered': null,
        'grade_cycle': null,
        'offered_years': null,
        'prereq': <String>[],
        'source': {'page': 'zdbk/pyfagl/pyfaxxcx_cxPyfaxscxIndex', 'jxjhh': s.jxjhh},
      });
    }
    modules.add({
      'module_id': entry.key,
      'module_path': moduleTitles[entry.key] ?? entry.key,
      'required_credits': sum,
    });
  }

  final quality = <String>[
    '课程清单来自教务方案摘要（专业核心课/核心实践课/前沿与荣誉课程），'
        '非完整课程表——通识/选修等模块未含',
    if (unknownCredits > 0) '$unknownCredits 门课程学分未知（成绩单未命中），按 0 计',
    if (s.kcdlxfyq != null) '教务声明课程总学分要求 ${_trimNum(s.kcdlxfyq!)}，'
        '摘要模块仅覆盖其中一部分',
  ];

  return {
    'meta': {
      'major': s.zymc.isEmpty ? s.id : s.zymc,
      'grade': grade.isNotEmpty ? grade : s.synj,
      'source_doc': '教务网培养方案 ${s.zymc} ${s.synj} 级'
          '（教学计划号 ${s.jxjhh}｜方案摘要接口实时获取）',
      'total_credits': s.zdbyxf ?? modules.fold<double>(
          0, (acc, m) => acc + (m['required_credits'] as double)),
      'extracted_by': 'plan_models.planFileFromSummary',
      'verified': false,
      'quality': quality,
      'plan_id': s.id,
      'plan_credits_label': s.creditsLabel,
    },
    'modules': modules,
    'courses': courses,
  };
}
/// 课程表一行（培养方案明细/课程列表接口的归一化结果）。
class PlanCourseRow {
  final String name; // 课程名称
  final String code; // 课程代码（可能为空）
  final double? credits; // 学分
  final String semester; // 开课学期（如"秋冬"/"秋"）
  final String module; // 课程模块（教务原始分类）
  final String nature; // 课程性质（必修/选修/限选）
  final String teacher; // 任课教师
  final Map<String, dynamic> raw;
  const PlanCourseRow({
    required this.name,
    this.code = '',
    this.credits,
    this.semester = '',
    this.module = '',
    this.nature = '',
    this.teacher = '',
    this.raw = const {},
  });

  bool get isEmpty => name.isEmpty;

  /// 从教务行归一化（键名中英混排：kcmc/课程名称、xf/学分、kkxq/开课学期…）。
  factory PlanCourseRow.fromRow(Map<String, dynamic> row) {
    String pick(List<String> keys) {
      for (final k in keys) {
        final v = row[k];
        if (v == null) continue;
        final s = v.toString().trim();
        if (s.isNotEmpty && s != 'null') return s;
      }
      return '';
    }

    double? credits;
    for (final k in ['xf', '学分', 'credits']) {
      final v = row[k];
      if (v is num) {
        credits = v.toDouble();
        break;
      }
      final t = v?.toString().trim();
      if (t != null && t.isNotEmpty) {
        final parsed = double.tryParse(t);
        if (parsed != null) {
          credits = parsed;
          break;
        }
      }
    }
    return PlanCourseRow(
      name: pick(['kcmc', '课程名称', 'name', 'kcmc_hz']),
      code: pick(['kcdm', '课程代码', 'course_id']),
      credits: credits,
      semester: pick(['kkxq', 'kklxmc', '开课学期', 'xqmc', 'xq', 'semester']),
      module: pick(['kcflmc', 'kcfjmc', '课程模块', 'module', 'kcmc_fl']),
      nature: pick(['kcxzmc', '课程性质', 'kcsx', 'kcxz', 'nature']),
      teacher: pick(['jsxm', 'skjs', '教师', 'teacher']),
      raw: row,
    );
  }
}

/// 审计用方案解析结果：摘要 + PlanFile + 课程表 + 质量说明（客户端一次性给全）。
class ResolvedPlan {
  final PlanSummary? summary;
  final Map<String, dynamic>? planFile;
  final List<PlanCourseRow> courseTable;
  final List<String> notes;
  final bool matched;
  const ResolvedPlan({
    this.summary,
    this.planFile,
    this.courseTable = const [],
    this.notes = const [],
    this.matched = false,
  });

  static const empty = ResolvedPlan();

  /// 一行式质量说明（进入审计页顶部提示条 / 方案页状态条）。
  String get quality {
    final s = summary;
    if (s == null) return notes.isEmpty ? '未获取到培养方案' : notes.join('；');
    return <String>[
      '教务网培养方案 ${s.zymc} ${s.synj} 级',
      s.creditsLabel,
      courseTable.isEmpty ? '方案摘要（不含逐门课程表）' : '${courseTable.length} 门课程',
      ...notes,
    ].join('｜');
  }
}
