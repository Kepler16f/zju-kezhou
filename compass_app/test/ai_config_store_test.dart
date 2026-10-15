// test/ai_config_store_test.dart — AI 配置持久化回归（纯 Dart，注入临时沙箱目录）。
// 护栏：ai.cfg 不被 clearCache 误删；坏文件回落未配置；deleteAiConfig 干净删除。
import 'dart:io';

import 'package:test/test.dart';

import 'package:compass_app/data/ai_config.dart';
import 'package:compass_app/data/credential_store.dart';

void main() {
  test('ai.cfg 存取往返 / clearCache 不删 / deleteAiConfig 删 / 坏文件容错', () async {
    final dir = await Directory.systemTemp.createTemp('compass_ai_store_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final store = CredentialStore(dir);

    expect((await store.loadAiConfig()).provider, AiProvider.none);

    const cfg = AiConfig(
      provider: AiProvider.anthropic,
      baseUrl: 'https://api.anthropic.com',
      apiKey: 'sk-test-123',
      model: 'claude-opus-5-5',
    );
    await store.saveAiConfig(cfg);
    final back = await store.loadAiConfig();
    expect(back.provider, AiProvider.anthropic);
    expect(back.apiKey, 'sk-test-123');
    expect(back.model, 'claude-opus-5-5');
    expect(back.enabled, isTrue);

    // clearCache 只删 cache_ 前缀：ai.cfg 必须幸存（密钥被"清缓存"顺手删=事故）
    await store.saveCache('some_cache', 'x');
    await store.clearCache();
    expect((await store.loadAiConfig()).apiKey, 'sk-test-123');

    await store.deleteAiConfig();
    expect((await store.loadAiConfig()).provider, AiProvider.none);

    // 损坏文件 → 回落未配置，不抛异常（启动早期读配置抛错会拖崩 App）
    await File('${dir.path}${Platform.pathSeparator}ai.cfg')
        .writeAsString('!!!not-base64!!!');
    expect((await store.loadAiConfig()).provider, AiProvider.none);
  });
}
