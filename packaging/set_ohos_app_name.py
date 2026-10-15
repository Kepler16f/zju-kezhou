#!/usr/bin/env python3
"""set_ohos_app_name.py — 把鸿蒙脚手架的桌面显示名改为「课舟」。

用法：python packaging/set_ohos_app_name.py <ohos目录> [名称]，默认名称=课舟。

背景：`flutter create --platforms ohos` 生成的 string.json 里
  AppScope/resources/base/element/string.json → app_name（应用级显示名）
  entry/src/main/resources/base/element/string.json → EntryAbility_label（入口 Ability 标签）
两处都默认是工程名（compass_app），装着就是英文名；本脚本把这两处改中文，
其余资源（权限说明等）保持原样。幂等：重复执行不改变结果。
"""
import io
import json
import os
import sys

TARGET_KEYS = ('app_name', 'EntryAbility_label', 'entry_label', 'main_ability_label')


def patch(path, name):
    if not os.path.isfile(path):
        print('skip (missing): %s' % path)
        return
    with io.open(path, encoding='utf-8') as fh:
        data = json.load(fh)
    changed = []
    for item in data.get('string', []):
        if item.get('name') in TARGET_KEYS and item.get('value') != name:
            item['value'] = name
            changed.append(item['name'])
    if changed:
        with io.open(path, 'w', encoding='utf-8', newline='\n') as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
            fh.write('\n')
        print('%s -> 更新 %s' % (path, ', '.join(changed)))
    else:
        print('%s -> 无需改动' % path)


def main():
    if len(sys.argv) < 2:
        sys.exit('用法：python packaging/set_ohos_app_name.py <ohos目录> [名称]')
    root = sys.argv[1]
    name = sys.argv[2] if len(sys.argv) > 2 else '课舟'
    patch(os.path.join(root, 'AppScope', 'resources', 'base', 'element', 'string.json'), name)
    patch(os.path.join(root, 'entry', 'src', 'main', 'resources', 'base', 'element', 'string.json'), name)


if __name__ == '__main__':
    main()
