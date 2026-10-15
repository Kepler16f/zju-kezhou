# 已知问题：Windows 上调整窗口大小导致进程被强杀（0xc000041d）

> 状态：**已定位根因，应用侧已规避（代价见"取舍"），引擎侧真修待上游/自建引擎。**
> 归档日期：2026-10-14。适用版本：Windows（arm64/x64）全部构建。

## 现象

Windows 桌面版启动后，只要拖动边框改窗口大小（或最大化/还原），进程立刻消失：
无报错弹窗、无 Flutter 红屏、Dart 侧来不及记录任何日志。事件查看器里是成对出现:

```
错误应用程序名称: kezhou.exe
错误模块名称:   flutter_windows.dll
异常代码:       0xc000041d      （伴随一次 0xc0000005）
错误偏移量:     000000000003e4e8
```

`0xc000041d` = `STATUS_FATAL_USER_CALLBACK_EXCEPTION`，含义是**异常从系统回调
（窗口过程）里逃逸**，被内核直接强杀，应用层 try/catch 或 Dart 侧
`ErrorWidget.builder` 都无法拦截。

## 根因（引擎缺陷，非本应用业务代码）

引擎源码 `shell/platform/common/accessibility_bridge.cc`：

```cpp
      // Flutter's root node should never be reparented.
      assert(child->parent());                                   // 第 226 行

      // Skip nodes whose parents are unchanged.
      if (child->parent()->id() == node_update.second.id) {      // 第 229 行 ← 崩在这里
```

release 构建启用 `NDEBUG`，第 226 行的断言被编译掉；当 AXTree 中出现**没有父节点的
节点**（引擎自己的"移除重新挂载节点"更新会留下这种孤儿节点），第 229 行
`child->parent()->id()` 就是一次空指针解引用 → AV → 从窗口过程逃逸 → 0xc000041d。

触发需要两个条件同时成立：

1. **语义树（无障碍）被启用**。Windows 引擎唯一的启用入口是窗口收到
   `WM_GETOBJECT`（引擎 `flutter_window.cc:792 → OnUpdateSemanticsEnabled(true)`），
   也就是**读屏器 / UI 自动化工具查询窗口**时才会打开。本机有常驻 UIA 客户端，
   新窗口一出现就会被查询，因此本机必现。
2. **出现 reparent（节点重新挂载）型语义更新**。本应用窗口 resize 必然产生；
   引擎会为它调用 `CreateRemoveReparentedNodesUpdate()`。

对照实验：同机同架构的 PiliPlus（Flutter ARM64，同样用 window_manager）连续 resize
不崩——说明不是"这台机器上的 Flutter 都坏"，而是本应用的语义树在 resize 时会产生
重新挂载，恰好踩中该引擎缺陷。

### 已排除的怀疑方向（都验过，别再试）

| 怀疑 | 结论 |
|---|---|
| Impeller 渲染器 ARM64 resize bug | **无关。** `set_impeller_switch(Disabled)` 构建实测仍崩在同一指令；曾引用的 issue #188635/#191050/#191069 讲的分别是 Rust→Dart FFI 堆损坏、resize 内存占用高，都不是本崩溃 |
| window_manager / 窗口显示路径 | **无关。** 加 window_manager 前后（21:53 前后两个构建）均崩 |
| 应用业务代码（登录/网络/图表） | **无关。** 崩溃点在被强杀前的引擎代码里，Dart 侧无任何异常记录 |
| 换引擎版本 | **无效。** 四个引擎版本（C:\flutter 3.47.2、D:\flutter-3477 3.48.0-0.2.pre 等）都在同一段代码崩；上游 master 至今仍**没有**这处空指针检查 |
| 在 runner 里拦掉 `WM_GETOBJECT` | **无效。** 引擎的视图是独立窗口（类名 `FLUTTERVIEW`），UIA 查询在窗口创建瞬间就到达，早于任何挂钩时机 |

## 应用侧规避（已落地）

`lib/main.dart`：

```dart
builder: (context, child) => ExcludeSemantics(child: child!),
```

应用不再产出语义树 → 不会出现 reparent 型语义更新 → 崩溃路径不可达。
实测：启动后连续 25 次任意尺寸 resize + 3 轮最大化/还原，进程全程存活。

**取舍**：读屏器（Narrator 等）读不到本应用内容。对本项目而言，
"读屏不可用" 远好于 "一改窗口大小就闪退"。引擎修好后应移除这一行。

## 引擎侧真修（推荐，需自建引擎）

```cpp
      // Skip nodes that don't exist or have a parent in the current tree.
      ui::AXNode* child = tree_->GetFromId(child_id);
      if (!child) {
        continue;
      }
+     // 根节点与被 `Unserialize` 摘下的孤儿节点没有父节点，release 下这里的
+     // assert 已被编译掉，必须显式判空，否则下面的 child->parent()->id() 空指针崩溃。
+     if (!child->parent()) {
+       continue;
+     }
      assert(child->parent());
```

落地方式（本机当前**不具备**条件）：需要 depot_tools + `gclient sync` 引擎依赖，
再 `flutter build windows --release --local-engine=windows-arm64 --local-engine-src-path=<引擎源码>`
（`C:\flutter\engine\src` 已具备引擎源码，但无 `out/` 构建目录与 depot_tools，
首次同步+全量编译代价很大）。更现实的路径是给上游报 issue 等修复合入。

## 复现与回归验证

```bash
# 1) 启动后自动 resize 压测（存活 = 通过）
powershell -NoProfile -ExecutionPolicy Bypass -File packaging/verify_resize_no_crash.ps1 `
  -ExePath "D:\compass\compass_app\build\windows\arm64\runner\Release\kezhou.exe" -Tag check

# 2) 看历史崩溃记录（事件查看器 Application 日志，ID 1000）
powershell -NoProfile -Command "Get-WinEvent -FilterHashtable @{LogName='Application';ProviderName='Application Error'} -MaxEvents 200 | Where-Object { \$_.Properties[0].Value -eq 'kezhou.exe' } | Select-Object TimeCreated, @{n='code';e={\$_.Properties[6].Value}}, @{n='offset';e={\$_.Properties[7].Value}}"
```

> 排查提示：WER 事件里的 `应用程序时间戳`（PE 链接时间戳）= 每次构建的唯一标识，
> 可用它把崩溃记录对应回具体构建产物；`flutter_windows.dll` 的故障偏移则可用
> 引擎自带的 `*.pdb` 反查到函数名与源码行。

## 附：本次排查顺带发现的问题

- **版本号没有随安装包递增**：`pubspec.yaml` 一直是 `0.10.1+2`，导致所有
  `kezhou.exe` 的版本资源都是 `0.10.1.2`，WER 报告无法区分是哪次构建（本次只能靠
  PE 时间戳辨认）。建议每次出安装包时同步 bump `pubspec.yaml` 版本。
- **本机残留 6 个 0 线程的 `kezhou.exe` 僵尸进程对象**（10-13 崩溃循环留下的），
  占着进程表和 WER 队列，可用任务管理器清掉。
- 诊断日志里有既有告警（与本崩溃无关）：
  `考试安排: Illegal argument(s): Illegal argument in isolate message: object is unsendable`
  —— `zju_client.dart` 把 `ZjuClient`（含 `Future`）发给了 isolate，导致"考试安排"
  降级为空。属于待修的业务缺陷。
