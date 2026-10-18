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

  /// 沙箱根目录路径（分享包等用户可见文件通道的落盘位置；失败抛异常由调用方兜底）。
  Future<String> sandboxDirPath() async => (await _dirGet()).path;

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

  /// 桌面端窗口偏好落盘（ui.cfg）：关闭窗口是否收起到托盘。
  /// 与 ai.cfg 同理不用 cache_ 前缀（清缓存不该重置用户习惯），
  /// 一键清除全量数据时由 [deleteUiPrefs] 显式删除。
  Future<void> saveCloseToTray(bool value) async {
    try {
      final f = File(p.join((await _dirGet()).path, 'ui.cfg'));
      await f.writeAsString(_obfuscate(json.encode({'closeToTray': value})));
    } catch (_) {/* 沙箱不可用（测试环境等）：静默 */}
  }

  /// 读取窗口偏好：缺文件/坏内容一律回落默认值（开启收起到托盘），绝不抛异常。
  Future<bool> loadCloseToTray() async {
    try {
      final f = File(p.join((await _dirGet()).path, 'ui.cfg'));
      if (!await f.exists()) return true;
      final raw = json.decode(_deobfuscate(await f.readAsString()));
      if (raw is Map && raw['closeToTray'] is bool) {
        return raw['closeToTray'] as bool;
      }
    } catch (_) {/* 坏文件按默认值处理 */}
    return true;
  }

  Future<void> deleteUiPrefs() async {
    try {
      final f = File(p.join((await _dirGet()).path, 'ui.cfg'));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 底栏布局偏好（nav.cfg）：页签顺序 + 启动默认首页（诉求 #9）。
  /// 与 ui.cfg 同理不用 cache_ 前缀（清缓存不重置界面习惯）；两个键同文件，
  /// 写入走"读-改-写"合并，避免 saveTabOrder / saveDefaultTab 互相覆盖；
  /// 一键清除全量数据时可调用 [deleteNavPrefs]。
  /// 规范索引（2026-10-18 需求 #1 起为五个）：0=学业 1=方案 2=选课 3=工具 4=设置。
  static const _defaultTabOrder = '0,1,2,3,4';

  /// 页签顺序落盘：逗号分隔的规范索引（0..4 全排列），如 '2,0,1,4,3'。
  Future<void> saveTabOrder(String order) => _saveNavPref('tabOrder', order);

  /// 读取页签顺序：新版五个 0..4 全排列原样返回；旧版四个 0..3 全排列自动迁移
  /// （原 3=设置 → 4，「工具」3 追加在末尾）；坏内容回落默认。绝不抛异常。
  Future<String> loadTabOrder() async {
    try {
      final f = File(p.join((await _dirGet()).path, 'nav.cfg'));
      if (await f.exists()) {
        final raw = json.decode(_deobfuscate(await f.readAsString()));
        if (raw is Map) {
          final v = raw['tabOrder'];
          if (v is String) {
            if (_isValidTabOrder5(v)) return v;
            final migrated = _migrateTabOrder4(v);
            if (migrated != null) return migrated;
          }
        }
      }
    } catch (_) {/* 坏文件/沙箱不可用：回落默认 */}
    return _defaultTabOrder;
  }

  /// 启动默认首页落盘：规范索引 0..4。
  Future<void> saveDefaultTab(int index) => _saveNavPref('defaultTab', index);

  /// 读取启动默认首页。版本判定靠同文件 tabOrder 的形状（main.dart 在
  /// 改默认页时同步落 tabOrder，新版文件必为五个 0..4 全排列）：
  ///  - tabOrder 为新版五排列 → defaultTab 原样（0..4）；
  ///  - tabOrder 为旧版四排列或缺失（旧版只在改动过时才写键）→ 旧索引 3=设置
  ///    迁移为 4；
  ///  - 越界/坏内容 → 0（学业）。绝不抛异常。
  Future<int> loadDefaultTab() async {
    try {
      final f = File(p.join((await _dirGet()).path, 'nav.cfg'));
      if (await f.exists()) {
        final raw = json.decode(_deobfuscate(await f.readAsString()));
        if (raw is Map) {
          final v = raw['defaultTab'];
          if (v is int) {
            final order = raw['tabOrder'];
            final isNewShape = order is String && _isValidTabOrder5(order);
            final isOldShape = !isNewShape && order is String &&
                _migrateTabOrder4(order) != null;
            if (isNewShape) return (v >= 0 && v <= 4) ? v : 0;
            // 旧版存档（四排列或缺 tabOrder 但只有旧 defaultTab）：3=设置→4
            final mapped = v == 3 ? 4 : v;
            return (mapped >= 0 && mapped <= 4) ? mapped : 0;
          }
        }
      }
    } catch (_) {/* 坏文件/沙箱不可用：回落默认 */}
    return 0;
  }

  /// 外语等级选择（需求 #5）：'L1'|'L2'|'L3' 或 null（未选择，引擎按方案原要求）。
  Future<void> saveForeignLevel(String? level) =>
      _saveNavPref('foreignLevel', level ?? '');

  /// 读取外语等级：缺省/空串一律 null（宁缺勿猜），绝不抛异常。
  Future<String?> loadForeignLevel() async {
    try {
      final f = File(p.join((await _dirGet()).path, 'nav.cfg'));
      if (await f.exists()) {
        final raw = json.decode(_deobfuscate(await f.readAsString()));
        if (raw is Map) {
          final v = raw['foreignLevel'];
          if (v is String && (v == 'L1' || v == 'L2' || v == 'L3')) return v;
        }
      }
    } catch (_) {/* 坏文件/沙箱不可用：未选择 */}
    return null;
  }

  Future<void> deleteNavPrefs() async {
    try {
      final f = File(p.join((await _dirGet()).path, 'nav.cfg'));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// nav.cfg 读-改-写合并写入：另一键的旧值原样保留；坏文件按空配置重建。
  Future<void> _saveNavPref(String key, Object value) async {
    try {
      final f = File(p.join((await _dirGet()).path, 'nav.cfg'));
      final data = <String, Object?>{};
      try {
        if (await f.exists()) {
          final raw = json.decode(_deobfuscate(await f.readAsString()));
          if (raw is Map) {
            for (final e in raw.entries) {
              data[e.key.toString()] = e.value;
            }
          }
        }
      } catch (_) {/* 坏文件：按空配置重写 */}
      data[key] = value;
      await f.writeAsString(_obfuscate(json.encode(data)));
    } catch (_) {/* 沙箱不可用（测试环境等）：静默 */}
  }

  /// '0,1,2,3,4' 形状校验：恰好五个 0..4 的整数索引且不重复（纯函数，宁缺勿猜）。
  static bool _isValidTabOrder5(String s) {
    final seen = <int>{};
    for (final part in s.split(',')) {
      final i = int.tryParse(part.trim());
      if (i == null || i < 0 || i > 4 || !seen.add(i)) return false;
    }
    return seen.length == 5;
  }

  /// 旧版四排列（0..3 全排列，无「工具」）→ 新版五排列：原 3（设置）改 4，
  /// 「工具」(3) 追加末尾。形状不符返回 null（调用方再回落默认）。
  static String? _migrateTabOrder4(String s) {
    final seen = <int>{};
    final parts = <int>[];
    for (final part in s.split(',')) {
      final i = int.tryParse(part.trim());
      if (i == null || i < 0 || i > 3 || !seen.add(i)) return null;
      parts.add(i);
    }
    if (parts.length != 4) return null;
    return '${parts.map((i) => i == 3 ? 4 : i).join(',')},3';
  }

  // 轻量混淆（非加密）：避免明文出现在文件系统搜索中；真实防护来自 OS 沙箱隔离。
  String _obfuscate(String s) => base64.encode(utf8.encode(s.split('').reversed.join()));
  String _deobfuscate(String s) => utf8.decode(base64.decode(s)).split('').reversed.join();
}

