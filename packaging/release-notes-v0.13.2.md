# 课舟 ClassArk v0.13.2

用户实测反馈修复版。

## 修复
- **审计引擎 v1.4（双镜像 Dart/Python 同步，金标对照一致）**
  - **多重计分**：一门课归属多个模块（多个标签）时，学分按各所属模块分别计入——与教务口径一致；明细标 `multi_tag`，报告口径说明固定新增第三条；已选未获学分（selected_no_credit）同口径双计；同一模块内重修/重复行仍只计一次
  - **毕业总学分以培养方案声明为准**：`totals.plan_total_credits`（meta.total_credits 最低毕业学分）+ `total_basis`（plan_declared / module_sum_fallback）；模块要求之和与方案声明不一致时以声明为准，trace 说明口径
  - **外语类改为自选学分**：设置页选 L1/L2/L3 后出现数字框（默认 6 / 4.5 / 3，可任意改），外语模块要求=你填的分数，**允许超过方案原要求**（多修多得）；审计动作 `foreign_lang_credits` 优先，`foreign_lang_level` 向后兼容
- **方案页认定型课程显示**：成绩单行带类别标注（如 category=美育类）但课名不含关键词（如「民乐演奏」）时，此前在认定板块消失——现按类别兜底纳入，与其他课程同样三态显示
- **AI 公益端点稳定性**：pollinations 限流返回 HTML 判为可重试服务端错误；流式超时未吐字自动降级非流式重试

## 安装包
| 平台 | 文件 |
|---|---|
| Windows arm64 / x64 | KeZhouSetup-0.13.2-win-arm64.exe / -x64.exe |
| Android arm64 / armv7 / x64 | app-arm64-v8a-release.apk 等 |
| iOS（未签名 ipa，显示名 ClassArk） | kezhou-unsigned.ipa |
| macOS arm64 / x64 | KeZhou-macos-*.zip |
| Linux arm64 / x64 | KeZhou-linux-*.tar.gz |
| 鸿蒙 NEXT（未签名 HAP） | compass_unsigned.hap |

质量门：514 项 Flutter 测试全绿；双引擎 parity 逐字段一致；只读红线/金标同步通过。
