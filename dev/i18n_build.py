#!/usr/bin/env python3
"""بناء docs/i18n/en.js من dev/i18n/ar.txt و dev/i18n/en.txt (نفس رقم السطر). السطر الفاضي بالإنجليزي = بدون ترجمة."""
import json, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ar = open(os.path.join(ROOT, 'dev/i18n/ar.txt'), encoding='utf-8').read().split('\n')
en = open(os.path.join(ROOT, 'dev/i18n/en.txt'), encoding='utf-8').read().split('\n') if os.path.exists(os.path.join(ROOT, 'dev/i18n/en.txt')) else []
d = {}
for i, a in enumerate(ar):
    if a and i < len(en) and en[i].strip(): d[a] = en[i].strip()
ex = os.path.join(ROOT, 'dev/i18n/extra.tsv')
if os.path.exists(ex):
    for line in open(ex, encoding='utf-8'):
        if '\t' in line:
            a, e = line.rstrip('\n').split('\t', 1)
            if a.strip() and e.strip(): d[a.strip()] = e.strip()
os.makedirs(os.path.join(ROOT, 'docs/i18n'), exist_ok=True)
open(os.path.join(ROOT, 'docs/i18n/en.js'), 'w', encoding='utf-8').write(
  '// مولّد من dev/i18n_build.py — لا تعدّله بإيدك\nexport default ' + json.dumps(d, ensure_ascii=False, separators=(',', ':')) + ';\n')
missing = [a for i, a in enumerate(ar) if a and not (i < len(en) and en[i].strip())]
print('translated', len(d), 'missing', len(missing))
