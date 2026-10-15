/// data/diagnostic_log.dart — 登录/取数链路步骤日志（内存环形缓冲 + 落盘持久化）。
/// 用途：登录失败或原生崩溃后，重启仍可从磁盘读最后记录（崩溃取证）。
/// 只记录步骤名/耗时/错误摘要，绝不记录密码、票据值。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class DiagEntry {
  final DateTime at;
  final String step;
  final String level; // ok / warn / error
  final String detail;
  DiagEntry(this.step, this.level, this.detail) : at = DateTime.now();
  String format() =>
      '${at.toString().substring(11, 19)} [$level] $step: $detail';
}

class DiagnosticLog {
  DiagnosticLog._();
  static final DiagnosticLog instance = DiagnosticLog._();
  final List<DiagEntry> _ring = [];
  static const _max = 80;
  File? _file;
  bool _fileTried = false;

  void record(String step, {String level = 'ok', String detail = ''}) {
    final e = DiagEntry(step, level, detail);
    _ring.add(e);
    if (_ring.length > _max) _ring.removeAt(0);
    _persist(e);
  }

  /// 落盘（追加；失败静默——日志绝不能影响主流程）
  Future<void> _persist(DiagEntry e) async {
    try {
      if (!_fileTried) {
        _fileTried = true;
        final dir = await getApplicationSupportDirectory();
        final d = Directory(p.join(dir.path, 'compass'));
        if (!await d.exists()) await d.create(recursive: true);
        _file = File(p.join(d.path, 'diag.log'));
        await _file!.writeAsString('\n==== session ${DateTime.now()} ====\n',
            mode: FileMode.append);
      }
      await _file?.writeAsString('${e.format()}\n', mode: FileMode.append);
    } catch (_) {}
  }

  void clear() {
    _ring.clear();
    _fileTried = false;
    _file = null;
  }

  List<DiagEntry> get entries => List.unmodifiable(_ring);

  String dump() => _ring.map((e) => e.format()).join('\n');
}
