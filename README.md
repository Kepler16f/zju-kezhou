# 课舟 ClassArk · 本科培养方案结构化与选课风险审计（全平台 App）

> **课舟**（中文名）= 课 + 舟，学海行舟；**ClassArk**（英文名，class 课堂 + ark 方舟）为 iOS 安装包显示名。
> 仓库、安装包与产物名沿用 `kezhou`（Android / Windows / 鸿蒙 / CI）。

把几十页 PDF 培养方案变成一张能问、能算的表：算出你还差几学分、哪些课顺序排错、下学期怎么选课。
一套 Flutter 代码出**全平台安装包**，内置浙江大学真实教务**只读**接口（ZJUAM 统一登录 → 正方成绩/课表/培养方案/选课查询/课堂分）。

## 一屏看懂

- **全平台成品**：Android(arm64/armv7/x86_64)、iOS(ipa)、鸿蒙 NEXT HAP、Windows(arm64/x64)、Linux(arm64/x64)、macOS(arm64/x64)。
- **真实数据、只读通道**：登录自己账号，成绩/课表/培养方案实时拉取；不提交选课、不改任何教务数据，`eval/check_readonly.py` 在 CI 机械拦截写接口。
- **四个页签**：学业 / 方案 / 选课 / 设置 + 全局 AI 悬浮助手。
- **导师模式**：学生自愿导出脱敏「学业档案分享包」发给导师，导师端纯审阅、不登录教务（见 `docs/教师模式合规说明.md`）。
- **双轨交付**（`docs/开发方案.md` v2 附录）：Flutter 全平台轨（真实成品）+ Dify/aihub 比赛申报轨（低代码智能体 + Python 规则引擎，本仓库 `engine/ dify/ prompts/ eval/`）。
- **分工原则：LLM 负责"读和说"，代码负责"对不对"**。学分/先修/冲突一律由确定性规则引擎计算（Python 与 Dart 双实现、金标对照逐字段一致），每条结论可溯源到方案页码。

## App 功能

### 页签一「学业」—— 学业看板
4.3 制/五分制 GPA、加权百分制、已获学分、按课程性质的学分看板、第二/三/四课堂分（素拓）；学期走势折线图（学期+累计双线，CustomPainter 零依赖）；GPA 模拟器（what-if 加课预测 + 目标反推"剩余学分需达到的平均绩点"）；成绩明细按学期分组。无数据不显示假 0。

### 页签二「方案」—— 培养方案 + 学业审计（已合并）
登录后自动「专业名 + 年级」匹配教务培养方案并爬取接口，应用内结构化观看（概览/学分学制/培养目标与要求/核心课 chips 已修高亮/课程表/辅修/第二三四课堂/官方 PDF）；**匹配有歧义时不替用户猜**，列出候选点选。三色达成度审计报告（实时方案优先、内置样例兜底），先修缺口/同学期排错/时间冲突/停开风险逐条溯源。微辅修按目标专业独立查询（不与主修方案混排）；我的课表周视图。详见 `docs/培养方案接入说明.md`。

### 页签三「选课」—— 只读选课查询
教务网登录后按需读取选课入口（类别×轮次内嵌页面）→ 单轮列表 / 跨轮汇总（同一教学班按「课程+教学班」身份跨轮对齐，容量/已选快照对比）/ 与培养方案和当前课表匹配的建议卡；**绝不提交选课/退课**；含离线演示数据入口。命中反爬软封禁时冷却退避、停止逐入口轰炸。详见 `docs/选课模块接入说明.md`。

### 页签四「设置」—— 登录与一切开关
ZJUAM 登录（凭证仅存本机沙箱、可一键清除；Cookie 仅驻内存）；记住登录、重启自动恢复会话；数据源切换（真实/粘贴/导出 CSV/样例）；AI 配置；「分享给导师」导出与「导师审阅模式」入口；关闭收起到托盘（Windows）；关于页含完整版本号与**登录诊断日志**（逐步记录卡点、不含敏感值）。原「登录页」已并入本页。

### AI 助手（悬浮入口，全局）
开箱即用：出厂默认免费公益端点（Pollinations，无需 API Key），也可在设置里换 OpenAI 兼容 / Anthropic / Dify。只把本机已算好的数字与清单**翻译成文字**，不计算、不排序、不推荐课表。发送范围经首次确认，且不含学号、姓名、教务凭证与 Cookie：
- 学业/审计解读：已修课程名/学分/成绩/学期、方案模块与课程要求、选课候选与课表、审计缺口数字、你的问题（常量与 `prompts/m5_select.md` 同口径，代码见 `lib/data/ai_prompts.dart`）；
- 选课一次性解读白名单更窄：课程名/学分/性质/缺口数字/候选教学班（见 `lib/data/ai_prompts.dart` 的 `kAiSendNotice`）；
- 屏幕识别（仅 Windows）：系统内置 WinRT OCR **本地**识别屏幕文字用于"回答屏幕上的问题"，不存在云端 OCR 外泄面；结果默认只填输入框，随问题发送需首次明确同意且不写入历史。
- 内置知识库仅预留接口（`lib/data/ai_knowledge.dart`），检索不接触个人信息。
- 一键清除会连带删除 AI 配置与密钥（合规承诺写进 `deleteAiConfig` 路径）。

### 稳定性与桌面细节
- **崩溃自动恢复**：Windows `RegisterApplicationRestart` 崩溃后自动带 `--crashed` 拉起，应用内提示可一键导出诊断日志；
- **窗口 resize 崩溃根因已定位并修复**（引擎 Impeller 在 ARM64 的问题，对齐 PiliPlus 禁用方案）：见 `docs/已知问题-Windows窗口resize崩溃.md`；
- **单实例**：重复启动聚焦已有窗口，不再无限开窗（见 `docs/桌面端-单实例与托盘.md`）；
- **内置字体**：`assets/fonts/NotoSansSC-{Regular,Bold}.ttf`（OFL-1.1，按 GB2312+应用文案裁剪，共约 4.5MB），干净 Linux/精简 Windows/无中文环境一致渲染中文。

## 快速开始

```bash
# ── 轨道一：Flutter App（成品） ──
cd compass_app
dart test test/                                   # 引擎与合规单测（纯 Dart VM；
#   本机若为定制 Flutter 分支 flutter test 会因 SDK hash 挂起，构建加 --no-tree-shake-icons）
flutter run                                       # 真机/模拟器运行
bash ../packaging/build_windows_installer.sh arm64   # Windows Setup.exe（含 VC 运行库，arm64 构建后自动装机）
flutter build apk --release --split-per-abi --no-tree-shake-icons

# ── 轨道二：Python 引擎（Dify Code 节点源，CI 金标门） ──
python data/check_golden.py                                # golden 一致性
python -m unittest discover -s engine/tests                # 引擎单测
python engine/run_audit.py                                 # 本地全链路演示
python engine/build_embed.py                               # 生成 dify/audit_code_node.py

# ── 双引擎金标对照 + 只读红线（CI 必跑） ──
cd .. && python eval/cross_engine_parity.py                # Python↔Dart 逐字段一致
python eval/check_readonly.py                              # 只读红线：无教务写接口引用
```

**CI**：GitHub Actions 按平台拆分（`.github/workflows/build-{android,windows,macos,ios,linux,hap}.yml`，由 `buildAll.yml` 分发器调用；push 到 main 只跑金标门，push `v*` tag 全平台出包）。手动构建：Actions → **Build all platforms** → Run workflow → 勾选需要的平台；产物为未压缩单文件（upload-artifact v7，`archive: false`）。iOS 未签名 ipa 由 `build-ios.yml` 从 xcarchive 组装（真机安装需自签/侧载工具）。

**交付形态约定**：只交安装包，不交 zip/裸目录——Windows `KeZhouSetup-<版本>-win-<arch>.exe`（用户级安装、免管理员、带卸载项）；Android APK、iOS IPA（显示名 **ClassArk**）、鸿蒙 HAP 本身即安装包；产物统一落 `dist/`。

## 目录

| 路径 | 内容 |
|---|---|
| `compass_app/` | Flutter 全平台 App（本文档主体） |
| `docs/开发方案.md` | 工程版实施方案（架构/数据模型/排期，v2 附录含双轨与构建矩阵） |
| `docs/运行与构建指南.md` | 怎么跑：桌面/真机/各平台打包（含鸿蒙 HAP）、单测、常见问题 |
| `docs/实测登录指南.md` | 登录/取数卡点排查（配合应用内诊断日志） |
| `docs/培养方案接入说明.md` | 培养方案取数与匹配：接口清单、匹配算法、字段、已知限制、回归护栏 |
| `docs/选课模块接入说明.md` | 选课取数与跨轮匹配：端点与置信度、三态语义、身份三档、写接口红线 |
| `docs/教师模式合规说明.md` | 导师审阅：数据主权在学生、分享包格式与脱敏、被否决路径 |
| `docs/桌面端-单实例与托盘.md` | Windows 单实例/托盘/关窗行为 |
| `docs/已知问题-Windows窗口resize崩溃.md` | 改窗口大小闪退的根因（引擎 Impeller/无障碍桥）与修复 |
| `docs/PDF观看方案-鸿蒙.md` | 应用内看方案 PDF 的鸿蒙可选包与落地方式 |
| `schema/` | plan / record / report 三数据契约 |
| `data/golden/` | 两专业培养方案结构化终稿（进 git，演示用合成数据） |
| `data/samples/` | 演示记录：粘贴文本、教务导出 CSV、含计划选课的全量 JSON |
| `engine/` | Python 规则引擎（= Dify Code 节点源）：audit / adapters / timecheck / common / build_embed / run_audit |
| `dify/` | 搭建指南 + 可直接粘贴的代码节点源（audit_code_node / m1_validate_code / policy_gate_code） |
| `prompts/` | m1_extract（抽取）/ m2_narrate（叙事）/ m4_answer（政策问答）/ m5_select（选课解读边界） |
| `eval/` | `cross_engine_parity` 双引擎对照、`check_readonly` 只读红线、`extract_accuracy` 抽取准确率评测 |
| `packaging/` | Windows 安装包脚本、workflow YAML 校验、发布前扫描 |
| `video/` | 演示固化输入与拍摄清单 |

## 数据流（答辩架构图）

```
培养方案PDF ──[Workflow M1: 抽取+校验+人工订正]──> data/golden/*.json（冻结，溯源含页码）
粘贴/导出CSV/zdbk接口 ──[adapters 三源适配器]──> Record Schema ──┐
golden（build_embed 注入为常量）────────────────────────────────┴─> [Code: audit 规则引擎]
                                                                       │ Report Schema JSON
                                               [LLM 叙事包装]──> 三色达成度报告 Markdown
政策文件×3 ──[知识库检索]──[Code 拒答门]──[LLM 带出处回答 / 固定拒答文案]
```

App 内真实链路：ZJUAM CAS 登录（RSA 加密提交，iPlanetDirectoryPro）→ 教务网双跳 service ticket（JSESSIONID+route）→ 成绩单 / 学籍(专业四级来源) / 培养方案(多级查询+评分匹配) / 课堂分 / 选课查询；HTTP 全部 `Isolate.run` 隔离、单飞 + 失败退避。

## 合规红线（写进申报书的工程落点）

- 演示数据全部合成：无真实姓名/学号（`student.alias` 为虚拟标识），见 `video/演示固化与自检.md` 检查项；
- 教务凭证仅存本机沙箱（混淆落盘、一键清除、不上传不落库），会话 Cookie 仅驻内存；真实数据接入仅处理用户本人账号；
- 输出固定声明：*本报告仅供与导师沟通参考，正式认定以教务系统为准*（引擎硬编码，LLM 无权删改）；
- AI 发送范围经首次确认、按最小白名单（见上"AI 助手"），一键清除连带删除 AI 配置与密钥；
- 导师模式不做教师端直连：数据主权在学生，教师态零登录、零网络请求，仅解析学生自愿导出的分享包（`docs/教师模式合规说明.md`）；
- 选课模块只读红线由 `eval/check_readonly.py` 在 CI 机械拦截（写接口路径零出现）；
- 无原始数据库导出，不绕过反爬高频轰炸（软封禁即冷却退避）。

## 贡献者

| [![Kepler16f](https://avatars.githubusercontent.com/Kepler16f?s=64)](https://github.com/Kepler16f) | [![shiroiyoru142857](https://avatars.githubusercontent.com/shiroiyoru142857?s=64)](https://github.com/shiroiyoru142857) |
|:---:|:---:|
| **Kepler16f** | **shiroiyoru142857** |
