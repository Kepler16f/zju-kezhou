/// data/zju_parse.dart — 教务响应解析纯函数（无 IO，供 zju_client 与单测共用）。
/// 字段依据正方教务系统公开接口行为：学期藏于选课课号 xkkh（"T20232024-1…" 中段），
/// 成绩原始值可能是百分数/等级/中文；学号前缀含入学年份。
library;

/// xkkh（选课课号）→ 学期 "2023-A"。取其中 "YYYYYYYY-S" 模式（如 20232024-1）。
String? semesterFromXkkh(String xkkh) {
  final m = RegExp(r'(\d{4})(\d{4})-([12])').firstMatch(xkkh);
  if (m == null) return null;
  final start = int.parse(m.group(1)!);
  final end = int.parse(m.group(2)!);
  if (end != start + 1) return null; // 非连续学年，防误匹配
  return '$start-${m.group(3) == '1' ? 'A' : 'B'}';
}

/// 学号 → 入学年级。浙大学号 "32xxxx…" 第 2-3 位为入学年后两位（3260009999 → 2026）。
String? inferGradeFromStudentId(String? studentId) {
  if (studentId == null) return null;
  final m = RegExp(r'^3(\d{2})').firstMatch(studentId.trim());
  return m == null ? null : '20${m.group(1)}';
}

const _wordScore = {
  '优秀': 90, '良好': 80, '中等': 70, '及格': 60, '合格': 75, '通过': 75,
  'A+': 95, 'A': 90, 'A-': 87, 'B+': 83, 'B': 80, 'B-': 77,
  'C+': 73, 'C': 70, 'C-': 67, 'D': 60, 'F': 0,
};

/// 单条 zdbk 成绩 item → Record Schema 课程行。字段名与正方 xscjcx 接口对齐。
/// 绩点口径对齐 Helechron Grade 模型：jd=五分制绩点（教务权威值）；
/// creditIncluded 排除弃修/待录/缓考/无效；gpaIncluded 再排除及格/不合格与线上课(xtwkc)。
Map<String, dynamic>? gradeItemToCourse(Map<String, dynamic> item) {
  final name = (item['kcmc'] ?? '').toString().trim();
  if (name.isEmpty) return null;
  final credits = double.tryParse((item['xf'] ?? '').toString().trim()) ?? 0.0;
  final xkkh = (item['xkkh'] ?? '').toString();
  final semester = semesterFromXkkh(xkkh) ??
      (item['xnxq'] != null ? semesterFromXkkh('T${item['xnxq']}') : null) ??
      'unknown';
  final original = (item['cj'] ?? '').toString().trim();
  final numeric = int.tryParse(RegExp(r'\d+').firstMatch(original)?.group(0) ?? '');
  final hundred = numeric ?? _wordScore[original.toUpperCase()] ?? _wordScore[original] ?? 0;
  final fivePoint = double.tryParse((item['jd'] ?? '').toString()) ?? 0.0;
  const excluded = {'弃修', '待录', '缓考', '无效'};
  final creditIncluded = !excluded.contains(original);
  final gpaIncluded = creditIncluded &&
      !const {'及格', '不合格'}.contains(original) &&
      !xkkh.contains('xtwkc');
  return {
    'course_id': (item['kch'] ?? item['kcdm'] ?? '').toString(),
    'name': name,
    'credits': credits,
    'grade': hundred,
    'five_point': fivePoint > 0 ? fivePoint : fiveFromScore(hundred),
    'five_point_source': fivePoint > 0 ? 'jd' : 'fallback',
    'passed': hundred >= 60 && !const {'不及格', '不合格', '缺考'}.contains(original),
    'credit_included': creditIncluded,
    'gpa_included': gpaIncluded,
    'semester': semester,
    'category': (item['kcxzmc'] ?? item['kclbmc'] ?? item['kcxz'] ?? '').toString(),
    'original': original,
    'xkkh': xkkh,
  };
}

/// 百分制 → 五分制的兜底参考换算（仅当教务 jd 缺失时使用，UI 会标注"参考换算"）。
double fiveFromScore(int hundred) {
  if (hundred >= 95) return 5.0;
  if (hundred >= 90) return 4.8;
  if (hundred >= 85) return 4.5;
  if (hundred >= 82) return 4.2;
  if (hundred >= 78) return 4.0;
  if (hundred >= 75) return 3.7;
  if (hundred >= 72) return 3.3;
  if (hundred >= 68) return 3.0;
  if (hundred >= 64) return 2.3;
  if (hundred >= 60) return 1.7;
  return 0.0;
}

/// 五分制 → 4.3 制（对齐 Helechron：>4 走映射表，避免 5.0 当 5.0 用）。
double fourFromFive(double five) {
  final map = {5.0: 4.3, 4.8: 4.2, 4.5: 4.1, 4.2: 4.0};
  if (five > 4.0) return map[five] ?? 4.0;
  return five;
}

/// 从成绩集合推"当前学期"：取最晚一条已修学期（其下学期为计划起点）。
String? currentSemesterFrom(List<Map<String, dynamic>> courses) {
  String? latest;
  for (final c in courses) {
    final s = c['semester'] as String?;
    if (s != null && s != 'unknown' && (latest == null || s.compareTo(latest) > 0)) {
      latest = s;
    }
  }
  return latest;
}
