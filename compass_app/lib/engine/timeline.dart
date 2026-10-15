/// engine/timeline.dart — 学期时间轴、开课判定、时间冲突。
/// 与 Python 版 engine/common.py 行为逐一对齐（金标对照测试守护，见 test/golden_parity_test.dart）。
library;

class Timeline {
  static const passGrade = 60.0;
  static const semestersPerGradeYear = 2;

  /// '2023-A' -> (2023, 0)；A=秋(0) B=春(1)
  static List<int> semKey(String s) {
    final p = s.trim().split('-');
    return [int.parse(p[0]), p[1].toUpperCase() == 'A' ? 0 : 1];
  }

  static String semStr(List<int> k) => '${k[0]}-${k[1] == 0 ? 'A' : 'B'}';

  /// 学期字符串 -> 学期索引整数（单调，可直接比较）
  static int semIdx(Object s) {
    final key = s is int ? [s ~/ 2, s % 2] : semKey(s.toString());
    return key[0] * semestersPerGradeYear + key[1];
  }

  /// 学期索引 -> '2027-A(秋)'
  static String idxStr(int idx) {
    final y = idx ~/ 2, t = idx % 2;
    return '$y-${t == 0 ? 'A' : 'B'}(${t == 0 ? '秋' : '春'})';
  }

  /// 课程在学年窗口 [fromYear, fromYear+horizon) 内的开课学期索引（升序）。
  /// offered_years 为 null 表示每年开；指定时按"学年标签"过滤。
  static List<int> courseOpenIdx(Map<String, dynamic> course, int fromYear, int horizon) {
    final offered = (course['offered'] as List? ?? []).map((e) => e.toString()).toSet();
    final cycleRaw = course['offered_years'];
    final cycle = cycleRaw == null
        ? null
        : (cycleRaw as List).map((e) => e is int ? e : int.parse(e.toString())).toList();
    final out = <int>[];
    for (var y = fromYear; y < fromYear + horizon; y++) {
      if (cycle != null && !cycle.contains(y)) continue;
      if (offered.contains('秋')) out.add(y * 2);
      if (offered.contains('春')) out.add(y * 2 + 1);
    }
    out.sort();
    return out;
  }

  /// 两门课时间区间重叠检测（同星期、节次相交、周次相交）
  static Map<String, dynamic>? slotsConflict(List slotsA, List slotsB) {
    for (final sa in slotsA.cast<Map<String, dynamic>>()) {
      for (final sb in slotsB.cast<Map<String, dynamic>>()) {
        if (sa['day'] != sb['day']) continue;
        if (sa['start'] > sb['end'] || sb['start'] > sa['end']) continue;
        final ws = [sa['week_start'] ?? 1, sb['week_start'] ?? 1].reduce((a, b) => a > b ? a : b);
        final we = [sa['week_end'] ?? 16, sb['week_end'] ?? 16].reduce((a, b) => a < b ? a : b);
        if (ws <= we) {
          return {
            'day': sa['day'],
            'start': [sa['start'], sb['start']].reduce((a, b) => a > b ? a : b),
            'end': [sa['end'], sb['end']].reduce((a, b) => a < b ? a : b),
            'week_start': ws,
            'week_end': we,
          };
        }
      }
    }
    return null;
  }

  /// 同学期计划课表两两查冲突
  static List<Map<String, dynamic>> checkPlan(List<Map<String, dynamic>> courses) {
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < courses.length; i++) {
      for (var j = i + 1; j < courses.length; j++) {
        final hit = slotsConflict(courses[i]['time_slots'] ?? [], courses[j]['time_slots'] ?? []);
        if (hit != null) {
          out.add({
            'a': courses[i]['name'],
            'b': courses[j]['name'],
            'detail': '周${hit['day']} 第${hit['start']}-${hit['end']}节'
                '（第${hit['week_start']}-${hit['week_end']}周）重叠',
          });
        }
      }
    }
    return out;
  }
}

/// difflib.SequenceMatcher.ratio 的精确移植（与 Python 结果一致，匹配阈值语义才不会漂移）。
class SeqMatcher {
  final String a, b;
  final Map<String, List<int>> b2j = {};
  final List<int> matchingBlocks = [];

  SeqMatcher(this.a, this.b) {
    for (var i = 0; i < b.length; i++) {
      b2j.putIfAbsent(b[i], () => []).add(i);
    }
    _findMatchingBlocks(0, a.length, 0, b.length);
  }

  void _findMatchingBlocks(int alo, int ahi, int blo, int bhi) {
    final q = _findLongestMatch(alo, ahi, blo, bhi);
    final i = q[0], j = q[1], k = q[2];
    if (k > 0) {
      if (alo < i && blo < j) _findMatchingBlocks(alo, i, blo, j);
      matchingBlocks.add(i);
      matchingBlocks.add(j);
      matchingBlocks.add(k);
      if (i + k < ahi && j + k < bhi) _findMatchingBlocks(i + k, ahi, j + k, bhi);
    }
  }

  List<int> _findLongestMatch(int alo, int ahi, int blo, int bhi) {
    int besti = alo, bestj = blo, bestsize = 0;
    final j2len = <int, int>{};
    for (var i = alo; i < ahi; i++) {
      final newj2len = <int, int>{};
      for (final j in b2j[a[i]] ?? const <int>[]) {
        if (j < blo) continue;
        if (j >= bhi) break;
        final k = (j2len[j - 1] ?? 0) + 1;
        newj2len[j] = k;
        if (k > bestsize) {
          besti = i - k + 1;
          bestj = j - k + 1;
          bestsize = k;
        }
      }
      j2len.addAll(newj2len);
    }
    return [besti, bestj, bestsize];
  }

  double ratio() {
    var matches = 0;
    for (var i = 0; i < matchingBlocks.length; i += 3) {
      matches += matchingBlocks[i + 2];
    }
    final t = a.length + b.length;
    return t == 0 ? 1.0 : 2.0 * matches / t;
  }
}

/// difflib.get_close_matches(name, names, n=1, cutoff=0.85) 的移植
List<String> getCloseMatches(String word, List<String> possibilities, {int n = 1, double cutoff = 0.85}) {
  final scored = <List<Object>>[];
  for (final p in possibilities) {
    final r = SeqMatcher(word, p).ratio();
    if (r >= cutoff) scored.add([r, p]);
  }
  scored.sort((x, y) => (y[0] as double).compareTo(x[0] as double));
  return scored.take(n).map((e) => e[1] as String).toList();
}
