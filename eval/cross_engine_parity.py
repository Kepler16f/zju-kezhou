# -*- coding: utf-8 -*-
"""eval/cross_engine_parity.py — 双引擎金标对照：Python audit.py 与 Dart engine 对同一输入
必须产出逐字段完全一致的报告。这是"两套实现、一套真相"的守护测试（CI 必跑）。

用法（仓库根目录）：
  python engine/run_audit.py > /dev/null                      # 确保 Python 引擎可跑
  cd compass_app && flutter test                              # 生成 test/golden_dart_report.json
  python eval/cross_engine_parity.py                          # 逐字段比对
退出码 0=一致；1=漂移（打印差异路径）。
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "engine"))

import audit  # noqa: E402

with open(os.path.join(ROOT, "data", "golden", "computer_science.json"), encoding="utf-8") as fh:
    cs = json.load(fh)
audit.PLAN_JSON = json.dumps({"computer_science": cs}, ensure_ascii=False)

with open(os.path.join(ROOT, "data", "samples", "demo1_cs_full.json"), encoding="utf-8") as fh:
    rec = json.load(fh)
py_report = audit.build(rec, cs)

dart_path = os.path.join(ROOT, "compass_app", "test", "golden_dart_report.json")
if not os.path.exists(dart_path):
    print("先跑: cd compass_app && flutter test（生成 Dart 金标输出）")
    sys.exit(2)
with open(dart_path, encoding="utf-8") as fh:
    dart_report = json.load(fh)


def norm(x):
    """归一化：数值统一 float、字符串去首尾空白。"""
    if isinstance(x, bool):
        return x
    if isinstance(x, (int, float)):
        return round(float(x), 6)
    if isinstance(x, str):
        return x.strip()
    if isinstance(x, list):
        return [norm(i) for i in x]
    if isinstance(x, dict):
        return {k: norm(v) for k, v in x.items()}
    return x


def diff(a, b, path="$"):
    out = []
    na, nb = norm(a), norm(b)
    if isinstance(na, dict) and isinstance(nb, dict):
        for k in sorted(set(na) | set(nb)):
            if k not in na or k not in nb:
                out.append("%s.%s 仅单侧存在" % (path, k))
            else:
                out += diff(na[k], nb[k], "%s.%s" % (path, k))
    elif isinstance(na, list) and isinstance(nb, list):
        if len(na) != len(nb):
            out.append("%s 长度 %d vs %d" % (path, len(na), len(nb)))
        else:
            for i, (x, y) in enumerate(zip(na, nb)):
                out += diff(x, y, "%s[%d]" % (path, i))
    else:
        if na != nb:
            out.append("%s: %r vs %r" % (path, na, nb))
    return out


drift = diff(py_report, dart_report)
if drift:
    print("❌ 双引擎漂移 %d 处：" % len(drift))
    for d in drift[:40]:
        print("  ", d)
    sys.exit(1)
print("✅ 双引擎金标一致：%d 模块 / %d 告警 / totals=%s" % (
    len(py_report["summary"]), len(py_report["warnings"]), py_report["totals"]))

# ── 第二组夹具：并列选项组（三选一）──────────────────────────────────────────
# golden 样例方案没有 alternative_groups，双引擎的「选项行合成为组行、totals
# 只计一次、落选选项缺口警告清除」这段逻辑此前无人比对（2026-10-19 用户 #8
# 复盘中发现的镜像空洞）。Dart 侧输出由 compass_app/test/alt_group_parity_test.dart
# 落盘到 test/golden_dart_report_alt.json，随仓库提交。
with open(os.path.join(ROOT, "data", "golden_alt", "alt_group_demo.json"), encoding="utf-8") as fh:
    alt_plan = json.load(fh)
with open(os.path.join(ROOT, "data", "samples", "demo4_alt_group.json"), encoding="utf-8") as fh:
    alt_rec = json.load(fh)
py_alt = audit.build(alt_rec, alt_plan)
alt_golden_path = os.path.join(ROOT, "compass_app", "test", "golden_dart_report_alt.json")
if not os.path.exists(alt_golden_path):
    print("缺少 test/golden_dart_report_alt.json（先跑: cd compass_app && "
          "dart test test/alt_group_parity_test.dart）")
    sys.exit(2)
with open(alt_golden_path, encoding="utf-8") as fh:
    dart_alt = json.load(fh)
alt_drift = diff(py_alt, dart_alt)
if alt_drift:
    print("❌ 并列选项组双引擎漂移 %d 处：" % len(alt_drift))
    for d in alt_drift[:40]:
        print("  ", d)
    sys.exit(1)
print("✅ 并列选项组一致：%d 行 / %d 告警 / totals=%s" % (
    len(py_alt["summary"]), len(py_alt["warnings"]), py_alt["totals"]))
