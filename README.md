# 学业罗盘 · 本科培养方案结构化与选课风险审计智能体

把几十页 PDF 培养方案变成一张能问、能算的表：算出你还差几学分、哪些课顺序排错、下学期怎么选课。

**双轨交付**（详见 `docs/开发方案.md` v2 附录）：
- **Dify/aihub 轨**（比赛申报）：低代码智能体 + Python 规则引擎，本仓库 `engine/ dify/ prompts/ eval/`；
- **Flutter 全平台轨**（真实成品）：`compass_app/`，一套 Dart 代码出 Android(arm64/armv7/x86_64)、iOS、鸿蒙 NEXT HAP、Windows(arm64/x64)、Linux(arm64/x64)、macOS(arm64/x64) 安装包，内置真实教务只读接口（ZJUAM 登录→正方成绩），凭证/数据不出设备。

**分工原则：LLM 负责"读和说"，代码负责"对不对"。** 学分/先修/冲突一律由确定性规则引擎计算（Python 与 Dart 双实现、金标对照测试逐字段一致），每条结论可溯源到方案页码。

## 快速开始

```bash
# ── 轨道一：Python 引擎（Dify Code 节点源） ──
python data/check_golden.py                                # golden 一致性
python -m unittest discover -s engine/tests               # 24 项单测
python engine/run_audit.py                                 # 本地全链路演示
python engine/build_embed.py                               # 生成 dify/audit_code_node.py

# ── 轨道二：Flutter App ──
cd compass_app
dart test test/engine_test.dart                           # 24 项引擎单测（纯 Dart VM）
flutter run                                               # 真机/模拟器运行
bash ../packaging/build_windows_installer.sh arm64        # Windows Setup.exe 安装包（含 VC 运行库，自动复制到 Downloads 与 dist/）
flutter build apk --release --split-per-abi --no-tree-shake-icons

# ── 双引擎金标对照（CI 必跑）──
cd .. && python eval/cross_engine_parity.py               # Python↔Dart 逐字段一致
```

**交付形态约定**：只交安装包，不交 zip/裸目录——Windows 用 `CompassSetup-*.exe`（用户级安装，免管理员，双击即用、带卸载项）；Android APK、iOS IPA、鸿蒙 HAP 本身即安装包；产物统一落 `dist/`。

**内置字体**：`compass_app/assets/fonts/NotoSansSC-{Regular,Bold}.ttf`（OFL-1.1，按 GB2312+应用文案裁剪，两个文件共约 4.5MB），保证干净 Linux/精简 Windows/无中文环境的设备上中文一致渲染。

**真实教务登录排查**：App 右上角 🐞"登录诊断日志"逐步记录卡点（无敏感值），配合 `docs/实测登录指南.md` 定位。

**学业分析套件**（App 四个 Tab）：
- **培养方案**（「方案」页）：浙大通行证登录后自动「专业名 + 年级」匹配教务培养方案并爬取接口，
  应用内结构化观看（概览/学分学制/培养目标与要求/专业核心课·核心实践课·前沿与荣誉课程 chips（已修高亮）/课程表/辅修/第二三四课堂/官方 PDF）；
  **匹配有歧义时不替用户猜**，列出候选方案让用户点选；详见 `docs/培养方案接入说明.md`
- **学业审计**：三色达成度报告（教务实时培养方案优先，内置样例兜底；方案打印页解析附数据质量提示）
- **学业看板**：4.3 制/五分制 GPA、加权百分制、已获学分、按课程性质的学分看板、第二/三/四课堂分（素拓）
- **GPA 工具**：学期走势折线图（学期+累计双线，CustomPainter 零依赖）、GPA 模拟器（what-if 加课预测 + 目标反推"剩余学分需达到的平均绩点"）
- 登录后自动：识别专业（学业生涯页 N105515→学籍页兜底）→ 匹配培养方案（列表 N153020 + 打印页）→ 注册为运行时方案 → 审计；课堂分并行拉取（N108001），失败不阻断

> 本机若为定制 Flutter 分支：`flutter test` 会因 SDK hash 挂起，用 `dart test` 替代；构建加 `--no-tree-shake-icons`。

## 目录

| 路径 | 内容 |
|---|---|
| `docs/开发方案.md` | 工程版实施方案（架构/数据模型/排期） |
| `docs/已知问题-Windows窗口resize崩溃.md` | Windows 改窗口大小闪退的根因（引擎无障碍桥空指针）与规避 |
| `docs/运行与构建指南.md` | 怎么跑：桌面/真机/各平台打包（含鸿蒙 HAP）、单测、常见问题 |
| `docs/培养方案接入说明.md` | 培养方案取数与匹配：接口清单、匹配算法、字段、已知限制、回归护栏 |
| `docs/PDF观看方案-鸿蒙.md` | 应用内看方案 PDF 的鸿蒙可选包（已实测版本约束）与落地方式 |
| `schema/` | plan / record / report 三数据契约 |
| `data/golden/` | 两专业培养方案结构化终稿（进 git，演示用合成数据） |
| `data/samples/` | 演示记录：粘贴文本、教务导出 CSV、含计划选课的全量 JSON |
| `engine/` | 规则引擎（= Dify Code 节点源）：audit / adapters / timecheck / common / build_embed / run_audit |
| `dify/` | 搭建指南 + 可直接粘贴的代码节点源（audit_code_node / m1_validate_code / policy_gate_code） |
| `prompts/` | m1_extract（抽取）/ m2_narrate（叙事）/ m4_answer（政策问答） |
| `eval/` | 抽取准确率评测脚本（指标①≥95% 的出数工具） |
| `video/` | 演示固化输入与拍摄清单 |

## 数据流（答辩架构图）

```
培养方案PDF ──[Workflow M1: 抽取+校验+人工订正]──> data/golden/*.json（冻结，溯源含页码）
粘贴/导出CSV/接口 ──[adapters 三源适配器]──> Record Schema ──┐
golden（build_embed 注入为常量）──────────────────────────────┴─> [Code: audit 规则引擎]
                                                                    │ Report Schema JSON
                                            [LLM 叙事包装]──> 三色达成度报告 Markdown
政策文件×3 ──[知识库检索]──[Code 拒答门]──[LLM 带出处回答 / 固定拒答文案]
```

## 合规红线（写进申报书的工程落点）

- 演示数据全部合成：无真实姓名/学号（`student.alias` 为虚拟标识），见 `video/演示固化与自检.md` 检查项；
- 凭证不落库、不留存；教务真实数据仅在 10/14 go/no-go 通过（书面授权 ≥5 份）后经 `export_csv` 适配器进入，`xuezaizheda_api` 分支为"已设计未启用"状态；
- 输出固定声明：*本报告仅供与导师沟通参考，正式认定以教务系统为准*（引擎硬编码，LLM 无权删改）。

## 每日自检（对应排期"当晚硬验收"）

| 日期 | 命令/标准 |
|---|---|
| 10/13 | `run_audit.py` 报告能出（M2 骨架）；M1 对 1 份 PDF 结构正确率≥80% |
| 10/14 | 单测全绿；golden 冻结；`go/no-go` 判定 |
| 10/15 | 主链路粘贴→报告 30 秒内出；Chatflow 拒答分支演示 |
| 10/16 | `eval/extract_accuracy.py` 出真实准确率表；固化输入×5 连跑零失误 |
