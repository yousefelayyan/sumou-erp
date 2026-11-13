#!/usr/bin/env python3
"""استخراج نصوص الواجهة العربية من docs/*.js لملف dev/i18n/ar.txt (سطر لكل نص)، مع الحفاظ على ترتيب المترجم الموجود.
   النص الجديد بينضاف بالآخر، والترجمة بـ dev/i18n/en.txt بنفس رقم السطر. بعدها: python3 dev/i18n_build.py"""
import re, glob, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AR = re.compile(r'[؀-ۿ]')
EDGE = ' \t:•·—–-*()،.؟?!«»"\'/|,;؛✓✔⚠️…'
def norm(p):
    p = re.sub(r'\s+', ' ', p).strip(EDGE).strip()
    return p
segs = []
seen = set()
def add(p):
    p = norm(p)
    if p and AR.search(p) and len(p) < 160 and '${' not in p and p not in seen:
        seen.add(p); segs.append(p)
files = sorted(glob.glob(os.path.join(ROOT, 'docs', '*.js'))) + [os.path.join(ROOT, 'docs', 'index.html')]
for f in files:
    s = open(f, encoding='utf-8').read()
    s = re.sub(r'^\s*//.*$', '', s, flags=re.M)          # تعليقات السطر
    for m in re.finditer(r'(?:placeholder|title|aria-label|label)="([^"$]*)"', s): add(m.group(1))
    for m in re.finditer(r"'((?:[^'\\\n]|\\.)*)'|\"((?:[^\"\\\n]|\\.)*)\"|`((?:[^`\\]|\\.)*)`", s, re.S):
        t = m.group(1) or m.group(2) or m.group(3) or ''
        t = re.sub(r'\$\{(?:[^{}]|\{[^{}]*\})*\}', '\x00', t)   # ${...}
        for part in re.split(r'<[^>]*>|\x00|\\n|\n', t):
            add(part)
            for sub in re.split(r'\s[—–]\s|:\s', part): add(sub)
# رسائل قاعدة البيانات الثابتة (raise exception بدون %)
for f in sorted(glob.glob(os.path.join(ROOT, 'sql', '[0-9]*.sql'))):
    for m in re.finditer(r"raise exception '((?:[^']|'')*)'", open(f, encoding='utf-8').read()):
        t = m.group(1).replace("''", "'")
        if '%' not in t: add(t)
path = os.path.join(ROOT, 'dev', 'i18n', 'ar.txt')
old = open(path, encoding='utf-8').read().split('\n') if os.path.exists(path) else []
old = [x for x in old if x]
oldset = set(old)
new = old + [x for x in segs if x not in oldset]
open(path, 'w', encoding='utf-8').write('\n'.join(new) + '\n')
print('total', len(new), 'new', len(new) - len(old))
