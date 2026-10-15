# -*- coding: utf-8 -*-
"""engine/run_audit.py — 本地全链路 CLI（备份演示路线 + 开发调试入口）。
用法：
  python engine/run_audit.py                       # 跑全部演示样例，输出 Markdown 报告
  python engine/run_audit.py data/samples/demo1_cs_full.json
  python engine/run_audit.py --paste data/samples/demo1_cs_paste.txt '{"alias":"演示同学01","major":"computer_science","grade":"2023","current_semester":"2026-A"}'
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ROOT = os.path.dirname(HERE)

import audit  # noqa: E402
import adapters  # noqa: E402

COLOR_MARK = {"green": "🟢", "yellow": "🟡", "red": "🔴"}


def load_golden_into_engine():
    d = os.path.join(ROOT, "data", "golden")
    plans = {}
    for f in sorted(os.listdir(d)):
        if f.endswith(".json"):
            p = json.load(open(os.path.join(d, f), encoding="utf-8"))
            plans[p["meta"]["major"]] = p
    audit.PLAN_JSON = json.dumps(plans, ensure_ascii=False)


def render_md(report):
    L = ["# 学业达成度审计报告", ""]
    t = report["totals"]
    L.append("**总览**：应修 %g ｜ 已修 %g ｜ 缺口 %g" % (t["required"], t["earned"], t["gap"]))
    L.append("")
    L.append("## 三色学分达成度")
    L.append("")
    L.append("| 模块 | 应修 | 已修 | 缺口 | 未来可选 | 状态 |")
    L.append("|---|---|---|---|---|---|")
    for m in report["summary"]:
        L.append("| %s | %g | %g | %g | %g | %s %s |" % (
            m["module_path"], m["required"], m["earned"], m["gap"],
            m["remaining_future"], COLOR_MARK[m["color"]], m["status"].split(" ", 1)[-1]))
    if report["warnings"]:
        L.append("")
        L.append("## 风险提示（看不见的坑）")
        L.append("")
        for w in report["warnings"]:
            mark = "🔴" if w["level"] == "red" else ("🟡" if w["level"] == "yellow" else "ℹ️")
            refs = "（出处：%s）" % "、".join(w["refs"]) if w["refs"] else ""
            L.append("- %s %s%s" % (mark, w["text"], refs))
    if report["summary"]:
        closed = [(m, c) for m in report["summary"] for c in m["missing_courses"] if c.get("closed")]
        if closed:
            L.append("")
            L.append("## 已关闭学分开课窗口（尽快与教务确认）")
            for m, c in closed:
                L.append("- 🔴 %s｜《%s》%g分 ｜方案P%s" % (m["module_path"], c["name"], c["credits"], c["page"]))
    L.append("")
    L.append("---")
    L.append("*%s ｜ %s ｜ %s*" % (report["disclaimer"], report["trace"]["plan"],
                                    "计算引擎 " + report["trace"]["engine"]))
    return "\n".join(L)


def run_record(rec):
    out = audit.main(json.dumps(rec, ensure_ascii=False))
    if "error" in out:
        print("ERROR:", out["error"])
        return None
    return out["report"]


def main():
    load_golden_into_engine()
    if len(sys.argv) > 1 and sys.argv[1] == "--paste":
        text = open(sys.argv[2], encoding="utf-8").read()
        student = json.loads(sys.argv[3])
        res = adapters.main(record_text=text, student_json=json.dumps(student))
        if "error" in res:
            print(res["error"])
            return
        rec = json.loads(res["record_json"])
        report = run_record(rec)
        if report:
            print(render_md(report))
        return
    files = sys.argv[1:] or [os.path.join(ROOT, "data", "samples", n)
                             for n in ("demo1_cs_full.json", "demo2_se_export.csv")]
    for fp in files:
        print("\n" + "=" * 72)
        print("样例：", os.path.basename(fp))
        print("=" * 72 + "\n")
        if fp.endswith(".csv"):
            with open(fp, encoding="utf-8") as fh:
                res = adapters.main(csv_rows=fh.read(), student_json=json.dumps(
                    {"alias": "演示同学02", "major": "software_engineering",
                     "grade": "2023", "current_semester": "2026-A"}))
            if "error" in res:
                print(res["error"])
                continue
            rec = json.loads(res["record_json"])
            rec["planned_courses"] = json.load(
                open(os.path.join(ROOT, "data", "samples", "demo3_se_full.json"),
                     encoding="utf-8")).get("planned_courses", [])
        else:
            with open(fp, encoding="utf-8") as fh:
                rec = json.load(fh)
        report = run_record(rec)
        if report:
            print(render_md(report))


if __name__ == "__main__":
    main()
