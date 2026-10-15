# -*- coding: utf-8 -*-
"""engine.adapters — 三源数据适配器：粘贴 / 教务导出CSV / 接口payload → 统一 Record Schema
纯 stdlib。Dify Code 节点入口：main(record_text, csv_rows, action='record')
"""
import csv
import io
import re

# 粘贴行格式（宽容）：学期 [课程代码] 名称 学分 [成绩]
LINE_RE = re.compile(
    r"^(?P<sem>20\d{2}-[AB])\s+(?P<rest>.+)$", re.M)
NUM_TAIL = re.compile(r"\s+(?P<c>\d+(?:\.\d+)?)\s+(?P<g>\d+(?:\.\d+)?)$")
ID_HEAD = re.compile(r"^(?P<id>[A-Z]{2,4}\d{3,6})\s+(?P<name>.+)$")

# 教务导出 CSV 列名映射（C 拿到真实样例后改这里即可，引擎零改动）
COLMAP = {
    "课程名称": "name", "课程名": "name", "name": "name",
    "学分": "credits", "成绩": "grade", "score": "grade",
    "开课学期": "semester", "学期": "semester", "修读学期": "semester",
    "课程代码": "course_id", "课程编号": "course_id",
}


def _norm_sem(v):
    v = str(v).strip().replace("—", "-").replace("－", "-")
    m = re.match(r"^(20\d{2})[-/年]?(秋|春|A|B|1|2)", v)
    if m:
        term = {"秋": "A", "A": "A", "1": "A", "春": "B", "B": "B", "2": "B"}[m.group(2)]
        return "%s-%s" % (m.group(1), term)
    if re.match(r"^20\d{2}-[AB]$", v):
        return v
    return None


def parse_paste(text):
    """学生粘贴成绩页 → courses 列表；解析失败行返回给调用方交 LLM 兜底（仅转格式，不算数）。"""
    courses, failed = [], []
    for raw in (text or "").splitlines():
        line = raw.strip()
        if not line:
            continue
        m = LINE_RE.match(line)
        if not m:
            failed.append(line)
            continue
        sem = _norm_sem(m.group("sem"))
        rest = m.group("rest").strip()
        g = None
        c = None
        nm = NUM_TAIL.search(rest)
        if nm:
            c = float(nm.group("c"))
            g = float(nm.group("g"))
            rest = rest[:nm.start()].strip()
        else:
            nm2 = re.search(r"\s+(\d+(?:\.\d+)?)$", rest)
            if nm2:
                c = float(nm2.group(1))
                rest = rest[:nm2.start()].strip()
        idm = ID_HEAD.match(rest)
        cid = idm.group("id") if idm else None
        name = idm.group("name") if idm else rest
        if not name or c is None or not sem:
            failed.append(line)
            continue
        courses.append({"course_id": cid, "name": name.strip(), "credits": c,
                        "grade": g, "passed": None if g is None else g >= 60,
                        "semester": sem})
    return courses, failed


def parse_export_csv(rows):
    """教务导出表（list[list] 含表头，或 CSV 字符串）→ courses 列表。"""
    if isinstance(rows, str):
        rows = list(csv.reader(io.StringIO(rows)))
    if not rows:
        return [], []
    header = [h.strip() for h in rows[0]]
    idx = {}
    for i, h in enumerate(header):
        if h in COLMAP:
            idx[COLMAP[h]] = i
    courses, failed = [], []
    for row in rows[1:]:
        try:
            name = row[idx["name"]].strip()
            credits = float(row[idx["credits"]])
            sem = _norm_sem(row[idx["semester"]]) if "semester" in idx else None
            grade = float(row[idx["grade"]]) if "grade" in idx and row[idx["grade"]] else None
            cid = row[idx["course_id"]].strip() if "course_id" in idx else None
        except (KeyError, IndexError, ValueError):
            failed.append(row)
            continue
        if not name or credits <= 0 or not sem:
            failed.append(row)
            continue
        courses.append({"course_id": cid or None, "name": name, "credits": credits,
                        "grade": grade, "passed": None if grade is None else grade >= 60,
                        "semester": sem})
    return courses, failed


def build_record(student, source, courses, planned=None, extra_warnings=None):
    """组装统一 Record（student 字段最小化：alias/major/grade/current_semester）。"""
    rec = {"student": student, "source": source, "courses": courses}
    if planned:
        rec["planned"] = planned
    if extra_warnings:
        rec["parse_warnings"] = extra_warnings
    return rec


def main(record_text="", csv_rows=None, student_json="{}", action="record"):
    """Dify Code 节点入口：自动嗅探输入形态 → 统一 Record Schema JSON。
    嗅探：csv_rows 非空→导出表；文本含逗号且首行含表头词→CSV；否则→粘贴。"""
    import json
    student = json.loads(student_json) if isinstance(student_json, str) else student_json
    if csv_rows:
        courses, failed = parse_export_csv(csv_rows)
        source = "export_csv"
    elif record_text and ("," in record_text and re.search(r"课程|成绩|学分", record_text.splitlines()[0])):
        courses, failed = parse_export_csv(record_text)
        source = "export_csv"
    else:
        courses, failed = parse_paste(record_text)
        source = "paste"
    if not courses:
        return {"error": "未能从输入解析出任何成绩记录。请按『学期 课程代码 课程名 学分 成绩』每行一门课重新粘贴，或上传教务导出表。",
                "unparsed": failed[:5]}
    rec = build_record(student, source, courses)
    if failed:
        rec["parse_warnings"] = ["以下 %d 行未识别，已忽略（如确属已修课程请单独补录）：%s"
                                 % (len(failed), " | ".join(str(f) for f in failed[:3]))]
    return {"record_json": json.dumps(rec, ensure_ascii=False)}
