/// data/consent_store.dart — 隐私政策同意状态的本机存储（首启门禁的数据层）。
///
/// 用途：
///  - 记录用户是否已就**当前版本**《隐私政策》(assets/privacy_policy.md) 达成同意，
///    供首启门禁页（lib/pages/privacy_consent_page.dart）判断"要不要再问一次"。
///  - 同时记录同意时间与所同意正文的摘要（sha256 前 12 位），让"同意的是哪一版正文"
///    可被审计、可被复核（与 docs/隐私政策.md 逐字对照）。
///
/// 设计约束（对应开发方案红线）：
///  - 同意记录只落本机沙箱私有目录（<sandbox>/consent.json），不联网、不含任何教务数据、
///    不含姓名学号等个人信息；设置页「一键清除全部本地数据」一并删除（清除逻辑见 main.dart）。
///  - **任何 IO 异常静默降级**：读失败 / 文件损坏 / 字段缺失 / 版本不匹配一律视为
///    "未同意"（false）；写失败不抛异常——首启门禁在启动最早期执行，抛异常会把 App 拖崩。
///  - 沙箱目录获取方式与凭证层一致：path_provider 的 getApplicationSupportDirectory()
///    （+ 'compass' 子目录），测试可注入临时目录复用同一套文件逻辑。
///  - 刻意**不做混淆编码**（与 cred.dat/ai.cfg 不同）：同意记录是面向用户可解释的证据，
///    需要能被审计工具直接读取；其防护来自 OS 沙箱隔离而非编码。
///  - 绝不写日志。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 当前隐私政策版本号。
/// 政策正文修订并重新评审后递增；递增后旧记录（policyVersion 不匹配）视为未同意，
/// 用户需重新确认——避免"旧版本的同意被当成新版本的同意"。
const String kConsentPolicyVersion = '1.0';

/// 所同意正文的摘要：assets/privacy_policy.md 的 sha256 前 12 位。
///
/// 来源：对随包发布的 assets/privacy_policy.md（与仓库 docs/隐私政策.md 逐字节相同）计算
///   sha256 = a4a66b9e542335eb59811deef3ba51ce4955bdda22cbe720643b90efba17154a
///   取前 12 位 = 8ac743853766
/// 正文一旦改动必须重算并同步本常量（否则同意记录与正文脱钩，审计无法自证）。
const String kConsentPolicySha = 'a4a66b9e5423';

/// 隐私政策同意状态存储。
///
/// 用法：
/// ```dart
/// final store = ConsentStore();
/// if (!await store.isAccepted()) {
///   // 首启：展示同意页；同意后 await store.accept();
/// }
/// ```
class ConsentStore {
  /// [sandboxDir]：可选注入沙箱目录（测试注入临时目录）；
  /// 省略时走 path_provider 的应用支持目录 + 'compass' 子目录（与凭证/缓存同目录）。
  ConsentStore({String? sandboxDir}) : _injectedDir = sandboxDir;

  final String? _injectedDir;

  /// 沙箱目录：注入优先；否则 path_provider getApplicationSupportDirectory() + 'compass'。
  /// 失败（插件未注册 / 目录不可用）时抛异常，由各公开方法静默兜底。
  Future<Directory> _sandbox() async {
    final injected = _injectedDir;
    if (injected != null && injected.isNotEmpty) return Directory(injected);
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'compass'));
  }

  /// 同意记录文件：<sandbox>/consent.json。
  Future<File> _consentFile() async =>
      File(p.join((await _sandbox()).path, 'consent.json'));

  /// 是否已就当前版本政策取得同意。
  ///
  /// 文件缺失 / 内容损坏 / 字段缺失或为空 / 记录的是旧版本 → 一律 false。
  /// **绝不抛异常**（启动早期调用，抛错会阻断整个启动流程）。
  Future<bool> isAccepted() async {
    try {
      final f = await _consentFile();
      if (!await f.exists()) return false;
      final raw = json.decode(await f.readAsString());
      if (raw is! Map) return false;
      final version = raw['policyVersion'];
      final acceptedAt = raw['acceptedAt'];
      final sha = raw['policySha'];
      if (version is! String || version.isEmpty) return false;
      if (acceptedAt is! String || acceptedAt.isEmpty) return false;
      if (sha is! String || sha.isEmpty) return false;
      // 政策版本升级后旧同意失效：需重新确认。
      return version == kConsentPolicyVersion;
    } catch (_) {
      return false; // 坏文件 / 沙箱不可用：按未同意处理，绝不抛异常打断启动
    }
  }

  /// 写入同意记录（当前版本 + 当前 UTC 时间 + 当前正文摘要）。
  /// 写失败静默（不崩启动）：结果是下次启动会再问一次，用户可重新同意。
  Future<void> accept() async {
    try {
      final dir = await _sandbox();
      if (!await dir.exists()) await dir.create(recursive: true);
      final f = File(p.join(dir.path, 'consent.json'));
      final payload = <String, Object?>{
        'policyVersion': kConsentPolicyVersion,
        'acceptedAt': DateTime.now().toUtc().toIso8601String(),
        'policySha': kConsentPolicySha,
      };
      await f.writeAsString(json.encode(payload), flush: true);
    } catch (_) {/* 沙箱不可用（测试环境 / 权限异常）：静默 */}
  }

  /// 撤回同意（删除记录文件）；文件不存在视为已撤回。失败静默。
  Future<void> withdraw() async {
    try {
      final f = await _consentFile();
      if (await f.exists()) await f.delete();
    } catch (_) {/* 沙箱不可用：静默 */}
  }

  /// 同意记录文件路径（供设置页「一键清除全部本地数据」定位删除）。
  /// 沙箱不可用时返回空串（调用方按"无需清除"处理）。
  Future<String> consentFilePath() async {
    try {
      return (await _consentFile()).path;
    } catch (_) {
      return '';
    }
  }
}
