"""校验所有 workflow：YAML 合法 + 每个 upload-artifact 步骤都设了 if-no-files-found: error。"""
import glob
import sys

import yaml

ok = True
for f in sorted(glob.glob('.github/workflows/*.yml')):
    try:
        d = yaml.safe_load(open(f, encoding='utf-8'))
    except Exception as e:
        ok = False
        print('%-30s YAML INVALID: %s' % (f.split('/')[-1], e))
        continue
    uploads = []
    for jname, job in (d.get('jobs') or {}).items():
        for s in (job.get('steps') or []):
            if isinstance(s, dict) and 'upload-artifact' in str(s.get('uses', '')):
                uploads.append(s)
    missing = [u for u in uploads if (u.get('with') or {}).get('if-no-files-found') != 'error']
    if missing:
        ok = False
        print('%-30s %d upload(s) WITHOUT if-no-files-found=error' % (f.split('/')[-1], len(missing)))
    else:
        print('%-30s OK  jobs=%d uploads=%d (all error-on-empty)' % (
            f.split('/')[-1], len(d.get('jobs') or {}), len(uploads)))
sys.exit(0 if ok else 1)
