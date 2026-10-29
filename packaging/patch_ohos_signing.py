#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把签名材料注入鸿蒙工程的 build-profile.json5（供 CI 构建期签名）。

用法：
    python3 packaging/patch_ohos_signing.py <ohos_dir> <p12> <cer> <p7b> <alias> <password>

原理：
  * 鸿蒙工程用 hvigor 的 signingConfigs 描述密钥库，products[].signingConfig 指向它；
    flutter build hap 时 hvigor 用该配置对包签名，产物即为已签名 .hap。
  * build-profile.json5 是 JSON5（可能带注释），因此这里做**文本级**精确改写，
    不做 JSON 解析，避免注释/尾逗号导致的解析失败。
  * 幂等：重复执行结果一致（先摘除旧的 signingConfigs 块，再写入新的）。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


def build_block(alias: str, password: str) -> str:
    return (
        '  "signingConfigs": [\n'
        '    {\n'
        '      "name": "kezhou_release",\n'
        '      "type": "local",\n'
        '      "material": {\n'
        '        "storeFile": "kezhou_sign.p12",\n'
        f'        "storePassword": "{password}",\n'
        f'        "keyAlias": "{alias}",\n'
        f'        "keyPassword": "{password}",\n'
        '        "signAlg": "SHA256withECDSA",\n'
        '        "profile": "kezhou_sign.p7b",\n'
        '        "certpath": "kezhou_sign.cer"\n'
        '      }\n'
        '    }\n'
        '  ],\n'
    )


def strip_existing(text: str) -> str:
    """去掉已有的 signingConfigs 块（不管内容是 [] 还是完整块）。"""
    m = re.search(r'[ \t]*"signingConfigs"\s*:\s*\[', text)
    if not m:
        return text
    i = m.start()
    depth = 0
    j = m.end() - 1  # 指向 '['
    while j < len(text):
        if text[j] == '[':
            depth += 1
        elif text[j] == ']':
            depth -= 1
            if depth == 0:
                j += 1
                break
        j += 1
    # 连同尾随逗号与换行一起吃掉
    k = j
    while k < len(text) and text[k] in ' \t':
        k += 1
    if k < len(text) and text[k] == ',':
        k += 1
    while k < len(text) and text[k] in ' \r\n':
        k += 1
    return text[:i] + text[k:]


def main() -> int:
    if len(sys.argv) != 7:
        print(__doc__)
        return 2
    ohos = Path(sys.argv[1])
    p12, cer, p7b, alias, password = sys.argv[2:7]
    for p in (p12, cer, p7b):
        if not Path(p).exists():
            print(f'签名材料缺失：{p}')
            return 1
    profile = ohos / 'build-profile.json5'
    if not profile.exists():
        print(f'找不到 {profile}')
        return 1

    text = profile.read_text(encoding='utf-8')
    text = strip_existing(text)

    # 在 "app": { 之后插入 signingConfigs
    m = re.search(r'("app"\s*:\s*\{)', text)
    if not m:
        print('build-profile.json5 里找不到 "app" 对象')
        return 1
    text = text[: m.end()] + '\n' + build_block(alias, password) + text[m.end():]

    # products[].signingConfig 指向我们的配置
    if re.search(r'"signingConfig"\s*:\s*"[^"]*"', text):
        text = re.sub(r'"signingConfig"\s*:\s*"[^"]*"',
                      '"signingConfig": "kezhou_release"', text, count=1)
    else:
        text = re.sub(r'("name"\s*:\s*"default"\s*,)',
                      r'\1\n        "signingConfig": "kezhou_release",', text, count=1)

    profile.write_text(text, encoding='utf-8')
    print('build-profile.json5 已注入签名配置：kezhou_release')
    for line in text.splitlines():
        if 'signingConfig' in line or 'storeFile' in line or 'profile' in line or 'certpath' in line:
            print('  ' + line.strip())
    return 0


if __name__ == '__main__':
    sys.exit(main())
