# 课舟 ClassArk 鸿蒙（HarmonyOS NEXT）AppTest / 应用测试分发全流程指南

> 基线日：**2026-10-21** ｜ 适用仓库：`Kepler16f/zju-kezhou`（main 分支）
> 适用范围：从「华为开发者联盟实名」到「测试人员装到包并回捞崩溃日志」，含 CI 签名对接。
> **本指南只描述流程与命令，不改动任何代码 / CI 文件**；文中给出的 diff 均为「建议」，需另行评审落地。

---

## 0. 仓库事实基线（先对账，再动手）

### 0.1 已确认的仓库事实（全部有出处）

| # | 事实 | 出处 | 对流程的影响 |
|---|---|---|---|
| F1 | 鸿蒙产物**由 GitHub Actions 构建**（`ubuntu-latest`），本机不参与鸿蒙打包 | `.github/workflows/build-hap.yml:13-14` | 签名必须在 CI 完成，或在华为云侧用 DevEco 完成 |
| F2 | CI 用 `ErBWs/setup-ohos@v2` 装鸿蒙 SDK，版本 `26.0.0.821` | `build-hap.yml:30-32` | 签名工具 `hap-sign-tool.jar` 随该 SDK 落地，CI 里可 `find` |
| F3 | Flutter 用 `flutter-ohos` 分支 `3.27.5-ohos-1.0.8`（gitcode） | `build-hap.yml:16-17`、`docs/运行与构建指南.md:9,59` | 决定 `flutter build hap` 的行为与产物路径 |
| F4 | `ohos/` 脚手架**不入库**，CI 现场 `flutter create --platforms ohos .` 生成 | `build-hap.yml:61-63` | 本地想看 `app.json5` / `module.json5`，必须自己先生成一次 |
| F5 | CI 把 `bundleName` 强制改写为 **`edu.zju.compass`** | `build-hap.yml:64` | 这是鸿蒙侧的「应用标识」，与 AGC 创建应用时填的包名必须一字不差 |
| F6 | 桌面显示名由 `packaging/set_ohos_app_name.py` 改成「课舟」/ en_US「KeZhou」 | `build-hap.yml:66-75`、`packaging/set_ohos_app_name.py` | 桌面名与 AGC 上的应用名是两套东西，可不同但送审材料要一致 |
| F7 | 图标由 CI 注入**分层图标**（前景 + 背景 + `layered_image.json`） | `build-hap.yml:77-96`、`compass_app/assets/brand/ohos/` | AGC 侧要按鸿蒙规范另传前景/背景两张图 |
| F8 | 产物名 **`compass_unsigned.hap`**（未签名），artifact 名 `compass-hap-unsigned`，`archive: false` | `build-hap.yml:113-124` | 下载到的是 hap 本体字节；HAP 本身是 zip，**不要再解包后当安装包** |
| F9 | 无签名配置时 `flutter build hap` 以非 0 退出，但未签名 HAP 已产出（CI 靠 `find` 回收） | `build-hap.yml:107-116`（含 `:115` 注释） | 签名改造时这一步的容错逻辑要一起想清楚 |
| F10 | `build-hap.yml` **本身没有 tag 触发**，只有 `push main/master` / `workflow_call` / `workflow_dispatch` | `build-hap.yml:6-10` | tag 路径在 `buildAll.yml`（`buildAll.yml:12-16` 的 `tags: ["v*"]`）→ hap job（`buildAll.yml:128-132`） |
| F11 | `buildAll.yml` 手动派发的 `hap` 开关默认 **false** | `buildAll.yml:74-77` | 手动跑要显式 `-f hap=true` |
| F12 | 当前版本 `0.13.11+25` → versionName `0.13.11`、versionCode `25` | `compass_app/pubspec.yaml:4` | 上架版本号规则以 pubspec 为唯一事实源 |
| F13 | Android 侧 applicationId 为 `edu.zju.compass.compass_app` | `compass_app/android/app/build.gradle.kts:22` | 鸿蒙侧 `edu.zju.compass` 与之同族但不等同 |
| F14 | `KEZHOU00002` 是 **Windows Inno Setup 的 AppId**（CI 用），本地脚本用 `KEZHOU00001` | `.github/workflows/build-windows.yml:59,160`、`docs/运行与构建指南.md:113` | 它**不是**鸿蒙包名，不能填进 AGC；鸿蒙侧标识是 bundleName |
| F15 | 产物下载已有现成脚本，兼容 `archive:false` 产物 | `packaging/_dl_artifacts.sh`、`packaging/check_ci_run.py` | 鸿蒙产物可直接复用这条链路 |
| F16 | 隐私政策已成文（占位版，两处待补） | `docs/隐私政策.md`（未入库，`git status` 显示 `??`） | 需要托管到公网 URL 后填进 AGC |
| F17 | 合规红线已工程化：只读红线扫描、凭证只存沙箱、Cookie 只驻内存 | `eval/check_readonly.py`、`compass_app/lib/data/credential_store.dart:1-13`、`docs/教师模式合规说明.md` | 上架材料的"数据处理说明"可以直接引用这些既成事实 |
| F18 | 已有落盘诊断日志（崩溃取证用） | `compass_app/lib/data/diagnostic_log.dart:1-4`、`docs/实测登录指南.md` | 崩溃回捞的零成本兜底方案 |

### 0.2 本机能力边界（决定了哪些步骤不能在本机做）

| 能力 | 本机有？ | 影响 |
|---|---|---|
| 鸿蒙 SDK（OpenHarmony SDK / HarmonyOS SDK） | ❌ | 不能本地 `flutter build hap`，也不能本地签名 |
| DevEco Studio | ❌ | 不能用「自动签名」一键出 `.p12/.cer/.p7b` |
| flutter-ohos SDK | ❌（CI 里 clone） | 不能本地生成 `ohos/` 脚手架 |
| GitHub CLI（`gh`） | ✅（CI 产物链路已在用） | 可直接触发 / 下载产物 |
| OpenSSL / JDK keytool | ✅ | 可在本地生成密钥与 CSR（不必上华为云） |

**结论**：签名材料在**本地用 openssl/keytool 生成密钥** → 上传到 AppGallery Connect 换 `.cer` + `.p7b` → 放回 GitHub Secrets → CI 签包。全程不需要 DevEco Studio。

### 0.3 三处「常见说法」与本仓库事实的差异（先纠正，避免照着做错）

1. **版本号**：本仓库当前是 `0.13.11+25`（`compass_app/pubspec.yaml:4`），不是 `1.0.0-beta.1`。若要迁到 `1.0.0-beta.1`，规则见 §5.5。
2. **`compass_app/ohos/` 目录当前不存在**（CI 现场生成，且 `.gitignore` **没有**忽略 `ohos/`）。想看 `app.json5` / `module.json5` 的真实内容，只能本地跑一次 `flutter create --platforms ohos .` 或从 CI 日志里捞。**注意**：本地生成后若误 `git add .`，会把整套脚手架提交进库——建议届时手动 `git restore --staged ohos/` 或临时加 ignore 规则（本次不改仓库）。
3. **`docs/隐私政策.md` 里有两处占位**：隐私政策 §12.2 联系方式写的是「浙大校内邮箱，提交前替换为真实邮箱」，§首部「最近更新」也是占位。这两处**必须**在托管前替换，否则 AGC 审核会因「无法联系开发者」驳回。

---

## 1. 全流程总览

### 1.1 三条路径（先选路，再干活）

| 路径 | 适用 | 需不需要华为审核 | 耗时 | 测试人数上限 |
|---|---|---|---|---|
| **路径 0**：CI 出签名 HAP → 内网/私聊分发 + `hdc` 安装 | 5–20 人内部试用、赶时间 | ❌ 不需要 | **半天**（前提：签名材料已备好） | 无硬上限，动手装 |
| **路径 1**：AGC 建应用 → 上传 HAP → **内测（AppTest）** | 20 人以上、要统一安装入口、要华为侧审核背书 | ✅ 需要（内测审核比上架轻） | **3–7 个工作日** | 以 AGC 页面为准（常见上限 1000 人） |
| **路径 2**：同上 + 正式上架 AppGallery | 对外公开分发 | ✅ 完整上架审核 | **6–10 周**（含软著、APP 备案） | 无 |

> **本指南主线走路径 1（AppTest / 内测）**，路径 0 作为「卡在华为审核时的救急通道」写进 §8.3。

### 1.2 阶段总表（基线 2026-10-21）

| 阶段 | 步骤 | 主要产出 | 关键卡点 |
|---|---|---|---|
| A 账号 | 2.1 注册 + 实名 | 可登录 AGC 的开发者账号 | 个人实名审核（0.5–2 工作日） |
| B 应用 | 3.1–3.4 建 AGC 项目 + HarmonyOS 应用 | bundleName `edu.zju.compass` 的应用条目 | 包名**创建后不可改** |
| C 证书 | 4.1–4.3 密钥 → CSR → `.cer` + `.p7b` | 签名四件套 | 发布证书人工审核（1–3 工作日） |
| D CI | 4.4–4.7 改 `build-hap.yml` + 灌 Secrets | 签好的 `compass_signed.hap` | 密钥泄露 / 算法不匹配 |
| E 构建 | 5.1–5.4 触发 CI → 下载产物 | `dist/ohos/compass_signed.hap` | `archive:false` 下载物无扩展名 |
| F 分发 | 6.1–6.3 上传 AGC → 内测 → 招募 | 测试人员可下载的入口 | 版本号/包名/证书三重校验 |
| G 回捞 | 6.4 崩溃与反馈 | 崩溃列表 / 诊断日志 | 鸿蒙侧 native crash 不进 Dart 日志 |
| H 合规 | 7.x 隐私政策托管、截图、权限说明、软著、备案 | 可送审的材料包 | 隐私政策 URL 不可访问 = 直接驳回 |

---

## 2. 步骤一：前置条件清单

### 2.1 华为开发者联盟账号与实名

| 项 | 要求 | 在哪操作 | 备注 |
|---|---|---|---|
| 账号 | 华为开发者联盟个人账号 | <https://developer.huawei.com/consumer/cn/> → 注册 | 手机号 + 邮箱 |
| 实名认证 | **个人**实名（身份证 + 人脸） | 登录后 → 右上角「账号中心」→「实名认证」 | 个人认证免费、审核快；企业/高校组织认证要营业执照/组织证明，周期长 |
| 开发者类型 | 选「个人开发者」即可做内测 | 同上 | 上架阶段再考虑是否升级主体 |
| AppGallery Connect | 免费开通 | <https://developer.huawei.com/consumer/cn/service/josp/agc/index.html> → 首次进入引导创建项目 | AGC 与联盟账号打通，用同一账号 |

**常见失败**

| 现象 | 原因 | 处置 |
|---|---|---|
| 实名提交后一直「审核中」 | 节假日/人工审核队列 | 1–2 工作日未过再联系客服；先用路径 0 不受影响 |
| AGC 提示「无权限」 | 未实名或未同意 AGC 协议 | 先实名，再在 AGC 首启页勾选协议 |
| 团队多人协作 | 个人账号无法共享 | 建 AGC 项目后邀请成员（项目 → 成员管理） |

### 2.2 AppGallery Connect 项目

- **在哪操作**：AGC 控制台 → 顶部「我的应用」旁的项目选择器 → 「添加项目」。
- **要什么**：项目名（建议 `课舟 ClassArk`）、描述、自动创建即可。
- **产出**：项目 ID，后续创建应用、证书、版本都挂在这个项目下。

### 2.3 签名四件套（缺一不可）

| 文件 | 是什么 | 谁生成 | 能不能自己造 |
|---|---|---|---|
| `.p12` | **私钥库**：里面是私钥（PKCS#12 容器） | 你本地用 openssl/keytool 生成 | ✅ 必须自己生成，私钥永不上传 |
| `.csr` | **证书签名请求**（PKCS#10）或公钥摘要 | 你本地生成 | ✅ |
| `.cer` | **应用证书**（X.509），证明「这个包是我司的」 | 拿 `.csr` 去 AGC 换 | ❌ 只能由 AGC 签发（或自签，仅限调试） |
| `.p7b` | **Profile（描述文件）**：把 bundleName + 证书指纹 + 有效期 + 权限白名单绑在一起 | AGC 签发并下载 | ❌ 上传 AGC 必须用 AGC 签发的 `.p7b`；自签 `.p7b` 只能本地装，AGC 会拒收 |

> **一句话**：`.p12`/`.csr` 你造，`.cer`/`.p7b` 华为给。

### 2.4 调试证书 vs 发布证书（选错要重做）

| 维度 | 调试证书（debug） | 发布证书（release） |
|---|---|---|
| 用途 | 本地 `hdc install`、开发者模式真机调试 | **上传 AGC、内测/公测/上架**（本指南主线） |
| Profile 类型 | `type: debug`，有效期通常较短（1 年左右，以页面为准） | `type: provision`（正式）/ 可选 beta，约 1–3 年，以页面为准 |
| 设备绑定 | 调试 profile 可绑定指定设备 UDID，数量受限 | 不绑设备 |
| 能不能传 AGC | ❌ | ✅ |
| 本仓库用途 | 路径 0 内部装机时可临时用 | **内测分发必须用这个** |

> 建议：**只做发布证书**，调试证书等真机联调时再申请，避免两套材料混用。

### 2.5 需要 DevEco Studio 吗？——不需要（但它是最省事的兜底）

| 路线 | 是否要 DevEco | 做法 | 推荐度 |
|---|---|---|---|
| **A（推荐）** | ❌ 不需要 | 本地 openssl 生成密钥 → AGC「证书管理」页签里按它给的命令生成并上传 `.cer` → 下载 `.p7b` | ★★★★★ 全程命令行，与 CI 对接最顺 |
| **B（兜底）** | ✅ 需要 | 装 DevEco Studio → 工程「Project Structure → Signing Configs → Automatically generate signature」 → 材料落在 `%USERPROFILE%\.ohos\config\`，签名配置自动写进 `ohos/build-profile.json5` | ★★★ 需要借一台装了 DevEco 的机器（学校机房 / 队友） |
| **C（仅调试）** | ❌ 不需要 | `java-certtool.jar` 自签一套 `.cer`/`.p7b` | ★★ **AGC 会拒收**，只能本地装机用 |

### 2.6 前置条件 Checklist

- [ ] 华为开发者联盟账号已注册
- [ ] 实名认证通过（个人即可）
- [ ] AGC 项目已创建，成员已邀请
- [ ] 本机有 `openssl`、`keytool`（JDK 17 即可）
- [ ] 本机有 `gh`（`gh auth status` 通过），且对 `Kepler16f/zju-kezhou` 有写权限
- [ ] 已决定走路径 1（AGC 内测）还是路径 0（内网直装）
- [ ] 已确认密钥**只**存本机磁盘，不入 git（见 §4.4 注意事项）

---

## 3. 步骤二：创建应用与开通 AppTest

### 3.1 创建 HarmonyOS 应用

**在哪操作**：AGC 控制台 → **我的应用** → **添加应用** → 选平台 **HarmonyOS** → 填表。

> 界面路径以官网当前界面为准（AGC 改版频繁），但下面每一项字段与仓库事实的对应关系不变。

### 3.2 表单逐条填写

| 表单项 | 填什么 | 为什么 | 校验点 |
|---|---|---|---|
| 应用名称（中文） | `课舟 ClassArk` | 与送审材料、`docs/隐私政策.md` 首行「课舟 ClassArk 隐私政策」一致 | 提交前与 F6 的桌面名「课舟」区分开：桌面名是安装后图标下的名字，AGC 名是市场名 |
| 应用名称（英文） | `ClassArk` | iOS 侧安装包显示名就是 ClassArk（README:7） | — |
| **包名 / Bundle Name** | **`edu.zju.compass`** | **必须与 `build-hap.yml:64` 写入 `ohos/AppScope/app.json5` 的值一字不差** | 创建后**不可修改**；改包名 = 改 `build-hap.yml:64` + 重建 AGC 应用 + 重新签 profile |
| 应用分类 | `教育 - 教育工具`（或 `学习教育`） | 课舟是学业规划/选课辅助工具 | 类目树以官网当前界面为准；避免落在「工具」等泛类目导致审核问询 |
| 描述 | 「课舟 ClassArk 是一款本地优先的本科培养方案结构化与选课风险审计工具：把培养方案 PDF 解析成可计算的表，算学分缺口、先修冲突与时间冲突，并通过浙江大学统一认证只读读取本人成绩/课表/培养方案/选课查询。**非官方工具**，不提交任何选课操作。」 | 必须写明「只读」「非官方」「本地优先」 | 禁止出现「官方」「第一」「最」等极限词；禁止暗示浙大官方出品（见 §7.4） |
| 应用图标 | 1024×1024 PNG | HarmonyOS 要求**前景 + 背景**分层 | 用 `compass_app/assets/brand/ohos/background.png` + `foreground.png`；`layered_image.json` 是工程内引用关系（`app.json5` 的 `icon` 指向 `$media:layered_image`） |
| 应用截图 | 手机 ≥1 张（建议 3–5 张），另给平板/2in1 各 1–2 张 | AGC 必填 | 竖版 1080×1920 或更高，宽 ≥720；用 `docs/render/`（已 gitignore）渲染 |
| 隐私政策 URL | 见 §3.3 | 必填 | **必须公网可访问、无需登录、非 JS 渲染** |
| 适龄/人群 | 详见 §7.3 | 涉及未成年人 | — |

### 3.3 隐私政策 URL 的具体做法（`docs/隐私政策.md` → 公网 URL）

**现状**：`docs/隐私政策.md` 已存在（9379 字节，未入库），但**两处占位必须先替换**：
- 第 12.2 条：`contact: 课舟项目组（浙大校内邮箱，提交前替换为真实邮箱）` → 换成真实可收信的邮箱；
- 文首「最近更新：2026-10-21（占位，正式发布前替换为最近一次更新时间）」→ 改成实际更新日。

**托管方式（三种，按推荐度）**

| 方式 | 链接形态 | 优点 | 坑 |
|---|---|---|---|
| **① GitHub Pages（推荐）** | `https://kepler16f.github.io/zju-kezhou/privacy-policy.html` | 是真网页、样式可控、长期免费 | 需要仓库开 Pages（Settings → Pages → GitHub Actions）；**文件名用 ASCII** |
| ② GitHub raw | `https://raw.githubusercontent.com/Kepler16f/zju-kezhou/main/docs/privacy-policy.md` | 零配置，改完即生效 | 返回 `text/plain`，审核爬虫可能不认；**中文文件名需 URL 编码**，建议先改成 ASCII 文件名 |
| ③ 对象存储 / 静态托管 | 任意 https 地址 | 完全可控 | 自有域名需 **ICP 备案**；境外站点在境内审核里可能被拒 |

**GitHub raw 链接格式（记牢这个模板）**

```
https://raw.githubusercontent.com/<owner>/<repo>/<branch-or-tag>/<path-in-repo>
```

本仓库实例：

```
# 分支（内容会随推送变，审核期间要保证该分支上的文件始终可达）
https://raw.githubusercontent.com/Kepler16f/zju-kezhou/main/docs/privacy-policy.md

# tag（内容冻结，审核期间最稳 —— 建议提交前打一个 tag 固定内容）
https://raw.githubusercontent.com/Kepler16f/zju-kezhou/v0.13.12/docs/privacy-policy.md
```

> **推荐组合**：文件本体放 `docs/privacy-policy.md`（ASCII 文件名，内容 = 现在的 `docs/隐私政策.md`），再开 GitHub Pages 指向 `docs/privacy-policy.md` 生成 HTML 页，AGC 里填 **Pages 的 HTML 链接**，raw 链接作为备用。审核通过后该 URL 长期有效，是应用信息里的必填项，**换域名等于重新提审**。

**Pages 最小做法**（不改仓库也能先跑通）：把 `docs/隐私政策.md` 内容包一层 `<html>` 丢进任意静态托管，拿到 https 链接即可。

**常见失败**

| 现象 | 原因 | 处置 |
|---|---|---|
| AGC 报「隐私政策链接无法访问」 | 仓库是私有的，raw 返回 404 | 确认仓库公开，或改用公开可访问的托管 |
| 报「链接返回的不是网页」 | 用了 raw（`text/plain`） | 改用 Pages/静态托管的 HTML 链接 |
| 报「链接内容与声明不符」 | 占位邮箱还在 | 先替换隐私政策 §12.2 再提交 |
| 审核期间链接 404 | 填的是 `main` 分支路径而文件被改名/删除 | 用 tag 固定内容的链接 |

### 3.4 「AppTest / 应用测试分发」入口在哪

HarmonyOS NEXT 的**应用测试分发 = AppGallery Connect 的「应用内测」**通道（部分文档/界面叫「应用测试」「Beta 分发」，以官网当前界面为准）。

**入口路径**（AGC 控制台）：

```
我的应用 → 选「课舟 ClassArk」→ 分发（或「版本管理」旁边的分发标签）
        → 应用内测 / 内测版本
```

或：

```
我的应用 → 选应用 → 版本管理 → 创建版本 → 版本类型选「内测版本」
```

两条路是同一个后台的不同入口：**「版本管理 → 创建版本 → 内测版本」负责传包**，「分发 → 应用内测」负责**招募测试人员与开关内测**。

**关键界面入口清单**（以官网当前界面为准）

| 用途 | 入口 |
|---|---|
| 创建应用 | 我的应用 → 添加应用 → HarmonyOS |
| 证书管理（`.cer` / `.p7b`） | 项目设置 / 我的应用 → 证书管理 |
| 上传版本 | 应用 → 版本管理 → 创建版本 → 上传 HAP |
| 内测分发 | 应用 → 分发 → 应用内测 |
| 崩溃/质量 | 应用 → 质量管理 → 崩溃分析（需开通分析服务） |
| 隐私合规 | 应用 → 合规 → 隐私政策 / 权限说明 |

### 3.5 步骤二 Checklist

- [ ] AGC 应用已创建，平台 = HarmonyOS
- [ ] 包名 = `edu.zju.compass`（与 `build-hap.yml:64` 一致）
- [ ] 应用名称 = 课舟 ClassArk / ClassArk
- [ ] 分类已选，描述已写明「只读 / 非官方 / 本地优先」
- [ ] 图标已按前景 + 背景两版上传（源自 `compass_app/assets/brand/ohos/`）
- [ ] 截图已备齐（手机 ≥1 张 + 平板/2in1）
- [ ] `docs/隐私政策.md` 两处占位已替换
- [ ] 隐私政策已托管出可访问 https URL（Pages 优先），已填入 AGC

---

## 4. 步骤三：签名配置与 CI 对接

### 4.1 选路线

```
本地 openssl 生成密钥/CSR ──┐
                            ├─→ AGC 申请发布证书 ─→ .cer + .p7b
本地 keytool 生成 p12+CSR ──┘
                                          ↓
                          GitHub Secrets（base64 + 口令 + 别名）
                                          ↓
                          CI 里签包 → compass_signed.hap
```

### 4.2 生成密钥与 CSR

#### 4.2.1 路线 A1：RSA 3072（与 AGC 证书管理页给出的命令一致）

> **以下命令请以 AGC「证书管理」页面当场给出的那条为准**（不同版本页面给的参数略有差异，如 subject 里的 O/CN）。下面这套是华为文档长期使用的版本。

```bash
mkdir -p ~/kezhou-signing && cd ~/kezhou-signing
umask 077                       # 生成的文件默认只有本人可读

# ① 私钥
openssl genrsa -out OpenHarmony.pem 3072

# ② 自签证书（作为"提交给 AGC 的证书"，具体是否用 csr 形式以页面为准）
openssl req -new -x509 -key OpenHarmony.pem -out OpenHarmonyApplication.pem \
  -subj "/C=CN/O=KeZhou ClassArk/CN=OpenHarmonyApplication Release" -days 3650

# ③ 打成 p12（别名 = 后面 CI 的 keyAlias，别名里有空格，yml 里要加引号）
openssl pkcs12 -export -in OpenHarmonyApplication.pem -inkey OpenHarmony.pem \
  -out OpenHarmony.p12 -password pass:'<STORE_PASSWORD>' \
  -name "OpenHarmonyApplication Release"
```

产物：`OpenHarmony.pem`（私钥，**永不外传**）、`OpenHarmonyApplication.pem`/`.cer`（证书，上传 AGC）、`OpenHarmony.p12`（私钥库，放进 CI Secret）。

#### 4.2.2 路线 A2：EC P-256 + keytool（想拿到标准 CSR 文本时）

```bash
keytool -genkeypair -v \
  -keyalg EC -keysize 256 -sigalg SHA256withECDSA \
  -dname "CN=OpenHarmonyApplication Release, OU=KeZhou ClassArk, O=KeZhou ClassArk, L=Hangzhou, ST=Zhejiang, C=CN" \
  -alias "OpenHarmonyApplication Release" \
  -keystore OpenHarmony.p12 -storetype PKCS12 \
  -storepass '<STORE_PASSWORD>' -keypass '<KEY_PASSWORD>' \
  -validity 3650

keytool -certreq -v -alias "OpenHarmonyApplication Release" \
  -keystore OpenHarmony.p12 -storepass '<STORE_PASSWORD>' \
  -file OpenHarmony.csr
```

> **注意**：多数 JDK 的 PKCS12 存储**要求 key 口令 = store 口令**。若 `keytool` 报 `-keypass` 相关错，把两者设成同一个值即可（CI 里也用同一口令，减少一个 Secret）。

#### 4.2.3 自检

```bash
# p12 里有什么（别名、有效期、签名算法）
keytool -list -v -keystore OpenHarmony.p12 -storepass '<STORE_PASSWORD>' \
  | grep -E 'Alias name|Entry type|Owner|Valid from|Signature algorithm'

# 证书指纹（AGC 上登记的指纹就是它的 SHA-256）
openssl x509 -inform DER -in OpenHarmonyApplication.cer -noout -fingerprint -sha256
# 若拿到的是 PEM 证书，去掉 -inform DER
openssl x509 -in OpenHarmonyApplication.pem -noout -subject -dates -fingerprint -sha256
```

### 4.3 申请 `.cer` 与 `.p7b`（Profile）

**在哪操作**：AGC 控制台 → **证书管理**（有的界面在「项目设置 → 证书管理」）→ **创建证书** → 类型选 **发布证书**。

流程：

1. 页面给出生成命令（把 §4.2 的命令按页面参数跑一遍），得到 `.p12` + `.cer`；
2. **上传 `.cer`**（或页面给你 CSR 上传入口时，上传 `.csr`）；
3. AGC 签发后，下载 **`.cer`** 与 **`.p7b`（Profile）**；
4. **记录 `.p7b` 的有效期**（`not-after`），写进日程，到期前重新申请（见 §8.2 风险 R4）。

**`.p7b` 内含的绑定关系**（后面校验全靠它）：

| 字段 | 含义 | 必须等于 |
|---|---|---|
| `bundle-name` | 应用的包名 | `edu.zju.compass` |
| `distribution-cert-fingerprint` | 发布证书指纹 | AGC 里登记的 `.cer` 的 SHA-256 |
| `validity.not-before / not-after` | 生效与失效时间 | 当前时间必须落在区间内 |
| `type` | `provision`（正式）/ `debug`（调试） | 发布分发用 `provision` |

### 4.4 把四件套安全地交给 CI

**Secrets 命名建议**（本仓库目前没有任何 signing Secret，这是新增）：

| Secret 名 | 内容 | 生成命令 |
|---|---|---|
| `HAP_KEYSTORE_BASE64` | `OpenHarmony.p12` 的 base64 | `base64 -w0 OpenHarmony.p12 > k.b64`（macOS：`base64 < f \| tr -d '\n'`） |
| `HAP_CERT_BASE64` | `.cer` 的 base64 | `base64 -w0 OpenHarmonyApplication.cer > c.b64` |
| `HAP_PROFILE_BASE64` | `.p7b` 的 base64 | `base64 -w0 OpenHarmonyApplication.p7b > p.b64` |
| `HAP_KEYSTORE_PASSWORD` | p12 的 store 口令 | 手填 |
| `HAP_KEY_PASSWORD` | 私钥口令（= store 口令时也要显式设） | 手填 |
| `HAP_KEY_ALIAS` | p12 里的别名，如 `OpenHarmonyApplication Release` | 手填（**含空格**） |
| `HAP_SIGN_ALGO` | `SHA256withRSA` 或 `SHA256withECDSA` | 与密钥类型一致 |
| `HAP_BUNDLE_NAME` | `edu.zju.compass` | 用于 CI 侧比对 profile，加固用 |

**灌入命令**：

```bash
gh secret set HAP_KEYSTORE_BASE64   --body "$(cat k.b64)"
gh secret set HAP_CERT_BASE64       --body "$(cat c.b64)"
gh secret set HAP_PROFILE_BASE64    --body "$(cat p.b64)"
gh secret set HAP_KEYSTORE_PASSWORD --body '<STORE_PASSWORD>'
gh secret set HAP_KEY_PASSWORD      --body '<KEY_PASSWORD>'
gh secret set HAP_KEY_ALIAS         --body 'OpenHarmonyApplication Release'
gh secret set HAP_SIGN_ALGO         --body 'SHA256withRSA'
gh secret set HAP_BUNDLE_NAME       --body 'edu.zju.compass'

gh secret list          # 确认已存在（只显示名字与更新时间，不回显值）
```

**加固建议**

1. **用 GitHub Environments 隔离**：建一个 `release` 环境，把上述 Secret 放进去并加「必须审核」，然后给 workflow 加 `environment: release`。这样只有手动/tag 触发的发布跑能读到密钥，日常 push 触发的构建读不到。
2. **别把密钥放进仓库**：当前 `.gitignore` **没有**忽略 `*.p12` / `*.p7b` / `*.cer` / `*.pem`——建议在落地 PR 里补上这几条（本次不改文件，只记录待办，见附录 D）。
3. **私钥永不进 AGC**：只传 `.cer` / `.csr`；`.p12` 只进 GitHub Secret。
4. **定期轮换**：发布证书到期或疑似泄露时，重新走 §4.2–4.3，并把旧 Secret 删掉（`gh secret delete HAP_KEYSTORE_BASE64`）。

### 4.5 `build-hap.yml` 建议改造（diff 思路，**不要照抄即用，先评审**）

#### 4.5.1 两条改造路线

| 路线 | 做法 | 侵入面 | 风险 | 推荐 |
|---|---|---|---|---|
| **B：构建后独立签名**（推荐） | 保持现有「回收未签名 HAP」的逻辑不变，新增一步用 `hap-sign-tool.jar` 给 `compass_unsigned.hap` 签名，产出 `compass_signed.hap` | 只**新增** 2 个 step，不动 JSON5 | 低 | ★★★★★ |
| **A：注入 `build-profile.json5`** | 把签名配置写进 `ohos/build-profile.json5` 的 `app.signingConfigs` + `app.products[].signingConfig`，让 `flutter build hap` 自己签 | 需要往 JSON5 注入内容（**该文件带注释，`json` 解析不了**），并把 `build-hap.yml:107-117` 的容错逻辑重写 | 中 | ★★★ |

#### 4.5.2 路线 B 的建议 diff（新增，不改现有 step）

在 `.github/workflows/build-hap.yml` 的 `Build HAP`（`:107-117`）之后、`upload-artifact`（`:119-124`）之前插入：

```yaml
      # ── 建议新增：签名材料落地 ─────────────────────────────────────────
      - name: Prepare signing material
        env:
          HAP_KEYSTORE_BASE64: ${{ secrets.HAP_KEYSTORE_BASE64 }}
          HAP_CERT_BASE64:     ${{ secrets.HAP_CERT_BASE64 }}
          HAP_PROFILE_BASE64:  ${{ secrets.HAP_PROFILE_BASE64 }}
          HAP_KEYSTORE_PASSWORD: ${{ secrets.HAP_KEYSTORE_PASSWORD }}
          HAP_KEY_ALIAS:       ${{ secrets.HAP_KEY_ALIAS }}
        run: |
          set -euo pipefail
          SIG="$RUNNER_TEMP/ohos-sign"
          mkdir -p "$SIG"
          echo "$HAP_KEYSTORE_BASE64" | base64 -d > "$SIG/kezhou.p12"
          echo "$HAP_CERT_BASE64"     | base64 -d > "$SIG/kezhou.cer"
          echo "$HAP_PROFILE_BASE64"  | base64 -d > "$SIG/kezhou.p7b"
          chmod 600 "$SIG"/*
          # 早期失败点：口令错/别名不存在，在这里就炸掉，别等到签名步骤
          keytool -list -keystore "$SIG/kezhou.p12" \
            -storepass "$HAP_KEYSTORE_PASSWORD" -alias "$HAP_KEY_ALIAS" >/dev/null
          # profile 里绑定的包名是否与本应用一致（不匹配 = 上传必被拒）
          python3 - "$SIG/kezhou.p7b" <<'PY'
          import re, sys
          raw = open(sys.argv[1], 'rb').read()
          txt = b''.join(re.findall(rb'[ -~]{4,}', raw)).decode('latin1')
          m = re.search(r'bundle-name"?\s*[:=]?\s*"?([A-Za-z0-9_.]+)', txt)
          print('profile bundle-name =', m.group(1) if m else 'NOT FOUND')
          PY

      # ── 建议新增：给回收来的未签名 HAP 补签名 ───────────────────────────
      - name: Sign HAP
        env:
          HAP_KEYSTORE_PASSWORD: ${{ secrets.HAP_KEYSTORE_PASSWORD }}
          HAP_KEY_PASSWORD:      ${{ secrets.HAP_KEY_PASSWORD }}
          HAP_KEY_ALIAS:         ${{ secrets.HAP_KEY_ALIAS }}
          HAP_SIGN_ALGO:         ${{ secrets.HAP_SIGN_ALGO }}
        run: |
          set -euo pipefail
          SIG="$RUNNER_TEMP/ohos-sign"
          # 注意：find | head -n 1 在 pipefail 下会因 SIGPIPE 返回 141，这里用 -print -quit
          TOOL="$(find "$HOME" /opt /usr/local -maxdepth 8 -name 'hap-sign-tool*.jar' -print -quit 2>/dev/null || true)"
          if [ -z "$TOOL" ]; then
            echo "::error::未找到 hap-sign-tool.jar（检查 setup-ohos 装的 SDK 布局）"
            exit 1
          fi
          echo "sign tool: $TOOL"
          java -jar "$TOOL" sign-app \
            -keyAlias "$HAP_KEY_ALIAS" \
            -signAlgo "${HAP_SIGN_ALGO:-SHA256withRSA}" \
            -mode localSign \
            -appCertFile "$SIG/kezhou.cer" \
            -profileFile "$SIG/kezhou.p7b" \
            -keystoreFile "$SIG/kezhou.p12" \
            -keystorePwd "$HAP_KEYSTORE_PASSWORD" \
            -keyPwd "$HAP_KEY_PASSWORD" \
            -inFile compass_app/build/ohos/compass_unsigned.hap \
            -outFile compass_app/build/ohos/compass_signed.hap
          ls -la compass_app/build/ohos/
```

再追加一个产物上传（**保留**原来的未签名产物，它对排查很有用）：

```yaml
      - uses: actions/upload-artifact@v7
        with:
          name: compass-hap-signed
          archive: false
          path: compass_app/build/ohos/compass_signed.hap
          if-no-files-found: error
```

#### 4.5.3 路线 B 的三个注意点

1. **`hap-sign-tool.jar` 路径不固定**：`ErBWs/setup-ohos@v2`（`build-hap.yml:30-32`，SDK `26.0.0.821`）装的 SDK 里，签名工具一般在 `<sdk>/tools/hap-sign-tool/hap-sign-tool.jar` 或 `<sdk>/default/openharmony/toolchains/` 下。**先在 runner 上 `find` 一次并把结果回写进 workflow**，别猜。
2. **`-signAlgo` 必须与密钥类型一致**：RSA 私钥 → `SHA256withRSA`；EC P-256 → `SHA256withECDSA`。不一致会在签名时报算法不匹配。
3. **不要动 `build-hap.yml:107-117` 的容错逻辑**：`flutter build hap --release` 在无签名配置时以非 0 退出但已产出未签名 HAP（`:115` 的注释就是这么记的），`find` 回收依赖这个行为。路线 B 正是吃这份「未签名 HAP」，所以这段**必须原样保留**。

#### 4.5.4 路线 A 的思路（若最终决定走 hvigor 内建签名）

- 在 `ohos/build-profile.json5` 的 `app` 节点下加 `signingConfigs`（`name` / `type` / `material.storeFile` / `storePassword` / `keyAlias` / `keyPassword` / `profile` / `cert`），并把 `app.products[0].signingConfig` 指到它；
- `material` 里的路径用相对 `ohos/` 的路径（CI 里材料已落在 `$RUNNER_TEMP/ohos-sign`，需要把路径写成相对或绝对）；
- **难点**：`build-profile.json5` 是 JSON5（含注释），CI 里要用能吃注释的解析器（例如 `npx --yes json5` 或自己写正则注入），`json.loads` 会直接抛错；
- 改完之后 `flutter build hap --release` 会自己签出 `entry-default-signed.hap`，`:113` 的 `find '*unsigned*.hap'` 就**匹配不到**了 → 必须同步改 `find` 模式与 `:116` 的 `cp` 目标名。
  → **这就是推荐路线 B 的原因：路线 A 会牵动产物回收逻辑。**

### 4.6 bundleName 与 AppId 的一致性校验点（5 处，必须全等）

| # | 位置 | 怎么查 | 期望值 |
|---|---|---|---|
| 1 | AGC 应用信息页「包名」 | 控制台肉眼 | `edu.zju.compass` |
| 2 | CI 生成的 `ohos/AppScope/app.json5` | `grep bundleName ohos/AppScope/app.json5` | `edu.zju.compass` |
| 3 | 编译后 HAP 内 | `unzip -p xxx.hap module.json \| grep -o 'bundleName[^,]*'` | `edu.zju.compass` |
| 4 | 签名 profile `.p7b` 内 | §4.5.2 的 python 片段 / `openssl asn1parse -inform DER -in kezhou.p7b -dump \| grep -i bundle` | `edu.zju.compass` |
| 5 | AGC「证书管理」里该应用名下的证书 | 控制台 | 与 `.cer` 指纹一致 |

> **关于 AppId**：`KEZHOU00002` 是**Windows Inno Setup 安装包的 AppId**（`.github/workflows/build-windows.yml:59,160`；本地脚本用 `KEZHOU00001`，见 `docs/运行与构建指南.md:113`）。它**不能**当鸿蒙包名填进 AGC。鸿蒙侧的应用标识只有 bundleName。若要在申请材料里做「全渠道统一标识」，就把 `KEZHOU00002` 当作文档编号写进去，包名仍用 `edu.zju.compass`。

### 4.7 步骤三 Checklist

- [ ] 本地已生成 `.p12`（含私钥）+ `.csr`/`.cer`
- [ ] AGC 已申请**发布证书**，`.cer` 与 `.p7b` 已下载并备份到本机**仓库外**目录
- [ ] `.p7b` 的 `bundle-name` = `edu.zju.compass`
- [ ] 已记录 `.p7b` 与 `.cer` 的有效期
- [ ] 8 个 Secret 全部 `gh secret list` 可见
- [ ] 建议：Secret 放在 GitHub Environment `release` 下
- [ ] `build-hap.yml` 的改造方案已在 PR 里评审（路线 B），`hap-sign-tool.jar` 路径已实测
- [ ] 建议：`.gitignore` 补 `*.p12` / `*.p7b` / `*.cer` / `*.pem`（见附录 D）

---

## 5. 步骤四：构建与产物

### 5.1 CI 触发方式（3 条路，别混淆）

| 触发方式 | 命令 / 操作 | 会不会出鸿蒙包 | 备注 |
|---|---|---|---|
| **手动单跑鸿蒙** | `gh workflow run build-hap.yml --repo Kepler16f/zju-kezhou --ref main` | ✅ | `build-hap.yml` 的 `workflow_dispatch` **没有任何 input**，一按就跑 |
| **全平台分发器手动** | `gh workflow run buildAll.yml --repo Kepler16f/zju-kezhou --ref main -f hap=true` | ✅ | `hap` 默认 false，必须显式传（`buildAll.yml:74-77`） |
| **push tag** | `git tag v0.13.12 && git push origin v0.13.12` | ✅（自动） | `buildAll.yml:12-16` 的 `tags: ["v*"]` → hap job 必跑（`buildAll.yml:128-132` 的 `startsWith(github.ref,'refs/tags/v')` 条件） |
| push main/master | 直接 push | ⚠️ 会跑 | `build-hap.yml:7-8` 对 main/master 的 push 会触发鸿蒙构建（**每次推 main 都烧一次 CI**） |

**推荐节奏**：签名打通阶段用「手动单跑」迭代；材料齐了、版本冻结了，再打 tag 走全平台出包。

### 5.2 产物名

| 阶段 | 文件名 | 位置 | artifact 名 |
|---|---|---|---|
| 未签名（现状） | `compass_unsigned.hap` | `compass_app/build/ohos/` | `compass-hap-unsigned` |
| **签名后（建议名）** | **`compass_signed.hap`** | `compass_app/build/ohos/` | 与未签名包**同一 artifact** `compass-hap-unsigned`（多 path 上传；签名 Secret 齐备时才出现） |

> 建议命名保持 `kezhou` 系族一致（README:8：仓库、安装包与产物名沿用 `kezhou`）。若要与 Android/Windows 的版本化命名对齐，可改为 `kezhou-<version>-ohos-arm64.hap`，版本号取自 `compass_app/pubspec.yaml:4`。
>
> 交付形态提醒（README:73）：**HAP 本身就是安装包**，不要交 zip、不要再套一层目录。

### 5.3 下载产物

#### 5.3.1 用 `gh`（最快）

```bash
gh run list --workflow build-hap.yml --limit 5
gh run download <run_id> -n compass-hap-unsigned -D dist/ohos/   # 目录内含 unsigned（必有）与 signed（有签名时才有）
ls -la dist/ohos/
# archive:false → 下载物没有 .hap 扩展名，按 artifact 名落盘，需改名
ls dist/ohos/   # compass_unsigned.hap / compass_signed.hap
```

#### 5.3.2 用仓库自带脚本（已处理 `archive:false` 的怪癖）

```bash
python packaging/check_ci_run.py <run_id> HarmonyOS     # 轮询到完成，打印每个 job 状态
bash packaging/_dl_artifacts.sh <run_id> kezhou-0.13.12-hap
```

> **这个脚本的一个已知副作用**（`packaging/_dl_artifacts.sh`）：HAP 文件头是 `PK`，脚本会把它当 zip 打开；HAP 内含多个条目 → 走「原样写出」分支，**文件名用的是 artifact 名（无 `.hap` 扩展名）**。所以下载完仍要手工改名成 `compass_signed.hap`。
>
> 顺带一提：仓库目前**没有** release workflow，`gh release download` 用不上（产物只走 Actions artifacts + 手工落到 `dist/`；`dist/` 已在 `.gitignore` 里）。

### 5.4 产物自检（下载后立刻做，5 条命令）

```bash
HAP=dist/ohos/compass_signed.hap

# ① 是不是一个完整的 HAP（zip 容器）
unzip -l "$HAP" | head -20

# ② 包名与版本（编译后的 module.json 合并了 app 段）
unzip -p "$HAP" module.json | python -c "
import sys, json
d = json.load(sys.stdin)
a = d.get('app', {})
v = a.get('version', {})
print('bundleName =', a.get('bundleName'))
print('versionCode=', v.get('code'))
print('versionName=', v.get('name'))
"

# ③ 版本是否与 pubspec 对得上（0.13.11+25 → 25 / 0.13.11）
grep -E '^version:' compass_app/pubspec.yaml

# ④ 签名自检（该子命令以工具 --help 为准）
TOOL=$(find "$HOME" -name 'hap-sign-tool*.jar' -print -quit)
java -jar "$TOOL" verify-app -inFile "$HAP"

# ⑤ 大小体检（arm64 release 通常 20–60 MB；过小说明打包不完整）
ls -lh "$HAP"
```

### 5.5 版本号规则（AGC 与 HAP 必须一致）

| 来源 | 字段 | 当前值 | 规则 |
|---|---|---|---|
| `compass_app/pubspec.yaml:4` | `version: 0.13.11+25` | versionName `0.13.11` / versionCode `25` | `+` 后面是 build number → versionCode；前面是 versionName |
| AGC 版本表单 | 版本名 | `0.13.11` | 与 HAP 内 `version.name` **一字不差** |
| AGC 版本表单 | 版本代码 | `25` | 与 HAP 内 `version.code` 一致，且**必须大于历史版本** |

> **若要迁到 `1.0.0-beta.1`**：pubspec 写成 `version: 1.0.0-beta.1+26`（build number 必须继续递增）。鸿蒙侧 `version.name` 是字符串，允许带连字符；`version.code` 必须是整数。**注意**：AGC 的版本表单与 HAP 内的值都要同步改，且内测/上架的每个版本号都不能复用。
>
> 迁移前先确认 CI 是从 pubspec 取版本号（`buildAll.yml` 注释亦如此写），不要在别处硬编码版本。

### 5.6 步骤四 Checklist

- [ ] CI 已触发（手动 / `-f hap=true` / tag）
- [ ] `Build HAP` 步骤通过；若走了路线 B，`Sign HAP` 步骤输出 `compass_signed.hap` 且非空
- [ ] `compass-hap-signed` artifact 存在
- [ ] 已下载到 `dist/ohos/` 并改名为 `compass_signed.hap`
- [ ] `unzip -l` 能列出条目；`module.json` 里的 bundleName = `edu.zju.compass`
- [ ] `version.code` / `version.name` 与 pubspec、AGC 表单一致
- [ ] 文件大小合理（不是几百 KB 的空壳）

---

## 6. 步骤五：上传与测试分发

### 6.1 上传 HAP 到 AGC

**在哪操作**：AGC → 我的应用 → 课舟 ClassArk → **版本管理** → **创建版本** → 版本类型选 **内测版本**。

| 表单项 | 填什么 | 校验规则 |
|---|---|---|
| 上传文件 | `compass_signed.hap` | 必须是**已签名**的包；未签名包直接被拒 |
| 版本号（versionName） | 如 `0.13.11` | 与 HAP 内 `version.name` 一致 |
| 版本代码（versionCode） | 如 `25` | 与 HAP 内 `version.code` 一致且大于历史版本 |
| 版本说明 / 更新内容 | 「修复教师模式学业达成审计红屏」等，取自 `packaging/release-notes-v0.13.11.md` | 与 `packaging/release-notes-v0.13.11.md` 对齐；别写测试流水账 |
| 隐私政策 URL | §3.3 的链接 | 必须可访问 |
| 权限说明 | §7.2 的表 | 与 `module.json5` 声明逐条对应 |
| 测试说明 | 「内部测试，反馈群 xxx」 | 内测版本建议写清反馈渠道 |

### 6.2 提交时会被校验的四件事（预判失败点）

| 校验项 | 失败表现 | 根因 | 处置 |
|---|---|---|---|
| **包名一致** | 「包名与应用信息不匹配」 | AGC 包名 ≠ HAP 内 bundleName（§4.6 的 5 处有一处不一致） | 逐处比对；改 HAP 比改 AGC 容易 |
| **签名一致** | 「应用签名校验失败 / 证书不匹配」 | `.cer` 不是该应用在 AGC 登记的发布证书；或 profile 与 `.cer` 不是同一对 | 用 §4.2.3 的指纹命令核对；重新走 §4.3 |
| **版本一致** | 「版本号与包内信息不一致」 | 表单填的值 ≠ `module.json` 里的值 | 用 §5.4 的命令读出真实值再填 |
| **权限缺失** | 「声明的权限缺少用途说明」 | `module.json5` 里有 AGC 未登记/未填用途的受限权限 | 见 §7.2；删掉用不到的权限，别硬凑 |

### 6.3 内测发布与测试人员招募

1. **提交审核**：内测版本也要过华为侧审核（比上架轻，但会有轮次）。审核意见一般在 AGC 版本详情页。
2. **开启内测**：审核通过 → 应用 → **分发 → 应用内测** → 开启内测。
3. **添加测试人员**：按华为账号（手机号/邮箱）批量添加，或生成内测链接/二维码自助领取（人数上限以官网当前界面为准，常见为 1000 人）。
4. **测试人员取包**：登录华为账号 → **AppGallery → 我的 → 应用内测**，或直接点内测链接。
5. **真机直装通道（并行准备）**：测试人员也可走 `hdc` 直装（见 §8.3 路径 0），适合"审核没过但今天必须测"的情况。

### 6.4 测试报告与崩溃日志回捞

| 方案 | 接入成本 | 覆盖范围 | 是否需要改 Flutter 代码 | 适合阶段 |
|---|---|---|---|---|
| **A. 复用现有诊断日志**（推荐先上） | 零 | Dart 层登录/取数链路日志，落盘在 App 沙箱 | 否 | 现在就能用 |
| **B. 自建上报** | 中（要自建端点 + 隐私评估） | Dart 层未捕获异常 | 是（`FlutterError.onError` / `PlatformDispatcher.onError`） | 需要量化崩溃率时 |
| **C. 华为 AGC 崩溃分析（APL/分析服务）** | 中高（要开通服务 + 接 HMS 鸿蒙端 SDK，需平台通道） | **鸿蒙 native crash + ANR**（Dart 日志覆盖不到的） | 是 | 上架前必做 |
| **D. 友盟+ 等第三方（鸿蒙版 SDK）** | 中（注册 + 接 SDK） | 跨平台统一看 | 是（平台通道） | 已在用友盟则复用 |

**方案 A 的现成抓手**（仓库里已有）：

- `compass_app/lib/data/diagnostic_log.dart` — 内存环形缓冲 + 落盘持久化，**原生崩溃后重启仍能读到最后记录**（文件头注释即这么写的），日志只记步骤名/耗时/错误摘要，不记密码/票据；
- `docs/实测登录指南.md` — 登录/取数卡点的排查手册；
- 应用内已有「导出诊断日志」入口（README:45-46）。

**方案 C 的关键提醒**：**鸿蒙侧 native crash 不会进 Dart 的落盘日志**。所以只做 A 会漏掉真正的崩溃。要在真机上捞鸿蒙原生日志：

```bash
hdc shell hilog | grep -iE "edu.zju.compass|ClassArk"     # 实时看
hdc shell hilog -r                                          # 先清空再复现
hdc shell aa force-stop edu.zju.compass                    # 结束进程
hdc shell bm dump -n edu.zju.compass                       # 查包信息
```

（`hdc` 来自鸿蒙 SDK 的 `toolchains`，CI 里由 `setup-ohos` 装上；本机没有 SDK 时，用 SDK 目录下的 `hdc.exe`。）

### 6.5 步骤五 Checklist

- [ ] HAP 已在 AGC 上传成功（未被签名/包名/版本校验拦下）
- [ ] 版本说明与 `packaging/release-notes-v0.13.11.md` 对齐
- [ ] 隐私政策 URL、权限说明已填
- [ ] 内测已开启，测试人员已添加（记录名单与设备型号）
- [ ] 已准备 `hdc` 直装包作为备份通道
- [ ] 崩溃回捞方案至少落地方案 A；方案 C 列入上架前待办

---

## 7. 步骤六：合规与上架材料清单

### 7.1 材料总表

| # | 材料 | 来源 / 怎么准备 | 当前状态 | 责任人 |
|---|---|---|---|---|
| 1 | 隐私政策正文 | `docs/隐私政策.md`（**已存在**，9379 字节，未入库） | ⚠️ 两处占位待替换（§3.3） | 待定 |
| 2 | 隐私政策公网 URL | GitHub Pages / 静态托管（§3.3） | ❌ 未做 | 待定 |
| 3 | 应用图标（前景 + 背景 1024×1024） | `compass_app/assets/brand/ohos/foreground.png`、`background.png` | ✅ 已有 | — |
| 4 | 应用截图（手机/平板/2in1） | 真机截图；`docs/render/` 出图（已 gitignore） | ❌ 未做 | 待定 |
| 5 | 应用描述 / 版本说明 | 手写 + `packaging/release-notes-v0.13.11.md` | ⚠️ 描述待写 | 待定 |
| 6 | 权限用途说明 | §7.2，从 `module.json5` 逐条导出 | ❌ 待生成 | 待定 |
| 7 | 开发者主体信息 | 联盟实名信息 | ⚠️ 待确认主体名称 | 待定 |
| 8 | 软件著作权登记证书 | 第三方机构办理 | ❌ 未申请（见 §7.3） | 待定 |
| 9 | APP 备案 | 工信部平台 | ❌ 未备案（见 §7.3） | 待定 |
| 10 | 未成年人保护说明 | `docs/隐私政策.md` 第九节可直接引用 | ✅ 有底稿 | — |
| 11 | 浙大名称/校徽使用说明 | 见 §7.4 | ⚠️ 需决策 | 待定 |

### 7.2 权限用途说明（逐条对照 `module.json5`）

**先导出真实声明**（`ohos/` 目录当前不在库里，需先生成或从 CI 日志取）：

```bash
# 本机生成脚手架后：
flutter create --platforms ohos .        # 仅生成，不影响 lib/
grep -n -A30 'requestPermissions' compass_app/ohos/entry/src/main/module.json5
grep -n -E 'bundleName|versionCode|versionName' compass_app/ohos/AppScope/app.json5
```

**模板常见权限与本应用的实际用途**（模板实际内容以现场生成结果为准，下面按 flutter-ohos 脚手架常见项给出用途）：

| 权限 | 用途说明（可直接抄进 AGC） | 本应用是否必要 | 依据 |
|---|---|---|---|
| `ohos.permission.INTERNET` | 访问浙江大学统一认证与教务只读接口拉取本人成绩/课表/培养方案/选课查询，以及用户主动开启后向所选 AI 服务发送解读请求 | ✅ 必要 | `compass_app/lib/data/zju_client.dart`（`dart:io HttpClient`）、`compass_app/lib/data/ai_client.dart` |
| `ohos.permission.GET_NETWORK_INFO` | 获取网络类型与连接状态，用于登录失败/请求失败时的诊断提示与网络切换重试 | ✅ 必要（诊断） | `docs/实测登录指南.md` 的排障口径 |
| `ohos.permission.READ_PASTEBOARD` / `WRITE_PASTEBOARD` | 仅在用户点击「复制/粘贴分享包」时按指令读写一次 | ⚠️ 剪贴板在鸿蒙上通常**不需要显式声明**，先按模板实际内容判断是否保留 | `compass_app/lib/main.dart:548`、`compass_app/lib/pages/teacher_review_page.dart:113,257` |
| `ohos.permission.KEEP_BACKGROUND_RUNNING`（若模板有） | 后台常驻 | ⚠️ **本应用不需要**，建议删除 | 应用无后台服务需求 |
| 相机 / 麦克风 / 定位 / 通讯录 / 日历 | —— | ❌ **一律不得出现** | `docs/隐私政策.md` §8.3 明确「不收集通讯录、位置、相机、麦克风」，声明与实现必须一致 |

**规则**

1. **只留用得到的**。多声明一个用不到的权限，审核会问「为什么需要」，答不出就驳回；和隐私政策对不上还会被当成违规。
2. **受限权限（restricted）** 需要在 AGC 填用途说明，可能还要额外材料；本应用应尽量不碰受限权限。
3. **权限说明必须与 `docs/隐私政策.md` 的口径一致**（该文件 §2 已列明「不收集通讯录/位置/相机/麦克风」）。
4. **改 `module.json5` 的影响面**：`ohos/` 是 CI 现场生成的（`build-hap.yml:61-63`），改法只有两条路 —— ① 在 workflow 里对生成的脚手架做 `sed` 注入（和现有 `:64` 改 bundleName 同一个位置）；② 把 `ohos/` 目录纳入版本库（**改动大，不建议**）。推荐 ①。

### 7.3 软著 / 备案 / 未成年人 / 校名的合规要点

| 事项 | 结论 | 动作 |
|---|---|---|
| **软件著作权** | 国内主体上架 AppGallery 通常需要软著证书；委托机构办理约 30 工作日（可加急，另计） | 内部测试（路径 1 的内测版本）通常不强制，但**上架路径必须提前启动** |
| **APP 备案（工信部）** | 上架前须在「全国互联网安全管理服务平台」完成 APP 备案，周期 3–10 工作日 | 与软著并行启动；备案主体须与开发者信息一致 |
| **自有域名** | 若隐私政策页放自有域名，域名需 ICP 备案 | 用 GitHub Pages 规避；用国内云则走备案 |
| **未成年人保护** | 应用面向在校本科生（含刚入学大一新生），`docs/隐私政策.md` §9 已写：不做年龄核验、不收集年龄信息、监护人可代为清除/卸载 | AGC 的「适龄/人群」如实填写；不要勾选需要未成年人模式才能合规的档位；§9 内容可作为说明材料 |
| **AI 第三方与跨境** | `docs/隐私政策.md` §4/§11：默认公益端点 `text.pollinations.ai` 在境外，构成一次出境传输 | **上架时必须在 AGC 如实申报第三方服务与数据出境情况**，否则属隐瞒 → 风险最高的一项 |
| **浙大名称与校徽** | 见 §7.4 | 需决策后再提审 |

### 7.4 浙大名称与校徽使用说明（基于仓库现状的事实判断）

**仓库现状**：

- 应用图标是**自绘帆船**（`compass_app/assets/brand/icon_source.png` → `assets/brand/ohos/*`），**不含浙江大学校徽**，也不含校名字标；
- 应用的浙大关联体现在三处：① 包名 `edu.zju.compass`；② 应用描述/隐私政策里的「浙江大学统一认证」「浙大校内邮箱」；③ `docs/隐私政策.md` §1.1「开发者主体：浙江大学学生竞赛团队（课舟 ClassArk 项目组）」；
- 仓库 LICENSE 为 MIT，README 署名「Kepler16f / shiroiyoru142857 / 61025」。

**使用规则（可直接照做）**

| 做 | 不做 |
|---|---|
| 客观描述「对接浙江大学统一认证与教务系统（只读）」 | 使用「浙江大学官方 App」「浙大官方出品」「官方助手」等表述 |
| 在开发者主体里如实写「学生竞赛团队」并留可联系邮箱 | 使用浙大校徽、校名字标、或与校徽相近的图形作为应用图标 |
| 包名保留 `edu.zju.compass` | 把 `edu.zju` 理解为「已获授权使用 edu 域名」的凭据 |
| 隐私政策里说明「非官方工具，不提交任何教务写操作」 | 暗示与学校存在合作/背书关系 |

**两个待决策项**

1. **包名**：`edu.zju.compass` 含 `edu.zju` 域段，形态上是教育机构域名。个人/团队开发者使用它对外上架存在被质疑「冒用机构标识」的风险。改名（如 `com.kezhou.classark`）会牵连三处：`build-hap.yml:64` 的 `sed`、AGC 已创建的应用（包名不可改，需重建）、以及已签发的 `.p7b`（profile 绑包名，需重签）。**建议**：若走内测，保持 `edu.zju.compass` 不动（内测不对外，风险低）；**若确定正式上架，先决策包名，再一次性把 CI 与 AGC 对齐**。
2. **主体**：上架主体是「个人」还是「高校组织」？个人主体审核更严（尤其涉及教育类 + 高校系统对接）；若能以实验室/院系组织身份上架，需组织证明材料。

### 7.5 步骤六 Checklist

- [ ] 隐私政策两处占位已替换，且已 commit（当前文件未入库）
- [ ] 隐私政策已托管出 https URL，线上可打开、无需登录
- [ ] 图标按前景/背景两版备好
- [ ] 截图齐（手机 ≥1 张，建议 3–5 张；平板/2in1 各 1–2 张）
- [ ] 权限说明已按 §7.2 逐条写完，且与 `module.json5` 实际声明一致
- [ ] AI 第三方服务与数据出境情况已在 AGC 如实申报
- [ ] 未成年人说明已按 `docs/隐私政策.md` §9 准备
- [ ] 软著与 APP 备案已启动（或已确认内测阶段不强制）
- [ ] 包名与主体已决策（正式上架前必须定）
- [ ] 描述/文案已过一遍极限词与「官方」用词检查

---

## 8. 步骤七：时间表与风险

### 8.1 时间表（基线 2026-10-21，按工作日估算）

| 序 | 环节 | 起 | 止 | 耗时 | 阻塞因素 | 负责人 |
|---|---|---|---|---|---|---|
| 1 | 联盟注册 + 个人实名 | 10-21 | 10-22 | 0.5–2 工作日 | 人工审核 | 待定 |
| 2 | AGC 项目 + HarmonyOS 应用 | 10-22 | 10-22 | 0.5 天 | 包名决策 | 待定 |
| 3 | 密钥生成 + CSR | 10-22 | 10-22 | 0.5 天 | — | 待定 |
| 4 | 发布证书申请 → `.cer` + `.p7b` | 10-22 | 10-24 | 1–3 工作日 | **华为人工审核（关键路径）** | 待定 |
| 5 | `build-hap.yml` 签名改造（与 3–4 并行） | 10-22 | 10-23 | 0.5–1 天 | 需先跑通 `hap-sign-tool` 路径 | 待定 |
| 6 | CI 签名出包 + 自检 | 10-24 | 10-24 | 0.5 天 | Secret 灌入 | 待定 |
| 7 | 上传 AGC + 填版本 | 10-24 | 10-24 | 0.5 天 | 三重校验（包名/签名/版本） | 待定 |
| 8 | 内测版本审核 | 10-25 | 10-27 | 1–3 工作日 | 华为侧 | — |
| 9 | 开启内测 + 招募测试人员 | 10-27 | 10-28 | 1 天 | 测试人员到位 | 待定 |
| 10 | 灰度测试 + 反馈回收 | 10-28 | 10-31 | 2–3 天 | — | 待定 |

**关键路径 = 步骤 1 → 4**（实名与证书审核），合计 **3–7 个工作日**。

**若走正式上架（路径 2），追加：**

| 追加项 | 耗时 | 可并行？ |
|---|---|---|
| 隐私政策托管 + 图文材料 | 1 天 | 可与证书并行 |
| 软著登记（第三方） | ~30 工作日（可加急，另询） | ✅ 与一切并行，**最早上启动** |
| APP 备案（工信部） | 3–10 工作日 | ✅ 可并行 |
| 上架审核 | 3–7 工作日 | — |
| **合计** | **6–10 周** | — |

### 8.2 风险登记表

| ID | 风险 | 触发条件 | 影响 | 概率 | 缓解措施 | 责任 |
|---|---|---|---|---|---|---|
| R1 | **签名材料泄露** | p12 进了 git / 贴到聊天 / CI 日志打印口令 | 任何人可伪造发布包 | 中 | p12 只进 Secret；`.gitignore` 补 `*.p12/*.p7b/*.cer/*.pem`；`build-hap.yml` 里 `chmod 600` + 不 echo 口令；定期轮换 | 待定 |
| R2 | **包名不一致** | 改 `build-hap.yml:64` 或 AGC 建错 | AGC 拒收，需重建应用 + 重签 profile | 中 | §4.6 的 5 处校验点做成 CI 断言（profile bundle-name 与 HAP bundleName 自动比对） | 待定 |
| R3 | **签名算法不匹配** | `-signAlgo` 与密钥类型不符 | 签名步骤失败 | 中 | `HAP_SIGN_ALGO` 显式设；CI 里先 `keytool -list` 看算法 | 待定 |
| R4 | **profile / 证书过期** | 调试证书约 1 年、发布证书约 3 年（以页面为准） | 到期后 CI 签出的包装不上、AGC 拒收 | 中 | 把 `.p7b` 的 `not-after` 记进日程，到期前 30 天重新申请；CI 里加有效期断言 | 待定 |
| R5 | **隐私政策 URL 不可访问** | 仓库私有 / raw 返回 text/plain / 占位邮箱未替换 | 审核直接驳回 | 高 | 用 Pages 的 HTML 链接；提交前用无痕窗口自测；替换占位 | 待定 |
| R6 | **权限声明与实现不符** | 模板带了用不到的权限 / 隐私政策与声明不一致 | 审核驳回 / 下架风险 | 中 | §7.2 逐条对照；多余权限在 workflow 里 sed 删掉 | 待定 |
| R7 | **AI 第三方与数据出境未申报** | 用了境外公益端点未申报 | 隐瞒 → 下架风险 | **高** | 申报；或上架版默认关闭 AI（`docs/隐私政策.md` §4.1 说默认关闭，需核实现） | 待定 |
| R8 | **浙大标识合规** | 描述暗示官方 | 驳回 / 投诉 | 中 | §7.4 规则；上架前把包名与主体决策定下来 | 待定 |
| R9 | **CI 不稳** | gitee 限流导致 `pub get` 失败（`build-hap.yml:98-105` 已有 5 次重试）；SDK 布局变化导致找不到 `hap-sign-tool.jar` | 构建失败 | 中 | 重试已有；`hap-sign-tool.jar` 路径在 PR 里实测后写死（不再靠 find 猜） | 待定 |
| R10 | **main 分支 push 反复触发鸿蒙构建** | `build-hap.yml:7-8` 对 main 的 push 触发 | CI 额度与时长浪费 | 高 | 已知行为；改触发条件需另开 PR（本次不动） | 待定 |
| R11 | **鸿蒙 native crash 收不到** | 只做了 Dart 侧日志 | 线上崩溃看不见 | 中 | 上架前接 AGC 崩溃分析（§6.4 方案 C） | 待定 |
| R12 | **真实用户数据被误上报** | 诊断日志/崩溃上报里带出学号、Cookie | 合规事故 | 中 | `compass_app/lib/data/diagnostic_log.dart` 已限定不记录密码/票据；上报前再过一遍 `packaging/prepublic_scan.py` | 待定 |

### 8.3 最短路径：「只做内部测试分发、暂不上架」

**路径 0（半天，推荐先跑通）**

```
CI 跑 build-hap.yml（手动） → 用发布证书签出 compass_signed.hap
  → 下载到 dist/ohos/ → 通过内网/私聊发给测试者
  → 测试者：设置 → 关于手机 → 连点版本号开启开发者模式 → 用 hdc 安装
```

```bash
# 测试者本机（已装鸿蒙 SDK 或 DevEco 的 hdc）
hdc list targets
hdc install -r compass_signed.hap
# 或把包传到设备后安装
hdc shell ls /data/local/tmp/
hdc file recv compass_signed.hap /data/local/tmp/
hdc shell bm install -p /data/local/tmp/compass_signed.hap
```

| 项 | 路径 0 | 路径 1（AGC 内测） |
|---|---|---|
| 华为审核 | ❌ 无 | ✅ 有 |
| 耗时 | **半天**（证书已备好时） | 3–7 个工作日 |
| 前提 | 发布证书 + `.p7b` 已有 | 还需 AGC 建应用 + 审核 |
| 安装便利度 | 差（要开开发者模式 + 传文件） | 好（AppGallery 内测入口） |
| 规模 | ≤ 20 人 | 20 人以上 |

> **勾选内测能跳过的审核**：正式上架审核、软著强制校验、APP 备案、公开市场运营规范检查、应用市场评分与排名相关项。**不能跳过**的：开发者实名、应用创建审核（包名与内容的基本审核）、内测版本自身的合规检查（隐私政策、权限说明、版本信息）。
>
> **决策建议**：先用路径 0 在 1–2 天内拿到真机反馈（重点验证登录、方案页、选课页在鸿蒙上的表现），同时并行推进证书申请与 AGC 建应用；待真机无阻塞问题再走路径 1。

---

## 9. 步骤八：每步自查清单（汇总速查）

### 前置条件

- [ ] 联盟账号已注册并实名（个人）
- [ ] AGC 项目已建
- [ ] 本机 `openssl` / `keytool` / `gh` 可用
- [ ] 已决定路径 0 还是路径 1

### 建应用

- [ ] 包名 `edu.zju.compass`（与 `build-hap.yml:64` 一致）
- [ ] 名称「课舟 ClassArk」/「ClassArk」，分类已选
- [ ] 描述含「只读 / 非官方 / 本地优先」，无极限词与「官方」
- [ ] 图标（前景 + 背景 1024²）、截图已备
- [ ] 隐私政策公网 URL 可访问；`docs/隐私政策.md` 占位已替换

### 签名与 CI

- [ ] `.p12`（私钥）+ `.cer` + `.p7b` 齐备，`.p7b` 的 `bundle-name` = `edu.zju.compass`
- [ ] 8 个 Secret 已灌入（建议放 GitHub Environment `release`）
- [ ] `build-hap.yml` 改造已评审：`hap-sign-tool.jar` 路径实测过
- [ ] `-signAlgo` 与密钥类型一致
- [ ] 保留原「回收未签名 HAP」逻辑，未误改 `build-hap.yml:107-117`
- [ ] 5 处 bundleName 校验点全等

### 构建与产物

- [ ] 触发方式正确（手动 / `-f hap=true` / tag）
- [ ] `compass-hap-signed` artifact 已生成
- [ ] 下载物已改名 `compass_signed.hap`（`archive:false` 无扩展名）
- [ ] `unzip -l` 有内容；`module.json` 的 bundleName / version 与预期一致
- [ ] 版本号与 pubspec 对齐，versionCode 递增

### 上传与分发

- [ ] AGC 上传未被包名/签名/版本校验拦下
- [ ] 版本说明取自 `packaging/release-notes-v0.13.11.md`
- [ ] 内测已开启，测试人员名单已记录
- [ ] 崩溃回捞至少落地方案 A（`compass_app/lib/data/diagnostic_log.dart`）

### 合规材料

- [ ] 隐私政策正文 + 公网 URL（Pages 优先）
- [ ] 权限说明逐条对照 `module.json5`，无多余权限
- [ ] AI 第三方与数据出境已如实申报
- [ ] 未成年人说明已备（引 `docs/隐私政策.md` §9）
- [ ] 软著 / APP 备案状态已明确（内测 or 上架）
- [ ] 包名与上架主体已决策

### 时间与风险

- [ ] 关键路径（实名 + 证书）已排期
- [ ] `.p7b` 到期日已记进日程
- [ ] R1/R5/R7 三条高风险项已有专人

---

## 附录 A：命令速查

```bash
# ── 触发构建 ──────────────────────────────────────────────
gh workflow run build-hap.yml  --repo Kepler16f/zju-kezhou --ref main
gh workflow run buildAll.yml   --repo Kepler16f/zju-kezhou --ref main -f hap=true
git tag v0.13.12 && git push origin v0.13.12

# ── 看状态 / 下载 ─────────────────────────────────────────
gh run list --workflow build-hap.yml --limit 5
gh run watch <run_id>
python packaging/check_ci_run.py <run_id> HarmonyOS
gh run download <run_id> -n compass-hap-signed -D dist/ohos/
mv dist/ohos/compass-hap-signed dist/ohos/compass_signed.hap
bash packaging/_dl_artifacts.sh <run_id> kezhou-0.13.12-hap

# ── 生成密钥 ──────────────────────────────────────────────
openssl genrsa -out OpenHarmony.pem 3072
openssl req -new -x509 -key OpenHarmony.pem -out OpenHarmonyApplication.pem \
  -subj "/C=CN/O=KeZhou ClassArk/CN=OpenHarmonyApplication Release" -days 3650
openssl pkcs12 -export -in OpenHarmonyApplication.pem -inkey OpenHarmony.pem \
  -out OpenHarmony.p12 -password pass:'<PWD>' -name "OpenHarmonyApplication Release"

# ── 自检 ─────────────────────────────────────────────────
keytool -list -v -keystore OpenHarmony.p12 -storepass '<PWD>' | head -30
openssl x509 -inform DER -in OpenHarmonyApplication.cer -noout -fingerprint -sha256
base64 -w0 OpenHarmony.p12 > k.b64        # macOS: base64 < f | tr -d '\n'

# ── Secrets ──────────────────────────────────────────────
gh secret set HAP_KEYSTORE_BASE64   --body "$(cat k.b64)"
gh secret set HAP_KEYSTORE_PASSWORD --body '<PWD>'
gh secret list

# ── 产物自检 ──────────────────────────────────────────────
unzip -l dist/ohos/compass_signed.hap | head -20
unzip -p dist/ohos/compass_signed.hap module.json | python -c "
import sys,json;d=json.load(sys.stdin);a=d.get('app',{});v=a.get('version',{})
print(a.get('bundleName'), v.get('code'), v.get('name'))"

# ── 真机 ─────────────────────────────────────────────────
hdc list targets
hdc install -r compass_signed.hap
hdc shell hilog | grep -i edu.zju.compass

# ── 仓库内既有质量门（发布前跑一遍）────────────────────────
python eval/check_readonly.py        # 只读红线：无教务写接口
python eval/cross_engine_parity.py   # 双引擎金标一致
python packaging/prepublic_scan.py   # 已入库文件的敏感信息扫描
```

---

## 附录 B：故障排查表

| 症状 | 根因 | 处置 |
|---|---|---|
| `flutter build hap` 失败但有 `*unsigned*.hap` | 缺签名配置（**当前常态**，`build-hap.yml:115` 已注明） | 正常，走路线 B 补签 |
| CI 找不到 `hap-sign-tool.jar` | SDK 布局与预期不同 | 在 runner 上 `find "$HOME" -name 'hap-sign-tool*.jar'` 实测后写死路径 |
| `keystore password was incorrect` | `HAP_KEYSTORE_PASSWORD` 与 p12 口令不符 | 用 `keytool -list` 本地验证后再灌 Secret |
| `alias does not exist` | `HAP_KEY_ALIAS` 与 p12 内别名不符 | `keytool -list -v` 看真实别名；注意别名含空格时 yml 要加引号 |
| 签名报「算法不匹配」 | `-signAlgo` 与密钥类型不符 | RSA → `SHA256withRSA`；EC → `SHA256withECDSA` |
| AGC 报「包名与应用信息不匹配」 | profile / HAP / AGC 三处 bundleName 不一致 | 按 §4.6 逐处比对 |
| AGC 报「应用签名校验失败」 | `.cer` 不是该应用的发布证书，或 profile 与 `.cer` 不配对 | 比对 §4.2.3 的 SHA-256 指纹；重新申请 |
| AGC 报「版本号与包内信息不一致」 | 表单填的值 ≠ `module.json` 内值 | 用附录 A 的读包命令读真值 |
| AGC 报「缺少隐私政策」/ 链接不可达 | URL 404 / raw 非网页 / 占位邮箱 | 见 §3.3 |
| 设备装不上：`signature verification failed` | profile 过期 / 证书与包不配对 / 包被改过 | 检查 `.p7b` 有效期；重签 |
| 设备装不上：`developer mode not enabled` | 测试机未开开发者模式 | 设置 → 关于手机 → 连点版本号 |
| 桌面图标下显示 `compass_app` | 资源名未改全 | 跑 `python packaging/set_ohos_app_name.py ohos`（`build-hap.yml:66-75` 已自动做，并有防回归检查） |
| 应用图标是模板默认 | 图标未注入 | 确认 `compass_app/assets/brand/ohos/` 六个文件齐全（`build-hap.yml:85-90`） |
| 下载的产物没有 `.hap` 后缀 | `archive: false` 的正常行为 | 手工改名；`packaging/_dl_artifacts.sh` 亦如此 |
| `unzip` 后一堆文件，误当安装包分发 | HAP 本身就是 zip | **HAP 本体就是安装包**，分发的就是那一个 `.hap` 文件 |
| CI 时长/额度告警 | main 每次 push 都触发鸿蒙构建（`build-hap.yml:7-8`） | 用手动触发；或另开 PR 改触发条件 |
| `pub get` 失败 | gitee 限流 | 已有 5 次重试（`build-hap.yml:98-105`）；仍失败则换镜像 |

---

## 附录 C：术语对照

| 术语 | 含义 |
|---|---|
| HAP | HarmonyOS Ability Package，**安装包本体**（zip 容器） |
| AppTest / 应用测试 | 本指南指 AGC 的「应用内测」分发通道（测试人员从 AppGallery 领取） |
| 内测 / 公测 | AGC 的分发类型；内测面向指定测试人员，公测面向公开申请 |
| Profile / `.p7b` | 描述文件，把 bundleName + 证书指纹 + 有效期 + 权限白名单绑定在一起 |
| `.cer` | 应用证书（X.509），由 AGC 签发 |
| `.p12` | PKCS#12 私钥库，含私钥，**永不公开** |
| `bundleName` | 鸿蒙应用包名，本仓库为 `edu.zju.compass` |
| versionCode / versionName | 鸿蒙版本号/版本名，本仓库由 `compass_app/pubspec.yaml:4` 派生 |
| `hap-sign-tool.jar` | 鸿蒙签名工具，随 SDK 落地，本地打包时由 hvigor 调用 |
| `hdc` | 鸿蒙设备调试工具（装包、收日志） |
| AGC | AppGallery Connect，华为的开发者后台（应用、版本、分发、质量） |
| APL | AppGallery Connect 分析服务里的崩溃/性能分析能力（业界也泛指鸿蒙侧崩溃采集） |

---

## 附录 D：本次盘点发现的仓库事实缺口（建议后续单独 PR 处理，本次未改动任何文件）

| # | 缺口 | 建议动作 | 影响 |
|---|---|---|---|
| D1 | `.gitignore` 未忽略 `*.p12` / `*.p7b` / `*.cer` / `*.pem` | 补 4 行规则 | 防止签名材料误入库（R1） |
| D2 | `ohos/` 目录不在 `.gitignore`，但 CI 现场生成 | 加 `compass_app/ohos/`（除非将来决定把它入库） | 防本地生成后误提交整套脚手架 |
| D3 | `docs/隐私政策.md` 未入库（`git status` 显示 `??`） | 提交，并把 §12.2 邮箱占位换成真实邮箱 | 隐私政策 URL 的前提 |
| D4 | 仓库无任何 signing Secret，也无签名相关 workflow 逻辑 | 按 §4.5 提 PR | 签名分发的主干工作 |
| D5 | `build-hap.yml` 无 tag 触发（tag 走 `buildAll.yml`） | 保持现状即可，但文档要写清 | 避免误以为 `build-hap.yml` 能打 tag |
| D6 | 无 release workflow，产物只落 Actions artifacts + 手工 `dist/` | 若要对外分发，考虑加 Release 附件 | 分发体验 |
| D7 | 无崩溃上报通道（只有本地诊断日志） | 上架前接 AGC 崩溃分析 | R11 |
| D8 | 版本号仍是 `0.13.11+25`，与「1.0.0-beta.1」目标差一步 | 用 §5.5 的规则迁移，build number 必须递增 | 上架版本规划 |

---

*本指南基于仓库 `Kepler16f/zju-kezhou`（main 分支，2026-10-21 前后）的实际文件撰写；所有仓库路径与文件名均已核对存在。华为控制台界面以官网当前版本为准。*
