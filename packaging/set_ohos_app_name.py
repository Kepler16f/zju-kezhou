#!/usr/bin/env python3
"""set_ohos_app_name.py — 把鸿蒙脚手架的桌面显示名改为「课舟」。

用法：python packaging/set_ohos_app_name.py <ohos目录>，默认中文名称=课舟、
英文名称=KeZhou（en_US 覆盖目录用英文，桌面语言为英文时不出现半中半英）。

背景（LIVE 实测教训）：flutter create --platforms ohos 的模板里，
桌面图标标签取 module.json5 → "$string:EntryAbility_label"，而 entry 资源有
base / en_US / zh_CN 三份 string.json 都定义了它（值=工程名 compass_app）。
鸿蒙按设备语言做资源覆盖：中文系统优先读 zh_CN——只改 base 的那次修复不彻底，
手机装上仍显示 compass。本脚本因此遍历全部 element/string.json：
  AppScope/resources/**/element/string.json        → app_name
  entry/src/main/resources/**/element/string.json  → EntryAbility_label / entry_label
  entry/src/ohosTest/resources/**/...              → 跳过（测试模块，不上桌面）
幂等：重复执行不改变结果。
"""
import glob
import io
import json
import os
import sys

TARGET_KEYS = ('app_name', 'EntryAbility_label', 'entry_label', 'main_ability_label')

# base/zh_CN 用中文名；en_US 用英文名（与 Windows ProductName 的罗马音一致）。
ZH_NAME = '课舟'
EN_NAME = 'KeZhou'


def patch(path, name):
    if not os.path.isfile(path):
        print('skip (missing): %s' % path)
        return
    with io.open(path, encoding='utf-8') as fh:
        data = json.load(fh)
    items = data.get('string')
    if not isinstance(items, list):
        print('%s -> 结构异常（string 不是列表），跳过' % path)
        return
    changed = []
    for item in items:
        if not isinstance(item, dict):
            continue
        if item.get('name') in TARGET_KEYS and item.get('value') != name:
            item['value'] = name
            changed.append(item['name'])
    if changed:
        with io.open(path, 'w', encoding='utf-8', newline='\n') as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
            fh.write('\n')
        print('%s -> 更新 %s (%s)' % (path, ', '.join(changed), name))
    else:
        print('%s -> 无需改动' % path)


def main():
    if len(sys.argv) < 2:
        sys.exit('用法：python packaging/set_ohos_app_name.py <ohos目录>')
    root = sys.argv[1]
    patterns = [
        os.path.join(root, 'AppScope', 'resources', '*', 'element', 'string.json'),
        os.path.join(root, 'entry', 'src', 'main', 'resources', '*', 'element',
                     'string.json'),
    ]
    hits = 0
    for pat in patterns:
        for path in sorted(glob.glob(pat)):
            # .../resources/<语言>/element/string.json → 上两级目录名是语言目录
            lang_dir = os.path.basename(os.path.dirname(os.path.dirname(path)))
            name = EN_NAME if lang_dir.lower().startswith('en') else ZH_NAME
            patch(path, name)
            hits += 1
    if hits == 0:
        sys.exit('未找到任何 string.json（检查 ohos 目录：%s）' % root)


if __name__ == '__main__':
    main()
