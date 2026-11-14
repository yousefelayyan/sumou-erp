// =====================================================================
//  السمو ERP — المرحلة 2: المالية
//  دليل الحسابات، الأرصدة الافتتاحية، سندات القيد والقبض والصرف
// =====================================================================
import { attachAudit } from './audit.js';
import { docTypeField, docTypeValue, docCopies, docTypeName, loadDocTypes, docCommittee } from './doctypes.js';
import { attachDocNav, setNavList } from './docnav.js';
import { docNo, loadNumbering, isManual, manualField, readManual, masterCode } from './numbering.js';
import { loadPosting, postFlag, postBarHTML, wirePostBar } from './posting.js';
import { S, sb, esc, fmtDate, fmtNum, num, today, toast, arError, modal, confirmBox, formData, can, log, qm , takeOpenParam } from './core.js';
import { printDoc, amountToWords } from './print.js';
import { openAttachments } from './attach.js';
import { recurringDialog } from './extras.js';
import { loadParties, partyDatalist, resolveParty, partyLabel } from './parties.js';
import { deptField, deptValue } from './departments.js';
import { loadLookups, pmOptions } from './lookups.js';
import { attachFollow } from './follow.js';

export const CATEGORIES = { assets: 'الموجودات', liabilities: 'المطلوبات', equity: 'حقوق الملكية', revenue: 'الإيرادات', expenses: 'المصاريف' };
export const NATURES = { debit: 'مدين', credit: 'دائن', both: 'مدين ودائن' };
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
      const match = new Set(accs.filter(a => qm([a.code, a.name], q)).map(a => a.id));
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
        <td>${(NATURES[a.nature] || '')}</td>
        <td dir="ltr" style="text-align:left;${a.is_group ? 'font-weight:700' : ''}">${Math.abs(b) >= 0.0005 ? `${fmtNum(Math.abs(b))} <span class="muted" style="font-size:11px">${b > 0 ? 'مدين' : 'دائن'}</span>` : '<span class="muted">—</span>'}</td>
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
      accs.map(a => [a.code, a.name, accs.find(p => p.id === a.parent_id)?.code || '', a.is_group ? 'نعم' : 'لا', CATEGORIES[a.category], (NATURES[a.nature] || ''), ACC_TYPES[a.account_type], (rolled[a.id] || 0).toFixed(3)])));
  v.querySelector('#prn')?.addEventListener('click', () => {
    const rows = [...accs].sort((x, y) => x.code.localeCompare(y.code, 'en', { numeric: true }));
    printDoc('دليل الحسابات', `<table class="pt"><thead><tr><th>رقم الحساب</th><th>اسم الحساب</th><th>الطبيعة</th><th>الرصيد</th></tr></thead><tbody>
      ${rows.map(a => `<tr style="${a.is_group ? 'font-weight:700;background:#f6f2fa' : ''}"><td>${esc(a.code)}</td><td style="padding-right:${(a.level - 1) * 16 + 6}px">${esc(a.name)}</td>
      <td>${(NATURES[a.nature] || '')}</td><td class="n">${rolled[a.id] ? fmtNum(rolled[a.id]) : ''}</td></tr>`).join('')}</tbody></table>`);
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
        <option value="debit" ${a.nature === 'debit' ? 'selected' : ''}>مدين</option><option value="credit" ${a.nature === 'credit' ? 'selected' : ''}>دائن</option><option value="both" ${a.nature === 'both' ? 'selected' : ''}>مدين ودائن (الرصيد بيظهر بجهته)</option></select></div>
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
      const rows = data.filter(e => (!st || e.status === st) && (!q || qm([docNo(e), String(e.entry_no), e.description, e.reference, e.party_name], q)));
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
    { const oid = takeOpenParam(); if (oid) { let row = data.find(x => x.id === oid); if (!row) row = (await sb.from('journal_entries').select('*').eq('id', oid).maybeSingle()).data; if (row && row.entry_type === type) voucherEditor(type, row, ctx); } }
    v.querySelector('#rows').onclick = (e) => { const r = e.target.closest('[data-open]'); if (r) { setNavList('je:' + type, [...v.querySelectorAll('#rows [data-open]')].map(tr => data.find(x => x.id === tr.dataset.open)).filter(Boolean)); voucherEditor(type, data.find(x => x.id === r.dataset.open), ctx); } };
  };
}

// ---------------------------------------------------------------------
//  محرّر السند
// ---------------------------------------------------------------------
// فتح سند جديد معبّى (مثلاً دفعة مقدمة على طلب مبيعات)
export function openVoucher(type, prefill, ctx) { return voucherEditor(type, null, ctx || { rerender() { } }, prefill); }
async function voucherEditor(type, entry, ctx, prefill = null) {
  const T = ENTRY_TYPES[type];
  const [accs, parties, ccR, curR, empR] = await Promise.all([loadAccounts(), loadParties(),
    sb.from('cost_centers').select('*').eq('company_id', S.company.id).order('code'), sb.from('currencies').select('*').eq('company_id', S.company.id).order('code'),
    sb.from('employees').select('id,code,name,is_active').eq('company_id', S.company.id).order('code')]);
  // الموظف بخانة الطرف (المرحلة 68): «👷 رمز — اسم»
  const emps = empR.data || [], empById = Object.fromEntries(emps.map(x => [x.id, x]));
  const empLabel = (x) => x ? `👷 ${x.code} — ${x.name}` : '';
  const resolveEmp = (t) => { t = (t || '').replace('👷', '').trim(); if (!t) return null; const c = t.split('—')[0].trim(); return emps.find(x => x.code === c) || emps.find(x => x.name === t) || null; };
  const sideLabel = (l) => l.employee_id ? empLabel(empById[l.employee_id]) : partyLabel(pById[l.party_id]);
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
  let linkedChq = [];
  if (entry && type === 'receipt') { const { data } = await sb.from('cheques').select('id,cheque_no,bank_name,due_date,amount,status,drawer_name').eq('receipt_entry_id', entry.id).order('due_date'); linkedChq = data || []; }
  const chqAdd = type === 'receipt' && can('cheques', 'add') && (!entry || !['reversed', 'cancelled'].includes(entry.status) && !entry.reversal_of && !entry.is_frozen);
  const readOnly = entry && entry.status !== 'draft' || (entry ? !can(T.screen, 'edit') : !can(T.screen, 'add'));
  const manual = await isManual(type);
  await loadPosting();
  const byId = Object.fromEntries(accs.map(a => [a.id, a]));
  const e = entry || { entry_date: today() >= S.fy.start_date && today() <= S.fy.end_date ? today() : S.fy.start_date, description: prefill?.description || '', reference: prefill?.reference || '', party_name: '', cash_account_id: null };

  // للقبض والصرف: السطر رقم 1 هو حساب الصندوق/البنك، والباقي سطور مبالغ
  let rows;
  if (isCash) {
    rows = lines.filter(l => !(l.line_no === 1 && l.account_id === e.cash_account_id) && !(type === 'receipt' && num(l.debit) > 0))
      .map(l => ({ acc: accLabel(byId[l.account_id]), party: sideLabel(l), desc: l.description || '', amount: num(type === 'receipt' ? l.credit : l.debit), cc: l.cost_center_id || '', cur: l.currency || '', fxa: l.fx_amount ?? '', fxr: l.fx_rate ?? '' }));
  } else {
    rows = lines.map(l => ({ acc: accLabel(byId[l.account_id]), party: sideLabel(l), desc: l.description || '', debit: num(l.debit), credit: num(l.credit), cc: l.cost_center_id || '', cur: l.currency || '', fxa: l.fx_amount ?? '', fxr: l.fx_rate ?? '' }));
  }
  if (!entry && prefill?.party_id && pById[prefill.party_id]) { const pp = pById[prefill.party_id];
    rows = [isCash ? { acc: accLabel(byId[pp.account_id]), party: partyLabel(pp), desc: prefill.description || '', amount: num(prefill.amount) } : { acc: accLabel(byId[pp.account_id]), party: partyLabel(pp), desc: prefill.description || '', debit: 0, credit: num(prefill.amount) }]; }
  while (rows.length < (isCash ? 1 : 2)) rows.push(isCash ? { acc: '', desc: '', amount: 0 } : { acc: '', desc: '', debit: 0, credit: 0 });

  if (isCash && !entry) e.cash_account_id = (leafAccounts(accs).find(a => a.account_type === 'cash') || leafAccounts(accs).find(a => a.account_type === 'bank'))?.id || null;
  const cashAccs = leafAccounts(accs).sort((x, y) => (['cash', 'bank'].includes(y.account_type) ? 1 : 0) - (['cash', 'bank'].includes(x.account_type) ? 1 : 0) || x.code.localeCompare(y.code, 'en', { numeric: true }));
  const ro = readOnly ? 'disabled' : '';
  const title = entry ? `${T.label} رقم ${docNo(entry)}` : `${T.label} جديد`;
  const bar = entry ? postBarHTML([{ key: 'gl', posted: entry.status !== 'draft',
    canPost: entry.status === 'draft' && can(T.screen, 'post') && postFlag(type, 'gl'),
    canUnpost: entry.status === 'posted' && !entry.reversal_of && !entry.reversed_by && ['journal', 'receipt', 'payment'].includes(type) && can(T.screen, 'unpost'),
    note: entry.status === 'reversed' ? 'انعمله قيد عكسي' : (!postFlag(type, 'gl') && entry.status === 'draft' ? 'هالنوع مش مفعّل ترحيله (الأدوات ← الترحيل)' : '') }]) : '';
  const dept = await deptField(entry?.department_id, ro, !entry); await loadLookups(); const dtf = await docTypeField(type, entry?.doc_type_id, ro);
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
      ${dept}${dtf}
      <div class="field" style="grid-column:span 2"><label>البيان</label><input name="description" value="${esc(e.description)}" ${ro}></div>
    </div></form>
    ${accountDatalist(accs)}${partyDatalist(parties).replace('</datalist>', emps.filter(x => x.is_active).map(x => `<option value="${esc(empLabel(x))}">موظف</option>`).join('') + '</datalist>')}
    <div class="table-wrap"><table class="t lines" id="lines">
      <thead><tr><th style="width:36px">#</th><th style="min-width:230px">الحساب</th><th style="min-width:170px">العميل / المورد / الموظف</th><th style="min-width:140px">البيان</th>
        ${ccs.length ? '<th style="width:140px">مركز الكلفة</th>' : ''}${curs.length ? '<th style="min-width:90px">العملة</th><th style="min-width:100px">بالعملة</th><th style="min-width:80px">السعر</th>' : ''}
        ${isCash ? '<th style="width:150px">المبلغ</th>' : '<th style="width:140px">مدين</th><th style="width:140px">دائن</th>'}<th style="width:40px"></th></tr></thead>
      <tbody></tbody>
      <tfoot><tr><td></td><td>${!readOnly ? '<button class="btn sm" id="add-line" type="button">➕ سطر</button>' + (type === 'journal' ? ' <button class="btn sm" id="load-bal" type="button" title="تحميل أرصدة حسابات أو عملاء أو موردين كسطور">📥 تحميل أرصدة</button>' : '') : ''}</td><td></td><td style="text-align:left" colspan="${1 + (ccs.length ? 1 : 0) + (curs.length ? 3 : 0)}"><b>المجموع</b></td>
        ${isCash ? '<td><b id="t-amt" dir="ltr"></b></td>' : '<td><b id="t-dr" dir="ltr"></b></td><td><b id="t-cr" dir="ltr"></b></td>'}<td></td></tr>
        ${!isCash ? `<tr><td></td><td></td><td></td><td style="text-align:left" colspan="${1 + (ccs.length ? 1 : 0) + (curs.length ? 3 : 0)}">الفرق</td><td colspan="2"><b id="t-diff" dir="ltr"></b></td><td></td></tr>` : ''}
        <tr><td></td><td colspan="${(isCash ? 5 : 6) + (ccs.length ? 1 : 0) + (curs.length ? 3 : 0)}" class="muted" id="t-words" style="font-size:13px"></td></tr></tfoot>
    </table></div>
    ${type === 'receipt' && (linkedChq.length || chqAdd) ? `<div class="card" id="chq-box" style="margin-top:12px;padding:10px 12px">
      <h4 style="margin:0 0 8px">📑 شيكات مستلمة بهالسند</h4>
      ${linkedChq.length ? `<table class="t"><thead><tr><th>رقم الشيك</th><th>البنك</th><th>الاستحقاق</th><th>الساحب</th><th>الحالة</th><th style="text-align:left">المبلغ</th></tr></thead><tbody>
        ${linkedChq.map(c => `<tr><td dir="ltr">${esc(c.cheque_no)}</td><td>${esc(c.bank_name || '')}</td><td>${fmtDate(c.due_date)}</td><td>${esc(c.drawer_name || '')}</td><td>${esc(CHQ_ST[c.status] || c.status)}</td><td class="n">${fmtNum(c.amount)}</td></tr>`).join('')}
        </tbody><tfoot><tr><td colspan="5"><b>مجموع الشيكات</b></td><td class="n"><b>${fmtNum(linkedChq.reduce((t, c) => t + num(c.amount), 0))}</b></td></tr></tfoot></table>` : ''}
      ${chqAdd ? `<div class="grid cols-3" style="margin-top:6px"><div class="field"><label>العميل (صاحب الشيكات) *</label><input list="party-list" id="chq-party" placeholder="بينعبّى من أول سطر فيه عميل"></div></div>
        <datalist id="bank-list">${(S._lk?.rows || []).filter(x => x.kind === 'bank' && x.is_active !== false).map(b => `<option value="${esc(b.name)}">`).join('')}</datalist>
        <div class="table-wrap"><table class="t lines" id="chq-new"><thead><tr><th>رقم الشيك *</th><th>البنك</th><th>الاستحقاق *</th><th>الساحب</th><th>المجيّر</th><th style="width:130px">المبلغ *</th><th style="width:40px"></th></tr></thead><tbody></tbody>
        <tfoot><tr><td colspan="5"><button class="btn sm" type="button" id="chq-addrow">➕ شيك</button> <span class="muted" style="font-size:12px">كل شيك بينسجّل بمحفظة الشيكات بقيد استلام لحاله (مدين صندوق الشيكات، دائن العميل) وبينربط بالسند.</span></td><td class="n"><b id="chq-tot"></b></td><td></td></tr></tfoot></table></div>
        ${readOnly && entry ? '<button class="btn primary sm" type="button" id="chq-save">💾 تسجيل الشيكات</button>' : ''}` : ''}</div>` : ''}`,
    foot: `
      ${!readOnly ? `<button class="btn primary" data-save>💾 حفظ</button>` : ''}
      ${entry?.status === 'posted' && can(T.screen, 'post') && !entry.reversal_of ? `<button class="btn" data-reverse>↩️ قيد عكسي</button>` : ''}
      ${entry && can(T.screen, 'print') ? `<button class="btn" data-print>🖨️ طباعة</button>` : ''}
      ${entry ? `<button class="btn" data-attach>📎 مرفقات</button>` : ''}
      ${entry && isCash && entry.status === 'posted' && !entry.reversal_of && !entry.reversed_by && (can(T.screen, 'edit') || can(T.screen, 'add')) && lines.some(l => l.party_id) ? `<button class="btn" data-alloc>🧾 توزيع على الفواتير</button>` : ''}
      ${entry && ['payment', 'journal'].includes(type) && entry.status === 'posted' && !entry.reversal_of && !entry.reversed_by && can('payroll', 'add') && can('payroll', 'post') && lines.some(l => l.employee_id && num(l.debit) > 0) ? `<button class="btn" data-toloan>👷 سلفة بالأقساط من الراتب</button>` : ''}
      ${entry && ['journal', 'receipt', 'payment'].includes(type) && can('journal_entries', 'add') ? `<button class="btn" data-recur>🔁 تكرار شهري</button>` : ''}
      ${entry?.status === 'draft' && can(T.screen, 'delete') ? `<button class="btn danger" data-del style="margin-inline-start:auto">حذف</button>` : ''}
      <button class="btn" data-close>إغلاق</button>` });
  if (isCash && entry && type === 'receipt') {   // سند فيه عمولة: نرجّع اختيار وسيلة الدفع
    const cl = lines.find(l => l.line_no !== 1 && num(l.debit) > 0);
    const pm = cl && (S._lk?.rows || []).find(x => x.kind === 'payment_method' && x.account_id === e.cash_account_id && x.commission_account_id === cl.account_id);
    const op = pm && m.el.querySelector(`[name=cash_account_id] option[data-pm="${pm.id}"]`); if (op) op.selected = true;
  }
  m.el.querySelector('.modal').style.maxWidth = ccs.length || curs.length ? '1320px' : '1000px';
  if (entry) { attachAudit(m.el, entry); attachFollow(m.el, 'journal_entries', entry, type, T.screen); }
  attachDocNav(m, entry, { key: 'je:' + type, open: (r) => voucherEditor(type, r, ctx), onNew: can(T.screen, 'add') ? () => voucherEditor(type, null, ctx) : null, table: 'journal_entries', canFreeze: can(T.screen, 'edit'), editable: !readOnly });
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
  m.el.querySelector('#load-bal')?.addEventListener('click', () => loadBalancesDialog());
  // ---- تحميل أرصدة (المرحلة 82): سطر لكل حساب/طرف برصيده لحد تاريخ، عكسه (تصفير) أو زي ما هو، ومع حساب مقابل اختياري
  async function loadBalancesDialog() {
    const groups = accs.filter(a => a.is_group).sort((a, b) => a.code.localeCompare(b.code, 'en', { numeric: true }));
    const { data: cats = [] } = await sb.from('party_categories').select('id,party_type,code,name').eq('company_id', S.company.id).order('code');
    const leaves = leafAccounts(accs);
    const d0 = m.el.querySelector('[name=entry_date]')?.value || today();
    const lm = modal({ stack: true, title: '📥 تحميل أرصدة على السند', body: `<div class="grid cols-2">
      <div class="field"><label>شو بدك تحمّل</label><select id="lb-k"><option value="accounts">حسابات تحت حساب رئيسي</option><option value="customer">أرصدة العملاء</option>
        <option value="supplier">أرصدة الموردين</option><option value="expense">بطاقات المصاريف</option><option value="employees">أرصدة الموظفين</option></select></div>
      <div class="field"><label>لحد تاريخ</label><input type="date" id="lb-to" value="${d0}"></div>
      <div class="field" style="grid-column:span 2" data-for="accounts"><label>الحساب الرئيسي</label><select id="lb-par">${groups.map(a => `<option value="${a.id}">${esc(a.code)} — ${esc(a.name)}</option>`).join('')}</select>
        <label class="check" style="margin-top:6px"><input type="checkbox" id="lb-bp"> سطر لكل عميل/مورد/موظف على الحساب (مش مجمّع)</label></div>
      <div class="field" style="grid-column:span 2;display:none" data-for="party"><label>الفئة (اختياري)</label><select id="lb-cat"><option value="">الكل</option></select></div>
      <div class="field" style="grid-column:span 2;display:none" data-for="employees"><label>حساب الموظفين (ذمم/سلف)</label><select id="lb-ea">${leaves.filter(a => a.account_type === 'employee').concat(leaves.filter(a => a.account_type !== 'employee')).map(a => `<option value="${a.id}">${esc(accLabel(a))}</option>`).join('')}</select></div>
      <div class="field" style="grid-column:span 2"><label>شكل السطور</label><select id="lb-m"><option value="rev">عكس الرصيد (تصفير الحسابات — للإقفال أو التحويل)</option><option value="same">نفس الرصيد (نقل الرصيد زي ما هو)</option></select></div>
      <div class="field" style="grid-column:span 2"><label>حساب مقابل لسطر الموازنة (اختياري)</label><input list="acc-list" id="lb-ctr" placeholder="فاضي = بدون سطر مقابل"></div>
      <label class="check" style="grid-column:span 2"><input type="checkbox" id="lb-rep" checked> استبدل السطور الفاضية بالسند</label></div>
      <div id="lb-msg" class="muted" style="font-size:12px"></div>`,
      foot: '<button class="btn primary" data-ok>📥 تحميل</button><button class="btn" data-close>إلغاء</button>' });
    const $ = (x) => lm.el.querySelector(x);
    const sync = () => {
      const k = $('#lb-k').value, party = ['customer', 'supplier', 'expense'].includes(k);
      lm.el.querySelectorAll('[data-for]').forEach(el => { el.style.display = el.dataset.for === (party ? 'party' : k) ? '' : 'none'; });
      if (party) $('#lb-cat').innerHTML = '<option value="">الكل</option>' + (cats || []).filter(c => c.party_type === k).map(c => `<option value="${c.id}">${esc(c.name)}</option>`).join('');
    };
    $('#lb-k').onchange = sync; sync();
    $('[data-ok]').onclick = async () => {
      const k = $('#lb-k').value, party = ['customer', 'supplier', 'expense'].includes(k);
      const p = party ? { kind: 'parties', type: k, category_id: $('#lb-cat').value || null }
        : k === 'employees' ? { kind: 'employees', account: $('#lb-ea').value } : { kind: 'accounts', parent: $('#lb-par').value, by_party: $('#lb-bp').checked };
      p.to = $('#lb-to').value;
      const ctr = $('#lb-ctr').value.trim() ? resolveAccount(accs, $('#lb-ctr').value) : null;
      if ($('#lb-ctr').value.trim() && !ctr) return toast('الحساب المقابل مش من القائمة', 'err');
      const { data, error } = await sb.rpc('entry_load_balances', { p_company: S.company.id, p_fy: S.fy.id, p });
      if (error) return toast(arError(error), 'err');
      if (!data?.length) return void ($('#lb-msg').textContent = 'ما في أرصدة لهالاختيار.');
      if (data.length > 500) return void ($('#lb-msg').textContent = `${data.length} سطر — كثير. ضيّق الاختيار (فئة أو حساب أصغر).`);
      const rev = $('#lb-m').value === 'rev', desc = rev ? 'تصفير رصيد ' + p.to : 'رصيد ' + p.to;
      if ($('#lb-rep').checked) for (let i = rows.length - 1; i >= 0; i--) { const r = rows[i]; if (!r.acc && !num(r.debit) && !num(r.credit)) rows.splice(i, 1); }
      let net = 0;
      for (const b of data) {
        const v = rev ? -num(b.balance) : num(b.balance); net += v;
        const side = b.employee_id ? empLabel(empById[b.employee_id]) : b.party_id ? partyLabel(pById[b.party_id]) : '';
        rows.push({ acc: accLabel(byId[b.account_id]), party: side, desc, debit: v > 0 ? Math.round(v * 1000) / 1000 : 0, credit: v < 0 ? Math.round(-v * 1000) / 1000 : 0 });
      }
      net = Math.round(net * 1000) / 1000;
      if (ctr && net) rows.push({ acc: accLabel(ctr), party: '', desc, debit: net < 0 ? -net : 0, credit: net > 0 ? net : 0 });
      drawRows(); lm.close(); toast(`انحمّل ${data.length} سطر`, 'ok');
    };
  }

  // ---- الشيكات الجديدة بالسند
  const chqRows = [];
  const chqTb = m.el.querySelector('#chq-new tbody');
  const chqDraw = () => {
    if (!chqTb) return;
    chqTb.innerHTML = chqRows.map((c, i) => `<tr>
      <td><input class="cell" dir="ltr" data-ci="${i}" data-ck="cheque_no" value="${esc(c.cheque_no || '')}"></td>
      <td><input class="cell" list="bank-list" data-ci="${i}" data-ck="bank_name" value="${esc(c.bank_name || '')}"></td>
      <td><input class="cell" type="date" data-ci="${i}" data-ck="due_date" value="${esc(c.due_date || '')}"></td>
      <td><input class="cell" data-ci="${i}" data-ck="drawer_name" value="${esc(c.drawer_name || '')}"></td>
      <td><input class="cell" data-ci="${i}" data-ck="endorser_name" value="${esc(c.endorser_name || '')}"></td>
      <td><input class="cell n" dir="ltr" inputmode="decimal" data-ci="${i}" data-ck="amount" value="${c.amount || ''}"></td>
      <td><button class="x" type="button" data-crm="${i}">×</button></td></tr>`).join('') || '<tr><td colspan="7" class="muted" style="font-size:13px">ما في شيكات جديدة.</td></tr>';
    chqTot();
  };
  const chqTot = () => { const el = m.el.querySelector('#chq-tot'); if (el) el.textContent = fmtNum(chqRows.reduce((t, c) => t + num(c.amount), 0)); };
  const chqPartyGuess = () => { const pi = m.el.querySelector('#chq-party'); if (pi && !pi.value) { const r = rows.find(x => resolveParty(parties, x.party)); if (r) pi.value = r.party; } };
  if (chqTb) {
    chqDraw(); chqPartyGuess();
    if (entry) { const lp = lines.find(l => l.party_id); const pi = m.el.querySelector('#chq-party'); if (lp && pi) pi.value = partyLabel(pById[lp.party_id]); }
    m.el.querySelector('#chq-addrow').onclick = () => { const last = chqRows.at(-1); chqRows.push({ bank_name: last?.bank_name || '', drawer_name: last?.drawer_name || '' }); chqPartyGuess(); chqDraw(); chqTb.querySelector(`[data-ci="${chqRows.length - 1}"][data-ck="cheque_no"]`)?.focus(); };
    chqTb.addEventListener('input', (ev) => { const t = ev.target; if (t.dataset.ck) { chqRows[+t.dataset.ci][t.dataset.ck] = t.value; if (t.dataset.ck === 'amount') chqTot(); } });
    chqTb.addEventListener('click', (ev) => { const b = ev.target.closest('[data-crm]'); if (b) { chqRows.splice(+b.dataset.crm, 1); chqDraw(); } });
  }
  const chqCheck = () => {   // بيرجّع {party, rows} أو رسالة خطأ
    const list = chqRows.filter(c => c.cheque_no || num(c.amount) || c.due_date);
    if (!list.length) return { rows: [] };
    for (const [i, c] of list.entries()) {
      if (!(c.cheque_no || '').trim()) return { err: `الشيك ${i + 1}: رقم الشيك مطلوب` };
      if (!c.due_date) return { err: `الشيك ${i + 1}: تاريخ الاستحقاق مطلوب` };
      if (!(num(c.amount) > 0)) return { err: `الشيك ${i + 1}: المبلغ مطلوب` };
    }
    const p = resolveParty(parties, m.el.querySelector('#chq-party')?.value || '');
    if (!p) return { err: 'اختار العميل اللي استلمنا منه الشيكات' };
    return { party: p, rows: list.map(c => ({ ...c, amount: num(c.amount) })) };
  };
  const chqSend = async (entryId, date) => {
    const ck = chqCheck(); if (!ck.rows.length) return true;
    const { error } = await sb.rpc('receipt_cheques', { p_company: S.company.id, p_entry: entryId, p_party: ck.party.id, p_date: date, p_rows: ck.rows });
    if (error) { toast('الشيكات ما انسجّلت: ' + arError(error), 'err'); return false; }
    toast(`انسجّل ${ck.rows.length} شيك بالمحفظة`, 'ok'); chqRows.length = 0; return true;
  };
  m.el.querySelector('#chq-save')?.addEventListener('click', async (ev) => {
    const ck = chqCheck(); if (ck.err) return toast(ck.err, 'err'); if (!ck.rows.length) return toast('أضف شيك أول', 'err');
    ev.target.disabled = true; if (await chqSend(entry.id, entry.entry_date)) reopen(entry.id); else ev.target.disabled = false;
  });

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
      const em = (r.party || '').includes('👷') ? resolveEmp(r.party) : null;
      const pt = em ? null : resolveParty(parties, r.party);
      if (r.party && !pt && !em) return toast(`السطر ${i + 1}: العميل/المورد/الموظف مش موجود بالقائمة`, 'err');
      const party_id = pt?.id || null, employee_id = em?.id || null;
      if (isCash) {
        if (!num(r.amount)) return toast(`السطر ${i + 1}: المبلغ مطلوب`, 'err');
        out.push({ account_id: a.id, party_id, employee_id, description: r.desc || null, debit: type === 'payment' ? num(r.amount) : 0, credit: type === 'receipt' ? num(r.amount) : 0, ...extra(r) });
      } else {
        if (!num(r.debit) && !num(r.credit)) return toast(`السطر ${i + 1}: اكتب مبلغ مدين أو دائن`, 'err');
        out.push({ account_id: a.id, party_id, employee_id, description: r.desc || null, debit: num(r.debit), credit: num(r.credit), ...extra(r) });
      }
    }
    const ckv = type === 'receipt' && chqTb ? chqCheck() : { rows: [] };
    if (ckv.err) return toast(ckv.err, 'err');
    if (isCash && !out.length && ckv.rows.length && !entry) {   // شيكات بس، بدون نقد: بتنسجّل بدون سند
      if (!(await confirmBox(`ما في مبلغ نقدي. نسجّل ${ckv.rows.length} شيك بالمحفظة بدون سند قبض؟`))) return;
      if (await chqSend(null, h.entry_date)) { m.close(); ctx.rerender(); }
      return;
    }
    if (isCash) {
      if (!h.cash_account_id) return toast('اختار حساب الصندوق أو البنك', 'err');
      if (!out.length) return toast('أضف سطر واحد على الأقل', 'err');
      if (out.some(l => l.account_id === h.cash_account_id)) return toast('ما بيصير نفس حساب الصندوق/البنك يكون بالسطور', 'err');
      const t = out.reduce((s, l) => s + l.debit + l.credit, 0);
      // عمولة وسيلة الدفع (فيزا…): البنك بالصافي والعمولة على حسابها
      const pmId = m.el.querySelector('[name=cash_account_id]')?.selectedOptions?.[0]?.dataset.pm;
      const pm = pmId && (S._lk?.rows || []).find(x => x.id === pmId);
      const comm = type === 'receipt' && pm && num(pm.rate) > 0 && pm.commission_account_id ? Math.round(t * num(pm.rate) * 10) / 1000 : 0;
      if (comm > 0) out.unshift({ account_id: pm.commission_account_id, description: `عمولة ${pm.name} ${num(pm.rate)}% — ${h.description || ''}`.trim(), debit: comm, credit: 0 });
      out.unshift({ account_id: h.cash_account_id, description: h.description, debit: type === 'receipt' ? Math.round((t - comm) * 1000) / 1000 : 0, credit: type === 'payment' ? t : 0 });
    } else {
      if (out.length < 2) return toast('القيد لازم يكون فيه سطرين على الأقل', 'err');
      const d = out.reduce((s, l) => s + l.debit, 0), c = out.reduce((s, l) => s + l.credit, 0);
      if (post && Math.abs(d - c) > 0.0005) return toast('القيد مش متوازن، ما بينرحّل', 'err');
    }
    const header = { entry_date: h.entry_date, description: h.description, reference: h.reference,
                     party_name: isCash ? h.party_name : null, cash_account_id: isCash ? h.cash_account_id : null, ...deptValue(m.el.querySelector('#v-form')), ...docTypeValue(m.el.querySelector('#v-form')),
                     ...(mn.value ? { entry_no: mn.value } : {}) };
    const btns = m.el.querySelectorAll('.modal-foot .btn'); btns.forEach(b => b.disabled = true);
    try {
      let id = entry?.id;
      if (id) {
        const u = await sb.from('journal_entries').update(header).eq('id', id); if (u.error) throw u.error;
        const d = await sb.from('journal_lines').delete().eq('entry_id', id); if (d.error) throw d.error;
      } else {
        const ins = await sb.from('journal_entries').insert({ ...header, company_id: S.company.id, fiscal_year_id: S.fy.id, entry_type: type, ...(prefill?.order_id ? { order_id: prefill.order_id } : {}) }).select().single();
        if (ins.error) throw ins.error; id = ins.data.id; entry = ins.data;
      }
      const li = await sb.from('journal_lines').insert(out.map((l, k) => ({ ...l, entry_id: id, line_no: k + 1 })));
      if (li.error) throw li.error;
      if (ckv.rows.length && !(await chqSend(id, h.entry_date))) {   // السند انحفظ بس الشيكات لأ: بنضل بالنافذة عشان ما تضيع
        entry = entry || { id }; toast('السند انحفظ، بس الشيكات ما انسجّلت. صحّح واضغط حفظ مرة ثانية', 'err'); btns.forEach(b => b.disabled = false); return;
      }
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
  m.el.querySelector('[data-toloan]')?.addEventListener('click', async () => {
    const ids = [...new Set(lines.filter(l => l.employee_id && num(l.debit) > 0).map(l => l.employee_id))];
    const { data: done } = await sb.from('employee_loans').select('employee_id,loan_no,status').eq('entry_id', entry.id).neq('status', 'cancelled');
    const nm = new Date(); nm.setMonth(nm.getMonth() + 1); const fm = `${nm.getFullYear()}-${String(nm.getMonth() + 1).padStart(2, '0')}`;
    const lm = modal({ title: '👷 تحويل السند لسلفة بالأقساط', size: 'sm', stack: true, body: `<form id="tl">
      <p class="muted" style="margin-top:0;font-size:13px">المبلغ = سطور السند المدينة على «حساب سلف الموظفين» (من حسابات الربط) لهالموظف. الأقساط بتنخصم لحالها بمسيّر الرواتب.</p>
      <div class="field"><label>الموظف</label><select name="emp">${ids.map(id => { const d = (done || []).find(x => x.employee_id === id); return `<option value="${id}" ${d ? 'disabled' : ''}>${esc(empById[id]?.name || '')}${d ? ` — محوّل (رقم ${d.loan_no})` : ''}</option>`; }).join('')}</select></div>
      <div class="grid cols-2"><div class="field"><label>عدد الأقساط</label><input name="n" type="number" min="1" max="120" value="1"></div>
        <div class="field"><label>شهر أول قسط</label><input name="fm" type="month" value="${fm}"></div></div></form>`,
      foot: '<button class="btn primary" data-go>تحويل</button><button class="btn" data-close>إلغاء</button>' });
    lm.el.querySelector('[data-go]').onclick = async (ev) => {
      const f = lm.el.querySelector('#tl'); ev.target.disabled = true;
      const { error } = await sb.rpc('loan_from_entry', { p_entry: entry.id, p_employee: f.emp.value, p_installments: parseInt(f.n.value) || 1, p_first_month: f.fm.value });
      ev.target.disabled = false; if (error) return toast(arError(error), 'err');
      toast('انعملت السلفة وجدول أقساطها (القروض والسلف)', 'ok'); lm.close();
    };
  });
  m.el.querySelector('[data-alloc]')?.addEventListener('click', () => allocateDialog(entry, [...new Set(lines.filter(l => l.party_id).map(l => l.party_id))], pById));
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
  m.el.querySelector('[data-print]')?.addEventListener('click', () => printVoucher(type, entry, lines, byId, linkedChq, Object.fromEntries(emps.map(x => [x.id, x.name]))));
}

const CHQ_ST = { portfolio: 'بالمحفظة', deposited: 'مودع', collected: 'محصّل', returned: 'راجع', cancelled: 'ملغى', issued: 'صادر', paid: 'مصروف' };
function printVoucher(type, e, lines, byId, chq = [], empNames = {}) {
  const T = ENTRY_TYPES[type];
  const isCash = type === 'receipt' || type === 'payment';
  const body = isCash ? lines.filter(l => l.line_no !== 1 && !(type === 'receipt' && num(l.debit) > 0)) : lines;
  const total = isCash ? body.reduce((s, l) => s + num(l.debit) + num(l.credit), 0) : lines.reduce((s, l) => s + num(l.debit), 0);
  printDoc(`${T.label} رقم ${docNo(e)}`, `
    <table class="meta"><tr><td><b>التاريخ:</b> ${fmtDate(e.entry_date)}</td><td><b>الحالة:</b> ${STATUS[e.status][0]}</td><td><b>المرجع:</b> ${esc(e.reference || '—')}</td></tr>
      ${isCash ? `<tr><td colspan="2"><b>${type === 'receipt' ? 'استلمنا من السيد/السادة' : 'صرفنا إلى السيد/السادة'}:</b> ${esc(e.party_name || '')}</td><td><b>${type === 'receipt' ? 'إلى حساب' : 'من حساب'}:</b> ${esc(byId[e.cash_account_id]?.name || '')}</td></tr>` : ''}
      <tr><td colspan="3"><b>البيان:</b> ${esc(e.description || '')}</td></tr></table>
    ${isCash ? `<div class="amount-box">مبلغ وقدره: <b>${fmtNum(total)}</b> دينار<br><span>${amountToWords(total)}</span></div>` : ''}
    <table class="pt"><thead><tr><th>#</th><th>رقم الحساب</th><th>اسم الحساب</th><th>البيان</th>${isCash ? '<th>المبلغ</th>' : '<th>مدين</th><th>دائن</th>'}</tr></thead><tbody>
      ${body.map((l, i) => `<tr><td>${i + 1}</td><td>${esc(byId[l.account_id]?.code)}</td><td>${esc(byId[l.account_id]?.name)}${l.party_id && S.parties ? ' — ' + esc(S.parties.find(p => p.id === l.party_id)?.name || '') : ''}${l.employee_id && empNames[l.employee_id] ? ' — 👷 ' + esc(empNames[l.employee_id]) : ''}</td><td>${esc(l.description || '')}</td>
        ${isCash ? `<td class="n">${fmtNum(num(l.debit) + num(l.credit))}</td>` : `<td class="n">${num(l.debit) ? fmtNum(l.debit) : ''}</td><td class="n">${num(l.credit) ? fmtNum(l.credit) : ''}</td>`}</tr>`).join('')}
      </tbody><tfoot><tr><td colspan="4"><b>المجموع</b> — ${amountToWords(total)}</td>${isCash ? `<td class="n"><b>${fmtNum(total)}</b></td>` : `<td class="n"><b>${fmtNum(total)}</b></td><td class="n"><b>${fmtNum(lines.reduce((s, l) => s + num(l.credit), 0))}</b></td>`}</tr></tfoot></table>
    ${chq.length ? `<h4 style="margin:12px 0 6px">الشيكات المستلمة</h4><table class="pt"><thead><tr><th>#</th><th>رقم الشيك</th><th>البنك</th><th>الاستحقاق</th><th>المبلغ</th></tr></thead><tbody>
      ${chq.map((c, i) => `<tr><td>${i + 1}</td><td>${esc(c.cheque_no)}</td><td>${esc(c.bank_name || '')}</td><td>${fmtDate(c.due_date)}</td><td class="n">${fmtNum(c.amount)}</td></tr>`).join('')}</tbody>
      <tfoot><tr><td colspan="4"><b>مجموع الشيكات</b></td><td class="n"><b>${fmtNum(chq.reduce((t, c) => t + num(c.amount), 0))}</b></td></tr>
      <tr><td colspan="4"><b>إجمالي المقبوض (نقد + شيكات)</b> — ${amountToWords(total + chq.reduce((t, c) => t + num(c.amount), 0))}</td><td class="n"><b>${fmtNum(total + chq.reduce((t, c) => t + num(c.amount), 0))}</b></td></tr></tfoot></table>` : ''}`, { kind: type === 'receipt' ? 'receipt' : type === 'payment' ? 'payment' : 'journal', copies: docCopies(e.doc_type_id) });
}

// ---------------------------------------------------------------------
//  الأرصدة الافتتاحية: الحسابات، العملاء، الموردين، المصاريف، الموظفين، الأصول الثابتة
//  route opening?k=acc|customer|supplier|expense|emp|ast[&from=<سنة>] — from بيفتح نافذة النسخ جاهزة
// ---------------------------------------------------------------------
const OB_TABS = { acc: 'الحسابات', customer: 'العملاء', supplier: 'الموردين', expense: 'المصاريف', emp: 'الموظفين', ast: 'الأصول الثابتة' };
const r3 = (x) => Math.round((Number(x) || 0) * 1000) / 1000;
const obVal = (x) => x ? fmtNum(x).replace(/,/g, '') : '';

async function viewOpening(v, ctx) {
  if (!needCompanyFY(v)) return;
  const qs = new URLSearchParams(location.hash.split('?')[1] || '');
  const [accs, parties] = await Promise.all([loadAccounts(), loadParties()]);
  if (!accs.length) return void (v.innerHTML = `<div class="notice">لازم يكون في دليل حسابات أول. <a href="#/accounts">روح لدليل الحسابات</a></div>`);
  const [entsR, empR, astR] = await Promise.all([
    sb.from('journal_entries').select('*').eq('company_id', S.company.id).eq('fiscal_year_id', S.fy.id).eq('entry_type', 'opening').order('created_at', { ascending: false }),
    can('payroll', 'view') ? sb.from('employees').select('id,code,name,account_id,is_active').eq('company_id', S.company.id).order('code') : { data: [] },
    can('fixed_assets', 'view') ? sb.from('fixed_assets').select('id,code,name,cost,opening_accum,asset_account_id,accum_account_id,status,purchase_date').eq('company_id', S.company.id).order('code') : { data: [] }]);
  if (entsR.error) throw entsR.error;
  const emps = empR.data || [], assets = astR.data || [];
  let entry = (entsR.data || []).find(x => x.status !== 'reversed') || null;
  let lines = [];
  if (entry) { const r = await sb.from('journal_lines').select('*').eq('entry_id', entry.id).order('line_no'); lines = r.data || []; }
  const accById = Object.fromEntries(accs.map(a => [a.id, a]));
  const empById = Object.fromEntries(emps.map(e => [e.id, e]));
  // الحالة: vals = حسابات مباشرة، pvals = أطراف، erows = موظفين [{emp, acc, d, c}]، avals = أصول {cost, accum}
  const vals = {}, pvals = {}, avals = {}; let erows = [];
  lines.forEach(l => {
    const d = num(l.debit), c = num(l.credit);
    if (l.asset_id) { const x = avals[l.asset_id] ||= { cost: 0, accum: 0 }; x.cost += d; x.accum += c; return; }
    if (l.employee_id) { const r = erows.find(z => z.emp === l.employee_id && z.acc === l.account_id); if (r) { r.d += d; r.c += c; } else erows.push({ emp: l.employee_id, acc: l.account_id, d, c }); return; }
    const t = l.party_id ? (pvals[l.party_id] ||= { d: 0, c: 0 }) : (vals[l.account_id] ||= { d: 0, c: 0 }); t.d += d; t.c += c;
  });
  const empAccDefault = (e) => e?.account_id || accs.find(a => !a.is_group && a.is_active && a.account_type === 'employee')?.id || '';
  emps.filter(e => e.is_active && !erows.some(r => r.emp === e.id)).forEach(e => erows.push({ emp: e.id, acc: empAccDefault(e), d: 0, c: 0 }));
  const plist = parties.filter(p => p.is_active || pvals[p.id]);
  const byType = { customer: plist.filter(p => p.party_type === 'customer'), supplier: plist.filter(p => p.party_type === 'supplier'), expense: plist.filter(p => p.party_type === 'expense') };
  const alist = assets.filter(a => a.status === 'active' || avals[a.id]);
  // سطور أصول ما بيقدر يشوفها (بدون صلاحية الأصول): بتضل زي ما هي بالحفظ
  const keepAst = lines.filter(l => l.asset_id && !alist.some(a => a.id === l.asset_id));
  keepAst.forEach(l => delete avals[l.asset_id]);
  const partyAcc = new Set(parties.map(p => p.account_id).filter(Boolean));
  const empAccs = accs.filter(a => !a.is_group && a.is_active && a.category !== 'revenue' && a.category !== 'expenses');
  const readOnly = (entry && entry.status !== 'draft') || !(entry ? can('opening_balances', 'edit') : can('opening_balances', 'add'));
  const dis = readOnly ? 'disabled' : '';
  const CAT = { assets: 'موجودات', liabilities: 'مطلوبات', equity: 'حقوق ملكية', revenue: 'إيرادات', expenses: 'مصاريف' };
  const tabs = ['acc', 'customer', 'supplier', ...(byType.expense.length ? ['expense'] : []), ...(can('payroll', 'view') ? ['emp'] : []), ...(can('fixed_assets', 'view') ? ['ast'] : [])];
  let tab = tabs.includes(qs.get('k')) ? qs.get('k') : 'acc';

  // مجموع التفصيلي (أطراف، موظفين، أصول) على كل حساب
  const subSums = () => {
    const m = {};
    plist.forEach(p => { const x = pvals[p.id]; if (x && p.account_id) m[p.account_id] = (m[p.account_id] || 0) + (x.d || 0) - (x.c || 0); });
    erows.forEach(r => { if (r.acc && (r.d || r.c)) m[r.acc] = (m[r.acc] || 0) + (r.d || 0) - (r.c || 0); });
    keepAst.forEach(l => { m[l.account_id] = (m[l.account_id] || 0) + num(l.debit) - num(l.credit); });
    alist.forEach(a => { const x = avals[a.id]; if (!x) return;
      if (x.cost && a.asset_account_id) m[a.asset_account_id] = (m[a.asset_account_id] || 0) + x.cost;
      if (x.accum && a.accum_account_id) m[a.accum_account_id] = (m[a.accum_account_id] || 0) - x.accum; });
    return m;
  };
  const leavesFor = () => { const sub = subSums();
    return accs.filter(a => !a.is_group && (a.is_active || vals[a.id] || sub[a.id])).sort((x, y) => x.code.localeCompare(y.code, 'en', { numeric: true })); };

  const partyTable = (type) => `<table class="t lines" data-tbl="${type}">
      <thead><tr><th style="width:90px">الرقم</th><th>الاسم</th><th>الحساب</th><th style="width:150px">مدين</th><th style="width:150px">دائن</th></tr></thead>
      <tbody>${byType[type].map(p => `<tr data-row="p:${p.id}" data-s="${esc((p.code + ' ' + p.name).toLowerCase())}">
        <td>${esc(p.code)}</td><td>${esc(p.name)}</td><td class="muted">${esc(accById[p.account_id]?.name || '')}</td>
        <td><input class="cell n" dir="ltr" inputmode="decimal" data-p="${p.id}" data-k="d" value="${obVal(pvals[p.id]?.d)}" ${dis}></td>
        <td><input class="cell n" dir="ltr" inputmode="decimal" data-p="${p.id}" data-k="c" value="${obVal(pvals[p.id]?.c)}" ${dis}></td></tr>`).join('')
        || '<tr><td colspan="5" class="muted">ما في بطاقات</td></tr>'}</tbody></table>
      <p class="muted" style="font-size:13px">${type === 'customer' ? 'رصيد العميل عادة مدين (إله علينا نحصّله).' : type === 'supplier' ? 'رصيد المورد عادة دائن (إلنا عليه ندفعله).' : 'رصيد بطاقة المصروف عادة مدين.'}</p>`;
  const empOpts = (sel) => emps.map(e => `<option value="${e.id}" ${e.id === sel ? 'selected' : ''}>${esc(e.code)} — ${esc(e.name)}</option>`).join('');
  const accOpts = (sel) => `<option value="">— الحساب —</option>` + empAccs.map(a => `<option value="${a.id}" ${a.id === sel ? 'selected' : ''}>${esc(a.code)} — ${esc(a.name)}</option>`).join('');
  const empBody = () => erows.map((r, i) => `<tr data-row="e:${i}" data-s="${esc(((empById[r.emp]?.code || '') + ' ' + (empById[r.emp]?.name || '')).toLowerCase())}">
      <td><select class="cell" data-ei="${i}" data-k="emp" ${dis}>${empOpts(r.emp)}</select></td>
      <td><select class="cell" data-ei="${i}" data-k="acc" ${dis}>${accOpts(r.acc)}</select></td>
      <td><input class="cell n" dir="ltr" inputmode="decimal" data-ei="${i}" data-k="d" value="${obVal(r.d)}" ${dis}></td>
      <td><input class="cell n" dir="ltr" inputmode="decimal" data-ei="${i}" data-k="c" value="${obVal(r.c)}" ${dis}></td>
      <td>${dis ? '' : `<button type="button" class="btn sm" data-edel="${i}" title="حذف السطر">✕</button>`}</td></tr>`).join('') || '<tr><td colspan="5" class="muted">ما في موظفين</td></tr>';

  v.innerHTML = `
    <div class="page-head"><h2>🧮 الأرصدة الافتتاحية</h2><span class="muted">${esc(S.fy.name || S.fy.code)} — بتاريخ ${fmtDate(S.fy.start_date)}</span>
      ${entry ? statusBadge(entry.status) : ''}<div class="spacer"></div>
      ${!readOnly ? `<button class="btn" id="ob-copy">📋 نسخ من سنة سابقة</button><button class="btn" id="ob-clear">🧹 تفريغ هالقسم</button>` : ''}
      <input class="search" id="q" placeholder="بحث…">
      <label class="check" style="margin:0"><input type="checkbox" id="only"> اللي إلها رصيد بس</label></div>
    ${entry?.status === 'posted' ? `<div class="notice info">الأرصدة الافتتاحية مرحّلة. لأي تعديل اعمل <a href="#/journal">سند قيد</a> تسوية، أو ألغِ ترحيلها من «الترحيل».</div>` : ''}
    ${entry?.reference === 'AUTO-CLOSE' ? `<div class="notice info">هالأرصدة انعملت تلقائياً من إغلاق السنة السابقة وتدويرها.</div>` : ''}
    <div class="tabs" id="ob-tabs">${tabs.map(t => `<div class="tab ${t === tab ? 'active' : ''}" data-tab="${t}">${OB_TABS[t]}</div>`).join('')}</div>
    <div class="tab-panel ${tab === 'acc' ? 'active' : ''}" data-tab="acc"><div class="card table-wrap"><table class="t lines" data-tbl="acc">
      <thead><tr><th style="width:120px">رقم الحساب</th><th>اسم الحساب</th><th>التصنيف</th><th style="width:150px">مدين</th><th style="width:150px">دائن</th></tr></thead>
      <tbody id="ob-acc"></tbody></table></div>
      <p class="muted" style="font-size:13px">الحسابات اللي إلها أرصدة تفصيلية (عملاء، موردين، موظفين، أصول) بتتعبّى لحالها من تبويباتها.</p></div>
    ${['customer', 'supplier', 'expense'].filter(t => tabs.includes(t)).map(t => `<div class="tab-panel ${tab === t ? 'active' : ''}" data-tab="${t}"><div class="card table-wrap">${partyTable(t)}</div></div>`).join('')}
    ${tabs.includes('emp') ? `<div class="tab-panel ${tab === 'emp' ? 'active' : ''}" data-tab="emp"><div class="card table-wrap"><table class="t lines" data-tbl="emp">
      <thead><tr><th>الموظف</th><th>الحساب (ذمم/سلف)</th><th style="width:150px">مدين</th><th style="width:150px">دائن</th><th style="width:40px"></th></tr></thead>
      <tbody id="ob-emp">${empBody()}</tbody></table>
      ${dis || !emps.length ? '' : '<button type="button" class="btn sm" id="ob-eadd" style="margin-top:8px">➕ سطر موظف</button>'}</div>
      <p class="muted" style="font-size:13px">سلفة الموظف أو ذمته علينا = مدين. مستحقاته (رواتب مستحقة مثلاً) = دائن.</p></div>` : ''}
    ${tabs.includes('ast') ? `<div class="tab-panel ${tab === 'ast' ? 'active' : ''}" data-tab="ast"><div class="card table-wrap"><table class="t lines" data-tbl="ast">
      <thead><tr><th style="width:90px">الرقم</th><th>الأصل</th><th>حساب الأصل / المجمع</th><th style="width:150px">الكلفة (مدين)</th><th style="width:150px">مجمع الاستهلاك (دائن)</th><th style="width:120px">صافي القيمة</th></tr></thead>
      <tbody>${alist.map(a => `<tr data-row="a2:${a.id}" data-s="${esc((a.code + ' ' + a.name).toLowerCase())}">
        <td>${esc(a.code)}</td><td>${esc(a.name)}</td>
        <td class="muted" style="font-size:12px">${esc(accById[a.asset_account_id]?.name || '⚠️ بدون حساب')} / ${esc(accById[a.accum_account_id]?.name || '⚠️ بدون حساب')}</td>
        <td><input class="cell n" dir="ltr" inputmode="decimal" data-as="${a.id}" data-k="cost" value="${obVal(avals[a.id]?.cost)}" ${dis}></td>
        <td><input class="cell n" dir="ltr" inputmode="decimal" data-as="${a.id}" data-k="accum" value="${obVal(avals[a.id]?.accum)}" ${dis}></td>
        <td class="n" data-nbv="${a.id}"></td></tr>`).join('') || '<tr><td colspan="6" class="muted">ما في أصول ثابتة</td></tr>'}</tbody></table>
      ${dis || !alist.length ? '' : '<button type="button" class="btn sm" id="ob-acards" style="margin-top:8px">📇 تعبئة من بطاقات الأصول</button>'}</div>
      <p class="muted" style="font-size:13px">الكلفة بتنزل مدين على حساب الأصل، ومجمع الاستهلاك دائن على حساب المجمع، لكل أصل.</p></div>` : ''}
    <div class="card" style="margin-top:12px;display:flex;gap:24px;flex-wrap:wrap;align-items:center">
      <div>مجموع المدين: <b id="td" dir="ltr"></b></div><div>مجموع الدائن: <b id="tc" dir="ltr"></b></div><div>الفرق: <b id="tf" dir="ltr"></b></div>
      <div class="spacer" style="flex:1"></div>
      ${!readOnly ? `<button class="btn primary" id="save">💾 حفظ مسودة</button>` : ''}
      ${!readOnly && can('opening_balances', 'post') ? `<button class="btn primary" id="savepost">✅ حفظ وترحيل</button>` : ''}
      ${entry && can('opening_balances', 'print') ? `<button class="btn" id="prn">🖨️ طباعة</button>` : ''}
    </div>`;

  // جدول الحسابات (بيتعاد رسمه لما تتغيّر الأرصدة التفصيلية)
  const drawAcc = () => {
    const sub = subSums();
    v.querySelector('#ob-acc').innerHTML = leavesFor().map(a => {
      const direct = vals[a.id] && (vals[a.id].d || vals[a.id].c);
      const auto = !direct && (partyAcc.has(a.id) || r3(sub[a.id]));
      const n = r3(sub[a.id]);
      const dv = auto ? (n > 0 ? obVal(n) : '') : obVal(vals[a.id]?.d), cv = auto ? (n < 0 ? obVal(-n) : '') : obVal(vals[a.id]?.c);
      return `<tr data-row="a:${a.id}" data-s="${esc((a.code + ' ' + a.name).toLowerCase())}">
        <td dir="ltr" style="text-align:right">${esc(a.code)}</td><td>${esc(a.name)}${auto ? ' <span class="badge brand">تفصيلي</span>' : direct && r3(sub[a.id]) ? ` <span class="badge warn" title="في كمان أرصدة تفصيلية على هالحساب">+ تفصيلي ${fmtNum(sub[a.id])}</span>` : ''}</td><td class="muted">${CAT[a.category] || ''}</td>
        <td><input class="cell n" dir="ltr" inputmode="decimal" data-a="${a.id}" data-k="d" value="${dv}" ${dis || (auto ? 'disabled' : '')}></td>
        <td><input class="cell n" dir="ltr" inputmode="decimal" data-a="${a.id}" data-k="c" value="${cv}" ${dis || (auto ? 'disabled' : '')}></td></tr>`;
    }).join('');
    filter();
  };
  const tot = () => {
    let d = 0, c = 0;
    Object.values(vals).forEach(x => { d += x.d || 0; c += x.c || 0; });
    plist.forEach(p => { const x = pvals[p.id]; if (x) { d += x.d || 0; c += x.c || 0; } });
    erows.forEach(r => { if (r.acc) { d += r.d || 0; c += r.c || 0; } });
    keepAst.forEach(l => { d += num(l.debit); c += num(l.credit); });
    alist.forEach(a => { const x = avals[a.id]; if (x) { d += x.cost || 0; c += x.accum || 0; } const el = v.querySelector(`[data-nbv="${a.id}"]`); if (el) el.textContent = x && (x.cost || x.accum) ? fmtNum((x.cost || 0) - (x.accum || 0)) : ''; });
    v.querySelector('#td').textContent = fmtNum(d); v.querySelector('#tc').textContent = fmtNum(c);
    const f = r3(d - c), el = v.querySelector('#tf');
    el.textContent = f ? fmtNum(Math.abs(f)) + (f > 0 ? ' (مدين أكثر)' : ' (دائن أكثر)') : '✓ متوازن'; el.style.color = f ? 'var(--bad)' : 'var(--ok)';
  };
  const filter = () => {
    const q = v.querySelector('#q').value.trim().toLowerCase(), only = v.querySelector('#only').checked;
    v.querySelectorAll('[data-row]').forEach(r => {
      const has = [...r.querySelectorAll('input')].some(i => num(i.value));
      r.style.display = (!q || qm(r.dataset.s, q)) && (!only || has) ? '' : 'none'; });
  };
  const redrawEmp = () => { const b = v.querySelector('#ob-emp'); if (b) b.innerHTML = empBody(); };
  const refresh = () => { drawAcc(); tot(); };
  refresh();

  v.querySelector('#ob-tabs').addEventListener('click', ev => {
    const t = ev.target.closest('.tab'); if (!t) return; tab = t.dataset.tab;
    v.querySelectorAll('#ob-tabs .tab').forEach(x => x.classList.toggle('active', x === t));
    v.querySelectorAll('.tab-panel').forEach(x => x.classList.toggle('active', x.dataset.tab === tab));
    if (tab === 'acc') drawAcc();
    try { history.replaceState(null, '', '#/opening?k=' + tab); } catch {}
  });
  const pair = (x, k, val) => { x[k] = val; if (val) x[k === 'd' ? 'c' : 'd'] = 0; };
  v.addEventListener('input', (e) => {
    const t = e.target, k = t.dataset.k; if (!k) return;
    if (t.dataset.a) { pair(vals[t.dataset.a] ||= { d: 0, c: 0 }, k, num(t.value)); if (num(t.value)) { const o = v.querySelector(`[data-a="${t.dataset.a}"][data-k="${k === 'd' ? 'c' : 'd'}"]`); if (o) o.value = ''; } }
    else if (t.dataset.p) { pair(pvals[t.dataset.p] ||= { d: 0, c: 0 }, k, num(t.value)); if (num(t.value)) v.querySelector(`[data-p="${t.dataset.p}"][data-k="${k === 'd' ? 'c' : 'd'}"]`).value = ''; }
    else if (t.dataset.ei != null && (k === 'd' || k === 'c')) { pair(erows[+t.dataset.ei], k, num(t.value)); if (num(t.value)) v.querySelector(`[data-ei="${t.dataset.ei}"][data-k="${k === 'd' ? 'c' : 'd'}"]`).value = ''; }
    else if (t.dataset.as) { (avals[t.dataset.as] ||= { cost: 0, accum: 0 })[k] = num(t.value); }
    else return;
    tot();
  });
  v.addEventListener('change', (e) => {
    const t = e.target; if (t.dataset.ei == null || !['emp', 'acc'].includes(t.dataset.k)) return;
    erows[+t.dataset.ei][t.dataset.k] = t.value;
    if (t.dataset.k === 'emp' && !erows[+t.dataset.ei].acc) { erows[+t.dataset.ei].acc = empAccDefault(empById[t.value]); redrawEmp(); }
    tot();
  });
  v.addEventListener('click', (e) => {
    const del = e.target.closest('[data-edel]'); if (del) { erows.splice(+del.dataset.edel, 1); redrawEmp(); tot(); }
  });
  v.querySelector('#ob-eadd')?.addEventListener('click', () => { const e0 = emps.find(e => e.is_active) || emps[0]; erows.push({ emp: e0.id, acc: empAccDefault(e0), d: 0, c: 0 }); redrawEmp(); tot(); });
  v.querySelector('#ob-acards')?.addEventListener('click', async () => {
    // الكلفة ومجمع الاستهلاك لحد آخر يوم قبل بداية السنة، من بطاقة الأصل ودورات الاستهلاك المرحّلة
    const prev = new Date(S.fy.start_date); prev.setDate(prev.getDate() - 1);
    const until = prev.toISOString().slice(0, 10);
    const { data: dl } = await sb.from('depreciation_lines').select('asset_id,amount,to_date,depreciation_runs!inner(status)').eq('depreciation_runs.status', 'posted').lte('to_date', until).in('asset_id', alist.map(a => a.id));
    const dep = {}; (dl || []).forEach(x => { dep[x.asset_id] = (dep[x.asset_id] || 0) + num(x.amount); });
    alist.forEach(a => { if (a.purchase_date > until) return; avals[a.id] = { cost: num(a.cost), accum: r3(num(a.opening_accum) + (dep[a.id] || 0)) };
      const ci = v.querySelector(`[data-as="${a.id}"][data-k="cost"]`), ai = v.querySelector(`[data-as="${a.id}"][data-k="accum"]`);
      if (ci) ci.value = obVal(avals[a.id].cost); if (ai) ai.value = obVal(avals[a.id].accum); });
    tot(); toast('تعبّت من بطاقات الأصول. راجعها قبل الحفظ', 'ok');
  });
  v.querySelector('#q').oninput = filter; v.querySelector('#only').onchange = filter;

  // تفريغ القسم الحالي
  const clearTab = (t) => {
    if (t === 'acc') Object.keys(vals).forEach(k => delete vals[k]);
    else if (byType[t]) byType[t].forEach(p => delete pvals[p.id]);
    else if (t === 'emp') erows.forEach(r => { r.d = 0; r.c = 0; });
    else if (t === 'ast') Object.keys(avals).forEach(k => delete avals[k]);
  };
  const redrawTab = (t) => {
    if (t === 'emp') return redrawEmp();
    if (byType[t]) byType[t].forEach(p => ['d', 'c'].forEach(k => { const i = v.querySelector(`[data-p="${p.id}"][data-k="${k}"]`); if (i) i.value = obVal(pvals[p.id]?.[k]); }));
    if (t === 'ast') alist.forEach(a => ['cost', 'accum'].forEach(k => { const i = v.querySelector(`[data-as="${a.id}"][data-k="${k}"]`); if (i) i.value = obVal(avals[a.id]?.[k]); }));
  };
  v.querySelector('#ob-clear')?.addEventListener('click', async () => {
    if (!(await confirmBox(`تفريغ كل أرصدة «${OB_TABS[tab]}» من الشاشة؟ (ما بينحفظ إلا لما تضغط حفظ)`))) return;
    clearTab(tab); redrawTab(tab); refresh();
  });

  // نسخ من سنة سابقة
  const copyDialog = (preYear) => {
    const years = (S.fiscalYearsAll || S.fiscalYears).filter(y => y.id !== S.fy.id).sort((a, b) => b.start_date.localeCompare(a.start_date));
    if (!years.length) return toast('ما في سنة مالية ثانية لهالشركة تنسخ منها', 'err');
    const before = years.filter(y => y.end_date < S.fy.start_date);
    const def = preYear && years.some(y => y.id === preYear) ? preYear : (before[0] || years[0]).id;
    const eq = accs.filter(a => !a.is_group && a.is_active && a.category === 'equity');
    const retDef = eq.find(a => /مدور|محتجز|retained/i.test(a.name))?.id || eq[0]?.id || '';
    const m = modal({ title: '📋 نسخ الأرصدة من سنة سابقة', size: 'sm', body: `<form id="cp-f">
      <label>السنة اللي بدك تنسخ أرصدة نهايتها<select name="fy">${years.map(y => `<option value="${y.id}" ${y.id === def ? 'selected' : ''}>${esc(y.name || y.code)} (${fmtDate(y.start_date)} ← ${fmtDate(y.end_date)})${y.is_closed ? ' — مغلقة' : ''}</option>`).join('')}</select></label>
      <div style="margin:10px 0 4px"><b>الأقسام</b></div>
      ${tabs.map(t => `<label class="check"><input type="checkbox" name="t_${t}" ${t === tab ? 'checked' : ''}> ${OB_TABS[t]}</label>`).join('')}
      <label style="margin-top:10px">طريقة النسخ<select name="mode"><option value="replace">استبدال أرصدة القسم بالمنسوخ</option><option value="empty">تعبئة الفاضي بس (ما بيلمس اللي مكتوب)</option></select></label>
      <label>حساب الأرباح المدورة (لنتيجة السنة إذا ما انقفلت)<select name="ret"><option value="">—</option>${eq.map(a => `<option value="${a.id}" ${a.id === retDef ? 'selected' : ''}>${esc(a.code)} — ${esc(a.name)}</option>`).join('')}</select></label>
      <p class="muted" style="font-size:13px">بينسخ الأرصدة المرحّلة بنهاية السنة اللي بتختارها. الإيرادات والمصاريف ما بتنسخ، صافيها بيروح على الأرباح المدورة. بعد النسخ راجع الأرقام واحفظ.</p></form>`,
      foot: '<button class="btn primary" data-go>📋 نسخ</button><button class="btn" data-close>إلغاء</button>' });
    m.el.querySelector('[data-go]').onclick = async (e) => {
      const f = formData(m.el.querySelector('#cp-f')), sel = tabs.filter(t => m.el.querySelector(`[name="t_${t}"]`).checked);
      if (!sel.length) return toast('اختار قسم واحد على الأقل', 'err');
      e.target.disabled = true;
      try {
        const call = (kind, type) => sb.rpc('opening_source', { p_company: S.company.id, p_from_fy: f.fy, p_kind: kind, p_type: type || null }).then(r => { if (r.error) throw r.error; return r.data || []; });
        let n = 0; const miss = [];
        for (const t of sel) {
          const rows = await call(t === 'acc' ? 'accounts' : t === 'emp' ? 'employees' : t === 'ast' ? 'assets' : 'parties', byType[t] ? t : null);
          if (f.mode === 'replace') clearTab(t);
          if (t === 'acc') {
            for (const r of rows) {
              let aid = r.account_id, bal = num(r.amount);
              if (!aid) { if (!f.ret) { miss.push('نتيجة السنة (ما اخترت حساب أرباح مدورة)'); continue; } aid = f.ret; }
              const x = vals[aid] ||= { d: 0, c: 0 };
              if (f.mode === 'empty' && (x.d || x.c) && r.account_id) continue;
              const net = r3((x.d || 0) - (x.c || 0) + bal);   // نتيجة السنة بتنضاف على رصيد الأرباح المدورة
              x.d = net > 0 ? net : 0; x.c = net < 0 ? -net : 0; n++;
            }
          } else if (byType[t]) {
            for (const r of rows) {
              if (!byType[t].some(p => p.id === r.party_id)) { miss.push('طرف موقوف أو مش موجود'); continue; }
              const x = pvals[r.party_id] ||= { d: 0, c: 0 };
              if (f.mode === 'empty' && (x.d || x.c)) continue;
              const b = num(r.amount); x.d = b > 0 ? b : 0; x.c = b < 0 ? -b : 0; n++;
            }
          } else if (t === 'emp') {
            for (const r of rows) {
              if (!empById[r.employee_id]) { miss.push('موظف'); continue; }
              let row = erows.find(z => z.emp === r.employee_id && z.acc === r.account_id) || erows.find(z => z.emp === r.employee_id && !z.d && !z.c);
              if (row && f.mode === 'empty' && (row.d || row.c)) continue;
              if (!row) erows.push(row = { emp: r.employee_id, acc: r.account_id, d: 0, c: 0 });
              const b = num(r.amount); row.acc = r.account_id; row.d = b > 0 ? b : 0; row.c = b < 0 ? -b : 0; n++;
            }
          } else if (t === 'ast') {
            for (const r of rows) {
              if (!alist.some(a => a.id === r.asset_id)) { miss.push('أصل مستبعد'); continue; }
              const x = avals[r.asset_id] ||= { cost: 0, accum: 0 };
              if (f.mode === 'empty' && (x.cost || x.accum)) continue;
              x.cost = num(r.amount); x.accum = num(r.amount2); n++;
            }
          }
          redrawTab(t);
        }
        refresh(); m.close();
        toast(`تم نسخ ${n} رصيد${miss.length ? ` — ما انتسخ ${miss.length}: ${[...new Set(miss)].join('، ')}` : ''}. راجع واحفظ`, miss.length ? 'warn' : 'ok');
      } catch (err) { e.target.disabled = false; toast(arError(err), 'err'); }
    };
  };
  v.querySelector('#ob-copy')?.addEventListener('click', () => copyDialog());
  if (qs.get('from') && !readOnly) { try { history.replaceState(null, '', '#/opening?k=' + tab); } catch {} copyDialog(qs.get('from')); }

  const save = async (post) => {
    const out = [];
    Object.entries(vals).forEach(([id, x]) => { if (x.d || x.c) out.push({ account_id: id, party_id: null, employee_id: null, asset_id: null, debit: x.d || 0, credit: x.c || 0, description: 'رصيد افتتاحي' }); });
    plist.forEach(p => { const x = pvals[p.id]; if (x && (x.d || x.c)) out.push({ account_id: p.account_id, party_id: p.id, employee_id: null, asset_id: null, debit: x.d || 0, credit: x.c || 0, description: 'رصيد افتتاحي - ' + p.name }); });
    for (const r of erows) { if (!(r.d || r.c)) continue;
      if (!r.acc) return toast(`اختار الحساب لسطر الموظف ${empById[r.emp]?.name || ''}`, 'err');
      out.push({ account_id: r.acc, party_id: null, employee_id: r.emp, asset_id: null, debit: r.d || 0, credit: r.c || 0, description: 'رصيد افتتاحي - ' + (empById[r.emp]?.name || '') }); }
    for (const a of alist) { const x = avals[a.id]; if (!x || !(x.cost || x.accum)) continue;
      if ((x.cost && !a.asset_account_id) || (x.accum && !a.accum_account_id)) return toast(`الأصل ${a.code} بدون حساب أصل/مجمع. عدّل بطاقته أول`, 'err');
      if (x.cost < 0 || x.accum < 0) return toast(`أرصدة الأصل ${a.code} لازم موجبة`, 'err');
      if (x.cost) out.push({ account_id: a.asset_account_id, party_id: null, employee_id: null, asset_id: a.id, debit: x.cost, credit: 0, description: 'كلفة أصل - ' + a.name });
      if (x.accum) out.push({ account_id: a.accum_account_id, party_id: null, employee_id: null, asset_id: a.id, debit: 0, credit: x.accum, description: 'مجمع استهلاك - ' + a.name }); }
    keepAst.forEach(l => out.push({ account_id: l.account_id, party_id: null, employee_id: null, asset_id: l.asset_id, debit: num(l.debit), credit: num(l.credit), description: l.description }));
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
  v.querySelector('#prn')?.addEventListener('click', () => printVoucher('opening', entry, lines, accById));
}

// أداة الأرصدة الافتتاحية (الأدوات): اختيار القسم والمصدر
async function viewOpeningTool(v) {
  if (!needCompanyFY(v)) return;
  const years = (S.fiscalYearsAll || S.fiscalYears).filter(y => y.id !== S.fy.id).sort((a, b) => b.start_date.localeCompare(a.start_date));
  const before = years.find(y => y.end_date < S.fy.start_date);
  const parts = [['acc', '📒', 'أرصدة الحسابات', 'رصيد كل حساب من الدليل (صندوق، بنوك، رأس المال…)'],
    ['customer', '🧑‍💼', 'أرصدة العملاء', 'ذمة كل عميل لحاله'], ['supplier', '🏭', 'أرصدة الموردين', 'رصيد كل مورد لحاله'],
    ...(can('payroll', 'view') ? [['emp', '👷', 'أرصدة الموظفين', 'سلف وذمم ومستحقات كل موظف']] : []),
    ...(can('fixed_assets', 'view') ? [['ast', '🏗️', 'أرصدة الأصول الثابتة', 'كلفة ومجمع استهلاك كل أصل']] : [])];
  v.innerHTML = `<div class="page-head"><h2>🧮 الأرصدة الافتتاحية</h2><span class="muted">للسنة ${esc(S.fy.name || S.fy.code)} — بتاريخ ${fmtDate(S.fy.start_date)}</span></div>
    <div class="card" style="max-width:820px">
      <h3 style="margin-top:0">١. شو بدك تدخل؟</h3>
      <div class="launch-grid" id="ot-parts">${parts.map(([k, i, l, d], n) => `<label class="launch-tile sub ot-part ${n === 0 ? 'on' : ''}" style="cursor:pointer"><input type="radio" name="part" value="${k}" ${n === 0 ? 'checked' : ''} hidden><span class="li">${i}</span><b>${l}</b><small>${d}</small></label>`).join('')}</div>
      <h3>٢. من وين الأرصدة؟</h3>
      <label class="check"><input type="radio" name="src" value="manual" checked> ✍️ إدخال يدوي</label>
      <label class="check"><input type="radio" name="src" value="copy" ${years.length ? '' : 'disabled'}> 📋 نسخ أرصدة نهاية سنة سابقة</label>
      <div id="ot-year" style="margin:6px 26px 0;display:none"><select id="ot-fy">${years.map(y => `<option value="${y.id}" ${y.id === before?.id ? 'selected' : ''}>${esc(y.name || y.code)} (${fmtDate(y.start_date)} ← ${fmtDate(y.end_date)})${y.is_closed ? ' — مغلقة' : ''}</option>`).join('')}</select></div>
      ${years.length ? '' : '<p class="muted" style="font-size:13px">ما في سنة ثانية لهالشركة تنسخ منها.</p>'}
      <div style="margin-top:16px"><button class="btn primary" id="ot-go">فتح ←</button></div>
      <p class="muted" style="font-size:13px;margin-top:12px">كل الأقسام بتنحفظ بقيد افتتاحي واحد للسنة. إذا السنة السابقة انقفلت وتدوّرت من «السنوات المالية»، الأرصدة بتكون جاهزة لحالها.</p>
    </div>`;
  v.querySelector('#ot-parts').addEventListener('change', () => v.querySelectorAll('.ot-part').forEach(x => x.classList.toggle('on', x.querySelector('input').checked)));
  v.querySelectorAll('[name="src"]').forEach(r => r.onchange = () => { v.querySelector('#ot-year').style.display = v.querySelector('[name="src"]:checked').value === 'copy' ? '' : 'none'; });
  v.querySelector('#ot-go').onclick = () => {
    const k = v.querySelector('[name="part"]:checked').value, copy = v.querySelector('[name="src"]:checked').value === 'copy';
    location.hash = '#/opening?k=' + k + (copy ? '&from=' + v.querySelector('#ot-fy').value : '');
  };
}

export const FINANCE_ROUTES = {
  'accounts': viewAccounts,
  'opening': viewOpening,
  'opening-tool': viewOpeningTool,
  'journal': voucherList('journal'),
  'receipts': voucherList('receipt'),
  'payments': voucherList('payment'),
};

// توزيع الدفعة على فواتير الطرف الآجلة المفتوحة
async function allocateDialog(entry, partyIds, pById) {
  const blocks = await Promise.all(partyIds.map(async pid => {
    const [o, a] = await Promise.all([sb.rpc('party_open_invoices', { p_company: S.company.id, p_party: pid, p_except_entry: entry.id }),
      sb.from('invoice_allocations').select('invoice_id,amount').eq('entry_id', entry.id)]);
    if (o.error) throw o.error;
    const mine = Object.fromEntries((a.data || []).map(x => [x.invoice_id, num(x.amount)]));
    return { pid, rows: (o.data || []).filter(r => num(r.remaining) > 0.0005 || mine[r.invoice_id]), mine };
  })).catch(e => { toast(arError(e), 'err'); return null; });
  if (!blocks) return;
  const m = modal({ title: `🧾 توزيع ${docNo(entry)} على الفواتير`, body: blocks.map(b => `<h4 style="margin:8px 0">${esc(pById[b.pid]?.name || '')}</h4>
    <div class="table-wrap"><table class="t" data-p="${b.pid}"><thead><tr><th>الفاتورة</th><th>التاريخ</th><th>الاستحقاق</th><th>المبلغ</th><th>المتبقي قبل الدفعة</th><th style="width:130px">من هالدفعة</th></tr></thead><tbody>
    ${b.rows.map(r => `<tr><td>${esc(r.doc_code || String(r.inv_no))}</td><td>${fmtDate(r.inv_date)}</td><td ${r.due_date < today() ? 'style="color:var(--bad)"' : ''}>${fmtDate(r.due_date)}</td>
      <td class="n">${fmtNum(r.total - r.returned)}</td><td class="n">${fmtNum(r.remaining)}</td>
      <td><input class="cell n" dir="ltr" inputmode="decimal" data-inv="${r.invoice_id}" data-max="${r.remaining}" value="${b.mine[r.invoice_id] || ''}"></td></tr>`).join('') || '<tr><td colspan="6" class="empty">ما في فواتير آجلة مفتوحة</td></tr>'}</tbody></table></div>
    <div style="margin:6px 0"><button class="btn sm" data-auto="${b.pid}">⚡ تلقائي (الأقدم أول)</button></div>`).join(''),
    foot: '<button class="btn primary" data-save>💾 حفظ التوزيع</button><button class="btn" data-close>إغلاق</button>' });
  m.el.querySelectorAll('[data-auto]').forEach(btn => btn.onclick = async () => {
    const { error } = await sb.rpc('auto_allocate', { p_entry: entry.id, p_party: btn.dataset.auto });
    if (error) return toast(arError(error), 'err');
    toast('انوزّعت الدفعة على الأقدم أول', 'ok'); m.close(true); allocateDialog(entry, partyIds, pById);
  });
  m.el.querySelector('[data-save]').onclick = async () => {
    for (const t of m.el.querySelectorAll('table[data-p]')) {
      const items = [...t.querySelectorAll('[data-inv]')].map(i => ({ invoice_id: i.dataset.inv, amount: num(i.value) })).filter(x => x.amount > 0);
      const { error } = await sb.rpc('allocate_payment', { p_entry: entry.id, p_party: t.dataset.p, p_items: items });
      if (error) return toast(arError(error), 'err');
    }
    toast('انحفظ التوزيع', 'ok'); m.close(true);
  };
}
