// =====================================================================
//  السمو ERP — الأستاذ العام والأستاذ المساعد: الحسابات، العملاء، الموردين، المصاريف، الموظفين، الأصول
//  بتحدد فترة، وبيطلعلك لكل حساب/عميل/مورد: رصيد أول المدة، مدين ودائن الفترة، والرصيد آخر المدة.
//  كبسة على أي سطر بتفتح كشف حسابه تحته (نفس مبدأ كشف الحساب).
// =====================================================================
import { S, sb, esc, toast, arError, can, fmtNum, fmtDate, num } from './core.js';
import { loadAccounts } from './finance.js';
import { ENTRY_TYPES } from './finance.js';
import { loadParties, PARTY } from './parties.js';
import { docNo } from './numbering.js';
import { downloadCSV } from './finance.js';

const bal = (x) => Math.abs(x) < 0.0005 ? '<span class="muted">—</span>' : `${fmtNum(Math.abs(x))} <small class="${x > 0 ? 'dr' : 'cr'}">${x > 0 ? 'مدين' : 'دائن'}</small>`;
const balTxt = (x) => Math.abs(x) < 0.0005 ? '' : `${fmtNum(Math.abs(x))} ${x > 0 ? 'مدين' : 'دائن'}`;
const amt = (x) => Math.abs(x) < 0.0005 ? '' : fmtNum(x);

function periodBar(id = 'pc') {
  return `<div class="card no-print" style="display:flex;gap:10px;flex-wrap:wrap;align-items:end" id="${id}">
    <div class="field"><label>الفترة</label><select data-f="per"><option value="fy">السنة المالية كاملة</option><option value="month">الشهر الحالي</option><option value="q">آخر 3 شهور</option><option value="custom">فترة محددة</option></select></div>
    <div class="field"><label>من</label><input type="date" data-f="from" value="${S.fy.start_date}"></div>
    <div class="field"><label>إلى</label><input type="date" data-f="to" value="${S.fy.end_date}"></div>
    <span data-slot></span>
    <div class="field" style="flex:1;min-width:150px"><label>بحث</label><input data-f="q" placeholder="الرمز أو الاسم…"></div>
    <label class="check" style="margin:0 0 10px"><input type="checkbox" data-f="moving" checked> بس اللي إلهم رصيد أو حركة</label>
    <button class="btn primary" data-f="go" type="button">🔎 عرض</button>
    <button class="btn sm" data-f="csv" type="button">⬇️ Excel</button><button class="btn sm" data-f="prn" type="button">🖨️ طباعة</button></div>`;
}
function wirePeriod(box, onGo) {
  const f = (n) => box.querySelector(`[data-f=${n}]`);
  const clamp = (d) => d < S.fy.start_date ? S.fy.start_date : d > S.fy.end_date ? S.fy.end_date : d;
  f('per').onchange = () => {
    const p = f('per').value, t = new Date(); const iso = (d) => d.toISOString().slice(0, 10);
    if (p === 'fy') { f('from').value = S.fy.start_date; f('to').value = S.fy.end_date; }
    if (p === 'month') { f('from').value = clamp(iso(new Date(t.getFullYear(), t.getMonth(), 1))); f('to').value = clamp(iso(t)); }
    if (p === 'q') { f('from').value = clamp(iso(new Date(t.getFullYear(), t.getMonth() - 2, 1))); f('to').value = clamp(iso(t)); }
    if (p !== 'custom') onGo();
  };
  ['from', 'to'].forEach(n => f(n).onchange = () => { f('per').value = 'custom'; });
  f('go').onclick = onGo; f('q').onkeydown = (e) => { if (e.key === 'Enter') onGo(); };
  f('prn').onclick = () => window.print();
  return f;
}
// كشف حساب مختصر تحت السطر
function statementHTML(open, rows, from, to) {
  let b = open, td = 0, tc = 0;
  const body = rows.map(m => { b += num(m.debit) - num(m.credit); td += num(m.debit); tc += num(m.credit);
    return `<tr><td>${fmtDate(m.entry_date)}</td><td>${esc((ENTRY_TYPES[m.entry_type]?.label || '') + ' ' + docNo(m))}</td>
      <td>${esc(m.line_description || m.description || '')}${m.draft ? ' <span class="badge warn">غير مرحّل</span>' : ''}</td><td>${esc(m.reference || '')}</td>
      <td class="n">${amt(num(m.debit))}</td><td class="n">${amt(num(m.credit))}</td><td class="n">${bal(b)}</td></tr>`; }).join('');
  return `<table class="t rep stmt"><thead><tr><th>التاريخ</th><th>السند</th><th>البيان</th><th>المرجع</th><th>مدين</th><th>دائن</th><th>الرصيد</th></tr></thead>
    <tbody><tr class="grp"><td>${fmtDate(from)}</td><td colspan="5">رصيد أول المدة</td><td class="n">${bal(open)}</td></tr>
    ${body || '<tr><td colspan="7" class="empty">ما في حركات مرحّلة بهالفترة</td></tr>'}</tbody>
    <tfoot><tr class="tot"><td colspan="4">المجموع / رصيد ${fmtDate(to)}</td><td class="n">${fmtNum(td)}</td><td class="n">${fmtNum(tc)}</td><td class="n">${bal(b)}</td></tr></tfoot></table>`;
}
// ملخص الحساب حسب نوع السند (مثل «ملخص» بستاليون) + الحركات
function summaryHTML(open, rows) {
  const g = {};
  rows.forEach(m => { const k = m.entry_type || 'journal'; (g[k] ||= { d: 0, c: 0, n: 0 }); g[k].d += num(m.debit); g[k].c += num(m.credit); g[k].n++; });
  const td = rows.reduce((s, m) => s + num(m.debit), 0), tc = rows.reduce((s, m) => s + num(m.credit), 0);
  const ob = open > 0 ? [open, 0] : [0, -open];
  return `<table class="t rep stmt" style="max-width:720px"><thead><tr><th>التفاصيل</th><th>عدد</th><th>مدين</th><th>دائن</th><th>الرصيد</th></tr></thead><tbody>
    <tr class="grp"><td>رصيد افتتاحي (أول المدة)</td><td></td><td class="n">${amt(ob[0])}</td><td class="n">${amt(ob[1])}</td><td class="n">${bal(open)}</td></tr>
    ${Object.entries(g).map(([k, x]) => `<tr><td>${esc(ENTRY_TYPES[k]?.label || k)}</td><td class="n">${x.n}</td><td class="n">${amt(x.d)}</td><td class="n">${amt(x.c)}</td><td class="n">${bal(x.d - x.c)}</td></tr>`).join('')
      || '<tr><td colspan="5" class="empty">ما في حركات مرحّلة بهالفترة</td></tr>'}</tbody>
    <tfoot><tr class="tot"><td>الرصيد</td><td></td><td class="n">${fmtNum(ob[0] + td)}</td><td class="n">${fmtNum(ob[1] + tc)}</td><td class="n">${bal(open + td - tc)}</td></tr></tfoot></table>`;
}
// «احتساب»: اختيار أنواع السندات اللي بتدخل بالملخص والحركات، ومع أو بدون الرصيد المدور
const STMT = new WeakMap();
// السندات غير المرحّلة لحساب أو طرف (للخيار «غير مرحّل / الجميع»)
async function draftRows(col, id, to) {
  const { data, error } = await sb.from('journal_lines').select('debit,credit,description,journal_entries!inner(company_id,fiscal_year_id,status,entry_date,entry_type,entry_no,doc_code,description,reference)')
    .eq(col, id).eq('journal_entries.company_id', S.company.id).eq('journal_entries.fiscal_year_id', S.fy.id).eq('journal_entries.status', 'draft').lte('journal_entries.entry_date', to).limit(5000);
  if (error) throw error;
  return (data || []).map(l => ({ ...l.journal_entries, line_description: l.description, debit: l.debit, credit: l.credit, draft: true })).sort((a, b) => a.entry_date.localeCompare(b.entry_date));
}
function tabbed(open, rows, from, to, drafts = null) {
  const kinds = [...new Set(rows.map(m => m.entry_type || 'journal'))];
  const html = `<div class="stmt-tabs"><button type="button" class="btn sm primary" data-v="sum">📋 ملخص</button><button type="button" class="btn sm" data-v="mov">📄 الحركات</button>
      ${drafts ? '<select data-stat style="width:auto;padding:4px 8px"><option value="posted">مرحّل</option><option value="draft">غير مرحّل</option><option value="all">الجميع</option></select>' : ''}
      <span class="stmt-calc"><b>احتساب:</b> <label><input type="checkbox" data-open checked> الرصيد المدور</label>
      ${kinds.map(k => `<label><input type="checkbox" data-k="${esc(k)}" checked> ${esc(ENTRY_TYPES[k]?.label || k)}</label>`).join('')}</span></div>
    <div data-p="sum">${summaryHTML(open, rows)}</div><div data-p="mov" hidden>${statementHTML(open, rows, from, to)}</div>`;
  tabbed.last = { open, rows, from, to, drafts, base: { open, rows } };
  return html;
}
function wireTabs(box) {
  const st = tabbed.last; if (!st) return; STMT.set(box, st);
  const t = box.querySelector('.stmt-tabs'); if (!t) return;
  t.onclick = (e) => { e.stopPropagation(); const b = e.target.closest('[data-v]'); if (!b) return;
    t.querySelectorAll('[data-v]').forEach(x => x.classList.toggle('primary', x === b));
    box.querySelectorAll('[data-p]').forEach(p => p.hidden = p.dataset.p !== b.dataset.v); };
  t.onchange = async (e) => {
    if (e.target.matches('[data-stat]')) {
      const mode = e.target.value; let dr = [];
      if (mode !== 'posted') { try { dr = await st.drafts(); } catch (err) { return toast(arError(err), 'err'); } }
      const dOpen = dr.filter(m => m.entry_date < st.from).reduce((s, m) => s + num(m.debit) - num(m.credit), 0);
      const dIn = dr.filter(m => m.entry_date >= st.from);
      st.open = mode === 'posted' ? st.base.open : mode === 'draft' ? dOpen : st.base.open + dOpen;
      st.rows = mode === 'posted' ? st.base.rows : mode === 'draft' ? dIn : [...st.base.rows, ...dIn].sort((a, b) => a.entry_date.localeCompare(b.entry_date));
      const kinds = [...new Set(st.rows.map(m => m.entry_type || 'journal'))];
      t.querySelector('.stmt-calc').innerHTML = `<b>احتساب:</b> <label><input type="checkbox" data-open checked> الرصيد المدور</label>` + kinds.map(k => `<label><input type="checkbox" data-k="${esc(k)}" checked> ${esc(ENTRY_TYPES[k]?.label || k)}</label>`).join('');
    }
    const on = new Set([...t.querySelectorAll('[data-k]')].filter(x => x.checked).map(x => x.dataset.k));
    const open = t.querySelector('[data-open]').checked ? st.open : 0;
    const rows = st.rows.filter(m => on.has(m.entry_type || 'journal'));
    box.querySelector('[data-p=sum]').innerHTML = summaryHTML(open, rows);
    box.querySelector('[data-p=mov]').innerHTML = statementHTML(open, rows, st.from, st.to);
  };
}
async function toggleStatement(tr, cols, loader) {
  const nx = tr.nextElementSibling;
  if (nx?.classList.contains('stmt-row')) { nx.remove(); tr.classList.remove('open'); return; }
  tr.classList.add('open');
  const row = document.createElement('tr'); row.className = 'stmt-row';
  row.innerHTML = `<td colspan="${cols}"><div class="muted">جاري تحميل كشف الحساب…</div></td>`;
  tr.after(row);
  try { row.firstElementChild.innerHTML = await loader(); wireTabs(row); } catch (e) { row.firstElementChild.innerHTML = `<div class="notice">${esc(arError(e))}</div>`; }
}

// ---------------------------------------------------------------------
//  مركز تحكم الحسابات
// ---------------------------------------------------------------------
async function viewAccountCenter(v) {
  if (!S.company || !S.fy) return void (v.innerHTML = `<div class="notice info">اختار شركة وسنة مالية من فوق أول.</div>`);
  // «مركز تحكم المصاريف» = نفس الشاشة على حسابات المصاريف بس (account-center?cat=expenses)
  const cat = new URLSearchParams(location.hash.split('?')[1] || '').get('cat');
  const CATN = { expenses: 'مركز تحكم المصاريف', revenue: 'مركز تحكم الإيرادات', assets: 'مركز تحكم الأصول', liabilities: 'مركز تحكم الالتزامات', equity: 'مركز تحكم حقوق الملكية' };
  const accs = (await loadAccounts()).filter(a => !CATN[cat] || a.category === cat);
  const byId = Object.fromEntries(accs.map(a => [a.id, a]));
  const groups = accs.filter(a => a.is_group);
  v.innerHTML = `<div class="page-head"><h2>${CATN[cat] ? '💸 ' + CATN[cat] : '📗 الأستاذ العام للحسابات'}</h2><div class="spacer"></div><span class="muted">${esc(S.company.name)} — ${esc(S.fy.name || S.fy.code)}</span></div>
    ${periodBar()}<div class="grid cols-4" id="kp" style="margin:12px 0"></div><div class="card table-wrap"><table class="t rep" id="tb"></table></div>`;
  v.querySelector('[data-slot]').outerHTML = `<div class="field"><label>تحت حساب</label><select data-f="par"><option value="">كل الحسابات</option>${groups.map(g => `<option value="${g.id}">${esc(g.code)} — ${esc(g.name)}</option>`).join('')}</select></div>
    <div class="field"><label>المستوى</label><select data-f="lvl"><option value="0">كل المستويات</option><option value="1">1</option><option value="2">2</option><option value="3">3</option></select></div>`;
  const box = v.querySelector('#pc');
  let out = [];
  const f = wirePeriod(box, () => run());
  f('par').onchange = () => run(); f('lvl').onchange = () => run(); f('moving').onchange = () => run();
  const under = (a, pid) => { for (let x = a; x; x = byId[x.parent_id]) if (x.id === pid) return true; return false; };
  async function run() {
    const from = f('from').value, to = f('to').value;
    const { data, error } = await sb.rpc('rep_trial_balance', { p_company: S.company.id, p_fy: S.fy.id, p_from: from, p_to: to });
    if (error) return toast(arError(error), 'err');
    const t = {}; accs.forEach(a => t[a.id] = { o: 0, d: 0, c: 0 });
    (data || []).forEach(r => { for (let x = byId[r.account_id]; x; x = byId[x.parent_id]) {
      const s = t[x.id]; s.o += num(r.open_debit) - num(r.open_credit); s.d += num(r.period_debit); s.c += num(r.period_credit); } });
    const par = f('par').value, lvl = +f('lvl').value, q = f('q').value.trim().toLowerCase(), moving = f('moving').checked;
    const list = accs.filter(a => (!par || (a.id !== par && under(a, par))) && (!lvl || (a.level || 1) <= lvl)
      && (!q || [a.code, a.name].some(x => (x || '').toLowerCase().includes(q)))
      && (!moving || Math.abs(t[a.id].o) > 0.0005 || t[a.id].d || t[a.id].c));
    const leaves = list.filter(a => !a.is_group);
    const sum = (k) => leaves.reduce((s, a) => s + t[a.id][k], 0);
    const close = (a) => t[a.id].o + t[a.id].d - t[a.id].c;
    const kp = (l, x) => `<div class="card stat"><span class="k">${l}</span><span class="v" style="font-size:20px">${x}</span></div>`;
    v.querySelector('#kp').innerHTML = kp('عدد الحسابات', leaves.length) + kp('مجموع مدين الفترة', fmtNum(sum('d'))) + kp('مجموع دائن الفترة', fmtNum(sum('c')))
      + kp('الفرق', fmtNum(Math.abs(sum('d') - sum('c'))));
    out = list.map(a => [a.code, a.name, balTxt(t[a.id].o), amt(t[a.id].d), amt(t[a.id].c), balTxt(close(a))]);
    v.querySelector('#tb').innerHTML = `<thead><tr><th>الرمز</th><th>الحساب</th><th>رصيد أول المدة</th><th>مدين الفترة</th><th>دائن الفترة</th><th>الرصيد آخر المدة</th></tr></thead>
      <tbody>${list.map(a => `<tr class="${a.is_group ? 'grp' : 'clickable'}" data-acc="${a.id}"><td dir="ltr" style="text-align:right">${esc(a.code)}</td>
        <td style="padding-inline-start:${8 + ((a.level || 1) - 1) * 14}px">${a.is_group ? `<b>${esc(a.name)}</b>` : `${esc(a.name)} <span class="muted" style="font-size:11px">▾ كشف</span>`}</td>
        <td class="n">${bal(t[a.id].o)}</td><td class="n">${amt(t[a.id].d)}</td><td class="n">${amt(t[a.id].c)}</td><td class="n"><b>${bal(close(a))}</b></td></tr>`).join('')
        || '<tr><td colspan="6" class="empty">ما في حسابات بهالفلتر</td></tr>'}</tbody>`;
  }
  v.querySelector('#tb').addEventListener('click', (e) => {
    const tr = e.target.closest('tr.clickable[data-acc]'); if (!tr) return;
    const from = f('from').value, to = f('to').value, id = tr.dataset.acc;
    toggleStatement(tr, 6, async () => {
      const [ob, mv] = await Promise.all([
        sb.rpc('rep_balance_before', { p_company: S.company.id, p_fy: S.fy.id, p_account: id, p_date: from }),
        sb.rpc('rep_ledger', { p_company: S.company.id, p_fy: S.fy.id, p_account: id, p_from: from, p_to: to })]);
      if (ob.error || mv.error) throw (ob.error || mv.error);
      return `<div class="stmt-head"><b>كشف حساب: ${esc(byId[id].code)} — ${esc(byId[id].name)}</b></div>` + tabbed(num(ob.data), mv.data || [], from, to, () => draftRows('account_id', id, to));
    });
  });
  f('csv').onclick = () => downloadCSV('الأستاذ العام.csv', [['الرمز', 'الحساب', 'رصيد أول المدة', 'مدين الفترة', 'دائن الفترة', 'الرصيد آخر المدة']].concat(out));
  run();
}

// ---------------------------------------------------------------------
//  مركز تحكم العملاء / الموردين
// ---------------------------------------------------------------------
async function viewPartyCenter(v) {
  if (!S.company || !S.fy) return void (v.innerHTML = `<div class="notice info">اختار شركة وسنة مالية من فوق أول.</div>`);
  const qt = new URLSearchParams(location.hash.split('?')[1] || '').get('type'); const type = ['customer', 'expense'].includes(qt) ? qt : 'supplier';
  const P = PARTY[type];
  const [parties, catR] = await Promise.all([loadParties(true), sb.from('party_categories').select('*').eq('company_id', S.company.id).eq('party_type', type).order('code')]);
  const list0 = parties.filter(p => p.party_type === type);
  const cats = catR.data || [], catById = Object.fromEntries(cats.map(c => [c.id, c]));
  v.innerHTML = `<div class="page-head"><h2>📒 أستاذ مساعد ${P.plural}</h2><div class="spacer"></div><a class="btn sm no-print" href="#/${P.route}">${P.icon} ${P.plural}</a>${type === 'expense' ? '' : '<a class="btn sm no-print" href="#/rep-aging">⏳ أعمار الذمم</a>'}</div>
    ${periodBar()}<div class="grid cols-4" id="kp" style="margin:12px 0"></div><div class="card table-wrap"><table class="t rep" id="tb"></table></div>`;
  v.querySelector('[data-slot]').outerHTML = `<div class="field"><label>الفئة</label><select data-f="cat"><option value="">كل الفئات</option>${cats.map(c => `<option value="${c.id}">${esc(c.name)}</option>`).join('')}<option value="-">بدون فئة</option></select></div>
    <div class="field"><label>الرصيد</label><select data-f="side"><option value="">الكل</option><option value="dr">مدين بس</option><option value="cr">دائن بس</option><option value="over">فوق سقف الائتمان</option></select></div>`;
  const box = v.querySelector('#pc');
  let out = [];
  const f = wirePeriod(box, () => run());
  ['cat', 'side', 'moving'].forEach(n => f(n).onchange = () => run());
  async function run() {
    const from = f('from').value, to = f('to').value;
    const { data, error } = await sb.rpc('rep_party_movements', { p_company: S.company.id, p_fy: S.fy.id, p_type: type, p_to: to });
    if (error) return toast(arError(error), 'err');
    const t = {}; list0.forEach(p => t[p.id] = { o: 0, d: 0, c: 0, last: null });
    (data || []).forEach(r => { const s = t[r.party_id]; if (!s) return;
      if (r.entry_date < from) s.o += num(r.debit) - num(r.credit); else { s.d += num(r.debit); s.c += num(r.credit); }
      if (!s.last || r.entry_date > s.last) s.last = r.entry_date; });
    const close = (p) => t[p.id].o + t[p.id].d - t[p.id].c;
    const cat = f('cat').value, side = f('side').value, q = f('q').value.trim().toLowerCase(), moving = f('moving').checked;
    const list = list0.filter(p => (!cat || (cat === '-' ? !p.category_id : p.category_id === cat))
      && (!q || [p.code, p.name, p.phone, p.trade_name].some(x => (x || '').toLowerCase().includes(q)))
      && (!moving || Math.abs(t[p.id].o) > 0.0005 || t[p.id].d || t[p.id].c)
      && (!side || (side === 'dr' ? close(p) > 0.0005 : side === 'cr' ? close(p) < -0.0005 : (num(p.credit_limit) > 0 && Math.abs(close(p)) > num(p.credit_limit)))))
      .sort((a, b) => Math.abs(close(b)) - Math.abs(close(a)));
    const dr = list.reduce((s, p) => s + Math.max(0, close(p)), 0), cr = list.reduce((s, p) => s + Math.max(0, -close(p)), 0);
    const kp = (l, x, s = '') => `<div class="card stat"><span class="k">${l}</span><span class="v" style="font-size:20px">${x}</span>${s ? `<span class="muted" style="font-size:12px">${s}</span>` : ''}</div>`;
    v.querySelector('#kp').innerHTML = kp(`عدد ${P.plural}`, list.length) + kp('مجموع الأرصدة المدينة', fmtNum(dr)) + kp('مجموع الأرصدة الدائنة', fmtNum(cr))
      + kp('صافي الرصيد', bal(dr - cr), type === 'supplier' ? 'الدائن = مستحق للموردين' : type === 'customer' ? 'المدين = مستحق على العملاء' : 'المدين = مصاريف الفترة');
    out = list.map(p => [p.code, p.name, catById[p.category_id]?.name || '', p.phone || '', balTxt(t[p.id].o), amt(t[p.id].d), amt(t[p.id].c), balTxt(close(p)), t[p.id].last || '']);
    v.querySelector('#tb').innerHTML = `<thead><tr><th>الرمز</th><th>الاسم</th><th>الفئة</th><th>الهاتف</th><th>رصيد أول المدة</th><th>مدين الفترة</th><th>دائن الفترة</th><th>الرصيد آخر المدة</th><th>آخر حركة</th></tr></thead>
      <tbody>${list.map(p => { const over = num(p.credit_limit) > 0 && Math.abs(close(p)) > num(p.credit_limit);
        return `<tr class="clickable" data-p="${p.id}"><td dir="ltr" style="text-align:right">${esc(p.code)}</td><td>${esc(p.name)} <span class="muted" style="font-size:11px">▾ كشف</span>${over ? ' <span class="badge bad">فوق السقف</span>' : ''}</td>
        <td>${esc(catById[p.category_id]?.name || '')}</td><td dir="ltr" style="text-align:right">${esc(p.phone || '')}</td>
        <td class="n">${bal(t[p.id].o)}</td><td class="n">${amt(t[p.id].d)}</td><td class="n">${amt(t[p.id].c)}</td><td class="n"><b>${bal(close(p))}</b></td><td>${t[p.id].last ? fmtDate(t[p.id].last) : ''}</td></tr>`; }).join('')
        || `<tr><td colspan="9" class="empty">ما في ${P.plural} بهالفلتر</td></tr>`}</tbody>
      <tfoot><tr class="tot"><td colspan="4">المجموع</td><td class="n">${bal(list.reduce((s, p) => s + t[p.id].o, 0))}</td><td class="n">${fmtNum(list.reduce((s, p) => s + t[p.id].d, 0))}</td>
        <td class="n">${fmtNum(list.reduce((s, p) => s + t[p.id].c, 0))}</td><td class="n">${bal(dr - cr)}</td><td></td></tr></tfoot>`;
  }
  v.querySelector('#tb').addEventListener('click', (e) => {
    const tr = e.target.closest('tr.clickable[data-p]'); if (!tr) return;
    const from = f('from').value, to = f('to').value, p = list0.find(x => x.id === tr.dataset.p);
    toggleStatement(tr, 9, async () => {
      const [ob, mv] = await Promise.all([
        sb.rpc('rep_party_balance_before', { p_company: S.company.id, p_fy: S.fy.id, p_party: p.id, p_date: from }),
        sb.rpc('rep_party_ledger', { p_company: S.company.id, p_fy: S.fy.id, p_party: p.id, p_from: from, p_to: to })]);
      if (ob.error || mv.error) throw (ob.error || mv.error);
      return `<div class="stmt-head"><b>كشف حساب: ${esc(p.code)} — ${esc(p.name)}</b>${num(p.credit_limit) ? ` <span class="muted">سقف الائتمان: ${fmtNum(p.credit_limit)}</span>` : ''}
        <a class="btn sm" href="#/rep-party" style="margin-inline-start:auto">كشف الحساب الكامل (طباعة وواتساب)</a></div>` + tabbed(num(ob.data), mv.data || [], from, to, () => draftRows('party_id', p.id, to));
    });
  });
  f('csv').onclick = () => downloadCSV(`أستاذ مساعد ${P.plural}.csv`, [['الرمز', 'الاسم', 'الفئة', 'الهاتف', 'رصيد أول المدة', 'مدين الفترة', 'دائن الفترة', 'الرصيد آخر المدة', 'آخر حركة']].concat(out));
  run();
}

// ---------------------------------------------------------------------
//  أستاذ مساعد الموظفين — من مسيّرات الرواتب المرحّلة
// ---------------------------------------------------------------------
const ym = (d) => d.slice(0, 7);
async function viewEmployeeCenter(v) {
  if (!S.company || !S.fy) return void (v.innerHTML = `<div class="notice info">اختار شركة وسنة مالية من فوق أول.</div>`);
  const [eR, rR] = await Promise.all([sb.from('employees').select('*').eq('company_id', S.company.id).order('code'),
    sb.from('payroll_runs').select('*').eq('company_id', S.company.id).eq('status', 'posted').order('period')]);
  if (eR.error || rR.error) return toast(arError(eR.error || rR.error), 'err');
  const emps = eR.data || [], runs = rR.data || [], runById = Object.fromEntries(runs.map(r => [r.id, r]));
  let lines = [];
  if (runs.length) { const lR = await sb.from('payroll_lines').select('*').in('run_id', runs.map(r => r.id)); if (lR.error) return toast(arError(lR.error), 'err'); lines = lR.data || []; }
  const depts = [...new Set(emps.map(e => e.department).filter(Boolean))];
  v.innerHTML = `<div class="page-head"><h2>📒 أستاذ مساعد الموظفين</h2><div class="spacer"></div><a class="btn sm no-print" href="#/employees">👷 الموظفين</a><a class="btn sm no-print" href="#/payroll">💵 الرواتب</a></div>
    ${periodBar()}<div class="grid cols-4" id="kp" style="margin:12px 0"></div><div class="card table-wrap"><table class="t rep" id="tb"></table></div>
    <p class="muted" style="font-size:12px">بيحسب من مسيّرات الرواتب المرحّلة بس. «المتراكم قبل الفترة» = صافي الرواتب من أول السنة لقبل الفترة.</p>`;
  v.querySelector('[data-slot]').outerHTML = `<div class="field"><label>القسم</label><select data-f="dep"><option value="">كل الأقسام</option>${depts.map(d => `<option>${esc(d)}</option>`).join('')}</select></div>`;
  const f = wirePeriod(v.querySelector('#pc'), () => run());
  ['dep', 'moving'].forEach(n => f(n).onchange = () => run());
  let out = [];
  const K = ['gross', 'ss_employee', 'income_tax', 'advances', 'other_ded', 'net', 'ss_employer'];
  function run() {
    const from = ym(f('from').value), to = ym(f('to').value), fyFrom = ym(S.fy.start_date);
    const t = {}; emps.forEach(e => { t[e.id] = { o: 0, m: [] }; K.forEach(k => t[e.id][k] = 0); });
    lines.forEach(l => { const r = runById[l.run_id], s = t[l.employee_id]; if (!r || !s) return;
      if (r.period >= fyFrom && r.period < from) s.o += num(l.net);
      else if (r.period >= from && r.period <= to) { K.forEach(k => s[k] += num(l[k])); s.m.push({ ...l, period: r.period }); } });
    const dep = f('dep').value, q = f('q').value.trim().toLowerCase(), moving = f('moving').checked;
    const list = emps.filter(e => (!dep || e.department === dep) && (!q || [e.code, e.name, e.job_title].some(x => (x || '').toLowerCase().includes(q)))
      && (!moving || t[e.id].m.length || t[e.id].o));
    const tot = (k) => list.reduce((s, e) => s + t[e.id][k], 0);
    const kp = (l, x) => `<div class="card stat"><span class="k">${l}</span><span class="v" style="font-size:20px">${x}</span></div>`;
    v.querySelector('#kp').innerHTML = kp('عدد الموظفين', list.length) + kp('إجمالي الرواتب', fmtNum(tot('gross'))) + kp('صافي المدفوع', fmtNum(tot('net'))) + kp('ضمان المنشأة', fmtNum(tot('ss_employer')));
    out = list.map(e => [e.code, e.name, e.department || '', amt(t[e.id].o), ...K.map(k => amt(t[e.id][k])), amt(t[e.id].o + t[e.id].net)]);
    v.querySelector('#tb').innerHTML = `<thead><tr><th>الرمز</th><th>الموظف</th><th>القسم</th><th>المتراكم قبل الفترة</th><th>الإجمالي</th><th>ضمان الموظف</th><th>ضريبة الدخل</th><th>سلف</th><th>خصومات أخرى</th><th>الصافي</th><th>ضمان المنشأة</th><th>المتراكم آخر المدة</th></tr></thead>
      <tbody>${list.map(e => `<tr class="clickable" data-e="${e.id}"><td dir="ltr" style="text-align:right">${esc(e.code)}</td><td>${esc(e.name)} <span class="muted" style="font-size:11px">▾ تفاصيل</span>${e.is_active === false ? ' <span class="badge">غير فعّال</span>' : ''}</td><td>${esc(e.department || '')}</td>
        <td class="n">${amt(t[e.id].o)}</td>${K.map(k => `<td class="n">${k === 'net' ? `<b>${amt(t[e.id][k])}</b>` : amt(t[e.id][k])}</td>`).join('')}<td class="n"><b>${amt(t[e.id].o + t[e.id].net)}</b></td></tr>`).join('')
        || '<tr><td colspan="12" class="empty">ما في موظفين بهالفلتر</td></tr>'}</tbody>
      <tfoot><tr class="tot"><td colspan="3">المجموع</td><td class="n">${fmtNum(tot('o'))}</td>${K.map(k => `<td class="n">${fmtNum(tot(k))}</td>`).join('')}<td class="n">${fmtNum(tot('o') + tot('net'))}</td></tr></tfoot>`;
    v.querySelector('#tb')._t = t;
  }
  v.querySelector('#tb').addEventListener('click', (ev) => {
    const tr = ev.target.closest('tr.clickable[data-e]'); if (!tr) return;
    const s = v.querySelector('#tb')._t[tr.dataset.e];
    toggleStatement(tr, 12, async () => {
      const rows = s.m.sort((a, b) => a.period.localeCompare(b.period));
      return `<table class="t rep stmt"><thead><tr><th>الشهر</th><th>الأساسي</th><th>العلاوات</th><th>إضافي</th><th>إضافات أخرى</th><th>الإجمالي</th><th>ضمان الموظف</th><th>ضريبة</th><th>سلف</th><th>خصومات</th><th>الصافي</th></tr></thead>
        <tbody>${rows.map(l => `<tr><td>${esc(l.period)}</td>${['basic', 'allowances', 'overtime', 'other_add', 'gross', 'ss_employee', 'income_tax', 'advances', 'other_ded', 'net'].map(k => `<td class="n">${amt(num(l[k]))}</td>`).join('')}</tr>`).join('')
        || '<tr><td colspan="11" class="empty">ما في رواتب مرحّلة بهالفترة</td></tr>'}</tbody></table>`;
    });
  });
  f('csv').onclick = () => downloadCSV('أستاذ مساعد الموظفين.csv', [['الرمز', 'الموظف', 'القسم', 'المتراكم قبل الفترة', 'الإجمالي', 'ضمان الموظف', 'ضريبة الدخل', 'سلف', 'خصومات أخرى', 'الصافي', 'ضمان المنشأة', 'المتراكم آخر المدة']].concat(out));
  run();
}

// ---------------------------------------------------------------------
//  أستاذ مساعد الأصول الثابتة — الكلفة ومجمع الاستهلاك والقيمة الدفترية
// ---------------------------------------------------------------------
async function viewAssetCenter(v) {
  if (!S.company || !S.fy) return void (v.innerHTML = `<div class="notice info">اختار شركة وسنة مالية من فوق أول.</div>`);
  const [aR, rR] = await Promise.all([sb.from('fixed_assets').select('*').eq('company_id', S.company.id).order('code'),
    sb.from('depreciation_runs').select('*').eq('company_id', S.company.id).eq('status', 'posted')]);
  if (aR.error || rR.error) return toast(arError(aR.error || rR.error), 'err');
  const assets = aR.data || [], runs = rR.data || [];
  let lines = [];
  if (runs.length) { const lR = await sb.from('depreciation_lines').select('*').in('run_id', runs.map(r => r.id)); if (lR.error) return toast(arError(lR.error), 'err'); lines = lR.data || []; }
  const cats = [...new Set(assets.map(a => a.category).filter(Boolean))];
  v.innerHTML = `<div class="page-head"><h2>📒 أستاذ مساعد الأصول الثابتة</h2><div class="spacer"></div><a class="btn sm no-print" href="#/assets">🏢 الأصول والاستهلاك</a></div>
    ${periodBar()}<div class="grid cols-4" id="kp" style="margin:12px 0"></div><div class="card table-wrap"><table class="t rep" id="tb"></table></div>
    <p class="muted" style="font-size:12px">بيحسب من دورات الاستهلاك المرحّلة، ومجمع الاستهلاك السابق المسجّل على بطاقة الأصل.</p>`;
  v.querySelector('[data-slot]').outerHTML = `<div class="field"><label>الفئة</label><select data-f="cat"><option value="">كل الفئات</option>${cats.map(c => `<option>${esc(c)}</option>`).join('')}</select></div>`;
  const f = wirePeriod(v.querySelector('#pc'), () => run());
  ['cat', 'moving'].forEach(n => f(n).onchange = () => run());
  let out = [], T = {};
  function run() {
    const from = f('from').value, to = f('to').value;
    T = {}; assets.forEach(a => T[a.id] = { o: num(a.opening_accum), p: 0, m: [] });
    lines.forEach(l => { const s = T[l.asset_id]; if (!s) return;
      if (l.to_date < from) s.o += num(l.amount); else if (l.to_date <= to) { s.p += num(l.amount); s.m.push(l); } });
    const cat = f('cat').value, q = f('q').value.trim().toLowerCase(), moving = f('moving').checked;
    const list = assets.filter(a => a.purchase_date <= to && (!cat || a.category === cat)
      && (!q || [a.code, a.name, a.serial_no, a.location].some(x => (x || '').toLowerCase().includes(q)))
      && (!moving || a.status === 'active' || T[a.id].p));
    const cl = (a) => T[a.id].o + T[a.id].p, sum = (fn) => list.reduce((s, a) => s + fn(a), 0);
    const kp = (l, x) => `<div class="card stat"><span class="k">${l}</span><span class="v" style="font-size:20px">${x}</span></div>`;
    v.querySelector('#kp').innerHTML = kp('عدد الأصول', list.length) + kp('الكلفة', fmtNum(sum(a => num(a.cost)))) + kp('استهلاك الفترة', fmtNum(sum(a => T[a.id].p))) + kp('القيمة الدفترية', fmtNum(sum(a => num(a.cost) - cl(a))));
    out = list.map(a => [a.code, a.name, a.category || '', a.purchase_date, amt(num(a.cost)), amt(T[a.id].o), amt(T[a.id].p), amt(cl(a)), amt(num(a.cost) - cl(a))]);
    v.querySelector('#tb').innerHTML = `<thead><tr><th>الرمز</th><th>الأصل</th><th>الفئة</th><th>تاريخ الشراء</th><th>الكلفة</th><th>مجمع الاستهلاك أول المدة</th><th>استهلاك الفترة</th><th>مجمع الاستهلاك آخر المدة</th><th>القيمة الدفترية</th></tr></thead>
      <tbody>${list.map(a => `<tr class="clickable" data-a="${a.id}"><td dir="ltr" style="text-align:right">${esc(a.code)}</td><td>${esc(a.name)} <span class="muted" style="font-size:11px">▾ تفاصيل</span>${a.status === 'disposed' ? ' <span class="badge">مستبعد</span>' : ''}</td>
        <td>${esc(a.category || '')}</td><td>${fmtDate(a.purchase_date)}</td><td class="n">${amt(num(a.cost))}</td><td class="n">${amt(T[a.id].o)}</td><td class="n">${amt(T[a.id].p)}</td><td class="n">${amt(cl(a))}</td><td class="n"><b>${amt(num(a.cost) - cl(a))}</b></td></tr>`).join('')
        || '<tr><td colspan="9" class="empty">ما في أصول بهالفلتر</td></tr>'}</tbody>
      <tfoot><tr class="tot"><td colspan="4">المجموع</td><td class="n">${fmtNum(sum(a => num(a.cost)))}</td><td class="n">${fmtNum(sum(a => T[a.id].o))}</td><td class="n">${fmtNum(sum(a => T[a.id].p))}</td><td class="n">${fmtNum(sum(cl))}</td><td class="n">${fmtNum(sum(a => num(a.cost) - cl(a)))}</td></tr></tfoot>`;
  }
  v.querySelector('#tb').addEventListener('click', (ev) => {
    const tr = ev.target.closest('tr.clickable[data-a]'); if (!tr) return;
    const a = assets.find(x => x.id === tr.dataset.a), s = T[a.id];
    toggleStatement(tr, 9, async () => {
      let acc = s.o;
      const rows = s.m.sort((x, y) => x.to_date.localeCompare(y.to_date)).map(l => { acc += num(l.amount);
        return `<tr><td>${fmtDate(l.from_date)}</td><td>${fmtDate(l.to_date)}</td><td class="n">${l.months}</td><td class="n">${fmtNum(l.amount)}</td><td class="n">${fmtNum(acc)}</td><td class="n">${fmtNum(num(a.cost) - acc)}</td></tr>`; }).join('');
      return `<div class="stmt-head"><b>${esc(a.code)} — ${esc(a.name)}</b> <span class="muted">العمر ${a.life_months} شهر، الخردة ${fmtNum(a.salvage)}</span></div>
        <table class="t rep stmt"><thead><tr><th>من</th><th>إلى</th><th>الشهور</th><th>الاستهلاك</th><th>المجمع</th><th>القيمة الدفترية</th></tr></thead>
        <tbody><tr class="grp"><td colspan="4">أول المدة</td><td class="n">${fmtNum(s.o)}</td><td class="n">${fmtNum(num(a.cost) - s.o)}</td></tr>${rows || '<tr><td colspan="6" class="empty">ما في استهلاك مرحّل بهالفترة</td></tr>'}</tbody></table>`;
    });
  });
  f('csv').onclick = () => downloadCSV('أستاذ مساعد الأصول.csv', [['الرمز', 'الأصل', 'الفئة', 'تاريخ الشراء', 'الكلفة', 'مجمع أول المدة', 'استهلاك الفترة', 'مجمع آخر المدة', 'القيمة الدفترية']].concat(out));
  run();
}

export const CENTER_ROUTES = { 'account-center': viewAccountCenter, 'party-center': viewPartyCenter, 'employee-center': viewEmployeeCenter, 'asset-center': viewAssetCenter };
