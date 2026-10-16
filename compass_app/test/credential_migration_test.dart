// test/credential_migration_test.dart — 凭证目录漂移修复回归（纯 Dart，注入临时目录）。
// 场景：0.10.x 数据在 <APPDATA>\edu.zju.compass\compass_app\compass，
// 改名「课舟」后新目录为空 → 升级即掉登录。migrateLegacyDirs 应自动搬回。
import 'dart:io';

import 'package:test/test.dart';

import 'package:compass_app/data/credential_store.dart';

Directory _legacyRoot(String tmp) =>
    Directory('${tmp}${Platform.pathSeparator}edu.zju.compass');

Directory _legacyCompass(String tmp, String product) =>
    Directory('${_legacyRoot(tmp).path}${Platform.pathSeparator}$product'
        '${Platform.pathSeparator}compass');

void main() {
  late Directory tmp;
  late Directory target;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('compass_mig_');
    target = Directory('${tmp.path}${Platform.pathSeparator}newroot'
        '${Platform.pathSeparator}compass');
    await target.create(recursive: true);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('旧目录有凭证 → 整目录搬入（含 ai.cfg / cache_*，跳过 diag.log）', () async {
    final old = _legacyCompass(tmp.path, 'compass_app');
    await old.create(recursive: true);
    await File('${old.path}${Platform.pathSeparator}cred.dat').writeAsString('CRED');
    await File('${old.path}${Platform.pathSeparator}ai.cfg').writeAsString('AI');
    await File('${old.path}${Platform.pathSeparator}cache_x.json').writeAsString('{}');
    await File('${old.path}${Platform.pathSeparator}diag.log').writeAsString('LOG');

    await CredentialStore.migrateLegacyDirs(
        target: target, appDataRoot: tmp); // 函数内部自拼 edu.zju.compass

    expect(await File('${target.path}${Platform.pathSeparator}cred.dat').readAsString(),
        'CRED');
    expect(await File('${target.path}${Platform.pathSeparator}ai.cfg').exists(), isTrue);
    expect(await File('${target.path}${Platform.pathSeparator}cache_x.json').exists(),
        isTrue);
    // 诊断日志不搬（新会话从头记）
    expect(
        await File('${target.path}${Platform.pathSeparator}diag.log').exists(), isFalse);
    // 旧目录保留（可回退）
    expect(await File('${old.path}${Platform.pathSeparator}cred.dat').exists(), isTrue);
  });

  test('多个旧目录并存 → 取 cred.dat 最新的一份', () async {
    final older = _legacyCompass(tmp.path, 'compass_app');
    final newer = _legacyCompass(tmp.path, '课舟');
    await older.create(recursive: true);
    await newer.create(recursive: true);
    await File('${older.path}${Platform.pathSeparator}cred.dat').writeAsString('OLD');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await File('${newer.path}${Platform.pathSeparator}cred.dat').writeAsString('NEW');

    await CredentialStore.migrateLegacyDirs(
        target: target, appDataRoot: tmp);

    expect(await File('${target.path}${Platform.pathSeparator}cred.dat').readAsString(),
        'NEW');
  });

  test('目标已有凭证 → 不动（绝不覆盖现登录）', () async {
    await File('${target.path}${Platform.pathSeparator}cred.dat').writeAsString('KEEP');
    final old = _legacyCompass(tmp.path, 'compass_app');
    await old.create(recursive: true);
    await File('${old.path}${Platform.pathSeparator}cred.dat').writeAsString('OLD');

    await CredentialStore.migrateLegacyDirs(
        target: target, appDataRoot: tmp);

    expect(await File('${target.path}${Platform.pathSeparator}cred.dat').readAsString(),
        'KEEP');
  });

  test('无旧目录 → 什么都不做', () async {
    await CredentialStore.migrateLegacyDirs(
        target: target, appDataRoot: tmp);
    expect(await target.list().isEmpty, isTrue);
  });

  test('同名文件已存在（非凭证）→ 不覆盖', () async {
    final old = _legacyCompass(tmp.path, 'compass_app');
    await old.create(recursive: true);
    await File('${old.path}${Platform.pathSeparator}cred.dat').writeAsString('OLD');
    await File('${target.path}${Platform.pathSeparator}cache_x.json')
        .writeAsString('MINE');
    await File('${old.path}${Platform.pathSeparator}cache_x.json')
        .writeAsString('THEIRS');

    await CredentialStore.migrateLegacyDirs(
        target: target, appDataRoot: tmp);

    expect(await File('${target.path}${Platform.pathSeparator}cache_x.json')
        .readAsString(), 'MINE');
  });
}
