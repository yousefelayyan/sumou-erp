import os
ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
import glob
parts=[f"-- #################### {f.split('/')[-1]} ####################\n"+open(f,encoding='utf-8').read() for f in sorted(glob.glob(ROOT+'/sql/[0-9][0-9]_*.sql'))]
hdr="""-- =====================================================================
--  نظام السمو ERP — ملف واحد فيه كل المراحل
--  الصقه كامل بـ Supabase ← SQL Editor ← New query ← Run
--  آمن للتشغيل أكثر من مرة، وما بيمسح أي بيانات موجودة.
-- =====================================================================
"""
open(ROOT+'/sql/ALL_IN_ONE.sql','w',encoding='utf-8').write(hdr+'\n\n'.join(parts))
