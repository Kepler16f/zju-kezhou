# -*- coding: utf-8 -*-
"""engine.audit — 学业进度审计规则引擎（确定性计算，无 LLM、无第三方库）。
入口：main(record_json) -> {"report": ..., "report_json": ...}
本文件是 Dart engine/audit.dart 的镜像实现，两者由 eval/cross_engine_parity.py
逐字段比对钉死一致（CI 金标门）。依赖：common.py（时间轴与冲突检测）。

口径（v1.3，2026-10-18 用户实测「积分重复计算」修复；与 Dart engine/audit.dart 逐逻辑对齐）：
 * 选课组：模块内「四选一 / 选 N 门 / 至少修读 N 门」类组按「至少 N 门」折算要求
   学分，不再按组内全部课程求和（仅当要求学分 == 组内全部课程学分和的全量和指纹，
   或门数口径模块时折算；只降不升，标注正确的模块一律不动）；
 * 外语等级：action 支持 {'foreign_lang_level': 'L1'|'L2'|'L3'}，外语类模块要求
   学分按等级封顶（L1=6 / L2=4.5 / L3=3）；等级缺省不假设，trace 注明；
 * 已选 vs 已获：每模块输出 selected_no_credit（已选未获学分课程数），与 earned
   （已获学分）分开呈现；报告顶层附 caliber_notes 口径说明。
"""
import difflib
import json
import re

import common
from common import PASS_GRADE, SEMESTERS_PER_GRADE_YEAR, sem_idx, sem_str, idx_str

ENGINE_VERSION = "1.3"
GRADUATION_YEARS = 6  # 最长学籍年限（年），自入学学年起算
PLAN_JSON = r'''{}'''  # golden 方案注入：{"computer_science": {...}, "software_engineering": {...}}

# ── 选课组与外语等级口径（纯函数，独立可测；与 Dart engine/audit.dart 同一规则）──

# 外语等级 → 外语类模块「要求学分」封顶值（用户 2026-10-18 明确口径：
# L1 计 6 分、L2 计 4.5 分、L3 计 3 分；按等级封顶，绝不抬高方案原要求）。
FOREIGN_LANG_CAPS = {"L1": 6.0, "L2": 4.5, "L3": 3.0}

# 报告口径说明（顶层 caliber_notes 的固定两条，字面量被测试逐字断言；
# UI 据此对 earned / selected_no_credit 用不同颜色注释）。
K_CALIBER_EARNED_NOTE = (
    "earned=已获学分：仅统计已通过且计入学分的课程，同一门课重修/补考只计一次；"
    "弃修/待录/缓考/无效不计入。")
K_CALIBER_SELECTED_NOTE = (
    "selected_no_credit=已选未获学分：本模块内已修未通过（含在修未出分、"
    "弃修/待录/缓考/无效）或已列入计划选课、尚未取得学分的课程门数"
    "（按方案课程去重），与 earned 分开呈现，请勿相加当作总进度。")

_CN_NUM = r"[0-9]+|[一二两三四五六七八九十]+"
_CN_DIGITS = {"一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
              "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10}


def _parse_cn_count(raw):
    t = raw.strip()
    if not t:
        return None
    try:
        return int(t)
    except ValueError:
        return _CN_DIGITS.get(t)


def _count_rule_from_text(text):
    """模块标识文本（module_path/title）→ 组内至少门数；无显式门数信号返回 None。
    支持「N 选 M」（N>M≥1，取 M）、「选 N 门」「至少（修读）N 门」；
    中文数字与阿拉伯数字皆可。刻意**不扫 notes**：说明文本里的门数常是只约束
    组内一部分课程的子规则（如「其中大学写作至少修读1门」），套到整模块会
    错杀真实总要求（宁缺勿猜）。"""
    m = re.search("(" + _CN_NUM + r")\s*选\s*(" + _CN_NUM + ")", text)
    if m:
        n = _parse_cn_count(m.group(1))
        k = _parse_cn_count(m.group(2))
        if n is not None and k is not None and n > k and k > 0:
            return k
    m = re.search("(?:至少\\s*(?:修读|修)?\\s*|选\\s*)(" + _CN_NUM + r")\s*门", text)
    if m:
        x = _parse_cn_count(m.group(1))
        if x is not None and x > 0:
            return x
    return None


def detect_module_group_rule(m):
    """识别模块的选课组规则（dict：min_courses/min_credits/source）；
    识别不了返回 None（按普通学分模块核算，宁缺勿猜）。
    识别优先级：
     1. 显式结构字段 `n_select`（组内任选 N 门）；
     2. 显式结构字段 `group`（{min_courses, min_credits} 任一非空）；
     3. `choice_rule`（适配层从板块说明识别的约束）；
     4. 模块标识文本（module_path + title）里的「N 选 M / 选 N 门 / 至少 N 门」。"""
    ns = m.get("n_select")
    if isinstance(ns, (int, float)) and ns >= 1:
        return {"min_courses": int(round(ns)), "min_credits": None, "source": "n_select"}
    for key in ("group", "choice_rule"):
        g = m.get(key)
        if not isinstance(g, dict):
            continue
        mc_raw = g.get("min_courses")
        mc = int(round(mc_raw)) if isinstance(mc_raw, (int, float)) and mc_raw >= 1 else None
        mcx = g.get("min_credits")
        mcx = float(mcx) if isinstance(mcx, (int, float)) and mcx else None
        if mc is not None or mcx is not None:
            return {"min_courses": mc, "min_credits": mcx, "source": key}
    id_text = "%s %s" % (m.get("module_path") or "", m.get("title") or "")
    from_text = _count_rule_from_text(id_text)
    if from_text is not None:
        return {"min_courses": from_text, "min_credits": None, "source": "title"}
    return None


def is_foreign_lang_module(m):
    """外语类模块判据：module_path/title/category 命中「外语」或「英语」
    （覆盖「外语类」「大学英语」等常见板块名；宁缺勿猜，不扫 notes/课程名）。"""
    t = "%s %s %s" % (m.get("module_path") or "", m.get("title") or "", m.get("category") or "")
    return "外语" in t or "英语" in t


def _r2(v):
    return round(float(v), 2)


def effective_required_credits(m, module_courses, rule=None):
    """模块「有效要求学分」：修正两类「积分重复计算」（纯函数，宁缺勿猜、只降不升）：
     * 门数口径模块（count_rule / plan_credits_unit='门'）：required_credits 里的
       数字是要求**门数**不是学分 → 按 N 门最便宜课程折算；折算不出（无课程/无
       门数信号）时归 0，绝不把门数当学分（0 保持 0）；
     * 学分口径模块：仅当「要求学分 == 组内全部课程学分和」（选课组被全量和的
       指纹）且存在含门数下限的组规则时，改按「N 门最便宜课程学分和」（有显式
       min_credits 时取二者较大值）折算——方案标注正确（要求 < 全组和）的模块
       一律不动。"""
    if rule is None:
        rule = detect_module_group_rule(m)
    req0 = float(m.get("required_credits") or 0)
    # 组内课程去重（同一课程多标签/重复行只计一次学分），学分升序
    seen = set()
    credits = []
    for c in module_courses:
        cid = str(c.get("course_id") or c.get("name") or "")
        if cid in seen:
            continue
        seen.add(cid)
        v = c.get("credits")
        if isinstance(v, (int, float)) and v > 0:
            credits.append(float(v))
    credits.sort()
    full_sum = sum(credits)

    def cheapest_sum(n):
        if n is None or n < 1 or not credits:
            return None
        return sum(credits[:n if n <= len(credits) else len(credits)])

    is_count = m.get("count_rule") is True or str(m.get("plan_credits_unit") or "").strip() == "门"
    if is_count:
        n = (rule or {}).get("min_courses")
        if n is None and req0 >= 1:
            n = int(round(req0))
        by_credits = (rule or {}).get("min_credits") or cheapest_sum(n or 0)
        if by_credits is not None and by_credits > 0:
            return _r2(by_credits)
        return req0 if req0 <= 0 else 0.0  # 门数折算不出时归 0，绝不把门数当学分
    if (rule is not None and rule.get("min_courses") is not None
            and rule["min_courses"] >= 1 and req0 > 0 and full_sum > 0
            and abs(req0 - full_sum) <= 1e-6):
        candidate = cheapest_sum(rule["min_courses"])
        mc = rule.get("min_credits")
        if mc is not None and mc > 0 and (candidate is None or mc > candidate):
            candidate = mc
        if candidate is not None and candidate < req0 - 1e-9:
            return _r2(candidate)
    return req0


def find_plan(major):
    """golden 方案数据只从 PLAN_JSON 常量读取（单文件设计）。
    本地/单测用法：audit.PLAN_JSON = json.dumps(loaded)（见 run_audit.py 与 tests）。"""
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
    """按模块汇总已通过学分（v1.3 起一并产出口径集合，与 Dart aggregate 同语义）。
    同一门方案课程多条成绩单记录（重修/补考）只计一次学分；
    credit_included=False（弃修/待录/缓考/无效）不计入已取得学分，但仍视为已通过，
    避免重复出现在待修列表。返回 (earned, passed_ids, earned_cids,
    selected_no_credit_ids)：passed_ids=通过去重（含不计学分的）；earned_cids=
    实际获得学分；selected_no_credit_ids=已选未取得学分的方案课程。"""
    earned = {m["module_id"]: 0.0 for m in plan["modules"]}
    passed_ids = set()
    earned_cids = set()
    selected_no_credit_ids = set()
    for r, c in matched:
        cid = c["course_id"]
        passed = _is_passed(r)
        credited = passed and r.get("credit_included") is not False
        if not credited:
            # 在修未出分 / 已修未过 / 弃修待录缓考无效：已选但未获学分
            selected_no_credit_ids.add(str(cid))
        if passed and cid not in passed_ids:
            passed_ids.add(cid)
            if credited:
                earned[c["module_id"]] += c["credits"]
                earned_cids.add(str(cid))
    return earned, passed_ids, earned_cids, selected_no_credit_ids


def build(record, plan, action=None):
    # action 参数校验（宁缺勿猜：非法外语等级显式报错，不静默忽略；未知键忽略）
    foreign_level_raw = (action or {}).get("foreign_lang_level")
    if foreign_level_raw is not None and str(foreign_level_raw) not in FOREIGN_LANG_CAPS:
        raise ValueError("未知的外语等级：%s（支持 L1/L2/L3）" % foreign_level_raw)
    foreign_cap = None if foreign_level_raw is None else FOREIGN_LANG_CAPS[str(foreign_level_raw)]

    matched, unmatched = match(record, plan)
    earned, passed_ids, earned_cids, selected_no_credit_ids = aggregate(matched, plan)
    plan_has_foreign = any(is_foreign_lang_module(m) for m in plan["modules"])
    by_id = {c["course_id"]: c for c in plan["courses"]}
    # 方案课程 id -> 首条匹配到的成绩单记录（无论是否通过），供 plan_courses 明细回显
    matched_record_by_plan_id = {}
    for r, c in matched:
        matched_record_by_plan_id.setdefault(c["course_id"], r)
    # 计划选课（已选未出分）：计入选课组口径的"已选未获学分"
    plan_courses = record.get("planned_courses") or []
    for x in plan_courses:
        cid = x.get("course_id")
        if cid is not None:
            selected_no_credit_ids.add(str(cid))
    # 模块课程一次取齐（保持 plan["courses"] 原序）：剩余/明细/组口径共用
    courses_by_module = {}
    for c in plan["courses"]:
        courses_by_module.setdefault(str(c["module_id"]), []).append(c)

    cur_idx = sem_idx(record["student"]["current_semester"])
    grade_year = int(record["student"]["grade"])
    grad_idx = grade_year * SEMESTERS_PER_GRADE_YEAR + GRADUATION_YEARS * SEMESTERS_PER_GRADE_YEAR - 1
    horizon = GRADUATION_YEARS + 1  # 学年窗口：grade_year .. grade_year+6（含毕业年 2028）

    def future_idx(c):
        """课程在当前学期之后、学籍年限之内的开课学期索引。"""
        return [i for i in common.course_open_idx(c, grade_year, horizon)
                if cur_idx < i <= grad_idx]

    summary, warnings = [], []
    group_applied = False  # 是否有模块的组口径折算实际生效（供 caliber_notes）
    for m in plan["modules"]:
        module_courses = courses_by_module.get(str(m["module_id"]), [])
        group_rule = detect_module_group_rule(m)
        req0 = float(m["required_credits"])
        req = effective_required_credits(m, module_courses, rule=group_rule)
        if abs(req - req0) > 1e-9:
            group_applied = True
        # 外语等级封顶：仅外语类模块，且只降不升（等级缺省 → 方案原要求）
        if foreign_cap is not None and is_foreign_lang_module(m) and foreign_cap < req:
            req = foreign_cap
        got = round(earned[m["module_id"]], 2)
        gap = round(max(0.0, req - got), 2)
        # 剩余可选 = 未通过该模块全部课程（含"已修未过待重修"，它们仍可补学分）
        remaining = [c for c in module_courses if c["course_id"] not in passed_ids]
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
        # 方案课程全量明细：展开卡片时展示“培养方案详细要求”，不再只有
        # gap=0 时的「学分已满足」。missing_courses 保留以兼容旧消费者。
        plan_courses_of_module = []
        seen_plan_course_ids = set()
        for c in module_courses:
            cid = str(c.get("course_id", ""))
            if cid in seen_plan_course_ids:
                continue
            seen_plan_course_ids.add(cid)
            fi = future_idx(c)
            r_hit = matched_record_by_plan_id.get(c["course_id"])
            item = {"course_id": c["course_id"], "name": c["name"],
                    "credits": c["credits"], "offered": c["offered"],
                    "offered_years": c.get("offered_years"),
                    "terms": [idx_str(i) for i in fi], "closed": not fi,
                    "passed": c["course_id"] in passed_ids}
            if r_hit is not None:
                item["record"] = {"semester": r_hit.get("semester"),
                                  "grade": r_hit.get("grade")}
            item["page"] = (c.get("source") or {}).get("page")
            plan_courses_of_module.append(item)
        # 已选未获学分课程数：方案课程里「已修未取得学分（未通过/在修未出分/
        # 弃修待录缓考无效）或已列入计划选课」且尚未取得学分的去重门数
        selected_no_credit = sum(
            1 for x in plan_courses_of_module
            if str(x["course_id"]) not in earned_cids
            and str(x["course_id"]) in selected_no_credit_ids)
        plan_course_stats = {"total": len(plan_courses_of_module),
                             "passed": sum(1 for x in plan_courses_of_module if x["passed"]),
                             "pending": sum(1 for x in plan_courses_of_module if not x["passed"]),
                             "closed": sum(1 for x in plan_courses_of_module if x["closed"])}
        row = {"module_id": m["module_id"], "module_path": m["module_path"],
               "title": m.get("title"), "level": m.get("level"), "category": m.get("category"),
               "plan_credits_raw": m.get("plan_credits_raw"),
               "plan_credits_unit": m.get("plan_credits_unit"),
               "notes": m.get("notes") or []}
        # 模块里带哪些扩展口径字段就透传哪些（教务实时方案可能有，golden 冻结方案没有）
        for k in ("choice_rule", "alternative", "certified_category", "sub_requirements"):
            if k in m:
                row[k] = m[k]
        row.update({"required": req, "earned": got, "selected_no_credit": selected_no_credit,
                    "gap": gap,
                    "remaining_future": open_before_grad,
                    "color": color, "status": status,
                    "plan_courses": plan_courses_of_module,
                    "course_stats": plan_course_stats, "missing_courses": missing})
        summary.append(row)

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

    def _g(n):
        return "%g" % float(n)

    # 口径说明（供 UI 用不同颜色注释；固定两条 + 按方案内容追加的组/外语口径）
    caliber_notes = [K_CALIBER_EARNED_NOTE, K_CALIBER_SELECTED_NOTE]
    if group_applied:
        caliber_notes.append(
            "选课组口径：模块内「四选一/选N门/至少修读N门」类组按「至少 N 门」"
            "折算要求学分（组内其余课程为可选项，不再全部求和），任过 N 门即达成。")
    if plan_has_foreign:
        caliber_notes.append(
            "外语口径：外语类模块可在审计动作中指定 foreign_lang_level"
            "（L1=6 分、L2=4.5 分、L3=3 分，按等级封顶要求学分）；"
            "未选择时按方案原要求核算。")
    trace_notes = []
    if foreign_cap is not None and plan_has_foreign:
        trace_notes.append("外语等级 %s：外语类模块要求学分按 %s 分封顶。"
                           % (foreign_level_raw, _g(foreign_cap)))
    if foreign_cap is not None and not plan_has_foreign:
        trace_notes.append("未在方案中识别外语类模块，foreign_lang_level=%s 未生效。" % foreign_level_raw)
    if foreign_cap is None and plan_has_foreign:
        trace_notes.append("外语等级未选择，外语类模块按方案原要求核算。")

    return {"summary": summary, "warnings": warnings,
            "extra_courses": unmatched, "totals": totals,
            "caliber_notes": caliber_notes,
            "disclaimer": "本报告仅供与导师沟通参考，正式认定以教务系统为准。",
            "trace": {"plan": "%s%s（核验日 %s）" % (
                plan["meta"]["source_doc"],
                "" if not str(plan["meta"].get("grade", "")).strip() else " %s级" % plan["meta"]["grade"],
                plan["meta"].get("verified_at", "-")),
                "engine": "v%s" % ENGINE_VERSION,
                "notes": trace_notes}}


def main(record_json="", action="audit"):
    rec = json.loads(record_json) if isinstance(record_json, str) else record_json
    action_map = None
    if isinstance(action, dict):
        action_map = {str(k): v for k, v in action.items()}
    elif action != "audit" and action is not None:
        return {"error": "unknown action: %s" % action}
    try:
        plan = find_plan(rec["student"]["major"])
        report = build(rec, plan, action=action_map)
    except ValueError as e:
        return {"error": str(e)}
    return {"report": report, "report_json": json.dumps(report, ensure_ascii=False)}
