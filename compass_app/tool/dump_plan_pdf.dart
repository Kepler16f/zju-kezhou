// tool/dump_plan_pdf.dart — 开发用：把真实方案 PDF 抽成文本并打印，便于核对解析规则。
// 用法：dart run tool/dump_plan_pdf.dart [pdf路径] [--raw] [--grep 关键词]
import 'dart:convert';
import 'dart:io';

import 'package:compass_app/data/pdf_text_extractor.dart';
import 'package:compass_app/data/plan_pdf_parse.dart';

void main(List<String> args) {
  final path = args.firstWhere((a) => !a.startsWith('--'),
      orElse: () =>
          'C:/Users/胡天泽/AppData/Roaming/edu.zju.compass/compass_app/compass/cache_planpdf_20261321.pdf');
  final raw = args.contains('--raw');
  final gi = args.indexOf('--grep');
  final needle = gi >= 0 && gi + 1 < args.length ? args[gi + 1] : null;

  final bytes = File(path).readAsBytesSync();
  final text = extractPdfText(bytes);

  // --out=<file>：以 UTF- 落盘（绕开 Windows 控制台代码页把中文写坏）。
  final oi = args.indexWhere((a) => a.startsWith('--out='));
  if (oi >= 0) {
    File(args[oi].substring('--out='.length)).writeAsStringSync(text,
        encoding: utf8, flush: true);
    stdout.writeln('已写出 UTF-8 文本 ${text.length} 字符');
    return;
  }
  stdout.writeln('== PDF: $path  (${bytes.length} bytes)');
  stdout.writeln('== 文本长度：${text.length}');

  if (raw) {
    if (needle == null) {
      stdout.writeln(text);
    } else {
      var i = 0, n = 0;
      while (true) {
        final k = text.indexOf(needle, i);
        if (k < 0) break;
        n++;
        stdout.writeln('--- 命中 #$n @ $k ---');
        stdout.writeln(text.substring(
            (k - 200).clamp(0, text.length), (k + 400).clamp(0, text.length)));
        i = k + needle.length;
        if (n > 12) break;
      }
      stdout.writeln('== 命中 $n 处');
    }
    return;
  }

  final ps = parsePlanPdfText(text);
  stdout.writeln('== 板块 ${ps.sections.length} 个（一级 ${ps.topCount} 个），课程 ${ps.courseCount} 门');
  for (final s in ps.sections) {
    final pad = '  ' * (s.level - 1);
    stdout.writeln('$pad[L${s.level}] ${s.label}  ${s.creditsRaw}学分'
        '  课程 ${s.courses.length} 门  说明 ${s.notes.length} 条');
    for (final n in s.notes.take(3)) {
      stdout.writeln('$pad     · ${n.length > 90 ? '${n.substring(0, 90)}…' : n}');
    }
    for (final c in s.courses.take(3)) {
      stdout.writeln('$pad     - ${c.code} ${c.name} ${c.credits} ${c.semester}');
    }
  }
  if (ps.qualityNotes.isNotEmpty) {
    stdout.writeln('== 质量：${ps.qualityNotes.join("；")}');
  }
}
