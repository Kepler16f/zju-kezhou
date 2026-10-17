/// data/screen_ocr.dart — 屏幕文字识别（诉求 #4：识别课程标签 / 回答屏幕上的问题）。
///
/// 实现：Windows 系统内置 WinRT OCR（Windows.Media.Ocr）+ System.Drawing 截屏，
/// 经 powershell.exe 子进程调用（本机实测中文识别完美、免费、完全离线，
/// 不经任何云端 OCR——不存在屏幕内容外泄面）。非 Windows 返回"不支持"。
/// 零新依赖、零新增原生插件：App 保持全平台可构建；能力按平台降级。
///
/// 红线：
///  - 脚本正文只用 ASCII（PowerShell 5.1 对无 BOM 非 ASCII 脚本的编码不可靠；
///    输出路径经 -File 参数以 argv 传入，CreateProcess 无损）；
///  - OCR 结果只填进聊天输入框（可编辑可放弃），绝不自动外发——屏幕里可能有
///    密码/个人信息，发送确认权始终在用户手里。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 识别结果：ok=拿到文字；unsupported=平台不支持；failed=执行失败（含超时）。
class ScreenOcrResult {
  final String status; // 'ok' | 'unsupported' | 'failed'
  final String text;
  final String? error;
  const ScreenOcrResult._(this.status, this.text, this.error);
  factory ScreenOcrResult.ok(String text) => ScreenOcrResult._('ok', text, null);
  factory ScreenOcrResult.unsupported() => const ScreenOcrResult._(
      'unsupported', '', '当前平台不支持屏幕识别（需 Windows 内置 OCR）');
  factory ScreenOcrResult.failed(String why) =>
      ScreenOcrResult._('failed', '', why);
  bool get isSuccess => status == 'ok';
}

/// 送进 AI 的最大屏幕文本量：防超长屏内容把请求撑爆（也缩小潜在外泄面）。
const int kMaxOcrText = 4000;

/// 清洗 OCR 文本：去掉除换行/制表外的控制字符、压多余空格、限长（纯函数，可测）。
String sanitizeOcrText(String raw, {int max = kMaxOcrText}) {
  var s = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  // 去控制字符（保留换行）：横向制表符在下一步统一并成空格，这里按空白一并清掉。
  s = s.replaceAll(RegExp('[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F]'), '');
  // 连续空格/制表符并成一个空格（OCR 常把列间距吐成多空格或制表）。
  s = s.replaceAll(RegExp('[ \\t]+'), ' ');
  s = s.trim();
  return s.length <= max ? s : s.substring(0, max);
}

/// 截屏 + WinRT OCR 的 PowerShell 脚本（纯 ASCII；
/// args[0]=PNG 暂存路径，args[1]=识别文本输出路径）。
/// 有意不设 $ErrorActionPreference='Stop'：WinRT 类型投影加载（[Type,...ContentType=
/// WindowsRuntime]）在非 ASCII 控制台/无窗口宿主下会打非终止性警告，Stop 会把
/// 警告升级成终止错误（实测 exit 1）；后续步骤取不到对象时本来就各有兜底。
String buildCaptureScript() => r'''
Add-Type -AssemblyName System.Drawing,System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DpiA {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[DpiA]::SetProcessDPIAware() | Out-Null
$b = [Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
$g = [Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
$bmp.Save($args[0], [Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
$null = [Windows.Media.Ocr.OcrEngine,Windows.Foundation.UniversalApiContract,ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder,Windows.Graphics.Imaging,ContentType=WindowsRuntime]
$null = [Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
$asyncWait = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
function Await($op,$t){ $m=$asyncWait.MakeGenericMethod($t); return $m.Invoke($null,@($op)).Result }
$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if ($null -eq $engine) { Write-Error 'NO_OCR_ENGINE'; exit 2 }
$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($args[0])) ([Windows.Storage.StorageFile])
$stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
$bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
$result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
[System.IO.File]::WriteAllText($args[1], $result.Text, [System.Text.Encoding]::UTF8)
''';

/// 截全屏并识别文字。仅 Windows；后台子进程，12s 超时（含截屏+OCR 冷启动）。
Future<ScreenOcrResult> captureScreenText({
  Duration timeout = const Duration(seconds: 12),
}) async {
  if (!Platform.isWindows) return ScreenOcrResult.unsupported();
  Directory? tmp;
  try {
    tmp = await Directory.systemTemp.createTemp('kezhou_ocr_');
    final png = '${tmp.path}${Platform.pathSeparator}cap.png';
    final out = '${tmp.path}${Platform.pathSeparator}ocr.txt';
    final script = '${tmp.path}${Platform.pathSeparator}cap.ps1';
    await File(script).writeAsString(buildCaptureScript());
    final r = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, png, out],
        stdoutEncoding: latin1,
        stderrEncoding: latin1).timeout(timeout);
    if (r.exitCode != 0) {
      final err = '${r.stderr}';
      if (err.contains('NO_OCR_ENGINE') || err.contains('OcrEngine')) {
        return ScreenOcrResult.failed('系统未安装 OCR 语言包（设置→时间和语言→语言 添加中文后重试）');
      }
      return ScreenOcrResult.failed('屏幕识别失败（exit ${r.exitCode}）');
    }
    final f = File(out);
    if (!await f.exists()) return ScreenOcrResult.failed('屏幕识别无输出');
    final text = sanitizeOcrText(await f.readAsString(encoding: utf8Codec));
    if (text.isEmpty) return ScreenOcrResult.ok(''); // 成功但屏幕没字：如实空
    return ScreenOcrResult.ok(text);
  } on TimeoutException {
    return ScreenOcrResult.failed('屏幕识别超时，请重试');
  } catch (e) {
    return ScreenOcrResult.failed('屏幕识别异常：$e');
  } finally {
    try {
      await tmp?.delete(recursive: true);
    } catch (_) {}
  }
}

/// utf8 解码别名（容忍半截中文：WinRT 输出正常是完整 UTF-8，稳妥起见不抛）。
const utf8Codec = Utf8Codec(allowMalformed: true);
