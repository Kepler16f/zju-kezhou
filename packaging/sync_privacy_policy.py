#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""改完 docs/隐私政策.md 后跑这个：同步随包正文 + 重算并写入 kConsentPolicySha。

用法（在仓库根目录）：
    python packaging/sync_privacy_policy.py

三件事：
  1. docs/隐私政策.md → compass_app/assets/privacy_policy.md（逐字节复制）
  2. 计算 sha256，更新 compass_app/lib/data/consent_store.dart 的 kConsentPolicySha
     （含其上方注释里的完整 sha256）
  3. 自检：两份文件是否一致、常量是否等于实际摘要
"""
import hashlib
import pathlib
import re
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / 'docs' / '隐私政策.md'
DST = ROOT / 'compass_app' / 'assets' / 'privacy_policy.md'
STORE = ROOT / 'compass_app' / 'lib' / 'data' / 'consent_store.dart'


def main() -> int:
    if not SRC.exists():
        print(f'缺少 {SRC}')
        return 1
    shutil.copyfile(SRC, DST)
    digest = hashlib.sha256(DST.read_bytes()).hexdigest()
    short = digest[:12]

    text = STORE.read_text(encoding='utf-8')
    new_text, n = re.subn(
        r"(const String kConsentPolicySha = ')[0-9a-f]+(';)",
        lambda m: m.group(1) + short + m.group(2),
        text)
    new_text = re.sub(r"///   sha256 = [0-9a-f]+",
                      f"///   sha256 = {digest}", new_text)
    if n == 0:
        print('未找到 kConsentPolicySha 常量，请检查 consent_store.dart')
        return 1
    STORE.write_text(new_text, encoding='utf-8', newline='\n')

    ok = DST.read_bytes() == SRC.read_bytes()
    print(f'随包正文已同步：{DST.relative_to(ROOT)}')
    print(f'kConsentPolicySha = {short}（完整 sha256: {digest}）')
    print(f'两份正文一致：{ok}')
    if not ok:
        return 1
    print('提醒：正文变更后需重新构建应用（同意记录的 policySha 与随包正文对应）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
