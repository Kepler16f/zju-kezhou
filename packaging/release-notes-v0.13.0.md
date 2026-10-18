# 课舟 ClassArk v0.13.0

本版为功能批次更新（13 项）+ 比赛轨退役：

## 新能力
- **AI 解读开闸弹窗**：首次安装默认关闭；点击 AI 入口询问是否开启（同意即公益免费模型）；已有配置（含自填 API Key 的自有服务）按配置直开，不再询问
- **选课指导模式**（原导师审阅）：独立开关、进入后可用设置页与 AI 助手
- **AI 选课咨询导出**：一键把问答随脱敏分享包（格式 v2）导出给指导教师，教师端审阅页直接呈现
- **审计引擎 v1.3**：选课组（大学写作四选一、耕读类选一门等）按「至少 N 门」折算，不再重复计算全部可选项；外语类可选 L1(6分)/L2(4.5分)/L3(3分) 封顶（设置页可切换，立即重算）
- **「已选上」vs「已获得学分」**：蓝/绿双色注释 + 报告口径说明
- **素拓看板实接**：对接 sztz.zju.edu.cn 第二/三/四课堂真实积分（getMyInfo 汇总优先，申报记录合计兜底，N108001 遗留兜底，缓存降级）
- **认定型课程修复**：美育类等认定性入口不再整类丢失；一门课的多个类别标签在合并视图并排显示
- **底栏自定义**：页签排序 + 启动默认首页（设置页）
- **成绩明细子标签等宽**（移动端一行多枚、自动换行）

## 质量
- 473 项测试全绿；Python↔Dart 双引擎 parity 逐字段一致；只读红线 CI 拦截
- flutter-ohos 3.27 API 兼容修复（RadioListTile）

## 安装包
| 平台 | 文件 |
|---|---|
| Windows arm64 | KeZhouSetup-0.13.0-win-arm64.exe |
| Windows x64 | KeZhouSetup-0.13.0-win-x64.exe |
| Android arm64 / armv7 / x64 | app-arm64-v8a-release.apk 等 |
| iOS（未签名 ipa，显示名 ClassArk） | kezhou-unsigned.ipa |
| macOS arm64 / x64 | KeZhou-macos-*.zip |
| Linux arm64 / x64 | KeZhou-linux-*.tar.gz |
| 鸿蒙 NEXT（未签名 HAP） | compass_unsigned.hap |

iOS/鸿蒙未签名（需自签或调试挂载）；macOS/Linux 因 .app 为目录以压缩包交付，其余均为单文件安装包。
