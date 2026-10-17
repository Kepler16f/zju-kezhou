/// engine/disclaimer.dart — 免责声明的唯一字面量来源（审计报告 / AI 面板 / UI 页脚共用）。
/// 文案被双端测试逐字断言（engine_test.dart 与 Python engine/tests/test_engine.py），
/// 改动即事故；LLM 无权删改（UI 层硬拼接）。
library;

const String kDisclaimer = '本报告仅供与导师沟通参考，正式认定以教务系统为准。';
