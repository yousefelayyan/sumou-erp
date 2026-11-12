// =====================================================================
//  السمو ERP — المرحلة 2: المالية
//  دليل الحسابات، الأرصدة الافتتاحية، سندات القيد والقبض والصرف
// =====================================================================
import { attachAudit } from './audit.js';
import { docNo, loadNumbering, isManual, manualField, readManual, masterCode } from './numbering.js';
import { loadPosting, postFlag, postBarHTML, wirePostBar } from './posting.js';
import { S, sb, esc, fmtDate, fmtNum, num, today, toast, arError, modal, confirmBox, formData, can, log } from './core.js';
import { printDoc, amountToWords } from './print.js';
import { openAttachments } from './attach.js';
import { recurringDialog } from './extras.js';
import { loadParties, partyDatalist, resolveParty, partyLabel } from './parties.js';
import { deptField, deptValue } from './departments.js';
import { loadLookups, pmOptions } from './lookups.js';

export const CATEGORIES = { assets: 'الموجودات', liabilities: 'المطلوبات', equity: 'حقوق الملكية', revenue: 'الإيرادات', expenses: 'المصاريف' };
export const ACC_TYPES = { general: 'عام', cash: 'صندوق', bank: 'بنك', customer: 'عميل', supplier: 'مورد', employee: 'موظف', tax: 'ضريبة' };
export const ENTRY_TYPES = {
  journal: { label: 'سند قيد', plural: 'سندات القيد', screen: 'journal_entries', route: 'journal', icon: '📒' },
  receipt: { label: 'سند قبض', plural: 'سندات القبض', screen: 'receipt_vouchers', route: 'receipts', icon: '📥' },
  payment: { label: 'سند صرف', plural: 'سندات الصرف', screen: 'payment_vouchers', route: 'payments', icon: '📤' },
  opening: { label: 'قيد افتتاحي', plural: 'الأرصدة الافتتاحية', screen: 'opening_balances', route: 'opening', icon: '🧮' },
  invoice: { label: 'قيد فاتورة', plural: 'قيود الفواتير', screen: 'journal_entries', route: 'sales', icon: '🧾' },
  cheque: { label: 'قيد شيك', plural: 'قيود الشيكات', screen: 'journal_entries', route: 'cheques', icon: '💳' },
  payroll: { label: 'قيد رواتب', plural: 'قيود الرواتب', screen: 'journal_entries', route: 'payroll', icon: '💵' },
  depreciation: { label: 'قيد استهلاك', plural: 'قيود الاستهلاك', screen: 'journal_entries', route: 'assets', icon: '📉' },
  stock: { label: 'قيد مخزون', plural: 'قيود المخزون', screen: 'journal_entries', route: 'stock', icon: '📦' },
  closing: { label: 'قيد إقفال', plural: 'قيود الإقفال', screen: 'journal_entries', route: 'fiscal-years', icon: '🔒' },
};
const STATUS = { draft: ['مسودة', 'warn'], posted: ['مرحّل', 'ok'], reversed: ['معكوس', 'bad'] };
const statusBadge = (s) => `<span class="badge ${STATUS[s][1]}">${STATUS[s][0]}</span>`;

// ---------------------------------------------------------------------
//  تحميل الحسابات (مع ذاكرة مؤقتة للشركة الحالية)
// ---------------------------------------------------------------------
export async function loadAccounts(force = false) {
  if (!S.company) return [];
  if (!force && S.accounts && S.accountsCompany === S.company.id) return S.accounts;
  const all = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await sb.from('accounts').select('*').eq('company_id', S.company.id).order('code').range(from, from + 999);
    if (error) throw error;
    all.push(...data); if (data.length < 1000) break;
  }
  S.accounts = all; S.accountsCompany = S.company.id;
  return all;
}
export const accLabel = (a) => a ? `${a.code} — ${a.name}` : '';
export const leafAccounts = (accs) => accs.filter(a => !a.is_group && a.is_active);

// قائمة اختيار الحساب (بحث بالرقم أو الاسم)
export function accountDatalist(accs, id = 'acc-list') {
  return `<datalist id="${id}">${leafAccounts(accs).map(a => `<option value="${esc(accLabel(a))}"></option>`).join('')}</datalist>`;
}
export function resolveAccount(accs, text) {
  const t = (text || '').trim(); if (!t) return null;
  const code = t.split('—')[0].trim();
  return accs.find(a => a.code === code && !a.is_group) || accs.find(a => !a.is_group && a.name === t) || null;
}

function needCompanyFY(v) {
  if (!S.company) { v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`; return false; }
  if (!S.fy) { v.innerHTML = `<div class="notice">هالشركة ما إلها سنة مالية. <a href="#/fiscal-years">أضف سنة مالية</a> أول.</div>`; return false; }
  return true;
}

async function loadBalances(fyId = S.fy?.id) {
  if (!fyId) return {};
  const { data, error } = await sb.from('account_balances').select('account_id,debit,credit').eq('company_id', S.company.id).eq('fiscal_year_id', fyId);
  if (error) throw error;
  return Object.fromEntries((data || []).map(r => [r.account_id, num(r.debit) - num(r.credit)]));
}

// ---------------------------------------------------------------------
//  دليل الحسابات (شجرة)
// ---------------------------------------------------------------------
const expanded = new Set();

async function viewAccounts(v, ctx) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const [accs] = await Promise.all([loadAccounts(true), loadNumbering(true)]);
  const bal = await loadBalances();
  const canAdd = can('accounts', 'add'), canEdit = can('accounts', 'edit'), canDel = can('accounts', 'delete');

  if (!accs.length) {
    v.innerHTML = `<div class="page-head"><h2>دليل الحسابات</h2></div>
      <div class="card" style="text-align:center;padding:40px">
        <p style="font-size:17px">هالشركة ما إلها دليل حسابات لسا.</p>
        ${canAdd ? `<p class="muted">بتقدر تبلّش بدليل حسابات أردني جاهز (78 حساب)، وبتعدّل عليه بعدين، أو تبني دليلك من الصفر.</p>
        <button class="btn primary" id="seed">🌳 إنشاء دليل حسابات جاهز</button> <button class="btn" id="add-root">➕ حساب رئيسي من الصفر</button>` : ''}
      </div>`;
    v.querySelector('#seed')?.addEventListener('click', async (e) => {
      e.target.disabled = true;
      const { data, error } = await sb.rpc('seed_default_accounts', { p_company: S.company.id });
      if (error) { e.target.disabled = false; return toast(arError(error), 'err'); }
      toast(`تم إنشاء ${data} حساب`, 'ok'); ctx.rerender();
    });
    v.querySelector('#add-root')?.addEventListener('click', () => accountForm(null, null, accs, ctx));
    return;
  }

  // تجميع الأرصدة على الحسابات الرئيسية
  const children = {}; accs.forEach(a => (children[a.parent_id || 'root'] ||= []).push(a));
  const rolled = {};
  const roll = (a) => { let t = bal[a.id] || 0; (children[a.id] || []).forEach(c => t += roll(c)); return rolled[a.id] = t; };
  (children.root || []).forEach(roll);
  if (!expanded.size) accs.filter(a => a.level === 1).forEach(a => expanded.add(a.id));

  v.innerHTML = `
    <div class="page-head"><h2>دليل الحسابات</h2><span class="badge brand">${accs.length} حساب</span><div class="spacer"></div>
      <input class="search" id="q" placeholder="بحث برقم أو اسم الحساب…">
      <button class="btn sm" id="exp">توسيع الكل</button><button class="btn sm" id="col">طي الكل</button>
      <button class="btn sm" id="csv">⬇️ Excel</button>
      ${can('accounts', 'print') ? `<button class="btn sm" id="prn">🖨️ طباعة</button>` : ''}
      ${canAdd ? `<button class="btn primary" id="add-root">➕ حساب رئيسي</button>` : ''}</div>
    <p class="muted" style="margin-top:-6px">الأرصدة من القيود المرحّلة بالسنة المالية: <b>${esc(S.fy ? (S.fy.name || S.fy.code) : '—')}</b>. (+) مدين، (−) دائن.</p>
    <div class="card table-wrap"><table class="t tree">
      <thead><tr><th style="width:130px">رقم الحساب</th><th>اسم الحساب</th><th>النوع</th><th>الطبيعة</th><th style="text-align:left">الرصيد</th><th></th></tr></thead>
      <tbody id="rows"></tbody></table></div>`;

  const draw = () => {
    const q = v.querySelector('#q').value.trim().toLowerCase();
    let visible;
    if (q) {
      const match = new Set(accs.filter(a => a.code.toLowerCase().includes(q) || a.name.toLowerCase().includes(q)).map(a => a.id));
      const byId = Object.fromEntries(accs.map(a => [a.id, a]));
      const keep = new Set();
      match.forEach(id => { let a = byId[id]; while (a) { keep.add(a.id); a = byId[a.parent_id]; } });
      visible = accs.filter(a => keep.has(a.id));
    } else {
      const out = [];
      const walk = (list) => list.sort((x, y) => x.code.localeCompare(y.code, 'en', { numeric: true })).forEach(a => { out.push(a); if (a.is_group && expanded.has(a.id)) walk(children[a.id] || []); });
      walk(children.root || []); visible = out;
    }
    v.querySelector('#rows').innerHTML = visible.map(a => {
      const b = rolled[a.id] || 0;
      return `<tr class="${a.is_group ? 'grp' : ''} ${a.is_active ? '' : 'inactive'}">
        <td dir="ltr" style="text-align:right">${esc(a.code)}</td>
        <td><span style="padding-inline-start:${(a.level - 1) * 22}px"></span>
          ${a.is_group ? `<span class="tog" data-tog="${a.id}">${expanded.has(a.id) || q ? '▾' : '◂'}</span>` : '<span class="tog-sp"></span>'}
          ${a.is_group ? `<b>${esc(a.name)}</b>` : esc(a.name)} ${a.is_active ? '' : '<span class="badge bad">موقوف</span>'}</td>
        <td>${a.is_group ? '<span class="muted">رئيسي</span>' : (a.account_type !== 'general' ? `<span class="badge brand">${ACC_TYPES[a.account_type]}</span>` : 'فرعي')}</td>
        <td>${a.nature === 'debit' ? 'مدين' : 'دائن'}</td>
        <td dir="ltr" style="text-align:left;${a.is_group ? 'font-weight:700' : ''}">${b ? fmtNum(b) : '<span class="muted">—</span>'}</td>
        <td class="actions">
          ${a.is_group && canAdd ? `<button class="btn sm" data-child="${a.id}">➕ فرعي</button>` : ''}
          ${canEdit ? `<button class="btn sm" data-edit="${a.id}">تعديل</button>` : ''}
          ${canDel ? `<button class="btn sm danger" data-del="${a.id}">حذف</button>` : ''}
          ${!a.is_group ? `<a class="btn sm" href="#/rep-ledger?acc=${a.id}">كشف</a>` : ''}
        </td></tr>`;
    }).join('') || `<tr><td colspan="6" class="empty">ما في نتائج</td></tr>`;
  };
  draw();
  v.querySelector('#q').oninput = draw;
  v.querySelector('#exp').onclick = () => { accs.filter(a => a.is_group).forEach(a => expanded.add(a.id)); draw(); };
  v.querySelector('#col').onclick = () => { expanded.clear(); draw(); };
  v.querySelector('#add-root')?.addEventListener('click', () => accountForm(null, null, accs, ctx));
  v.querySelector('#csv').onclick = () => downloadCSV(`دليل الحسابات - ${S.company.name}.csv`,
    [['رقم الحساب', 'اسم الحساب', 'الحساب الأب', 'رئيسي', 'التصنيف', 'الطبيعة', 'النوع', 'الرصيد']].concat(
      accs.map(a => [a.code, a.name, accs.find(p => p.id === a.parent_id)?.code || '', a.is_group ? 'نعم' : 'لا', CATEGORIES[a.category], a.nature === 'debit' ? 'مدين' : 'دائن', ACC_TYPES[a.account_type], (rolled[a.id] || 0).toFixed(3)])));
  v.querySelector('#prn')?.addEventListener('click', () => {
    const rows = [...accs].sort((x, y) => x.code.localeCompare(y.code, 'en', { numeric: true }));
    printDoc('دليل الحسابات', `<table class="pt"><thead><tr><th>رقم الحساب</th><th>اسم الحساب</th><th>الطبيعة</th><th>الرصيد</th></tr></thead><tbody>
      ${rows.map(a => `<tr style="${a.is_group ? 'font-weight:700;background:#f6f2fa' : ''}"><td>${esc(a.code)}</td><td style="padding-right:${(a.level - 1) * 16 + 6}px">${esc(a.name)}</td>
      <td>${a.nature === 'debit' ? 'مدين' : 'دائن'}</td><td class="n">${rolled[a.id] ? fmtNum(rolled[a.id]) : ''}</td></tr>`).join('')}</tbody></table>`);
  });
  v.querySelector('#rows').onclick = async (e) => {
    const t = e.target.closest('[data-tog]'), ch = e.target.closest('[data-child]'), ed = e.target.closest('[data-edit]'), dl = e.target.closest('[data-del]');
    if (t) { const id = t.dataset.tog; expanded.has(id) ? expanded.delete(id) : expanded.add(id); draw(); }
    if (ch) accountForm(null, accs.find(a => a.id === ch.dataset.child), accs, ctx);
    if (ed) { const a = accs.find(x => x.id === ed.dataset.edit); accountForm(a, accs.find(p => p.id === a.parent_id), accs, ctx); }
    if (dl) {
      const a = accs.find(x => x.id === dl.dataset.del);
      if ((children[a.id] || []).length) return toast('الحساب إله حسابات فرعية، احذفها أول', 'err');
      if (!(await confirmBox(`حذف الحساب «${a.code} - ${a.name}»؟`))) return;
      const { error } = await sb.from('accounts').delete().eq('id', a.id);
      if (error) return toast(arError(error), 'err');
      await log('حذف', 'accounts', a.id, { code: a.code, name: a.name });
      toast('تم الحذف', 'ok'); ctx.rerender();
    }
  };
}

function suggestCode(parent, accs) {
  const mc = masterCode('m_account', accs.filter(a => (a.parent_id || null) === (parent?.id || null)).map(a => a.code), parent?.code || null);
  if (mc !== null) return mc;
  if (!parent) {
    const roots = accs.filter(a => !a.parent_id).map(a => parseInt(a.code)).filter(n => !isNaN(n));
    return String((roots.length ? Math.max(...roots) : 0) + 1);
  }
  const sibs = accs.filter(a => a.parent_id === parent.id).map(a => a.code);
  const nums = sibs.filter(c => c.startsWith(parent.code) && /^\d+$/.test(c)).map(c => parseInt(c));
  if (nums.length) return String(Math.max(...nums) + 1);
  return parent.code + (parent.level >= 2 ? '01' : '1');
}

function accountForm(a, parent, accs, ctx) {
  const isNew = !a;
  a = a || { code: suggestCode(parent, accs), name: '', is_group: !parent || parent.level < 2, category: parent?.category || 'assets',
             nature: parent?.nature || 'debit', account_type: 'general', is_active: true, parent_id: parent?.id || null };
  const groups = accs.filter(g => g.is_group && g.id !== a.id);
  const m = modal({ title: isNew ? (parent ? `حساب جديد تحت «${parent.name}»` : 'حساب رئيسي جديد') : `تعديل الحساب ${a.code}`, body: `
    <form id="acc-form"><div class="grid cols-2">
      <div class="field"><label>رقم الحساب *</label><input name="code" required value="${esc(a.code)}" dir="ltr"></div>
      <div class="field"><label>اسم الحساب *</label><input name="name" required value="${esc(a.name)}"></div>
      <div class="field"><label>الاسم بالإنجليزي</label><input name="name_en" value="${esc(a.name_en)}" dir="ltr"></div>
      <div class="field"><label>الحساب الأب</label><select name="parent_id"><option value="">— بدون (حساب على المستوى الأول) —</option>
        ${groups.map(g => `<option value="${g.id}" ${g.id === a.parent_id ? 'selected' : ''}>${esc(g.code)} — ${esc(g.name)}</option>`).join('')}</select></div>
      <div class="field"><label>التصنيف</label><select name="category" ${a.parent_id ? 'disabled' : ''}>
        ${Object.entries(CATEGORIES).map(([k, l]) => `<option value="${k}" ${a.category === k ? 'selected' : ''}>${l}</option>`).join('')}</select>
        <span class="hint">الحساب الفرعي بياخذ تصنيف أبوه تلقائياً</span></div>
      <div class="field"><label>طبيعة الحساب</label><select name="nature">
        <option value="debit" ${a.nature === 'debit' ? 'selected' : ''}>مدين</option><option value="credit" ${a.nature === 'credit' ? 'selected' : ''}>دائن</option></select></div>
      <div class="field"><label>نوع الحساب</label><select name="account_type">
        ${Object.entries(ACC_TYPES).map(([k, l]) => `<option value="${k}" ${a.account_type === k ? 'selected' : ''}>${l}</option>`).join('')}</select>
        <span class="hint">«صندوق» و«بنك» بيظهروا أول بسندات القبض والصرف</span></div>
    </div>
    <label class="check"><input type="checkbox" name="is_group" ${a.is_group ? 'checked' : ''}> حساب رئيسي (تجميعي، ما بينقيّد عليه، إله حسابات فرعية)</label>
    <label class="check"><input type="checkbox" name="is_active" ${a.is_active ? 'checked' : ''}> الحساب فعّال</label>
    <div class="field"><label>ملاحظات</label><textarea name="notes" style="min-height:60px">${esc(a.notes)}</textarea></div></form>`,
    foot: `<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>` });
  const f = m.el.querySelector('#acc-form');
  f.parent_id.onchange = () => {
    const p = accs.find(x => x.id === f.parent_id.value);
    f.category.disabled = !!p; if (p) { f.category.value = p.category; f.nature.value = p.nature; }
  };
  m.el.querySelector('[data-save]').onclick = async () => {
    const d = formData(f);
    if (!d.code || !d.name) return toast('رقم الحساب واسمه مطلوبين', 'err');
    const p = accs.find(x => x.id === d.parent_id);
    d.category = p ? p.category : f.category.value;
    d.company_id = S.company.id;
    const res = isNew ? await sb.from('accounts').insert(d) : await sb.from('accounts').update(d).eq('id', a.id);
    if (res.error) return toast(arError(res.error), 'err');
    await log(isNew ? 'إضافة' : 'تعديل', 'accounts', a.id || d.code, { code: d.code, name: d.name });
    if (p) expanded.add(p.id);
    toast('تم الحفظ', 'ok'); m.close(); ctx.rerender();
  };
}

export function downloadCSV(name, rows) {
  const csv = '﻿' + rows.map(r => r.map(x => `"${String(x ?? '').replace(/"/g, '""')}"`).join(',')).join('\r\n');
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }));
  a.download = name; a.click(); setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

// ---------------------------------------------------------------------
//  قوائم السندات (قيد، قبض، صرف)
// ---------------------------------------------------------------------
function voucherList(type) {
  return async function (v, ctx) {
    if (!needCompanyFY(v)) return;
    const T = ENTRY_TYPES[type];
    const [{ data, error }, accs] = await Promise.all([
      sb.from('journal_entries').select('*').eq('company_id', S.company.id).eq('fiscal_year_id', S.fy.id).eq('entry_type', type).order('entry_date', { ascending: false }).order('entry_no', { ascending: false }).limit(2000),
      loadAccounts(),
    ]);
    if (error) throw error;
    const accName = Object.fromEntries(accs.map(a => [a.id, a.name]));
    v.innerHTML = `
      <div class="page-head"><h2>${T.icon} ${T.plural}</h2><span class="badge brand">${data.length}</span><div class="spacer"></div>
        <select class="search" id="st" style="min-width:130px"><option value="">كل الحالات</option><option value="draft">مسودة</option><option value="posted">مرحّل</option><option value="reversed">معكوس</option></select>
        <input class="search" id="q" placeholder="بحث بالرقم أو البيان أو المرجع…">
        ${can(T.screen, 'add') ? `<button class="btn primary" id="add">➕ ${T.label} جديد</button>` : ''}</div>
      ${!accs.length ? `<div class="notice">لازم يكون في دليل حسابات أول. <a href="#/accounts">روح لدليل الحسابات</a></div>` : ''}
      <div class="card table-wrap"><table class="t">
        <thead><tr><th>الرقم</th><th>التاريخ</th>${type !== 'journal' ? `<th>${type === 'receipt' ? 'استلمنا من' : 'صرفنا إلى'}</th><th>${type === 'receipt' ? 'إلى حساب' : 'من حساب'}</th>` : ''}<th>البيان</th><th>المرجع</th><th style="text-align:left">المبلغ</th><th>الحالة</th></tr></thead>
        <tbody id="rows"></tbody></table></div>`;
    const draw = () => {
      const q = v.querySelector('#q').value.trim().toLowerCase(), st = v.querySelector('#st').value;
      const rows = data.filter(e => (!st || e.status === st) && (!q || [docNo(e), String(e.entry_no), e.description, e.reference, e.party_name].some(x => (x || '').toLowerCase().includes(q))));
      v.querySelector('#rows').innerHTML = rows.map(e => `<tr class="click" data-open="${e.id}">
        <td><b dir="ltr">${esc(docNo(e))}</b></td><td>${fmtDate(e.entry_date)}</td>
        ${type !== 'journal' ? `<td>${esc(e.party_name || '')}</td><td>${esc(accName[e.cash_account_id] || '')}</td>` : ''}
        <td>${esc(e.description || '')}</td><td>${esc(e.reference || '')}</td>
        <td dir="ltr" style="text-align:left">${e.status === 'draft' ? '<span class="muted">—</span>' : fmtNum(e.total)}</td><td>${statusBadge(e.status)}</td></tr>`).join('')
        || `<tr><td colspan="8" class="empty">ما في ${T.plural} بهالسنة المالية</td></tr>`;
    };
    draw();
    v.querySelector('#q').oninput = draw; v.querySelector('#st').onchange = draw;
    v.querySelector('#add')?.addEventListener('click', () => voucherEditor(type, null, ctx));
    v.querySelector('#rows').onclick = (e) => { const r = e.target.closest('[data-open]'); if (r) voucherEditor(type, data.find(x => x.id === r.dataset.open), ctx); };
  };
}

// ---------------------------------------------------------------------
//  محرّر السند
// ---------------------------------------------------------------------
async function voucherEditor(type, entry, ctx) {
  const T = ENTRY_TYPES[type];
  const [accs, parties, ccR, curR] = await Promise.all([loadAccounts(), loadParties(),
    sb.from('cost_centers').select('*').eq('company_id', S.company.id).order('code'), sb.from('currencies').select('*').eq('company_id', S.company.id).order('code')]);
  if (!leafAccounts(accs).length) return toast('لازم يكون في حسابات فرعية بدليل الحسابات أول', 'err');
  const ccs = ccR.data || [], curs = (curR.data || []).filter(c => c.is_active);
  const pById = Object.fromEntries(parties.map(p => [p.id, p]));
  let lines = [];
  if (entry) {
    const { data, error } = await sb.from('journal_lines').select('*').eq('entry_id', entry.id).order('line_no');
    if (error) return toast(arError(error), 'err');
    lines = data;
  }
  const isCash = type === 'receipt' || type === 'payment';
  const readOnly = entry && entry.status !== 'draft' || (entry ? !can(T.screen, 'edit') : !can(T.screen, 'add'));
  const manual = await isManual(type);
  await loadPosting();
  const byId = Object.fromEntries(accs.map(a => [a.id, a]));
  const e = entry || { entry_date: today() >= S.fy.start_date && today() <= S.fy.end_date ? today() : S.fy.start_date, description: '', reference: '', party_name: '', cash_account_id: null };

  // للقبض والصرف: السطر رقم 1 هو حساب الصندوق/البنك، والباقي سطور مبالغ
  let rows;
  if (isCash) {
    rows = lines.filter(l => !(l.line_no === 1 && l.account_id === e.cash_account_id))
      .map(l => ({ acc: accLabel(byId[l.account_id]), party: partyLabel(pById[l.party_id]), desc: l.description || '', amount: num(type === 'receipt' ? l.credit : l.debit), cc: l.cost_center_id || '', cur: l.currency || '', fxa: l.fx_amount ?? '', fxr: l.fx_rate ?? '' }));
  } else {
    rows = lines.map(l => ({ acc: accLabel(byId[l.account_id]), party: partyLabel(pById[l.party_id]), desc: l.description || '', debit: num(l.debit), credit: num(l.credit), cc: l.cost_center_id || '', cur: l.currency || '', fxa: l.fx_amount ?? '', fxr: l.fx_rate ?? '' }));
  }
  while (rows.length < (isCash ? 1 : 2)) rows.push(isCash ? { acc: '', desc: '', amount: 0 } : { acc: '', desc: '', debit: 0, credit: 0 });

  if (isCash && !entry) e.cash_account_id = (leafAccounts(accs).find(a => a.account_type === 'cash') || leafAccounts(accs).find(a => a.account_type === 'bank'))?.id || null;
  const cashAccs = leafAccounts(accs).sort((x, y) => (['cash', 'bank'].includes(y.account_type) ? 1 : 0) - (['cash', 'bank'].includes(x.account_type) ? 1 : 0) || x.code.localeCompare(y.code, 'en', { numeric: true }));
  const ro = readOnly ? 'disabled' : '';
  const title = entry ? `${T.label} رقم ${docNo(entry)}` : `${T.label} جديد`;
  const bar = entry ? postBarHTML([{ key: 'gl', posted: entry.status !== 'draft',
    canPost: entry.status === 'draft' && can(T.screen, 'post') && postFlag(type, 'gl'),
    canUnpost: entry.status === 'posted' && !entry.reversal_of && !entry.reversed_by && ['journal', 'receipt', 'payment'].includes(type) && can(T.screen, 'unpost'),
    note: entry.status === 'reversed' ? 'انعمله قيد عكسي' : (!postFlag(type, 'gl') && entry.status === 'draft' ? 'هالنوع مش مفعّل ترحيله (الأدوات ← الترحيل)' : '') }]) : '';
  const dept = await deptField(entry?.department_id, ro, !entry); await loadLookups();
  const m = modal({ title, body: `${bar}
    ${entry ? `<div style="margin:-6px 0 12px">${statusBadge(entry.status)} ${entry.reversal_of ? '<span class="badge brand">قيد عكسي</span>' : ''}
      ${entry.status !== 'draft' ? '<span class="muted" style="font-size:13px"> — القيد المرحّل ما بينعدّل. للتصحيح اعمل «قيد عكسي».</span>' : ''}</div>` : ''}
    <form id="v-form"><div class="grid ${isCash ? 'cols-3' : 'cols-3'}">
      ${manualField(manual, entry?.entry_no, ro)}
      <div class="field"><label>التاريخ *</label><input type="date" name="entry_date" value="${esc(e.entry_date)}" min="${S.fy.start_date}" max="${S.fy.end_date}" ${ro}></div>
      ${isCash ? `<div class="field"><label>${type === 'receipt' ? 'استلمنا من' : 'صرفنا إلى'}</label><input name="party_name" value="${esc(e.party_name)}" ${ro}></div>
        <div class="field"><label>${type === 'receipt' ? 'إلى حساب (الصندوق/البنك) *' : 'من حساب (الصندوق/البنك) *'}</label><select name="cash_account_id" ${ro}>
          <option value="">— اختار —</option>${pmOptions()}${cashAccs.map(a => `<option value="${a.id}" ${a.id === e.cash_account_id ? 'selected' : ''}>${esc(accLabel(a))}${['cash', 'bank'].includes(a.account_type) ? ' ★' : ''}</option>`).join('')}</select></div>` : ''}
      <div class="field"><label>المرجع / رقم الشيك</label><input name="reference" value="${esc(e.reference)}" ${ro}></div>
      ${dept}
      <div class="field" style="grid-column:span 2"><label>البيان</label><input name="description" value="${esc(e.description)}" ${ro}></div>
    </div></form>
    ${accountDatalist(accs)}${partyDatalist(parties)}
    <div class="table-wrap"><table class="t lines" id="lines">
      <thead><tr><th style="width:36px">#</th><th style="min-width:230px">الحساب</th><th style="min-width:170px">العميل / المورد</th><th style="min-width:140px">البيان</th>
        ${ccs.length ? '<th style="width:140px">مركز الكلفة</th>' : ''}${curs.length ? '<th style="min-width:90px">العملة</th><th style="min-width:100px">بالعملة</th><th style="min-width:80px">السعر</th>' : ''}
        ${isCash ? '<th style="width:150px">المبلغ</th>' : '<th style="width:140px">مدين</th><th style="width:140px">دائن</th>'}<th style="width:40px"></th></tr></thead>
      <tbody></tbody>
      <tfoot><tr><td></td><td>${!readOnly ? '<button class="btn sm" id="add-line" type="button">➕ سطر</button>' : ''}</td><td></td><td style="text-align:left" colspan="${1 + (ccs.length ? 1 : 0) + (curs.length ? 3 : 0)}"><b>المجموع</b></td>
        ${isCash ? '<td><b id="t-amt" dir="ltr"></b></td>' : '<td><b id="t-dr" dir="ltr"></b></td><td><b id="t-cr" dir="ltr"></b></td>'}<td></td></tr>
        ${!isCash ? `<tr><td></td><td></td><td></td><td style="text-align:left" colspan="${1 + (ccs.length ? 1 : 0) + (curs.length ? 3 : 0)}">الفرق</td><td colspan="2"><b id="t-diff" dir="ltr"></b></td><td></td></tr>` : ''}
        <tr><td></td><td colspan="${(isCash ? 5 : 6) + (ccs.length ? 1 : 0) + (curs.length ? 3 : 0)}" class="muted" id="t-words" style="font-size:13px"></td></tr></tfoot>
    </table></div>`,
    foot: `
      ${!readOnly ? `<button class="btn primary" data-save>💾 حفظ</button>` : ''}
      ${entry?.status === 'posted' && can(T.screen, 'post') && !entry.reversal_of ? `<button class="btn" data-reverse>↩️ قيد عكسي</button>` : ''}
      ${entry && can(T.screen, 'print') ? `<button class="btn" data-print>🖨️ طباعة</button>` : ''}
      ${entry ? `<button class="btn" data-attach>📎 مرفقات</button>` : ''}
      ${entry && ['journal', 'receipt', 'payment'].includes(type) && can('journal_entries', 'add') ? `<button class="btn" data-recur>🔁 تكرار شهري</button>` : ''}
      ${entry?.status === 'draft' && can(T.screen, 'delete') ? `<button class="btn danger" data-del style="margin-inline-start:auto">حذف</button>` : ''}
      <button class="btn" data-close>إغلاق</button>` });
  m.el.querySelector('.modal').style.maxWidth = ccs.length || curs.length ? '1320px' : '1000px';
  if (entry) attachAudit(m.el, entry);
  const tb = m.el.querySelector('#lines tbody');

  const drawRows = () => {
    tb.innerHTML = rows.map((r, i) => `<tr>
      <td class="muted">${i + 1}</td>
      <td><input list="acc-list" data-i="${i}" data-k="acc" value="${esc(r.acc)}" placeholder="رقم أو اسم الحساب…" ${ro} class="cell"></td>
      <td><input list="party-list" data-i="${i}" data-k="party" value="${esc(r.party || '')}" placeholder="اختياري" ${ro} class="cell"></td>
      <td><input data-i="${i}" data-k="desc" value="${esc(r.desc)}" ${ro} class="cell"></td>
      ${ccs.length ? `<td><select data-i="${i}" data-k="cc" class="cell" ${ro}><option value=""></option>${ccs.map(c => `<option value="${c.id}" ${c.id === r.cc ? 'selected' : ''}>${esc(c.name)}</option>`).join('')}</select></td>` : ''}
      ${curs.length ? `<td><select data-i="${i}" data-k="cur" class="cell" ${ro}><option value="">دينار</option>${curs.map(c => `<option value="${esc(c.code)}" ${c.code === r.cur ? 'selected' : ''}>${esc(c.code)}</option>`).join('')}</select></td>
        <td><input data-i="${i}" data-k="fxa" value="${r.fxa ?? ''}" inputmode="decimal" dir="ltr" class="cell n" ${ro || (r.cur ? '' : 'disabled')}></td>
        <td><input data-i="${i}" data-k="fxr" value="${r.fxr ?? ''}" inputmode="decimal" dir="ltr" class="cell n" ${ro || (r.cur ? '' : 'disabled')}></td>` : ''}
      ${isCash ? `<td><input data-i="${i}" data-k="amount" value="${r.amount || ''}" inputmode="decimal" dir="ltr" ${ro} class="cell n"></td>`
               : `<td><input data-i="${i}" data-k="debit" value="${r.debit || ''}" inputmode="decimal" dir="ltr" ${ro} class="cell n"></td>
                  <td><input data-i="${i}" data-k="credit" value="${r.credit || ''}" inputmode="decimal" dir="ltr" ${ro} class="cell n"></td>`}
      <td>${!readOnly ? `<button class="x" data-rm="${i}" type="button" title="حذف السطر">×</button>` : ''}</td></tr>`).join('');
    totals();
  };
  const totals = () => {
    if (isCash) {
      const t = rows.reduce((s, r) => s + num(r.amount), 0);
      m.el.querySelector('#t-amt').textContent = fmtNum(t);
      m.el.querySelector('#t-words').textContent = t ? amountToWords(t) : '';
    } else {
      const d = rows.reduce((s, r) => s + num(r.debit), 0), c = rows.reduce((s, r) => s + num(r.credit), 0);
      m.el.querySelector('#t-dr').textContent = fmtNum(d); m.el.querySelector('#t-cr').textContent = fmtNum(c);
      const diff = Math.round((d - c) * 1000) / 1000, el = m.el.querySelector('#t-diff');
      el.textContent = diff ? fmtNum(Math.abs(diff)) + (diff > 0 ? ' (مدين أكثر)' : ' (دائن أكثر)') : '✓ متوازن';
      el.style.color = diff ? 'var(--bad)' : 'var(--ok)';
      m.el.querySelector('#t-words').textContent = d ? amountToWords(d) : '';
    }
  };
  drawRows();
  tb.addEventListener('input', (ev) => {
    const t = ev.target; if (!t.dataset.k) return;
    const r = rows[+t.dataset.i];
    r[t.dataset.k] = t.dataset.k === 'acc' || t.dataset.k === 'desc' ? t.value : t.value;
    if (t.dataset.k === 'debit' && num(t.value)) { r.credit = 0; const o = tb.querySelector(`[data-i="${t.dataset.i}"][data-k="credit"]`); if (o) o.value = ''; }
    if (t.dataset.k === 'credit' && num(t.value)) { r.debit = 0; const o = tb.querySelector(`[data-i="${t.dataset.i}"][data-k="debit"]`); if (o) o.value = ''; }
    if ((t.dataset.k === 'fxa' || t.dataset.k === 'fxr') && r.cur) {   // المبلغ بالدينار = بالعملة × السعر
      const v = Math.round(num(r.fxa) * num(r.fxr) * 1000) / 1000, i = t.dataset.i;
      const k = isCash ? 'amount' : (num(r.credit) && !num(r.debit) ? 'credit' : 'debit');
      r[k] = v; const o = tb.querySelector(`[data-i="${i}"][data-k="${k}"]`); if (o) o.value = v || '';
    }
    totals();
  });
  tb.addEventListener('change', (ev) => {
    const t = ev.target;
    if (t.dataset.k === 'cc') { rows[+t.dataset.i].cc = t.value; return; }
    if (t.dataset.k === 'cur') { const r = rows[+t.dataset.i]; r.cur = t.value;
      if (t.value) { r.fxr = curs.find(c => c.code === t.value)?.rate || r.fxr;
        if (num(r.fxa)) { const v = Math.round(num(r.fxa) * num(r.fxr) * 1000) / 1000; const k = isCash ? 'amount' : (num(r.credit) && !num(r.debit) ? 'credit' : 'debit'); r[k] = v; } }
      else { r.fxa = ''; r.fxr = ''; } drawRows(); return; }
    if (t.dataset.k === 'party') {
      const p = resolveParty(parties, t.value), r = rows[+t.dataset.i];
      t.classList.toggle('bad', !!t.value && !p);
      if (p) {
        t.value = partyLabel(p); r.party = t.value;
        if (!resolveAccount(accs, r.acc)) { r.acc = accLabel(byId[p.account_id]); const ai = tb.querySelector(`[data-i="${t.dataset.i}"][data-k="acc"]`); if (ai) ai.value = r.acc; }
        const pn = m.el.querySelector('[name=party_name]'); if (pn && !pn.value) pn.value = p.name;
      }
      return;
    }
    if (t.dataset.k !== 'acc') return;
    const a = resolveAccount(accs, t.value);
    t.classList.toggle('bad', !!t.value && !a);
    if (a) { t.value = accLabel(a); rows[+t.dataset.i].acc = t.value; }
  });
  tb.addEventListener('keydown', (ev) => {   // Enter على آخر خانة بيضيف سطر
    if (ev.key !== 'Enter' || readOnly) return; ev.preventDefault();
    const i = +ev.target.dataset.i;
    if (i === rows.length - 1) { addLine(); }
    tb.querySelector(`[data-i="${i + 1}"][data-k="acc"]`)?.focus();
  });
  tb.addEventListener('click', (ev) => { const b = ev.target.closest('[data-rm]'); if (!b) return; rows.splice(+b.dataset.rm, 1); if (!rows.length) addLine(false); drawRows(); });
  const addLine = (redraw = true) => {
    if (isCash) rows.push({ acc: '', party: '', desc: '', amount: 0 });
    else {   // اقتراح المبلغ اللي بيوازن القيد
      const d = rows.reduce((s, r) => s + num(r.debit), 0), c = rows.reduce((s, r) => s + num(r.credit), 0);
      rows.push({ acc: '', desc: rows.at(-1)?.desc || '', debit: c > d ? Math.round((c - d) * 1000) / 1000 : 0, credit: d > c ? Math.round((d - c) * 1000) / 1000 : 0 });
    }
    if (redraw) drawRows();
  };
  m.el.querySelector('#add-line')?.addEventListener('click', () => addLine());

  const fxBad = (r) => r.cur && num(r.fxa) && Math.abs(num(r.fxa) * num(r.fxr) - (isCash ? num(r.amount) : num(r.debit) + num(r.credit))) > 0.0015;
  const extra = (r) => ({ cost_center_id: r.cc || null, currency: r.cur || null, fx_rate: r.cur && num(r.fxr) ? num(r.fxr) : null, fx_amount: r.cur && num(r.fxa) ? num(r.fxa) : null });
  const save = async (post) => {
    const h = formData(m.el.querySelector('#v-form'));
    if (!h.entry_date) return toast('التاريخ مطلوب', 'err');
    if (h.entry_date < S.fy.start_date || h.entry_date > S.fy.end_date) return toast('التاريخ لازم يكون جوّا السنة المالية الحالية', 'err');
    const mn = readManual(m.el.querySelector('#v-form'), manual);
    if (!mn.ok) return toast('الترقيم يدوي: اكتب رقم المستند (رقم صحيح أكبر من صفر)', 'err');
    const out = [];
    for (const [i, r] of rows.entries()) {
      const empty = !r.acc && !r.party && !num(r.amount) && !num(r.debit) && !num(r.credit);
      if (empty) continue;
      const a = resolveAccount(accs, r.acc);
      if (!a) return toast(`السطر ${i + 1}: اختار حساب صحيح من القائمة`, 'err');
      if (fxBad(r)) return toast(`السطر ${i + 1}: المبلغ بالدينار لازم يساوي المبلغ بالعملة × السعر`, 'err');
      const pt = resolveParty(parties, r.party);
      if (r.party && !pt) return toast(`السطر ${i + 1}: العميل/المورد مش موجود بالقائمة`, 'err');
      const party_id = pt?.id || null;
      if (isCash) {
        if (!num(r.amount)) return toast(`السطر ${i + 1}: المبلغ مطلوب`, 'err');
        out.push({ account_id: a.id, party_id, description: r.desc || null, debit: type === 'payment' ? num(r.amount) : 0, credit: type === 'receipt' ? num(r.amount) : 0, ...extra(r) });
      } else {
        if (!num(r.debit) && !num(r.credit)) return toast(`السطر ${i + 1}: اكتب مبلغ مدين أو دائن`, 'err');
        out.push({ account_id: a.id, party_id, description: r.desc || null, debit: num(r.debit), credit: num(r.credit), ...extra(r) });
      }
    }
    if (isCash) {
      if (!h.cash_account_id) return toast('اختار حساب الصندوق أو البنك', 'err');
      if (!out.length) return toast('أضف سطر واحد على الأقل', 'err');
      if (out.some(l => l.account_id === h.cash_account_id)) return toast('ما بيصير نفس حساب الصندوق/البنك يكون بالسطور', 'err');
      const t = out.reduce((s, l) => s + l.debit + l.credit, 0);
      out.unshift({ account_id: h.cash_account_id, description: h.description, debit: type === 'receipt' ? t : 0, credit: type === 'payment' ? t : 0 });
    } else {
      if (out.length < 2) return toast('القيد لازم يكون فيه سطرين على الأقل', 'err');
      const d = out.reduce((s, l) => s + l.debit, 0), c = out.reduce((s, l) => s + l.credit, 0);
      if (post && Math.abs(d - c) > 0.0005) return toast('القيد مش متوازن، ما بينرحّل', 'err');
    }
    const header = { entry_date: h.entry_date, description: h.description, reference: h.reference,
                     party_name: isCash ? h.party_name : null, cash_account_id: isCash ? h.cash_account_id : null, ...deptValue(m.el.querySelector('#v-form')),
                     ...(mn.value ? { entry_no: mn.value } : {}) };
    const btns = m.el.querySelectorAll('.modal-foot .btn'); btns.forEach(b => b.disabled = true);
    try {
      let id = entry?.id;
      if (id) {
        const u = await sb.from('journal_entries').update(header).eq('id', id); if (u.error) throw u.error;
        const d = await sb.from('journal_lines').delete().eq('entry_id', id); if (d.error) throw d.error;
      } else {
        const ins = await sb.from('journal_entries').insert({ ...header, company_id: S.company.id, fiscal_year_id: S.fy.id, entry_type: type }).select().single();
        if (ins.error) throw ins.error; id = ins.data.id; entry = ins.data;
      }
      const li = await sb.from('journal_lines').insert(out.map((l, k) => ({ ...l, entry_id: id, line_no: k + 1 })));
      if (li.error) throw li.error;
      await log(entry && entry.id === id && !post ? 'حفظ' : 'إضافة', T.screen, id, { no: entry?.entry_no });
      if (post) { const p = await sb.rpc('post_entry', { p_id: id }); if (p.error) { toast(arError(p.error), 'err'); return reopen(id); } toast('انحفظ وانرحّل للمحاسبة', 'ok'); }
      else toast('تم الحفظ', 'ok');
      reopen(id);
    } catch (err) { toast(arError(err), 'err'); btns.forEach(b => b.disabled = false); }
  };
  // بعد الحفظ أو الترحيل: السند بيضل مفتوح عشان تبيّن كبسات الترحيل
  const reopen = async (id) => {
    m.close(); ctx.rerender();
    const { data } = await sb.from('journal_entries').select('*').eq('id', id).single();
    if (data) voucherEditor(type, data, ctx);
  };
  m.el.querySelector('[data-save]')?.addEventListener('click', () => save(false));
  // كبسة «ترحيل للمحاسبة»: إذا السند لسا مسودة بيحفظ التعديلات أول وبعدين بيرحّل
  m.el.querySelector('[data-postdo=gl]')?.addEventListener('click', (ev) => { if (!readOnly) { ev.stopImmediatePropagation(); save(true); } });
  if (entry) wirePostBar(m.el, 'entry', entry.id, () => reopen(entry.id));
  m.el.querySelector('[data-attach]')?.addEventListener('click', () => openAttachments('entry', entry.id, `${T.label} رقم ${docNo(entry)}`));
  m.el.querySelector('[data-recur]')?.addEventListener('click', () => recurringDialog(entry));
  m.el.querySelector('[data-del]')?.addEventListener('click', async () => {
    if (!(await confirmBox(`حذف ${T.label} رقم ${docNo(entry)}؟`))) return;
    const { error } = await sb.from('journal_entries').delete().eq('id', entry.id);
    if (error) return toast(arError(error), 'err');
    await log('حذف', T.screen, entry.id, { no: entry.entry_no });
    toast('تم الحذف', 'ok'); m.close(); ctx.rerender();
  });
  m.el.querySelector('[data-reverse]')?.addEventListener('click', async () => {
    const d = prompt('تاريخ القيد العكسي (YYYY-MM-DD):', today() <= S.fy.end_date && today() >= S.fy.start_date ? today() : entry.entry_date);
    if (!d) return;
    const { error } = await sb.rpc('reverse_entry', { p_id: entry.id, p_date: d });
    if (error) return toast(arError(error), 'err');
    toast('تم عمل القيد العكسي وترحيله', 'ok'); m.close(); ctx.rerender();
  });
  m.el.querySelector('[data-print]')?.addEventListener('click', () => printVoucher(type, entry, lines, byId));
}

function printVoucher(type, e, lines, byId) {
  const T = ENTRY_TYPES[type];
  const isCash = type === 'receipt' || type === 'payment';
  const body = isCash ? lines.filter(l => l.line_no !== 1) : lines;
  const total = isCash ? body.reduce((s, l) => s + num(l.debit) + num(l.credit), 0) : lines.reduce((s, l) => s + num(l.debit), 0);
  printDoc(`${T.label} رقم ${docNo(e)}`, `
    <table class="meta"><tr><td><b>التاريخ:</b> ${fmtDate(e.entry_date)}</td><td><b>الحالة:</b> ${STATUS[e.status][0]}</td><td><b>المرجع:</b> ${esc(e.reference || '—')}</td></tr>
      ${isCash ? `<tr><td colspan="2"><b>${type === 'receipt' ? 'استلمنا من السيد/السادة' : 'صرفنا إلى السيد/السادة'}:</b> ${esc(e.party_name || '')}</td><td><b>${type === 'receipt' ? 'إلى حساب' : 'من حساب'}:</b> ${esc(byId[e.cash_account_id]?.name || '')}</td></tr>` : ''}
      <tr><td colspan="3"><b>البيان:</b> ${esc(e.description || '')}</td></tr></table>
    ${isCash ? `<div class="amount-box">مبلغ وقدره: <b>${fmtNum(total)}</b> دينار<br><span>${amountToWords(total)}</span></div>` : ''}
    <table class="pt"><thead><tr><th>#</th><th>رقم الحساب</th><th>اسم الحساب</th><th>البيان</th>${isCash ? '<th>المبلغ</th>' : '<th>مدين</th><th>دائن</th>'}</tr></thead><tbody>
      ${body.map((l, i) => `<tr><td>${i + 1}</td><td>${esc(byId[l.account_id]?.code)}</td><td>${esc(byId[l.account_id]?.name)}${l.party_id && S.parties ? ' — ' + esc(S.parties.find(p => p.id === l.party_id)?.name || '') : ''}</td><td>${esc(l.description || '')}</td>
        ${isCash ? `<td class="n">${fmtNum(num(l.debit) + num(l.credit))}</td>` : `<td class="n">${num(l.debit) ? fmtNum(l.debit) : ''}</td><td class="n">${num(l.credit) ? fmtNum(l.credit) : ''}</td>`}</tr>`).join('')}
      </tbody><tfoot><tr><td colspan="4"><b>المجموع</b> — ${amountToWords(total)}</td>${isCash ? `<td class="n"><b>${fmtNum(total)}</b></td>` : `<td class="n"><b>${fmtNum(total)}</b></td><td class="n"><b>${fmtNum(lines.reduce((s, l) => s + num(l.credit), 0))}</b></td>`}</tr></tfoot></table>`, { kind: type === 'receipt' ? 'receipt' : type === 'payment' ? 'payment' : 'journal' });
}

// ---------------------------------------------------------------------
//  الأرصدة الافتتاحية
// ---------------------------------------------------------------------
async function viewOpening(v, ctx) {
  if (!needCompanyFY(v)) return;
  const [accs, parties] = await Promise.all([loadAccounts(), loadParties()]);
  if (!accs.length) return void (v.innerHTML = `<div class="notice">لازم يكون في دليل حسابات أول. <a href="#/accounts">روح لدليل الحسابات</a></div>`);
  const { data: ents, error } = await sb.from('journal_entries').select('*').eq('company_id', S.company.id).eq('fiscal_year_id', S.fy.id).eq('entry_type', 'opening').order('created_at', { ascending: false });
  if (error) throw error;
  let entry = (ents || []).find(x => x.status !== 'reversed') || null;
  let lines = [];
  if (entry) { const r = await sb.from('journal_lines').select('*').eq('entry_id', entry.id); lines = r.data || []; }
  // أرصدة الحسابات العادية، وأرصدة العملاء والموردين لحالها
  const vals = {}, pvals = {};
  lines.forEach(l => { const t = l.party_id ? (pvals[l.party_id] ||= { d: 0, c: 0 }) : (vals[l.account_id] ||= { d: 0, c: 0 }); t.d += num(l.debit); t.c += num(l.credit); });
  // حسابات إجمالية بتتعبّى من أرصدة الأطراف (إلا إذا إلها رصيد قديم بدون طرف)
  const partyAcc = new Set(parties.map(p => p.account_id).filter(id => !(vals[id] && (vals[id].d || vals[id].c))));
  const leaves = accs.filter(a => !a.is_group && (a.is_active || vals[a.id] || partyAcc.has(a.id))).sort((x, y) => x.code.localeCompare(y.code, 'en', { numeric: true }));
  const plist = parties.filter(p => p.is_active || pvals[p.id]);
  const readOnly = (entry && entry.status !== 'draft') || !(entry ? can('opening_balances', 'edit') : can('opening_balances', 'add'));
  const dis = readOnly ? 'disabled' : '';
  const CAT = { assets: 'موجودات', liabilities: 'مطلوبات', equity: 'حقوق ملكية', revenue: 'إيرادات', expenses: 'مصاريف' };
  v.innerHTML = `
    <div class="page-head"><h2>🧮 الأرصدة الافتتاحية</h2><span class="muted">${esc(S.fy.name || S.fy.code)} — بتاريخ ${fmtDate(S.fy.start_date)}</span>
      ${entry ? statusBadge(entry.status) : ''}<div class="spacer"></div>
      <input class="search" id="q" placeholder="بحث…">
      <label class="check" style="margin:0"><input type="checkbox" id="only"> اللي إلها رصيد بس</label></div>
    ${entry?.status === 'posted' ? `<div class="notice info">الأرصدة الافتتاحية مرحّلة. لأي تعديل اعمل <a href="#/journal">سند قيد</a> تسوية.</div>` : ''}
    ${plist.length ? `<div class="tabs"><div class="tab active" data-tab="acc">الحسابات</div><div class="tab" data-tab="par">العملاء والموردين (${plist.length})</div></div>` : ''}
    <div class="tab-panel active" data-tab="acc"><div class="card table-wrap"><table class="t lines" id="ob">
      <thead><tr><th style="width:120px">رقم الحساب</th><th>اسم الحساب</th><th>التصنيف</th><th style="width:160px">مدين</th><th style="width:160px">دائن</th></tr></thead>
      <tbody>${leaves.map(a => `<tr data-row="a:${a.id}" data-s="${esc((a.code + ' ' + a.name).toLowerCase())}">
        <td dir="ltr" style="text-align:right">${esc(a.code)}</td><td>${esc(a.name)}${partyAcc.has(a.id) ? ' <span class="badge brand">من أرصدة العملاء/الموردين</span>' : ''}</td><td class="muted">${CAT[a.category] || ''}</td>
        <td><input class="cell n" dir="ltr" inputmode="decimal" data-a="${a.id}" data-k="d" value="${vals[a.id]?.d || ''}" ${dis || (partyAcc.has(a.id) ? 'disabled' : '')}></td>
        <td><input class="cell n" dir="ltr" inputmode="decimal" data-a="${a.id}" data-k="c" value="${vals[a.id]?.c || ''}" ${dis || (partyAcc.has(a.id) ? 'disabled' : '')}></td></tr>`).join('')}</tbody></table></div></div>
    <div class="tab-panel" data-tab="par"><div class="card table-wrap"><table class="t lines" id="obp">
      <thead><tr><th style="width:90px">الرقم</th><th>الاسم</th><th>النوع</th><th>الحساب</th><th style="width:160px">مدين</th><th style="width:160px">دائن</th></tr></thead>
      <tbody>${plist.map(p => `<tr data-row="p:${p.id}" data-s="${esc((p.code + ' ' + p.name).toLowerCase())}">
        <td>${esc(p.code)}</td><td>${esc(p.name)}</td><td>${p.party_type === 'customer' ? 'عميل' : p.party_type === 'supplier' ? 'مورد' : 'مصروف'}</td><td class="muted">${esc(accs.find(a => a.id === p.account_id)?.name || '')}</td>
        <td><input class="cell n" dir="ltr" inputmode="decimal" data-p="${p.id}" data-k="d" value="${pvals[p.id]?.d || ''}" ${dis}></td>
        <td><input class="cell n" dir="ltr" inputmode="decimal" data-p="${p.id}" data-k="c" value="${pvals[p.id]?.c || ''}" ${dis}></td></tr>`).join('')}</tbody></table></div>
      <p class="muted" style="font-size:13px">رصيد العميل عادة مدين (إله علينا نحصّله)، ورصيد المورد عادة دائن.</p></div>
    <div class="card" style="margin-top:12px;display:flex;gap:24px;flex-wrap:wrap;align-items:center">
      <div>مجموع المدين: <b id="td" dir="ltr"></b></div><div>مجموع الدائن: <b id="tc" dir="ltr"></b></div><div>الفرق: <b id="tf" dir="ltr"></b></div>
      <div class="spacer" style="flex:1"></div>
      ${!readOnly ? `<button class="btn primary" id="save">💾 حفظ مسودة</button>` : ''}
      ${!readOnly && can('opening_balances', 'post') ? `<button class="btn primary" id="savepost">✅ حفظ وترحيل</button>` : ''}
      ${entry && can('opening_balances', 'print') ? `<button class="btn" id="prn">🖨️ طباعة</button>` : ''}
    </div>`;
  v.querySelectorAll('.tabs').forEach(tabs => tabs.addEventListener('click', ev => {
    const t = ev.target.closest('.tab'); if (!t) return;
    tabs.querySelectorAll('.tab').forEach(x => x.classList.toggle('active', x === t));
    v.querySelectorAll('.tab-panel').forEach(x => x.classList.toggle('active', x.dataset.tab === t.dataset.tab));
  }));
  const syncPartyAccounts = () => {     // مجموع أرصدة الأطراف على حساباتهم الإجمالية
    const sums = {};
    plist.forEach(p => { const x = pvals[p.id]; if (!x) return; const s2 = sums[p.account_id] ||= 0; sums[p.account_id] = s2 + (x.d || 0) - (x.c || 0); });
    partyAcc.forEach(id => { const n = sums[id] || 0;
      const d = v.querySelector(`[data-a="${id}"][data-k="d"]`), c = v.querySelector(`[data-a="${id}"][data-k="c"]`);
      if (d) d.value = n > 0 ? fmtNum(n) : ''; if (c) c.value = n < 0 ? fmtNum(-n) : ''; });
  };
  const tot = () => {
    let d = 0, c = 0;
    Object.entries(vals).forEach(([id, x]) => { if (!partyAcc.has(id)) { d += x.d || 0; c += x.c || 0; } });
    Object.values(pvals).forEach(x => { d += x.d || 0; c += x.c || 0; });
    v.querySelector('#td').textContent = fmtNum(d); v.querySelector('#tc').textContent = fmtNum(c);
    const f = Math.round((d - c) * 1000) / 1000, el = v.querySelector('#tf');
    el.textContent = f ? fmtNum(Math.abs(f)) + (f > 0 ? ' (مدين أكثر)' : ' (دائن أكثر)') : '✓ متوازن'; el.style.color = f ? 'var(--bad)' : 'var(--ok)';
    syncPartyAccounts();
  };
  tot();
  const onInput = (e) => {
    const t = e.target; if (!t.dataset.k || !(t.dataset.a || t.dataset.p)) return;
    const store = t.dataset.a ? vals : pvals, key = t.dataset.a || t.dataset.p, attr = t.dataset.a ? 'a' : 'p';
    const x = store[key] ||= { d: 0, c: 0 };
    x[t.dataset.k] = num(t.value);
    if (x[t.dataset.k]) { const o = t.dataset.k === 'd' ? 'c' : 'd'; x[o] = 0; v.querySelector(`[data-${attr}="${key}"][data-k="${o}"]`).value = ''; }
    tot();
  };
  v.querySelectorAll('#ob, #obp').forEach(t => t.addEventListener('input', onInput));
  const filter = () => {
    const q = v.querySelector('#q').value.trim().toLowerCase(), only = v.querySelector('#only').checked;
    v.querySelectorAll('[data-row]').forEach(r => { const [k, id] = r.dataset.row.split(':'); const x = k === 'a' ? vals[id] : pvals[id];
      r.style.display = (!q || r.dataset.s.includes(q)) && (!only || (x && (x.d || x.c)) || (k === 'a' && partyAcc.has(id))) ? '' : 'none'; });
  };
  v.querySelector('#q').oninput = filter; v.querySelector('#only').onchange = filter;
  const save = async (post) => {
    const out = [];
    Object.entries(vals).forEach(([id, x]) => { if (!partyAcc.has(id) && (x.d || x.c)) out.push({ account_id: id, party_id: null, debit: x.d || 0, credit: x.c || 0, description: 'رصيد افتتاحي' }); });
    plist.forEach(p => { const x = pvals[p.id]; if (x && (x.d || x.c)) out.push({ account_id: p.account_id, party_id: p.id, debit: x.d || 0, credit: x.c || 0, description: 'رصيد افتتاحي - ' + p.name }); });
    if (out.length < 2) return toast('أدخل أرصدة لحسابين على الأقل', 'err');
    const d = out.reduce((s2, l) => s2 + l.debit, 0), c = out.reduce((s2, l) => s2 + l.credit, 0);
    if (post && Math.abs(d - c) > 0.0005) return toast('الأرصدة مش متوازنة، ما بتنرحّل', 'err');
    try {
      let id = entry?.id;
      if (!id) {
        const ins = await sb.from('journal_entries').insert({ company_id: S.company.id, fiscal_year_id: S.fy.id, entry_type: 'opening', entry_date: S.fy.start_date, description: 'الأرصدة الافتتاحية ' + (S.fy.name || S.fy.code) }).select().single();
        if (ins.error) throw ins.error; id = ins.data.id; entry = ins.data;
      } else {
        const del = await sb.from('journal_lines').delete().eq('entry_id', id); if (del.error) throw del.error;
      }
      const li = await sb.from('journal_lines').insert(out.map((l, k) => ({ ...l, entry_id: id, line_no: k + 1 }))); if (li.error) throw li.error;
      await log('حفظ', 'opening_balances', id, { lines: out.length });
      if (post) { const p2 = await sb.rpc('post_entry', { p_id: id }); if (p2.error) throw p2.error; toast('تم الحفظ والترحيل', 'ok'); }
      else toast('تم الحفظ كمسودة', 'ok');
      ctx.rerender();
    } catch (err) { toast(arError(err), 'err'); }
  };
  v.querySelector('#save')?.addEventListener('click', () => save(false));
  v.querySelector('#savepost')?.addEventListener('click', () => save(true));
  v.querySelector('#prn')?.addEventListener('click', () => {
    const byId = Object.fromEntries(accs.map(a => [a.id, a]));
    printVoucher('opening', entry, lines, byId);
  });
}

export const FINANCE_ROUTES = {
  'accounts': viewAccounts,
  'opening': viewOpening,
  'journal': voucherList('journal'),
  'receipts': voucherList('receipt'),
  'payments': voucherList('payment'),
};
