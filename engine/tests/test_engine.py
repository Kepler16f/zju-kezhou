# -*- coding: utf-8 -*-
"""单元测试：时间轴、三色边界、先修、开课窗口、时间冲突、三源适配器、golden 一致性。
运行：python -m unittest discover -s engine/tests -v
（对应答辩追问"算错了谁负责"的证据文件）"""
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.dirname(HERE)
ROOT = os.path.dirname(ENGINE)
sys.path.insert(0, ENGINE)

import audit
import adapters
import common


def load_plans():
    d = os.path.join(ROOT, "data", "golden")
    out = {}
    for f in os.listdir(d):
        if f.endswith(".json"):
            with open(os.path.join(d, f), encoding="utf-8") as fh:
                p = json.load(fh)
            out[p["meta"]["major"]] = p
    return out


PLANS = load_plans()
audit.PLAN_JSON = json.dumps(PLANS, ensure_ascii=False)


def rec(minor="computer_science", current="2026-A", courses=None, planned=None):
    return {"student": {"alias": "t", "major": minor, "grade": "2023",
                        "current_semester": current},
            "source": "paste",
            "courses": courses or [],
            "planned_courses": planned or []}


def cr(cid, name, credits, grade=80, sem="2025-A"):
    return {"course_id": cid, "name": name, "credits": credits, "grade": grade, "semester": sem}


class TestTimeline(unittest.TestCase):
    def test_sem_order(self):
        self.assertLess(common.sem_idx("2026-A"), common.sem_idx("2026-B"))
        self.assertLess(common.sem_idx("2026-B"), common.sem_idx("2027-A"))

    def test_open_idx_biennial(self):
        c = {"offered": ["春"], "offered_years": [2027]}
        self.assertEqual(common.course_open_idx(c, 2023, 6), [2027 * 2 + 1])

    def test_open_idx_multi(self):
        c = {"offered": ["秋", "春"], "offered_years": None}
        got = common.course_open_idx(c, 2026, 2)
        self.assertEqual(got, [2026 * 2, 2026 * 2 + 1, 2027 * 2, 2027 * 2 + 1])


class TestThreeColor(unittest.TestCase):
    def setUp(self):
        self.plan = PLANS["computer_science"]

    def test_green_exact(self):
        cs = self.plan["courses"]
        general = [cr(c["course_id"], c["name"], c["credits"])
                   for c in cs if c["module_id"] == "general_required"]
        r = audit.build(rec(courses=general), self.plan)
        m = next(x for x in r["summary"] if x["module_id"] == "general_required")
        self.assertEqual(m["color"], "green")
        self.assertEqual(m["gap"], 0.0)

    def test_yellow_when_coverable(self):
        r = audit.build(rec(courses=[cr("CS3101", "人工智能导论", 3.0)]), self.plan)
        m = next(x for x in r["summary"] if x["module_id"] == "major_limited")
        self.assertEqual(m["color"], "yellow")

    def test_red_when_pool_closed(self):
        # 任意选修池：EL001 每年开(2分) < 要求4分，EL002/EL003 已关闭 -> 红
        r = audit.build(rec(), self.plan)
        m = next(x for x in r["summary"] if x["module_id"] == "free_elective")
        self.assertEqual(m["color"], "red")
        self.assertTrue(any(w["type"] == "graduation_risk" and "任意选修" in w["text"]
                            for w in r["warnings"]))

    def test_failed_not_counted(self):
        r = audit.build(rec(courses=[cr("CS3101", "人工智能导论", 3.0, grade=59)]), self.plan)
        m = next(x for x in r["summary"] if x["module_id"] == "major_limited")
        self.assertEqual(m["earned"], 0.0)
        self.assertTrue(any(w["type"] == "failed_recheck" for w in r["warnings"]))


class TestPrereq(unittest.TestCase):
    def setUp(self):
        self.plan = PLANS["computer_science"]

    def test_prereq_gap_detected(self):
        r = audit.build(rec(courses=[cr("CS3001", "操作系统", 4.0)]), self.plan)
        self.assertTrue(any(w["type"] == "prereq_gap" and "计算机组成原理" in w["text"]
                            for w in r["warnings"]))

    def test_prereq_same_semester(self):
        planned = [{"course_id": "CS3002", "name": "编译原理", "semester": "2026-B",
                    "time_slots": []},
                   {"course_id": "CS2001", "name": "数据结构与算法", "semester": "2026-B",
                    "time_slots": []}]
        r = audit.build(rec(courses=[], planned=planned), self.plan)
        hit = [w for w in r["warnings"] if w["type"] == "prereq_same_semester"]
        self.assertTrue(hit and "拆开两学期" in hit[0]["text"])

    def test_prereq_ok_no_warning(self):
        courses = [cr("CS1001", "程序设计基础", 4.0), cr("CS2002", "计算机组成原理", 4.0),
                   cr("CS2001", "数据结构与算法", 4.0)]
        r = audit.build(rec(courses=courses), self.plan)
        self.assertFalse(any(w["type"] == "prereq_gap" for w in r["warnings"]))


class TestOffering(unittest.TestCase):
    def setUp(self):
        self.plan = PLANS["computer_science"]

    def test_plan_wrong_season(self):
        planned = [{"course_id": "CS2003", "name": "算法设计与分析", "semester": "2026-B"}]
        r = audit.build(rec(planned=planned), self.plan)  # CS2003 仅秋
        self.assertTrue(any(w["type"] == "offering_closed" and "仅秋" in w["text"]
                            for w in r["warnings"]))

    def test_plan_wrong_cycle(self):
        planned = [{"course_id": "CS3102", "name": "信息安全导论", "semester": "2026-B"}]
        r = audit.build(rec(planned=planned), self.plan)  # 仅2027学年开
        self.assertTrue(any("隔年开课" in w["text"] for w in r["warnings"]))

    def test_missed_biennial_pool(self):
        # PR4001 生产实习仅 2025 学年春开，2026-A 视角已错过
        m = next(x for x in audit.build(rec(), self.plan)["summary"]
                 if x["module_id"] == "intensive_practice")
        closed = [c for c in m["missing_courses"] if c["course_id"] == "PR4001"]
        self.assertTrue(closed and closed[0]["closed"])


class TestTimeConflict(unittest.TestCase):
    def test_overlap(self):
        self.assertTrue(common.slots_conflict(
            [{"day": 2, "start": 3, "end": 4}], [{"day": 2, "start": 4, "end": 5}]))

    def test_week_disjoint(self):
        self.assertIsNone(common.slots_conflict(
            [{"day": 2, "start": 1, "end": 2, "week_start": 1, "week_end": 8}],
            [{"day": 2, "start": 1, "end": 2, "week_start": 9, "week_end": 16}]))

    def test_plan_conflict_report(self):
        planned = [{"course_id": "CS3006", "name": "计算机体系结构", "semester": "2027-A",
                    "time_slots": [{"day": 5, "start": 1, "end": 2}]},
                   {"course_id": "CS3103", "name": "区块链技术导论", "semester": "2027-A",
                    "time_slots": [{"day": 5, "start": 2, "end": 3}]}]
        r = audit.build(rec(planned=planned), PLANS["computer_science"])
        self.assertTrue(any(w["type"] == "time_conflict" for w in r["warnings"]))


class TestAdapters(unittest.TestCase):
    def test_parse_paste(self):
        text = "2023-A CS1001 程序设计基础 4.0 91\n2023-B 高等数学 5.0 80\n坏行没有学分"
        courses, failed = adapters.parse_paste(text)
        self.assertEqual(len(courses), 2)
        self.assertEqual(courses[0]["course_id"], "CS1001")
        self.assertIsNone(courses[1]["course_id"])
        self.assertEqual(failed, ["坏行没有学分"])

    def test_parse_export_csv_str(self):
        text = ("课程代码,课程名称,学分,成绩,开课学期\n"
                "CS1001,程序设计基础,4.0,91,2023-秋\n"
                "GS1004,体育（基础）,1.0,89,2024-春\n")
        courses, failed = adapters.parse_export_csv(text)
        self.assertEqual(len(courses), 2)
        self.assertEqual(courses[0]["semester"], "2023-A")
        self.assertEqual(courses[1]["semester"], "2024-B")

    def test_main_error_on_empty(self):
        out = adapters.main("完全不是成绩单的一行文字")
        self.assertIn("error", out)


class TestGoldenConsistency(unittest.TestCase):
    """golden 是冻结数据，此测试防手改后失去一致性（进 CI 习惯）。"""
    def test_prereq_refs_exist(self):
        for major, p in PLANS.items():
            ids = {c["course_id"] for c in p["courses"]}
            for c in p["courses"]:
                for pre in c.get("prereq", []):
                    self.assertIn(pre, ids, "%s: %s 先修引用 %s 不存在" % (major, c["course_id"], pre))

    def test_credits_step(self):
        for p in PLANS.values():
            for c in p["courses"]:
                self.assertGreater(c["credits"], 0)
                self.assertAlmostEqual(c["credits"] * 2 % 1, 0, msg=c["name"])

    def test_module_paths_unique(self):
        for p in PLANS.values():
            ms = [m["module_id"] for m in p["modules"]]
            self.assertEqual(len(ms), len(set(ms)))


class TestEndToEnd(unittest.TestCase):
    def test_demo_sample_full_report(self):
        with open(os.path.join(ROOT, "data", "samples", "demo1_cs_full.json"),
                  encoding="utf-8") as fh:
            rec1 = json.load(fh)
        r = audit.build(rec1, PLANS["computer_science"])
        types = {w["type"] for w in r["warnings"]}
        for t in ("prereq_gap", "time_conflict", "graduation_risk", "failed_recheck",
                  "unmatched_courses", "offering_closed"):
            self.assertIn(t, types)
        self.assertEqual(r["disclaimer"], "本报告仅供与导师沟通参考，正式认定以教务系统为准。")
        self.assertTrue(r["trace"]["plan"])

    def test_se_sample(self):
        with open(os.path.join(ROOT, "data", "samples", "demo3_se_full.json"),
                  encoding="utf-8") as fh:
            rec3 = json.load(fh)
        r = audit.build(rec3, PLANS["software_engineering"])
        m = next(x for x in r["summary"] if x["module_id"] == "general_required")
        self.assertEqual(m["earned"], 21.0)  # 10门通识全过：3+2+2+1+1+2+2+3+3+2
        mc = next(x for x in r["summary"] if x["module_id"] == "major_core")
        self.assertEqual(mc["earned"], 13.0)  # SE1001+SE2001+SE2002+SE3001
        self.assertEqual(mc["color"], "yellow")  # 缺6，SE3002/SE3003 可补


if __name__ == "__main__":
    unittest.main(verbosity=2)
