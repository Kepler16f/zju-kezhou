# -*- coding: utf-8 -*-
# 自动生成：python engine/build_embed.py ｜ 2026-10-17 22:00 ｜ 专业：computer_science、software_engineering
# 用法：整文件粘贴进 Dify「代码执行(Python3)」节点
# 输入：record_json(str)  action(str，固定 'audit') ｜ 输出：report_json(str)
import difflib
import json


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


# -*- coding: utf-8 -*-
"""engine.audit — M2 学业进度审计规则引擎（确定性计算，无 LLM、无第三方库）。
入口：main(record_json) -> {"report": ..., "report_json": ...}
Dify Code 节点用法：PLAN_JSON 常量由 engine/build_embed.py 注入，本文件其余逻辑原样粘贴。
依赖：py（时间轴与冲突检测）。时间轴约定见 py 顶部说明。
"""






ENGINE_VERSION = "1.2"
GRADUATION_YEARS = 6  # 最长学籍年限（年），自入学学年起算
PLAN_JSON = r'''{"computer_science": {"meta": {"major": "computer_science", "grade": "2023", "source_doc": "2023级计算机专业本科培养方案（合成演示样例）", "total_credits": 103.0, "extracted_by": "M1 workflow v1", "verified": true, "verified_at": "2026-10-13"}, "modules": [{"module_id": "general_required", "module_path": "通识教育/通识必修", "required_credits": 34.0, "kind": "必修", "course_ids": ["GS1001", "GS1002", "GS1003", "GS1004", "GS1005", "GS1006", "GS1007", "GS1008", "GS1009", "GS1010", "GS1011", "GS1012", "GS1013", "GS1014", "GS1015", "GS1016"]}, {"module_id": "major_core", "module_path": "专业教育/专业核心", "required_credits": 39.0, "kind": "必修", "course_ids": ["CS1001", "CS1002", "CS2001", "CS2002", "CS2003", "CS3001", "CS3002", "CS3003", "CS3004", "CS3005", "CS3006", "CS3007"]}, {"module_id": "major_limited", "module_path": "专业教育/专业限选", "required_credits": 8.0, "kind": "限选", "course_ids": ["CS3101", "CS3102", "CS4101", "CS4102", "CS3103"]}, {"module_id": "intensive_practice", "module_path": "集中实践", "required_credits": 18.0, "kind": "必修", "course_ids": ["PR3001", "PR3002", "PR4001", "PR4002", "PR4003"]}, {"module_id": "free_elective", "module_path": "任意选修", "required_credits": 4.0, "kind": "限选", "course_ids": ["EL001", "EL002", "EL003"]}], "courses": [{"course_id": "GS1001", "name": "思想道德与法治", "credits": 3.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 12}}, {"course_id": "GS1002", "name": "英语学术读写", "credits": 2.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 13}}, {"course_id": "GS1003", "name": "英语国际交流", "credits": 2.0, "module_id": "general_required", "nature": "通识必修", "offered": ["春"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 13}}, {"course_id": "GS1004", "name": "体育（基础）", "credits": 1.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 14}}, {"course_id": "GS1005", "name": "体育（选项）", "credits": 1.0, "module_id": "general_required", "nature": "通识必修", "offered": ["春"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 14}}, {"course_id": "GS1006", "name": "军事理论", "credits": 2.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 15}}, {"course_id": "GS1007", "name": "计算机基础", "credits": 2.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 16}}, {"course_id": "GS1008", "name": "毛泽东思想和中国特色社会主义理论体系概论", "credits": 3.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 17}}, {"course_id": "GS1009", "name": "中国近现代史纲要", "credits": 3.0, "module_id": "general_required", "nature": "通识必修", "offered": ["春"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 17}}, {"course_id": "GS1010", "name": "马克思主义基本原理", "credits": 3.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 18}}, {"course_id": "GS1011", "name": "形势与政策", "credits": 2.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 18}}, {"course_id": "GS1012", "name": "劳动教育", "credits": 2.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋", "春"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 19}}, {"course_id": "GS1013", "name": "国家安全教育", "credits": 2.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 19}}, {"course_id": "GS1014", "name": "创新创业基础", "credits": 2.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋", "春"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 20}}, {"course_id": "GS1015", "name": "心理与人格发展", "credits": 2.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋", "春"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 20}}, {"course_id": "GS1016", "name": "人工智能通识", "credits": 2.0, "module_id": "general_required", "nature": "通识必修", "offered": ["春"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 21}}, {"course_id": "CS1001", "name": "程序设计基础", "credits": 4.0, "module_id": "major_core", "nature": "必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 23}}, {"course_id": "CS1002", "name": "离散数学", "credits": 3.0, "module_id": "major_core", "nature": "必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 23}}, {"course_id": "CS2001", "name": "数据结构与算法", "credits": 4.0, "module_id": "major_core", "nature": "必修", "offered": ["春"], "grade_cycle": null, "offered_years": null, "prereq": ["CS1001"], "source": {"page": 24}}, {"course_id": "CS2002", "name": "计算机组成原理", "credits": 4.0, "module_id": "major_core", "nature": "必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": ["CS1001"], "source": {"page": 25}}, {"course_id": "CS2003", "name": "算法设计与分析", "credits": 3.0, "module_id": "major_core", "nature": "必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": ["CS2001"], "source": {"page": 25}, "note": "算法设计与分析仅秋季"}, {"course_id": "CS3001", "name": "操作系统", "credits": 4.0, "module_id": "major_core", "nature": "必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": ["CS2001", "CS2002"], "source": {"page": 26}}, {"course_id": "CS3002", "name": "编译原理", "credits": 3.0, "module_id": "major_core", "nature": "必修", "offered": ["春"], "grade_cycle": null, "offered_years": null, "prereq": ["CS2001"], "source": {"page": 26}}, {"course_id": "CS3003", "name": "计算机网络", "credits": 3.0, "module_id": "major_core", "nature": "必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": ["CS2002"], "source": {"page": 27}}, {"course_id": "CS3004", "name": "数据库系统", "credits": 3.0, "module_id": "major_core", "nature": "必修", "offered": ["春"], "grade_cycle": null, "offered_years": null, "prereq": ["CS1001"], "source": {"page": 27}}, {"course_id": "CS3005", "name": "软件工程导论", "credits": 2.0, "module_id": "major_core", "nature": "必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 28}}, {"course_id": "CS3006", "name": "计算机体系结构", "credits": 3.0, "module_id": "major_core", "nature": "必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": ["CS2002"], "source": {"page": 28}}, {"course_id": "CS3007", "name": "数值分析", "credits": 3.0, "module_id": "major_core", "nature": "必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": ["CS1002"], "source": {"page": 29}}, {"course_id": "CS3101", "name": "人工智能导论", "credits": 3.0, "module_id": "major_limited", "nature": "限选", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 30}}, {"course_id": "CS3102", "name": "信息安全导论", "credits": 2.0, "module_id": "major_limited", "nature": "限选", "offered": ["春"], "grade_cycle": null, "offered_years": [2027], "prereq": [], "source": {"page": 30}}, {"course_id": "CS4101", "name": "机器学习", "credits": 4.0, "module_id": "major_limited", "nature": "限选", "offered": ["秋"], "grade_cycle": null, "offered_years": [2025], "prereq": ["CS2003"], "source": {"page": 31}}, {"course_id": "CS4102", "name": "数据挖掘", "credits": 3.0, "module_id": "major_limited", "nature": "限选", "offered": ["秋"], "grade_cycle": null, "offered_years": [2025, 2026, 2027], "prereq": [], "source": {"page": 31}}, {"course_id": "CS3103", "name": "区块链技术导论", "credits": 2.0, "module_id": "major_limited", "nature": "限选", "offered": ["春"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 32}}, {"course_id": "PR3001", "name": "课程设计（数据结构）", "credits": 2.0, "module_id": "intensive_practice", "nature": "实践", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": ["CS2001"], "source": {"page": 33}}, {"course_id": "PR3002", "name": "科研训练", "credits": 2.0, "module_id": "intensive_practice", "nature": "实践", "offered": ["秋", "春"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 33}}, {"course_id": "PR4001", "name": "生产实习", "credits": 2.0, "module_id": "intensive_practice", "nature": "实践", "offered": ["春"], "grade_cycle": null, "offered_years": [2025], "prereq": [], "source": {"page": 34}}, {"course_id": "PR4002", "name": "专业实习", "credits": 4.0, "module_id": "intensive_practice", "nature": "实践", "offered": ["秋", "春"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 34}}, {"course_id": "PR4003", "name": "毕业设计（论文）", "credits": 8.0, "module_id": "intensive_practice", "nature": "实践", "offered": ["春"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 35}}, {"course_id": "EL001", "name": "创新设计思维", "credits": 2.0, "module_id": "free_elective", "nature": "任选", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 36}}, {"course_id": "EL002", "name": "数据可视化", "credits": 2.0, "module_id": "free_elective", "nature": "任选", "offered": ["春"], "grade_cycle": null, "offered_years": [2024, 2025], "prereq": [], "source": {"page": 36}}, {"course_id": "EL003", "name": "科技伦理", "credits": 2.0, "module_id": "free_elective", "nature": "任选", "offered": ["秋"], "grade_cycle": null, "offered_years": [2024, 2025], "prereq": [], "source": {"page": 36}}]}, "software_engineering": {"meta": {"major": "software_engineering", "grade": "2023", "source_doc": "2023级软件学院本科培养方案（合成样例）", "total_credits": 61.0, "extracted_by": "M1 workflow v1", "verified": true, "verified_at": "2026-10-13"}, "modules": [{"module_id": "general_required", "module_path": "通识教育/通识必修", "required_credits": 21.0, "kind": "必修"}, {"module_id": "major_core", "module_path": "专业教育/专业核心", "required_credits": 19.0, "kind": "必修"}, {"module_id": "major_limited", "module_path": "专业教育/专业限选", "required_credits": 5.0, "kind": "限选"}, {"module_id": "intensive_practice", "module_path": "集中实践", "required_credits": 14.0, "kind": "必修"}, {"module_id": "free_elective", "module_path": "任意选修", "required_credits": 2.0, "kind": "限选"}], "courses": [{"course_id": "GS1001", "name": "思想道德与法治", "credits": 3.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 12}}, {"course_id": "GS1002", "name": "英语学术读写", "credits": 2.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 13}}, {"course_id": "GS1003", "name": "英语国际交流", "credits": 2.0, "module_id": "general_required", "nature": "通识必修", "offered": ["春"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 13}}, {"course_id": "GS1004", "name": "体育（基础）", "credits": 1.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 14}}, {"course_id": "GS1005", "name": "体育（选项）", "credits": 1.0, "module_id": "general_required", "nature": "通识必修", "offered": ["春"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 14}}, {"course_id": "GS1006", "name": "军事理论", "credits": 2.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 15}}, {"course_id": "GS1007", "name": "计算机基础", "credits": 2.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 16}}, {"course_id": "GS1008", "name": "毛泽东思想和中国特色社会主义理论体系概论", "credits": 3.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 17}}, {"course_id": "GS1009", "name": "中国近现代史纲要", "credits": 3.0, "module_id": "general_required", "nature": "通识必修", "offered": ["春"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 17}}, {"course_id": "GS1010", "name": "形势与政策", "credits": 2.0, "module_id": "general_required", "nature": "通识必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 18}}, {"course_id": "SE1001", "name": "程序设计基础", "credits": 4.0, "module_id": "major_core", "nature": "必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 21}}, {"course_id": "SE2001", "name": "面向对象设计", "credits": 3.0, "module_id": "major_core", "nature": "必修", "offered": ["春"], "grade_cycle": null, "offered_years": null, "prereq": ["SE1001"], "source": {"page": 22}}, {"course_id": "SE2002", "name": "数据结构", "credits": 4.0, "module_id": "major_core", "nature": "必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": ["SE1001"], "source": {"page": 22}}, {"course_id": "SE3001", "name": "软件需求工程", "credits": 2.0, "module_id": "major_core", "nature": "必修", "offered": ["春"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 23}}, {"course_id": "SE3002", "name": "软件测试", "credits": 3.0, "module_id": "major_core", "nature": "必修", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": ["SE2001"], "source": {"page": 23}}, {"course_id": "SE3003", "name": "软件体系结构", "credits": 3.0, "module_id": "major_core", "nature": "必修", "offered": ["春"], "grade_cycle": null, "offered_years": null, "prereq": ["SE2002"], "source": {"page": 24}}, {"course_id": "SE3101", "name": "移动应用开发", "credits": 2.0, "module_id": "major_limited", "nature": "限选", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 25}}, {"course_id": "SE4101", "name": "云原生技术", "credits": 3.0, "module_id": "major_limited", "nature": "限选", "offered": ["春"], "grade_cycle": null, "offered_years": [2026], "prereq": [], "source": {"page": 25}}, {"course_id": "SE4001", "name": "企业实习", "credits": 6.0, "module_id": "intensive_practice", "nature": "实践", "offered": ["春"], "grade_cycle": null, "offered_years": [2026], "prereq": [], "source": {"page": 26}}, {"course_id": "SE4002", "name": "毕业设计（论文）", "credits": 8.0, "module_id": "intensive_practice", "nature": "实践", "offered": ["春"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 26}}, {"course_id": "EL101", "name": "IT项目管理", "credits": 2.0, "module_id": "free_elective", "nature": "任选", "offered": ["秋"], "grade_cycle": null, "offered_years": null, "prereq": [], "source": {"page": 27}}]}}'''


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
    """按模块汇总已通过学分。同一门方案课程多条成绩单记录（重修/补考）只计一次学分；
    credit_included=False（弃修/待录/缓考/无效）不计入已取得学分，但仍视为已通过，
    避免重复出现在待修列表。"""
    earned = {m["module_id"]: 0.0 for m in plan["modules"]}
    counted = set()
    for r, c in matched:
        cid = c["course_id"]
        if not _is_passed(r) or cid in counted:
            continue
        counted.add(cid)
        if r.get("credit_included") is not False:
            earned[c["module_id"]] += c["credits"]
    return earned


def build(record, plan):
    matched, unmatched = match(record, plan)
    earned = aggregate(matched, plan)
    by_id = {c["course_id"]: c for c in plan["courses"]}
    taken_ids = {c["course_id"] for _, c in matched}
    passed_ids = {c["course_id"] for r, c in matched if _is_passed(r)}
    # 方案课程 id -> 首条匹配到的成绩单记录（无论是否通过），供 plan_courses 明细回显
    matched_record_by_plan_id = {}
    for r, c in matched:
        matched_record_by_plan_id.setdefault(c["course_id"], r)

    cur_idx = sem_idx(record["student"]["current_semester"])
    grade_year = int(record["student"]["grade"])
    grad_idx = grade_year * SEMESTERS_PER_GRADE_YEAR + GRADUATION_YEARS * SEMESTERS_PER_GRADE_YEAR - 1
    horizon = GRADUATION_YEARS + 1  # 学年窗口：grade_year .. grade_year+6（含毕业年 2028）

    def future_idx(c):
        """课程在当前学期之后、学籍年限之内的开课学期索引。"""
        return [i for i in course_open_idx(c, grade_year, horizon)
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
        # 方案课程全量明细：展开卡片时展示“培养方案详细要求”，不再只有
        # gap=0 时的「学分已满足」。missing_courses 保留以兼容旧消费者。
        plan_courses_of_module = []
        seen_plan_course_ids = set()
        for c in plan["courses"]:
            if c["module_id"] != m["module_id"]:
                continue
            cid = c["course_id"]
            if cid in seen_plan_course_ids:
                continue
            seen_plan_course_ids.add(cid)
            fi = future_idx(c)
            r_hit = matched_record_by_plan_id.get(cid)
            item = {"course_id": c["course_id"], "name": c["name"],
                    "credits": c["credits"], "offered": c["offered"],
                    "offered_years": c.get("offered_years"),
                    "terms": [idx_str(i) for i in fi], "closed": not fi,
                    "passed": cid in passed_ids}
            if r_hit is not None:
                item["record"] = {"semester": r_hit.get("semester"),
                                  "grade": r_hit.get("grade")}
            item["page"] = (c.get("source") or {}).get("page")
            plan_courses_of_module.append(item)
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
        row.update({"required": req, "earned": got, "gap": gap,
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
        for cf in check_plan(group):
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
