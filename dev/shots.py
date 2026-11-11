import asyncio, subprocess, time, sys, shutil, os, re
HERE=os.path.dirname(os.path.abspath(__file__)); src=os.path.join(os.path.dirname(HERE),'docs'); dst='/tmp/ui'
shutil.rmtree(dst,ignore_errors=True); shutil.copytree(src,dst); shutil.copy(os.path.join(HERE,'mock.js'),dst)
c=open(dst+'/core.js',encoding='utf-8').read().replace('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm','./mock.js'); open(dst+'/core.js','w',encoding='utf-8').write(c)
h=re.sub(r'<link href="https://fonts.googleapis.com[^>]*>','',open(dst+'/index.html',encoding='utf-8').read()); open(dst+'/index.html','w',encoding='utf-8').write(h)
from playwright.async_api import async_playwright
srv=subprocess.Popen(['python3','-m','http.server','8766','-d',dst],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); time.sleep(1)
routes=sys.argv[1:]
async def main():
  async with async_playwright() as p:
    b=await p.chromium.launch(); pg=await b.new_page(viewport={'width':1400,'height':900})
    errs=[]; pg.on('pageerror',lambda e:errs.append(str(e))); pg.on('console',lambda m: m.type=='error' and errs.append(m.text))
    for r in routes:
      name,_,action=r.partition('@')
      await pg.goto('about:blank'); await pg.goto(f'http://localhost:8766/index.html#/{name}'); await pg.wait_for_timeout(800)
      if action: await pg.click(action); await pg.wait_for_timeout(600)
      await pg.screenshot(path=f'/tmp/v_{re.sub(r"[^a-z0-9]","_",r)}.png')
    print('errors:',errs); await b.close()
asyncio.run(main()); srv.kill()
