// test/screen_ocr_test.dart — 屏幕识别纯函数回归（纯 Dart，CI 白名单可跑）。
// 真机截屏链路（captureScreenText）不在此覆盖：它依赖交互式会话 + 屏幕内容，
// 已用临时 e2e 在本机验证（status=ok，WinRT 引擎中英文均可识别）。
import 'package:test/test.dart';

import 'package:compass_app/data/screen_ocr.dart';

void main() {
  group('sanitizeOcrText', () {
    test('压空格/去控制字符/保留换行', () {
      expect(sanitizeOcrText('  a   b\tc'), 'a b c');
      expect(sanitizeOcrText('x\x07y'), 'xy');
      expect(sanitizeOcrText('\r\na\rb'), 'a\nb');
    });
    test('限长（防超长屏内容撑爆请求）', () {
      expect(sanitizeOcrText('x' * 5000).length, kMaxOcrText);
      expect(sanitizeOcrText('short'), 'short');
    });
  });

  group('协议约定', () {
    test('脚本纯 ASCII（PowerShell 5.1 非 ASCII 无 BOM 编码不可靠）', () {
      expect(buildCaptureScript().runes.every((r) => r < 128), isTrue);
    });
    test('ScreenOcrResult 状态机', () {
      expect(ScreenOcrResult.ok('t').isSuccess, isTrue);
      expect(ScreenOcrResult.unsupported().isSuccess, isFalse);
      expect(ScreenOcrResult.failed('x').status, 'failed');
    });
  });
}
