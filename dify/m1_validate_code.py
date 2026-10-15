# -*- coding: utf-8 -*-
# M1 抽取校验 Code 节点（Dify「代码执行(Python3)」）
# 输入：extracted(str LLM输出JSON数组)  total_declared(str 模块声明学分,可空)
# 输出：validated(str 合格课程JSON)  rejects(str 不合格行)  report(str 校验摘要)
# 规则与 docs/开发方案.md §4.3 一致；本文件同时用于本地跑评测脚本。
import difflib
import json
import re

VALID_NATURE = {"通识必修", "必修", "限选", "任选", "实践"}
VALID_OFFERED = {"秋", "春"}


def check_course(c):
    """返回问题列表；空列表 = 合格。字段级检查即评测表的'字段准确率'口径。"""
    issues = []
    name = c.get("name")
    if not isinstance(name, str) or not name.strip():
        issues.append("name缺失")
    cr = c.get("credits")
    if cr is None:
        issues.append("credits缺失")
    elif not isinstance(cr, (int, float)) or not (0 < cr <= 20):
        issues.append("credits越界(%s)" % cr)
    elif abs(cr * 2 - round(cr * 2)) > 1e-9:
        issues.append("credits非0.5步长(%s)" % cr)
    if c.get("nature") not in VALID_NATURE:
        issues.append("nature非法(%s)" % c.get("nature"))
    off = c.get("offered")
    if not isinstance(off, list) or not off or not set(off) <= VALID_OFFERED:
        issues.append("offered非法(%s)" % off)
    page = c.get("page")
    if page is not None and (not isinstance(page, int) or page < 1):
        issues.append("page越界(%s)" % page)
    return issues


def resolve_prereq(courses, plan_courses=None):
    """prereq_text -> course_id（difflib≥0.85），失败进 unresolved。
    plan_courses：用于跨块解析（先修课可能在本块之外）；None 表示只做块内解析。"""
    names = [c["name"] for c in courses]
    by_name = {c["name"]: c for c in courses}
    unresolved = []
    for c in courses:
        text = c.pop("prereq_text", "") or ""
        ids = []
        if text.strip() in ("", "无"):
            c["prereq"] = []
            continue
        parts = re.split(r"[、，,;；/]|先修[:：]?\s*", text)
        for p in parts:
            p = p.strip()
            if not p or len(p) < 2:
                continue
            close = difflib.get_close_matches(p, names, 1, 0.85)
            if close:
                ids.append(close[0])
            else:
                unresolved.append({"course": c["name"], "prereq_text": p})
        c["prereq"] = sorted(set(ids))
    return unresolved


def main(extracted="", total_declared="", module_required=""):
    clean = re.sub(r"^```(?:json)?|```$", "", extracted.strip(), flags=re.M).strip()
    try:
        courses = json.loads(clean)
        if isinstance(courses, dict):
            courses = courses.get("courses", [])
    except (ValueError, TypeError):
        return {"validated": "[]", "rejects": "[]",
                "report": "LLM 输出不是合法 JSON，本块重跑或转人工。", "ok": "false"}

    valid, rejects = [], []
    for c in courses:
        if not isinstance(c, dict):
            rejects.append({"row": str(c), "issues": ["非对象行"]})
            continue
        issues = check_course(c)
        if issues:
            rejects.append({"row": c, "issues": issues})
        else:
            c["module_hint"] = c.get("module_hint", "")
            valid.append(c)

    unresolved = resolve_prereq(valid)
    dup = {}
    for c in valid:
        dup[c["name"]] = dup.get(c["name"], 0) + 1
    dups = [k for k, v in dup.items() if v > 1]

    lines = ["块内课程 %d：合格 %d，不合格 %d" % (len(courses), len(valid), len(courses) - len(valid)),
             "先修未解析 %d 条%s" % (len(unresolved),
                                    "（%s）" % "、".join(u["prereq_text"] for u in unresolved[:3]) if unresolved else ""),
             "重名课程 %d 门%s" % (len(dups), "（%s）" % "、".join(dups[:3]) if dups else "")]
    if module_required:
        s = round(sum(c["credits"] for c in valid), 2)
        req = float(module_required)
        lines.append("模块学分求和 %g vs 声明 %g：%s" % (s, req, "✅" if abs(s - req) < 0.01 else "⚠️ 差 %g，回原文核对" % (s - req)))
    report = " ｜ ".join(lines)
    return {"validated": json.dumps(valid, ensure_ascii=False),
            "rejects": json.dumps(rejects, ensure_ascii=False),
            "unresolved": json.dumps(unresolved, ensure_ascii=False),
            "report": report, "ok": "true" if len(valid) >= len(courses) * 0.8 else "false"}
