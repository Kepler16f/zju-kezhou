// test/app_version_test.dart — 版本号唯一来源与 pubspec 同步校验。
import 'dart:io';
import 'package:test/test.dart';
import 'package:compass_app/data/app_version.dart';

void main() {
  test('kAppVersion 与 pubspec.yaml 一致', () {
    final f = File('pubspec.yaml');
    expect(f.existsSync(), isTrue, reason: '需在 compass_app/ 下运行测试');
    final m = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
        .firstMatch(f.readAsStringSync());
    expect(m, isNotNull, reason: 'pubspec 缺 version 行');
    expect(kAppVersion, m!.group(1),
        reason: 'lib/data/app_version.dart 的 kAppVersion 与 pubspec.yaml 漂移了，请同步');
  });

  test('短版本号格式', () {
    expect(kAppVersionShort, matches(RegExp(r'^\d+\.\d+\.\d+$')));
  });
}
