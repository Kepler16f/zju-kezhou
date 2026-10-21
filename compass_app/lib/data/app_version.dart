/// data/app_version.dart — 版本号唯一来源（纯 Dart，全平台含鸿蒙可用）。
///
/// 与 pubspec.yaml 的 `version:` 保持同步，由 `test/app_version_test.dart`
/// 强制校验（漂移即测试失败）。设置页展示这里的完整版本号。
/// 发版流程：改 pubspec.yaml → 同步改这里 → 跑测试。
library;

/// 完整版本号（含构建号），如 "0.10.9+9"。
const String kAppVersion = '0.13.11+25';

/// 展示用短版本（形如 "0.10.9"）。
String get kAppVersionShort => kAppVersion.split('+').first;
