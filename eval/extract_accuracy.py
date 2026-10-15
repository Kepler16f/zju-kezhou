# -*- coding: utf-8 -*-
"""eval/extract_accuracy.py — M1 抽取字段准确率评测（指标①，目标≥95%）。
用法：python eval/extract_accuracy.py
比对：data/golden/<major>.json（人工订正终稿=标准答案） vs data/golden/raw_<major>.json
     （M1 workflow 未订正的原始输出；文件名以 raw_ 前缀存放于同一目录）
输出：总体与分字段准确率、nature 混淆矩阵、失败清单 eval/accuracy_report.md
口径：credits 精确相等；name 相等或相似度≥0.95；offered/nature 集合精确；prereq 集合精确；page 相等。
随机抽样 100 字段（不足取全量），抽样种子固定 20261013（可复现）。
"""
import difflib
import json
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GD = os.path.join(ROOT, "data", "golden")
FIELDS = ["name", "credits", "nature", "offered", "prereq", "page"]


def field_eq(field, a, b):
    if field == "name":
        if a == b:
            return True
        return difflib.SequenceMatcher(None, str(a), str(b)).ratio() >= 0.95
    if field == "credits":
        try:
            return abs(float(a) - float(b)) < 1e-9
        except (TypeError, ValueError):
            return False
    if field in ("offered", "prereq"):
        na = sorted(set(a if isinstance(a, list) else []))
        nb = sorted(set(b if isinstance(b, list) else []))
        return na == nb
    if field == "nature":
        return a == b
    if field == "page":
        return str(a) == str(b)
    return a == b


def run(major):
    gp = os.path.join(GD, "%s.json" % major)
    rp = os.path.join(GD, "raw_%s.json" % major)
    if not os.path.exists(rp):
        return None  # 原始输出尚未产生（M1 还没跑），跳过
    gold = json.load(open(gp, encoding="utf-8"))
    raw = json.load(open(rp, encoding="utf-8"))
    raw_courses = raw["courses"] if isinstance(raw, dict) else raw
    raw_by_name = {}
    for c in raw_courses:
        raw_by_name.setdefault(c.get("name", ""), c)
    results, nature_conf = [], {}
    samples = []
    rng = random.Random(20261013)
    for g in gold["courses"]:
        r = raw_by_name.get(g["name"])
        if r is None:
            cand = difflib.get_close_matches(g["name"], list(raw_by_name), 1, 0.85)
            r = raw_by_name[cand[0]] if cand else None
        gpage = (g.get("source") or {}).get("page")
        for f in FIELDS:
            gv = gpage if f == "page" else g.get(f)
            if r is None:
                rv = None
            else:
                rv = (r.get("source") or {}).get("page") if f == "page" else r.get(f)
            samples.append((g["name"], f, gv, rv, r is not None))
    if len(samples) > 100:
        samples = rng.sample(samples, 100)
    ok = 0
    fails = []
    by_field = {}
    for name, f, gv, rv, matched_row in samples:
        passed = matched_row and field_eq(f, gv, rv)
        ok += passed
        by_field.setdefault(f, [0, 0])
        by_field[f][1] += 1
        by_field[f][0] += passed
        if not passed:
            fails.append((name, f, gv, rv))
        if f == "nature" and matched_row:
            key = (str(rv), str(gv))
            nature_conf[key] = nature_conf.get(key, 0) + 1
    return {"total": len(samples), "ok": ok, "acc": ok / len(samples) if samples else 0,
            "by_field": by_field, "fails": fails, "nature_conf": nature_conf}


def main():
    lines = ["# M1 抽取准确率评测表", "",
             "抽样种子 20261013（可复现）；口径见脚本头注释。", ""]
    grand = [0, 0]
    for major in ("computer_science", "software_engineering"):
        res = run(major)
        lines.append("## %s" % major)
        if res is None:
            lines.append("（等待 M1 workflow 原始输出 raw_%s.json）\n" % major)
            continue
        grand[0] += res["ok"]
        grand[1] += res["total"]
        lines.append("字段准确率 **%.1f%%**（%d/%d）" % (res["acc"] * 100, res["ok"], res["total"]))
        lines.append("")
        lines.append("| 字段 | 准确/样本 | 准确率 |")
        lines.append("|---|---|---|")
        for f in FIELDS:
            o, t = res["by_field"].get(f, [0, 0])
            lines.append("| %s | %d/%d | %.1f%% |" % (f, o, t, 100 * o / t if t else 0))
        lines.append("")
        if res["nature_conf"]:
            lines.append("### nature 混淆（抽取值 → 标准值）")
            lines.append("")
            lines.append("| 抽取 | 标准 | 次数 |")
            lines.append("|---|---|---|")
            for (r, g), n in sorted(res["nature_conf"].items(), key=lambda x: -x[1])[:15]:
                flag = "✅" if r == g else "❌"
                lines.append("| %s | %s | %d %s |" % (r, g, n, flag))
            lines.append("")
        if res["fails"]:
            lines.append("### 失败清单（进人工订正队列）")
            lines.append("")
            for name, f, gv, rv in res["fails"][:20]:
                lines.append("- %s / %s：抽取=`%s` 标准=`%s`" % (name, f, rv, gv))
            lines.append("")
    if grand[1]:
        lines.append("## 总计：%.1f%%（%d/%d）｜目标≥95%%：%s" % (
            100 * grand[0] / grand[1], grand[0], grand[1],
            "✅ 达标" if grand[0] / grand[1] >= 0.95 else "❌ 未达标"))
    out = os.path.join(HERE, "accuracy_report.md")
    open(out, "w", encoding="utf-8").write("\n".join(lines))
    print("\n".join(lines))
    print("\nwritten:", out)


if __name__ == "__main__":
    main()
