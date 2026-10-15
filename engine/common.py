# -*- coding: utf-8 -*-
"""engine.common — 学期时间轴、开课学期判定与时间冲突检测（纯 stdlib，可直接进 Dify Code 节点）。

时间轴约定（单一事实来源）：
  学期字符串 "YYYY-T"：T=A 表示学年 YYYY 的秋季（YYYY年9月起），T=B 表示学年 YYYY 的春季（YYYY+1年2月起）。
  学年 YYYY = 当年9月至次年7月。学期索引 idx = YYYY*2 + (0 若秋, 1 若春)，数值单调，可直接比较先后。
  例：2023-A=4046, 2023-B=4047, 2024-A=4048 ... 2026-B=4053, 2027-A=4054, 2027-B=4055。
  offered_years=[YYYY] 指"学年 YYYY"开课（含该学年秋 idx=YYYY*2 与春 idx=YYYY*2+1）。
"""

PASS_GRADE = 60.0
SEMESTERS_PER_GRADE_YEAR = 2   # 每学年 2 个学期


def sem_key(s):
    """'2023-A' -> (2023, 0)；A=秋(0) B=春(1)。"""
    y, t = s.strip().split("-")
    return (int(y), 0 if t.upper() == "A" else 1)


def sem_str(key):
    return "%d-%s" % (key[0], "A" if key[1] == 0 else "B")


def sem_idx(s):
    """学期字符串或 (y,t) 元组 -> 学期索引整数。"""
    key = sem_key(s) if isinstance(s, str) else s
    return key[0] * SEMESTERS_PER_GRADE_YEAR + key[1]


def idx_str(idx):
    """学期索引 -> 可读标签，如 4055 -> '2027-B(春)'。"""
    y, t = divmod(idx, 2)
    return "%d-%s(%s)" % (y, "AB"[t], "秋" if t == 0 else "春")


def course_open_idx(course, from_year, horizon_years):
    """课程在学年 [from_year, from_year+horizon_years) 内的开课学期索引升序列表。"""
    out = []
    for y in range(from_year, from_year + horizon_years):
        cycle = course.get("offered_years")
        if cycle and y not in cycle:
            continue
        if "秋" in course["offered"]:
            out.append(y * 2)
        if "春" in course["offered"]:
            out.append(y * 2 + 1)
    return sorted(out)


# ---------- 时间冲突（M3）：同星期、节次区间相交区间相交 ----------

def slots_conflict(a, b):
    for sa in a:
        for sb in b:
            if sa["day"] != sb["day"]:
                continue
            if sa["start"] > sb["end"] or sb["start"] > sa["end"]:
                continue
            ws = max(sa.get("week_start", 1), sb.get("week_start", 1))
            we = min(sa.get("week_end", 16), sb.get("week_end", 16))
            if ws <= we:
                return {"day": sa["day"], "start": max(sa["start"], sb["start"]),
                        "end": min(sa["end"], sb["end"]), "week_start": ws, "week_end": we}
    return None


def check_plan(courses):
    """同学期计划课表两两查冲突：[{name, time_slots}] -> 冲突对列表。"""
    out = []
    n = len(courses)
    for i in range(n):
        for j in range(i + 1, n):
            hit = slots_conflict(courses[i].get("time_slots") or [],
                                 courses[j].get("time_slots") or [])
            if hit:
                out.append({"a": courses[i]["name"], "b": courses[j]["name"],
                            "detail": "周%d 第%d-%d节（第%d-%d周）重叠" % (
                                hit["day"], hit["start"], hit["end"],
                                hit["week_start"], hit["week_end"])})
    return out
