#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tool/chalaoshi_fetch.py 的纯函数单测（换源/回归时先跑这个）。

不联网、不碰真实站点：只测解析与取值逻辑，锚点用实测样本（十分制原生）。
运行： python tool/test_chalaoshi_fetch.py
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from chalaoshi_fetch import (  # noqa: E402
    clamp_score,
    discover_ids,
    parse_teacher_page,
)


class ClampScoreTest(unittest.TestCase):
    def test_ten_point_native_no_conversion(self):
        self.assertEqual(clamp_score("9.39"), 9.39)   # 毕惟红实测样本，直取不折算
        self.assertEqual(clamp_score("10.0"), 10.0)   # 高分榜上限合法
        self.assertEqual(clamp_score("5"), 5.0)       # 低分同样直取（不再 /2）
        self.assertEqual(clamp_score("0"), 0.0)

    def test_out_of_range_or_dirty_returns_none(self):
        self.assertIsNone(clamp_score("10.1"))        # 越上界
        self.assertIsNone(clamp_score("-1"))          # 越下界
        self.assertIsNone(clamp_score("abc"))         # 非数值
        self.assertIsNone(clamp_score(None))


class ParseTest(unittest.TestCase):
    def test_real_title_anchor(self):
        html = "<html><head><title>毕惟红老师 9.39分 422人打分 - 查老师</title></head></html>"
        self.assertEqual(parse_teacher_page(html), ("毕惟红", 9.39, 422))

    def test_whitespace_and_extra_text(self):
        html = "<title> 张三丰老师 8.0分 12人打分 - 查老师 </title>"
        self.assertEqual(parse_teacher_page(html), ("张三丰", 8.0, 12))

    def test_no_match_returns_none(self):
        self.assertIsNone(parse_teacher_page("no title here"))
        self.assertIsNone(parse_teacher_page(None))
        self.assertIsNone(parse_teacher_page("<title>无数字</title>"))


class DiscoverTest(unittest.TestCase):
    def test_dedupe_and_limit(self):
        html = '/t/1/ /t/1/ /t/8/ /t/893/ /t/2006/'
        self.assertEqual(discover_ids(html, 10), ["1", "8", "893", "2006"])
        self.assertEqual(discover_ids(html, 2), ["1", "8"])


if __name__ == "__main__":
    unittest.main()
