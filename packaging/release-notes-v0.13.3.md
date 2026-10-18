# 课舟 ClassArk v0.13.3

选课分类视图修复（LIVE 实测根因校准版）。

## 修复
- **思政类/军体类/外语类等分类 tab 看不到课程**（用户反馈，LIVE 探针一手定性）：
  教务网对这些 lx=zl 子入口的 dl 查询**服务器侧恒返回空**，但课程都在「全部课程」池里，
  每行带服务器自带的归类字段 `kcgs`（课程归属，多标签用 `\`、`,`，如 `思政类\军体类`）
  与 `rdlb`（认定类别）。本版：
  - 解析层把 `kcgs/rdlb` 拆进每门课的类别标签（多标签如实多枚显示，合并视图同样生效）；
  - 分类视图空 tab 自动从已加载的全量池按类别回退填充（含「（演示）」等注记归一、
    ≥2 字互为包含兜底），并标注来源；池里确实没有的类别保持如实空态。
  - 实测回填规模：军体类 4 门（体育Ⅶ/Ⅷ、军事理论等）、思政类 20、外语类 32、
    美育类 159、心理健康类 64、计算机类 11（沙箱缓存离线复算）。

## 安装包
| 平台 | 文件 |
|---|---|
| Windows arm64 / x64 | KeZhouSetup-0.13.3-win-arm64.exe / -x64.exe |
| Android arm64 / armv7 / x64 | app-arm64-v8a-release.apk 等 |
| iOS（未签名 ipa，显示名 ClassArk） | kezhou-unsigned.ipa |
| macOS arm64 / x64 | KeZhou-macos-*.zip |
| Linux arm64 / x64 | KeZhou-linux-*.tar.gz |
| 鸿蒙 NEXT（未签名 HAP） | compass_unsigned.hap |

质量门：519 项 Flutter 测试全绿；双引擎 parity 逐字段一致；只读红线/金标同步通过。
