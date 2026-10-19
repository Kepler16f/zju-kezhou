/// data/teacher_rating.dart — 教师评分本地表（数据源统一叫「查老师」）。
///
/// 红线：本文件零网络请求——评分只做本地表匹配（assets/data/teacher_ratings.json
/// 由主线灌入；解析层对空/缺失/脏数据一律健壮，绝不抛异常）。
library;

import 'dart:convert';

/// 数据源名称（全项目统一口径，不得出现其他叫法）。
const String kTeacherRatingSource = '查老师';

/// 单个教师的评分快照。avg 定死 0-10（对齐「查老师」站点原生十分制，
/// 实测高分榜 9.95、教师页 9.39/10）；越界或无法解析的条目在建表时被丢弃。
class TeacherRating {
  final String teacher; // 教师名（原文书写形式）
  final double avg; // 平均分 0-10
  final int count; // 评价人数（未知 → 0）
  final List<String> tags; // 标签（评好/评差词，可为空）
  final String source; // 数据源名称（默认「查老师」）

  const TeacherRating({
    required this.teacher,
    required this.avg,
    this.count = 0,
    this.tags = const [],
    this.source = kTeacherRatingSource,
  });

  /// 展示口径一行：`评分 9.39/10（422 人评 · 查老师）`；未命中由调用方显示「评分：暂无」。
  String get displayText => '评分 ${avg.toStringAsFixed(1)}/10'
      '（${count < 0 ? 0 : count} 人评 · $source）';

  @override
  String toString() => 'TeacherRating($teacher, $avg, $count, $source)';
}

/// 教师名归一（顶层纯函数，test/teacher_rating_test.dart 直连断言）：
/// trim、删除所有空白（半角/全角/制表/换行）、统一小写——
/// 「 张 三 」与「张三」等价，「Zhang San」与「zhangsan」等价。
String normalizeTeacherName(String name) =>
    name.replaceAll(RegExp(r'[\s\u3000]+'), '').toLowerCase();

/// 本地评分表：Map<归一化教师名, TeacherRating>。
class TeacherRatingStore {
  final Map<String, TeacherRating> _ratings;

  const TeacherRatingStore(this._ratings);

  /// 空表（加载失败/未灌数据时的安全降级——UI 一律显示「评分：暂无」）。
  static const TeacherRatingStore empty = TeacherRatingStore({});

  int get length => _ratings.length;
  bool get isEmpty => _ratings.isEmpty;

  /// 顶层必须为 Map；脏结构（非 Map / 值非 Map / avg 缺失或越界 / count 非数值）
  /// 逐条跳过，绝不抛异常。同归一键重复时后者覆盖前者（不做合并猜测）。
  factory TeacherRatingStore.fromJson(Object? json) {
    if (json is! Map) return const TeacherRatingStore({});
    final out = <String, TeacherRating>{};
    for (final entry in json.entries) {
      final teacher = '${entry.key}'.trim();
      final key = normalizeTeacherName(teacher);
      if (key.isEmpty) continue;
      final r = entry.value;
      if (r is! Map) continue;
      final avg = _asDouble(r['avg']);
      // NaN/Infinity/越界（站点十分制上限 10）/无法解析 → 整条丢（宁缺勿猜）
      if (avg == null || !avg.isFinite || avg < 0 || avg > 10) continue;
      final count = _asDouble(r['count']);
      final tags = r['tags'];
      final source = r['source'];
      out[key] = TeacherRating(
        teacher: teacher, // 显示用原始书写，匹配用归一键
        avg: avg,
        count: (count != null && count.isFinite) ? count.round() : 0,
        tags: tags is List
            ? [
                for (final t in tags)
                  if (t is String && t.trim().isNotEmpty) t.trim()
              ]
            : const [],
        source: source is String && source.trim().isNotEmpty
            ? source.trim()
            : kTeacherRatingSource,
      );
    }
    return TeacherRatingStore(out);
  }

  /// JSON 文本 → 表对象；空/解析失败返回空表，绝不抛（调用方无需 catch）。
  factory TeacherRatingStore.fromSerialized(String? source) {
    if (source == null) return empty;
    try {
      return TeacherRatingStore.fromJson(jsonDecode(source));
    } catch (_) {
      return empty;
    }
  }

  /// 查一位教师：先精确原键，再归一化键；未命中返回 null。
  /// [courseName] 为按课过滤预留口径（当前表按教师全局，宁缺勿猜不做模糊推断）。
  TeacherRating? lookup(String teacher, String? courseName) {
    final key = normalizeTeacherName(teacher);
    if (key.isEmpty) return null;
    return _ratings[key];
  }

  static double? _asDouble(Object? v) => switch (v) {
        final double d => d,
        final int i => i.toDouble(),
        final String s => double.tryParse(s.trim()),
        _ => null,
      };
}
