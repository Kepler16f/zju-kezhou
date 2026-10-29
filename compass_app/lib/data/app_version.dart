/// data/app_version.dart — 版本号唯一来源（纯 Dart，全平台含鸿蒙可用）。
///
/// 与 pubspec.yaml 的 `version:` 保持同步，由 `test/app_version_test.dart`
/// 强制校验（漂移即测试失败）。设置页展示这里的完整版本号。
/// 发版流程：改 pubspec.yaml → 同步改这里 → 跑测试。
///
/// 1.0 起采用「构建号进包、阶段标识进显示」双轨：
///  * pubspec 写纯数字版本（1.0.0+26）——保证 Android versionCode 单调递增
///    （旧安装包可覆盖升级）、iOS CFBundleShortVersionString 与 Windows 文件
///    版本号字段保持合法格式；
///  * 本文件的 kAppVersion 是**对外显示串**（1.0.0_beta1），阶段后缀只影响
///    用户看到的文字，不参与任何构建号与升级判定。
library;

/// 对外显示的完整版本号（含阶段标识），如 "1.0.0_beta1"。
/// 数字基段必须与 pubspec.yaml 的 version 基段一致（由测试强制）。
const String kAppVersion = '1.0.0_beta1';

/// 展示用短版本（形如 "1.0.0_beta1"；若显示串带构建号则截断之）。
String get kAppVersionShort => kAppVersion.split('+').first;
