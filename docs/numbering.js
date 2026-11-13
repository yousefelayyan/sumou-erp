// =====================================================================
//  السمو ERP — طريقة الترقيم (تنسيق أرقام المستندات لكل شركة)
// =====================================================================
import { S, sb, esc, toast, arError, can, log, isAdmin } from './core.js';

// أنواع المستندات اللي إلها ترقيم قابل للتنسيق
export const NUM_KINDS = [
  { key: 'journal',         label: 'سندات القيد',          group: 'المالية',  family: 'entry' },
  { key: 'receipt',         label: 'سندات القبض',          group: 'المالية',  family: 'entry' },
  { key: 'payment',         label: 'سندات الصرف',          group: 'المالية',  family: 'entry' },
  { key: 'sale',            label: 'فواتير المبيعات',      group: 'المبيعات', family: 'invoice' },
  { key: 'sale_return',     label: 'مرتجع المبيعات',       group: 'المبيعات', family: 'invoice' },
  { key: 'purchase',        label: 'فواتير المشتريات',     group: 'المشتريات', family: 'invoice' },
  { key: 'purchase_return', label: 'مرتجع المشتريات',      group: 'المشتريات', family: 'invoice' },
  { key: 'stock_in',        label: 'سندات الإدخال',        group: 'المخزون',  family: 'stock' },
  { key: 'stock_out',       label: 'سندات الإخراج',        group: 'المخزون',  family: 'stock' },
  { key: 'stock_transfer',  label: 'سندات التحويل',        group: 'المخزون',  family: 'stock' },
  { key: 'stock_count',     label: 'الجرد والتسوية',       group: 'المخزون',  family: 'stock' },
  { key: 'm_company',       label: 'الشركات (لكل المكتب)', group: 'الرموز الأساسية', family: 'company' },
  { key: 'm_account',       label: 'دليل الحسابات',        group: 'الرموز الأساسية', family: 'master' },
  { key: 'm_customer',      label: 'العملاء',              group: 'الرموز الأساسية', family: 'master' },
  { key: 'm_supplier',      label: 'الموردين',             group: 'الرموز الأساسية', family: 'master' },
  { key: 'm_customer_category', label: 'فئات العملاء',     group: 'الرموز الأساسية', family: 'master' },
  { key: 'm_supplier_category', label: 'فئات الموردين',    group: 'الرموز الأساسية', family: 'master' },
  { key: 'm_department',    label: 'الدوائر',             group: 'الرموز الأساسية', family: 'master' },
  { key: 'm_expense',       label: 'بطاقات المصاريف',      group: 'الرموز الأساسية', family: 'master' },
  { key: 'm_expense_category', label: 'فئات المصاريف',     group: 'الرموز الأساسية', family: 'master' },
  { key: 'm_item',          label: 'الأصناف والخدمات',     group: 'الرموز الأساسية', family: 'master' },
  { key: 'm_item_category', label: 'فئات المواد',          group: 'الرموز الأساسية', family: 'master' },
  { key: 'm_warehouse',     label: 'المستودعات',           group: 'الرموز الأساسية', family: 'master' },
  { key: 'm_cost_center',   label: 'مراكز الكلفة',         group: 'الرموز الأساسية', family: 'master' },
  { key: 'm_employee',      label: 'الموظفين',             group: 'الرموز الأساسية', family: 'master' },
  { key: 'm_asset',         label: 'الأصول الثابتة',       group: 'الرموز الأساسية', family: 'master' },
];
const KIND = Object.fromEntries(NUM_KINDS.map(k => [k.key, k]));

export const defaultRule = (key) => key?.startsWith('m_')
  ? { mode: 'auto', digits: key === 'm_account' ? 2 : 0, pad: '0', sep: '', prefix: '', suffix: '', add_parent: true, by_category: false }
  : ({ mode: 'auto', reset: key?.startsWith('stock_') ? 'none' : 'year', split: 'none',
  digits: 0, pad: '0', sep: '-', prefix: '', suffix: '', add_year: false, year_digits: 4, add_month: false, add_split: false });

let cache = null, cacheCo = null;
export async function loadNumbering(force = false) {
  if (!S.company) return {};
  if (!force && cache && cacheCo === S.company.id) return cache;
  const { data } = await sb.from('company_settings').select('numbering').eq('company_id', S.company.id).maybeSingle();
  cache = data?.numbering || {}; cacheCo = S.company.id; return cache;
}
export const clearNumberingCache = () => { cache = null; };
export async function ruleFor(key) { const all = await loadNumbering(); return { ...defaultRule(key), ...(all[key] || {}) }; }
export async function isManual(key) { return (await ruleFor(key)).mode === 'manual'; }

// رمز مقترح للبطاقات الأساسية (حساب، صنف، عميل…). بيرجّع null إذا ما في إعداد محفوظ (فبيضل الاقتراح القديم)
// لازم loadNumbering() تكون انعملت قبل. يدوي = فاضي
export function masterCode(key, codes, parentCode = null) {
  if (!cache || cacheCo !== S.company?.id || !cache[key]) return null;
  const r = { ...defaultRule(key), ...cache[key] };
  if (r.mode === 'manual') return '';
  const usePar = key === 'm_item' ? !!r.by_category : r.add_parent !== false;
  const head = (r.prefix || '') + (parentCode && usePar ? parentCode + (r.sep || '') : '');
  const tail = r.suffix || '';
  let max = 0;
  for (const c of codes || []) {
    const x = String(c ?? '');
    if (!x.startsWith(head) || !x.endsWith(tail) || x.length <= head.length + tail.length) continue;
    const mid = x.slice(head.length, x.length - tail.length);
    if (/^\d+$/.test(mid) || (r.pad && new RegExp('^' + r.pad.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '*\\d+$').test(mid))) {
      const n = parseInt(mid.replace(/^\D+/, ''), 10); if (n > max) max = n;
    }
  }
  let n = String(max + 1); const d = Math.min(12, Math.max(0, +r.digits || 0));
  if (d > n.length) n = n.padStart(d, (r.pad || '0').slice(0, 1));
  return head + n + tail;
}

// الرقم اللي بينعرض: المنسّق إذا موجود، وإلا الرقم العادي
export const ruleSync = (key) => (cache && cacheCo === S.company?.id && cache[key]) ? { ...defaultRule(key), ...cache[key] } : null;
export const docNo = (r) => r ? (r.doc_code || r.entry_no || r.inv_no || r.doc_no || '') : '';

// نفس منطق قاعدة البيانات، للمعاينة بس
export function formatPreview(r, no = 125, splitCode = '02', date = new Date()) {
  const parts = [];
  if (r.add_split && r.split !== 'none' && splitCode) parts.push(splitCode);
  if (r.add_year) { const y = date.getFullYear(); parts.push(+r.year_digits === 2 ? String(y % 100).padStart(2, '0') : String(y)); }
  if (r.add_month) parts.push(String(date.getMonth() + 1).padStart(2, '0'));
  let n = String(no); const d = Math.min(12, Math.max(0, +r.digits || 0));
  if (d > n.length) n = n.padStart(d, (r.pad || '0').slice(0, 1));
  parts.push(n);
  return (r.prefix || '') + parts.join(r.sep ?? '') + (r.suffix || '');
}

// حقل الرقم اليدوي بنموذج المستند
export const manualField = (manual, value, ro = '') => manual
  ? `<div class="field"><label>رقم المستند * <span class="muted" style="font-size:12px">(ترقيم يدوي)</span></label><input type="number" min="1" step="1" name="__manual_no" value="${esc(value ?? '')}" ${ro}></div>` : '';
export function readManual(form, manual) {
  if (!manual) return { ok: true, value: undefined };
  const v = form.querySelector('[name="__manual_no"]')?.value.trim();
  if (!v || !(+v >= 1) || !Number.isInteger(+v)) return { ok: false };
  return { ok: true, value: +v };
}

const RESETS = [['none', 'بدون ما يبدأ من جديد (تسلسل مستمر)'], ['year', 'يبدأ من جديد كل سنة مالية'], ['month', 'يبدأ من جديد كل شهر (فترة محاسبية)']];
const SPLITS = { entry: [['none', 'تسلسل واحد للشركة']],
  invoice: [['none', 'تسلسل واحد للشركة'], ['cost_center', 'تسلسل لكل مركز كلفة (فرع/دائرة)'], ['warehouse', 'تسلسل لكل مستودع']],
  stock: [['none', 'تسلسل واحد للشركة'], ['warehouse', 'تسلسل لكل مستودع']] };

async function viewNumbering(v, ctx) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const editable = can('companies', 'edit');
  const dis = editable ? '' : 'disabled';
  const all = JSON.parse(JSON.stringify(await loadNumbering(true)));
  let cur = ctx?.params?.k && KIND[ctx.params.k] ? ctx.params.k : 'journal';
  let dirty = false;
  const KINDS = NUM_KINDS.filter(k => k.key !== 'm_company' || isAdmin());
  const groups = [...new Set(KINDS.map(k => k.group))];
  let coNum = (await sb.rpc('company_numbering')).data || { mode: 'auto', digits: 2 };
  v.innerHTML = `<div class="page-head"><h2>🔢 طريقة الترقيم</h2><div class="spacer"></div>${editable ? '<button class="btn primary" id="save">💾 حفظ</button>' : ''}</div>
    <p class="muted">لكل نوع مستند بهالشركة: كيف ينرقّم، وإيمتى يبدأ من جديد، وشو شكل الرقم اللي بيطلع بالشاشات والطباعة. التغيير بيمشي على المستندات الجديدة بس.</p>
    <div class="grid" style="grid-template-columns:230px 1fr 1fr;gap:16px;align-items:start">
      <div class="card" style="padding:8px" id="kinds"><input id="ksearch" placeholder="🔎 بحث… (فواتير، عملاء، شيكات…)" style="width:100%;margin-bottom:8px">${groups.map(g => `<div class="kgrp" data-grp="${esc(g)}">
        <button type="button" class="kgrp-title" data-toggle="${esc(g)}">${g}<span class="chev">›</span></button>
        <div class="kgrp-items">${KINDS.filter(k => k.group === g).map(k => `<button type="button" class="btn sm" data-k="${k.key}" style="display:flex;width:100%;justify-content:flex-start;margin-bottom:4px">${k.label}<span class="badge" data-tag="${k.key}" style="margin-inline-start:auto"></span></button>`).join('')}</div></div>`).join('')}</div>
      <form class="card" id="nf-mode"></form>
      <form class="card" id="nf-fmt"></form>
    </div>`;
  const rule = () => ({ ...defaultRule(cur), ...(all[cur] || {}) });
  const tag = (k) => { if (k === 'm_company') return coNum.mode === 'manual' ? 'يدوي' : 'تلقائي'; if (k.startsWith('m_') && !all[k]) return 'افتراضي'; const r = { ...defaultRule(k), ...(all[k] || {}) }; return r.mode === 'manual' ? 'يدوي' : 'تلقائي'; };
  const openGrp = (g) => v.querySelectorAll('.kgrp').forEach(el => el.classList.toggle('open', el.dataset.grp === g));
  const drawTags = () => KINDS.forEach(k => { v.querySelector(`[data-tag="${k.key}"]`).textContent = tag(k.key);
    v.querySelector(`[data-k="${k.key}"]`).classList.toggle('primary', k.key === cur); });
  const radio = (name, val, label, r) => `<label class="check"><input type="radio" name="${name}" value="${val}" ${r[name] === val ? 'checked' : ''} ${dis}> ${label}</label>`;
  const chk = (name, label, r, extra = '') => `<label class="check"><input type="checkbox" name="${name}" ${r[name] ? 'checked' : ''} ${dis} ${extra}> ${label}</label>`;
  const drawMaster = () => {
    const r = rule(), K = KIND[cur];
    v.querySelector('#nf-mode').innerHTML = `<h3 style="margin-top:0">طريقة الترميز — ${K.label}</h3>
      ${radio('mode', 'auto', 'ترميز تلقائي (البرنامج بيقترح الرمز الجاي وبتقدر تعدّله)', r)}${radio('mode', 'manual', 'ترميز يدوي (الرمز بيضل فاضي وبتكتبه)', r)}
      ${cur === 'm_item' ? `<hr><b style="font-size:14px">الترميز حسب</b>${radio('by_cat', 'no', 'تسلسل واحد لكل الأصناف', { by_cat: r.by_category ? 'yes' : 'no' })}${radio('by_cat', 'yes', 'ترقيم تلقائي حسب الفئة (رمز الفئة + تسلسل جوّا الفئة)', { by_cat: r.by_category ? 'yes' : 'no' })}<p class="muted" style="font-size:12px">مثال: فئة «مشروبات» رمزها 01، أصنافها بتصير 01.000001، 01.000002… (حسب الفاصل وعدد الخانات). الفئات من شاشة «الأصناف والخدمات» ← «فئات المواد».</p>` : ''}
      ${cur === 'm_account' ? `<hr>${chk('add_parent', 'إضافة الرمز الرئيسي (رمز الحساب الأب) قبل رمز الحساب', r)}<p class="muted" style="font-size:12px">مثال: حساب تحت «11 الموجودات المتداولة» بيصير 1101، 1102…</p>` : ''}
      <p class="muted" style="font-size:12px">إذا ما حفظت إعداد لهالنوع، البرنامج بيضل يقترح الرمز بالطريقة القديمة.</p>`;
    v.querySelector('#nf-fmt').innerHTML = `<h3 style="margin-top:0">شكل الرمز</h3>
      <div class="grid cols-3">
        <div class="field"><label>عدد خانات الرمز</label><input type="number" name="digits" min="0" max="12" value="${+r.digits || 0}" ${dis}></div>
        <div class="field"><label>حرف التنقيع</label><input name="pad" maxlength="1" value="${esc(r.pad)}" ${dis}></div>
        <div class="field"><label>الحرف الفاصل</label><input name="sep" maxlength="3" value="${esc(r.sep)}" ${dis}></div>
        <div class="field"><label>النص السابق</label><input name="prefix" maxlength="15" value="${esc(r.prefix)}" placeholder="مثلاً C" ${dis}></div>
        <div class="field"><label>النص اللاحق</label><input name="suffix" maxlength="15" value="${esc(r.suffix)}" ${dis}></div>
      </div>
      <div class="notice info" style="margin-top:12px">مثال: <b dir="ltr" style="font-size:18px" id="pv">${esc(masterPreview(r))}</b></div>`;
    drawTags();
  };
  const masterPreview = (r) => { const d = Math.min(12, Math.max(0, +r.digits || 0)); let n = '7'; if (d > 1) n = n.padStart(d, (r.pad || '0').slice(0, 1));
    return (r.prefix || '') + (cur === 'm_account' && r.add_parent !== false ? '11' + (r.sep || '') : cur === 'm_item' && r.by_category ? '01' + (r.sep || '') : '') + n + (r.suffix || ''); };
  const drawCompany = () => {
    const ad = isAdmin() ? '' : 'disabled';
    v.querySelector('#nf-mode').innerHTML = `<h3 style="margin-top:0">ترقيم الشركات</h3>
      <label class="check"><input type="radio" name="co_mode" value="auto" ${coNum.mode !== 'manual' ? 'checked' : ''} ${ad}> تلقائي (01، 02، 03…) — الرمز بينحط لحاله وما بيتعدّل</label>
      <label class="check"><input type="radio" name="co_mode" value="manual" ${coNum.mode === 'manual' ? 'checked' : ''} ${ad}> يدوي — بتكتب رمز الشركة بإيدك</label>
      <p class="muted" style="font-size:12px">هالإعداد لكل شركات المكتب (مش لهالشركة بس). وبالحالتين ما بيصير رمزين متشابهين.</p>`;
    v.querySelector('#nf-fmt').innerHTML = `<h3 style="margin-top:0">شكل الرمز</h3>
      <div class="field"><label>عدد الخانات</label><input type="number" name="co_digits" min="1" max="6" value="${+coNum.digits || 2}" ${ad}></div>
      <div class="notice info" style="margin-top:12px">مثال: <b dir="ltr" style="font-size:18px" id="pv">${'1'.padStart(+coNum.digits || 2, '0')}</b></div>
      ${isAdmin() ? '<button type="button" class="btn primary" id="co-save">💾 حفظ ترقيم الشركات</button>' : ''}`;
    const rd = () => { coNum = { mode: v.querySelector('[name=co_mode]:checked')?.value || 'auto', digits: Math.min(6, Math.max(1, parseInt(v.querySelector('[name=co_digits]').value) || 2)) }; v.querySelector('#pv').textContent = '1'.padStart(coNum.digits, '0'); drawTags(); };
    v.querySelector('#nf-mode').onchange = rd; v.querySelector('#nf-fmt').oninput = rd;
    v.querySelector('#co-save')?.addEventListener('click', async () => {
      rd(); const { error } = await sb.rpc('set_company_numbering', { p_mode: coNum.mode, p_digits: coNum.digits });
      if (error) return toast(arError(error), 'err'); toast('انحفظ ترقيم الشركات', 'ok');
    });
    drawTags();
  };
  const draw = () => {
    if (KIND[cur].family === 'company') return drawCompany();
    if (KIND[cur].family === 'master') return drawMaster();
    const r = rule(), K = KIND[cur], splits = SPLITS[K.family];
    v.querySelector('#nf-mode').innerHTML = `<h3 style="margin-top:0">طريقة الترقيم — ${K.label}</h3>
      ${radio('mode', 'auto', 'ترقيم تلقائي', r)}${radio('mode', 'manual', 'ترقيم يدوي (المستخدم بيكتب الرقم)', r)}
      <hr><b style="font-size:14px">إيمتى يبدأ الترقيم من 1؟</b>${RESETS.map(([k, l]) => radio('reset', k, l, r)).join('')}
      <hr><b style="font-size:14px">التسلسل حسب</b>${splits.map(([k, l]) => radio('split', k, l, r)).join('')}
      ${K.family === 'entry' ? '<p class="muted" style="font-size:12px">السندات المالية مركز الكلفة فيها على السطور، فتسلسلها واحد للشركة.</p>' : ''}
      ${r.split === 'cost_center' ? '<p class="muted" style="font-size:12px">الفاتورة بدون مركز كلفة بتاخذ تسلسل لحالها.</p>' : ''}`;
    v.querySelector('#nf-fmt').innerHTML = `<h3 style="margin-top:0">شكل الرقم</h3>
      <div class="grid cols-3">
        <div class="field"><label>عدد خانات الرقم</label><input type="number" name="digits" min="0" max="12" value="${+r.digits || 0}" ${dis}></div>
        <div class="field"><label>حرف التنقيع</label><input name="pad" maxlength="1" value="${esc(r.pad)}" ${dis}></div>
        <div class="field"><label>الحرف الفاصل</label><input name="sep" maxlength="3" value="${esc(r.sep)}" ${dis}></div>
        <div class="field"><label>النص السابق</label><input name="prefix" maxlength="15" value="${esc(r.prefix)}" placeholder="مثلاً INV-" ${dis}></div>
        <div class="field"><label>النص اللاحق</label><input name="suffix" maxlength="15" value="${esc(r.suffix)}" ${dis}></div>
        <div class="field"><label>رمز السنة</label><select name="year_digits" ${dis}><option value="4" ${+r.year_digits !== 2 ? 'selected' : ''}>2026</option><option value="2" ${+r.year_digits === 2 ? 'selected' : ''}>26</option></select></div>
      </div>
      ${chk('add_split', 'إضافة رمز مركز الكلفة / المستودع إلى الرقم', r, r.split === 'none' ? 'disabled' : '')}
      ${chk('add_year', 'إضافة رمز السنة المالية إلى الرقم', r)}
      ${chk('add_month', 'إضافة رمز الشهر (الفترة المحاسبية) إلى الرقم', r)}
      <div class="notice info" style="margin-top:12px">مثال: <b dir="ltr" style="font-size:18px" id="pv">${esc(formatPreview(r))}</b></div>
      <p class="muted" style="font-size:12px">«عدد الخانات» صفر يعني الرقم بدون تنقيع (125). لو 6 وحرف التنقيع 0 بيصير 000125.</p>`;
    drawTags();
  };
  const read = () => {
    const r = rule();
    v.querySelectorAll('#nf-mode [name], #nf-fmt [name]').forEach(el => {
      if (el.type === 'radio') { if (el.checked) { if (el.name === 'by_cat') r.by_category = el.value === 'yes'; else r[el.name] = el.value; } }
      else if (el.type === 'checkbox') r[el.name] = el.checked;
      else r[el.name] = el.value;
    });
    r.digits = Math.min(12, Math.max(0, parseInt(r.digits) || 0));
    if (KIND[cur].family !== 'master') { r.year_digits = +r.year_digits === 2 ? 2 : 4; if (r.split === 'none') r.add_split = false; }
    all[cur] = r; dirty = true;
  };
  const onChange = (e) => { if (KIND[cur].family === 'company') return; read(); if (['split', 'mode', 'reset', 'by_cat'].includes(e.target.name)) draw(); else { v.querySelector('#pv').textContent = KIND[cur].family === 'master' ? masterPreview(rule()) : formatPreview(rule()); drawTags(); } };
  v.querySelector('#nf-mode').addEventListener('change', onChange);
  v.querySelector('#nf-fmt').addEventListener('input', onChange);
  v.querySelector('#nf-fmt').addEventListener('change', onChange);
  v.querySelector('#kinds').addEventListener('click', (e) => {
    const t = e.target.closest('[data-toggle]');
    if (t) { const el = t.closest('.kgrp'); openGrp(el.classList.contains('open') ? null : t.dataset.toggle); return; }
    const b = e.target.closest('[data-k]'); if (!b) return; cur = b.dataset.k; draw(); });
  openGrp(KIND[cur].group);
  v.querySelector('#ksearch').addEventListener('input', (e) => {
    const t = e.target.value.trim();
    v.querySelectorAll('#kinds [data-k]').forEach(b => { b.style.display = !t || b.textContent.includes(t) ? 'flex' : 'none'; });
    v.querySelectorAll('#kinds .kgrp').forEach(g => { const any = [...g.querySelectorAll('[data-k]')].some(b => b.style.display !== 'none');
      g.style.display = any ? '' : 'none'; if (t) g.classList.toggle('open', any); });
    if (!t) openGrp(KIND[cur].group);
  });
  v.querySelector('#save')?.addEventListener('click', async () => {
    await sb.rpc('ensure_company_settings', { p_company: S.company.id });
    const { error } = await sb.from('company_settings').update({ numbering: all, updated_at: new Date().toISOString() }).eq('company_id', S.company.id);
    if (error) return toast(arError(error), 'err');
    clearNumberingCache(); dirty = false; await log('تعديل', 'numbering', S.company.id); toast('تم حفظ طريقة الترقيم', 'ok');
  });
  draw();
}

export const NUMBERING_ROUTES = { numbering: viewNumbering };
