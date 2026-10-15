/// data/credential_store.dart — 凭证与缓存的合规存储层（纯 Dart，无原生插件依赖）。
///
/// 设计约束（对应开发方案红线）：
///  - 学号/密码存 App 沙箱私有目录，混淆编码，权限仅限当前用户（移动端沙箱由 OS 隔离，
///    桌面端为用户 profile 内私有文件）。P1 升级路径：实现 [SecureBackend] 接口接入
///    系统Keystore/Keychain（各平台原生），当前纯文件后端保证全平台零原生依赖可构建。
///  - SSO Cookie（iPlanetDirectoryPro / JSESSIONID / route）仅驻内存，进程退出即消失。
///  - 教务数据缓存（成绩 JSON）放 App 沙箱，提供一键清除。
///  - 任何值不写日志。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// P1 升级点：接入系统级安全存储（Android Keystore / iOS Keychain / Win 凭据管理器）。
/// 当前 FileBackend 已满足"数据不出设备 + 用户态隔离"；接口留好替换缝。
abstract class SecureBackend {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> deleteAll();
}

class CredentialStore {
  /// 可选注入沙箱目录：App 内省略（走 path_provider）；
  /// 离线探针/诊断工具（纯 Dart VM，无插件）传入已知沙箱路径复用同一套文件。
  CredentialStore([Directory? sandboxDir]) {
    if (sandboxDir != null) _dir = sandboxDir;
  }

  final Map<String, String> _memory = {}; // Cookie 专用，永不落盘
  Directory? _dir;

  Future<Directory> _dirGet() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    _dir = Directory(p.join(base.path, 'compass'));
    if (!await _dir!.exists()) await _dir!.create(recursive: true);
    return _dir!;
  }

  Future<File> _credFile() async => File(p.join((await _dirGet()).path, 'cred.dat'));

  Future<void> saveCredentials(String username, String password) async {
    final f = await _credFile();
    await f.writeAsString(_obfuscate('$username\n$password'));
  }

  Future<(String, String)?> loadCredentials() async {
    try {
      final f = await _credFile();
      if (!await f.exists()) return null;
      final parts = _deobfuscate(await f.readAsString()).split('\n');
      if (parts.length == 2 && parts[0].isNotEmpty) return (parts[0], parts[1]);
    } catch (_) {/* 沙箱不可用（测试环境等） */}
    return null;
  }

  Future<void> deleteCredentials() async {
    try {
      final f = await _credFile();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 内存 Cookie 域（SSO/会话，进程生命周期）
  void setMemory(String key, String value) => _memory[key] = value;
  String? memory(String key) => _memory[key];
  void removeMemory(String key) => _memory.remove(key);
  void clearMemory() => _memory.clear();

  /// 教务数据缓存（沙箱文件，可清除；失败静默——缓存只是优化不是依赖）
  Future<void> saveCache(String name, String content) async {
    try {
      final f = File(p.join((await _dirGet()).path, 'cache_$name.json'));
      await f.writeAsString(content);
    } catch (_) {}
  }

  Future<String?> readCache(String name) async {
    try {
      final f = File(p.join((await _dirGet()).path, 'cache_$name.json'));
      if (await f.exists()) return await f.readAsString();
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearCache() async {
    try {
      final d = await _dirGet();
      for (final f in d.listSync().whereType<File>()) {
        if (p.basename(f.path).startsWith('cache_')) await f.delete();
      }
    } catch (_) {}
  }

  /// 二进制缓存（培养方案 PDF）：与文本缓存同目录、同名前缀，
  /// 于是"清除数据"里既有的 cache_ 前缀清理逻辑会自动一并删除。
  Future<String?> saveBinaryCache(String name, List<int> bytes) async {
    try {
      final f = File(p.join((await _dirGet()).path, 'cache_$name'));
      await f.writeAsBytes(bytes, flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  Future<List<int>?> readBinaryCache(String name) async {
    try {
      final f = File(p.join((await _dirGet()).path, 'cache_$name'));
      if (await f.exists()) return await f.readAsBytes();
    } catch (_) {/* 沙箱不可用 */}
    return null;
  }

  // 轻量混淆（非加密）：避免明文出现在文件系统搜索中；真实防护来自 OS 沙箱隔离。
  String _obfuscate(String s) => base64.encode(utf8.encode(s.split('').reversed.join()));
  String _deobfuscate(String s) => utf8.decode(base64.decode(s)).split('').reversed.join();
}

