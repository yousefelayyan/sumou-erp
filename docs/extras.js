// =====================================================================
//  السمو ERP — لوحة الأرقام، بانتظار الترحيل، القيود المتكررة،
//  مراكز الكلفة، العملات، التسوية البنكية
// =====================================================================
import { docNo, loadNumbering, masterCode } from './numbering.js';
import { S, sb, esc, fmtDate, fmtNum, num, today, toast, arError, modal, confirmBox, formData, can, log } from './core.js';
import { loadAccounts, leafAccounts, accLabel, ENTRY_TYPES, downloadCSV } from './finance.js';
import { printDoc } from './print.js';

const noCo = (v) => void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
const q = (k) => new URLSearchParams(location.hash.split('?')[1] || '').get(k);

// ---------------------------------------------------------------------
//  لوحة الأرقام (بتنعرض بالصفحة الرئيسية)
// ---------------------------------------------------------------------
export async function dashboardPanel(el) {
  if (!S.company || !S.fy || !el) return;
  // القيود المتكررة المستحقة بتنعمل مسودات لحالها
  if (can('journal_entries', 'add')) sb.rpc('run_recurring', { p_company: S.company.id }).then(r => { if (r.data > 0) toast(`انعمل ${r.data} قيد متكرر كمسودة — شوفها بـ«بانتظار الترحيل»`, 'ok'); });
  const d0 = today() >= S.fy.start_date && today() <= S.fy.end_date ? today() : S.fy.end_date;
  const { data: k, error } = await sb.rpc('dash_kpis', { p_company: S.company.id, p_fy: S.fy.id, p_date: d0 });
  if (error || !k) return;
  const card = (label, val, sub, href, color) => `<a class="card stat" ${href ? `href="${href}"` : ''} style="text-decoration:none;color:inherit">
      <span class="k">${label}</span><span class="v" dir="ltr" style="text-align:right;${color ? `color:${color}` : ''}">${fmtNum(val)}</span>${sub ? `<span class="muted" style="font-size:12px">${sub}</span>` : ''}</a>`;
  const drafts = num(k.drafts_entries) + num(k.drafts_invoices) + num(k.drafts_stock);
  const ms = k.month_sales || [], mx = Math.max(1, ...ms.map(x => Math.abs(num(x.v))));
  el.innerHTML = `<h3 style="margin:18px 0 8px">📊 أرقام الشركة</h3>
    <div class="grid cols-4">
      ${can('reports', 'view') ? card('مبيعات هالشهر', k.sales_month, `مشتريات الشهر: ${fmtNum(k.purchases_month)}`, '#/sales') : ''}
      ${can('reports', 'view') ? card('صافي الربح للسنة', k.profit_year, `مبيعات السنة: ${fmtNum(k.sales_year)}`, '#/rep-income', num(k.profit_year) < 0 ? 'var(--bad)' : '') : ''}
      ${can('reports', 'view') ? card('الصندوق', k.cash, `البنوك: ${fmtNum(k.bank)}`, '#/rep-trial') : ''}
      ${can('reports', 'view') ? card('ذمم العملاء', k.receivables, `ذمم الموردين: ${fmtNum(k.payables)}`, '#/rep-aging') : ''}
      ${can('cheques', 'view') ? card('شيكات واردة خلال 7 أيام', k.cheques_in_7, `صادرة: ${fmtNum(k.cheques_out_7)}`, '#/cheques') : ''}
      <a class="card stat" href="#/pending" style="text-decoration:none;color:inherit"><span class="k">بانتظار الترحيل</span>
        <span class="v" style="${drafts ? 'color:var(--warn,#b45309)' : ''}">${drafts}</span><span class="muted" style="font-size:12px">قيود ${k.drafts_entries} · فواتير ${k.drafts_invoices} · مخزون ${k.drafts_stock}</span></a>
    </div>
    ${ms.length && can('reports', 'view') ? `<div class="card" style="margin-top:12px"><b>المبيعات الشهرية</b>
      <div style="display:flex;align-items:flex-end;gap:6px;height:120px;margin-top:10px">${ms.map(x => `<div style="flex:1;display:flex;flex-direction:column;align-items:center;gap:4px" title="${fmtNum(x.v)}">
        <div style="width:100%;max-width:34px;background:var(--brand);opacity:.85;border-radius:6px 6px 0 0;height:${Math.max(2, Math.abs(num(x.v)) / mx * 96)}px"></div>
        <span class="muted" style="font-size:11px">${x.m.slice(5)}</span></div>`).join('')}</div></div>` : ''}`;
}

// ---------------------------------------------------------------------
//  بانتظار الترحيل (الموافقة)
// ---------------------------------------------------------------------
const INV_LABEL = { sale: 'فاتورة بيع', sale_return: 'مرتجع بيع', purchase: 'فاتورة شراء', purchase_return: 'مرتجع شراء' };
const STOCK_LABEL = { in: 'سند إدخال', out: 'سند إخراج', transfer: 'سند تحويل', count: 'جرد' };
const INV_ROUTE = { sale: 'sales', sale_return: 'sales', purchase: 'purchases', purchase_return: 'purchases' };
async function viewPending(v) {
  if (!S.company) return noCo(v);
  const [{ data, error }, ppl] = await Promise.all([sb.rpc('pending_posts', { p_company: S.company.id }), sb.from('profiles').select('id,full_name,username,email')]);
  if (error) throw error;
  const who = Object.fromEntries((ppl.data || []).map(p => [p.id, p.full_name || p.username || p.email]));
  const label = (r) => r.kind === 'entry' ? (ENTRY_TYPES[r.doc_type]?.label || r.doc_type) : r.kind === 'invoice' ? INV_LABEL[r.doc_type] : STOCK_LABEL[r.doc_type];
  const href = (r) => r.kind === 'entry' ? `#/${ENTRY_TYPES[r.doc_type]?.route || 'journal'}` : r.kind === 'invoice' ? `#/${INV_ROUTE[r.doc_type]}` : `#/stock-docs?type=${r.doc_type}`;
  v.innerHTML = `<div class="page-head"><h2>⏳ بانتظار الترحيل</h2><span class="badge brand">${data.length}</span></div>
    <p class="muted">هون كل المسودات اللي دخلها الموظفين وما انرحّلت لسا. المحاسب أو المدير بيراجعها وبيرحّلها. (الموظف اللي ما إله صلاحية «ترحيل» بيقدر يحفظ مسودة بس.)</p>
    <div class="card table-wrap"><table class="t"><thead><tr><th>النوع</th><th>الرقم</th><th>التاريخ</th><th>البيان</th><th>المبلغ</th><th>دخلها</th><th>وقت الإدخال</th><th></th></tr></thead><tbody>
    ${data.map(r => `<tr><td>${esc(label(r))}</td><td><b dir="ltr">${esc(docNo(r))}</b></td><td>${fmtDate(r.doc_date)}</td><td>${esc(r.description || '')}</td>
      <td class="n">${r.amount == null ? '' : fmtNum(r.amount)}</td><td>${esc(who[r.created_by] || '')}</td><td class="muted" style="font-size:12px">${fmtDate(r.created_at)}</td>
      <td><a class="btn sm" href="${href(r)}">فتح الشاشة</a></td></tr>`).join('') || '<tr><td colspan="8" class="empty">ما في مسودات 👍</td></tr>'}</tbody></table></div>`;
}

// ---------------------------------------------------------------------
//  القيود المتكررة
// ---------------------------------------------------------------------
export function recurringDialog(entry) {
  const d = new Date(entry.entry_date); const nxt = new Date(d.getFullYear(), d.getMonth() + 1, Math.min(28, d.getDate()));
  const iso = (x) => `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, '0')}-${String(x.getDate()).padStart(2, '0')}`;
  const m = modal({ title: '🔁 تكرار هالقيد تلقائياً', size: 'sm', body: `<form id="rc"><div class="field"><label>الاسم</label><input name="title" value="${esc(entry.description || 'قيد متكرر')}"></div>
    <div class="grid cols-2"><div class="field"><label>كل كم شهر</label><select name="every_months">${[1, 2, 3, 6, 12].map(n => `<option value="${n}">${n === 1 ? 'كل شهر' : n === 12 ? 'كل سنة' : 'كل ' + n + ' شهور'}</option>`).join('')}</select></div>
    <div class="field"><label>باليوم رقم</label><input name="day_of_month" value="${Math.min(28, d.getDate())}" inputmode="numeric"></div>
    <div class="field"><label>أول مرة بتاريخ</label><input type="date" name="next_date" value="${iso(nxt)}"></div>
    <div class="field"><label>لغاية (اختياري)</label><input type="date" name="end_date"></div></div></form>
    <p class="muted" style="font-size:13px">لما يجي موعده، البرنامج بيعمل نسخة منه كـ«مسودة» لحاله، وإنت بتراجعها وبترحّلها.</p>`,
    foot: '<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>' });
  m.el.querySelector('[data-save]').onclick = async () => {
    const f = formData(m.el.querySelector('#rc')); const day = Math.max(1, Math.min(28, +f.day_of_month || 1));
    const { error } = await sb.from('recurring_entries').insert({ company_id: S.company.id, source_entry_id: entry.id, title: f.title || 'قيد متكرر',
      every_months: +f.every_months, day_of_month: day, next_date: f.next_date, end_date: f.end_date || null });
    if (error) return toast(arError(error), 'err');
    toast('تم. بتلاقيه بشاشة «القيود المتكررة»', 'ok'); m.close();
  };
}
async function viewRecurring(v, ctx) {
  if (!S.company) return noCo(v);
  const { data, error } = await sb.from('recurring_entries').select('*').eq('company_id', S.company.id).order('next_date');
  if (error) throw error;
  v.innerHTML = `<div class="page-head"><h2>🔁 القيود المتكررة</h2><div class="spacer"></div>${can('journal_entries', 'add') ? '<button class="btn primary" id="run">▶️ ولّد المستحق الآن</button>' : ''}</div>
    <p class="muted">لتضيف قيد متكرر: افتح أي سند قيد أو قبض أو صرف، واضغط «🔁 تكرار شهري». المستحق بيتولّد لحاله كل ما تفتح الصفحة الرئيسية.</p>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الاسم</th><th>التكرار</th><th>الموعد الجاي</th><th>لغاية</th><th>آخر تشغيل</th><th>الحالة</th><th></th></tr></thead><tbody>
    ${data.map(r => `<tr><td><b>${esc(r.title)}</b></td><td>${r.every_months === 1 ? 'شهري' : r.every_months === 12 ? 'سنوي' : 'كل ' + r.every_months + ' شهور'} — يوم ${r.day_of_month}</td>
      <td>${fmtDate(r.next_date)}</td><td>${r.end_date ? fmtDate(r.end_date) : '—'}</td><td>${r.last_run ? fmtDate(r.last_run) : '—'}</td>
      <td>${r.is_active ? '<span class="badge ok">فعّال</span>' : '<span class="badge bad">موقوف</span>'}</td>
      <td class="actions">${can('journal_entries', 'add') ? `<button class="btn sm" data-tg="${r.id}">${r.is_active ? 'إيقاف' : 'تفعيل'}</button> <button class="btn sm danger" data-rm="${r.id}">حذف</button>` : ''}</td></tr>`).join('')
      || '<tr><td colspan="7" class="empty">ما في قيود متكررة</td></tr>'}</tbody></table></div>`;
  v.querySelector('#run')?.addEventListener('click', async () => { const r = await sb.rpc('run_recurring', { p_company: S.company.id }); if (r.error) return toast(arError(r.error), 'err'); toast(`انعمل ${r.data} قيد كمسودة`, 'ok'); ctx.rerender(); });
  v.querySelector('tbody').onclick = async (e) => {
    const t = e.target.closest('[data-tg]'), d = e.target.closest('[data-rm]');
    if (t) { const r = data.find(x => x.id === t.dataset.tg); const { error } = await sb.from('recurring_entries').update({ is_active: !r.is_active }).eq('id', r.id); if (error) return toast(arError(error), 'err'); ctx.rerender(); }
    if (d) { if (!(await confirmBox('حذف التكرار؟ (القيود اللي انعملت بتضل)'))) return; const { error } = await sb.from('recurring_entries').delete().eq('id', d.dataset.rm); if (error) return toast(arError(error), 'err'); ctx.rerender(); }
  };
}

// ---------------------------------------------------------------------
//  مراكز الكلفة + العملات (شاشة وحدة بتبويبين) + تقرير مراكز الكلفة
// ---------------------------------------------------------------------
async function viewCostCenters(v, ctx) {
  if (!S.company) return noCo(v);
  const tab = q('tab') === 'cur' ? 'cur' : 'cc';
  const tbl = tab === 'cc' ? 'cost_centers' : 'currencies';
  const [{ data, error }] = await Promise.all([sb.from(tbl).select('*').eq('company_id', S.company.id).order('code'), loadNumbering(true)]);
  if (error) throw error;
  const ed = can('accounts', 'edit');
  v.innerHTML = `<div class="page-head"><h2>${tab === 'cc' ? '🎯 مراكز الكلفة' : '💱 العملات الأجنبية'}</h2><div class="spacer"></div>
      ${tab === 'cc' ? '<a class="btn sm" href="#/rep-cc">📊 تقرير مراكز الكلفة</a>' : '<a class="btn sm" href="#/rep-fx">📊 أرصدة العملات</a>'} ${ed ? '<button class="btn primary" id="add">➕ إضافة</button>' : ''}</div>
    <div class="tabs"><a class="tab ${tab === 'cc' ? 'active' : ''}" href="#/cost-centers" style="text-decoration:none">🎯 مراكز الكلفة</a><a class="tab ${tab === 'cur' ? 'active' : ''}" href="#/cost-centers?tab=cur" style="text-decoration:none">💱 العملات</a></div>
    <p class="muted">${tab === 'cc' ? 'مثل الفروع أو المشاريع أو الأقسام. لما تضيف مراكز، بيطلع عمود «مركز الكلفة» بسندات القيد، وخانة بالفواتير والموظفين والأصول.' : 'لما تضيف عملة، بيطلع بالسندات عمود العملة والمبلغ بالعملة وسعر الصرف، والمبلغ بالدينار بينحسب لحاله. السعر = كم دينار للوحدة.'}</p>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرمز</th><th>الاسم</th>${tab === 'cur' ? '<th>سعر الصرف (دينار)</th>' : ''}<th>الحالة</th><th></th></tr></thead><tbody>
    ${data.map(r => `<tr><td>${esc(r.code)}</td><td><b>${esc(r.name)}</b></td>${tab === 'cur' ? `<td class="n">${num(r.rate)}</td>` : ''}<td>${r.is_active ? '<span class="badge ok">فعّال</span>' : '<span class="badge bad">موقوف</span>'}</td>
      <td class="actions">${ed ? `<button class="btn sm" data-ed="${r.id}">تعديل</button>` : ''}</td></tr>`).join('') || `<tr><td colspan="5" class="empty">ما في ${tab === 'cc' ? 'مراكز كلفة' : 'عملات'}</td></tr>`}</tbody></table></div>`;
  const open = (r) => {
    const isNew = !r; r = r || { code: tab === 'cur' ? 'USD' : (masterCode('m_cost_center', data.map(x => x.code)) ?? String(data.length + 1)), name: tab === 'cur' ? 'دولار أمريكي' : '', rate: tab === 'cur' ? 0.709 : null, is_active: true };
    const m = modal({ title: isNew ? 'إضافة' : 'تعديل', size: 'sm', body: `<form id="f"><div class="field"><label>الرمز</label><input name="code" value="${esc(r.code)}" dir="ltr"></div>
      <div class="field"><label>الاسم</label><input name="name" value="${esc(r.name)}"></div>${tab === 'cur' ? `<div class="field"><label>سعر الصرف (كم دينار للوحدة)</label><input name="rate" value="${r.rate}" inputmode="decimal" dir="ltr"></div>` : ''}
      <label class="check"><input type="checkbox" name="is_active" ${r.is_active ? 'checked' : ''}> فعّال</label></form>`,
      foot: '<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>' });
    m.el.querySelector('[data-save]').onclick = async () => {
      const d = formData(m.el.querySelector('#f')); if (!d.code || !d.name) return toast('الرمز والاسم مطلوبين', 'err');
      if (tab === 'cur') { d.rate = num(d.rate); d.code = d.code.toUpperCase(); if (d.rate <= 0) return toast('سعر الصرف لازم يكون أكبر من صفر', 'err'); }
      const res = isNew ? await sb.from(tbl).insert({ ...d, company_id: S.company.id }) : await sb.from(tbl).update(d).eq('id', r.id);
      if (res.error) return toast(arError(res.error), 'err'); toast('تم الحفظ', 'ok'); m.close(); ctx.rerender();
    };
  };
  v.querySelector('#add')?.addEventListener('click', () => open(null));
  v.querySelector('tbody').onclick = (e) => { const b = e.target.closest('[data-ed]'); if (b) open(data.find(x => x.id === b.dataset.ed)); };
}

async function viewRepCC(v) {
  if (!S.company || !S.fy) return noCo(v);
  const { data: ccs } = await sb.from('cost_centers').select('*').eq('company_id', S.company.id).order('code');
  v.innerHTML = `<div class="page-head"><h2>📊 تقرير مراكز الكلفة</h2></div>
    <div class="card no-print filters"><div class="field"><label>من</label><input type="date" id="f-from" value="${S.fy.start_date}"></div><div class="field"><label>إلى</label><input type="date" id="f-to" value="${S.fy.end_date}"></div>
      <div class="field" style="justify-content:flex-end"><button class="btn primary" id="run">عرض</button></div><div class="field" style="justify-content:flex-end"><button class="btn" id="prn">🖨️ طباعة</button></div></div><div id="out"></div>`;
  let last;
  const run = async () => {
    const from = v.querySelector('#f-from').value, to = v.querySelector('#f-to').value;
    const { data, error } = await sb.rpc('rep_cost_centers', { p_company: S.company.id, p_from: from, p_to: to });
    if (error) return void (v.querySelector('#out').innerHTML = `<div class="notice">${esc(arError(error))}</div>`);
    const nm = Object.fromEntries((ccs || []).map(c => [c.id, `${c.code} — ${c.name}`]));
    const rows = data.sort((a, b) => (nm[a.cost_center_id] || 'ي').localeCompare(nm[b.cost_center_id] || 'ي', 'ar'));
    const t = rows.reduce((s, r) => ({ r: s.r + num(r.revenue), e: s.e + num(r.expenses) }), { r: 0, e: 0 });
    const table = `<table class="t pt rep"><thead><tr><th>مركز الكلفة</th><th>الإيرادات</th><th>المصاريف</th><th>صافي الربح</th></tr></thead><tbody>
      ${rows.map(r => `<tr><td>${esc(nm[r.cost_center_id] || 'بدون مركز كلفة')}</td><td class="n">${fmtNum(r.revenue)}</td><td class="n">${fmtNum(r.expenses)}</td><td class="n" style="${num(r.revenue) - num(r.expenses) < 0 ? 'color:var(--bad)' : ''}">${fmtNum(num(r.revenue) - num(r.expenses))}</td></tr>`).join('') || '<tr><td colspan="4" class="empty">ما في حركات</td></tr>'}</tbody>
      <tfoot><tr class="tot"><td>المجموع</td><td class="n">${fmtNum(t.r)}</td><td class="n">${fmtNum(t.e)}</td><td class="n">${fmtNum(t.r - t.e)}</td></tr></tfoot></table>`;
    v.querySelector('#out').innerHTML = `<div class="card table-wrap" style="margin-top:12px">${table}</div>`; last = { table, from, to };
  };
  v.querySelector('#run').onclick = run; v.querySelector('#prn').onclick = () => last && printDoc('تقرير مراكز الكلفة', last.table, { subtitle: `من ${fmtDate(last.from)} إلى ${fmtDate(last.to)}` });
  run();
}

async function viewRepFX(v) {
  if (!S.company) return noCo(v);
  const accs = await loadAccounts(); const by = Object.fromEntries(accs.map(a => [a.id, a]));
  const { data, error } = await sb.rpc('rep_fx_balances', { p_company: S.company.id, p_date: today() });
  if (error) throw error;
  const { data: curs } = await sb.from('currencies').select('*').eq('company_id', S.company.id);
  const rate = Object.fromEntries((curs || []).map(c => [c.code, num(c.rate)]));
  const table = `<table class="t pt rep"><thead><tr><th>الحساب</th><th>العملة</th><th>الرصيد بالعملة</th><th>الرصيد بالدفاتر (دينار)</th><th>بالسعر الحالي</th><th>فرق إعادة التقييم</th></tr></thead><tbody>
    ${data.map(r => { const now = num(r.fx_balance) * (rate[r.currency] || 0); return `<tr><td>${esc(accLabel(by[r.account_id]))}</td><td>${esc(r.currency)}</td><td class="n">${fmtNum(r.fx_balance)}</td><td class="n">${fmtNum(r.jod_balance)}</td>
      <td class="n">${rate[r.currency] ? fmtNum(now) : '—'}</td><td class="n">${rate[r.currency] ? fmtNum(now - num(r.jod_balance)) : '—'}</td></tr>`; }).join('') || '<tr><td colspan="6" class="empty">ما في حركات بعملات أجنبية</td></tr>'}</tbody></table>`;
  v.innerHTML = `<div class="page-head"><h2>💱 أرصدة العملات الأجنبية</h2><div class="spacer"></div><button class="btn" id="prn">🖨️ طباعة</button></div>
    <p class="muted">فرق إعادة التقييم = الرصيد بالعملة × السعر الحالي − الرصيد بالدفاتر. إذا بدك تسجّله، اعمل سند قيد بين الحساب وحساب «فروقات العملة».</p>
    <div class="card table-wrap">${table}</div>`;
  v.querySelector('#prn').onclick = () => printDoc('أرصدة العملات الأجنبية', table, { subtitle: `كما في ${fmtDate(today())}` });
}

// ---------------------------------------------------------------------
//  التسوية البنكية
// ---------------------------------------------------------------------
async function viewBankRecons(v, ctx) {
  if (!S.company) return noCo(v);
  const id = q('id');
  if (id) return reconScreen(v, ctx, id);
  const [{ data, error }, accs] = await Promise.all([sb.from('bank_recons').select('*').eq('company_id', S.company.id).order('statement_date', { ascending: false }), loadAccounts()]);
  if (error) throw error;
  const by = Object.fromEntries(accs.map(a => [a.id, a]));
  const banks = leafAccounts(accs).filter(a => a.account_type === 'bank').concat(leafAccounts(accs).filter(a => a.account_type === 'cash'));
  v.innerHTML = `<div class="page-head"><h2>🏦 التسوية البنكية</h2><div class="spacer"></div>${can('bank_recon', 'edit') ? '<button class="btn primary" id="add">➕ تسوية جديدة</button>' : ''}</div>
    <p class="muted">بتطابق كشف البنك مع حساب البنك بالدفاتر: بتأشّر على الحركات اللي ظهرت بكشف البنك، والبرنامج بيبيّنلك الفرق والحركات المعلّقة (شيكات ما انصرفت، إيداعات بالطريق).</p>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الحساب</th><th>تاريخ الكشف</th><th>رصيد الكشف</th><th>الحالة</th><th></th></tr></thead><tbody>
    ${data.map(r => `<tr class="click" data-open="${r.id}"><td><b>${esc(accLabel(by[r.account_id]))}</b></td><td>${fmtDate(r.statement_date)}</td><td class="n">${fmtNum(r.statement_balance)}</td>
      <td>${r.status === 'done' ? '<span class="badge ok">مقفلة</span>' : '<span class="badge warn">مفتوحة</span>'}</td><td><span class="btn sm">فتح</span></td></tr>`).join('') || '<tr><td colspan="5" class="empty">ما في تسويات</td></tr>'}</tbody></table></div>`;
  v.querySelector('tbody').onclick = (e) => { const r = e.target.closest('[data-open]'); if (r) location.hash = `#/bank-recon?id=${r.dataset.open}`; };
  v.querySelector('#add')?.addEventListener('click', () => {
    const m = modal({ title: 'تسوية بنكية جديدة', size: 'sm', body: `<form id="f"><div class="field"><label>حساب البنك</label><select name="account_id">${banks.map(a => `<option value="${a.id}">${esc(accLabel(a))}</option>`).join('')}</select></div>
      <div class="field"><label>تاريخ كشف البنك</label><input type="date" name="statement_date" value="${today()}"></div>
      <div class="field"><label>الرصيد بكشف البنك (آخر الكشف)</label><input name="statement_balance" inputmode="decimal" dir="ltr"></div></form>`,
      foot: '<button class="btn primary" data-save>متابعة</button><button class="btn" data-close>إلغاء</button>' });
    m.el.querySelector('[data-save]').onclick = async () => {
      const d = formData(m.el.querySelector('#f')); if (!d.account_id || d.statement_balance == null) return toast('عبّي الحقول', 'err');
      const { data: r, error: er } = await sb.from('bank_recons').insert({ company_id: S.company.id, account_id: d.account_id, statement_date: d.statement_date, statement_balance: num(d.statement_balance) }).select().single();
      if (er) return toast(arError(er), 'err'); m.close(); location.hash = `#/bank-recon?id=${r.id}`;
    };
  });
}

async function reconScreen(v, ctx, id) {
  const [{ data: rc, error }, accs] = await Promise.all([sb.from('bank_recons').select('*').eq('id', id).single(), loadAccounts()]);
  if (error) throw error;
  const acc = accs.find(a => a.id === rc.account_id);
  const [ln, bb] = await Promise.all([sb.rpc('rep_bank_lines', { p_recon: id }), sb.rpc('account_book_balance', { p_company: S.company.id, p_account: rc.account_id, p_date: rc.statement_date })]);
  if (ln.error) throw ln.error;
  const lines = ln.data, book = num(bb.data), done = rc.status === 'done', ed = can('bank_recon', 'edit') && !done;
  const sel = new Set(lines.filter(l => l.cleared).map(l => l.line_id));
  v.innerHTML = `<div class="page-head"><h2>🏦 تسوية: ${esc(accLabel(acc))}</h2><div class="spacer"></div><a class="btn sm" href="#/bank-recon">↩️ رجوع</a>
      <button class="btn" id="prn">🖨️ طباعة</button>${ed ? '<button class="btn primary" id="fin">✅ إقفال التسوية</button>' : ''}${done && can('bank_recon', 'edit') ? '<button class="btn" id="reopen">فتح التسوية</button>' : ''}</div>
    <div class="grid cols-4" id="sum"></div>
    <div class="card no-print" style="margin:12px 0;display:flex;gap:8px;flex-wrap:wrap;align-items:center">${ed ? '<button class="btn sm" id="all">تأشير الكل</button><button class="btn sm" id="none">إلغاء الكل</button>' : ''}
      <input class="search" id="qq" placeholder="بحث بالمبلغ أو البيان…" style="flex:1;min-width:200px"></div>
    <div class="card table-wrap"><table class="t"><thead><tr><th style="width:40px">✓</th><th>التاريخ</th><th>السند</th><th>البيان</th><th>المرجع</th><th>مدين (إيداع)</th><th>دائن (سحب)</th></tr></thead><tbody id="rows"></tbody></table></div>`;
  const sum = () => {
    const unc = lines.filter(l => !sel.has(l.line_id));
    const dep = unc.reduce((s, l) => s + num(l.debit), 0), wd = unc.reduce((s, l) => s + num(l.credit), 0);
    const expected = book - dep + wd, diff = Math.round((num(rc.statement_balance) - expected) * 1000) / 1000;
    v.querySelector('#sum').innerHTML = `
      <div class="card stat"><span class="k">رصيد الدفاتر ${fmtDate(rc.statement_date)}</span><span class="v" dir="ltr">${fmtNum(book)}</span></div>
      <div class="card stat"><span class="k">إيداعات بالطريق (مش بالكشف)</span><span class="v" dir="ltr">${fmtNum(dep)}</span><span class="muted">− من الدفاتر</span></div>
      <div class="card stat"><span class="k">شيكات/سحوبات ما ظهرت بالكشف</span><span class="v" dir="ltr">${fmtNum(wd)}</span><span class="muted">+ للدفاتر</span></div>
      <div class="card stat"><span class="k">الرصيد المتوقع بالكشف / الفعلي</span><span class="v" dir="ltr">${fmtNum(expected)}</span>
        <span style="font-weight:700;color:${diff ? 'var(--bad)' : 'var(--ok)'}">${diff ? 'الفرق: ' + fmtNum(diff) : '✓ مطابق لكشف البنك (' + fmtNum(rc.statement_balance) + ')'}</span></div>`;
    return { dep, wd, expected, diff, unc };
  };
  const draw = () => {
    const qq = (v.querySelector('#qq').value || '').trim();
    v.querySelector('#rows').innerHTML = lines.filter(l => !qq || `${l.description} ${l.reference} ${num(l.debit)} ${num(l.credit)}`.includes(qq)).map(l => `<tr style="${sel.has(l.line_id) ? 'background:#f0fdf4' : ''}">
      <td><input type="checkbox" data-l="${l.line_id}" ${sel.has(l.line_id) ? 'checked' : ''} ${ed ? '' : 'disabled'} style="width:18px;height:18px;accent-color:var(--brand)"></td>
      <td>${fmtDate(l.entry_date)}</td><td>${esc(ENTRY_TYPES[l.entry_type]?.label || '')} ${esc(docNo(l))}</td><td>${esc(l.description || '')}</td><td>${esc(l.reference || '')}</td>
      <td class="n">${num(l.debit) ? fmtNum(l.debit) : ''}</td><td class="n">${num(l.credit) ? fmtNum(l.credit) : ''}</td></tr>`).join('') || '<tr><td colspan="7" class="empty">ما في حركات</td></tr>';
    sum();
  };
  draw();
  v.querySelector('#qq').oninput = draw;
  const setMany = async (ids, on) => {
    if (on) { const r = await sb.from('bank_cleared').upsert(ids.map(x => ({ line_id: x, recon_id: id, company_id: S.company.id }))); if (r.error) return toast(arError(r.error), 'err'); ids.forEach(x => sel.add(x)); }
    else { const r = await sb.from('bank_cleared').delete().eq('recon_id', id).in('line_id', ids); if (r.error) return toast(arError(r.error), 'err'); ids.forEach(x => sel.delete(x)); }
    draw();
  };
  v.querySelector('#rows').onchange = (e) => { const c = e.target.closest('[data-l]'); if (c) setMany([c.dataset.l], c.checked); };
  v.querySelector('#all')?.addEventListener('click', () => setMany(lines.filter(l => !sel.has(l.line_id)).map(l => l.line_id), true));
  v.querySelector('#none')?.addEventListener('click', () => setMany([...sel], false));
  v.querySelector('#fin')?.addEventListener('click', async () => {
    const s = sum(); if (s.diff && !(await confirmBox(`في فرق ${fmtNum(s.diff)} مع كشف البنك. بدك تقفل التسوية هيك؟`))) return;
    const { error: er } = await sb.from('bank_recons').update({ status: 'done' }).eq('id', id); if (er) return toast(arError(er), 'err'); toast('انقفلت التسوية', 'ok'); ctx.rerender();
  });
  v.querySelector('#reopen')?.addEventListener('click', async () => { const { error: er } = await sb.from('bank_recons').update({ status: 'open' }).eq('id', id); if (er) return toast(arError(er), 'err'); ctx.rerender(); });
  v.querySelector('#prn').onclick = () => { const s = sum();
    printDoc(`مذكرة تسوية بنكية: ${accLabel(acc)}`, `<table class="pt"><tr><td>الرصيد حسب الدفاتر</td><td class="n">${fmtNum(book)}</td></tr>
      <tr><td>يطرح: إيداعات بالطريق</td><td class="n">(${fmtNum(s.dep)})</td></tr><tr><td>يضاف: شيكات وسحوبات لم تظهر بالكشف</td><td class="n">${fmtNum(s.wd)}</td></tr>
      <tr class="tot"><td>الرصيد المعدّل</td><td class="n">${fmtNum(s.expected)}</td></tr><tr><td>الرصيد حسب كشف البنك</td><td class="n">${fmtNum(rc.statement_balance)}</td></tr>
      <tr class="tot"><td>الفرق</td><td class="n">${fmtNum(s.diff)}</td></tr></table>
      <h3 class="sec">الحركات المعلّقة</h3><table class="pt"><thead><tr><th>التاريخ</th><th>البيان</th><th>المرجع</th><th>إيداع</th><th>سحب</th></tr></thead><tbody>
      ${s.unc.map(l => `<tr><td>${fmtDate(l.entry_date)}</td><td>${esc(l.description || '')}</td><td>${esc(l.reference || '')}</td><td class="n">${num(l.debit) ? fmtNum(l.debit) : ''}</td><td class="n">${num(l.credit) ? fmtNum(l.credit) : ''}</td></tr>`).join('')}</tbody></table>`,
      { subtitle: `كما في ${fmtDate(rc.statement_date)}`, kind: 'journal' }); };
}

export const EXTRA_ROUTES = { 'pending': viewPending, 'recurring': viewRecurring, 'cost-centers': viewCostCenters, 'rep-cc': viewRepCC, 'rep-fx': viewRepFX, 'bank-recon': viewBankRecons };
