// =====================================================================
//  السمو ERP — النسخ الاحتياطي والاسترجاع + الاستيراد من إكسل
// =====================================================================
import { S, sb, esc, fmtDate, fmtDateTime, num, today, toast, arError, modal, confirmBox, can, isAdmin, log, localStorageGet, localStorageSet } from './core.js';
import { loadAccounts, leafAccounts } from './finance.js';

const stamp = () => new Date().toISOString().slice(0, 16).replace('T', '_').replace(':', '-');
const saveFile = (name, text, type = 'application/json') => { const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([text], { type })); a.download = name; a.click(); setTimeout(() => URL.revokeObjectURL(a.href), 4000); };
const safe = (s) => String(s || '').replace(/[\\/:*?"<>|]+/g, ' ').trim();

// ---------------------------------------------------------------------
//  النسخ الاحتياطي
// ---------------------------------------------------------------------
async function backupOne(c) {
  const { data, error } = await sb.rpc('backup_company', { p_company: c.id });
  if (error) throw error;
  return data;
}

// نسخة تلقائية يومية بالتخزين (بتشتغل لما المدير يفتح البرنامج، مرة باليوم)
export async function autoBackup() {
  if (!isAdmin() || !S.companies?.length || S.trial) return;   // التجربة المجانية بدون نسخ تلقائية
  const key = 'sumou.autobackup.' + S.session.user.id, day = today();
  if (localStorageGet(key) === day) return;
  localStorageSet(key, day);
  let ok = 0;
  for (const c of S.companies) {
    try {
      const data = await backupOne(c);
      const up = await sb.storage.from('backups').upload(`${c.id}/${day}.json`, new Blob([JSON.stringify(data)], { type: 'application/json' }), { upsert: true, contentType: 'application/json' });
      if (up.error) throw up.error;
      ok++;
      // نخلي آخر 30 نسخة بس
      const ls = await sb.storage.from('backups').list(c.id, { limit: 200, sortBy: { column: 'name', order: 'desc' } });
      const old = (ls.data || []).slice(30).map(f => `${c.id}/${f.name}`);
      if (old.length) await sb.storage.from('backups').remove(old);
    } catch (e) { console.warn('auto backup', c.name, e); }
  }
  if (ok) console.log(`نسخة تلقائية: ${ok} شركة`);
}


// ---------------------------------------------------------------------
//  نسخة تلقائية على مجلد بجهاز المستخدم (مثلاً قرص D) — File System Access بكروم وإيدج
//  المجلد بينحفظ مقبضه بـ IndexedDB لكل مستخدم؛ كل يوم ملف واحد لكل الشركات، وبنخلي آخر 60 ملف.
// ---------------------------------------------------------------------
const LB_PREFIX = 'نسخة السمو ERP ';
export const localBackupSupported = () => typeof window !== 'undefined' && 'showDirectoryPicker' in window;
const idb = () => new Promise((res, rej) => { const r = indexedDB.open('sumou-local-backup', 1); r.onupgradeneeded = () => r.result.createObjectStore('h'); r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
const idbDo = async (mode, fn) => { const db = await idb(); return new Promise((res, rej) => { const tx = db.transaction('h', mode), q = fn(tx.objectStore('h')); tx.oncomplete = () => res(q?.result); tx.onerror = () => rej(tx.error); }); };
const lbKey = () => 'dir.' + (S.session?.user?.id || 'x');
const getDir = () => idbDo('readonly', st => st.get(lbKey())).catch(() => null);
const setDir = (h) => idbDo('readwrite', st => h ? st.put(h, lbKey()) : st.delete(lbKey()));

async function writeLocalBackup(dir) {
  const comps = S.companies || [], out = [];
  for (const c of comps) out.push(await backupOne(c));
  const day = today(), name = `${LB_PREFIX}${day}.json`;
  const fh = await dir.getFileHandle(name, { create: true }), w = await fh.createWritable();
  await w.write(JSON.stringify({ app: 'sumou-erp', multi: true, created_at: new Date().toISOString(), companies: out })); await w.close();
  // آخر 60 نسخة بس
  const names = [];
  for await (const [n, h] of dir.entries()) if (h.kind === 'file' && n.startsWith(LB_PREFIX) && n.endsWith('.json')) names.push(n);
  names.sort().reverse().slice(60).forEach(n => dir.removeEntry(n).catch(() => {}));
  localStorageSet('sumou.localbackup.' + S.session.user.id, day);
  return { name, count: out.length };
}

let lbBar = null;
function permissionBar(dir) {
  if (lbBar) return;
  lbBar = document.createElement('div');
  lbBar.style.cssText = 'position:fixed;bottom:14px;left:14px;z-index:9999;background:var(--brand);color:#fff;padding:10px 14px;border-radius:12px;box-shadow:0 6px 20px rgba(0,0,0,.25);display:flex;gap:8px;align-items:center;font-size:14px';
  lbBar.innerHTML = `💾 النسخة اليومية على مجلد «${esc(dir.name)}» بجهازك بدها إذن <button class="btn sm" data-ok>اسمح واحفظ</button><button class="btn sm" data-x>✕</button>`;
  document.body.appendChild(lbBar);
  lbBar.querySelector('[data-x]').onclick = () => { lbBar.remove(); lbBar = null; };
  lbBar.querySelector('[data-ok]').onclick = async () => {
    try {
      if ((await dir.requestPermission({ mode: 'readwrite' })) !== 'granted') return toast('ما انعطى الإذن', 'err');
      lbBar.remove(); lbBar = null;
      const r = await writeLocalBackup(dir); toast(`✓ انحفظت النسخة على جهازك: ${r.name}`, 'ok');
    } catch (e) { toast(arError(e), 'err'); }
  };
}

export async function autoLocalBackup() {
  if (!isAdmin() || !S.companies?.length || S.trial || !localBackupSupported()) return;
  if (localStorageGet('sumou.localbackup.' + S.session.user.id) === today()) return;
  const dir = await getDir(); if (!dir) return;
  const perm = await dir.queryPermission({ mode: 'readwrite' });
  if (perm === 'granted') { try { await writeLocalBackup(dir); } catch (e) { console.warn('local backup', e); } }
  else permissionBar(dir);
}

async function localBackupCard(box) {
  if (!localBackupSupported()) { box.innerHTML = '<div class="notice">هالخاصية بتشتغل على كروم أو إيدج على الكمبيوتر بس.</div>'; return; }
  const dir = await getDir(), last = localStorageGet('sumou.localbackup.' + S.session.user.id);
  const perm = dir ? await dir.queryPermission({ mode: 'readwrite' }) : null;
  box.innerHTML = dir ? `<p style="margin-top:0">المجلد: <b>📁 ${esc(dir.name)}</b> ${perm === 'granted' ? '<span class="badge ok">مسموح</span>' : '<span class="badge warn">بدها إذن</span>'}
      ${last ? ` · آخر نسخة: ${fmtDate(last)}` : ''}</p>
      <div style="display:flex;gap:8px;flex-wrap:wrap"><button class="btn primary" data-now>💾 احفظ نسخة هلأ</button><button class="btn" data-pick>📁 غيّر المجلد</button><button class="btn danger" data-off>إيقاف</button></div>`
    : `<p class="muted" style="margin-top:0">اختار مجلد على جهازك (مثلاً اعمل مجلد «نسخ السمو» على قرص D واختاره)، والبرنامج رح يحط فيه نسخة لكل الشركات كل يوم أول ما تفتحه، وبيخلي آخر 60 نسخة.</p>
      <button class="btn primary" data-pick>📁 اختيار المجلد</button>`;
  box.querySelector('[data-pick]').onclick = async () => {
    try {
      const h = await window.showDirectoryPicker({ id: 'sumou-backup', mode: 'readwrite', startIn: 'documents' });
      await setDir(h); const r = await writeLocalBackup(h);
      toast(`✓ انحفظت أول نسخة: ${r.name}`, 'ok'); localBackupCard(box);
    } catch (e) { if (e?.name !== 'AbortError') toast(arError(e), 'err'); }
  };
  box.querySelector('[data-now]')?.addEventListener('click', async (e) => {
    try {
      if ((await dir.requestPermission({ mode: 'readwrite' })) !== 'granted') return toast('ما انعطى الإذن', 'err');
      e.target.disabled = true; const r = await writeLocalBackup(dir); toast(`✓ انحفظت: ${r.name} (${r.count} شركة)`, 'ok'); localBackupCard(box);
    } catch (er) { e.target.disabled = false; toast(arError(er), 'err'); }
  });
  box.querySelector('[data-off]')?.addEventListener('click', async () => {
    if (!(await confirmBox('إيقاف النسخة اليومية على جهازك؟ الملفات القديمة بتضل بمكانها.'))) return;
    await setDir(null); localBackupCard(box);
  });
}

async function viewBackup(v, ctx) {
  if (!isAdmin()) return void (v.innerHTML = '<div class="notice">هالشاشة لمدير النظام بس.</div>');
  const comps = S.companies || [];
  v.innerHTML = `<div class="page-head"><h2>💾 النسخ الاحتياطي والاسترجاع</h2></div>
    <div class="notice info">البرنامج بياخذ <b>نسخة تلقائية كل يوم</b> لكل الشركات أول ما تفتحه (كمدير)، وبيحتفظ بآخر 30 يوم بالتخزين. وبتقدر كمان تنزّل نسخة على جهازك وقت ما بدك — الأفضل مرة بالأسبوع على الأقل، وتحطها على الهارد الخارجي.</div>
    <div class="card"><h3 style="margin-top:0">⬇️ تنزيل نسخة على جهازك</h3>
      <div style="display:flex;gap:8px;flex-wrap:wrap"><button class="btn primary" id="all">⬇️ نسخة لكل الشركات (${comps.length})</button>
      ${S.company ? `<button class="btn" id="one">⬇️ نسخة لـ«${esc(S.company.name)}» بس</button>` : ''}</div><div id="prog" class="muted" style="margin-top:8px"></div></div>
    <div class="card"><h3 style="margin-top:0">🖥️ نسخة يومية تلقائية على جهازك (قرص D مثلاً)</h3><div id="local"></div></div>
    <div class="card"><h3 style="margin-top:0">☁️ النسخ التلقائية المحفوظة</h3><div id="cloud" class="muted">جاري التحميل…</div></div>
    <div class="card"><h3 style="margin-top:0">♻️ استرجاع من نسخة</h3>
      <p class="muted" style="margin-top:0">الاسترجاع بيرجّع الشركة كاملة بكل قيودها وفواتيرها وأرقامها، <b>إذا كانت مش موجودة</b> (انحذفت أو قاعدة بيانات جديدة). الشركات الموجودة ما بتتأثر.</p>
      <label class="btn">📂 اختيار ملف النسخة<input type="file" id="rf" accept=".json,application/json" hidden></label></div>`;
  localBackupCard(v.querySelector('#local'));
  const prog = v.querySelector('#prog');
  const dl = async (list) => {
    const out = [];
    for (const [i, c] of list.entries()) { prog.textContent = `جاري نسخ ${c.name} (${i + 1}/${list.length})…`; out.push(await backupOne(c)); }
    const file = list.length === 1 ? out[0] : { app: 'sumou-erp', multi: true, created_at: new Date().toISOString(), companies: out };
    saveFile(list.length === 1 ? `نسخة ${safe(list[0].name)} ${stamp()}.json` : `نسخة السمو ERP كل الشركات ${stamp()}.json`, JSON.stringify(file));
    prog.textContent = `✓ تم تنزيل النسخة (${list.length} شركة) — ${fmtDateTime(new Date())}`;
    await log('نسخ احتياطي', 'backup', null, { companies: list.length });
  };
  v.querySelector('#all').onclick = () => dl(comps).catch(e => { prog.textContent = ''; toast(arError(e), 'err'); });
  v.querySelector('#one')?.addEventListener('click', () => dl([S.company]).catch(e => { prog.textContent = ''; toast(arError(e), 'err'); }));
  // النسخ بالتخزين
  (async () => {
    const box = v.querySelector('#cloud'), rows = [];
    for (const c of comps) {
      const ls = await sb.storage.from('backups').list(c.id, { limit: 40, sortBy: { column: 'name', order: 'desc' } });
      if (ls.error) { box.innerHTML = `<div class="notice">${esc(arError(ls.error))}</div>`; return; }
      (ls.data || []).forEach(f => rows.push({ c, f }));
    }
    box.innerHTML = rows.length ? `<table class="t"><thead><tr><th>الشركة</th><th>التاريخ</th><th>الحجم</th><th></th></tr></thead><tbody>
      ${rows.map((r, i) => `<tr><td>${esc(r.c.name)}</td><td>${esc(r.f.name.replace('.json', ''))}</td><td>${Math.round((r.f.metadata?.size || 0) / 1024)} كيلو</td><td><button class="btn sm" data-dl="${i}">⬇️ تنزيل</button></td></tr>`).join('')}</tbody></table>`
      : '<div class="empty">لسا ما في نسخ تلقائية — بتنعمل لحالها اليوم</div>';
    box.onclick = async (e) => { const b = e.target.closest('[data-dl]'); if (!b) return; const r = rows[+b.dataset.dl];
      const { data, error } = await sb.storage.from('backups').download(`${r.c.id}/${r.f.name}`); if (error) return toast(arError(error), 'err');
      saveFile(`نسخة ${safe(r.c.name)} ${r.f.name}`, await data.text()); };
  })();
  // الاسترجاع
  v.querySelector('#rf').onchange = async (e) => {
    const f = e.target.files[0]; e.target.value = ''; if (!f) return;
    let j; try { j = JSON.parse(await f.text()); } catch { return toast('الملف مش مقروء', 'err'); }
    const list = j.multi ? j.companies : [j];
    if (!list?.length || list.some(x => x.app !== 'sumou-erp')) return toast('الملف مش نسخة احتياطية من السمو ERP', 'err');
    const exist = new Set(comps.map(c => c.id));
    const todo = list.filter(x => !exist.has(x.company_id)), skip = list.length - todo.length;
    if (!todo.length) return toast('كل الشركات اللي بالنسخة موجودة أصلاً — ما في شي للاسترجاع', 'err');
    if (!(await confirmBox(`استرجاع ${todo.length} شركة: ${todo.map(x => x.company_name).join('، ')}${skip ? ` (و${skip} موجودة رح تنتجاهل)` : ''}؟`))) return;
    let ok = 0;
    for (const x of todo) { const r = await sb.rpc('restore_company', { p_data: x }); if (r.error) toast(`${x.company_name}: ${arError(r.error)}`, 'err'); else ok++; }
    toast(`تم استرجاع ${ok} شركة`, ok ? 'ok' : 'err'); if (ok) setTimeout(() => location.reload(), 1200);
  };
}

// ---------------------------------------------------------------------
//  الاستيراد من إكسل
// ---------------------------------------------------------------------
let XLSX = null;
async function xlsx() {
  if (XLSX) return XLSX;
  await new Promise((res, rej) => { const s = document.createElement('script'); s.src = 'https://cdn.sheetjs.com/xlsx-0.20.3/package/dist/xlsx.full.min.js'; s.onload = res; s.onerror = () => rej(new Error('ما قدرت أحمّل مكتبة الإكسل. تأكد من الإنترنت.')); document.head.appendChild(s); });
  return (XLSX = window.XLSX);
}
const yes = (x) => ['نعم', 'yes', 'y', '1', 'true', '✓', 'صح'].includes(String(x ?? '').trim().toLowerCase());

const KINDS = {
  customers: { label: 'العملاء', perm: ['customers', 'add'], cols: ['الرقم', 'الاسم*', 'الاسم التجاري', 'الموبايل', 'الهاتف', 'الإيميل', 'المدينة', 'العنوان', 'الرقم الضريبي', 'سقف الائتمان', 'مدة السداد (أيام)'],
    sample: ['', 'محمد أحمد', 'مؤسسة النور', '0791234567', '', '', 'عمّان', 'شارع الجاردنز', '', 1000, 30] },
  suppliers: { label: 'الموردين', perm: ['suppliers', 'add'], cols: ['الرقم', 'الاسم*', 'الاسم التجاري', 'الموبايل', 'الهاتف', 'الإيميل', 'المدينة', 'العنوان', 'الرقم الضريبي', 'سقف الائتمان', 'مدة السداد (أيام)'],
    sample: ['', 'شركة التوريدات', '', '0781234567', '', '', 'الزرقاء', '', '123456', 0, 0] },
  items: { label: 'الأصناف والخدمات', perm: ['items', 'add'], cols: ['الرقم*', 'الاسم*', 'النوع (بضاعة/خدمة)', 'الوحدة', 'سعر البيع', 'سعر الشراء', 'الضريبة %', 'الباركود'],
    sample: ['101', 'كرتونة ماء', 'بضاعة', 'كرتونة', 2, 1.5, 16, ''] },
  accounts: { label: 'دليل الحسابات', perm: ['accounts', 'add'], cols: ['رقم الحساب*', 'اسم الحساب*', 'رقم الحساب الرئيسي*', 'حساب رئيسي؟ (نعم/لا)'],
    sample: ['5215', 'مصاريف سفر', '52', 'لا'] },
  opening: { label: 'الأرصدة الافتتاحية', perm: ['opening_balances', 'add'], cols: ['رقم الحساب*', 'مدين', 'دائن', 'رقم العميل/المورد', 'البيان'],
    sample: ['1101', 500, '', '', 'رصيد الصندوق'] },
  employees: { label: 'الموظفين', perm: ['payroll', 'edit'], cols: ['الرقم*', 'الاسم*', 'الرقم الوطني', 'رقم الضمان', 'الوظيفة', 'القسم', 'تاريخ التعيين (YYYY-MM-DD)', 'الراتب الأساسي', 'العلاوات', 'مشمول بالضمان (نعم/لا)', 'ضريبة شهرية', 'البنك', 'IBAN', 'الموبايل'],
    sample: ['1', 'أحمد محمد', '9901234567', '', 'محاسب', 'المالية', '2026-01-01', 600, 50, 'نعم', 0, 'البنك العربي', '', '0791111111'] },
};

async function viewImport(v) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const kinds = Object.entries(KINDS).filter(([, k]) => can(...k.perm));
  v.innerHTML = `<div class="page-head"><h2>📥 الاستيراد من إكسل</h2></div>
    <p class="muted">لـ«${esc(S.company.name)}»: نزّل النموذج، عبّيه بالإكسل (كل سطر = سجل)، وارفعه. البرنامج بيعرضلك المعاينة قبل ما يحفظ. الخانات اللي عليها * مطلوبة.</p>
    <div class="card"><div class="grid cols-3">
      <div class="field"><label>شو بدك تستورد؟</label><select id="kind">${kinds.map(([k, x]) => `<option value="${k}">${x.label}</option>`).join('')}</select></div>
      <div class="field" style="justify-content:flex-end"><button class="btn" id="tpl">⬇️ تنزيل النموذج</button></div>
      <div class="field" style="justify-content:flex-end"><label class="btn primary">📂 رفع ملف الإكسل<input type="file" id="file" accept=".xlsx,.xls,.csv" hidden></label></div></div>
      <label class="check" id="upd-box"><input type="checkbox" id="upd"> إذا الرقم موجود من قبل، حدّث بياناته (بدل ما يتجاهله)</label></div>
    <div id="pv"></div>`;
  const kindSel = v.querySelector('#kind');
  const updBox = () => v.querySelector('#upd-box').style.display = ['customers', 'suppliers', 'items', 'employees'].includes(kindSel.value) ? '' : 'none';
  kindSel.onchange = () => { updBox(); v.querySelector('#pv').innerHTML = ''; }; updBox();
  v.querySelector('#tpl').onclick = async () => {
    try { const X = await xlsx(), K = KINDS[kindSel.value];
      const ws = X.utils.aoa_to_sheet([K.cols, K.sample]); ws['!cols'] = K.cols.map(() => ({ wch: 18 })); ws['!views'] = [{ RTL: true }];
      const wb = X.utils.book_new(); wb.Workbook = { Views: [{ RTL: true }] }; X.utils.book_append_sheet(wb, ws, 'البيانات');
      X.writeFile(wb, `نموذج استيراد ${K.label}.xlsx`); } catch (e) { toast(e.message, 'err'); }
  };
  v.querySelector('#file').onchange = async (e) => {
    const f = e.target.files[0]; e.target.value = ''; if (!f) return;
    try {
      const X = await xlsx(); const wb = X.read(await f.arrayBuffer(), { cellDates: true });
      const aoa = X.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, defval: '', raw: false, dateNF: 'yyyy-mm-dd' });
      const rows = aoa.slice(1).filter(r => r.some(c => String(c).trim() !== ''));
      if (!rows.length) return toast('الملف فاضي', 'err');
      await preview(v, kindSel.value, rows.map(r => r.map(c => String(c ?? '').trim())), v.querySelector('#upd').checked);
    } catch (er) { toast(er.message || 'ما قدرت أقرأ الملف', 'err'); }
  };
}

async function preview(v, kind, rows, update) {
  const K = KINDS[kind], pv = v.querySelector('#pv');
  const accs = ['customers', 'suppliers', 'accounts', 'opening'].includes(kind) ? await loadAccounts(true) : [];
  const byCode = Object.fromEntries(accs.map(a => [a.code, a]));
  let parties = [];
  if (kind === 'opening') parties = (await sb.from('parties').select('id,code,name,account_id,party_type').eq('company_id', S.company.id)).data || [];
  const recs = [], errs = [];
  rows.forEach((r, i) => {
    const n = i + 2, g = (k) => r[k] ?? '';
    try {
      if (kind === 'customers' || kind === 'suppliers') {
        if (!g(1)) throw 'الاسم فاضي';
        const t = kind === 'customers' ? 'customer' : 'supplier';
        const acc = leafAccounts(accs).find(a => a.account_type === t); if (!acc) throw `ما في حساب ${t === 'customer' ? 'ذمم عملاء' : 'ذمم موردين'} بالدليل`;
        recs.push({ company_id: S.company.id, party_type: t, code: g(0), name: g(1), trade_name: g(2) || null, mobile: g(3) || null, phone: g(4) || null, email: g(5) || null,
          city: g(6) || null, address: g(7) || null, tax_no: g(8) || null, credit_limit: num(g(9)), payment_terms_days: parseInt(g(10), 10) || 0, account_id: acc.id });
      } else if (kind === 'items') {
        if (!g(0) || !g(1)) throw 'الرقم والاسم مطلوبين';
        recs.push({ company_id: S.company.id, code: g(0), name: g(1), item_type: /خدم|service/i.test(g(2)) ? 'service' : 'goods', unit: g(3) || 'حبة',
          sale_price: num(g(4)), purchase_price: num(g(5)), tax_rate: g(6) === '' ? 16 : num(g(6)), barcode: g(7) || null });
      } else if (kind === 'accounts') {
        if (!g(0) || !g(1) || !g(2)) throw 'رقم الحساب واسمه والحساب الرئيسي مطلوبين';
        if (byCode[g(0)]) throw `الحساب ${g(0)} موجود`;
        const par = byCode[g(2)] || recs.find(x => x.code === g(2)); if (!par) throw `الحساب الرئيسي ${g(2)} مش موجود`;
        recs.push({ company_id: S.company.id, code: g(0), name: g(1), parent_code: g(2), is_group: yes(g(3)), nature: par.nature, category: par.category });
      } else if (kind === 'opening') {
        const a = byCode[g(0)]; if (!a) throw `الحساب ${g(0)} مش موجود`; if (a.is_group) throw `الحساب ${g(0)} رئيسي`;
        const d = num(g(1)), c = num(g(2)); if (!d && !c) throw 'ما في مبلغ'; if (d && c) throw 'مدين ودائن بنفس السطر';
        let party_id = null; if (g(3)) { const p = parties.find(x => x.code === g(3)); if (!p) throw `العميل/المورد ${g(3)} مش موجود`; party_id = p.id; }
        recs.push({ account_id: a.id, debit: d, credit: c, party_id, description: g(4) || null, _label: `${a.code} — ${a.name}` });
      } else if (kind === 'employees') {
        if (!g(0) || !g(1)) throw 'الرقم والاسم مطلوبين';
        recs.push({ company_id: S.company.id, code: g(0), name: g(1), national_id: g(2) || null, ss_no: g(3) || null, job_title: g(4) || null, department: g(5) || null,
          hire_date: /^\d{4}-\d{2}-\d{2}$/.test(g(6)) ? g(6) : null, basic_salary: num(g(7)), allowances: num(g(8)), ss_subject: g(9) === '' ? true : yes(g(9)),
          income_tax: num(g(10)), bank_name: g(11) || null, iban: g(12) || null, mobile: g(13) || null });
      }
    } catch (m) { errs.push(`السطر ${n}: ${m}`); }
  });
  const show = K.cols.map(c => c.replace('*', ''));
  const tot = kind === 'opening' ? recs.reduce((s, r) => ({ d: s.d + r.debit, c: s.c + r.credit }), { d: 0, c: 0 }) : null;
  pv.innerHTML = `<div class="card"><h3 style="margin-top:0">المعاينة: ${recs.length} سجل سليم ${errs.length ? `· <span style="color:var(--bad)">${errs.length} فيها مشكلة</span>` : ''}</h3>
    ${errs.length ? `<div class="notice" style="max-height:160px;overflow:auto">${errs.map(esc).join('<br>')}</div>` : ''}
    ${tot ? `<div class="notice ${Math.abs(tot.d - tot.c) < 0.0005 ? 'info' : ''}">مجموع المدين ${tot.d.toFixed(3)} · مجموع الدائن ${tot.c.toFixed(3)} ${Math.abs(tot.d - tot.c) < 0.0005 ? '✓ متوازن' : '— مش متوازن (بتقدر تحفظه مسودة وتكمّله)'}</div>` : ''}
    <div class="table-wrap" style="max-height:320px"><table class="t"><thead><tr><th>#</th>${show.map(c => `<th>${esc(c)}</th>`).join('')}</tr></thead><tbody>
    ${rows.slice(0, 50).map((r, i) => `<tr><td class="muted">${i + 2}</td>${show.map((_, k) => `<td>${esc(r[k] ?? '')}</td>`).join('')}</tr>`).join('')}</tbody></table></div>
    ${rows.length > 50 ? `<p class="muted">… و${rows.length - 50} سطر كمان</p>` : ''}
    ${recs.length ? `<button class="btn primary" id="go" style="margin-top:10px">✅ استيراد ${recs.length} سجل${kind === 'opening' ? ' (كقيد افتتاحي مسودة)' : ''}</button>` : ''}</div>`;
  pv.querySelector('#go')?.addEventListener('click', async (e) => {
    e.target.disabled = true; e.target.textContent = 'جاري الاستيراد…';
    try {
      let n = 0;
      if (kind === 'opening') {
        if (!S.fy) throw new Error('اختار سنة مالية');
        const ins = await sb.from('journal_entries').insert({ company_id: S.company.id, fiscal_year_id: S.fy.id, entry_type: 'opening', entry_date: S.fy.start_date, description: 'أرصدة افتتاحية (مستوردة من إكسل)' }).select().single();
        if (ins.error) throw ins.error;
        const li = await sb.from('journal_lines').insert(recs.map((r, k) => ({ entry_id: ins.data.id, line_no: k + 1, account_id: r.account_id, party_id: r.party_id, description: r.description, debit: r.debit, credit: r.credit })));
        if (li.error) { await sb.from('journal_entries').delete().eq('id', ins.data.id); throw li.error; }
        n = recs.length; toast(`انعمل قيد افتتاحي مسودة فيه ${n} سطر. راجعه ورحّله من «الأرصدة الافتتاحية»`, 'ok');
      } else if (kind === 'accounts') {
        for (const r of recs) {
          const par = (await sb.from('accounts').select('id').eq('company_id', S.company.id).eq('code', r.parent_code).single()).data;
          const { parent_code, ...row } = r;
          const res = await sb.from('accounts').insert({ ...row, parent_id: par.id }); if (res.error) throw new Error(`${r.code}: ${arError(res.error)}`); n++;
        }
      } else {
        const tbl = kind === 'items' ? 'items' : kind === 'employees' ? 'employees' : 'parties';
        const conflict = tbl === 'parties' ? 'company_id,party_type,code' : 'company_id,code';
        const withCode = recs.filter(r => r.code), noCode = recs.filter(r => !r.code);
        for (let i = 0; i < withCode.length; i += 300) {
          const chunk = withCode.slice(i, i + 300);
          const res = await sb.from(tbl).upsert(chunk, { onConflict: conflict, ignoreDuplicates: !update }); if (res.error) throw res.error; n += chunk.length;
        }
        for (let i = 0; i < noCode.length; i += 300) {   // الرقم بينعمل لحاله
          const chunk = noCode.slice(i, i + 300).map(({ code, ...x }) => x);
          for (const x of chunk) { const res = await sb.from(tbl).insert({ ...x, code: '' }); if (res.error) throw res.error; n++; }
        }
        if (tbl === 'parties') S.parties = null;
        toast(`تم استيراد ${n} سجل`, 'ok');
      }
      await log('استيراد', kind, null, { rows: n });
      e.target.textContent = `✓ تم (${n})`;
    } catch (er) { toast(arError(er), 'err'); e.target.disabled = false; e.target.textContent = 'إعادة المحاولة'; }
  });
}

export const TOOLS_ROUTES = { 'backup': viewBackup, 'import': viewImport };
