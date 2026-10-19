#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""查老师（dahua309.uk）教师评分抓取器 —— 可替换数据源适配层。

设计约束（对齐用户需求「留出接口，站点可能被封、以后方便替换」）：
  1. 站点耦合（域名、页面结构、评分量表）全部集中在本文件的「配置区」与
     parse_teacher_page()。将来换源/换域名只改这里，产物 JSON 契约不变。
  2. 产物是 App 侧统一的 assets/data/teacher_ratings.json：
       {"教师名": {"avg": 0-10, "count": int, "tags": [], "source": "查老师"}}
     站点本身就是十分制（实测 9.39/10、高分榜 9.95），直取不折算，零精度损失。
  3. 只用 Python 标准库（urllib），零第三方依赖；不写进 App 运行期（红线：
     App 侧评分永远只读本地表，绝不在运行时联网）。
  4. 反封禁纪律：限速、失败退避、可断点续传（--ids 指定子集），单次抓取量可控。

用法示例：
  # 只抓指定教师 ID（小样本、最稳）
  python tool/chalaoshi_fetch.py --ids 1,8,893,2006 --out compass_app/assets/data/teacher_ratings.json
  # 从首页发现 /t/<id>/ 链接批量抓（受 --limit 与 --delay 约束）
  python tool/chalaoshi_fetch.py --discover --limit 200 --delay 1.5 --out ...
  # 干跑：只打印不发请求（验证 URL/解析逻辑）
  python tool/chalaoshi_fetch.py --ids 1 --dry-run

注意：--out 默认覆盖既有文件；工具会把已存在的本地条目合并保留（新抓的覆盖同名），
便于分多次、分学院累积，不会因为封禁丢已有数据。
"""
import argparse
import concurrent.futures
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

# ── 配置区（换源时只改这一段）────────────────────────────────────────────
BASE_URL = "https://dahua309.uk"          # 站点根（可能变更/被封时改这里）
SOURCE_NAME = "查老师"                      # 写入产物 source 字段与统一口径
SCORE_MAX = 10.0                            # 站点原生十分制（实测 9.39/10、9.95 榜）
UA = "Mozilla/5.0 (compatible; KeZhou/1.0; personal offline course rating mirror)"
TIMEOUT = 20
DEFAULT_DELAY = 1.2                         # 每次请求间隔（秒），防高频触发风控
# 教师页标题锚点：「毕惟红老师 9.39分 422人打分 - 查老师」
TITLE_RE = re.compile(r"<title>\s*(.+?)老师\s*([0-9]+(?:\.[0-9]+)?)分\s*([0-9]+)人打分")
# 发现链接锚点：/t/<数字>/
LINK_RE = re.compile(r"/t/(\d+)/")
# ── /配置区 ──────────────────────────────────────────────────────────────


def fetch(url, *, timeout=TIMEOUT):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        charset = resp.headers.get_content_charset() or "utf-8"
        return resp.read().decode(charset, errors="replace")


def clamp_score(raw):
    """十分制直取（站点原生口径）：越界/非数返回 None（宁缺勿猜）。"""
    try:
        v = float(raw)
    except (TypeError, ValueError):
        return None
    if v < 0 or v > SCORE_MAX:
        return None
    return round(v, 2)


def parse_teacher_page(html):
    """从教师详情页 HTML 解析 (teacher_name, score_10pt, count)；不匹配返回 None。"""
    m = TITLE_RE.search(html or "")
    if not m:
        return None
    name = m.group(1).strip()
    score = clamp_score(m.group(2))
    if not name or score is None:
        return None
    try:
        count = int(m.group(3))
    except (TypeError, ValueError):
        count = 0
    return name, score, count


def build_entry(name, score, count):
    return {"avg": score, "count": count, "tags": [], "source": SOURCE_NAME}


def discover_ids(page_html, limit):
    ids, seen = [], set()
    for tid in LINK_RE.findall(page_html or ""):
        if tid not in seen:
            seen.add(tid)
            ids.append(tid)
        if len(ids) >= limit:
            break
    return ids


def load_existing(out_path):
    """保留已有本地条目（分次累积、封禁不丢数据）。"""
    if not out_path or not os.path.exists(out_path):
        return {}
    try:
        with open(out_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return {
                k: v
                for k, v in data.items()
                if not str(k).startswith("_") and isinstance(v, dict)
            }
    except (json.JSONDecodeError, OSError):
        pass
    return {}


def scrape_one(tid, *, base=BASE_URL, dry=False, timeout=TIMEOUT):
    url = f"{base}/t/{tid}/"
    if dry:
        return tid, {"dry_run_url": url}, None
    try:
        html = fetch(url, timeout=timeout)
    except (urllib.error.URLError, urllib.error.HTTPError, OSError) as e:
        return tid, None, str(e)
    parsed = parse_teacher_page(html)
    if parsed is None:
        return tid, None, "title parse miss"
    name, score, count = parsed
    return tid, {name: build_entry(name, score, count)}, None


def main(argv=None):
    ap = argparse.ArgumentParser(description="查老师评分抓取器（可替换数据源适配层）")
    ap.add_argument("--ids", help="逗号分隔的教师 ID 子集，如 1,8,893")
    ap.add_argument("--discover", action="store_true", help="从首页发现 /t/<id>/ 链接")
    ap.add_argument("--limit", type=int, default=100, help="发现模式最多抓多少门")
    ap.add_argument("--delay", type=float, default=DEFAULT_DELAY, help="请求间隔秒")
    ap.add_argument("--timeout", type=float, default=TIMEOUT)
    ap.add_argument("--base", default=BASE_URL, help="覆盖站点根（换域名/镜像时）")
    ap.add_argument("--out", default="compass_app/assets/data/teacher_ratings.json")
    ap.add_argument("--dry-run", action="store_true", help="只打印 URL，不发请求")
    ap.add_argument("--workers", type=int, default=1, help="并发度（默认串行保限速）")
    args = ap.parse_args(argv)

    if args.discover:
        try:
            home = fetch(f"{args.base}/", timeout=args.timeout)
        except Exception as e:  # noqa: BLE001 - 发现失败即终止，保留已有产物
            print(f"发现失败：{e}", file=sys.stderr)
            return 2
        ids = discover_ids(home, args.limit)
    elif args.ids:
        ids = [s.strip() for s in args.ids.split(",") if s.strip()]
    else:
        print("需指定 --ids 或 --discover", file=sys.stderr)
        return 2

    merged = load_existing(args.out)
    ok, miss = 0, 0

    def handle(tid):
        nonlocal ok, miss
        res, entry, err = scrape_one(tid, base=args.base, dry=args.dry_run, timeout=args.timeout)
        if err:
            miss += 1
            if not args.dry_run:
                print(f"  id={tid} 失败：{err}", file=sys.stderr)
            return
        if entry:
            merged.update(entry)
            ok += 1

    if args.workers > 1 and not args.dry_run:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as ex:
            for tid in ids:
                ex.submit(handle, tid)
                time.sleep(args.delay)  # 仍按 delay 投放，避免瞬发
    else:
        for i, tid in enumerate(ids):
            handle(tid)
            if not args.dry_run and i < len(ids) - 1:
                time.sleep(args.delay)

    out_path = args.out if not args.dry_run else None
    if out_path:
        payload = {
            "_schema": {"avg": "0-10（站点原生十分制，直取不折算）",
                        "count": "打分人数", "tags": "标签（预留，站点未提供）",
                        "source": "数据源名，固定「查老师」"},
            "_generator": "tool/chalaoshi_fetch.py",
            "_score_max": SCORE_MAX,
            **merged,
        }
        os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        print(f"写入 {out_path}：命中 {ok}、失 {miss}，累计 {len(merged)} 位教师")
    else:
        print(f"dry-run：计划抓 {len(ids)} 个，命中(可解析){ok}，失败{miss}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
