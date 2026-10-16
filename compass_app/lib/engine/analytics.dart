/// engine/analytics.dart — 学业分析引擎（纯函数，无 IO/无 LLM）。
/// 口径对齐 Helechron GpaHelper/Grade 模型：
///  - 五分制绩点 jd 为教务权威值；缺失时用 fiveFromScore 兜底（UI 标注"参考换算"）
///  - gpaIncluded 排除弃修/待录/缓考/无效/及格(二级制)/xtwkc 线上课
///  - 4.3 制 = five>4 走映射 {5.0:4.3, 4.8:4.2, 4.5:4.1, 4.2:4.0}，否则原值
///  - 加权百分制 = Σ(成绩×学分)/Σ学分（仅 gpaIncluded）
library;

import '../data/zju_parse.dart' show fourFromFive, fiveFromScore;

class Analytics {
  /// 按学期分桶（semester 升序；'unknown' 归入"未识别"组排最前）
  static List<String> semesterOrder(List<Map<String, dynamic>> courses) {
    final sems = courses
        .map((c) => c['semester'] as String? ?? 'unknown')
        .toSet()
        .toList();
    sems.sort((a, b) {
      if (a == 'unknown') return -1;
      if (b == 'unknown') return 1;
      return a.compareTo(b);
    });
    return sems;
  }

  /// 通过判定：passed 字段优先，缺省按 grade>=60 推断
  /// （与 engine/matching.dart 的 isPassed 同口径；样例/手写记录常缺 passed 字段，
  ///  若按缺省 false 处理会把整份成绩单排除在 GPA 之外——历史 bug）。
  static bool isPassed(Map<String, dynamic> c) {
    final p = c['passed'];
    if (p is bool) return p;
    final g = (c['grade'] as num?)?.toDouble();
    return g != null && g >= 60;
  }

  static bool _gpaIncluded(Map<String, dynamic> c) =>
      (c['gpa_included'] as bool? ?? true) && isPassed(c);

  /// 五分绩点：教务 jd 权威值优先；缺失（粘贴/样例模式）用百分制参考换算兜底。
  static double fiveOf(Map<String, dynamic> c) {
    final jd = (c['five_point'] as num?)?.toDouble() ?? 0.0;
    if (jd > 0) return jd;
    return fiveFromScore((c['grade'] as num?)?.toInt() ?? 0);
  }

  static double _five(Map<String, dynamic> c) => fiveOf(c);

  static double _credit(Map<String, dynamic> c) =>
      (c['credits'] as num?)?.toDouble() ?? 0.0;

  static double _grade(Map<String, dynamic> c) =>
      (c['grade'] as num?)?.toDouble() ?? 0.0;

  /// 总览：五分制/4.3 制/加权百分制 GPA + 已获学分（creditIncluded 且五分>0 或 xtwkc）
  static Map<String, double> overall(List<Map<String, dynamic>> courses) {
    var sumFive = 0.0, sumFour = 0.0, sumHundred = 0.0, gpaCredits = 0.0;
    var earned = 0.0;
    for (final c in courses) {
      final credit = _credit(c);
      if ((c['credit_included'] as bool? ?? true) && _five(c) > 0) earned += credit;
      if (!_gpaIncluded(c)) continue;
      sumFive += _five(c) * credit;
      sumFour += fourFromFive(_five(c)) * credit;
      sumHundred += _grade(c) * credit;
      gpaCredits += credit;
    }
    return {
      'five': gpaCredits == 0 ? 0.0 : sumFive / gpaCredits,
      'four': gpaCredits == 0 ? 0.0 : sumFour / gpaCredits,
      'weighted': gpaCredits == 0 ? 0.0 : sumHundred / gpaCredits,
      'gpa_credits': gpaCredits,
      'earned_credits': earned,
    };
  }

  /// 学期走势：每学期 {semester, four, weighted, credits, cumulative_four}。
  static List<Map<String, double>> semesterTrend(List<Map<String, dynamic>> courses) {
    final out = <Map<String, double>>[];
    var cumSum = 0.0, cumCredits = 0.0;
    for (final sem in semesterOrder(courses)) {
      final bucket = courses
          .where((c) => (c['semester'] as String? ?? 'unknown') == sem)
          .toList();
      final o = overall(bucket);
      final gpaCredits = bucket.where(_gpaIncluded).fold<double>(0, (s, c) => s + _credit(c));
      cumSum += (o['four']! * gpaCredits);
      cumCredits += gpaCredits;
      out.add({
        'semester_idx': sem == 'unknown' ? -1 : _semesterIndex(sem).toDouble(),
        'four': o['four']!,
        'weighted': o['weighted']!,
        'credits': gpaCredits,
        'cumulative_four': cumCredits == 0 ? 0.0 : cumSum / cumCredits,
      });
    }
    return out;
  }

  static int _semesterIndex(String s) {
    final m = RegExp(r'(\d{4})-([AB])').firstMatch(s);
    if (m == null) return 0;
    return int.parse(m.group(1)!) * 2 + (m.group(2) == 'B' ? 1 : 0);
  }

  /// 学分看板：按课程 category（kcxzmc）聚合已获学分（含未匹配类目）。
  static List<Map<String, dynamic>> creditByCategory(List<Map<String, dynamic>> courses) {
    final byCat = <String, double>{};
    for (final c in courses) {
      if (!_gpaIncluded(c) && !isPassed(c)) continue;
      if (!(c['credit_included'] as bool? ?? true)) continue;
      final cat = (c['category'] as String? ?? '').trim();
      final key = cat.isEmpty ? '未分类' : cat;
      byCat[key] = (byCat[key] ?? 0) + _credit(c);
    }
    final entries = byCat.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final e in entries) {'category': e.key, 'credits': e.value}
    ];
  }

  /// GPA 模拟器（what-if）：现有课程 + 计划课程（学分×预期五分绩点）→ 预测 4.3 制 GPA。
  static double simulateGpa(List<Map<String, dynamic>> courses,
      List<Map<String, dynamic>> planned) {
    var sumFour = 0.0, credits = 0.0;
    for (final c in courses) {
      if (!_gpaIncluded(c)) continue;
      sumFour += fourFromFive(_five(c)) * _credit(c);
      credits += _credit(c);
    }
    for (final p in planned) {
      sumFour += fourFromFive(_five(p)) * _credit(p);
      credits += _credit(p);
    }
    return credits == 0 ? 0.0 : sumFour / credits;
  }

  /// 反推：距目标 4.3 制 GPA，剩余 R 学分需要达到的平均五分绩点（闭式解，无解返回 null）。
  static double? requiredFiveForTarget(
      List<Map<String, dynamic>> courses, double targetFour, double remainingCredits) {
    var sumFour = 0.0, credits = 0.0;
    for (final c in courses) {
      if (!_gpaIncluded(c)) continue;
      sumFour += fourFromFive(_five(c)) * _credit(c);
      credits += _credit(c);
    }
    if (remainingCredits <= 0) return null;
    final neededFour = targetFour * (credits + remainingCredits) - sumFour;
    final neededAvgFour = neededFour / remainingCredits;
    if (neededAvgFour < 0 || neededAvgFour > 4.3) return null;
    // 4.3 制 → 五分制反查（映射表逆向，落在区间取下界）
    final reverse = <double, double>{4.3: 5.0, 4.2: 4.8, 4.1: 4.5, 4.0: 4.2};
    for (final e in reverse.entries) {
      if (neededAvgFour >= e.key) return e.value;
    }
    return neededAvgFour.clamp(0.0, 4.0); // ≤4.0 时五分=四分
  }
}
