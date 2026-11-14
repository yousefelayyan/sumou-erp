#!/usr/bin/env python3
"""فحص الترجمة: بيفتح شاشات البرنامج (بالقاعدة الوهمية) بالإنجليزي وبيطبع النصوص العربية اللي ما إلها ترجمة."""
import asyncio, subprocess, time, sys, shutil, os, re, json
HERE=os.path.dirname(os.path.abspath(__file__)); src=os.path.join(os.path.dirname(HERE),'docs'); dst='/tmp/ui_i18n'
shutil.rmtree(dst,ignore_errors=True); shutil.copytree(src,dst); shutil.copy(os.path.join(HERE,'mock.js'),dst)
c=open(dst+'/core.js',encoding='utf-8').read().replace('./lib/supabase.min.js','./mock.js'); open(dst+'/core.js','w',encoding='utf-8').write(c)
h=re.sub(r'<link href="https://fonts.googleapis.com[^>]*>','',open(dst+'/index.html',encoding='utf-8').read()); open(dst+'/index.html','w',encoding='utf-8').write(h)
from playwright.async_api import async_playwright
srv=subprocess.Popen(['python3','-m','http.server','8767','-d',dst],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); time.sleep(1)
routes=[l.strip() for l in open(os.path.join(HERE,'i18n','routes.txt')) if l.strip()]
async def main():
  miss=set()
  async with async_playwright() as p:
    b=await p.chromium.launch(); pg=await b.new_page(viewport={'width':1400,'height':900})
    await pg.goto('http://localhost:8767/index.html')
    await pg.evaluate("localStorage.setItem('sumou.lang','en'); localStorage.setItem('sumou.i18n.debug','1')")
    for r in routes:
      name,_,action=r.partition('@')
      try:
        await pg.goto('about:blank'); await pg.goto(f'http://localhost:8767/index.html#/{name}'); await pg.wait_for_timeout(900)
        for a in [x for x in action.split('@') if x]: await pg.click(a, timeout=3000); await pg.wait_for_timeout(500)
        # كمان النصوص اللي ضلّت عربي بالصفحة كلها (مش بس اللي مرّت على tr)
        txt=await pg.evaluate("""() => { const out=[]; const tw=document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          let n; while((n=tw.nextNode())){ if(/[\\u0600-\\u06FF]/.test(n.nodeValue) && !n.parentElement.closest('[data-noi18n],textarea,input,select option[value=""]')) out.push(n.nodeValue.trim()); }
          for (const el of document.querySelectorAll('[placeholder],[title]')) for (const a of ['placeholder','title']) { const v=el.getAttribute(a); if (v && /[\\u0600-\\u06FF]/.test(v)) out.push(v); }
          return [...new Set(out.concat([...(window.__i18nMissing||[])]))]; }""")
        for t in txt: miss.add((t, name))
      except Exception as e: print('ERR', r, e, file=sys.stderr)
    await b.close()
  srv.terminate()
  seen={}
  for t,r in sorted(miss):
    seen.setdefault(t, r)
  for t,r in seen.items(): print(f'{r}\t{t}')
asyncio.run(main())
