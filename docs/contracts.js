// =====================================================================
//  السمو ERP — العقود والرسوم المتكررة (route contracts)
//  عقد على عميل بسطور زي الفاتورة، كل كم شهر وبيوم محدد. «توليد الفواتير المستحقة» = contract_generate (مسودة أو مرحّلة).
// =====================================================================
import { S, sb, esc, fmtDate, fmtNum, num, toast, arError, modal, confirmBox, can, today } from './core.js';
import { loadParties, partyLabel, partyDatalist, resolveParty } from './parties.js';
import { loadItems, openInvoiceById } from './invoices.js';
import { deptField, deptValue } from './departments.js';
import { repOptions } from './lookups.js';
import { printDoc, amountToWords } from './print.js';

const EVERY = { 1: 'شهري', 2: 'كل شهرين', 3: 'ربع سنوي (كل 3 شهور)', 4: 'كل 4 شهور', 6: 'نصف سنوي', 12: 'سنوي' };
const ST = { active: ['فعّال', 'ok'], paused: ['موقوف', 'warn'], ended: ['منتهي', 'bad'] };
const itemLabel = (i) => i ? `${i.code} — ${i.name}` : '';
const r3 = (x) => Math.round(x * 1000) / 1000;
const lineAmt = (l, inc) => { const b = num(l.qty) * num(l.unit_price) - num(l.discount); return r3(inc ? b : b * (1 + num(l.tax_rate) / 100)); };
const endOfMonth = (d) => { const [y, m] = d.split('-').map(Number), last = new Date(y, m, 0).getDate(); return `${y}-${String(m).padStart(2, '0')}-${String(last).padStart(2, '0')}`; };

const VARS = ['[الشركة]', '[العميل]', '[رقم العقد]', '[عنوان العقد]', '[التاريخ]', '[البداية]', '[النهاية]', '[الدورية]', '[يوم الفاتورة]', '[قيمة الفاتورة]', '[القيمة بالحروف]', '[القيمة السنوية]', '[جدول البنود]', '[ملاحظات]'];
const DEFAULT_TPL = `عقد تقديم خدمات

إنه في يوم [التاريخ] تم الاتفاق بين كل من:
الطرف الأول: [الشركة]
الطرف الثاني: [العميل]

البند الأول: موضوع العقد
يلتزم الطرف الأول بتقديم الخدمات التالية للطرف الثاني: [عنوان العقد].
[جدول البنود]

البند الثاني: مدة العقد
تبدأ مدة هذا العقد من [البداية] وتنتهي في [النهاية].

البند الثالث: الأتعاب وطريقة الدفع
يدفع الطرف الثاني للطرف الأول مبلغ [قيمة الفاتورة] دينار ([القيمة بالحروف]) [الدورية]، تستحق في اليوم [يوم الفاتورة] من الشهر، بمجموع سنوي [القيمة السنوية] دينار.

البند الرابع: أحكام عامة
يلتزم الطرفان بأحكام هذا العقد، وأي نزاع ينشأ عنه تختص به محاكم عمّان.

[ملاحظات]`;
const fmtPlain = (n) => (Math.round(num(n) * 1000) / 1000).toLocaleString('en-US', { minimumFractionDigits: 3, maximumFractionDigits: 3 });
function fillContract(text, c, party, lines) {
  const amt = (lines || []).reduce((s, l) => s + lineAmt(l, c.prices_include_tax), 0);
  const table = (lines || []).length ? `<table class="pt" style="margin:6px 0"><thead><tr><th>#</th><th>البند</th><th>الكمية</th><th>السعر</th><th>الخصم</th><th>الضريبة %</th><th>المجموع</th></tr></thead><tbody>
    ${lines.map((l, i) => `<tr><td>${i + 1}</td><td>${esc(l.description || l._name || '')}</td><td class="n">${num(l.qty)}</td><td class="n">${fmtNum(l.unit_price)}</td><td class="n">${num(l.discount) ? fmtNum(l.discount) : ''}</td><td class="n">${num(l.tax_rate)}</td><td class="n">${fmtNum(lineAmt(l, c.prices_include_tax))}</td></tr>`).join('')}</tbody></table>` : '';
  const map = { '[الشركة]': S.company?.name || '', '[العميل]': party?.name || '', '[رقم العقد]': String(c.contract_no || ''), '[عنوان العقد]': c.title || '',
    '[التاريخ]': fmtDate(today()), '[البداية]': fmtDate(c.start_date), '[النهاية]': c.end_date ? fmtDate(c.end_date) : 'حتى يتم إنهاؤه', '[الدورية]': (EVERY[c.every_months] || '').replace(/ \(.*\)/, ''),
    '[يوم الفاتورة]': String(c.day_of_month || ''), '[قيمة الفاتورة]': fmtPlain(amt), '[القيمة بالحروف]': amountToWords(amt), '[القيمة السنوية]': fmtPlain(amt * 12 / (c.every_months || 1)), '[ملاحظات]': c.notes || '' };
  let h = esc(text || '');
  for (const [k, val] of Object.entries(map)) h = h.split(esc(k)).join(esc(val));
  return h.split(esc('[جدول البنود]')).join(table).replace(/\n/g, '<br>');
}

async function viewTemplates(v) {
  const { data: rows, error } = await sb.from('contract_templates').select('*').eq('company_id', S.company.id).order('code');
  if (error) return void (v.innerHTML = `<div class="notice">${esc(arError(error))}</div>`);
  const ed = can('contracts', 'edit');
  v.innerHTML = `<div class="page-head"><h2>📝 قوالب العقود</h2><div class="spacer"></div><a class="btn" href="#/contracts">🔁 العقود</a>${ed ? '<button class="btn primary" data-new>➕ قالب جديد</button>' : ''}</div>
    <p class="muted">القالب هو نص العقد، والكلمات بين القوسين بتتعبّى لحالها من بيانات كل عقد: ${VARS.join(' ')}</p>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرمز</th><th>اسم القالب</th><th>الحالة</th><th></th></tr></thead><tbody>
    ${(rows || []).map(r => `<tr class="click" data-open="${r.id}"><td>${esc(r.code)}</td><td><b>${esc(r.name)}</b></td><td>${r.is_active ? '<span class="badge ok">فعّال</span>' : '<span class="badge">موقوف</span>'}</td><td></td></tr>`).join('') || '<tr><td colspan="4" class="empty">ما في قوالب — اعمل واحد وبيتعبّى بنموذج جاهز تعدّل عليه</td></tr>'}</tbody></table></div>`;
  const open = (r) => {
    const r0 = r || { code: String((rows || []).length + 1).padStart(2, '0'), name: '', body: DEFAULT_TPL, is_active: true };
    const dis = ed ? '' : 'disabled';
    const m = modal({ title: r ? `قالب ${r.code}` : 'قالب عقد جديد', body: `<form id="tf"><div class="grid cols-3">
        <div class="field"><label>الرمز</label><input name="code" value="${esc(r0.code)}" ${dis}></div>
        <div class="field" style="grid-column:span 2"><label>اسم القالب *</label><input name="name" value="${esc(r0.name)}" ${dis}></div></div>
        <div class="field"><label>نص العقد <small class="muted">— اضغط على كلمة لتنحط مكان المؤشر</small></label>
          <div style="display:flex;gap:4px;flex-wrap:wrap;margin-bottom:4px">${VARS.map(x => `<button type="button" class="btn sm" data-var="${esc(x)}" ${dis}>${esc(x)}</button>`).join('')}</div>
          <textarea name="body" rows="18" style="font-family:inherit;line-height:1.7" ${dis}>${esc(r0.body)}</textarea></div>
        <label class="check"><input type="checkbox" name="is_active" ${r0.is_active ? 'checked' : ''} ${dis}> فعّال</label></form>`,
      foot: `${ed ? '<button class="btn primary" data-save>💾 حفظ</button>' : ''}${r && ed ? '<button class="btn danger" data-del style="margin-inline-start:auto">حذف</button>' : ''}<button class="btn" data-close>إغلاق</button>` });
    m.el.querySelector('.modal').style.maxWidth = '900px';
    const f = m.el.querySelector('#tf');
    m.el.querySelectorAll('[data-var]').forEach(b => b.onclick = () => { const ta = f.body, p = ta.selectionStart ?? ta.value.length; ta.value = ta.value.slice(0, p) + b.dataset.var + ta.value.slice(ta.selectionEnd ?? p); ta.focus(); ta.selectionStart = ta.selectionEnd = p + b.dataset.var.length; });
    m.el.querySelector('[data-save]')?.addEventListener('click', async () => {
      const rec = { code: f.code.value.trim(), name: f.name.value.trim(), body: f.body.value, is_active: f.is_active.checked };
      if (!rec.code || !rec.name) return toast('الرمز والاسم مطلوبين', 'err');
      const res = r ? await sb.from('contract_templates').update(rec).eq('id', r.id) : await sb.from('contract_templates').insert({ ...rec, company_id: S.company.id });
      if (res.error) return toast(arError(res.error), 'err');
      toast('انحفظ القالب', 'ok'); m.close(); viewTemplates(v);
    });
    m.el.querySelector('[data-del]')?.addEventListener('click', async () => {
      if (!(await confirmBox(`حذف القالب «${r.name}»؟ العقود اللي عليه بتضل بنصها.`))) return;
      const { error: e2 } = await sb.from('contract_templates').delete().eq('id', r.id); if (e2) return toast(arError(e2), 'err'); m.close(); viewTemplates(v);
    });
  };
  v.querySelector('[data-new]')?.addEventListener('click', () => open(null));
  v.querySelector('tbody').addEventListener('click', (e) => { const tr = e.target.closest('[data-open]'); if (tr) open(rows.find(x => x.id === tr.dataset.open)); });
}

async function viewContracts(v, ctx) {
  if (!S.company) return void (v.innerHTML = '<div class="notice info">اختار شركة أول.</div>');
  if (new URLSearchParams(location.hash.split('?')[1] || '').get('t') === 'templates') return viewTemplates(v);
  const [{ data: rows, error }, , parties] = await Promise.all([
    sb.from('contracts').select('*').eq('company_id', S.company.id).order('contract_no'),
    Promise.resolve({ data: null }),
    loadParties()]);
  if (error) return void (v.innerHTML = `<div class="notice">${esc(arError(error))}</div>`);
  const ids = (rows || []).map(c => c.id), lines = [];
  for (let i = 0; i < ids.length; i += 150) { const { data: part } = await sb.from('contract_lines').select('contract_id,qty,unit_price,discount,tax_rate').in('contract_id', ids.slice(i, i + 150)).limit(1000); lines.push(...(part || [])); }
  const pById = Object.fromEntries(parties.map(p => [p.id, p]));
  const amt = {}; (rows || []).forEach(c => { amt[c.id] = (lines || []).filter(l => l.contract_id === c.id).reduce((s, l) => s + lineAmt(l, c.prices_include_tax), 0); });
  const until0 = endOfMonth(today());
  v.innerHTML = `<div class="page-head"><h2>🔁 العقود والرسوم المتكررة</h2><div class="spacer"></div>
      <a class="btn" href="#/contracts?t=templates">📝 قوالب العقود</a>${can('contracts', 'add') ? '<button class="btn primary" data-new>➕ عقد جديد</button>' : ''}</div>
    <div class="card" style="display:flex;gap:8px;flex-wrap:wrap;align-items:end;margin-bottom:10px">
      <div class="field" style="margin:0"><label>الحالة</label><select id="f-s"><option value="">الكل</option>${Object.entries(ST).map(([k, [l]]) => `<option value="${k}" ${k === 'active' ? 'selected' : ''}>${l}</option>`).join('')}</select></div>
      <div class="field" style="margin:0;flex:1;min-width:200px"><label>بحث</label><input id="f-q" placeholder="العميل أو العنوان"></div>
      ${can('contracts', 'add') && can('sales_invoices', 'add') ? `<div class="field" style="margin:0"><label>توليد الفواتير المستحقة لغاية</label><input type="date" id="g-until" value="${until0}"></div>
      <button class="btn primary" data-gen>⚙️ معاينة وتوليد</button>` : ''}</div>
    <div class="card table-wrap" id="tbl"></div>`;
  const draw = () => {
    const s = v.querySelector('#f-s').value, q = v.querySelector('#f-q').value.trim().toLowerCase();
    const list = (rows || []).filter(c => (!s || c.status === s) && (!q || `${pById[c.party_id]?.name || ''} ${c.title}`.toLowerCase().includes(q)));
    const due = (c) => c.status === 'active' && c.next_date <= today() && (!c.end_date || c.next_date <= c.end_date);
    const monthly = list.filter(c => c.status === 'active').reduce((a, c) => a + amt[c.id] / c.every_months, 0);
    v.querySelector('#tbl').innerHTML = `<table class="t"><thead><tr><th>الرقم</th><th>العميل</th><th>العقد</th><th>الدورية</th><th>من</th><th>إلى</th><th>الاستحقاق الجاي</th><th style="text-align:left">قيمة الفاتورة</th><th>ترحيل تلقائي</th><th>الحالة</th></tr></thead><tbody>
      ${list.map(c => `<tr class="click" data-open="${c.id}"><td><b>${c.contract_no}</b></td><td>${esc(pById[c.party_id]?.name || '')}</td><td>${esc(c.title)}</td>
        <td>${EVERY[c.every_months]} · يوم ${c.day_of_month}</td><td>${fmtDate(c.start_date)}</td><td>${c.end_date ? fmtDate(c.end_date) : '<span class="muted">مفتوح</span>'}</td>
        <td>${c.status === 'active' ? `${fmtDate(c.next_date)}${due(c) ? ' <span class="badge warn">مستحق</span>' : ''}` : '—'}</td>
        <td class="n"><b>${fmtNum(amt[c.id])}</b></td><td>${c.auto_post ? '✅' : ''}</td><td><span class="badge ${ST[c.status][1]}">${ST[c.status][0]}</span></td></tr>`).join('') || '<tr><td colspan="10" class="empty">ما في عقود</td></tr>'}</tbody>
      ${list.length ? `<tfoot><tr><th colspan="7">معدل الإيراد الشهري للعقود الفعّالة (شامل الضريبة)</th><th class="n">${fmtNum(monthly)}</th><th colspan="2"></th></tr></tfoot>` : ''}</table>`;
  };
  draw();
  ['#f-s', '#f-q'].forEach(s => v.querySelector(s).addEventListener('input', draw));
  v.querySelector('[data-new]')?.addEventListener('click', () => contractEditor(null, ctx, () => viewContracts(v, ctx)));
  v.querySelector('#tbl').addEventListener('click', (e) => { const tr = e.target.closest('[data-open]'); if (tr) contractEditor(rows.find(x => x.id === tr.dataset.open), ctx, () => viewContracts(v, ctx)); });
  v.querySelector('[data-gen]')?.addEventListener('click', () => generateDialog(v.querySelector('#g-until').value, pById, () => viewContracts(v, ctx)));
}

async function generateDialog(until, pById, done) {
  if (!until) return toast('اختار التاريخ', 'err');
  const { data, error } = await sb.rpc('contract_due', { p_company: S.company.id, p_until: until });
  if (error) return toast(arError(error), 'err');
  if (!data?.length) return toast('ما في استحقاقات لغاية هالتاريخ', 'ok');
  const ids = [...new Set(data.map(r => r.contract_id))];
  const m = modal({ title: `الفواتير المستحقة لغاية ${fmtDate(until)}`, body: `
    <div class="notice info" style="margin-bottom:10px">رح تنعمل فاتورة بيع آجلة لكل استحقاق. العقد اللي عليه «ترحيل تلقائي» بتترحّل فاتورته (إذا إلك صلاحية ترحيل)، والباقي بيضل مسودة. الاستحقاق اللي تاريخه بسنة مالية مغلقة أو مش موجودة بيتأجّل.</div>
    <div class="table-wrap"><table class="t"><thead><tr><th><input type="checkbox" id="g-all" checked></th><th>التاريخ</th><th>العقد</th><th>العميل</th><th style="text-align:left">المبلغ</th></tr></thead><tbody>
      ${data.map(r => `<tr><td><input type="checkbox" data-c="${r.contract_id}" checked></td><td>${fmtDate(r.due_date)}</td><td>${r.contract_no} — ${esc(r.title)}</td><td>${esc(pById[r.party_id]?.name || '')}</td><td class="n">${fmtNum(r.amount)}</td></tr>`).join('')}</tbody>
      <tfoot><tr><th colspan="4">المجموع (${data.length} فاتورة)</th><th class="n">${fmtNum(data.reduce((s, r) => s + num(r.amount), 0))}</th></tr></tfoot></table></div>
    <p class="muted" style="font-size:12.5px">الاختيار على مستوى العقد: إذا شلت العلامة عن سطر بيتشال كل استحقاقات نفس العقد.</p>`,
    foot: '<button class="btn primary" data-go>⚙️ توليد الفواتير</button><button class="btn" data-close>إغلاق</button>' });
  m.el.querySelector('.modal').style.maxWidth = '760px';
  const boxes = () => [...m.el.querySelectorAll('[data-c]')];
  m.el.querySelector('#g-all').addEventListener('change', (e) => boxes().forEach(b => b.checked = e.target.checked));
  m.el.addEventListener('change', (e) => { const b = e.target.closest('[data-c]'); if (b) boxes().filter(x => x.dataset.c === b.dataset.c).forEach(x => x.checked = b.checked); });
  m.el.querySelector('[data-go]').addEventListener('click', async (e) => {
    const sel = [...new Set(boxes().filter(b => b.checked).map(b => b.dataset.c))];
    if (!sel.length) return toast('اختار عقد واحد على الأقل', 'err');
    e.target.disabled = true;
    const { data: n, error: er } = await sb.rpc('contract_generate', { p_company: S.company.id, p_until: until, p_ids: sel.length === ids.length ? null : sel });
    e.target.disabled = false;
    if (er) return toast(arError(er), 'err');
    m.close(); genResult(n); done();
  });
}

function genResult(r) {
  const f = r?.failed || [];
  if (!f.length) return toast(r?.made ? `انعملت ${r.made} فاتورة${r.posted ? ` (ترحّل منها ${r.posted})` : ''}` : 'ما في شي مستحق', 'ok');
  modal({ title: 'نتيجة توليد الفواتير', body: `<p>انعملت <b>${num(r.made)}</b> فاتورة${r.posted ? ` (ترحّل منها ${r.posted})` : ''}.</p>
    <div class="notice" style="margin-bottom:8px">هالعقود ما طلعت فواتيرها، وما تغيّر فيها شي:</div>
    <div class="table-wrap"><table class="t"><thead><tr><th>العقد</th><th>السبب</th></tr></thead><tbody>
    ${f.map(x => `<tr><td>${x.contract_no} — ${esc(x.title)}</td><td>${esc(arError({ message: x.error }))}</td></tr>`).join('')}</tbody></table></div>`,
    foot: '<button class="btn" data-close>إغلاق</button>' });
}

async function contractEditor(c, ctx, done) {
  const { data: tpls } = await sb.from('contract_templates').select('id,code,name,body,is_active').eq('company_id', S.company.id).order('code');
  const [parties, items, { data: st }, ln, inv] = await Promise.all([loadParties(), loadItems(),
    sb.from('company_settings').select('default_tax_rate').eq('company_id', S.company.id).maybeSingle(),
    c ? sb.from('contract_lines').select('*').eq('contract_id', c.id).order('line_no') : { data: [] },
    c ? sb.from('invoices').select('id,inv_no,doc_code,inv_date,total,status,contract_period').eq('contract_id', c.id).order('inv_date', { ascending: false }).limit(200) : { data: [] }]);
  const cust = parties.filter(p => p.party_type === 'customer' && (p.is_active || p.id === c?.party_id));
  const act = items.filter(i => i.is_active || (ln.data || []).some(l => l.item_id === i.id));
  const ro = c ? !can('contracts', 'edit') : !can('contracts', 'add');
  const dis = ro ? 'disabled' : '';
  const c0 = c || { every_months: 1, day_of_month: 1, start_date: today(), status: 'active', auto_post: false, prices_include_tax: false };
  const p0 = parties.find(p => p.id === c0.party_id);
  const dept = await deptField(c?.department_id, dis, !c);
  const reps = repOptions(c0.sales_rep_id);
  const rate0 = num(st?.default_tax_rate ?? 16);
  const rowHTML = (l = {}) => `<tr>
    <td><input data-k="item" list="ct-items" value="${esc(itemLabel(items.find(i => i.id === l.item_id)))}" ${dis} style="min-width:180px"></td>
    <td><input data-k="desc" value="${esc(l.description || '')}" ${dis} style="min-width:160px"></td>
    <td><input data-k="qty" inputmode="decimal" value="${l.qty ?? 1}" ${dis} style="width:70px"></td>
    <td><input data-k="price" inputmode="decimal" value="${l.unit_price ?? ''}" ${dis} style="width:90px"></td>
    <td><input data-k="disc" inputmode="decimal" value="${num(l.discount) || ''}" ${dis} style="width:70px"></td>
    <td><input data-k="rate" inputmode="decimal" value="${l.tax_rate ?? rate0}" ${dis} style="width:60px"></td>
    <td class="n" data-k="tot"></td><td>${ro ? '' : '<button type="button" class="btn sm danger" data-rm>✕</button>'}</td></tr>`;
  const m = modal({ title: c ? `عقد رقم ${c.contract_no}` : 'عقد جديد', body: `
    <form id="cf"><div class="grid cols-3">
      <div class="field" style="grid-column:span 2"><label>العميل *</label><input id="cp" list="cp-list" value="${esc(p0 ? partyLabel(p0) : '')}" ${dis}>${partyDatalist(cust, 'cp-list')}</div>
      <div class="field"><label>الحالة</label><select name="status" ${dis}>${Object.entries(ST).map(([k, [l]]) => `<option value="${k}" ${k === c0.status ? 'selected' : ''}>${l}</option>`).join('')}</select></div>
      <div class="field" style="grid-column:span 3"><label>عنوان العقد * <small class="muted">(بينكتب بملاحظات الفاتورة)</small></label><input name="title" value="${esc(c0.title || '')}" placeholder="مثلاً: أتعاب مسك دفاتر شهرية" ${dis}></div>
      <div class="field"><label>الدورية</label><select name="every_months" ${dis}>${Object.entries(EVERY).map(([k, l]) => `<option value="${k}" ${+k === c0.every_months ? 'selected' : ''}>${l}</option>`).join('')}</select></div>
      <div class="field"><label>يوم الفاتورة بالشهر (1–28)</label><input name="day_of_month" type="number" min="1" max="28" value="${c0.day_of_month}" ${dis}></div>
      <div class="field"><label>الاستحقاق الجاي</label><input type="date" name="next_date" value="${esc(c0.next_date || '')}" ${dis}><small class="muted">فاضي = أول يوم فاتورة من بداية العقد</small></div>
      <div class="field"><label>بداية العقد *</label><input type="date" name="start_date" value="${esc(c0.start_date)}" ${dis}></div>
      <div class="field"><label>نهاية العقد</label><input type="date" name="end_date" value="${esc(c0.end_date || '')}" ${dis}><small class="muted">فاضي = مفتوح</small></div>
      <div class="field"><label>المندوب</label><select name="sales_rep_id" ${dis}><option value="">—</option>${reps}</select></div>
      <div class="field"><label><input type="checkbox" name="auto_post" ${c0.auto_post ? 'checked' : ''} ${dis}> ترحيل الفاتورة تلقائياً</label></div>
      <div class="field"><label><input type="checkbox" name="prices_include_tax" ${c0.prices_include_tax ? 'checked' : ''} ${dis}> الأسعار شاملة الضريبة</label></div>
      ${dept}
      <div class="field" style="grid-column:span 3"><label>ملاحظات</label><input name="notes" value="${esc(c0.notes || '')}" ${dis}></div></div>
      <details style="margin-top:8px" ${c0.terms ? 'open' : ''}><summary style="cursor:pointer;font-weight:700">📝 نص العقد (للطباعة)</summary>
        <div style="display:flex;gap:8px;align-items:end;margin:6px 0;flex-wrap:wrap"><div class="field" style="margin:0;min-width:220px"><label>القالب</label><select name="template_id" ${dis}><option value="">—</option>${(tpls || []).filter(t => t.is_active || t.id === c0.template_id).map(t => `<option value="${t.id}" ${t.id === c0.template_id ? 'selected' : ''}>${esc(t.code)} — ${esc(t.name)}</option>`).join('')}</select></div>
          ${ro ? '' : '<button type="button" class="btn sm" data-fill>⬇️ تعبئة من القالب</button>'}<a class="btn sm" href="#/contracts?t=templates">إدارة القوالب</a></div>
        <textarea name="terms" rows="10" style="font-family:inherit;line-height:1.7" placeholder="اختار قالب واضغط «تعبئة من القالب»، أو اكتب نص العقد هون. الكلمات بين القوسين بتتعبّى وقت الطباعة." ${dis}>${esc(c0.terms || '')}</textarea></details>
      <datalist id="ct-items">${act.map(i => `<option value="${esc(itemLabel(i))}"></option>`).join('')}</datalist>
      <h4 style="margin:12px 0 6px">سطور الفاتورة</h4>
      <div class="table-wrap"><table class="t" id="cl"><thead><tr><th>الصنف / الخدمة</th><th>البيان</th><th>الكمية</th><th>السعر</th><th>الخصم</th><th>الضريبة %</th><th style="text-align:left">المجموع</th><th></th></tr></thead>
        <tbody>${(ln.data || []).map(rowHTML).join('') || rowHTML()}</tbody>
        <tfoot><tr><th colspan="6">قيمة كل فاتورة (شامل الضريبة)</th><th class="n" id="cl-tot"></th><th></th></tr></tfoot></table></div>
      ${ro ? '' : '<button type="button" class="btn sm" data-add style="margin-top:6px">➕ سطر</button>'}
    </form>
    ${c ? `<h4 style="margin:14px 0 6px">الفواتير اللي طلعت من العقد (${(inv.data || []).length})</h4>
      <div class="table-wrap"><table class="t"><thead><tr><th>الفاتورة</th><th>التاريخ</th><th>الفترة</th><th style="text-align:left">المجموع</th><th>الحالة</th></tr></thead><tbody>
      ${(inv.data || []).map(i => `<tr class="click" data-inv="${i.id}"><td><b>${esc(i.doc_code || String(i.inv_no ?? ''))}</b></td><td>${fmtDate(i.inv_date)}</td><td>${esc(i.contract_period || '')}</td><td class="n">${fmtNum(i.total)}</td>
        <td><span class="badge ${i.status === 'posted' ? 'ok' : i.status === 'cancelled' ? 'bad' : 'warn'}">${i.status === 'posted' ? 'مرحّلة' : i.status === 'cancelled' ? 'ملغاة' : 'مسودة'}</span></td></tr>`).join('') || '<tr><td colspan="5" class="empty">لسا ما طلعت فواتير</td></tr>'}</tbody></table></div>` : ''}`,
    foot: `${!ro ? '<button class="btn primary" data-save>💾 حفظ</button>' : ''}
      ${c && can('contracts', 'print') ? '<button class="btn" data-print>🖨️ طباعة العقد</button>' : ''}
      ${c && c.status === 'active' && can('contracts', 'add') && can('sales_invoices', 'add') ? '<button class="btn" data-gen1>⚙️ توليد المستحق لهالعقد</button>' : ''}
      ${c && can('contracts', 'delete') && !(inv.data || []).length ? '<button class="btn danger" data-del style="margin-inline-start:auto">حذف</button>' : ''}
      <button class="btn" data-close>إغلاق</button>` });
  m.el.querySelector('.modal').style.maxWidth = '980px';
  let savedId = null;
  const f = m.el.querySelector('#cf'), tb = m.el.querySelector('#cl tbody');
  const val = (tr, k) => tr.querySelector(`[data-k=${k}]`).value;
  const recalc = () => {
    const inc = f.prices_include_tax.checked; let t = 0;
    tb.querySelectorAll('tr').forEach(tr => { const a = lineAmt({ qty: val(tr, 'qty'), unit_price: val(tr, 'price'), discount: val(tr, 'disc'), tax_rate: val(tr, 'rate') }, inc); t += a; tr.querySelector('[data-k=tot]').textContent = fmtNum(a); });
    m.el.querySelector('#cl-tot').textContent = fmtNum(t);
  };
  recalc();
  f.addEventListener('input', recalc);
  tb.addEventListener('change', (e) => {
    const inp = e.target.closest('[data-k=item]'); if (!inp) return;
    const it = act.find(i => itemLabel(i) === inp.value), tr = inp.closest('tr'); if (!it) return;
    if (!val(tr, 'price')) tr.querySelector('[data-k=price]').value = it.sale_price ?? '';
    if (it.tax_rate != null) tr.querySelector('[data-k=rate]').value = it.tax_rate;
    recalc();
  });
  tb.addEventListener('click', (e) => { if (e.target.closest('[data-rm]')) { e.target.closest('tr').remove(); if (!tb.children.length) tb.insertAdjacentHTML('beforeend', rowHTML()); recalc(); } });
  m.el.querySelector('[data-add]')?.addEventListener('click', () => { tb.insertAdjacentHTML('beforeend', rowHTML()); recalc(); });
  m.el.querySelector('[data-fill]')?.addEventListener('click', async () => {
    const t = (tpls || []).find(x => x.id === f.template_id.value); if (!t) return toast('اختار القالب أول', 'err');
    if (f.terms.value.trim() && !(await confirmBox('بدك تستبدل نص العقد الحالي بنص القالب؟'))) return;
    f.terms.value = t.body; f.dispatchEvent(new Event('input', { bubbles: true }));
  });
  m.el.querySelector('[data-print]')?.addEventListener('click', () => {
    const text = f.terms.value.trim() || (tpls || []).find(x => x.id === f.template_id.value)?.body || DEFAULT_TPL;
    const lines = [...tb.querySelectorAll('tr')].map(tr => { const it = act.find(i => itemLabel(i) === val(tr, 'item').trim());
      return { description: val(tr, 'desc').trim() || it?.name || '', qty: val(tr, 'qty'), unit_price: val(tr, 'price'), discount: val(tr, 'disc'), tax_rate: val(tr, 'rate') }; })
      .filter(l => l.description || num(l.unit_price));
    const cc = { ...c, every_months: +f.every_months.value, day_of_month: +f.day_of_month.value, start_date: f.start_date.value, end_date: f.end_date.value || null,
      title: f.title.value, notes: f.notes.value, prices_include_tax: f.prices_include_tax.checked };
    const party = resolveParty(cust, m.el.querySelector('#cp').value);
    printDoc(`عقد رقم ${c.contract_no}`, `<div style="font-size:14px;line-height:1.9">${fillContract(text, cc, party, lines)}</div>
      <table style="width:100%;margin-top:40px"><tr><td style="width:50%;text-align:center">الطرف الأول<br>${esc(S.company.name)}<br><br>التوقيع: ..................</td>
        <td style="text-align:center">الطرف الثاني<br>${esc(party?.name || '')}<br><br>التوقيع: ..................</td></tr></table>`, { subtitle: cc.title });
  });
  m.el.querySelectorAll('[data-inv]').forEach(tr => tr.addEventListener('click', () => openInvoiceById(tr.dataset.inv, ctx)));
  m.el.querySelector('[data-save]')?.addEventListener('click', async (e) => {
    const p = resolveParty(cust, m.el.querySelector('#cp').value); if (!p) return toast('اختار العميل من القائمة', 'err');
    if (!f.title.value.trim()) return toast('اكتب عنوان العقد', 'err');
    const lines = [];
    for (const tr of tb.querySelectorAll('tr')) {
      const iv = val(tr, 'item').trim(), it = act.find(i => itemLabel(i) === iv), desc = val(tr, 'desc').trim();
      if (!iv && !desc && !num(val(tr, 'price'))) continue;
      if (iv && !it) return toast('اختار الصنف من القائمة', 'err');
      if (num(val(tr, 'qty')) <= 0) return toast('الكمية لازم أكبر من صفر', 'err');
      if (num(val(tr, 'disc')) > num(val(tr, 'qty')) * num(val(tr, 'price'))) return toast('الخصم أكبر من قيمة السطر', 'err');
      lines.push({ line_no: lines.length + 1, item_id: it?.id || null, description: desc || null, qty: num(val(tr, 'qty')), unit_price: num(val(tr, 'price')), discount: num(val(tr, 'disc')), tax_rate: num(val(tr, 'rate')) });
    }
    if (!lines.length) return toast('ضيف سطر واحد على الأقل', 'err');
    const rec = { party_id: p.id, title: f.title.value.trim(), status: f.status.value, every_months: +f.every_months.value, day_of_month: Math.min(28, Math.max(1, +f.day_of_month.value || 1)),
      start_date: f.start_date.value, end_date: f.end_date.value || null, ...(f.next_date.value !== (c0.next_date || '') ? { next_date: f.next_date.value || null } : {}), sales_rep_id: f.sales_rep_id.value || null,
      auto_post: f.auto_post.checked, prices_include_tax: f.prices_include_tax.checked, notes: f.notes.value || null, ...deptValue(f),
      template_id: f.template_id.value || null, terms: f.terms.value.trim() ? f.terms.value : null };
    if (!rec.start_date) return toast('اختار بداية العقد', 'err');
    e.target.disabled = true;
    let id = c?.id || savedId;
    if (id) { const { error } = await sb.from('contracts').update(rec).eq('id', id); if (error) { e.target.disabled = false; return toast(arError(error), 'err'); } }
    else { const { data, error } = await sb.from('contracts').insert({ ...rec, company_id: S.company.id }).select('id').single(); if (error) { e.target.disabled = false; return toast(arError(error), 'err'); } id = savedId = data.id; }
    const d1 = await sb.from('contract_lines').delete().eq('contract_id', id);
    const d2 = d1.error ? d1 : await sb.from('contract_lines').insert(lines.map(l => ({ ...l, contract_id: id })));
    e.target.disabled = false;
    if (d2.error) return toast(arError(d2.error), 'err');
    toast('تم الحفظ', 'ok'); m.close(); done();
  });
  m.el.querySelector('[data-gen1]')?.addEventListener('click', async () => {
    const until = endOfMonth(today());
    if (!(await confirmBox(`توليد فواتير هالعقد المستحقة لغاية ${fmtDate(until)}؟`))) return;
    const { data: n, error } = await sb.rpc('contract_generate', { p_company: S.company.id, p_until: until, p_ids: [c.id] });
    if (error) return toast(arError(error), 'err');
    m.close(); genResult(n); done();
  });
  m.el.querySelector('[data-del]')?.addEventListener('click', async () => {
    if (!(await confirmBox(`حذف العقد رقم ${c.contract_no}؟`))) return;
    const { error } = await sb.from('contracts').delete().eq('id', c.id); if (error) return toast(arError(error), 'err');
    m.close(); done();
  });
}

export const CONTRACT_ROUTES = { contracts: viewContracts };
