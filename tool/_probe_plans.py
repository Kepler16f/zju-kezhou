# -*- coding: utf-8 -*-
import json, sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
for f in [r'/d/compass/compass_app/assets/golden/computer_science.json',
          r'/d/compass/compass_app/assets/golden/software_engineering.json']:
    d = json.load(open(f, encoding='utf-8'))
    print('=====', f)
    print('top keys:', list(d.keys()))
    print('meta keys:', list(d.get('meta', {}).keys()))
    mods = d.get('modules', [])
    print('modules:', len(mods))
    for m in mods:
        print('  -', m.get('module_id'), '| path:', repr(m.get('module_path')), '| req:', m.get('required_credits'),
              '| keys:', sorted(k for k in m.keys()))
