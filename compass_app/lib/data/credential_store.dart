/// data/credential_store.dart — 凭证与缓存的合规存储层（纯 Dart，无原生插件依赖）。
///
/// 设计约束（对应开发方案红线）：
///  - 学号/密码存 App 沙箱私有目录，混淆编码，权限仅限当前用户（移动端沙箱由 OS 隔离，
///    桌面端为用户 profile 内私有文件）。P1 升级路径：实现 [SecureBackend] 接口接入
///    系统Keystore/Keychain（各平台原生），当前纯文件后端保证全平台零原生依赖可构建。
///  - SSO Cookie（iPlanetDirectoryPro / JSESSIONID / route）仅驻内存，进程退出即消失。
///  - 教务数据缓存（成绩 JSON）放 App 沙箱，提供一键清除。
///  - AI 解读配置（ai.cfg）与凭证同目录同混淆：仅存本机；启用云端 AI 时发送范围见
///    设置页「数据与合规」（评审结论：对外口径为「教务凭证与原始教务数据不出设备，
///    AI 解读默认关闭、启用后仅发送最小字段」，两处文案必须一致）。
///  - 任何值不写日志。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ai_config.dart';

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

  /// Windows 上 path_provider 的目录取自 exe 版本资源（公司名\产品名）——
  /// 应用改名（06de9cf「课舟」）曾导致数据目录漂移、升级后凭证"丢失"（用户反馈 #3）。
  /// 生产环境把数据收敛到固定目录 %APPDATA%\edu.zju.compass\compass（永不漂移），
  /// 并把历史目录（当前产品名 / compass_app / kezhou）里 cred.dat 最新的一份整目录
  /// 归位进来（同名不覆盖、跳过 diag.log、原目录保留可回退）。
  /// 其它平台 bundle id / applicationId 从未变过，path_provider 目录天然稳定。
  /// 测试环境（FLUTTER_TEST=true，flutter test 自动注入）不扫描、不迁移、不建真实目录：
  /// 直接走 path_provider（由测试 mock → 抛异常 → 上层静默回落"未登录"），
  /// widget 测试绝不读写真实用户目录。
  Future<Directory> _dirGet() async {
    if (_dir != null) return _dir!;
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      final b = await getApplicationSupportDirectory();
      _dir = Directory(p.join(b.path, 'compass'));
      return _dir!;
    }
    final appData = Platform.isWindows ? Platform.environment['APPDATA'] : null;
    if (appData == null || appData.isEmpty) {
      final b = await getApplicationSupportDirectory();
      _dir = Directory(p.join(b.path, 'compass'));
      if (!await _dir!.exists()) await _dir!.create(recursive: true);
      return _dir!;
    }
    final fixed = Directory(p.join(appData, 'edu.zju.compass', 'compass'));
    // 候选：固定目录 + 当前产品名目录（path_provider）+ 更早的两个产品名遗留目录。
    final candidates = <Directory>[
      fixed,
      ...await _productNamedDirs(appData),
    ];
    Directory? best;
    DateTime? bestMtime;
    for (final d in candidates) {
      final c = File(p.join(d.path, 'cred.dat'));
      if (!await c.exists()) continue;
      final m = await c.lastModified();
      if (bestMtime == null || m.isAfter(bestMtime)) {
        best = d;
        bestMtime = m;
      }
    }
    _dir = fixed;
    if (!await fixed.exists()) await fixed.create(recursive: true);
    if (best != null && best.path != fixed.path) {
      await _copyInto(target: fixed, source: best); // 历史凭证 → 固定目录
    }
    return _dir!;
  }

  /// 当前产品名目录（走 path_provider）+ 历史产品名（compass_app / kezhou）的 compass 子目录。
  Future<List<Directory>> _productNamedDirs(String appData) async {
    final out = <Directory>[];
    try {
      final b = await getApplicationSupportDirectory();
      out.add(Directory(p.join(b.path, 'compass')));
    } catch (_) {/* 探测失败：跳过该候选 */}
    for (final name in const ['compass_app', 'kezhou']) {
      out.add(Directory(p.join(appData, 'edu.zju.compass', name, 'compass')));
    }
    return out;
  }

  /// 整目录搬入：同名不覆盖、跳过 diag.log；单文件失败不阻断。
  static Future<void> _copyInto(
      {required Directory target, required Directory source}) async {
    try {
      await for (final e in source.list()) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (name == 'diag.log') continue;
        final dst = File(p.join(target.path, name));
        if (await dst.exists()) continue;
        try {
          await e.copy(dst.path);
        } catch (_) {/* 单文件失败不阻断迁移 */}
      }
    } catch (_) {/* 迁移尽力而为 */}
  }

  /// 一次性自愈（公开以便单测直接驱动旧布局迁移）：
  /// 旧数据目录（compass_app / 课舟 / kezhou）里若有凭证，取 cred.dat 最新的一份
  /// 整目录搬入 target（同名不覆盖、跳过诊断日志；旧目录保留可回退）。
  /// 仅在目标目录尚无凭证时触发。_dirGet 的候选扫描已覆盖同样逻辑，
  /// 这里作为可独立测试的纯函数保留。
  static Future<void> migrateLegacyDirs({
    required Directory target,
    required Directory appDataRoot,
  }) async {
    try {
      if (await File(p.join(target.path, 'cred.dat')).exists()) return;
      Directory? best;
      DateTime? bestMtime;
      for (final name in const ['compass_app', '课舟', 'kezhou']) {
        final d = Directory(
            p.join(appDataRoot.path, 'edu.zju.compass', name, 'compass'));
        if (!await d.exists()) continue;
        final c = File(p.join(d.path, 'cred.dat'));
        if (!await c.exists()) continue;
        final m = await c.lastModified();
        if (bestMtime == null || m.isAfter(bestMtime)) {
          best = d;
          bestMtime = m;
        }
      }
      if (best == null) return;
      await _copyInto(target: target, source: best);
    } catch (_) {/* 迁移是尽力而为：失败不阻塞登录主流程 */}
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

  /// 已缓存文件的真实路径（不存在返回 null）；命中缓存时复用，免去重新下载。
  Future<String?> binaryCachePath(String name) async {
    try {
      final f = File(p.join((await _dirGet()).path, 'cache_$name'));
      if (await f.exists()) return f.path;
    } catch (_) {/* 沙箱不可用 */}
    return null;
  }

  /// AI 解读配置落盘（ai.cfg）。**刻意不用 cache_ 前缀**：缓存会被 clearCache 顺带清掉，
  /// 而 AI 密钥被"清缓存"顺手删除是事故（用户会以为配置丢了）；一键清除全量数据时由
  /// main.dart 的 _clearData 显式调用 [deleteAiConfig]。
  Future<void> saveAiConfig(AiConfig config) async {
    try {
      final f = File(p.join((await _dirGet()).path, 'ai.cfg'));
      await f.writeAsString(_obfuscate(json.encode(config.toJson())));
    } catch (_) {/* 沙箱不可用（测试环境等）：静默 */}
  }

  /// 是否存过 AI 配置（ai.cfg 存在与否）。主界面据此区分
  /// 「出厂从未配置（默认给公益免费端点，开箱即用）」与
  /// 「用户显式配置过（含选过关闭）→ 完全尊重用户选择」。
  Future<bool> hasStoredAiConfig() async {
    try {
      return await File(p.join((await _dirGet()).path, 'ai.cfg')).exists();
    } catch (_) {
      return false; // 沙箱不可用：按未存过处理（等价出厂态）
    }
  }

  /// 读取 AI 配置：缺文件/坏内容/未知提供方一律回落未配置（none），绝不抛异常
  /// ——启动早期读配置抛错会把整个 App 拖崩。
  Future<AiConfig> loadAiConfig() async {
    try {
      final f = File(p.join((await _dirGet()).path, 'ai.cfg'));
      if (!await f.exists()) return const AiConfig();
      return AiConfig.fromJson(json.decode(_deobfuscate(await f.readAsString())));
    } catch (_) {
      return const AiConfig();
    }
  }

  Future<void> deleteAiConfig() async {
    try {
      final f = File(p.join((await _dirGet()).path, 'ai.cfg'));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  // 轻量混淆（非加密）：避免明文出现在文件系统搜索中；真实防护来自 OS 沙箱隔离。
  String _obfuscate(String s) => base64.encode(utf8.encode(s.split('').reversed.join()));
  String _deobfuscate(String s) => utf8.decode(base64.decode(s)).split('').reversed.join();
}

