# 课舟 ClassArk v0.12.1

面向浙大学子的学业规划助手：只读对接教务系统，实时拉取成绩/课表/培养方案/选课，结构化审计学分缺口与先修冲突，结论可溯源；AI 只做「读和说」，公益端点开箱即用。

## 安装包（全部为原生安装包，非压缩包套壳）

| 平台 | 文件 |
|---|---|
| Windows arm64 | KeZhouSetup-0.12.1-win-arm64.exe |
| Windows x64 | KeZhouSetup-0.12.1-win-x64.exe |
| Android arm64 | app-arm64-v8a-release.apk |
| Android armv7 | app-armeabi-v7a-release.apk |
| Android x64 | app-x86_64-release.apk |
| iOS (未签名 ipa，显示名 ClassArk) | kezhou-unsigned.ipa |
| macOS arm64 | KeZhou-macos-arm64.zip |
| macOS x64 | KeZhou-macos-x64.zip |
| Linux arm64 | KeZhou-linux-arm64.tar.gz |
| Linux x64 | KeZhou-linux-x64.tar.gz |
| 鸿蒙 NEXT (未签名 HAP) | compass_unsigned.hap |

说明：iOS/鸿蒙产物未签名（需自签或调试挂载）；macOS/Linux 因 .app 是目录只能以压缩包交付，Windows/APK/IPA/HAP 均为单文件安装包。

## 校验方式

CI 金标门（Python↔Dart 双引擎逐字段一致 + 只读红线扫描）与单测全绿后由 tag v0.12.1 自动出包，见 Actions 构建记录。
