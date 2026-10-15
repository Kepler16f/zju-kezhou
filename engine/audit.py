# -*- coding: utf-8 -*-
"""engine.audit — M2 学业进度审计规则引擎（确定性计算，无 LLM、无第三方库）。
入口：main(record_json) -> {"report": ..., "report_json": ...}
Dify Code 节点用法：PLAN_JSON 常量由 engine/build_embed.py 注入，本文件其余逻辑原样粘贴。
依赖：common.py（时间轴与冲突检测）。时间轴约定见 common.py 顶部说明。
"""
import difflib
import json

import common
from common import PASS_GRADE, SEMESTERS_PER_GRADE_YEAR, sem_idx, sem_str, idx_str

ENGINE_VERSION = "1.1"
GRADUATION_YEARS = 6  # 最长学籍年限（年），自入学学年起算
PLAN_JSON = r'''{}'''  # build_embed.py 替换为 {"computer_science": {...}, "software_engineering": {...}}


def find_plan(major):
    """golden 方案数据只从 PLAN_JSON 常量读取（单文件设计）。
    本地/单测用法：audit.PLAN_JSON = json.dumps(loaded)；Dify 用法：build_embed.py 已注入。"""
    try:
        plans = json.loads(PLAN_JSON)
    except (TypeError, ValueError):
        plans = {}
    if not plans:
        raise ValueError("PLAN_JSON 未注入 golden 数据")
    if major not in plans:
        raise ValueError("方案数据中无该专业：%s（支持：%s）" % (major, "、".join(sorted(plans))))
    return plans[major]


def _is_passed(r):
    """通过判定口径：显式 passed 优先，否则 grade>=60；两者皆无视为未通过。"""
    if r.get("passed") is not None:
        return bool(r["passed"])
    g = r.get("grade")
    return g is not None and g >= PASS_GRADE


def match(record, plan):
    """已修记录 ↔ 方案课程：course_id 精确优先，名称相似度≥0.85 兜底。
    匹配失败的课程单独列示，不抵扣任何模块学分（防止"超修任意课"蒙混过关）。"""
    by_id = {c["course_id"]: c for c in plan["courses"]}
    names = [c["name"] for c in plan["courses"]]
    name_to_course = {c["name"]: c for c in plan["courses"]}
    matched, unmatched = [], []
    for r in record["courses"]:
        course = None
        cid = r.get("course_id")
        if cid and cid in by_id:
            course = by_id[cid]
        else:
            close = difflib.get_close_matches(r["name"], names, 1, 0.85)
            if close:
                course = name_to_course[close[0]]
        if course is None:
            unmatched.append(r)
        else:
            matched.append((r, course))
    return matched, unmatched


def aggregate(matched, plan):
    """按模块汇总已通过学分。"""
    earned = {m["module_id"]: 0.0 for m in plan["modules"]}
    for r, c in matched:
        if _is_passed(r):
            earned[c["module_id"]] += c["credits"]
    return earned


def build(record, plan):
    matched, unmatched = match(record, plan)
    earned = aggregate(matched, plan)
    by_id = {c["course_id"]: c for c in plan["courses"]}
    taken_ids = {c["course_id"] for _, c in matched}
    passed_ids = {c["course_id"] for r, c in matched if _is_passed(r)}

    cur_idx = sem_idx(record["student"]["current_semester"])
    grade_year = int(record["student"]["grade"])
    grad_idx = grade_year * SEMESTERS_PER_GRADE_YEAR + GRADUATION_YEARS * SEMESTERS_PER_GRADE_YEAR - 1
    horizon = GRADUATION_YEARS + 1  # 学年窗口：grade_year .. grade_year+6（含毕业年 2028）

    def future_idx(c):
        """课程在当前学期之后、学籍年限之内的开课学期索引。"""
        return [i for i in common.course_open_idx(c, grade_year, horizon)
                if cur_idx < i <= grad_idx]

    summary, warnings = [], []
    for m in plan["modules"]:
        req = m["required_credits"]
        got = round(earned[m["module_id"]], 2)
        gap = round(max(0.0, req - got), 2)
        # 剩余可选 = 未通过该模块全部课程（含"已修未过待重修"，它们仍可补学分）
        remaining = [c for c in plan["courses"]
                     if c["module_id"] == m["module_id"] and c["course_id"] not in passed_ids]
        open_before_grad = round(sum(c["credits"] for c in remaining if future_idx(c)), 2)
        color = "green" if gap <= 1e-9 else ("yellow" if gap <= open_before_grad + 1e-9 else "red")
        status = {"green": "🟢 已达成", "yellow": "🟡 待补",
                  "red": "🔴 学籍年限内无法补足"}[color]
        missing = []
        if gap > 0:
            for c in sorted(remaining, key=lambda x: -x["credits"]):
                fi = future_idx(c)
                missing.append({"course_id": c["course_id"], "name": c["name"],
                                "credits": c["credits"], "offered": c["offered"],
                                "offered_years": c.get("offered_years"),
                                "terms": [idx_str(i) for i in fi], "closed": not fi,
                                "page": (c.get("source") or {}).get("page")})
        summary.append({"module_id": m["module_id"], "module_path": m["module_path"],
                        "required": req, "earned": got, "gap": gap,
                        "remaining_future": open_before_grad,
                        "color": color, "status": status, "missing_courses": missing})

        if color == "red" and gap > 0:
            closed_courses = [c for c in remaining if not future_idx(c)]
            open_courses = [c for c in remaining if future_idx(c)]
            closed_credit = round(sum(c["credits"] for c in closed_courses), 2)
            detail = "、".join("《%s》%g分" % (c["name"], c["credits"]) for c in closed_courses[:3])
            if closed_courses and closed_credit >= gap:
                cause = "方案内该模块剩余课程在学籍年限内已无开课窗口：%s" % detail
            else:
                cause = "即使重修补上（可补 %g 分），缺口 %g 分仍超出未来可选学分" % (
                    round(sum(c["credits"] for c in open_courses), 2), gap)
            warnings.append({"type": "graduation_risk", "level": "red",
                             "text": "「%s」缺口 %g 分，%s。存在延毕风险，请尽快与教务确认替代方案。"
                                      % (m["module_path"], gap, cause),
                             "refs": ["%s@p%s" % (c["course_id"], (c.get("source") or {}).get("page"))
                                      for c in closed_courses[:3]]})
        elif color == "yellow" and gap > 0:
            tight = [c for c in remaining if future_idx(c)
                     and (c.get("offered_years") or len(c["offered"]) == 1)]
            tight.sort(key=lambda c: (len(future_idx(c)), -c["credits"]))
            for c in tight[:2]:
                cyc = c.get("offered_years")
                why = "（隔年开课，仅 %s 学年）" % "、".join(str(y) for y in cyc) if cyc \
                    else "（仅%s开课）" % c["offered"][0]
                taken_failed = c["course_id"] in {cc["course_id"] for rr, cc in matched if not _is_passed(rr)}
                verb = "已修未过需重修" if taken_failed else "尚未修"
                warnings.append({"type": "offering_closed", "level": "yellow",
                                 "text": "「%s」%g分%s，%s，可选窗口：%s；错过需等待。"
                                          % (c["name"], c["credits"], verb, why,
                                             "、".join(idx_str(i) for i in future_idx(c))),
                                 "refs": ["%s@p%s" % (c["course_id"], (c.get("source") or {}).get("page"))]})

    # 先修检查（已修侧）：已通过课程的先修必须也在通过集合中
    for r, c in matched:
        if not _is_passed(r):
            continue
        for p in c.get("prereq", []):
            if p in passed_ids:
                continue
            pc = by_id.get(p)
            if pc is None:
                continue
            warnings.append({"type": "prereq_gap", "level": "red",
                             "text": "「%s」已通过，但其先修「%s」在记录中未通过（或缺失），选课资格存疑，请与教务核实。"
                                      % (c["name"], pc["name"]),
                             "refs": ["%s@p%s" % (c["course_id"], (c.get("source") or {}).get("page")),
                                      "%s@p%s" % (pc["course_id"], (pc.get("source") or {}).get("page"))]})

    # 计划选课表内部：开课学期匹配 + 先修顺序 + 时间冲突
    plan_courses = record.get("planned_courses") or []
    sem_of_plan = {}
    for x in plan_courses:
        cid = x.get("course_id")
        if not cid:
            continue
        sem_of_plan.setdefault(cid, []).append(
            sem_idx(x.get("semester", record["student"]["current_semester"])))
    for x in plan_courses:
        c = by_id.get(x.get("course_id"))
        if not c:
            continue
        xi = sem_of_plan[c["course_id"]][0]
        term = "秋" if xi % 2 == 0 else "春"
        if term not in c["offered"]:
            warnings.append({"type": "offering_closed", "level": "yellow",
                             "text": "计划选课「%s」排在 %s，但培养方案标注仅%s开课，需调整学期。"
                                      % (c["name"], idx_str(xi), "/".join(c["offered"])),
                             "refs": ["%s@p%s" % (c["course_id"], (c.get("source") or {}).get("page"))]})
        elif c.get("offered_years") and xi // 2 not in c["offered_years"]:
            warnings.append({"type": "offering_closed", "level": "yellow",
                             "text": "计划选课「%s」排在 %s，但该课隔年开课（仅 %s 学年），本学期不开，需等到对应学年。"
                                      % (c["name"], idx_str(xi), "、".join(str(y) for y in c["offered_years"])),
                             "refs": ["%s@p%s" % (c["course_id"], (c.get("source") or {}).get("page"))]})
        for p in c.get("prereq", []):
            if p in passed_ids:
                continue
            pk = sem_of_plan.get(p)
            pc = by_id.get(p)
            if pk and min(pk) >= xi and pc:
                warnings.append({"type": "prereq_same_semester", "level": "red",
                                 "text": "计划选课「%s」需先修「%s」，但先修排在同一学期或更晚（%s vs %s），会选不上，需拆开两学期。"
                                          % (c["name"], pc["name"], idx_str(min(pk)), idx_str(xi)),
                                 "refs": ["%s@p%s" % (c["course_id"], (c.get("source") or {}).get("page")),
                                          "%s@p%s" % (pc["course_id"], (pc.get("source") or {}).get("page"))]})
    for semester in sorted({x.get("semester") for x in plan_courses if x.get("semester")}):
        group = [x for x in plan_courses if x.get("semester") == semester]
        for cf in common.check_plan(group):
            warnings.append({"type": "time_conflict", "level": "red",
                             "text": "%s 计划课表冲突：%s 与 %s %s。" % (semester, cf["a"], cf["b"], cf["detail"]),
                             "refs": []})

    # 未通过课程重修提醒
    for r in record["courses"]:
        if r.get("grade") is not None and not _is_passed(r):
            warnings.append({"type": "failed_recheck", "level": "yellow",
                             "text": "《%s》成绩 %g 未通过，需重修或补考，该课程学分未计入。"
                                      % (r["name"], r["grade"]),
                             "refs": []})
    if unmatched:
        warnings.append({"type": "unmatched_courses", "level": "info",
                         "text": "以下 %d 门课程未在培养方案中匹配到，未计入模块学分（多为超修任选或名称差异过大，请人工核对）：%s。"
                                 % (len(unmatched), "、".join(u["name"] for u in unmatched[:5])),
                         "refs": []})

    totals = {"required": round(sum(m["required"] for m in summary), 2),
              "earned": round(sum(m["earned"] for m in summary), 2),
              "gap": round(sum(m["gap"] for m in summary), 2)}
    return {"summary": summary, "warnings": warnings,
            "extra_courses": unmatched, "totals": totals,
            "disclaimer": "本报告仅供与导师沟通参考，正式认定以教务系统为准。",
            "trace": {"plan": "%s%s（核验日 %s）" % (
                plan["meta"]["source_doc"],
                "" if not str(plan["meta"].get("grade", "")).strip() else " %s级" % plan["meta"]["grade"],
                plan["meta"].get("verified_at", "-")),
                "engine": "v%s" % ENGINE_VERSION}}


def main(record_json="", action="audit"):
    rec = json.loads(record_json) if isinstance(record_json, str) else record_json
    if action != "audit":
        return {"error": "unknown action: %s" % action}
    try:
        plan = find_plan(rec["student"]["major"])
    except ValueError as e:
        return {"error": str(e)}
    report = build(rec, plan)
    return {"report": report, "report_json": json.dumps(report, ensure_ascii=False)}
