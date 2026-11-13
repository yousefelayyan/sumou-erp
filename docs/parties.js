// =====================================================================
//  السمو ERP — المرحلة 4: الزبائن والموردين
// =====================================================================
import { loadDepartments } from './departments.js';
import { loadLookups, lookupDatalistSync, repOptions, hasReps, loyaltyOptions, hasLoyalty } from './lookups.js';
import { loadCustomFields, cfFieldsHTML, cfValues } from './orders.js';
import { loadFieldLayout, applyLayout, checkRequired } from './mfg.js';
import { attachAudit } from './audit.js';
import { docNo, loadNumbering, masterCode } from './numbering.js';
import { emailDialog, emailWrap, emailTable } from './messages.js';
import { S, sb, esc, fmtDate, fmtNum, num, today, toast, arError, modal, confirmBox, formData, can, log } from './core.js';
import { loadAccounts, leafAccounts, accLabel, ENTRY_TYPES, downloadCSV } from './finance.js';
import { printDoc } from './print.js';

export const PARTY = {
  customer: { label: 'عميل', plural: 'العملاء', screen: 'customers', route: 'customers', icon: '🧑‍💼', accType: 'customer', side: 1 },
  supplier: { label: 'مورد', plural: 'الموردين', screen: 'suppliers', route: 'suppliers', icon: '🏭', accType: 'supplier', side: -1 },
  expense:  { label: 'مصروف', plural: 'المصاريف', screen: 'expense_cards', route: 'expenses', icon: '💸', accType: null, accCat: 'expenses', side: 1 },
};

const STOPS = [['stop_credit', 'وقف البيع الآجل'], ['stop_cheques', 'وقف استلام الشيكات منه'], ['stop_if_debit', 'وقف البيع الآجل إذا عليه رصيد مدين']];
export async function loadParties(force = false) {
  if (!S.company) return [];
  if (!force && S.parties && S.partiesCompany === S.company.id) return S.parties;
  const all = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await sb.from('parties').select('*').eq('company_id', S.company.id).order('code').range(from, from + 999);
    if (error) throw error;
    all.push(...data); if (data.length < 1000) break;
  }
  S.parties = all; S.partiesCompany = S.company.id;
  return all;
}
export const partyLabel = (p) => p ? `${p.code} — ${p.name}` : '';
export function partyDatalist(parties, id = 'party-list') {
  return `<datalist id="${id}">${parties.filter(p => p.is_active).map(p => `<option value="${esc(partyLabel(p))}">${PARTY[p.party_type].label}</option>`).join('')}</datalist>`;
}
export function resolveParty(parties, text) {
  const t = (text || '').trim(); if (!t) return null;
  const code = t.split('—')[0].trim();
  return parties.find(p => p.code === code) || parties.find(p => p.name === t) || null;
}

// ---------------------------------------------------------------------
//  قائمة العملاء / الموردين
// ---------------------------------------------------------------------
function partyList(type) {
  return async function (v, ctx) {
    if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
    const P = PARTY[type];
    const [parties, accs, , cats] = await Promise.all([loadParties(true), loadAccounts(), loadNumbering(true), loadPartyCats(type), loadLookups(), loadCustomFields(), loadFieldLayout(), loadDepartments()]);
    const catById = Object.fromEntries(cats.map(c => [c.id, c]));
    const stopOf = (p) => { const c = catById[p.category_id] || {}; return STOPS.filter(([k]) => p[k] || c[k]).map(([, l]) => l.replace('وقف ', '')).join('، '); };
    let bal = {};
    if (S.fy) {
      const { data } = await sb.from('party_balances').select('party_id,debit,credit').eq('company_id', S.company.id).eq('fiscal_year_id', S.fy.id);
      bal = Object.fromEntries((data || []).map(r => [r.party_id, num(r.debit) - num(r.credit)]));
    }
    const list = parties.filter(p => p.party_type === type);
    const total = list.reduce((s, p) => s + (bal[p.id] || 0), 0) * P.side;
    v.innerHTML = `
      <div class="page-head"><h2>${P.icon} ${P.plural}</h2><span class="badge brand">${list.length}</span>
        <span class="muted">إجمالي الأرصدة: <b dir="ltr">${fmtNum(total)}</b></span><div class="spacer"></div>
        <select class="search" id="fc" style="min-width:140px"><option value="">كل الفئات</option>${cats.map(c => `<option value="${c.id}">${esc(c.name)}</option>`).join('')}<option value="-">بدون فئة</option></select>
        <input class="search" id="q" placeholder="بحث بالاسم أو الرقم أو الهاتف…">
        <a class="btn sm" href="#/party-categories?type=${type}">🗂️ فئات ${P.plural}</a>
        <button class="btn sm" id="csv">⬇️ Excel</button>
        ${can(P.screen, 'add') ? `<button class="btn primary" id="add">➕ ${P.label} جديد</button>` : ''}</div>
      ${!accs.length ? `<div class="notice">لازم يكون في دليل حسابات أول. <a href="#/accounts">روح لدليل الحسابات</a></div>` : ''}
      <div class="card table-wrap"><table class="t">
        <thead><tr><th>الرقم</th><th>الاسم</th><th>الفئة</th><th>الهاتف</th><th>المدينة</th><th>الرقم الضريبي</th><th style="text-align:left">الرصيد</th><th>الحالة</th><th></th></tr></thead>
        <tbody id="rows"></tbody></table></div>
      <p class="muted" style="font-size:13px">الرصيد من القيود المرحّلة بالسنة المالية الحالية. ${type === 'customer' ? 'الرصيد الموجب = علينا نحصّله من العميل.' : 'الرصيد الموجب = علينا ندفعه للمورد.'}</p>`;
    const draw = () => {
      const q = v.querySelector('#q').value.trim().toLowerCase(), fc = v.querySelector('#fc').value;
      const rows = list.filter(p => (!fc || (fc === '-' ? !p.category_id : p.category_id === fc))).filter(p => !q || [p.code, p.name, p.name2, p.reference, p.trade_name, p.phone, p.mobile, p.tax_no].some(x => (x || '').toLowerCase().includes(q)));
      v.querySelector('#rows').innerHTML = rows.map(p => { const b = (bal[p.id] || 0) * P.side; const over = p.credit_limit > 0 && b > p.credit_limit;
        return `<tr><td>${esc(p.code)}</td><td><b>${esc(p.name)}</b>${p.trade_name ? `<div class="muted" style="font-size:12px">${esc(p.trade_name)}</div>` : ''}</td><td>${esc(catById[p.category_id]?.name || '')}</td>
        <td dir="ltr" style="text-align:right">${esc(p.mobile || p.phone || '')}</td><td>${esc(p.city || '')}</td><td dir="ltr" style="text-align:right">${esc(p.tax_no || '')}</td>
        <td dir="ltr" style="text-align:left;${over ? 'color:var(--bad);font-weight:700' : ''}">${b ? fmtNum(b) : '<span class="muted">—</span>'}${over ? ' ⚠️' : ''}</td>
        <td>${p.is_active ? '<span class="badge ok">فعّال</span>' : '<span class="badge bad">موقوف</span>'}${stopOf(p) ? ` <span class="badge warn" title="${esc(stopOf(p))}">⛔ ${esc(stopOf(p))}</span>` : ''}</td>
        <td class="actions"><a class="btn sm" href="#/party-profile?id=${p.id}" title="ملف إحصائي">📊</a> <a class="btn sm" href="#/party-docs?t=docs&party=${p.id}" title="الوثائق">📄</a> <a class="btn sm" href="#/rep-party?party=${p.id}">كشف</a>
          ${can(P.screen, 'edit') ? `<button class="btn sm" data-edit="${p.id}">تعديل</button>` : ''}
          ${can(P.screen, 'delete') ? `<button class="btn sm danger" data-del="${p.id}">حذف</button>` : ''}</td></tr>`; }).join('')
        || `<tr><td colspan="9" class="empty">ما في ${P.plural}</td></tr>`;
    };
    draw();
    v.querySelector('#q').oninput = draw; v.querySelector('#fc').onchange = draw;
    v.querySelector('#add')?.addEventListener('click', () => partyForm(type, null, accs, ctx, cats));
    v.querySelector('#csv').onclick = () => downloadCSV(`${P.plural} - ${S.company.name}.csv`,
      [['الرقم', 'الاسم', 'الاسم التجاري', 'الهاتف', 'الموبايل', 'الإيميل', 'المدينة', 'العنوان', 'الرقم الضريبي', 'سقف الائتمان', 'مدة السداد', 'الرصيد']]
        .concat(list.map(p => [p.code, p.name, p.trade_name, p.phone, p.mobile, p.email, p.city, p.address, p.tax_no, p.credit_limit, p.payment_terms_days, ((bal[p.id] || 0) * P.side).toFixed(3)])));
    v.querySelector('#rows').onclick = async (e) => {
      const ed = e.target.closest('[data-edit]'), dl = e.target.closest('[data-del]');
      if (ed) partyForm(type, list.find(p => p.id === ed.dataset.edit), accs, ctx, cats);
      if (dl) {
        const p = list.find(x => x.id === dl.dataset.del);
        if (!(await confirmBox(`حذف ${P.label} «${p.name}»؟`))) return;
        const { error } = await sb.from('parties').delete().eq('id', p.id);
        if (error) return toast(arError(error), 'err');
        await log('حذف', P.screen, p.id, { name: p.name }); toast('تم الحذف', 'ok'); ctx.rerender();
      }
    };
  };
}

const lkOpts = (kind, val) => (S._lk?.cid === S.company?.id ? S._lk.rows : []).filter(r => r.kind === kind && (r.is_active || r.id === val))
  .map(r => `<option value="${r.id}" ${r.id === val ? 'selected' : ''}>${esc(r.code)} — ${esc(r.name)}</option>`).join('');
const subDepts = () => (S._depts?.cid === S.company?.id ? S._depts.rows : []).filter(d => d.kind === 'sub');

async function partyForm(type, p, accs, ctx, cats = []) {
  if (type === 'customer') { const { data } = await sb.from('price_lists').select('id,code,name,is_active').eq('company_id', S.company.id).order('code'); S._plists = data || []; }
  const P = PARTY[type], isNew = !p;
  const leaves = leafAccounts(accs);
  const okAcc = (a) => P.accCat ? a.category === P.accCat : a.account_type === P.accType;
  const def = leaves.find(okAcc);
  p = p || { name: '', code: masterCode(type === 'customer' ? 'm_customer' : type === 'supplier' ? 'm_supplier' : 'm_expense', (S.parties || []).filter(x => x.party_type === type).map(x => x.code)) || '', account_id: def?.id, credit_limit: 0, payment_terms_days: 0, is_active: true };
  const sorted = [...leaves].filter(a => !P.accCat || okAcc(a)).sort((a, b) => okAcc(b) - okAcc(a) || a.code.localeCompare(b.code, 'en', { numeric: true }));
  const m = modal({ title: isNew ? `${P.label} جديد` : `تعديل ${P.label}: ${p.name}`, body: `
    <form id="p-form">
      <div class="tabs"><div class="tab active" data-tab="g">عام</div><div class="tab" data-tab="c">الاتصال والعنوان</div><div class="tab" data-tab="f">المالية</div>${cfFieldsHTML(type, p.extra) || (type === 'customer' && hasLoyalty()) ? '<div class="tab" data-tab="x">إضافي</div>' : ''}</div>
      <div class="tab-panel active" data-tab="g"><div class="grid cols-2">
        <div class="field"><label>الاسم *</label><input name="name" required value="${esc(p.name)}"></div>
        <div class="field"><label>الرقم</label><input name="code" value="${esc(p.code)}" placeholder="تلقائي" dir="ltr"></div>
        ${type === 'customer' && (S._plists || []).length ? `<div class="field"><label>قائمة الأسعار</label><select name="price_list_id"><option value="">— سعر البيع العادي —</option>${S._plists.filter(l => l.is_active || l.id === p.price_list_id).map(l => `<option value="${l.id}" ${l.id === p.price_list_id ? 'selected' : ''}>${esc(l.code)} — ${esc(l.name)}</option>`).join('')}</select></div>` : ''}
        ${type === 'customer' && hasReps() ? `<div class="field"><label>المندوب</label><select name="sales_rep_id"><option value="">—</option>${repOptions(p.sales_rep_id)}</select></div>` : ''}
        <div class="field"><label>الفئة</label><select name="category_id"><option value="">— بدون فئة —</option>${cats.filter(c => c.is_active || c.id === p.category_id).map(c => `<option value="${c.id}" ${c.id === p.category_id ? 'selected' : ''}>${esc(c.code)} — ${esc(c.name)}</option>`).join('')}</select></div>
        <div class="field"><label>الوصف #2 (اسم ثاني / بالإنجليزي)</label><input name="name2" value="${esc(p.name2 || '')}"></div>
        <div class="field"><label>المرجع</label><input name="reference" value="${esc(p.reference || '')}"></div>
        <div class="field"><label>الاسم التجاري</label><input name="trade_name" value="${esc(p.trade_name)}"></div>
        <div class="field"><label>الرقم الضريبي</label><input name="tax_no" value="${esc(p.tax_no)}" dir="ltr"></div>
        <div class="field"><label>الرقم الوطني</label><input name="national_no" value="${esc(p.national_no)}" dir="ltr"></div>
        <div class="field"><label>الشخص المسؤول</label><input name="contact_person" value="${esc(p.contact_person)}"></div></div>
        <label class="check"><input type="checkbox" name="is_active" ${p.is_active ? 'checked' : ''}> فعّال</label></div>
      <div class="tab-panel" data-tab="x">
        ${type === 'customer' && hasLoyalty() ? `<div class="grid cols-2"><div class="field"><label>بطاقة الولاء</label><select name="loyalty_type_id"><option value="">— بدون بطاقة —</option>${loyaltyOptions(p.loyalty_type_id)}</select></div>
          <div class="field"><label>رقم البطاقة</label><input name="loyalty_card_no" dir="ltr" value="${esc(p.loyalty_card_no || '')}"></div></div>` : ''}
        ${cfFieldsHTML(type, p.extra)}</div>
      <div class="tab-panel" data-tab="c"><div class="grid cols-2">
        <div class="field"><label>الموبايل</label><input name="mobile" value="${esc(p.mobile)}" dir="ltr"></div>
        <div class="field"><label>الهاتف</label><input name="phone" value="${esc(p.phone)}" dir="ltr"></div>
        <div class="field"><label>الإيميل</label><input name="email" type="email" value="${esc(p.email)}" dir="ltr"></div>
        <div class="field"><label>إيميل ثاني</label><input name="email2" type="email" value="${esc(p.email2 || '')}" dir="ltr"></div>
        <div class="field"><label>إيميل ثالث</label><input name="email3" type="email" value="${esc(p.email3 || '')}" dir="ltr"></div>
        <div class="field"><label>المدينة</label><input name="city" list="lk-city" value="${esc(p.city)}">${lookupDatalistSync('lk-city', ['region', 'country'])}</div></div>
        <div class="field"><label>العنوان</label><input name="address" value="${esc(p.address)}"></div></div>
      <div class="tab-panel" data-tab="f"><div class="grid cols-2">
        <div class="field" style="grid-column:span 2"><label>الحساب بدليل الحسابات *</label><select name="account_id">
          ${sorted.map(a => `<option value="${a.id}" ${a.id === p.account_id ? 'selected' : ''}>${esc(accLabel(a))}${okAcc(a) ? ' ★' : ''}</option>`).join('')}</select>
          <span class="hint">عادة «${type === 'customer' ? 'الذمم المدينة (العملاء)' : 'الذمم الدائنة (الموردين)'}». كل ${P.plural} بيتجمّعوا على هالحساب، وكل واحد إله كشف لحاله.</span></div>
        <div class="field"><label>سقف الائتمان</label><input name="credit_limit" value="${p.credit_limit || ''}" inputmode="decimal" dir="ltr" placeholder="0 = بدون سقف"></div>
        ${type === 'customer' ? `<div class="field" style="grid-column:span 2"><label>⛔ إيقاف البيع</label><div style="display:flex;gap:14px;flex-wrap:wrap">${STOPS.map(([k, l]) => `<label style="font-weight:normal"><input type="checkbox" name="${k}" ${p[k] ? 'checked' : ''}> ${l}</label>`).join('')}</div>
          <span class="hint">بيمنع ترحيل الفاتورة الآجلة أو تسجيل الشيك، إلا لمين إله صلاحية «تجاوز سقف الائتمان وإيقاف البيع». العلامة على فئة العميل بتنطبق كمان.</span></div>` : ''}
        <div class="field"><label>مدة السداد / شروط الدفع (أيام)</label><input name="payment_terms_days" value="${p.payment_terms_days || ''}" inputmode="numeric" dir="ltr"></div>
        <div class="field"><label>وسيلة الدفع الافتراضية</label><select name="payment_method_id"><option value="">—</option>${lkOpts('payment_method', p.payment_method_id)}</select></div>
        <div class="field"><label>العملة</label><input name="currency" list="cur-list" value="${esc(p.currency || '')}" dir="ltr" placeholder="JOD"><datalist id="cur-list"></datalist></div>
        <div class="field"><label>المسار</label><select name="route_id"><option value="">—</option>${lkOpts('route', p.route_id)}</select></div>
        ${subDepts().length ? `<div class="field"><label>الدائرة</label><select name="department_id"><option value="">—</option>${subDepts().filter(d => d.is_active || d.id === p.department_id).map(d => `<option value="${d.id}" ${d.id === p.department_id ? 'selected' : ''}>${esc(d.code)} — ${esc(d.name)}</option>`).join('')}</select></div>` : ''}</div>
        <div class="field"><label>ملاحظات</label><textarea name="notes" style="min-height:60px">${esc(p.notes)}</textarea></div></div>
    </form>`, foot: `<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>` });
  if (!isNew) attachAudit(m.el, p);
  m.el.querySelectorAll('.tabs').forEach(tabs => tabs.addEventListener('click', ev => {
    const t = ev.target.closest('.tab'); if (!t) return;
    tabs.querySelectorAll('.tab').forEach(x => x.classList.toggle('active', x === t));
    m.el.querySelectorAll('.tab-panel').forEach(x => x.classList.toggle('active', x.dataset.tab === t.dataset.tab));
  }));
  applyLayout(m.el.querySelector('#p-form'), type);
  sb.from('currencies').select('code,name').eq('company_id', S.company.id).eq('is_active', true).then(({ data }) => {
    const dl = m.el.querySelector('#cur-list'); if (dl) dl.innerHTML = '<option value="JOD">دينار أردني</option>' + (data || []).map(c => `<option value="${esc(c.code)}">${esc(c.name)}</option>`).join('');
  });
  m.el.querySelector('[data-save]').onclick = async () => {
    const d = formData(m.el.querySelector('#p-form'));
    if (!d.name) return toast('الاسم مطلوب', 'err');
    { const rq = checkRequired(m.el.querySelector('#p-form'), type); if (rq) return toast(rq, 'err'); }
    if (!d.account_id) return toast('اختار الحساب', 'err');
    const ex = cfValues(m.el.querySelector('#p-form'), type, p.extra); Object.keys(d).filter(k => k.startsWith('cf__')).forEach(k => delete d[k]); if (ex) d.extra = ex;
    if ('loyalty_type_id' in d) d.loyalty_type_id = d.loyalty_type_id || null; if ('loyalty_card_no' in d) d.loyalty_card_no = d.loyalty_card_no || null;
    if (type === 'customer') STOPS.forEach(([k]) => d[k] = !!d[k]);
    d.credit_limit = num(d.credit_limit); d.payment_terms_days = parseInt(d.payment_terms_days) || 0; d.category_id = d.category_id || null; if ('sales_rep_id' in d) d.sales_rep_id = d.sales_rep_id || null; if ('price_list_id' in d) d.price_list_id = d.price_list_id || null;
    ['route_id', 'payment_method_id', 'department_id', 'currency', 'reference', 'name2', 'email2', 'email3'].forEach(k => { if (k in d) d[k] = String(d[k] || '').trim() || null; });
    if (isNew) { d.company_id = S.company.id; d.party_type = type; d.code = d.code || ''; }
    else if (!d.code) delete d.code;
    const res = isNew ? await sb.from('parties').insert(d) : await sb.from('parties').update(d).eq('id', p.id);
    if (res.error) return toast(arError(res.error), 'err');
    await log(isNew ? 'إضافة' : 'تعديل', P.screen, p.id || d.name, { name: d.name });
    S.parties = null; toast('تم الحفظ', 'ok'); m.close(); ctx.rerender();
  };
}

// ---------------------------------------------------------------------
//  كشف حساب عميل/مورد
// ---------------------------------------------------------------------
async function viewPartyLedger(v) {
  if (!S.company || !S.fy) return void (v.innerHTML = `<div class="notice info">اختار شركة وسنة مالية من فوق أول.</div>`);
  const parties = await loadParties();
  const pre = parties.find(p => p.id === new URLSearchParams(location.hash.split('?')[1] || '').get('party'));
  v.innerHTML = `<div class="page-head"><h2>👤 كشف حساب عميل / مورد</h2></div>
    <div class="card no-print filters">
      <div class="field" style="min-width:300px;flex:1"><label>العميل / المورد</label><input list="party-list" id="f-p" value="${esc(partyLabel(pre))}" placeholder="رقم أو اسم…">${partyDatalist(parties)}</div>
      <div class="field"><label>من تاريخ</label><input type="date" id="f-from" value="${S.fy.start_date}"></div>
      <div class="field"><label>إلى تاريخ</label><input type="date" id="f-to" value="${S.fy.end_date}"></div>
      <div class="field" style="justify-content:flex-end"><button class="btn primary" id="f-run">عرض التقرير</button></div>
      <div class="field" style="justify-content:flex-end;flex-direction:row;gap:6px"><button class="btn" id="f-print">🖨️ طباعة</button><button class="btn" id="f-csv">⬇️ Excel</button><button class="btn" id="f-wa" style="background:#25d366;color:#fff;border-color:#25d366">💬 واتساب</button><button class="btn" id="f-mail">📧 إيميل</button></div>
    </div><div id="out"><div class="empty">اختار عميل أو مورد واضغط «عرض التقرير»</div></div>`;
  let last = null;
  const run = async () => {
    const p = resolveParty(parties, v.querySelector('#f-p').value);
    if (!p) return toast('اختار عميل أو مورد من القائمة', 'err');
    const from = v.querySelector('#f-from').value, to = v.querySelector('#f-to').value, out = v.querySelector('#out');
    const P = PARTY[p.party_type];
    const [ob, mv] = await Promise.all([
      sb.rpc('rep_party_balance_before', { p_company: S.company.id, p_fy: S.fy.id, p_party: p.id, p_date: from }),
      sb.rpc('rep_party_ledger', { p_company: S.company.id, p_fy: S.fy.id, p_party: p.id, p_from: from, p_to: to })]);
    if (ob.error || mv.error) return void (out.innerHTML = `<div class="notice">${esc(arError(ob.error || mv.error))}</div>`);
    let b = num(ob.data), td = 0, tc = 0;
    const fmtB = (x) => `${fmtNum(Math.abs(x))} ${Math.abs(x) < 0.0005 ? '' : x > 0 ? 'مدين' : 'دائن'}`;
    const body = mv.data.map(m => { b += num(m.debit) - num(m.credit); td += num(m.debit); tc += num(m.credit);
      return `<tr><td>${fmtDate(m.entry_date)}</td><td>${ENTRY_TYPES[m.entry_type].label} ${esc(docNo(m))}</td><td>${esc(m.line_description || m.description || '')}</td><td>${esc(m.reference || '')}</td>
        <td class="n">${num(m.debit) ? fmtNum(m.debit) : ''}</td><td class="n">${num(m.credit) ? fmtNum(m.credit) : ''}</td><td class="n">${fmtB(b)}</td></tr>`; }).join('');
    const table = `<table class="t pt rep"><thead><tr><th>التاريخ</th><th>السند</th><th>البيان</th><th>المرجع</th><th>مدين</th><th>دائن</th><th>الرصيد</th></tr></thead>
      <tbody><tr class="grp"><td>${fmtDate(from)}</td><td colspan="5">رصيد أول المدة</td><td class="n">${fmtB(num(ob.data))}</td></tr>
      ${body || '<tr><td colspan="7" class="empty">ما في حركات مرحّلة بهالفترة</td></tr>'}</tbody>
      <tfoot><tr class="tot"><td colspan="4">المجموع / الرصيد النهائي</td><td class="n">${fmtNum(td)}</td><td class="n">${fmtNum(tc)}</td><td class="n">${fmtB(b)}</td></tr></tfoot></table>`;
    out.innerHTML = `<div class="card" style="margin:12px 0"><b>${esc(p.code)} — ${esc(p.name)}</b> <span class="badge brand">${P.label}</span>
        <span class="muted">${esc([p.mobile || p.phone, p.city, p.tax_no ? 'ر.ض: ' + p.tax_no : ''].filter(Boolean).join(' · '))}</span>
        <div style="margin-top:6px">الرصيد النهائي: <b dir="ltr">${fmtB(b)}</b> ${p.credit_limit > 0 ? `<span class="muted"> · سقف الائتمان ${fmtNum(p.credit_limit)}</span>` : ''}</div></div>
      <div class="card table-wrap">${table}</div>`;
    last = { p, from, to, table, mv: mv.data, ob: num(ob.data) };
  };
  v.querySelector('#f-run').onclick = run;
  if (!can('reports', 'print')) v.querySelector('#f-print').style.display = 'none';
  v.querySelector('#f-print').onclick = () => last && printDoc(`كشف حساب ${PARTY[last.p.party_type].label}: ${last.p.code} — ${last.p.name}`, last.table, { subtitle: `من ${fmtDate(last.from)} إلى ${fmtDate(last.to)}` });
  v.querySelector('#f-csv').onclick = () => { if (!last) return; let b = last.ob;
    downloadCSV(`كشف حساب ${last.p.name}.csv`, [['التاريخ', 'السند', 'البيان', 'المرجع', 'مدين', 'دائن', 'الرصيد'], [last.from, 'رصيد أول المدة', '', '', '', '', b.toFixed(3)]]
      .concat(last.mv.map(m => { b += num(m.debit) - num(m.credit); return [m.entry_date, `${ENTRY_TYPES[m.entry_type].label} ${docNo(m)}`, m.line_description || m.description || '', m.reference || '', num(m.debit).toFixed(3), num(m.credit).toFixed(3), b.toFixed(3)]; }))); };
  v.querySelector('#f-wa').onclick = () => {
    if (!last) return toast('اعرض الكشف أول', 'err');
    const p = last.p; let b = last.ob, td = 0, tc = 0;
    last.mv.forEach(m => { b += num(m.debit) - num(m.credit); td += num(m.debit); tc += num(m.credit); });
    const side = (x) => Math.abs(x) < 0.0005 ? '' : x > 0 ? (p.party_type === 'customer' ? ' مدين (مستحق عليكم)' : ' مدين') : (p.party_type === 'supplier' ? ' دائن (مستحق لكم)' : ' دائن');
    const recent = last.mv.slice(-10).map(m => `▫️ ${fmtDate(m.entry_date)} — ${ENTRY_TYPES[m.entry_type].label} ${docNo(m)}: ${num(m.debit) ? fmtNum(m.debit) + ' مدين' : fmtNum(m.credit) + ' دائن'}`).join('\n');
    const txt = `*${S.company.name}*\nكشف حساب: ${p.name}\nمن ${fmtDate(last.from)} إلى ${fmtDate(last.to)}\n\nرصيد أول المدة: ${fmtNum(Math.abs(last.ob))}\nمجموع المدين: ${fmtNum(td)}\nمجموع الدائن: ${fmtNum(tc)}\n*الرصيد النهائي: ${fmtNum(Math.abs(b))} دينار${side(b)}*`
      + (recent ? `\n\nآخر الحركات:\n${recent}` : '') + `\n\nللاستفسار يرجى التواصل معنا. شكراً لكم.`;
    let ph = String(p.mobile || p.phone || '').replace(/\D/g, '');
    if (ph.startsWith('00')) ph = ph.slice(2); else if (ph.startsWith('0')) ph = '962' + ph.slice(1); else if (ph.length === 9 && ph.startsWith('7')) ph = '962' + ph;
    window.open(`https://wa.me/${ph}?text=${encodeURIComponent(txt)}`, '_blank');
    if (!ph) toast('ما في رقم موبايل للطرف — اختار الرقم من الواتساب', '');
  };
  v.querySelector('#f-mail').onclick = () => {
    if (!last) return toast('اعرض الكشف أول', 'err');
    const p = last.p; let b = last.ob, td = 0, tc = 0;
    const fB = (x) => `${fmtNum(Math.abs(x))} ${Math.abs(x) < 0.0005 ? '' : x > 0 ? 'مدين' : 'دائن'}`;
    const rows = [[fmtDate(last.from), 'رصيد أول المدة', '', '', '', fB(b)]].concat(last.mv.map(m => { b += num(m.debit) - num(m.credit); td += num(m.debit); tc += num(m.credit);
      return [fmtDate(m.entry_date), esc(`${ENTRY_TYPES[m.entry_type].label} ${docNo(m)}`), esc(m.line_description || m.description || ''), num(m.debit) ? fmtNum(m.debit) : '', num(m.credit) ? fmtNum(m.credit) : '', fB(b)]; }));
    const foot = `<tfoot><tr><td colspan="3" style="border:1px solid #ddd;padding:6px"><b>المجموع / الرصيد النهائي</b></td><td style="border:1px solid #ddd;padding:6px"><b>${fmtNum(td)}</b></td><td style="border:1px solid #ddd;padding:6px"><b>${fmtNum(tc)}</b></td><td style="border:1px solid #ddd;padding:6px"><b>${fB(b)}</b></td></tr></tfoot>`;
    const html = emailWrap(`كشف حساب: ${p.name}`, `<p>من ${fmtDate(last.from)} إلى ${fmtDate(last.to)}</p>` + emailTable(['التاريخ', 'السند', 'البيان', 'مدين', 'دائن', 'الرصيد'], rows, foot)
      + `<p style="margin-top:12px"><b>الرصيد النهائي: ${fB(b)} دينار</b></p><p>للاستفسار يرجى التواصل معنا. شكراً لكم.</p>`);
    const text = `كشف حساب: ${p.name}\nمن ${fmtDate(last.from)} إلى ${fmtDate(last.to)}\nمجموع المدين: ${fmtNum(td)}\nمجموع الدائن: ${fmtNum(tc)}\nالرصيد النهائي: ${fB(b)} دينار\n\n${S.company.name}`;
    emailDialog({ party: p, subject: `كشف حساب ${p.name} — ${S.company.name}`, html, text, kind: 'statement' });
  };
  if (pre) run();
}

// ---------------------------------------------------------------------
//  أعمار الذمم (توزيع الرصيد على فترات حسب الأقدمية، بطريقة الوارد أولاً)
// ---------------------------------------------------------------------
async function viewAging(v) {
  if (!S.company || !S.fy) return void (v.innerHTML = `<div class="notice info">اختار شركة وسنة مالية من فوق أول.</div>`);
  const q = new URLSearchParams(location.hash.split('?')[1] || '');
  const type0 = q.get('type') === 'supplier' ? 'supplier' : 'customer', mode0 = q.get('mode') === 'detail' ? 'detail' : 'summary';
  const asOf0 = today() >= S.fy.start_date && today() <= S.fy.end_date ? today() : S.fy.end_date;
  const [parties, , catsC, catsS] = await Promise.all([loadParties(), loadLookups(), loadPartyCats('customer'), loadPartyCats('supplier')]);
  const cats = { customer: catsC, supplier: catsS };
  v.innerHTML = `<div class="page-head"><h2>⏳ أعمار الذمم</h2><div class="spacer"></div>
      <div class="tabs" style="margin:0">${[['summary', 'تجميعي'], ['detail', 'تفصيلي']].map(([k, l]) => `<a class="tab ${mode0 === k ? 'active' : ''}" href="#/rep-aging?type=${type0}&mode=${k}">${l}</a>`).join('')}</div></div>
    <div class="card no-print filters">
      <div class="field"><label>النوع</label><select id="f-type"><option value="customer" ${type0 === 'customer' ? 'selected' : ''}>العملاء (ذمم مدينة)</option><option value="supplier" ${type0 === 'supplier' ? 'selected' : ''}>الموردين (ذمم دائنة)</option></select></div>
      <div class="field"><label>الطرف</label><input id="f-p" list="ag-plist" placeholder="الكل"><datalist id="ag-plist"></datalist></div>
      <div class="field"><label>الفئة</label><select id="f-cat"></select></div>
      <div class="field" id="rep-box"><label>المندوب</label><select id="f-rep"><option value="">الكل</option>${repOptions('')}</select></div>
      <div class="field"><label>المدينة</label><input id="f-city" list="ag-cities" placeholder="الكل"><datalist id="ag-cities">${[...new Set(parties.map(p => p.city).filter(Boolean))].map(c => `<option value="${esc(c)}">`).join('')}</datalist></div>
      <div class="field"><label>طول الفترة (يوم)</label><select id="f-step">${[15, 30, 45, 60, 90].map(n => `<option value="${n}" ${n === 30 ? 'selected' : ''}>${n}</option>`).join('')}</select></div>
      <div class="field"><label>العمر اعتباراً من تاريخ</label><input type="date" id="f-to" value="${asOf0}"></div>
      <div class="field"><label>العمر حسب</label><select id="f-basis"><option value="doc">تاريخ المستند</option><option value="due">تاريخ الاستحقاق (إن وجد)</option></select></div>
      <div class="field" style="justify-content:flex-end"><label class="check" style="margin:0 0 10px"><input type="checkbox" id="f-zero" checked> إخفاء الأرصدة الصفرية</label></div>
      <div class="field" style="justify-content:flex-end"><button class="btn primary" id="f-run">عرض التقرير</button></div>
      <div class="field" style="justify-content:flex-end;flex-direction:row;gap:6px"><button class="btn" id="f-print">🖨️ طباعة</button><button class="btn" id="f-csv">⬇️ Excel</button></div>
    </div><div id="out"></div>`;
  const fillType = () => { const t = v.querySelector('#f-type').value;
    v.querySelector('#ag-plist').innerHTML = parties.filter(p => p.party_type === t).map(p => `<option value="${esc(p.code)} — ${esc(p.name)}">`).join('');
    v.querySelector('#f-cat').innerHTML = '<option value="">الكل</option>' + cats[t].map(c => `<option value="${c.id}">${esc(c.name)}</option>`).join('');
    v.querySelector('#rep-box').style.display = t === 'customer' && hasReps() ? '' : 'none'; };
  fillType(); v.querySelector('#f-type').addEventListener('change', () => { fillType(); v.querySelector('#f-p').value = ''; });
  let last = null;
  const run = async () => {
    const type = v.querySelector('#f-type').value, to = v.querySelector('#f-to').value, P = PARTY[type], out = v.querySelector('#out');
    const mode = (new URLSearchParams(location.hash.split('?')[1] || '')).get('mode') === 'detail' ? 'detail' : 'summary';
    const step = +v.querySelector('#f-step').value, basis = v.querySelector('#f-basis').value;
    const B = [0, 1, 2, 3].map(i => [`${i * step + (i ? 1 : 0)}-${(i + 1) * step}`, i * step + (i ? 1 : 0), (i + 1) * step]).concat([[`+${4 * step}`, 4 * step + 1, 1e9]]);
    const mv = await sb.rpc('rep_party_aging_docs', { p_company: S.company.id, p_fy: S.fy.id, p_type: type, p_to: to });
    if (mv.error) return void (out.innerHTML = `<div class="notice">${esc(arError(mv.error))}</div>`);
    const by = {}; mv.data.forEach(r => (by[r.party_id] ||= []).push(r));
    const asOf = new Date(to);
    const pq = v.querySelector('#f-p').value.split('—')[0].trim(), cat = v.querySelector('#f-cat').value, rep = v.querySelector('#f-rep').value, city = v.querySelector('#f-city').value.trim();
    const rows = parties.filter(p => p.party_type === type && (!pq || p.code === pq) && (!cat || p.category_id === cat) && (!rep || p.sales_rep_id === rep) && (!city || p.city === city)).map(p => {
      const ms = by[p.id] || [];
      // الحركة اللي بتزيد الذمة (مدين للعميل، دائن للمورد) وبتسدّها الحركة الثانية (الأقدم أول)
      const inc = ms.map(m => ({ m, a: P.side > 0 ? num(m.debit) - num(m.credit) : num(m.credit) - num(m.debit) })).filter(x => x.a > 0);
      let paid = ms.reduce((s, m) => s + Math.max(0, P.side > 0 ? num(m.credit) - num(m.debit) : num(m.debit) - num(m.credit)), 0);
      const buckets = [0, 0, 0, 0, 0], open = [];
      for (const x of inc) { const use = Math.min(paid, x.a); paid -= use; const left = x.a - use; if (left <= 0.0005) continue;
        const ref = basis === 'due' && x.m.due_date ? x.m.due_date : x.m.entry_date;
        const age = Math.max(0, Math.floor((asOf - new Date(ref)) / 86400000)), bi = B.findIndex(b => age >= b[1] && age <= b[2]);
        buckets[bi] += left; open.push({ ...x.m, left, age, bi }); }
      const total = buckets.reduce((s, x) => s + x, 0) - paid;   // paid المتبقي = رصيد معاكس (دفعة مقدمة)
      return { p, buckets, total, advance: paid, open };
    }).filter(r => !v.querySelector('#f-zero').checked || Math.abs(r.total) > 0.0005);
    const tot = [0, 0, 0, 0, 0], T = rows.reduce((s, r) => { r.buckets.forEach((x, i) => tot[i] += x); return s + r.total; }, 0), adv = rows.reduce((s, r) => s + r.advance, 0);
    const pct = (x) => T > 0.0005 ? ` <small class="muted">${Math.round(x / T * 100)}%</small>` : '';
    let table;
    if (mode === 'summary') {
      table = `<table class="t pt rep"><thead><tr><th>الرقم</th><th>${P.label}</th>${B.map(b => `<th>${b[0]} يوم</th>`).join('')}<th>دفعات مقدمة</th><th>الرصيد</th></tr></thead>
      <tbody>${rows.map(r => `<tr><td>${esc(r.p.code)}</td><td>${esc(r.p.name)}</td>${r.buckets.map(x => `<td class="n">${x > 0.0005 ? fmtNum(x) : ''}</td>`).join('')}
        <td class="n">${r.advance > 0.0005 ? fmtNum(r.advance) : ''}</td><td class="n"><b>${fmtNum(r.total)}</b></td></tr>`).join('') || `<tr><td colspan="9" class="empty">ما في أرصدة</td></tr>`}</tbody>
      <tfoot><tr class="tot"><td colspan="2">المجموع (${rows.length})</td>${tot.map(x => `<td class="n">${fmtNum(x)}${pct(x)}</td>`).join('')}<td class="n">${fmtNum(adv)}</td><td class="n">${fmtNum(T)}</td></tr></tfoot></table>`;
    } else {
      const ET = { sale: 'فاتورة', invoice: 'فاتورة', opening: 'رصيد افتتاحي', journal: 'قيد', receipt: 'سند قبض', payment: 'سند صرف', cheque: 'شيك' };
      table = `<table class="t pt rep"><thead><tr><th>التاريخ</th><th>المستند</th><th>البيان</th><th>الاستحقاق</th><th>العمر</th>${B.map(b => `<th>${b[0]}</th>`).join('')}</tr></thead><tbody>
      ${rows.map(r => `<tr class="grp"><td colspan="5"><b>${esc(r.p.code)} — ${esc(r.p.name)}</b>${r.p.phone || r.p.mobile ? ` <small class="muted">${esc(r.p.mobile || r.p.phone)}</small>` : ''}</td>${B.map(() => '<td></td>').join('')}</tr>
        ${r.open.map(o => `<tr><td>${fmtDate(o.entry_date)}</td><td>${esc(ET[o.entry_type] || ENTRY_TYPES?.[o.entry_type]?.label || '')} ${esc(o.doc_no || '')}</td><td>${esc(o.description || '')}</td><td>${fmtDate(o.due_date)}</td><td class="n">${o.age}</td>
          ${B.map((_, i) => `<td class="n">${i === o.bi ? fmtNum(o.left) : ''}</td>`).join('')}</tr>`).join('')}
        ${r.advance > 0.0005 ? `<tr><td colspan="5" class="muted">دفعات مقدمة / رصيد معاكس</td><td class="n" colspan="${B.length}">-${fmtNum(r.advance)}</td></tr>` : ''}
        <tr class="tot"><td colspan="5">مجموع ${esc(r.p.name)}: ${fmtNum(r.total)}</td>${r.buckets.map(x => `<td class="n">${x > 0.0005 ? fmtNum(x) : ''}</td>`).join('')}</tr>`).join('') || `<tr><td colspan="10" class="empty">ما في أرصدة</td></tr>`}</tbody>
      <tfoot><tr class="tot"><td colspan="5">المجموع العام: ${fmtNum(T)}${adv > 0.0005 ? ` (بعد دفعات مقدمة ${fmtNum(adv)})` : ''}</td>${tot.map(x => `<td class="n">${fmtNum(x)}${pct(x)}</td>`).join('')}</tr></tfoot></table>`;
    }
    out.innerHTML = `<div class="card table-wrap" style="margin-top:12px">${table}</div>
      <p class="muted" style="font-size:13px">الأعمار محسوبة من ${basis === 'due' ? 'تاريخ الاستحقاق (أو تاريخ المستند إذا ما إله)' : 'تاريخ كل مستند'} لغاية ${fmtDate(to)}، والدفعات بتسدّ الأقدم أول. حركات السنة المالية الحالية (مع الرصيد الافتتاحي).</p>`;
    last = { type, to, table, rows, B, mode };
  };
  v.querySelector('#f-run').onclick = run;
  if (!can('reports', 'print')) v.querySelector('#f-print').style.display = 'none';
  v.querySelector('#f-print').onclick = () => last && printDoc(`أعمار ذمم ${PARTY[last.type].plural} — ${last.mode === 'detail' ? 'تفصيلي' : 'تجميعي'}`, last.table, { subtitle: `كما في ${fmtDate(last.to)}`, landscape: true });
  v.querySelector('#f-csv').onclick = () => last && downloadCSV(`أعمار الذمم - ${PARTY[last.type].plural}.csv`, last.mode === 'detail'
    ? [['الرقم', 'الاسم', 'التاريخ', 'المستند', 'البيان', 'الاستحقاق', 'العمر', 'المبلغ', 'الفترة']].concat(last.rows.flatMap(r => r.open.map(o => [r.p.code, r.p.name, o.entry_date, o.doc_no || '', o.description || '', o.due_date || '', o.age, o.left.toFixed(3), last.B[o.bi][0]])))
    : [['الرقم', 'الاسم', ...last.B.map(b => b[0]), 'دفعات مقدمة', 'الرصيد']].concat(last.rows.map(r => [r.p.code, r.p.name, ...r.buckets.map(x => x.toFixed(3)), r.advance.toFixed(3), r.total.toFixed(3)])));
  run();
}

// ---------------------------------------------------------------------
//  فئات العملاء / فئات الموردين
// ---------------------------------------------------------------------
async function loadPartyCats(type) {
  const { data, error } = await sb.from('party_categories').select('*').eq('company_id', S.company.id).eq('party_type', type).order('code');
  if (error) throw error; return data || [];
}
async function viewPartyCategories(v, ctx) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const type = ['supplier', 'expense'].includes(new URLSearchParams(location.hash.split('?')[1] || '').get('type')) ? new URLSearchParams(location.hash.split('?')[1] || '').get('type') : 'customer';
  const P = PARTY[type];
  const [cats, parties] = await Promise.all([loadPartyCats(type), loadParties(true), loadNumbering(true)]);
  const used = (id) => parties.filter(p => p.category_id === id).length;
  const canAdd = can(P.screen, 'add'), canEd = can(P.screen, 'edit'), canDel = can(P.screen, 'delete');
  v.innerHTML = `<div class="page-head"><h2>🗂️ فئات ${P.plural}</h2><span class="badge brand">${cats.length}</span><div class="spacer"></div>
      <a class="btn sm" href="#/${P.route}">${P.icon} ${P.plural}</a>${canAdd ? `<button class="btn primary" id="c-add">➕ فئة جديدة</button>` : ''}</div>
    <p class="muted">الفئة بتجمّع ${P.plural} (مثلاً: ${type === 'customer' ? 'جملة، مفرق، شركات' : 'محلي، استيراد، خدمات'}). بتختار فئة كل ${P.label} من بطاقته، وبتفلتر فيها القائمة.${type === 'customer' ? ' علامات «⛔» على الفئة بتنطبق على كل عملائها.' : ''}</p>
    <div class="card table-wrap"><table class="t"><thead><tr><th style="width:120px">الرمز</th><th>اسم الفئة</th><th>عدد ${P.plural}</th>${type === 'customer' ? STOPS.map(([, l]) => `<th style="font-size:12px">⛔ ${l}</th>`).join('') : ''}<th>فعّالة</th><th></th></tr></thead><tbody id="crows"></tbody></table></div>`;
  const draw = () => {
    v.querySelector('#crows').innerHTML = cats.map(c => `<tr data-id="${c.id}"><td><input data-f="code" value="${esc(c.code)}" dir="ltr" ${canEd ? '' : 'disabled'}></td>
      <td><input data-f="name" value="${esc(c.name)}" ${canEd ? '' : 'disabled'}></td><td>${used(c.id)}</td>
      ${type === 'customer' ? STOPS.map(([k]) => `<td><input type="checkbox" data-f="${k}" ${c[k] ? 'checked' : ''} ${canEd ? '' : 'disabled'}></td>`).join('') : ''}
      <td><input type="checkbox" data-f="is_active" ${c.is_active ? 'checked' : ''} ${canEd ? '' : 'disabled'}></td>
      <td class="actions">${canEd ? '<button class="btn sm" data-save type="button">💾 حفظ</button>' : ''} ${canDel && !used(c.id) ? '<button class="btn sm danger" data-del type="button">حذف</button>' : ''}</td></tr>`).join('')
      || `<tr><td colspan="${type === 'customer' ? 8 : 5}" class="empty">ما في فئات لسا</td></tr>`;
  };
  draw();
  v.querySelector('#c-add')?.addEventListener('click', async () => {
    const code = masterCode(type === 'customer' ? 'm_customer_category' : type === 'supplier' ? 'm_supplier_category' : 'm_expense_category', cats.map(c => c.code)) ?? String(Math.max(0, ...cats.map(c => parseInt(c.code, 10) || 0)) + 1);
    const { data, error } = await sb.from('party_categories').insert({ company_id: S.company.id, party_type: type, code, name: 'فئة جديدة' }).select().single();
    if (error) return toast(arError(error), 'err');
    cats.push(data); await log('إضافة', 'party_categories', data.id, { type }); draw(); v.querySelector(`[data-id="${data.id}"] [data-f=name]`)?.select();
  });
  v.querySelector('#crows').addEventListener('click', async (e) => {
    const tr = e.target.closest('[data-id]'); if (!tr) return; const c = cats.find(x => x.id === tr.dataset.id);
    if (e.target.closest('[data-save]')) {
      const d = { code: tr.querySelector('[data-f=code]').value.trim(), name: tr.querySelector('[data-f=name]').value.trim(), is_active: tr.querySelector('[data-f=is_active]').checked };
      if (type === 'customer') STOPS.forEach(([k]) => d[k] = tr.querySelector(`[data-f=${k}]`).checked);
      if (!d.code || !d.name) return toast('الرمز والاسم مطلوبين', 'err');
      const { error } = await sb.from('party_categories').update(d).eq('id', c.id); if (error) return toast(arError(error), 'err');
      Object.assign(c, d); await log('تعديل', 'party_categories', c.id, { name: d.name }); toast('تم الحفظ', 'ok');
    }
    if (e.target.closest('[data-del]')) {
      if (!(await confirmBox(`حذف الفئة «${c.name}»؟`))) return;
      const { error } = await sb.from('party_categories').delete().eq('id', c.id); if (error) return toast(arError(error), 'err');
      cats.splice(cats.indexOf(c), 1); await log('حذف', 'party_categories', c.id, { name: c.name }); draw();
    }
  });
}

export const PARTY_ROUTES = {
  'customers': partyList('customer'), 'suppliers': partyList('supplier'), 'expenses': partyList('expense'), 'party-categories': viewPartyCategories,
  'rep-party': viewPartyLedger, 'rep-aging': viewAging,
};
