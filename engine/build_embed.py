# -*- coding: utf-8 -*-
"""engine/build_embed.py — 生成单文件版 Dify Code 节点源码（common+audit 内联 + golden 注入）。
用法：python engine/build_embed.py
输出：dify/audit_code_node.py —— 整个文件粘贴进 Dify「代码执行(Python3)」节点即可。
注意：golden 有更新时务必重跑本脚本并重新粘贴，文件头部带生成时间。
"""
import datetime
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "dify", "audit_code_node.py")

plans = {}
gd = os.path.join(ROOT, "data", "golden")
for f in sorted(os.listdir(gd)):
    if f.endswith(".json"):
        p = json.load(open(os.path.join(gd, f), encoding="utf-8"))
        plans[p["meta"]["major"]] = p


def read(path):
    src = open(path, encoding="utf-8").read()
    # 去掉 docstring 与 import 行（单文件内联后不需要）
    src = re.sub(r'^""".*?"""', "", src, count=1, flags=re.S)
    src = re.sub(r"^(import|from) .*", "", src, flags=re.M)
    return src.strip()


common = read(os.path.join(HERE, "common.py"))
audit = read(os.path.join(HERE, "audit.py"))
# 跨模块引用改内联
audit = audit.replace("common.course_open_idx", "course_open_idx")
audit = audit.replace("common.check_plan", "check_plan")
audit = audit.replace("common.", "")
audit = re.sub(r"_load_disk_plans\(\)[\s\S]*?return out\n", "", audit, count=1)
audit = audit.replace(
    "    plans = _load_disk_plans()",
    "    plans = json.loads(PLAN_JSON)")
# 注入 golden
audit = re.sub(r"PLAN_JSON = r'''\{\}'''[^\n]*",
               "PLAN_JSON = r'''" + json.dumps(plans, ensure_ascii=False) + "'''", audit, count=1)

head = ("# -*- coding: utf-8 -*-\n"
        "# 自动生成：python engine/build_embed.py ｜ %s ｜ 专业：%s\n"
        "# 用法：整文件粘贴进 Dify「代码执行(Python3)」节点\n"
        "# 输入：record_json(str)  action(str，固定 'audit') ｜ 输出：report_json(str)\n"
        "import difflib\nimport json\n\n"
        % (datetime.datetime.now().strftime("%Y-%m-%d %H:%M"), "、".join(plans)))

open(OUT, "w", encoding="utf-8").write(head + "\n" + common + "\n\n\n" + audit + "\n")
print("written:", OUT, os.path.getsize(OUT), "bytes")
