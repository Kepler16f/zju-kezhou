// test/app_version_test.dart — 版本号唯一来源与 pubspec 同步校验。
//
// 1.0 起的口径：pubspec 走纯数字版本（构建号单调递增），显示串在
// lib/data/app_version.dart（可带 _betaN 阶段标识）。两条必须同源：
// 显示串的数字基段 == pubspec 的基段，否则视为漂移。
import 'dart:io';
import 'package:test/test.dart';
import 'package:compass_app/data/app_version.dart';

void main() {
  test('kAppVersion 的数字基段与 pubspec.yaml 一致', () {
    final f = File('pubspec.yaml');
    expect(f.existsSync(), isTrue, reason: '需在 compass_app/ 下运行测试');
    final m = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
        .firstMatch(f.readAsStringSync());
    expect(m, isNotNull, reason: 'pubspec 缺 version 行');

    final pubspec = m!.group(1)!;
    final pubBase = pubspec.split('+').first;
    final dispBase = kAppVersion.split('+').first.split('_').first;
    expect(dispBase, pubBase,
        reason: 'lib/data/app_version.dart 的显示版本 $kAppVersion 与 '
            'pubspec.yaml 的 version: $pubspec 基段不一致，请同步');
  });

  test('pubspec 构建号为正整数（保证 Android versionCode 递增）', () {
    final f = File('pubspec.yaml');
    final m = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
        .firstMatch(f.readAsStringSync());
    final parts = m!.group(1)!.split('+');
    expect(parts.length, 2, reason: 'pubspec version 需带构建号（x.y.z+build）');
    expect(int.parse(parts[1]), greaterThan(0),
        reason: '构建号必须为正整数');
  });

  test('显示版本号格式', () {
    expect(kAppVersion,
        matches(RegExp(r'^\d+\.\d+\.\d+(_[A-Za-z0-9.]+)?(\+\d+)?$')),
        reason: '显示版本应为 x.y.z、可选 _阶段标识、可选 +构建号');
    expect(kAppVersionShort, matches(RegExp(r'^\d+\.\d+\.\d+')));
  });
}
