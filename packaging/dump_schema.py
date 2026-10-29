#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""打印 hvigor 配置 schema 里与 signingConfig 相关的片段 + 扫描 SDK 内的签名工具。

用法：python3 packaging/dump_schema.py <sdk_home>
"""
from __future__ import annotations

import os
import re
import sys


def walk(root: str):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ('.git', 'node_modules')]
        for fn in filenames:
            yield os.path.join(dirpath, fn)


def main() -> int:
    root = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('HOS_SDK_HOME', '')
    print('=== SDK 顶层 ===')
    try:
        for name in sorted(os.listdir(root)):
            print('  ', name)
    except Exception as e:
        print('  读取失败:', e)

    schemas = []
    signs = []
    for p in walk(root):
        low = p.lower()
        if 'schema' in low and low.endswith('.json'):
            schemas.append(p)
        if 'sign' in low and low.endswith(('.jar', '.py', '.js', '.sh', '.ts')):
            signs.append(p)

    print('\n=== schema 文件 ===')
    for s in schemas[:20]:
        print('  ', s)

    print('\n=== 签名相关文件 ===')
    for s in signs[:25]:
        print('  ', s)

    print('\n=== schema 中的 signingConfig 片段 ===')
    for f in schemas[:6]:
        try:
            text = open(f, encoding='utf-8', errors='replace').read()
        except Exception:
            continue
        if 'signingConfig' not in text:
            continue
        print(f'--- {f}')
        for m in list(re.finditer(r'[Ss]igning[Cc]onfigs?', text))[:5]:
            i = m.start()
            print(text[max(0, i - 200):i + 700].replace('\n', ' ')[:900])
            print('   ---')
    return 0


if __name__ == '__main__':
    sys.exit(main())
