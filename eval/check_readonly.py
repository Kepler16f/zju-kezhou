#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""eval/check_readonly.py — 只读红线机械护栏（CI 用）。

对 compass_app/lib/ 与 engine/ 做全文检索，禁止出现任何教务写操作接口路径：
  - xkBcZyZzxkYzb  选课提交（含 zzxkyzbjk_ 前缀变体）
  - tuikBcZzxkYzb  退课
  - xkBcZypx       选课批次刷新
  - cxXkTitleMsg   写链路前置探针（登记在案：不得进入任何代码路径）

写接口名单与合规口径登记于 docs/选课模块接入说明.md；本脚本是「仅只读」对外承诺的
机械证据：分析错误与越界改动都会在此拦下。退出码：命中任一 -> 1（CI 失败）。
"""
from __future__ import annotations

import pathlib
import sys

WRITE_MARKERS = ["xkBcZyZzxkYzb", "tuikBcZzxkYzb", "xkBcZypx", "cxXkTitleMsg"]


def _scan(path: pathlib.Path, hits: list[str]) -> None:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return
    for marker in WRITE_MARKERS:
        if marker in text:
            hits.append(f"{path}: 命中写接口标记 {marker}")


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent
    targets = [root / "compass_app" / "lib", root / "engine"]
    hits: list[str] = []
    for target in targets:
        if not target.exists():
            continue
        for pattern in ("*.dart", "*.py"):
            for f in target.rglob(pattern):
                _scan(f, hits)
    if hits:
        print("只读红线被触碰：检测到教务写接口路径引用（名单见 docs/选课模块接入说明.md）")
        for h in hits:
            print("  " + h)
        return 1
    print("只读红线通过：lib/ 与 engine/ 未出现任何教务写接口路径")
    return 0


if __name__ == "__main__":
    sys.exit(main())
