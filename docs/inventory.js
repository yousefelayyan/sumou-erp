import { attachFollow } from './follow.js';
// =====================================================================
//  السمو ERP — المخزون والجرد
// =====================================================================
import { attachAudit } from './audit.js';
import { docTypeField, docTypeValue, docCopies, docTypeName, loadDocTypes, docCommittee } from './doctypes.js';
import { attachDocNav, setNavList } from './docnav.js';
import { deptField, deptValue } from './departments.js';
import { docNo, loadNumbering, isManual, manualField, readManual, masterCode } from './numbering.js';
import { loadPosting, postFlag, postBarHTML, wirePostBar } from './posting.js';
import { S, sb, esc, fmtDate, fmtNum, num, today, toast, arError, modal, confirmBox, formData, can, log, fmtQty, fmtPrice } from './core.js';
import { downloadCSV, loadAccounts, leafAccounts, accLabel } from './finance.js';
import { loadItems, serialCellHTML, serialPicker, parseSerials } from './invoices.js';
import { printDoc } from './print.js';
import { openAttachments } from './attach.js';

const DOC = {
  in:       { label: 'سند إدخال', icon: '📥' },
  out:      { label: 'سند إخراج', icon: '📤' },
  transfer: { label: 'سند تحويل بين المستودعات', icon: '🔁' },
  count:    { label: 'جرد وتسوية', icon: '📋' },
};
const itemLabel = (i) => i ? `${i.code} — ${i.name}` : '';
const resolveItem = (items, t) => { t = (t || '').trim(); if (!t) return null; const c = t.split('—')[0].trim(); return items.find(i => i.code === c) || items.find(i => i.name === t || i.barcode === t) || items.find(i => (i.barcodes || []).some(b => b.barcode === t)) || null; };

export async function loadWarehouses() {
  if (!S.company) return [];
  const { data } = await sb.from('warehouses').select('*').eq('company_id', S.company.id).order('code');
  if (!data?.length && can('inventory', 'view')) {
    const r = await sb.rpc('default_warehouse', { p_company: S.company.id });
    if (!r.error) { const again = await sb.from('warehouses').select('*').eq('company_id', S.company.id).order('code'); return again.data || []; }
  }
  return data || [];
}

// ---------------------------------------------------------------------
//  رصيد المخزون
// ---------------------------------------------------------------------
async function viewStock(v) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const [items, whs] = await Promise.all([loadItems(true), loadWarehouses()]);
  v.innerHTML = `<div class="page-head"><h2>📦 رصيد المخزون</h2><div class="spacer"></div>
      ${can('inventory', 'add') ? Object.entries(DOC).map(([k, d]) => `<a class="btn ${k === 'count' ? '' : 'sm'}" href="#/stock-docs?type=${k}">${d.icon} ${d.label}</a>`).join(' ') : ''}</div>
    <div class="card no-print filters">
      <div class="field"><label>المستودع</label><select id="f-w"><option value="">كل المستودعات</option>${whs.map(w => `<option value="${w.id}">${esc(w.name)}</option>`).join('')}</select></div>
      <div class="field"><label>كما في تاريخ</label><input type="date" id="f-d" value="${today()}"></div>
      <div class="field"><label>بحث</label><input id="f-q" placeholder="الصنف…"></div>
      <div class="field" style="justify-content:flex-end"><button class="btn primary" id="run">عرض</button></div>
      <div class="field" style="justify-content:flex-end;flex-direction:row;gap:6px"><button class="btn" id="prn">🖨️ طباعة</button><button class="btn" id="csv">⬇️ Excel</button></div></div>
    <div id="out"></div>
    <p class="muted" style="font-size:13px">الكميات من الفواتير المرحّلة وسندات المخزون. الكلفة = متوسط كلفة الوارد. محاسبياً المشتريات بتنقيّد مصروف، وقيمة المخزون آخر السنة بتاخذها من هالتقرير لقيد التسوية.</p>`;
  let last = null;
  const run = async () => {
    const w = v.querySelector('#f-w').value || null, d = v.querySelector('#f-d').value, q = v.querySelector('#f-q').value.trim().toLowerCase();
    const { data, error } = await sb.rpc('rep_stock_balance', { p_company: S.company.id, p_date: d, p_wh: w });
    if (error) return void (v.querySelector('#out').innerHTML = `<div class="notice">${esc(arError(error))}</div>`);
    const it = Object.fromEntries(items.map(i => [i.id, i])), wn = Object.fromEntries(whs.map(x => [x.id, x.name]));
    const rows = data.filter(r => !q || itemLabel(it[r.item_id]).toLowerCase().includes(q)).sort((a, b) => (it[a.item_id]?.code || '').localeCompare(it[b.item_id]?.code || '', 'en', { numeric: true }));
    const tv = rows.reduce((s, r) => s + num(r.value), 0);
    const table = `<table class="t pt rep"><thead><tr><th>الصنف</th><th>المستودع</th><th>الوحدة</th><th>الكمية</th><th>متوسط الكلفة</th><th>القيمة</th><th class="no-print"></th></tr></thead><tbody>
      ${rows.map(r => `<tr><td>${esc(itemLabel(it[r.item_id]))}</td><td>${esc(wn[r.warehouse_id] || '')}</td><td>${esc(it[r.item_id]?.unit || '')}</td>
        <td class="n" style="${num(r.qty) < 0 ? 'color:var(--bad);font-weight:700' : ''}">${fmtQty(r.qty)}</td><td class="n">${fmtNum(r.avg_cost)}</td><td class="n">${fmtNum(r.value)}</td>
        <td class="no-print"><a class="btn sm" href="#/item-card?item=${r.item_id}">بطاقة الصنف</a></td></tr>`).join('') || '<tr><td colspan="7" class="empty">ما في أرصدة مخزون</td></tr>'}</tbody>
      <tfoot><tr class="tot"><td colspan="5">إجمالي قيمة المخزون</td><td class="n">${fmtNum(tv)}</td><td class="no-print"></td></tr></tfoot></table>`;
    v.querySelector('#out').innerHTML = `<div class="card table-wrap" style="margin-top:12px">${table}</div>`;
    last = { d, table, rows, it, wn };
  };
  v.querySelector('#run').onclick = run; v.querySelector('#f-q').oninput = run; v.querySelector('#f-w').onchange = run;
  v.querySelector('#prn').onclick = () => last && printDoc('رصيد المخزون', last.table.replace(/<th class="no-print"><\/th>/, '').replace(/<td class="no-print">.*?<\/td>/g, ''), { subtitle: `كما في ${fmtDate(last.d)}` });
  v.querySelector('#csv').onclick = () => last && downloadCSV('رصيد المخزون.csv', [['الرقم', 'الصنف', 'المستودع', 'الكمية', 'متوسط الكلفة', 'القيمة']]
    .concat(last.rows.map(r => [last.it[r.item_id]?.code, last.it[r.item_id]?.name, last.wn[r.warehouse_id], num(r.qty).toFixed(3), num(r.avg_cost).toFixed(3), num(r.value).toFixed(3)])));
  run();
}

// ---------------------------------------------------------------------
//  بطاقة الصنف
// ---------------------------------------------------------------------
async function viewItemCard(v) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const [items, whs] = await Promise.all([loadItems(), loadWarehouses()]);
  const pre = items.find(i => i.id === new URLSearchParams(location.hash.split('?')[1] || '').get('item'));
  const y0 = S.fy?.start_date || `${new Date().getFullYear()}-01-01`;
  v.innerHTML = `<div class="page-head"><h2>🗂️ بطاقة صنف</h2></div>
    <div class="card no-print filters">
      <div class="field" style="min-width:260px;flex:1"><label>الصنف</label><input list="itm" id="f-i" value="${esc(itemLabel(pre))}"><datalist id="itm">${items.filter(i => i.item_type === 'goods').map(i => `<option value="${esc(itemLabel(i))}"></option>`).join('')}</datalist></div>
      <div class="field"><label>المستودع</label><select id="f-w"><option value="">الكل</option>${whs.map(w => `<option value="${w.id}">${esc(w.name)}</option>`).join('')}</select></div>
      <div class="field"><label>من</label><input type="date" id="f-from" value="${y0}"></div><div class="field"><label>إلى</label><input type="date" id="f-to" value="${today()}"></div>
      <div class="field" style="justify-content:flex-end"><button class="btn primary" id="run">عرض</button></div>
      <div class="field" style="justify-content:flex-end"><button class="btn" id="prn">🖨️ طباعة</button></div></div><div id="out"></div>`;
  let last = null;
  const run = async () => {
    const it = resolveItem(items, v.querySelector('#f-i').value); if (!it) return toast('اختار صنف من القائمة', 'err');
    const from = v.querySelector('#f-from').value, to = v.querySelector('#f-to').value;
    const { data, error } = await sb.rpc('rep_item_card', { p_company: S.company.id, p_item: it.id, p_from: from, p_to: to, p_wh: v.querySelector('#f-w').value || null });
    if (error) return void (v.querySelector('#out').innerHTML = `<div class="notice">${esc(arError(error))}</div>`);
    const wn = Object.fromEntries(whs.map(x => [x.id, x.name]));
    const ob = num(data.find(r => !r.move_date)?.opening); let bal = ob; const mv = data.filter(r => r.move_date); let tin = 0, tout = 0;
    const table = `<table class="t pt rep"><thead><tr><th>التاريخ</th><th>البيان</th><th>المستودع</th><th>وارد</th><th>صادر</th><th>الرصيد</th><th>الكلفة</th></tr></thead><tbody>
      <tr class="grp"><td>${fmtDate(from)}</td><td colspan="4">رصيد أول المدة</td><td class="n">${fmtNum(ob)}</td><td></td></tr>
      ${mv.map(m => { const q = num(m.qty); bal += q; if (q > 0) tin += q; else tout -= q;
        return `<tr><td>${fmtDate(m.move_date)}</td><td>${esc(m.description || '')}</td><td>${esc(wn[m.warehouse_id] || '')}</td><td class="n">${q > 0 ? fmtNum(q) : ''}</td><td class="n">${q < 0 ? fmtNum(-q) : ''}</td><td class="n">${fmtNum(bal)}</td><td class="n">${num(m.unit_cost) ? fmtPrice(m.unit_cost) : ''}</td></tr>`; }).join('')}</tbody>
      <tfoot><tr class="tot"><td colspan="3">المجموع</td><td class="n">${fmtNum(tin)}</td><td class="n">${fmtNum(tout)}</td><td class="n">${fmtNum(bal)}</td><td></td></tr></tfoot></table>`;
    v.querySelector('#out').innerHTML = `<div class="card table-wrap" style="margin-top:12px">${table}</div>`;
    last = { it, from, to, table };
  };
  v.querySelector('#run').onclick = run;
  v.querySelector('#prn').onclick = () => last && printDoc(`بطاقة صنف: ${itemLabel(last.it)}`, last.table, { subtitle: `من ${fmtDate(last.from)} إلى ${fmtDate(last.to)}` });
  if (pre) run();
}

// ---------------------------------------------------------------------
//  سندات المخزون
// ---------------------------------------------------------------------
async function viewStockDocs(v, ctx) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const type = new URLSearchParams(location.hash.split('?')[1] || '').get('type') || 'in';
  const D = DOC[type] || DOC.in;
  const [{ data, error }, whs] = await Promise.all([
    sb.from('stock_docs').select('*').eq('company_id', S.company.id).eq('doc_type', type).order('doc_date', { ascending: false }).order('doc_no', { ascending: false }).limit(2000), loadWarehouses()]);
  if (error) throw error;
  const wn = Object.fromEntries(whs.map(x => [x.id, x.name]));
  v.innerHTML = `<div class="page-head"><h2>${D.icon} ${D.label}</h2><span class="badge brand">${data.length}</span><div class="spacer"></div>
      <a class="btn sm" href="#/stock">📦 رصيد المخزون</a> <a class="btn sm" href="#/warehouses">🏬 المستودعات</a>
      ${can('inventory', 'add') ? `<button class="btn primary" id="add">➕ ${D.label} جديد</button>` : ''}</div>
    <div class="tabs">${Object.entries(DOC).map(([k, d]) => `<a class="tab ${k === type ? 'active' : ''}" href="#/stock-docs?type=${k}" style="text-decoration:none">${d.icon} ${d.label}</a>`).join('')}</div>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرقم</th><th>التاريخ</th><th>المستودع</th>${type === 'transfer' ? '<th>إلى</th>' : ''}<th>ملاحظات</th><th>الحالة</th></tr></thead>
      <tbody id="rows">${data.map(d => `<tr class="click" data-open="${d.id}"><td><b dir="ltr">${esc(docNo(d))}</b></td><td>${fmtDate(d.doc_date)}</td><td>${esc(wn[d.warehouse_id] || '')}</td>
        ${type === 'transfer' ? `<td>${esc(wn[d.to_warehouse_id] || '')}</td>` : ''}<td>${esc(d.notes || '')}</td>
        <td>${d.status === 'posted' ? '<span class="badge ok">مرحّل</span>' : '<span class="badge warn">مسودة</span>'}</td></tr>`).join('') || '<tr><td colspan="6" class="empty">ما في سندات</td></tr>'}</tbody></table></div>`;
  v.querySelector('#add')?.addEventListener('click', () => docEditor(type, null, whs, ctx));
  v.querySelector('#rows').onclick = (e) => { const r = e.target.closest('[data-open]'); if (r) { setNavList('sd:' + type, [...v.querySelectorAll('#rows [data-open]')].map(tr => data.find(x => x.id === tr.dataset.open)).filter(Boolean)); docEditor(type, data.find(x => x.id === r.dataset.open), whs, ctx); } };
}

async function docEditor(type, doc, whs, ctx) {
  const D = DOC[type], items = (await loadItems()).filter(i => i.item_type === 'goods');
  const st = (await sb.from('company_settings').select('perpetual_inventory,cogs_account_id').eq('company_id', S.company.id).maybeSingle()).data || {};
  const perp = !!st.perpetual_inventory && type !== 'transfer';
  const accs = perp ? leafAccounts(await loadAccounts()) : [];
  let lines = [];
  if (doc) { const r = await sb.from('stock_doc_lines').select('*').eq('doc_id', doc.id).order('line_no'); lines = r.data || []; }
  const byId = Object.fromEntries(items.map(i => [i.id, i]));
  const readOnly = (doc && doc.status === 'posted') || (doc ? !can('inventory', 'edit') : !can('inventory', 'add'));
  const ro = readOnly ? 'disabled' : '';
  const manual = await isManual('stock_' + type);
  await loadPosting();
  const K = 'stock_' + type;
  const bar = doc ? postBarHTML([
    postFlag(K, 'stock') || doc.status === 'posted' ? { key: 'stock', posted: doc.status === 'posted', canPost: doc.status === 'draft' && can('inventory', 'post') && postFlag(K, 'stock'),
      canUnpost: doc.status === 'posted' && !doc.entry_id && can('inventory', 'unpost'), note: doc.status === 'posted' && doc.entry_id && can('inventory', 'unpost') ? 'لإلغاء ترحيل المخزون ألغِ ترحيل المحاسبة أول' : '' } : null,
    postFlag(K, 'gl') || doc.entry_id ? { key: 'gl', posted: !!doc.entry_id, canPost: doc.status === 'posted' && !doc.entry_id && can('inventory', 'post') && postFlag(K, 'gl'),
      canUnpost: !!doc.entry_id && can('inventory', 'unpost'), note: doc.status !== 'posted' && !doc.entry_id ? 'بعد الترحيل للمخزون' : '' } : null]) : '';
  const d0 = doc || { doc_date: today(), warehouse_id: whs[0]?.id };
  let rows = lines.map(l => ({ item: itemLabel(byId[l.item_id]), qty: num(l.qty), counted: l.counted_qty == null ? '' : num(l.counted_qty), cost: num(l.unit_cost), batch: l.batch_no || '', exp: l.expiry_date || '', serials: (l.serials || []).join('\n') }));
  if (!rows.length) rows.push({ item: '', qty: 0, counted: '', cost: 0 });
  const isCount = type === 'count';
  const dept = await deptField(doc?.department_id, ro, !doc); const dtf = await docTypeField('stock_' + type, doc?.doc_type_id, ro);
  const m = modal({ title: doc ? `${D.label} رقم ${docNo(doc)}` : `${D.label} جديد`, body: `${bar}
    <form id="sd-form"><div class="grid cols-3">
      ${manualField(manual, doc?.doc_no, ro)}
      <div class="field"><label>التاريخ</label><input type="date" name="doc_date" value="${esc(d0.doc_date)}" ${ro}></div>
      <div class="field"><label>${type === 'transfer' ? 'من مستودع' : 'المستودع'}</label><select name="warehouse_id" ${ro}>${whs.map(w => `<option value="${w.id}" ${w.id === d0.warehouse_id ? 'selected' : ''}>${esc(w.name)}</option>`).join('')}</select></div>
      ${type === 'transfer' ? `<div class="field"><label>إلى مستودع</label><select name="to_warehouse_id" ${ro}><option value="">—</option>${whs.map(w => `<option value="${w.id}" ${w.id === d0.to_warehouse_id ? 'selected' : ''}>${esc(w.name)}</option>`).join('')}</select></div>` : '<div></div>'}
      ${dept}${dtf}
      ${perp ? `<div class="field" style="grid-column:span 3"><label>الحساب المقابل بالقيد (الجرد المستمر)</label><select name="account_id" ${ro}><option value="">— الافتراضي: ${esc(accs.find(a => a.id === st.cogs_account_id)?.name || 'كلفة البضاعة المباعة')} —</option>${accs.map(a => `<option value="${a.id}" ${a.id === d0.account_id ? 'selected' : ''}>${esc(accLabel(a))}</option>`).join('')}</select>
        <small class="muted">${type === 'in' ? 'مثلاً لبضاعة أول المدة اختار رأس المال أو الأرصدة الافتتاحية' : 'مثلاً مصروف تالف أو هدايا'}</small></div>` : ''}
      <div class="field" style="grid-column:span 3"><label>ملاحظات</label><input name="notes" value="${esc(d0.notes)}" ${ro}></div></div></form>
    <datalist id="sd-items">${items.filter(i => i.is_active).map(i => `<option value="${esc(itemLabel(i))}"></option>`).join('')}</datalist>
    ${isCount ? '<div class="notice info">اكتب الكمية الفعلية اللي عدّيتها. لما ترحّل، النظام بيحسب الفرق عن رصيد الدفاتر وبيعمل تسوية.</div>' : ''}
    <table class="t lines" id="sdl"><thead><tr><th>#</th><th style="min-width:240px">الصنف</th><th style="width:130px">${isCount ? 'الكمية الفعلية' : 'الكمية'}</th>${isCount && doc?.status === 'posted' ? '<th style="width:120px">التسوية</th>' : ''}<th style="width:130px">الكلفة للوحدة</th><th></th></tr></thead><tbody></tbody></table>
    ${!readOnly ? '<button class="btn sm" id="sd-add" type="button" style="margin-top:6px">➕ سطر</button>' : ''}`,
    foot: `${!readOnly ? '<button class="btn primary" data-save>💾 حفظ</button>' : ''}
      ${doc && can('inventory', 'print') ? '<button class="btn" data-print>🖨️ طباعة</button>' : ''}
      ${doc ? '<button class="btn" data-attach>📎 مرفقات</button>' : ''}
      ${doc?.status === 'draft' && can('inventory', 'delete') ? '<button class="btn danger" data-del style="margin-inline-start:auto">حذف</button>' : ''}
      <button class="btn" data-close>إغلاق</button>` });
  m.el.querySelector('.modal').style.maxWidth = '900px';
  const tb = m.el.querySelector('#sdl tbody');
  if (doc) { attachAudit(m.el, doc); attachFollow(m.el, 'stock_docs', doc, 'stock', 'inventory'); }
  attachDocNav(m, doc, { key: 'sd:' + type, open: (r) => docEditor(type, r, whs, ctx), onNew: can('inventory', 'add') ? () => docEditor(type, null, whs, ctx) : null, table: 'stock_docs', canFreeze: can('inventory', 'edit'), editable: !readOnly });
  // الدفعات (المرحلة 64): الإدخال بيكتب الدفعة وتاريخها، والإخراج/التحويل بيختار من أرصدة المستودع (فاضي = الأقرب انتهاء)، والجرد اختياري
  const inbound = type === 'in' || isCount;
  let bal = [];
  const loadBal = async () => { if (!items.some(x => x.batch_mode && x.batch_mode !== 'none')) return;
    const { data } = await sb.rpc('batch_balances', { p_company: S.company.id, p_warehouse: m.el.querySelector('[name=warehouse_id]').value || null, p_item: null, p_all: false });
    bal = (data || []).filter(x => x.batch_id); draw(); };
  const batchCell = (r, i) => { const it = resolveItem(items, r.item); if (!it || !it.batch_mode || it.batch_mode === 'none') return '';
    const opts = bal.filter(x => x.item_id === it.id);
    return `<div class="batch-cell"><span>🧪</span><input class="cell" data-i="${i}" data-k="batch" value="${esc(r.batch)}" list="sbl-${i}" placeholder="${inbound ? 'رقم الدفعة' : 'الدفعة (فاضي = الأقرب انتهاء)'}" ${ro}>
      <datalist id="sbl-${i}">${opts.map(x => `<option value="${esc(x.batch_no)}">${fmtQty(x.qty)}${x.expiry_date ? ' · ينتهي ' + fmtDate(x.expiry_date) : ''}</option>`).join('')}</datalist>
      ${inbound && it.batch_mode === 'expiry' ? `<input class="cell" type="date" data-i="${i}" data-k="exp" value="${esc(r.exp)}" title="تاريخ الانتهاء" ${ro}>` : ''}</div>`; };
  const draw = () => {
    tb.innerHTML = rows.map((r, i) => `<tr><td class="muted">${i + 1}</td>
      <td><input class="cell" list="sd-items" data-i="${i}" data-k="item" value="${esc(r.item)}" ${ro}>${batchCell(r, i)}${isCount ? '' : serialCellHTML(r, i, resolveItem(items, r.item), ro, type === 'in')}</td>
      <td><input class="cell n" data-i="${i}" data-k="${isCount ? 'counted' : 'qty'}" value="${isCount ? r.counted : (r.qty || '')}" inputmode="decimal" ${ro}></td>
      ${isCount && doc?.status === 'posted' ? `<td class="n" style="color:${r.qty < 0 ? 'var(--bad)' : 'var(--ok)'}">${r.qty ? fmtQty(r.qty) : '—'}</td>` : ''}
      <td><input class="cell n" data-i="${i}" data-k="cost" value="${r.cost || ''}" inputmode="decimal" ${ro}></td>
      <td>${!readOnly ? `<button class="x" type="button" data-rm="${i}">×</button>` : ''}</td></tr>`).join('');
  };
  draw(); loadBal(); m.el.querySelector('[name=warehouse_id]')?.addEventListener('change', loadBal);
  tb.addEventListener('input', (e) => { const t = e.target; if (t.dataset.k) rows[+t.dataset.i][t.dataset.k] = t.value;
    if (t.dataset.k === 'serials' || t.dataset.k === 'qty') { const c = tb.querySelector(`[data-scnt="${t.dataset.i}"]`); if (c) { const r = rows[+t.dataset.i], n = parseSerials(r.serials).length; c.textContent = `${n}/${fmtQty(num(r.qty))}`; c.className = n === num(r.qty) ? 'muted' : 'bad-txt'; } } });
  tb.addEventListener('click', async (e) => { const b = e.target.closest('[data-spick]'); if (!b) return; const r = rows[+b.dataset.spick], it = resolveItem(items, r.item); if (!it) return;
    const sel = await serialPicker(it, m.el.querySelector('[name=warehouse_id]').value || null, r.serials); if (!sel) return;
    r.serials = sel.join('\n'); if (num(r.qty) < sel.length) r.qty = sel.length; draw(); });
  tb.addEventListener('change', (e) => { const t = e.target; if (t.dataset.k !== 'item') return; const it = resolveItem(items, t.value); t.classList.toggle('bad', !!t.value && !it);
    if (it) { t.value = itemLabel(it); rows[+t.dataset.i].item = t.value; if (!num(rows[+t.dataset.i].cost)) rows[+t.dataset.i].cost = num(it.purchase_price); draw(); } });
  tb.addEventListener('click', (e) => { const b = e.target.closest('[data-rm]'); if (!b) return; rows.splice(+b.dataset.rm, 1); if (!rows.length) rows.push({ item: '', qty: 0, counted: '', cost: 0 }); draw(); });
  m.el.querySelector('#sd-add')?.addEventListener('click', () => { rows.push({ item: '', qty: 0, counted: '', cost: 0 }); draw(); });
  const save = async (post) => {
    const h = formData(m.el.querySelector('#sd-form'));
    if (!h.warehouse_id) return toast('اختار المستودع', 'err');
    const out = [];
    for (const [k, r] of rows.entries()) {
      if (!r.item) continue;
      const it = resolveItem(items, r.item); if (!it) return toast(`السطر ${k + 1}: الصنف مش موجود`, 'err');
      const bm = it.batch_mode && it.batch_mode !== 'none', bx = bm ? { batch_no: (r.batch || '').trim() || null, expiry_date: inbound && r.exp ? r.exp : null } : { batch_no: null, expiry_date: null };
      const sys = doc?.supply_request_id || doc?.production_id;
      if (bm && type === 'in' && !sys && !bx.batch_no) return toast(`السطر ${k + 1}: ${it.name} بده رقم دفعة`, 'err');
      if (bm && type === 'in' && !sys && it.batch_mode === 'expiry' && !bx.expiry_date) return toast(`السطر ${k + 1}: ${it.name} بده تاريخ انتهاء`, 'err');
      if (isCount) { if (r.counted === '' || num(r.counted) < 0) return toast(`السطر ${k + 1}: اكتب الكمية الفعلية`, 'err'); out.push({ item_id: it.id, counted_qty: num(r.counted), qty: 0, unit_cost: num(r.cost), ...bx }); }
      else { if (num(r.qty) <= 0) return toast(`السطر ${k + 1}: الكمية لازم تكون أكبر من صفر`, 'err');
        const sl = it.serial_tracked ? parseSerials(r.serials) : [];
        if (sl.length && sl.length !== num(r.qty)) return toast(`السطر ${k + 1}: ${it.name} — عدد السيريالات (${sl.length}) لازم يساوي الكمية`, 'err');
        out.push({ item_id: it.id, qty: num(r.qty), unit_cost: num(r.cost), ...bx, serials: sl.length ? sl : null }); }
    }
    if (!out.length) return toast('أضف صنف واحد على الأقل', 'err');
    const mn = readManual(m.el.querySelector('#sd-form'), manual);
    if (!mn.ok) return toast('الترقيم يدوي: اكتب رقم السند (رقم صحيح أكبر من صفر)', 'err');
    const btns = m.el.querySelectorAll('.modal-foot .btn'); btns.forEach(b => b.disabled = true);
    try {
      const header = { ...(mn.value ? { doc_no: mn.value } : {}), doc_date: h.doc_date, warehouse_id: h.warehouse_id, to_warehouse_id: type === 'transfer' ? h.to_warehouse_id : null, notes: h.notes, ...deptValue(m.el.querySelector('#sd-form')), ...docTypeValue(m.el.querySelector('#sd-form')), ...(perp ? { account_id: h.account_id } : {}) };
      let id = doc?.id;
      if (id) { const u = await sb.from('stock_docs').update(header).eq('id', id); if (u.error) throw u.error; const dl = await sb.from('stock_doc_lines').delete().eq('doc_id', id); if (dl.error) throw dl.error; }
      else { const ins = await sb.from('stock_docs').insert({ ...header, company_id: S.company.id, doc_type: type }).select().single(); if (ins.error) throw ins.error; id = ins.data.id; doc = ins.data; }
      const li = await sb.from('stock_doc_lines').insert(out.map((l, k) => ({ ...l, doc_id: id, line_no: k + 1 }))); if (li.error) throw li.error;
      if (post) { const p = await sb.rpc('post_stock_doc', { p_id: id }); if (p.error) { toast(arError(p.error), 'err'); return reopen(id); } toast('انحفظ وانرحّل للمخزون', 'ok'); }
      else toast('تم الحفظ', 'ok');
      reopen(id);
    } catch (err) { toast(arError(err), 'err'); btns.forEach(b => b.disabled = false); }
  };
  const reopen = async (id) => {
    m.close(); ctx.rerender();
    const { data } = await sb.from('stock_docs').select('*').eq('id', id).single();
    if (data) docEditor(type, data, whs, ctx);
  };
  m.el.querySelector('[data-save]')?.addEventListener('click', () => save(false));
  m.el.querySelector('[data-postdo=stock]')?.addEventListener('click', (ev) => { if (!readOnly) { ev.stopImmediatePropagation(); save(true); } });
  if (doc) wirePostBar(m.el, 'stock', doc.id, () => reopen(doc.id));
  m.el.querySelector('[data-del]')?.addEventListener('click', async () => {
    if (!(await confirmBox(`حذف ${D.label} رقم ${docNo(doc)}؟`))) return;
    const { error } = await sb.from('stock_docs').delete().eq('id', doc.id); if (error) return toast(arError(error), 'err'); toast('تم الحذف', 'ok'); m.close(); ctx.rerender();
  });
  m.el.querySelector('[data-attach]')?.addEventListener('click', () => openAttachments('stock_doc', doc.id, `${D.label} رقم ${docNo(doc)}`));
  m.el.querySelector('[data-print]')?.addEventListener('click', () => {
    const wn = Object.fromEntries(whs.map(x => [x.id, x.name]));
    printDoc(`${D.label} رقم ${docNo(doc)}`, `<table class="meta"><tr><td><b>التاريخ:</b> ${fmtDate(doc.doc_date)}</td><td><b>المستودع:</b> ${esc(wn[doc.warehouse_id] || '')}</td>${type === 'transfer' ? `<td><b>إلى:</b> ${esc(wn[doc.to_warehouse_id] || '')}</td>` : ''}</tr>
      ${doc.notes ? `<tr><td colspan="3"><b>ملاحظات:</b> ${esc(doc.notes)}</td></tr>` : ''}</table>
      <table class="pt" style="margin-top:10px"><thead><tr><th>#</th><th>الصنف</th><th>${isCount ? 'الفعلي' : 'الكمية'}</th>${isCount ? '<th>التسوية</th>' : ''}<th>الكلفة</th></tr></thead><tbody>
      ${lines.map((l, i) => `<tr><td>${i + 1}</td><td>${esc(itemLabel(byId[l.item_id]))}${l.batch_no ? `<br><small>دفعة ${esc(l.batch_no)}${l.expiry_date ? ' · ينتهي ' + fmtDate(l.expiry_date) : ''}</small>` : ''}</td><td class="n">${fmtQty(isCount ? l.counted_qty : l.qty)}</td>${isCount ? `<td class="n">${fmtQty(l.qty)}</td>` : ''}<td class="n">${fmtPrice(l.unit_cost)}</td></tr>`).join('')}</tbody></table>
${isCount && docCommittee(doc.doc_type_id) ? `<div style="margin-top:18px"><b>لجنة الجرد:</b><div class="signs">${docCommittee(doc.doc_type_id).split(/[،,]/).map(x => x.trim()).filter(Boolean).map(x => `<div>${esc(x)}</div>`).join('')}</div></div>` : ''}
`, { kind: 'stock', copies: docCopies(doc.doc_type_id) });
  });
}

// ---------------------------------------------------------------------
//  المستودعات
// ---------------------------------------------------------------------
async function viewWarehouses(v, ctx) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const [whs] = await Promise.all([loadWarehouses(), loadNumbering(true)]);
  v.innerHTML = `<div class="page-head"><h2>🏬 المستودعات</h2><div class="spacer"></div>${can('inventory', 'edit') ? '<button class="btn primary" id="add">➕ مستودع</button>' : ''}</div>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرقم</th><th>الاسم</th><th>الحالة</th><th></th></tr></thead><tbody>
    ${whs.map(w => `<tr><td>${esc(w.code)}</td><td><b>${esc(w.name)}</b></td><td>${w.is_active ? '<span class="badge ok">فعّال</span>' : '<span class="badge bad">موقوف</span>'}</td>
      <td class="actions">${can('inventory', 'edit') ? `<button class="btn sm" data-edit="${w.id}">تعديل</button>` : ''}</td></tr>`).join('')}</tbody></table></div>`;
  const open = (w) => {
    const isNew = !w; w = w || { code: masterCode('m_warehouse', whs.map(x => x.code)) ?? String(whs.length + 1), name: '', is_active: true };
    const m = modal({ title: isNew ? 'مستودع جديد' : 'تعديل مستودع', size: 'sm', body: `<form id="w-form">
      <div class="field"><label>الرقم</label><input name="code" value="${esc(w.code)}"></div><div class="field"><label>الاسم *</label><input name="name" value="${esc(w.name)}"></div>
      <label class="check"><input type="checkbox" name="is_active" ${w.is_active ? 'checked' : ''}> فعّال</label></form>`,
      foot: `<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>` });
    m.el.querySelector('[data-save]').onclick = async () => {
      const d = formData(m.el.querySelector('#w-form')); if (!d.name || !d.code) return toast('الرقم والاسم مطلوبين', 'err');
      const res = isNew ? await sb.from('warehouses').insert({ ...d, company_id: S.company.id }) : await sb.from('warehouses').update(d).eq('id', w.id);
      if (res.error) return toast(arError(res.error), 'err'); toast('تم الحفظ', 'ok'); m.close(); ctx.rerender();
    };
  };
  v.querySelector('#add')?.addEventListener('click', () => open(null));
  v.querySelector('tbody').onclick = (e) => { const b = e.target.closest('[data-edit]'); if (b) open(whs.find(w => w.id === b.dataset.edit)); };
}

export const INVENTORY_ROUTES = { 'stock': viewStock, 'item-card': viewItemCard, 'stock-docs': viewStockDocs, 'warehouses': viewWarehouses };
