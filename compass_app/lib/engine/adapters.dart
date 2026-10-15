/// engine/adapters.dart — 三源数据适配：学生粘贴 / 教务导出CSV / （真实接口见 data/zju_adapter.dart）
/// → 统一 Record Schema。与 Python 版 engine/adapters.py 对齐。
library;

import 'dart:convert';

class RecordAdapter {
  static final _line = RegExp(r'^(20\d{2}-[AB])\s+(.+)$');
  static final _numTail = RegExp(r'\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)$');
  static final _idHead = RegExp(r'^([A-Z]{2,4}\d{3,6})\s+(.+)$');
  static final _semNorm = RegExp(r'^(20\d{2})[-/年]?(秋|春|A|B|1|2)');

  static const colMap = {
    '课程名称': 'name', '课程名': 'name', 'name': 'name',
    '学分': 'credits', '成绩': 'grade', 'score': 'grade',
    '开课学期': 'semester', '学期': 'semester', '修读学期': 'semester',
    '课程代码': 'course_id', '课程编号': 'course_id',
  };

  static String? _normSem(String v) {
    final t = v.trim().replaceAll('—', '-').replaceAll('－', '-');
    final m = _semNorm.firstMatch(t);
    if (m != null) {
      const map = {'秋': 'A', 'A': 'A', '1': 'A', '春': 'B', 'B': 'B', '2': 'B'};
      return '${m.group(1)}-${map[m.group(2)]}';
    }
    return RegExp(r'^20\d{2}-[AB]$').hasMatch(t) ? t : null;
  }

  /// 学生粘贴成绩页。返回 (courses, failedLines)
  static (List<Map<String, dynamic>>, List<String>) parsePaste(String text) {
    final courses = <Map<String, dynamic>>[];
    final failed = <String>[];
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final m = _line.firstMatch(line);
      if (m == null) {failed.add(line); continue;}
      final sem = _normSem(m.group(1)!);
      var rest = m.group(2)!.trim();
      double? c, g;
      final nm = _numTail.firstMatch(rest);
      if (nm != null) {
        c = double.parse(nm.group(1)!);
        g = double.parse(nm.group(2)!);
        rest = rest.substring(0, nm.start).trim();
      } else {
        final nm2 = RegExp(r'\s+(\d+(?:\.\d+)?)$').firstMatch(rest);
        if (nm2 != null) {
          c = double.parse(nm2.group(1)!);
          rest = rest.substring(0, nm2.start).trim();
        }
      }
      final idm = _idHead.firstMatch(rest);
      final cid = idm?.group(1);
      final name = (idm?.group(2) ?? rest).trim();
      if (name.isEmpty || c == null || sem == null) {failed.add(line); continue;}
      courses.add({
        'course_id': cid,
        'name': name,
        'credits': c,
        'grade': g,
        'passed': g == null ? null : g >= 60,
        'semester': sem,
      });
    }
    return (courses, failed);
  }

  /// 教务导出 CSV（字符串或行数组）
  static (List<Map<String, dynamic>>, List<String>) parseExportCsv(Object rows) {
    final List<List<String>> grid;
    if (rows is String) {
      grid = _csvRows(rows);
    } else if (rows is List) {
      grid = rows.map((e) => (e as List).map((x) => x.toString()).toList()).toList();
    } else {
      return (<Map<String, dynamic>>[], []);
    }
    if (grid.isEmpty) return (<Map<String, dynamic>>[], []);
    final header = grid.first.map((h) => h.trim()).toList();
    final idx = <String, int>{};
    for (var i = 0; i < header.length; i++) {
      final k = colMap[header[i]];
      if (k != null) idx[k] = i;
    }
    final courses = <Map<String, dynamic>>[];
    final failed = <String>[];
    for (final row in grid.skip(1)) {
      try {
        final name = row[idx['name']!].trim();
        final credits = double.parse(row[idx['credits']!]);
        final sem = idx.containsKey('semester') ? _normSem(row[idx['semester']!]) : null;
        final grade = (idx.containsKey('grade') && row.length > idx['grade']! &&
                row[idx['grade']!].isNotEmpty)
            ? double.parse(row[idx['grade']!])
            : null;
        final cid = idx.containsKey('course_id') && row.length > idx['course_id']!
            ? (row[idx['course_id']!].trim().isEmpty ? null : row[idx['course_id']!].trim())
            : null;
        if (name.isEmpty || credits <= 0 || sem == null) {failed.add(row.join(',')); continue;}
        courses.add({
          'course_id': cid,
          'name': name,
          'credits': credits,
          'grade': grade,
          'passed': grade == null ? null : grade >= 60,
          'semester': sem,
        });
      } catch (_) {
        failed.add(row.join(','));
      }
    }
    return (courses, failed);
  }

  static List<List<String>> _csvRows(String s) {
    final out = <List<String>>[];
    for (final line in const LineSplitter().convert(s)) {
      if (line.trim().isEmpty) continue;
      final cells = <String>[];
      var cur = '';
      var inQ = false;
      for (var i = 0; i < line.length; i++) {
        final ch = line[i];
        if (ch == '"') {
          inQ = !inQ;
        } else if (ch == ',' && !inQ) {
          cells.add(cur);
          cur = '';
        } else {
          cur += ch;
        }
      }
      cells.add(cur);
      out.add(cells);
    }
    return out;
  }

  /// Dify / 本地统一入口：自动嗅探形态 → Record JSON 字符串
  static Map<String, dynamic> run({String recordText = '', Object? csvRows, String studentJson = '{}'}) {
    final student = json.decode(studentJson) as Map<String, dynamic>;
    List<Map<String, dynamic>> courses;
    List<String> failed;
    String source;
    if (csvRows != null) {
      final r = parseExportCsv(csvRows);
      courses = r.$1; failed = r.$2; source = 'export_csv';
    } else if (recordText.contains(',') &&
        RegExp(r'课程|成绩|学分').hasMatch(const LineSplitter().convert(recordText).first)) {
      final r = parseExportCsv(recordText);
      courses = r.$1; failed = r.$2; source = 'export_csv';
    } else {
      final r = parsePaste(recordText);
      courses = r.$1; failed = r.$2; source = 'paste';
    }
    if (courses.isEmpty) {
      return {
        'error': '未能从输入解析出任何成绩记录。请按『学期 课程代码 课程名 学分 成绩』每行一门课重新粘贴，或上传教务导出表。',
        'unparsed': failed.take(5).toList(),
      };
    }
    final rec = <String, dynamic>{
      'student': student,
      'source': source,
      'courses': courses,
    };
    if (failed.isNotEmpty) {
      rec['parse_warnings'] = '以下 ${failed.length} 行未识别，已忽略'
          '（如确属已修课程请单独补录）：${failed.take(3).join(' | ')}';
    }
    return {'record_json': json.encode(rec)};
  }
}
