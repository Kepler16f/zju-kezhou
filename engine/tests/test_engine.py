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


class GroupRuleTest(unittest.TestCase):
    """需求 #5（v1.3）：选课组「四选一」按至少 N 门折算，不再全量和。"""

    @staticmethod
    def _plan(required=8.0):
        return {
            "meta": {"major": "group_test", "source_doc": "d.pdf",
                     "grade": "2023", "verified_at": "2026-01-01"},
            "modules": [{"module_id": "wr", "module_path": "通识必修·大学写作（四选一）",
                         "title": "大学写作", "level": 1, "category": "选修",
                         "required_credits": required, "plan_credits_raw": None,
                         "plan_credits_unit": None, "notes": []}],
            "courses": [
                {"course_id": "W%d" % i, "name": "写作%d" % i, "credits": 2.0, "module_id": "wr",
                 "offered": ["秋", "春"], "offered_years": None, "prereq": [],
                 "source": {"page": 2}} for i in range(1, 5)
            ],
        }

    def test_four_pick_one_not_full_sum(self):
        r = audit.build(rec(courses=[cr("W1", "写作1", 2.0)]), self._plan())
        m = r["summary"][0]
        self.assertEqual(m["required"], 2.0)   # 1 门最便宜，不再 8 分
        self.assertEqual(m["gap"], 0.0)
        self.assertEqual(m["color"], "green")
        self.assertTrue(any("选课组口径" in n for n in r["caliber_notes"]))

    def test_correct_annotation_untouched(self):
        r = audit.build(rec(courses=[cr("W1", "写作1", 2.0)]), self._plan(required=2.0))
        self.assertEqual(r["summary"][0]["required"], 2.0)  # 要求 < 全组和：不动
        self.assertFalse(any("选课组口径" in n for n in r["caliber_notes"]))

    def test_n_select_field_group(self):
        plan = self._plan()
        plan["modules"][0]["n_select"] = 1
        plan["modules"][0]["module_path"] = "通识选修"  # 去"四选一"字样，验证结构化字段
        r = audit.build(rec(courses=[cr("W1", "写作1", 2.0)]), plan)
        self.assertEqual(r["summary"][0]["required"], 2.0)

    def test_multi_label_course_counted_once(self):
        # 同名课重复行（多标签）：组内学分去重，只计一次
        plan = self._plan(required=2.0)
        c2 = dict(plan["courses"][0])
        c2["source"] = {"page": 3}
        plan["courses"].append(c2)
        r = audit.build(rec(courses=[cr("W1", "写作1", 2.0)]), plan)
        self.assertEqual(r["summary"][0]["earned"], 2.0)

    def test_selected_no_credit(self):
        plan = self._plan(required=2.0)
        # 在修未出分：selected_no_credit 计 1，earned 0
        r1 = audit.build(rec(courses=[{"course_id": "W2", "name": "写作2", "credits": 2.0,
                                       "grade": None, "passed": False, "semester": "2025-A"}]), plan)
        self.assertEqual(r1["summary"][0]["selected_no_credit"], 1)
        self.assertEqual(r1["summary"][0]["earned"], 0.0)
        # 计划选课（无成绩）同样计入
        r2 = audit.build(rec(planned=[{"course_id": "W3", "name": "写作3", "credits": 2.0}]), plan)
        self.assertEqual(r2["summary"][0]["selected_no_credit"], 1)

    def test_engine_trace_v14_and_caliber_notes(self):
        r = audit.build(rec(), PLANS["computer_science"])
        self.assertEqual(r["trace"]["engine"], "v1.5")
        self.assertIn("caliber_notes", r)
        self.assertTrue(any("earned=已获学分" in n for n in r["caliber_notes"]))
        self.assertTrue(any("selected_no_credit=已选未获学分" in n for n in r["caliber_notes"]))
        # v1.4 固定第三条口径（多标签双计）恒在
        self.assertTrue(any("同一课程多类别归属" in n for n in r["caliber_notes"]))
        for m in r["summary"]:
            self.assertIn("selected_no_credit", m)
        # 总学分口径（v1.4）：CS golden 声明 103 → plan_declared
        self.assertEqual(r["totals"]["plan_total_credits"], 103.0)
        self.assertEqual(r["totals"]["total_basis"], "plan_declared")
        self.assertTrue(any("方案声明最低毕业学分" in n for n in r["trace"]["notes"]))


class ForeignLangLevelTest(unittest.TestCase):
    """需求 #5：外语模块要求学分按 L1=6 / L2=4.5 / L3=3 封顶；缺省不假设。"""

    @staticmethod
    def _plan(required=12.0):
        return {
            "meta": {"major": "fl_test", "source_doc": "d.pdf",
                     "grade": "2023", "verified_at": "2026-01-01"},
            "modules": [{"module_id": "fl", "module_path": "外语类", "title": "大学英语",
                         "level": 1, "category": "必修", "required_credits": required,
                         "plan_credits_raw": None, "plan_credits_unit": None, "notes": []}],
            "courses": [
                {"course_id": "FL%02d" % i, "name": "大学英语%d" % i, "credits": 3.0,
                 "module_id": "fl", "offered": ["秋", "春"], "offered_years": None,
                 "prereq": [], "source": {"page": 1}} for i in range(1, 5)
            ],
        }

    def _rec(self, n=2):
        return rec(courses=[cr("FL%02d" % i, "大学英语%d" % i, 3.0) for i in range(1, n + 1)])

    def test_default_untouched(self):
        r = audit.build(self._rec(), self._plan())
        self.assertEqual(r["summary"][0]["required"], 12.0)
        self.assertTrue(any("外语等级未选择" in n for n in r["trace"]["notes"]))
        self.assertTrue(any("外语口径" in n for n in r["caliber_notes"]))

    def test_caps(self):
        for level, cap in (("L1", 6.0), ("L2", 4.5), ("L3", 3.0)):
            r = audit.build(self._rec(4), self._plan(), action={"foreign_lang_level": level})
            m = r["summary"][0]
            self.assertEqual(m["required"], cap, level)
            self.assertEqual(m["earned"], 12.0, level)  # 已获不变（封顶只降要求）
            self.assertEqual(m["gap"], 0.0, level)
            self.assertTrue(any("外语等级" in n for n in r["trace"]["notes"]), level)

    def test_cap_never_raises(self):
        # 要求 4 < L1 封顶 6：只降不升
        r = audit.build(self._rec(), self._plan(required=4.0), action={"foreign_lang_level": "L1"})
        self.assertEqual(r["summary"][0]["required"], 4.0)

    def test_invalid_level(self):
        with self.assertRaises(ValueError):
            audit.build(self._rec(), self._plan(), action={"foreign_lang_level": "L9"})

    def test_invalid_level_main_error_shape(self):
        out = audit.main(json.dumps(self._rec()), action={"foreign_lang_level": "X1"})
        self.assertIn("error", out)

    def test_no_foreign_module(self):
        r = audit.build(rec(), PLANS["computer_science"], action={"foreign_lang_level": "L1"})
        self.assertTrue(any("未生效" in n for n in r["trace"]["notes"]))
        self.assertFalse(any("外语口径" in n for n in r["caliber_notes"]))


class MultiTagDoubleCountTest(unittest.TestCase):
    """多重计分（v1.4 用户口径）：一节课归属多个模块时学分两边都计。"""

    @staticmethod
    def _module(mid, path, required, title=None):
        return {"module_id": mid, "module_path": path, "title": title or path,
                "level": 1, "category": "必修", "required_credits": required,
                "plan_credits_raw": None, "plan_credits_unit": None, "notes": []}

    @staticmethod
    def _course(cid, name, credits, mid):
        return {"course_id": cid, "name": name, "credits": credits, "module_id": mid,
                "offered": ["秋", "春"], "offered_years": None, "prereq": [],
                "source": {"page": 1}}

    def _multi_plan(self):
        # W1 同时挂在「大学写作（四选一）」与「专业限选」两个模块
        return {
            "meta": {"major": "mt", "source_doc": "d.pdf", "grade": "2023",
                     "verified_at": "2026-01-01", "total_credits": 4.0},
            "modules": [
                self._module("writing_group", "通识教育/通识选修 · 大学写作（四选一）", 8.0, "大学写作（四选一）"),
                self._module("other", "专业教育/专业限选", 2.0),
            ],
            "courses": [
                self._course("W1", "写作1", 2.0, "writing_group"),
                self._course("W2", "写作2", 2.0, "writing_group"),
                self._course("W3", "写作3", 2.0, "writing_group"),
                self._course("W4", "写作4", 2.0, "writing_group"),
                self._course("W1", "写作1", 2.0, "other"),  # 同课号第二个归属
            ],
        }

    def _row(self, report, mid):
        return next(m for m in report["summary"] if m["module_id"] == mid)

    def test_same_course_id_two_modules_earns_both(self):
        r = audit.build(rec(courses=[cr("W1", "写作1", 2.0)]), self._multi_plan())
        self.assertEqual(self._row(r, "writing_group")["earned"], 2.0)
        self.assertEqual(self._row(r, "other")["earned"], 2.0)
        self.assertEqual(r["totals"]["earned"], 4.0)
        # 两处 W1 明细都标 multi_tag
        for mid in ("writing_group", "other"):
            w1 = next(c for c in self._row(r, mid)["plan_courses"] if c["course_id"] == "W1")
            self.assertTrue(w1.get("multi_tag"), mid)
        self.assertTrue(any("多重计分" in n for n in r["trace"]["notes"]))
        self.assertTrue(any("同一课程多类别归属" in n for n in r["caliber_notes"]))

    def test_selected_no_credit_double(self):
        w = {"course_id": "W1", "name": "写作1", "credits": 2.0,
             "grade": None, "passed": False, "semester": "2025-A"}
        r = audit.build(rec(courses=[w]), self._multi_plan())
        self.assertEqual(self._row(r, "writing_group")["selected_no_credit"], 1)
        self.assertEqual(self._row(r, "other")["selected_no_credit"], 1)
        self.assertEqual(self._row(r, "writing_group")["earned"], 0.0)

    def test_retake_counts_once_per_module(self):
        r = audit.build(rec(courses=[
            cr("W1", "写作1", 2.0, grade=61),
            cr("W1", "写作1", 2.0, grade=88),
        ]), self._multi_plan())
        self.assertEqual(self._row(r, "writing_group")["earned"], 2.0)
        self.assertEqual(self._row(r, "other")["earned"], 2.0)
        self.assertEqual(r["totals"]["earned"], 4.0)

    def test_same_name_different_id_cross_modules(self):
        plan = {
            "meta": {"major": "mt2", "source_doc": "d.pdf", "grade": "2023",
                     "verified_at": "2026-01-01", "total_credits": 5.0},
            "modules": [self._module("m1", "专业教育/专业核心", 3.0),
                        self._module("m2", "通识教育/劳育类", 2.0)],
            "courses": [self._course("A1", "劳动教育实践", 3.0, "m1"),
                        self._course("B2", "劳动教育实践", 2.0, "m2")],
        }
        # 成绩单只有 A1；B2 靠同名匹配（≥0.85）命中 → 两模块各计一次
        r = audit.build(rec(courses=[cr("A1", "劳动教育实践", 3.0)]), plan)
        self.assertEqual(self._row(r, "m1")["earned"], 3.0)
        self.assertEqual(self._row(r, "m2")["earned"], 2.0)
        self.assertEqual(r["totals"]["earned"], 5.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
