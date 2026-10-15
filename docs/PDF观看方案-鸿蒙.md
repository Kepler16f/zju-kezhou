# 应用内看方案 PDF：鸿蒙（HarmonyOS NEXT）方案对比

> 背景：培养方案的官方 PDF 端点已打通（`GET /jwglxt/pyfagl/pyfayl_cxPyfaylPdf.html?id=<jxjhh>`），
> 桌面端能下载后用系统阅读器打开；**移动端（含鸿蒙）目前只落盘，不能应用内直接看**。
> 本文给"鸿蒙上怎么在应用内看"的可选方案，含**已实测存在**的包与版本约束。

## 0. 现状与缺口

| 端 | 现状 |
|---|---|
| Windows/macOS/Linux | 下载到沙箱 → `explorer`/`open`/`xdg-open` 唤起系统阅读器（`_canOpenExternal`） |
| Android/iOS/鸿蒙 | 只保存文件 + 提示"请用系统文件管理器打开"（**缺口**） |
| 全平台 | 「方案」页的结构化视图（概览/学分/核心课/chips 高亮/课程表/辅修/二三四课堂）**已经是应用内观看**，不依赖 PDF |

也就是说：**"应用内观看培养方案"这个需求已经由结构化视图满足**；下面讨论的是"把 PDF 原文也搬进 App 内"。

## 1. 已核实的鸿蒙可选项（2026-10 于 pub.dev 实测）

| 包 | 最新版 | SDK 约束 | 与 flutter-ohos 3.27.5（Dart 3.6） | 用途 |
|---|---|---|---|---|
| `pdf_render_ohos` | 1.0.0 | `>=2.17.0 <4.0.0`，flutter `>=1.20.0` | ✅ 兼容 | 把 PDF 渲染成图片（自己写翻页 UI，最可控） |
| `flutter_pdfview_ohos` | 1.0.0 | `>=2.19.6 <4.0.0`，flutter `>=2.5.0` | ✅ 兼容 | 现成 PDFView 控件（最省事） |
| `printing_ohos` | 1.0.1 | `>=3.3.0 <4.0.0`，flutter `>=3.22.0` | ✅ 兼容 | 预览/打印/分享 PDF |
| `webview_flutter_ohos` | 3.15.0 | `>=2.19.0 <4.0.0`，flutter `>=3.7.0` | ✅ 兼容 | 用 WebView 内嵌预览（含在线 PDF.js 方案） |
| `pdfrx` | 2.6.5 | **`^3.13.0`，flutter `>=3.47.0`** | ❌ **不可用** | 最强的跨平台 PDF 渲染；需锁旧版（1.0.x 线）才能在 3.27 用 |

> 结论：**鸿蒙有替代品（"有的"），而且不只一个**。首选 `flutter_pdfview_ohos`（渲染控件）或
> `pdf_render_ohos`（自绘 UI）；`pdfrx` 这条最常见的路线在 flutter-ohos 3.27.5 上反而走不通。
> 这些都是 ohos-only 包，源码归属一般在 openharmony-sig / openharmony-tpc 组织下，
> 可通过 pub.dev 页面核对版本与维护状态。

## 2. 推荐落地方式（按风险从低到高）

### 方案 A（推荐，先做）：结构化为主，PDF 做"能看就看"

保持现状 + 一处小改：移动端把"系统文件管理器打开"改为**系统级分享/打开意图**
（零新依赖；鸿蒙/Android 上系统阅读器普遍能开 PDF）。
优点：不引入任何 ohos-only 依赖，各平台 workflow（build-*.yml）零风险；
缺点：仍是跳出应用。

### 方案 B（要做"真·应用内"）：按平台条件接插件

注意 pubspec **没有** 平台条件依赖，所以：

1. 直接加依赖（`flutter pub get` 会在所有平台解析它，但 ohos-only 插件在别的平台只是没有实现，
   编译期不报错，运行期抛 `MissingPluginException`）；
2. **必须在 Dart 侧做平台判断 + try/catch 兜底**，否则桌面/Android 会崩。

```yaml
# pubspec.yaml
dependencies:
  flutter_pdfview_ohos: ^1.0.0      # ohos-only；其他平台运行时不可用
```

```dart
// 观看入口：只有鸿蒙走应用内预览，其余平台维持"下载 + 系统打开"
Future<void> _previewPdf(String path) async {
  if (!Platform.isOhos) {          // flutter-ohos 提供的 Platform.isOhos
    return _openExternal(path);     // 桌面/移动端原有路径
  }
  try {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PDFView(filePath: path),   // flutter_pdfview_ohos 的控件
    ));
  } catch (e) {                     // 插件缺失/版式不支持 → 回落到系统打开
    _snack('应用内预览不可用，已保存到 $path');
  }
}
```

> `Platform.isOhos` 是 flutter-ohos 分支提供的；用官方 stable 编译时该 getter 不存在，
> 所以这段代码要么只在 ohos 构建时启用，要么用 `defaultTargetPlatform` + 字符串判断，
> 或对 ohos 相关 API 加 `// ignore` 与条件导入。

3. **只改 `build-hap.yml`** 里的依赖注入块，别动其他平台的 workflow；
4. 建议加一条 CI：`flutter build hap` 成功即可（无需真机），运行时行为靠真机目测。

### 方案 C：WebView 内嵌

`webview_flutter_ohos` + 本地 HTML 包一层 PDF.js（或直接指向一个 file:// 的 PDF）。
适合"顺带还要展示方案网页版"的场景；多一层 JS 依赖，但避开了原生渲染插件。

## 3. 结论与建议

1. **"应用内观看培养方案"已经实现**（结构化视图，全平台一致，零新依赖，且不依赖 910 端点是否可用）；
2. 想把 **PDF 原文**也内嵌：鸿蒙走 `flutter_pdfview_ohos`（首选）或 `pdf_render_ohos`，
   用**平台条件 + try/catch** 兜底，改动面限于 pubspec + 方案页 + `build-hap.yml`；
3. 不要用 `pdfrx` 最新版（要 Flutter ≥3.47 / Dart 3.13，与 flutter-ohos 3.27.5 不兼容）；
   若确实想用，锁 1.0.x 并在两个 SDK 上各跑一次 `flutter build`；
4. 无论选哪种，**PDF 都只是加分项**：明细端点对学生账号返回 910 是常态，
   PDF 也可能没上传，所以结构化视图必须始终是可用的主路径（当前实现即如此）。