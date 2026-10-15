import yaml
import sys

for f in ['.github/workflows/build-hap.yml', '.github/workflows/build-all.yml']:
    try:
        with open(f, encoding='utf-8') as fh:
            d = yaml.safe_load(fh)
        print('%-40s YAML OK   jobs=%s' % (f, list((d.get('jobs') or {}).keys())))
    except Exception as e:
        print('%-40s YAML INVALID' % f)
        print('    %s' % str(e).replace('\n', '\n    ')[:900])
