# -*- coding: utf-8 -*-
"""data/sync_assets.py — golden/samples 双侧同步：data/{golden,samples} ↔ compass_app/assets/。
用法：
  python data/sync_assets.py           # 执行同步（以 data/ 为准覆盖 assets/）
  python data/sync_assets.py --check   # 仅校验（CI 用，不一致即退出码 1）
"""
import filecmp
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAIRS = [
    (os.path.join(ROOT, "data", "golden"), os.path.join(ROOT, "compass_app", "assets", "golden")),
    (os.path.join(ROOT, "data", "samples"), os.path.join(ROOT, "compass_app", "assets", "samples")),
]
COPY_ONLY = {"demo1_cs_full.json", "demo3_se_full.json", "demo1_cs_paste.txt", "demo2_se_export.csv"}


def main():
    check = "--check" in sys.argv
    drift = []
    for src, dst in PAIRS:
        for f in sorted(os.listdir(src)):
            if not f.endswith((".json", ".txt", ".csv")) or f.startswith("raw_"):
                continue
            if "samples" in src and f not in COPY_ONLY:
                continue
            s, d = os.path.join(src, f), os.path.join(dst, f)
            if not os.path.exists(d) or not filecmp.cmp(s, d, shallow=False):
                drift.append("%s ↔ %s" % (os.path.relpath(s, ROOT), os.path.relpath(d, ROOT)))
                if not check:
                    os.makedirs(dst, exist_ok=True)
                    shutil.copyfile(s, d)
                    print("synced:", os.path.relpath(d, ROOT))
    if check and drift:
        print("❌ 双侧漂移（跑 python data/sync_assets.py 同步）：")
        for x in drift:
            print("  ", x)
        sys.exit(1)
    if not drift:
        print("✅ golden/samples 双侧一致" if check else "同步完成，无变更")


if __name__ == "__main__":
    main()
