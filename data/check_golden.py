# -*- coding: utf-8 -*-
"""data/check_golden.py — golden 数据自检。口径：
   必修池(kind=必修)：required_credits == 该模块课程学分和（全部必修）；
   限选/任选池(kind=限选)：required_credits <= 该模块课程学分和（池内任选达标即可）；
   先修引用存在；total_credits == 各模块 required 之和；module_id 唯一。
用法：python data/check_golden.py"""
import json
import os

D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "golden")

for f in sorted(os.listdir(D)):
    if not f.endswith(".json") or f.startswith("raw_"):
        continue
    p = json.load(open(os.path.join(D, f), encoding="utf-8"))
    issues = []
    ids = {c["course_id"] for c in p["courses"]}
    sums = {}
    for c in p["courses"]:
        sums[c["module_id"]] = round(sums.get(c["module_id"], 0) + c["credits"], 2)
        for pre in c.get("prereq", []):
            if pre not in ids:
                issues.append("先修引用不存在: %s -> %s" % (c["course_id"], pre))
    seen = set()
    for m in p["modules"]:
        mid = m["module_id"]
        if mid in seen:
            issues.append("module_id 重复: %s" % mid)
        seen.add(mid)
        s = sums.get(mid, 0)
        req = m["required_credits"]
        if m.get("kind") == "必修":
            if abs(s - req) > 1e-9:
                issues.append("必修模块 %s: 应修 %s != 课程和 %s" % (mid, req, s))
        else:
            if req > s + 1e-9:
                issues.append("限选池 %s: 应修 %s > 池内总学分 %s" % (mid, req, s))
        m["course_ids"] = [c["course_id"] for c in p["courses"] if c["module_id"] == mid]
    total = round(sum(m["required_credits"] for m in p["modules"]), 2)
    if abs(total - p["meta"]["total_credits"]) > 1e-9:
        issues.append("总学分: 声明 %s != 模块应修和 %s" % (p["meta"]["total_credits"], total))
    for i in issues:
        print("[%s] ❌ %s" % (f, i))
    if not issues:
        print("[%s] ✅ OK 总学分 %s（模块: %s）" % (
            f, total, ", ".join("%s=%s" % (m["module_id"], m["required_credits"]) for m in p["modules"])))

