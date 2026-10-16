/// engine/selection.dart — 选课候选分析（确定性纯函数；不并入 audit.build() 输出）。
///
/// 边界（设计评审结论，改动前先读）：
/// - 数字与结论只来自确定性计算：方案缺开课季信息（offered 为 null，runtime 方案常态）时
///   输出「未知」，绝不回显 audit 报告对未知的关闭语义（那是另一套口径，见 docs）；
/// - 输出独立 JSON 形状，不进 report.schema —— 双引擎 parity 只锁 audit.build；
/// - 时间冲突依赖调用方提供的当前课表时隙；课表未知时如实降级并在 notes 声明「未检查」，
///   绝不把「没检查」渲染成「没有冲突」；
/// - 与 audit 同口径的匹配算法统一走 engine/matching.dart（单一事实源）。
library;

import '../data/xk_models.dart';
import 'disclaimer.dart';
import 'matching.dart';
import 'timeline.dart';

/// 分析输入。candidates 为已合并候选（顺序即展示顺序，UI 负责按课程代码排序）。
class SelectionRequest {
  final List<XkMergedCourse> candidates;
  final List<Map<String, dynamic>> transcript; // 已修记录行（Record Schema courses）
  final List<Map<String, dynamic>> planCourses; // plan['courses']
  final List<Map<String, dynamic>> planModules; // plan['modules']（module_id/module_path；类别对照用）
  final String currentSemester; // '2026-A'；空 = 未知
  final List<Map<String, dynamic>> currentTimetableSlots; // 当前课表时隙（kbList 解析产物）
  final bool currentTimetableKnown; // 课表是否成功取得（false → 冲突检查降级）
  const SelectionRequest({
    required this.candidates,
    this.transcript = const [],
    this.planCourses = const [],
    this.planModules = const [],
    this.currentSemester = '',
    this.currentTimetableSlots = const [],
    this.currentTimetableKnown = false,
  });
}

/// 选课标签 ↔ 培养方案类别 的确定性对照表（诉求 #5）。
/// 每个类别的 value 为「探针词」：标签文本包含任一探针，则用该探针在方案模块路径
/// （module_path）里找归属。探针特意选双方都常见的高频词（如「通识」「专业核心」），
/// 避免把「专业选修」标签探进「专业核心」模块（探针互斥）。未命中 = 类别未知，绝不硬归类。
const Map<String, List<String>> _tagCategoryHints = {
  '思政': ['思政', '思想政治', '马克思', '习思想', '毛概', '形势与政策', '四史', '党史', '国史', '改革史', '社会史'],
  '体育': ['体育', '军训', '军事理论', '国防'],
  '外语': ['外语', '英语', '日语', '德语', '法语', '俄语', '西语', '韩语'],
  '计算机基础': ['计算机基础', '程序设计基础', '计算思维'],
  '通识': ['通识', '文化基础', '通选'],
  '数理': ['数学', '物理', '概率', '统计', '线性代数', '高等数学'],
  '专业核心': ['专业核心', '核心课'],
  '专业选修': ['专业选修', '限选', '专选'],
  '实践': ['实践', '实习', '实验课', '毕业设计', '毕业论文', '劳动'],
  '创新创业': ['创新创业', '大创', '竞赛'],
};

/// 标签 → 探针词（命中的第一个；未命中 null）。
String? _tagProbe(String tag) {
  final t = tag.replaceAll(RegExp(r'\s'), '');
  for (final hints in _tagCategoryHints.values) {
    for (final h in hints) {
      if (t.contains(h)) return h;
    }
  }
  return null;
}

/// 单个候选课程相对培养方案/课表的关系分析。
class CandidateAnalysis {
  final XkMergedCourse course;
  final String role; // gap（缺口未修）| passed（已修）| extra（方案外）| unknown
  final String matchConfidence; // exact | fuzzy | none
  final String? planCourseId;
  final String? planName;
  final String offeredMatch; // yes | no | unknown（方案未标注开课季 → unknown）
  final bool prereqIncomplete;
  final List<String> conflictTexts; // 与当前课表的冲突描述
  final List<String> notes; // 逐条留痕（未知/降级/异常）
  final String? planCategory; // 归属类别（标签归入的方案 module_path；未命中为 null）
  final String categoryBasis; // plan | tag | unknown（方案课程自带 module 优先，标签兜底）
  const CandidateAnalysis({
    required this.course,
    required this.role,
    required this.matchConfidence,
    this.planCourseId,
    this.planName,
    this.offeredMatch = 'unknown',
    this.prereqIncomplete = false,
    this.conflictTexts = const [],
    this.notes = const [],
    this.planCategory,
    this.categoryBasis = 'unknown',
  });
}

/// 建议卡（AI 解读的输入、UI 直接渲染的数据源；数字全部出自本文件）。
class SelectionAdvice {
  final List<CandidateAnalysis> candidates;
  final Map<String, int> counts; // gap/passed/extra/unknown/conflict 计数
  final List<Map<String, dynamic>> warnings; // {type,level,text,refs}（xk_ 前缀，与 audit 类型不混）
  final List<String> notes; // 全局留痕
  final String disclaimer;
  const SelectionAdvice({
    required this.candidates,
    required this.counts,
    required this.warnings,
    required this.notes,
    required this.disclaimer,
  });
}

SelectionAdvice buildSelectionAdvice(SelectionRequest req) {
  final warnings = <Map<String, dynamic>>[];
  final notes = <String>[];

  // 1) 已修集合（统一匹配算法；未命中不抵扣，与 audit 同口径）
  final (matched, _) = matchRecordToPlan(req.transcript, {'courses': req.planCourses});
  final passedIds = <String>{};
  for (final pair in matched) {
    if (isPassed(pair[0] as Map<String, dynamic>)) {
      passedIds.add('${(pair[1] as Map<String, dynamic>)['course_id']}');
    }
  }
  final planById = <String, Map<String, dynamic>>{
    for (final c in req.planCourses) '${c['course_id']}': c,
  };

  // 2) 学期与开课季口径
  int? semIdx;
  String? term;
  if (req.currentSemester.isNotEmpty) {
    try {
      semIdx = Timeline.semIdx(req.currentSemester);
      term = req.currentSemester.endsWith('-A')
          ? '秋'
          : (req.currentSemester.endsWith('-B') ? '春' : null);
    } catch (_) {
      semIdx = null;
      term = null;
    }
  }
  if (term == null) {
    notes.add('当前学期未知：未做开课季匹配，开课信息请以教务系统为准。');
  }
  if (!req.currentTimetableKnown) {
    notes.add('当前课表未知：未做时间冲突检查（不代表没有冲突）。');
  }

  // 3) 逐条分析
  final analyses = <CandidateAnalysis>[];
  final counts = <String, int>{'gap': 0, 'passed': 0, 'extra': 0, 'unknown': 0, 'conflict': 0};
  // 方案模块对照：module_id → module_path（类别归属以方案为准，诉求 #6）。
  final modulePaths = <String, String>{
    for (final m in req.planModules)
      if (m['module_id'] != null)
        '${m['module_id']}': '${m['module_path'] ?? m['module_id']}',
  };
  for (final mc in req.candidates) {
    final base = mc.base;
    final cNotes = <String>[];
    final conflicts = <String>[];

    // 与方案匹配（course_id 精确 → 名称 0.85 兜底）；kch 可能为空 → 只走名称
    final row = <String, dynamic>{
      'course_id': base.kch.isEmpty ? null : base.kch,
      'name': base.kcmc,
    };
    final (m2, _) = matchRecordToPlan([row], {'courses': req.planCourses});
    Map<String, dynamic>? planCourse;
    var confidence = 'none';
    if (m2.isNotEmpty) {
      planCourse = m2.first[1] as Map<String, dynamic>;
      confidence = (base.kch.isNotEmpty && '${planCourse['course_id']}' == base.kch)
          ? 'exact'
          : 'fuzzy';
    }

    // 归属类别（诉求 #5/#6）：以培养方案为准——命中方案课程取其模块路径；
    // 未命中（方案外）再用 zdbk 课程标签对照方案模块类别（标签→类别 hint→module_path）。
    String? planCategory;
    var categoryBasis = 'unknown';
    if (planCourse != null) {
      final mid = '${planCourse['module_id'] ?? ''}';
      if (modulePaths.containsKey(mid)) {
        planCategory = modulePaths[mid];
        categoryBasis = 'plan';
      }
    } else if (base.tags.isNotEmpty && req.planCourses.isNotEmpty) {
      // 标签命中探针词，再以探针在方案模块路径（module_path）里找归属（确定性判据）。
      for (final tag in base.tags) {
        final probe = _tagProbe(tag);
        if (probe == null) continue;
        final hit = modulePaths.values.where((p) => p.contains(probe)).toList();
        if (hit.isNotEmpty) {
          planCategory = hit.first;
          categoryBasis = 'tag';
          cNotes.add('类别按选课标签「$tag」对照方案推断（课程本身不在方案清单中）。');
          break;
        }
      }
    }

    var role = 'unknown';
    var offeredMatch = 'unknown';
    var prereqIncomplete = false;
    if (planCourse == null) {
      role = 'extra';
      cNotes.add('未在培养方案中匹配到同名课程（可能为方案外课程或名称差异过大）。');
    } else {
      final pid = '${planCourse['course_id']}';
      if (passedIds.contains(pid)) {
        role = 'passed';
        cNotes.add('该课程你已修读（重复修读是否计入学分以教务系统为准）。');
      } else {
        role = 'gap';
      }
      // 开课季口径：offered 缺失 = 未知（绝不当作「不开课」）
      final offered = planCourse['offered'];
      if (offered is List && offered.isNotEmpty) {
        if (term == null) {
          offeredMatch = 'unknown';
        } else {
          final years = planCourse['offered_years'];
          if (years is List && years.isNotEmpty && semIdx != null) {
            final y = semIdx ~/ 2;
            if (!years.contains(y)) {
              offeredMatch = 'no';
              cNotes.add('方案标注隔年开课，本学年不在开课年。');
            } else {
              offeredMatch = offered.contains(term) ? 'yes' : 'no';
              if (offeredMatch == 'no') cNotes.add('与方案标注的开课季不符（本学期为$term）。');
            }
          } else {
            offeredMatch = offered.contains(term) ? 'yes' : 'no';
            if (offeredMatch == 'no') cNotes.add('与方案标注的开课季不符（本学期为$term）。');
          }
        }
      } else {
        cNotes.add('方案未标注开课季：开课信息未知，请以教务系统为准。');
      }
      // 先修
      final prereq = planCourse['prereq'];
      if (prereq is List && prereq.isNotEmpty) {
        final missing = prereq.where((p) => !passedIds.contains('$p')).toList();
        if (missing.isNotEmpty) {
          prereqIncomplete = true;
          final names = missing.map((p) => planById['$p']?['name'] ?? '$p').join('、');
          cNotes.add('先修未完成：$names。');
          final page = (planCourse['source'] is Map) ? (planCourse['source'] as Map)['page'] : null;
          warnings.add({
            'type': 'xk_prereq_incomplete',
            'level': 'yellow',
            'text': '《${base.kcmc}》的先修课程（$names）尚未修读，选课时请确认是否满足先修要求。',
            'refs': ['${planCourse['course_id']}@p${page ?? '-'}'],
          });
        }
      }
      if (offeredMatch == 'no') {
        warnings.add({
          'type': 'xk_offering_check',
          'level': 'yellow',
          'text': '《${base.kcmc}》与方案标注的开课季不符，请核对本学期是否实际开课。',
          'refs': ['${planCourse['course_id']}@p${(planCourse['source'] is Map) ? ((planCourse['source'] as Map)['page'] ?? '-') : '-'}'],
        });
      }
    }

    // 时间冲突（仅在课表已知时；时隙解析失败也如实留痕）
    if (req.currentTimetableKnown) {
      if (base.slots.isEmpty && base.sksj.isNotEmpty) {
        cNotes.add('该课程的上课时间未能解析，冲突未检查。');
      } else if (base.slots.isNotEmpty && req.currentTimetableSlots.isNotEmpty) {
        final hit = Timeline.slotsConflict(base.slots, req.currentTimetableSlots);
        if (hit != null) {
          // slotsConflict 返回交集区间；单节/单周不渲染成「4-4节」这种形态
          final wk = weekdayLabel(hit['day'] as int);
          final sec = hit['start'] == hit['end']
              ? '第${hit['start']}节'
              : '第${hit['start']}-${hit['end']}节';
          final wks = hit['week_start'] == hit['week_end']
              ? '第${hit['week_start']}周'
              : '第${hit['week_start']}-${hit['week_end']}周';
          final text = '与当前课表重叠：$wk $sec（$wks）';
          conflicts.add(text);
          warnings.add({
            'type': 'xk_time_conflict',
            'level': 'yellow',
            'text': '《${base.kcmc}》$text，请与教务系统核对。',
            'refs': const [],
          });
        }
      }
    }

    if (base.identityTier == 3) {
      cNotes.add('该条目缺少教学班标识，无法区分平行班（请以教务系统为准）。');
    }
    cNotes.addAll(mc.notes);

    counts[role] = (counts[role] ?? 0) + 1;
    if (conflicts.isNotEmpty) counts['conflict'] = (counts['conflict'] ?? 0) + 1;

    analyses.add(CandidateAnalysis(
      course: mc,
      role: role,
      matchConfidence: confidence,
      planCourseId: planCourse == null ? null : '${planCourse['course_id']}',
      planName: planCourse == null ? null : '${planCourse['name']}',
      offeredMatch: offeredMatch,
      prereqIncomplete: prereqIncomplete,
      conflictTexts: conflicts,
      notes: cNotes,
      planCategory: planCategory,
      categoryBasis: categoryBasis,
    ));
  }

  if (req.candidates.isEmpty) {
    notes.add('尚无候选选课数据：请先在选课页拉取选课列表。');
  }
  return SelectionAdvice(
    candidates: analyses,
    counts: counts,
    warnings: warnings,
    notes: notes,
    disclaimer: kDisclaimer,
  );
}

/// 建议卡 → AI 提示词的输入 JSON（只含允许发送的字段；学号/姓名/成绩明细绝不包含）。
/// 由调用方（AI 面板）组装 system 提示词时使用；本函数本身不做网络。
Map<String, dynamic> adviceToPromptJson(SelectionAdvice advice) => {
      'counts': advice.counts,
      'candidates': [
        for (final a in advice.candidates)
          {
            'course': a.course.base.kcmc,
            'teacher': a.course.base.teacher,
            'time': a.course.base.sksj,
            'capacity': a.course.base.cap,
            'selected': a.course.base.selected,
            'credits': a.course.base.xf,
            'role': a.role,
            'offered_match': a.offeredMatch,
            'prereq_incomplete': a.prereqIncomplete,
            'conflicts': a.conflictTexts,
            'notes': a.notes,
            'rounds': a.course.roundOrder.length,
            'tags': a.course.base.tags,
            'category': a.planCategory,
            'category_basis': a.categoryBasis,
          },
      ],
      'warnings': advice.warnings.map((w) => w['text']).toList(),
      'notes': advice.notes,
      'disclaimer': advice.disclaimer,
    };
