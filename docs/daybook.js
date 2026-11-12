// =====================================================================
//  السمو ERP — اليوميات (لكل نوع سند)، تقرير مندوبي المبيعات، وتحليل المخزون
//  (تعمير المخزون، المخزون بطيء الحركة، معدل دوران المخزون)
// =====================================================================
import { S, sb, esc, toast, arError, fmtNum, fmtDate, num, today } from './core.js';
import { downloadCSV, loadAccounts } from './finance.js';
import { loadParties } from './parties.js';
import { loadItems } from './invoices.js';
import { docNo } from './numbering.js';
import { loadDepartments } from './departments.js';
import { loadLookups } from './lookups.js';

const amt = (x) => Math.abs(x) < 0.0005 ? '' : fmtNum(x);
const qs = () => new URLSearchParams(location.hash.split('?')[1] || '');
const ST = { draft: ['مسودة', 'warn'], posted: ['مرحّل', 'ok'], reversed: ['معكوس', 'bad'], cancelled: ['ملغاة', 'bad'] };
const badge = (s) => ST[s] ? `<span class="badge ${ST[s][1]}">${ST[s][0]}</span>` : esc(s || '');

// ---------------------------------------------------------------------
//  اليوميات
// ---------------------------------------------------------------------
export const DAYBOOKS = {
  journal:         { label: 'يومية القيود العامة', src: 'je', t: 'journal', icon: '📒', g: 'المالية' },
  opening:         { label: 'يومية القيود الافتتاحية', src: 'je', t: 'opening', icon: '🧮', g: 'المالية' },
  receipt:         { label: 'يومية سندات القبض', src: 'je', t: 'receipt', icon: '📥', g: 'حسابات القبض' },
  sale:            { label: 'يومية فواتير المبيعات', src: 'inv', t: 'sale', icon: '🧾', g: 'حسابات القبض' },
  sale_return:     { label: 'يومية مردودات المبيعات', src: 'inv', t: 'sale_return', icon: '↩️', g: 'حسابات القبض' },
  cheque_in:       { label: 'يومية الأوراق التجارية / العملاء', src: 'chq', t: 'in', icon: '💳', g: 'حسابات القبض' },
  payment:         { label: 'يومية سندات الصرف', src: 'je', t: 'payment', icon: '📤', g: 'حسابات الدفع' },
  purchase:        { label: 'يومية فواتير المشتريات', src: 'inv', t: 'purchase', icon: '🛒', g: 'حسابات الدفع' },
  purchase_return: { label: 'يومية مردودات المشتريات', src: 'inv', t: 'purchase_return', icon: '↩️', g: 'حسابات الدفع' },
  cheque_out:      { label: 'يومية الأوراق التجارية / الموردين', src: 'chq', t: 'out', icon: '💳', g: 'حسابات الدفع' },
  stock_in:        { label: 'يومية سندات الإدخال', src: 'sd', t: 'in', icon: '📥', g: 'المخزون' },
  stock_out:       { label: 'يومية سندات الإخراج', src: 'sd', t: 'out', icon: '📤', g: 'المخزون' },
  stock_transfer:  { label: 'يومية سندات التحويل', src: 'sd', t: 'transfer', icon: '🔁', g: 'المخزون' },
  stock_count:     { label: 'يومية الجرد والتسوية', src: 'sd', t: 'count', icon: '📋', g: 'المخزون' },
};

function bar(extra = '') {
  return `<div class="card no-print" style="display:flex;gap:10px;flex-wrap:wrap;align-items:end" id="db">
    <div class="field"><label>من</label><input type="date" data-f="from" value="${S.fy.start_date}"></div>
    <div class="field"><label>إلى</label><input type="date" data-f="to" value="${S.fy.end_date}"></div>
    ${extra}
    <div class="field" style="flex:1;min-width:150px"><label>بحث</label><input data-f="q" placeholder="رقم، بيان، اسم…"></div>
    <button class="btn primary" data-f="go" type="button">🔎 عرض</button>
    <button class="btn sm" data-f="csv" type="button">⬇️ Excel</button><button class="btn sm" data-f="prn" type="button">🖨️ طباعة</button></div>`;
}
const stSel = `<div class="field"><label>الترحيل</label><select data-f="st"><option value="posted">مرحّل</option><option value="draft">غير مرحّل</option><option value="">الجميع</option></select></div>`;

async function viewDaybook(v) {
  if (!S.company || !S.fy) return void (v.innerHTML = `<div class="notice info">اختار شركة وسنة مالية من فوق أول.</div>`);
  const k = DAYBOOKS[qs().get('k')] ? qs().get('k') : 'journal', D = DAYBOOKS[k];
  const [parties, depts, accs, whR] = await Promise.all([loadParties(true), loadDepartments(), loadAccounts(),
    sb.from('warehouses').select('id,name').eq('company_id', S.company.id)]);
  const pById = Object.fromEntries(parties.map(p => [p.id, p])), accById = Object.fromEntries(accs.map(a => [a.id, a]));
  const whById = Object.fromEntries((whR.data || []).map(w => [w.id, w])), dById = Object.fromEntries(depts.map(d => [d.id, d]));
  const subDepts = depts.filter(d => d.kind === 'sub');
  const deptSel = subDepts.length ? `<div class="field"><label>الدائرة</label><select data-f="dep"><option value="">الكل</option>${subDepts.map(d => `<option value="${d.id}">${esc(d.name)}</option>`).join('')}</select></div>` : '';
  const others = Object.entries(DAYBOOKS).filter(([, x]) => x.g === D.g);
  v.innerHTML = `<div class="page-head"><h2>${D.icon} ${esc(D.label)}</h2><div class="spacer"></div><span class="muted">${esc(S.company.name)}</span></div>
    <div class="tabs no-print lk-tabs">${others.map(([kk, x]) => `<a class="tab ${kk === k ? 'active' : ''}" href="#/daybook?k=${kk}">${x.icon} ${esc(x.label.replace('يومية ', ''))}</a>`).join('')}</div>
    ${bar((D.src === 'chq' ? '' : stSel) + deptSel)}<div class="grid cols-4" id="kp" style="margin:12px 0"></div><div class="card table-wrap"><table class="t rep" id="tb"></table></div>`;
  const box = v.querySelector('#db'), f = (n) => box.querySelector(`[data-f=${n}]`);
  let out = [];
  async function run() {
    const from = f('from').value, to = f('to').value, st = f('st')?.value ?? '', q = f('q').value.trim().toLowerCase(), dep = f('dep')?.value || '';
    let rows = [], head = [], body, foot = '';
    if (D.src === 'je') {
      let r = sb.from('journal_entries').select('*').eq('company_id', S.company.id).eq('entry_type', D.t).gte('entry_date', from).lte('entry_date', to).order('entry_date').limit(5000);
      if (st) r = r.eq('status', st); if (dep) r = r.eq('department_id', dep);
      const { data, error } = await r; if (error) return toast(arError(error), 'err');
      rows = (data || []).filter(e => !q || [docNo(e), e.description, e.reference, e.party_name].some(x => String(x || '').toLowerCase().includes(q)));
      head = ['التاريخ', 'رقم السند', ...(D.t === 'journal' || D.t === 'opening' ? [] : [D.t === 'receipt' ? 'استلمنا من' : 'صرفنا إلى', 'الصندوق / البنك']), 'البيان', 'المرجع', 'الدائرة', 'المبلغ', 'الحالة'];
      const cash = !(D.t === 'journal' || D.t === 'opening');
      body = rows.map(e => [fmtDate(e.entry_date), docNo(e), ...(cash ? [e.party_name || '', accById[e.cash_account_id]?.name || ''] : []), e.description || '', e.reference || '', dById[e.department_id]?.name || '', num(e.total), e.status]);
      const tot = rows.reduce((s, e) => s + num(e.total), 0);
      kpis([['عدد السندات', rows.length], ['المجموع', fmtNum(tot)], ['مرحّل', rows.filter(e => e.status === 'posted').length], ['مسودات', rows.filter(e => e.status === 'draft').length]]);
      foot = `<tr class="tot"><td colspan="${head.length - 2}">المجموع</td><td class="n">${fmtNum(tot)}</td><td></td></tr>`;
    } else if (D.src === 'inv') {
      let r = sb.from('invoices').select('*').eq('company_id', S.company.id).eq('inv_type', D.t).gte('inv_date', from).lte('inv_date', to).order('inv_date').limit(5000);
      if (st) r = r.eq('status', st); if (dep) r = r.eq('department_id', dep);
      const { data, error } = await r; if (error) return toast(arError(error), 'err');
      rows = (data || []).filter(i => !q || [docNo(i), i.reference, i.party_name, pById[i.party_id]?.name, i.notes].some(x => String(x || '').toLowerCase().includes(q)));
      head = ['التاريخ', 'رقم الفاتورة', 'العميل / المورد', 'الدفع', 'المرجع', 'قبل الضريبة', 'الخصم', 'الضريبة', 'الإجمالي', 'الحالة'];
      body = rows.map(i => [fmtDate(i.inv_date), docNo(i), pById[i.party_id]?.name || i.party_name || '', i.payment_type === 'cash' ? 'نقدي' : 'آجل', i.reference || '', num(i.subtotal), num(i.discount_total), num(i.tax_total), num(i.total), i.status]);
      const s = (key) => rows.reduce((a, i) => a + num(i[key]), 0);
      kpis([['عدد الفواتير', rows.length], ['قبل الضريبة', fmtNum(s('subtotal'))], ['الضريبة', fmtNum(s('tax_total'))], ['الإجمالي', fmtNum(s('total'))]]);
      foot = `<tr class="tot"><td colspan="5">المجموع</td><td class="n">${fmtNum(s('subtotal'))}</td><td class="n">${fmtNum(s('discount_total'))}</td><td class="n">${fmtNum(s('tax_total'))}</td><td class="n">${fmtNum(s('total'))}</td><td></td></tr>`;
    } else if (D.src === 'sd') {
      let r = sb.from('stock_docs').select('*').eq('company_id', S.company.id).eq('doc_type', D.t).gte('doc_date', from).lte('doc_date', to).order('doc_date').limit(5000);
      if (st) r = r.eq('status', st); if (dep) r = r.eq('department_id', dep);
      const { data, error } = await r; if (error) return toast(arError(error), 'err');
      rows = (data || []).filter(d => !q || [docNo(d), d.notes].some(x => String(x || '').toLowerCase().includes(q)));
      let val = {};
      if (rows.length) {
        const mv = await sb.from('stock_moves').select('source_id,qty,unit_cost').eq('company_id', S.company.id).in('source_id', rows.map(d => d.id));
        (mv.data || []).forEach(m => { const x = (val[m.source_id] ||= { q: 0, v: 0 }); if (D.t !== 'transfer' || num(m.qty) > 0) { x.q += Math.abs(num(m.qty)); x.v += Math.abs(num(m.qty) * num(m.unit_cost)); } });
      }
      head = ['التاريخ', 'رقم السند', D.t === 'transfer' ? 'من مستودع' : 'المستودع', ...(D.t === 'transfer' ? ['إلى مستودع'] : []), 'البيان', 'الكمية', 'القيمة', 'الحالة'];
      body = rows.map(d => [fmtDate(d.doc_date), docNo(d), whById[d.warehouse_id]?.name || '', ...(D.t === 'transfer' ? [whById[d.to_warehouse_id]?.name || ''] : []), d.notes || '', val[d.id]?.q || 0, val[d.id]?.v || 0, d.status]);
      const tq = rows.reduce((a, d) => a + (val[d.id]?.q || 0), 0), tv = rows.reduce((a, d) => a + (val[d.id]?.v || 0), 0);
      kpis([['عدد السندات', rows.length], ['الكمية', fmtNum(tq)], ['القيمة', fmtNum(tv)], ['مسودات', rows.filter(d => d.status === 'draft').length]]);
      foot = `<tr class="tot"><td colspan="${head.length - 3}">المجموع</td><td class="n">${fmtNum(tq)}</td><td class="n">${fmtNum(tv)}</td><td></td></tr>`;
    } else {
      const r = sb.from('cheques').select('*').eq('company_id', S.company.id).eq('direction', D.t).gte('issue_date', from).lte('issue_date', to).order('due_date').limit(5000);
      const { data, error } = await r; if (error) return toast(arError(error), 'err');
      rows = (data || []).filter(c => !q || [c.cheque_no, c.bank_name, c.drawer_name, pById[c.party_id]?.name].some(x => String(x || '').toLowerCase().includes(q)));
      const CS = { portfolio: 'بالمحفظة', collected: 'محصّل', returned: 'راجع', issued: 'صادر', paid: 'مصروف', cancelled: 'ملغى' };
      head = ['تاريخ التحرير', 'تاريخ الاستحقاق', 'رقم الشيك', 'البنك', D.t === 'in' ? 'العميل' : 'المورد', 'المبلغ', 'الحالة'];
      body = rows.map(c => [fmtDate(c.issue_date), fmtDate(c.due_date), c.cheque_no, c.bank_name || '', pById[c.party_id]?.name || c.drawer_name || '', num(c.amount), CS[c.status] || c.status]);
      const tot = rows.reduce((a, c) => a + num(c.amount), 0), due = rows.filter(c => c.due_date < today() && ['portfolio', 'issued'].includes(c.status));
      kpis([['عدد الشيكات', rows.length], ['المجموع', fmtNum(tot)], ['مستحقة وما انصرفت', due.length], ['قيمتها', fmtNum(due.reduce((a, c) => a + num(c.amount), 0))]]);
      foot = `<tr class="tot"><td colspan="5">المجموع</td><td class="n">${fmtNum(tot)}</td><td></td></tr>`;
    }
    out = body.map(r => r.map(x => typeof x === 'number' ? fmtNum(x) : (ST[x]?.[0] || x)));
    const stIdx = D.src === 'chq' ? -1 : head.length - 1;
    v.querySelector('#tb').innerHTML = `<thead><tr><th>#</th>${head.map(h => `<th>${esc(h)}</th>`).join('')}</tr></thead>
      <tbody>${body.map((r, i) => `<tr><td class="muted">${i + 1}</td>${r.map((x, j) => j === stIdx ? `<td>${badge(x)}</td>` : typeof x === 'number' ? `<td class="n">${amt(x)}</td>` : `<td>${esc(x)}</td>`).join('')}</tr>`).join('')
        || `<tr><td colspan="${head.length + 1}" class="empty">ما في سندات بهالفترة</td></tr>`}</tbody>${body.length ? `<tfoot>${foot.replace('<td colspan="', '<td></td><td colspan="')}</tfoot>` : ''}`;
    f('csv').onclick = () => downloadCSV(D.label + '.csv', [head].concat(out));
  }
  function kpis(list) { v.querySelector('#kp').innerHTML = list.map(([l, x]) => `<div class="card stat"><span class="k">${esc(l)}</span><span class="v" style="font-size:20px">${x}</span></div>`).join(''); }
  f('go').onclick = run; f('q').onkeydown = (e) => { if (e.key === 'Enter') run(); };
  ['st', 'dep'].forEach(n => { if (f(n)) f(n).onchange = run; });
  f('prn').onclick = () => window.print();
  run();
}

// ---------------------------------------------------------------------
//  مبيعات وتحصيلات مندوبي المبيعات
// ---------------------------------------------------------------------
async function viewSalesReps(v) {
  if (!S.company || !S.fy) return void (v.innerHTML = `<div class="notice info">اختار شركة وسنة مالية من فوق أول.</div>`);
  const [lk, parties] = await Promise.all([loadLookups(true), loadParties(true)]);
  const reps = lk.filter(r => r.kind === 'sales_rep');
  v.innerHTML = `<div class="page-head"><h2>🧑‍💼 تقرير مندوبي المبيعات</h2><div class="spacer"></div><a class="btn sm no-print" href="#/setup?k=sales_rep">⚙️ المندوبين</a></div>
    ${reps.length ? '' : '<div class="notice info">ما في مندوبين لسا. عرّفهم من «إعداد ← مندوبي المبيعات» واربطهم على العملاء والفواتير.</div>'}
    ${bar()}<div class="grid cols-4" id="kp" style="margin:12px 0"></div><div class="card table-wrap"><table class="t rep" id="tb"></table></div>
    <p class="muted" style="font-size:12px">المبيعات من الفواتير المرحّلة (قبل الضريبة وبعد الخصم). التحصيلات = سندات القبض المرحّلة من عملاء المندوب. العمولة = صافي المبيعات × النسبة.</p>`;
  const box = v.querySelector('#db'), f = (n) => box.querySelector(`[data-f=${n}]`);
  let out = [];
  async function run() {
    const from = f('from').value, to = f('to').value, q = f('q').value.trim().toLowerCase();
    const [iR, rR] = await Promise.all([
      sb.from('invoices').select('id,inv_type,subtotal,discount_total,total,sales_rep_id,party_id').eq('company_id', S.company.id).in('inv_type', ['sale', 'sale_return']).eq('status', 'posted').gte('inv_date', from).lte('inv_date', to).limit(10000),
      sb.from('journal_lines').select('party_id,credit,debit,journal_entries!inner(company_id,entry_type,status,entry_date)').eq('journal_entries.company_id', S.company.id).eq('journal_entries.entry_type', 'receipt').eq('journal_entries.status', 'posted').gte('journal_entries.entry_date', from).lte('journal_entries.entry_date', to).not('party_id', 'is', null).limit(20000)]);
    if (iR.error) return toast(arError(iR.error), 'err');
    const repOfParty = Object.fromEntries(parties.map(p => [p.id, p.sales_rep_id]));
    const t = {}; const get = (id) => (t[id || '-'] ||= { n: 0, s: 0, r: 0, c: 0, cust: new Set() });
    (iR.data || []).forEach(i => { const x = get(i.sales_rep_id); const net = num(i.subtotal) - num(i.discount_total);
      if (i.inv_type === 'sale') { x.n++; x.s += net; } else x.r += net; if (i.party_id) x.cust.add(i.party_id); });
    (rR.data || []).forEach(l => { const x = get(repOfParty[l.party_id]); x.c += num(l.credit) - num(l.debit); });
    const list = [...reps, ...(t['-'] ? [{ id: '-', code: '', name: 'بدون مندوب', rate: 0 }] : [])]
      .filter(r => !q || [r.code, r.name].some(x => (x || '').toLowerCase().includes(q)));
    const row = (r) => { const x = t[r.id] || { n: 0, s: 0, r: 0, c: 0, cust: new Set() }; const net = x.s - x.r; return { r, x, net, com: net * num(r.rate) / 100 }; };
    const rows = list.map(row).sort((a, b) => b.net - a.net);
    const sum = (k) => rows.reduce((a, y) => a + y[k], 0), sx = (k) => rows.reduce((a, y) => a + y.x[k], 0);
    v.querySelector('#kp').innerHTML = [['صافي المبيعات', fmtNum(sum('net'))], ['التحصيلات', fmtNum(sx('c'))], ['العمولات', fmtNum(sum('com'))], ['عدد الفواتير', sx('n')]]
      .map(([l, x]) => `<div class="card stat"><span class="k">${l}</span><span class="v" style="font-size:20px">${x}</span></div>`).join('');
    out = rows.map(y => [y.r.code, y.r.name, y.x.n, y.x.cust.size, fmtNum(y.x.s), fmtNum(y.x.r), fmtNum(y.net), fmtNum(y.x.c), y.r.rate ?? '', fmtNum(y.com)]);
    v.querySelector('#tb').innerHTML = `<thead><tr><th>الرمز</th><th>المندوب</th><th>الفواتير</th><th>العملاء</th><th>المبيعات</th><th>المردودات</th><th>صافي المبيعات</th><th>التحصيلات</th><th>العمولة %</th><th>العمولة</th></tr></thead>
      <tbody>${rows.map(y => `<tr><td>${esc(y.r.code)}</td><td><b>${esc(y.r.name)}</b></td><td class="n">${y.x.n}</td><td class="n">${y.x.cust.size}</td><td class="n">${amt(y.x.s)}</td><td class="n">${amt(y.x.r)}</td><td class="n"><b>${amt(y.net)}</b></td><td class="n">${amt(y.x.c)}</td><td class="n">${y.r.rate ?? ''}</td><td class="n">${amt(y.com)}</td></tr>`).join('')
        || '<tr><td colspan="10" class="empty">ما في بيانات</td></tr>'}</tbody>
      <tfoot><tr class="tot"><td colspan="4">المجموع</td><td class="n">${fmtNum(sx('s'))}</td><td class="n">${fmtNum(sx('r'))}</td><td class="n">${fmtNum(sum('net'))}</td><td class="n">${fmtNum(sx('c'))}</td><td></td><td class="n">${fmtNum(sum('com'))}</td></tr></tfoot>`;
  }
  f('go').onclick = run; f('prn').onclick = () => window.print();
  f('csv').onclick = () => downloadCSV('مندوبي المبيعات.csv', [['الرمز', 'المندوب', 'الفواتير', 'العملاء', 'المبيعات', 'المردودات', 'صافي المبيعات', 'التحصيلات', 'العمولة %', 'العمولة']].concat(out));
  run();
}

// ---------------------------------------------------------------------
//  تحليل المخزون
// ---------------------------------------------------------------------
const SA = {
  aging:    { label: 'تعمير المخزون', icon: '⏳', hint: 'الكمية الموجودة موزّعة حسب عمرها من تاريخ دخولها (الأقدم بيطلع أول).' },
  slow:     { label: 'المخزون بطيء الحركة', icon: '🐢', hint: 'أصناف إلها رصيد وما طلع منها شي من فترة.' },
  turnover: { label: 'معدل دوران المخزون', icon: '🔄', hint: 'كلفة البضاعة الطالعة بالفترة ÷ متوسط قيمة المخزون (أول وآخر الفترة). كل ما زاد الرقم، البضاعة بتلف أسرع.' },
};
async function viewStockAnalysis(v) {
  if (!S.company || !S.fy) return void (v.innerHTML = `<div class="notice info">اختار شركة وسنة مالية من فوق أول.</div>`);
  const k = SA[qs().get('k')] ? qs().get('k') : 'aging', A = SA[k];
  const [items, whR, catR] = await Promise.all([loadItems(true), sb.from('warehouses').select('id,name').eq('company_id', S.company.id).order('code'),
    sb.from('item_categories').select('id,name').eq('company_id', S.company.id)]);
  const goods = items.filter(i => i.item_type !== 'service'), whs = whR.data || [], cats = catR.data || [];
  const catById = Object.fromEntries(cats.map(c => [c.id, c]));
  const extra = `<div class="field"><label>المستودع</label><select data-f="wh"><option value="">كل المستودعات</option>${whs.map(w => `<option value="${w.id}">${esc(w.name)}</option>`).join('')}</select></div>
    ${cats.length ? `<div class="field"><label>الفئة</label><select data-f="cat"><option value="">الكل</option>${cats.map(c => `<option value="${c.id}">${esc(c.name)}</option>`).join('')}</select></div>` : ''}
    ${k === 'slow' ? '<div class="field"><label>بدون حركة طالعة من (يوم)</label><input data-f="days" type="number" value="90" style="width:90px"></div>' : ''}`;
  v.innerHTML = `<div class="page-head"><h2>${A.icon} ${esc(A.label)}</h2><div class="spacer"></div></div>
    <div class="tabs no-print lk-tabs">${Object.entries(SA).map(([kk, x]) => `<a class="tab ${kk === k ? 'active' : ''}" href="#/stock-analysis?k=${kk}">${x.icon} ${esc(x.label)}</a>`).join('')}</div>
    <p class="muted" style="font-size:13px;margin:8px 0">${esc(A.hint)}</p>
    ${bar(extra)}<div class="grid cols-4" id="kp" style="margin:12px 0"></div><div class="card table-wrap"><table class="t rep" id="tb"></table></div>`;
  const box = v.querySelector('#db'), f = (n) => box.querySelector(`[data-f=${n}]`);
  if (k !== 'turnover') { f('from').closest('.field').style.display = 'none'; f('to').previousElementSibling.textContent = 'لغاية تاريخ'; }
  let out = [], head = [];
  async function run() {
    const from = f('from').value, to = f('to').value, wh = f('wh').value, cat = f('cat')?.value || '', q = f('q').value.trim().toLowerCase();
    let r = sb.from('stock_moves').select('item_id,warehouse_id,move_date,qty,unit_cost,source_type').eq('company_id', S.company.id).lte('move_date', to).order('move_date').limit(50000);
    if (wh) r = r.eq('warehouse_id', wh);
    const { data, error } = await r; if (error) return toast(arError(error), 'err');
    const mv = {}; (data || []).forEach(m => (mv[m.item_id] ||= []).push(m));
    const list = goods.filter(i => (!cat || i.category_id === cat) && (!q || [i.code, i.name].some(x => (x || '').toLowerCase().includes(q))));
    const ref = to > today() ? today() : to; const days = (d) => Math.floor((new Date(ref) - new Date(d)) / 864e5);
    const kp = (arr) => v.querySelector('#kp').innerHTML = arr.map(([l, x]) => `<div class="card stat"><span class="k">${l}</span><span class="v" style="font-size:20px">${x}</span></div>`).join('');
    let rows = [];
    if (k === 'aging') {
      const B = [[0, 30, '0–30 يوم'], [31, 60, '31–60'], [61, 90, '61–90'], [91, 180, '91–180'], [181, 1e9, 'أكثر من 180']];
      for (const it of list) {
        const ms = mv[it.id] || []; const onHand = ms.reduce((s, m) => s + num(m.qty), 0); if (onHand <= 0.0005) continue;
        const val = ms.reduce((s, m) => s + num(m.qty) * num(m.unit_cost), 0);
        // الأقدم بيطلع أول: الباقي من آخر الحركات الداخلة
        let left = onHand; const b = B.map(() => 0);
        for (const m of [...ms].filter(m => num(m.qty) > 0).reverse()) { if (left <= 0) break; const take = Math.min(left, num(m.qty)); left -= take;
          const d = days(m.move_date); b[B.findIndex(x => d >= x[0] && d <= x[1])] += take; }
        if (left > 0) b[B.length - 1] += left;
        rows.push({ it, onHand, val, b });
      }
      head = ['الرمز', 'الصنف', 'الفئة', 'الرصيد', 'القيمة', ...B.map(x => x[2])];
      kp([['عدد الأصناف', rows.length], ['قيمة المخزون', fmtNum(rows.reduce((s, x) => s + x.val, 0))], ['كمية فوق 90 يوم', fmtNum(rows.reduce((s, x) => s + x.b[3] + x.b[4], 0))], ['كمية فوق 180 يوم', fmtNum(rows.reduce((s, x) => s + x.b[4], 0))]]);
      out = rows.map(x => [x.it.code, x.it.name, catById[x.it.category_id]?.name || '', fmtNum(x.onHand), fmtNum(x.val), ...x.b.map(n => fmtNum(n))]);
      v.querySelector('#tb').innerHTML = `<thead><tr>${head.map(h => `<th>${h}</th>`).join('')}</tr></thead><tbody>${rows.map(x => `<tr><td>${esc(x.it.code)}</td><td>${esc(x.it.name)}</td><td>${esc(catById[x.it.category_id]?.name || '')}</td><td class="n"><b>${fmtNum(x.onHand)}</b></td><td class="n">${fmtNum(x.val)}</td>${x.b.map((n, i) => `<td class="n" style="${n && i >= 3 ? 'color:#b42318;font-weight:700' : ''}">${amt(n)}</td>`).join('')}</tr>`).join('') || `<tr><td colspan="${head.length}" class="empty">ما في رصيد</td></tr>`}</tbody>`;
    } else if (k === 'slow') {
      const lim = +f('days').value || 90;
      for (const it of list) {
        const ms = mv[it.id] || []; const onHand = ms.reduce((s, m) => s + num(m.qty), 0); if (onHand <= 0.0005) continue;
        const ins = ms.filter(m => num(m.qty) > 0), outs = ms.filter(m => num(m.qty) < 0);
        const lastOut = outs.length ? outs[outs.length - 1].move_date : null, lastIn = ins.length ? ins[ins.length - 1].move_date : null;
        const idle = lastOut ? days(lastOut) : (lastIn ? days(lastIn) : 0);
        if (idle < lim) continue;
        rows.push({ it, onHand, val: ms.reduce((s, m) => s + num(m.qty) * num(m.unit_cost), 0), lastIn, lastOut, idle });
      }
      rows.sort((a, b) => b.idle - a.idle);
      head = ['الرمز', 'الصنف', 'الفئة', 'الرصيد', 'القيمة', 'آخر دخول', 'آخر خروج', 'أيام بدون حركة'];
      kp([['أصناف بطيئة', rows.length], ['قيمتها', fmtNum(rows.reduce((s, x) => s + x.val, 0))], ['ما طلع منها ولا مرة', rows.filter(x => !x.lastOut).length], ['أقدم ركود (يوم)', rows[0]?.idle || 0]]);
      out = rows.map(x => [x.it.code, x.it.name, catById[x.it.category_id]?.name || '', fmtNum(x.onHand), fmtNum(x.val), x.lastIn || '', x.lastOut || 'ولا مرة', x.idle]);
      v.querySelector('#tb').innerHTML = `<thead><tr>${head.map(h => `<th>${h}</th>`).join('')}</tr></thead><tbody>${rows.map(x => `<tr><td>${esc(x.it.code)}</td><td>${esc(x.it.name)}</td><td>${esc(catById[x.it.category_id]?.name || '')}</td><td class="n">${fmtNum(x.onHand)}</td><td class="n">${fmtNum(x.val)}</td><td>${fmtDate(x.lastIn)}</td><td>${x.lastOut ? fmtDate(x.lastOut) : '<span class="badge warn">ولا مرة</span>'}</td><td class="n"><b>${x.idle}</b></td></tr>`).join('') || `<tr><td colspan="${head.length}" class="empty">ما في أصناف راكدة أكثر من ${lim} يوم 👍</td></tr>`}</tbody>`;
    } else {
      const pd = Math.max(1, Math.floor((new Date(to) - new Date(from)) / 864e5) + 1);
      for (const it of list) {
        const ms = mv[it.id] || []; if (!ms.length) continue;
        const valAt = (d, incl) => ms.filter(m => incl ? m.move_date <= d : m.move_date < d).reduce((s, m) => s + num(m.qty) * num(m.unit_cost), 0);
        const ov = valAt(from, false), cv = valAt(to, true);
        const cogs = ms.filter(m => m.move_date >= from && m.move_date <= to && num(m.qty) < 0 && m.source_type === 'invoice').reduce((s, m) => s - num(m.qty) * num(m.unit_cost), 0);
        const avg = (ov + cv) / 2; const tr = avg > 0.0005 ? cogs / avg : 0;
        if (!cogs && !ov && !cv) continue;
        rows.push({ it, ov, cv, avg, cogs, tr, dd: tr ? pd / tr : null });
      }
      rows.sort((a, b) => b.tr - a.tr);
      head = ['الرمز', 'الصنف', 'الفئة', 'قيمة أول الفترة', 'قيمة آخر الفترة', 'متوسط المخزون', 'كلفة المبيعات', 'معدل الدوران', 'أيام التخزين'];
      const T = rows.reduce((a, x) => ({ avg: a.avg + x.avg, cogs: a.cogs + x.cogs }), { avg: 0, cogs: 0 }); const tt = T.avg ? T.cogs / T.avg : 0;
      kp([['كلفة المبيعات', fmtNum(T.cogs)], ['متوسط المخزون', fmtNum(T.avg)], ['معدل الدوران العام', tt.toFixed(2) + ' مرة'], ['متوسط أيام التخزين', tt ? Math.round(pd / tt) + ' يوم' : '—']]);
      out = rows.map(x => [x.it.code, x.it.name, catById[x.it.category_id]?.name || '', fmtNum(x.ov), fmtNum(x.cv), fmtNum(x.avg), fmtNum(x.cogs), x.tr.toFixed(2), x.dd ? Math.round(x.dd) : '']);
      v.querySelector('#tb').innerHTML = `<thead><tr>${head.map(h => `<th>${h}</th>`).join('')}</tr></thead><tbody>${rows.map(x => `<tr><td>${esc(x.it.code)}</td><td>${esc(x.it.name)}</td><td>${esc(catById[x.it.category_id]?.name || '')}</td><td class="n">${amt(x.ov)}</td><td class="n">${amt(x.cv)}</td><td class="n">${amt(x.avg)}</td><td class="n">${amt(x.cogs)}</td><td class="n"><b>${x.tr.toFixed(2)}</b></td><td class="n">${x.dd ? Math.round(x.dd) : '—'}</td></tr>`).join('') || `<tr><td colspan="${head.length}" class="empty">ما في حركات</td></tr>`}</tbody>`;
    }
    f('csv').onclick = () => downloadCSV(A.label + '.csv', [head].concat(out));
  }
  f('go').onclick = run; f('prn').onclick = () => window.print(); f('wh').onchange = run; if (f('cat')) f('cat').onchange = run;
  run();
}

export const DAYBOOK_ROUTES = { 'daybook': viewDaybook, 'rep-sales-reps': viewSalesReps, 'stock-analysis': viewStockAnalysis };
