/// data/ai_prompts.dart — AI 解读的系统提示词与发送载荷组装（合规关键件）。
///
/// 边界（设计评审C定稿；改文案必须同步 prompts/m5_select.md 与设置页「数据与合规」）：
///  - 数字与结论只能引用输入 JSON；禁止计算、排序、推荐倾向、生成课表、预测结果；
///  - 发送白名单：课程名/学分/性质/缺口数字/候选教学班信息/本学期课表课程名与时段/用户问题；
///  - 免责声明与页脚由 UI 层硬拼接，不交给模型（本文件只提供常量）。
library;

import 'dart:convert';

import '../engine/disclaimer.dart';
import '../engine/selection.dart';

/// 面板标题（评审C：命名不得有「帮你选」倾向，且避开「课程答疑」撞题面）。
const String kAiPanelTitle = 'AI 解读（可选）· 只翻译，不替你做选择';

/// 发送前常驻提示（首次发送前需用户确认一次）。
const String kAiSendNotice =
    '开启后仅发送：课程名/学分/性质/缺口数字/候选教学班信息、本学期课表课程名与时段、'
    '与你的问题；不发送：学号、姓名、成绩、凭证、方案原文。请勿在提问中输入个人信息。';

/// 合规弹窗的数据口径段（settings_page 引用本常量，禁止另写一份——文案分叉即事故）。
const String kAiComplianceDataNote =
    '「AI 解读」出厂预置公益免费端点（无需 Key；也可换自有服务或关闭），'
    '首次发送前会弹出「发送范围确认」。仅发送课程名/学分/性质/缺口数字/'
    '候选教学班信息、本学期课表课程名与时段、与你的问题；绝不发送学号、姓名、成绩明细、'
    '教务凭证、方案原文或原始成绩单文本；请勿在提问中输入个人信息。AI 密钥（若换用自有'
    '服务）与教务凭证同存于本机沙箱，「一键清除全部本地数据」会一并删除。'
    '公益通道偶有限流属正常现象。';

/// 越界回退文案（输入拦截与输出兜底共用；评审C定稿）。
const String kAiBoundaryFallback =
    '我不能替你决定选哪门，也不能生成课表。可以帮你复述建议卡、整理要向导师/教务确认的问题；'
    '请携带本页建议卡与导师/教务确认。';

/// AI 输出页脚（UI 硬拼接，复制按钮同附）。
const String kAiFooter =
    '以上解读由 AI 根据本机计算结果生成，仅供与导师/教务沟通参考；'
    '本工具不替你选课、不生成课表；正式认定以教务系统为准。';

/// 候选列表脚注（排序不代表推荐）。
const String kCandidatesOrderNote = '列表按课程代码排序，不代表推荐或优先次序。';

/// 容量/已选脚注（快照语义，不预测结果）。
const String kCapacityNote =
    '容量与已选人数为查询时刻快照；筛选、调剂与余量释放以教务系统规则为准，本工具不预测结果。';

/// 固定问题 chips（自由输入之外的稳妥入口）。
const List<String> kAiQuickQuestions = <String>[
  '解释这份建议卡',
  '这门课为什么标记了冲突',
  '帮我整理与导师核对的问题',
];

/// 系统提示词（评审C推荐的 8 条硬规则；prompts/m5_select.md 是本文件的仓库级副本，同步改）。
String buildGuidanceSystemPrompt() => '''
你是选课建议卡的解读节点。你只把输入 JSON（建议卡与审计报告数字）翻译成文字，不是分析师、不是计算器、不替用户做决定。
硬性规则（违反任何一条即为事故）：
1. 课程名、学分、性质、时间、容量、轮次、缺口数字只能原样引用输入 JSON；禁止加总、平均、比较、换算、推算、编造。
2. 禁止任何选择倾向：不得出现「建议选/优先/其次/推荐/备选/更适合/值得选/容易选上/比较稳/成功率高」等措辞；不得对课程或教学班排序、分级、贴好差标签；列表只能按课程代码排序并注明「排序不代表推荐次序」。
3. 禁止生成课表或方案：不得输出「选 A、B、C 三门」式组合，不得判断多门候选相互之间是否冲突或可同选；冲突结论只能引用输入 JSON 中「与本学期课表」的既有标记。
4. 禁谈结果预测：能否选上、筛选、调剂、余量释放一律只写「规则以教务系统为准，本工具无法预测」，不得给出概率、把握、「稳不稳」的任何判断。
5. 禁止新增输入 JSON 中不存在的课程、教师、时间、地点，禁止「你还可以了解……」「比如……」式补充。
6. 输出固定三段：1)事实复述（逐条引用既有值）；2)风险提示（逐条原样转述既有 warnings）；3)核对清单——每一条必须是向导师/教务确认的疑问句（例：「请与教务确认：本教学班是否面向我的年级开放？」），不得写成待办动作。
7. 输入为空的字段如实写「未标注/以教务系统为准」，不得用常识补全。
8. 不要自行添加任何免责或承诺语句（界面会统一附加；若与界面声明冲突，以界面为准）。
''';

/// 越界关键词拦截（输入侧预检）：命中即直接回退边界文案，不发请求。
/// 匹配前先去掉全部空白（评审实测「帮 我 选」这类空格拆分可绕过朴素 contains）。
/// 宁愿多拦（回退文案会引导用户去用建议卡与核对清单），拦住的是"求推荐/求排课"类意图。
List<String> findBoundaryTriggers(String input) {
  // 注意：不设裸词『建议』——它会撞上界面自身的快捷问题「解释这份建议卡」；
  // 只拦带求推荐意图的组合（选课建议/给个建议/求建议）。
  const triggers = [
    '帮我排', '排课表', '排一下', '排个课表', '列个课表', '替我选', '帮我选', '帮我挑',
    '该选哪', '选哪门', '哪个好', '哪门好', '比较好', '推荐', '优先', '选课建议',
    '给个建议', '求建议', '最好选', '建议选', '备选', '概率', '能选上', '稳不稳',
    '比较稳', '成功率', '容易选上', '排序', '排个序', '三门',
  ];
  final compact = input.replaceAll(RegExp(r'\s+'), '');
  final hits = <String>[];
  for (final t in triggers) {
    if (compact.contains(t)) hits.add(t);
  }
  return hits;
}

/// AI 输出的第二道防线（输出侧预检，评审定稿）：模型偶发无视提示词时兜住底线。
/// 命中禁用倾向词/组合句式 → 整段替换为边界文案（宁可误杀：本机建议卡仍完整可用）。
/// 规则与 prompts/m5_select.md 规则 2/3 同源；「与当前课表重叠：周X 第N节」这类
/// 引用既有 JSON 的冲突复述不受影响。
String sanitizeAiOutput(String text) {
  final compact = text.replaceAll(RegExp(r'\s+'), '');
  const banned = [
    '建议选', '优先选', '优先', '其次', '推荐', '备选', '更适合', '值得选',
    '容易选上', '比较稳', '稳不稳', '成功率高', '成功率', '概率', '帮你选', '替你选',
  ];
  for (final b in banned) {
    if (compact.contains(b)) return kAiBoundaryFallback;
  }
  // 组合选课句式（"选 A、B、C 三门"式）与成品课表形态
  if (RegExp(r'选\s*[A-CＡ-Ｃ]').hasMatch(text)) return kAiBoundaryFallback;
  if (compact.contains('课表如下') || compact.contains('选课方案') || compact.contains('三门课')) {
    return kAiBoundaryFallback;
  }
  return text;
}

/// 可转发告警类型白名单（评审定稿，勿放宽）：
/// - `failed_recheck`（文案内嵌不及格分数——实测曾把「成绩 55」送进载荷，critical 泄漏）
///   与 `unmatched_courses`（含成绩单未匹配课程名）**明确排除**；
/// - 其余类型文本只含课程名/缺口数字/时间冲突描述，属发送白名单。
const List<String> kForwardableWarningTypes = [
  'prereq_gap',
  'prereq_same_semester',
  'offering_closed',
  'graduation_risk',
  'time_conflict',
];

/// 审计报告 → 发送子集（白名单字段；不含姓名/学号/成绩）。
/// 注意：报告本身虽无姓名学号，但 **warnings 原文可能内嵌成绩数字**（failed_recheck），
/// 因此 warnings 必须走 kForwardableWarningTypes 过滤，绝不能整段透传（历史事故见上）。
Map<String, dynamic>? auditSubsetOf(Map<String, dynamic>? report) {
  if (report == null) return null;
  final summary = <Map<String, dynamic>>[];
  for (final m in (report['summary'] as List? ?? const [])) {
    if (m is! Map) continue;
    final missing = <Map<String, dynamic>>[];
    for (final c in (m['missing_courses'] as List? ?? const []).take(12)) {
      if (c is Map) {
        missing.add({
          'course': c['name'],
          'credits': c['credits'],
          'offered': c['offered'],
        });
      }
    }
    summary.add({
      'module': m['module_path'],
      'required': m['required'],
      'earned': m['earned'],
      'gap': m['gap'],
      'status': m['status'],
      'missing': missing,
    });
  }
  final warnings = <String>[];
  for (final w in (report['warnings'] as List? ?? const [])) {
    if (w is Map && kForwardableWarningTypes.contains('${w['type']}') && w['text'] != null) {
      warnings.add('${w['text']}');
    }
  }
  return {
    'totals': report['totals'],
    'summary': summary,
    if (warnings.isNotEmpty) 'warnings': warnings.take(12).toList(),
    'disclaimer': kDisclaimer,
  };
}

/// 组装单次请求的 user 载荷（JSON 文本）。
String buildUserPayload({
  required SelectionAdvice advice,
  Map<String, dynamic>? auditReport,
  required String question,
}) {
  final data = <String, dynamic>{
    '建议卡': adviceToPromptJson(advice),
    '培养方案缺口': auditSubsetOf(auditReport),
    '用户问题': question,
  };
  return const JsonEncoder.withIndent('  ').convert(data);
}
