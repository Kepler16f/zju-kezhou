/// data/xk_models.dart — 选课(xsxk)数据模型与跨轮次匹配（纯 Dart，零 IO，不抛异常）。
///
/// 数据层不变量（评审结论，勿回退）：
/// - 教学班身份＝课程+教学班：有 jxb_id 用 kch_id|jxb_id 主键；无 jxb_id 但有教师+时间
///   用指纹降级；再不行只按课程聚合并标注「无法区分平行班」（三档降级链）。
/// - 轮次（xkkz_id/xklc）只是观测维度，绝不参与身份键；do_jxb_id（加密串）不出现于本层。
/// - 「同一教学班跨轮次稳定」是工作假设（待 LIVE 探针校准）——合并仅用于只读展示，
///   不参与任何判定；跨轮一致性异常一律留痕，绝不静默合并。
library;

/// 选课入口（首页菜单项）。两种形态（LIVE 取证 2026-10-16）：
///  - 通用正方（xsxk/zzxkyzb）：轮次 xkkz_id × 类别 kklxdm；
///  - 浙大自主选课（xsxk/zzxkghb N253530）：入口=课程类别（dl 代码，如 EA=思政类、
///    53=心理健康类），xkkzId 存 dl、kklxdm 存 lx（bl=本类）。label=类别名。
class XkRound {
  final String xkkzId; // 选课设置ID / 浙大 dl 类别码（观测键）
  final String kklxdm; // onclick 第一参数 / 浙大 lx（可能为空）
  final String? xklc; // 轮次编号：公开资料不能证实其参数位，拿不到就 null
  final String label; // 菜单可见文本（真实入口名，供 UI）

  const XkRound({
    required this.xkkzId,
    this.kklxdm = '',
    this.xklc,
    this.label = '',
  });

  @override
  String toString() => 'XkRound($xkkzId, $kklxdm, $xklc, $label)';
}

/// 一条课程列表行（解析后）。
class XkCourse {
  final String kch; // 课程号（可能空）
  final String kchId; // 课程ID（32hex；可能空）
  final String kcmc; // 课程名（必有；空行在解析层被丢弃）
  final double? xf; // 学分（未知 → null，不当 0）
  final String jxbId; // 教学班ID（可能空）
  final String jxbmc; // 教学班名/序号（可能空）
  final String teacher; // 教师原文（jsxx；可能空）
  final String sksj; // 上课时间原文（可能空）
  final String cdmc; // 场地（可能空）
  final String xqjmc; // 校区（可能空）
  final String subTerm; // 子学期归属（秋/冬/秋冬/短/春/夏；LIVE 取证：真实行带 xxq，诉求 #4）
  final int? cap; // 容量（多键尝试后仍未知 → null）
  final int? selected; // 已选人数（未知 → null）
  final List<Map<String, dynamic>> slots; // 解析后时隙（对齐 Timeline.slotsConflict 消费 schema）
  final List<String> tags; // 课程标签/性质（如 通识核心课/专业选修/思政…；来自教务课程性质字段）
  final List<String> categories; // 观测来源类别入口名（诉求 #11：单行来自一个入口，仍用列表
                                 // 承载；跨入口合并见 XkMergedCourse.categories。与 tags 分开：
                                 // tags 兼容保留入口名混排，读取点不动）
  final String xkkzId; // 来源入口
  final String? xklc;
  final Map<String, dynamic> raw; // 原始行（诊断/展开详情用；不含任何凭证）

  const XkCourse({
    required this.kcmc,
    this.kch = '',
    this.kchId = '',
    this.xf,
    this.jxbId = '',
    this.jxbmc = '',
    this.teacher = '',
    this.sksj = '',
    this.cdmc = '',
    this.xqjmc = '',
    this.subTerm = '',
    this.cap,
    this.selected,
    this.slots = const [],
    this.tags = const [],
    this.categories = const [],
    this.xkkzId = '',
    this.xklc,
    this.raw = const {},
  });

  /// 身份档位：1=教学班主键；2=指纹（教师+时间）；3=仅课程（无法区分平行班）
  int get identityTier {
    if (jxbId.isNotEmpty) return 1;
    if (sksj.isNotEmpty && teacher.isNotEmpty) return 2;
    return 3;
  }

  /// 跨轮次匹配键（配合 identityTier 使用；轮次不参与）。
  /// 主键含归一化课程名：同一 jxb_id 但课程名不同属数据异常，分开展示不静默合并（评审A4）。
  /// 三段标识符均过 _fp（大小写/全角/零宽归一），避免同班因书写差异被拆卡（评审L2）。
  String get identityKey {
    switch (identityTier) {
      case 1:
        return 'j|${_fp(kchId.isNotEmpty ? kchId : kch)}|${_fp(jxbId)}|${_fp(kcmc)}';
      case 2:
        return 'f|${_fp(kch.isNotEmpty ? kch : kcmc)}|${_fp(teacher)}|${_fp(sksj)}';
      default:
        return 'c|${_fp(kch.isNotEmpty ? kch : kcmc)}';
    }
  }

  /// 指纹（用于「疑似同一教学班（轮次间标识变化）」校验；与 identityKey 的 f 档同构）
  String get fingerprint =>
      '${_fp(kchId.isNotEmpty ? kchId : (kch.isNotEmpty ? kch : kcmc))}|${_fp(teacher)}|${_fp(sksj)}';
}

/// 指纹归一化：小写、去空白/常见分隔符（全角空格、间隔号）、全角→半角、
/// 剔除零宽与变体选择符等格式字符（视觉相同但码点不同会让指纹分叉，评审L2）。
/// 与 plan 侧 normalizePlanName 不同源，勿混用。
String _fp(String s) {
  final buf = StringBuffer();
  for (final r in s.trim().toLowerCase().runes) {
    if (r == 0x200B || r == 0x200C || r == 0x200D || r == 0xFE0F || r == 0x00AD) {
      continue; // ZWSP/ZWJ/ZWNJ/变体选择符/软连字符
    }
    if (r == 0x3000 || r == 0x00B7) continue; // 全角空格与「·」：视作分隔符剔除
    if (r >= 0xFF01 && r <= 0xFF5E) {
      buf.writeCharCode(r - 0xFEE0); // 全角 ASCII → 半角
      continue;
    }
    final c = String.fromCharCode(r);
    if (c.trim().isEmpty) continue;
    buf.write(c);
  }
  return buf.toString();
}

/// 跨轮次合并结果：每条已合并课程 + 全局留痕。
class XkMergeResult {
  final List<XkMergedCourse> courses;
  final List<String> notes; // 合并期异常与降级留痕（疑似同班/档位统计等）
  const XkMergeResult({required this.courses, required this.notes});
}

/// 已合并课程：同一身份的教学班（或同课程）跨入口观测集合。
class XkMergedCourse {
  final XkCourse base; // 展示主体（字段最全的一次观测）
  final Map<String, XkObservation> byRound; // xkkzId -> 观测
  final List<String> roundOrder; // 入口出现顺序（保持拉取顺序）
  final List<String> notes; // 本条留痕
  final List<String> tags; // 跨入口标签并集（课程性质/类别入口；兼容字段，读取点未迁移）
  final List<String> categories; // 跨入口类别列表（诉求 #11）：合并各观测来源的类别，
                                 // 去重保序——同一门课可属于多个类别标签（跨轮/跨入口），
                                 // UI 逐标签出 Chip，不再只认单个来源入口
  final List<Map<String, dynamic>> slots; // 跨入口时隙并集（冲突检测）
  const XkMergedCourse({
    required this.base,
    required this.byRound,
    required this.roundOrder,
    this.notes = const [],
    this.tags = const [],
    this.categories = const [],
    this.slots = const [],
  });

  int get tier => base.identityTier;

  /// 最新容量/已选（取有值且最后拉取的观测）；未知保持 null
  XkObservation? get latest {
    for (final id in roundOrder.reversed) {
      final o = byRound[id];
      if (o != null && (o.cap != null || o.selected != null)) return o;
    }
    return roundOrder.isEmpty ? null : byRound[roundOrder.last];
  }
}

/// 单个入口上的一次观测（只读快照，带时间与状态三态）。
class XkObservation {
  final String xkkzId;
  final String? xklc;
  final String label;
  final int? cap;
  final int? selected;
  final int fetchedAtMillis;
  final String state; // 'data' | 'empty'（A6 三态中第三态「不可用/未知」不落缓存、不进本结构）
  final int count; // 该入口解析出的行数
  const XkObservation({
    required this.xkkzId,
    this.xklc,
    this.label = '',
    this.cap,
    this.selected,
    this.fetchedAtMillis = 0,
    this.state = 'data',
    this.count = 0,
  });
}

/// 跨轮次合并（只读展示用）。
///
/// 规则：
/// - 一级分组按 identityKey（档位 1/2 分别合并；档位 3 按课程聚合并在 notes 标注）；
/// - 同 jxb_id 但课程名/课程ID 不同 → 异常留痕（数据不一致，不合并展示口径）；
/// - 两个不同 jxb_id 的教学班指纹相同 → 双方标「疑似同一教学班（轮次间标识变化）」，不静默合并；
/// - 观测按 xkkzId 归并（同入口重复拉取时以新观测覆盖）。
XkMergeResult mergeXkCourses(List<XkCourse> all) {
  final notes = <String>[];
  final groups = <String, List<XkCourse>>{};
  final order = <String>[];
  for (final c in all) {
    final k = '${c.identityTier}|${c.identityKey}';
    final g = groups.putIfAbsent(k, () {
      order.add(k);
      return <XkCourse>[];
    });
    g.add(c);
  }

  // 异常留痕 1：同 jxb_id 但课程名不一致
  final byJxb = <String, List<XkCourse>>{};
  for (final c in all.where((c) => c.jxbId.isNotEmpty)) {
    byJxb.putIfAbsent(c.jxbId, () => []).add(c);
  }
  byJxb.forEach((jxb, list) {
    final names = list.map((c) => c.kcmc).toSet();
    if (names.length > 1) {
      notes.add('同一教学班标识($jxb)对应多个课程名，数据异常，已分别展示，请以教务系统为准。');
    }
  });

  // 异常留痕 2：不同 jxb_id 但指纹相同 → 疑似同一教学班（轮次间标识变化），不静默合并
  final byFp = <String, Set<String>>{};
  for (final c in all.where((c) => c.identityTier == 1 && c.sksj.isNotEmpty)) {
    byFp.putIfAbsent(c.fingerprint, () => <String>{}).add(c.jxbId);
  }
  final suspectJxb = <String>{};
  byFp.forEach((fp, jxbSet) {
    if (jxbSet.length > 1) suspectJxb.addAll(jxbSet);
  });

  // 异常留痕 1b：同一 jxb_id 落进多个身份键（字段缺失/大小写差异等）→ 同班被拆开，必须提示
  final byJxbKeys = <String, Set<String>>{};
  for (final c in all.where((c) => c.jxbId.isNotEmpty)) {
    byJxbKeys.putIfAbsent(c.jxbId, () => <String>{}).add(c.identityKey);
  }
  byJxbKeys.forEach((jxb, keys) {
    if (keys.length > 1) {
      notes.add('同一教学班标识($jxb)存在字段差异，已分别展示，请以教务系统为准。');
    }
  });

  final merged = <XkMergedCourse>[];
  var tier3Groups = 0;
  for (final k in order) {
    final list = groups[k]!;
    // 展示主体：取字段最全的一次
    XkCourse base = list.first;
    var best = _fieldCount(base);
    for (final c in list) {
      final n = _fieldCount(c);
      if (n > best) {
        base = c;
        best = n;
      }
    }
    final byRound = <String, XkObservation>{};
    final roundOrder = <String>[];
    for (final c in list) {
      // 空 xkkzId 行统一归并到 (unknown) 观测（不再每行一个伪入口，评审L2）
      final key = c.xkkzId.isEmpty ? '(unknown)' : c.xkkzId;
      final prev = byRound[key];
      if (prev == null) {
        roundOrder.add(key);
        byRound[key] = XkObservation(
          xkkzId: key,
          xklc: c.xklc,
          label: c.xkkzId.isEmpty ? '(未知入口)' : '',
          cap: c.cap,
          selected: c.selected,
          state: 'data',
          count: 1,
        );
      } else {
        // 同入口多行：快照取最后一行，但累计行数（不再静默覆盖）并在卡上留痕
        byRound[key] = XkObservation(
          xkkzId: key,
          xklc: c.xklc,
          label: prev.label,
          cap: c.cap,
          selected: c.selected,
          state: prev.state,
          count: prev.count + 1,
        );
      }
    }
    final cNotes = <String>[];
    if (base.identityTier == 3) {
      tier3Groups++;
    }
    if (base.identityTier == 2) {
      cNotes.add('该条目按 教师+时间 指纹匹配（列表未提供教学班标识），未含场地信息。');
    }
    if (suspectJxb.contains(base.jxbId)) {
      cNotes.add('疑似同一教学班在轮次间标识变化（教师与时间相同但教学班ID不同），未自动合并，请以教务系统为准。');
    }
    if (byRound.values.any((o) => o.count > 1)) {
      cNotes.add('同一入口存在多行记录，容量/已选为最后一行的快照。');
    }
    final mergedTags = <String>{for (final c in list) ...c.tags};
    // 类别合并（诉求 #11）：按观测顺序并集、去重保序——先到的来源类别排前面，
    // 同一类别跨入口重复观测只保留一个。tags 仍是并集兼容口径，两者不互相改写。
    final seenCats = <String>{};
    final mergedCategories = <String>[
      for (final c in list)
        for (final t in c.categories)
          if (seenCats.add(t)) t,
    ];
    final mergedSlots = <Map<String, dynamic>>[
      for (final c in list) ...c.slots,
    ];
    merged.add(XkMergedCourse(
      base: base,
      byRound: byRound,
      roundOrder: roundOrder,
      notes: cNotes,
      tags: mergedTags.toList(),
      categories: mergedCategories,
      slots: mergedSlots,
    ));
  }
  if (tier3Groups > 0) {
    notes.add('$tier3Groups 个条目缺少教学班标识，仅按课程聚合，无法区分平行班，请以教务系统为准。');
  }
  return XkMergeResult(courses: merged, notes: notes);
}

int _fieldCount(XkCourse c) {
  var n = 0;
  if (c.kch.isNotEmpty) n++;
  if (c.kchId.isNotEmpty) n++;
  if (c.jxbId.isNotEmpty) n++;
  if (c.jxbmc.isNotEmpty) n++;
  if (c.teacher.isNotEmpty) n++;
  if (c.sksj.isNotEmpty) n++;
  if (c.cdmc.isNotEmpty) n++;
  if (c.xqjmc.isNotEmpty) n++;
  if (c.xf != null) n++;
  if (c.cap != null) n++;
  if (c.selected != null) n++;
  // 标签/时隙也是展示与冲突判断的关键字段：带标签的观测更应成为 base。
  if (c.tags.isNotEmpty) n += 2;
  if (c.categories.isNotEmpty) n++;
  if (c.slots.isNotEmpty) n++;
  if (c.subTerm.isNotEmpty) n++;
  return n;
}

/// 星期显示名（1=周一 .. 7=周日；越界返回 ''）
String weekdayLabel(int day) {
  if (day < 1 || day > 7) return '';
  return const ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'][day];
}
