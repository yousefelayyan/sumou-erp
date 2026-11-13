// =====================================================================
//  السمو ERP — طلبات المبيعات والتزويد، العروض الترويجية، بطاقات الولاء، الحقول الإضافية
// =====================================================================
import { S, sb, esc, toast, arError, can, modal, confirmBox, formData, fmtNum, fmtDate, num, today } from './core.js';
import { loadParties, partyDatalist, resolveParty, partyLabel } from './parties.js';
import { loadItems, openInvoicePrefill, bilingualDoc } from './invoices.js';
import { printDoc, amountToWords } from './print.js';
import { loadLookups, repOptions, hasReps } from './lookups.js';
import { downloadCSV } from './finance.js';
import { attachAudit } from './audit.js';

const r3 = (x) => Math.round(x * 1000) / 1000;
const amt = (x) => Math.abs(x) < 0.0005 ? '' : fmtNum(x);
const qs = () => new URLSearchParams(location.hash.split('?')[1] || '');
const itemLabel = (it) => it ? `${it.code} — ${it.name}` : '';
const resolveItem = (items, v) => { v = (v || '').trim(); if (!v) return null; return items.find(i => itemLabel(i) === v || i.code === v || i.name === v || i.barcode === v) || null; };

export const ORD = {
  sales_order:    { label: 'طلب مبيعات', plural: 'طلبات المبيعات', screen: 'sales_orders', partyType: 'customer', partyLabel: 'العميل', inv: 'sale', icon: '📝' },
  purchase_order: { label: 'طلب تزويد', plural: 'طلبات التزويد', screen: 'purchase_orders', partyType: 'supplier', partyLabel: 'المورد', inv: 'purchase', icon: '📋' },
};
const OST = { open: ['مفتوح', 'warn'], converted: ['تحوّل لفاتورة', 'ok'], cancelled: ['ملغى', 'bad'] };
const obadge = (s) => `<span class="badge ${OST[s][1]}">${OST[s][0]}</span>`;

async function viewOrders(v, ctx) {
  if (!S.company || !S.fy) return void (v.innerHTML = `<div class="notice info">اختار شركة وسنة مالية من فوق أول.</div>`);
  const type = ORD[qs().get('t')] ? qs().get('t') : 'sales_order', O = ORD[type];
  const [oR, parties] = await Promise.all([sb.from('orders').select('*').eq('company_id', S.company.id).eq('order_type', type).order('order_date', { ascending: false }).limit(3000), loadParties(), loadLookups()]);
  if (oR.error) throw oR.error;
  const pById = Object.fromEntries(parties.map(p => [p.id, p]));
  const rows = oR.data || [];
  v.innerHTML = `<div class="page-head"><h2>${O.icon} ${O.plural}</h2><span class="badge brand">${rows.length}</span><div class="spacer"></div>
      <select id="fs" style="width:auto"><option value="">كل الحالات</option><option value="open">مفتوح</option><option value="converted">تحوّل لفاتورة</option><option value="cancelled">ملغى</option></select>
      <input id="q" placeholder="بحث بالرقم أو الاسم…" style="width:220px">
      ${can(O.screen, 'add') ? `<button class="btn primary" id="add">➕ ${O.label} جديد</button>` : ''}</div>
    <p class="muted" style="font-size:13px">${type === 'sales_order' ? 'طلب العميل أو عرض السعر قبل الفاتورة. ما بيأثّر على الحسابات ولا المخزون، وبكبسة بيتحوّل لفاتورة بيع.' : 'طلب الشراء من المورد قبل ما توصل البضاعة. بكبسة بيتحوّل لفاتورة شراء.'}</p>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرقم</th><th>التاريخ</th><th>${O.partyLabel}</th><th>المرجع</th><th>صالح لغاية</th><th>الإجمالي</th><th>الحالة</th><th></th></tr></thead><tbody id="tb"></tbody></table></div>`;
  const draw = () => {
    const st = v.querySelector('#fs').value, q = v.querySelector('#q').value.trim().toLowerCase();
    const list = rows.filter(o => (!st || o.status === st) && (!q || [String(o.order_no), o.party_name, pById[o.party_id]?.name, o.reference].some(x => (x || '').toLowerCase().includes(q))));
    v.querySelector('#tb').innerHTML = list.map(o => `<tr class="clickable" data-open="${o.id}"><td><b>${o.order_no}</b></td><td>${fmtDate(o.order_date)}</td><td>${esc(pById[o.party_id]?.name || o.party_name || '')}</td>
      <td>${esc(o.reference || '')}</td><td>${o.valid_until ? fmtDate(o.valid_until) + (o.status === 'open' && o.valid_until < today() ? ' <span class="badge bad">منتهي</span>' : '') : ''}</td>
      <td class="n">${fmtNum(o.total)}</td><td>${obadge(o.status)}</td><td><button class="btn sm">فتح</button></td></tr>`).join('') || `<tr><td colspan="8" class="empty">ما في ${O.plural}</td></tr>`;
  };
  draw();
  v.querySelector('#fs').onchange = draw; v.querySelector('#q').oninput = draw;
  v.querySelector('#add')?.addEventListener('click', () => orderEditor(type, null, ctx));
  v.querySelector('#tb').onclick = (e) => { const tr = e.target.closest('[data-open]'); if (tr) orderEditor(type, rows.find(o => o.id === tr.dataset.open), ctx); };
}

function printOrder(type, ord, lines, party, items) {
  const O = ORD[type], itBy = Object.fromEntries(items.map(i => [i.id, i]));
  const ls = lines.map(l => ({ ...l, sub: r3(num(l.qty) * num(l.unit_price) - num(l.discount)) }));
  const sub = r3(ls.reduce((s, l) => s + l.sub, 0)), disc = r3(ls.reduce((s, l) => s + num(l.discount), 0)), tax = r3(ls.reduce((s, l) => s + r3(l.sub * num(l.tax_rate) / 100), 0));
  const en = type === 'sales_order' ? 'Sales Order' : 'Purchase Order';
  printDoc(`${O.label} رقم ${ord.order_no}`, (cfg) => cfg.invoice_layout === 'bilingual'
    ? bilingualDoc({ cfg, titleAr: O.label, titleEn: en, no: ord.order_no, date: ord.order_date, pay: '', orderNo: ord.reference || '', project: ord.project, party, partyName: party?.name || ord.party_name,
        lines: ls, sub, disc, tax, total: r3(sub + tax), notes: ord.notes, noLabel: ['رقم الطلب', 'Order No.'] })
    : `<table class="meta"><tr><td><b>الرقم:</b> ${ord.order_no}</td><td><b>التاريخ:</b> ${fmtDate(ord.order_date)}</td><td>${ord.valid_until ? `<b>صالح لغاية:</b> ${fmtDate(ord.valid_until)}` : ''}</td></tr>
        <tr><td colspan="2"><b>${O.partyLabel}:</b> ${esc(party?.name || ord.party_name || '')}</td><td>${ord.reference ? `<b>المرجع:</b> ${esc(ord.reference)}` : ''}</td></tr>${ord.project ? `<tr><td colspan="3"><b>المشروع:</b> ${esc(ord.project)}</td></tr>` : ''}</table>
      <table class="pt" style="margin-top:10px"><thead><tr><th>#</th><th>الصنف</th><th>البيان</th><th>الكمية</th><th>السعر</th><th>الخصم</th><th>المجموع</th></tr></thead><tbody>
      ${ls.map((l, i) => `<tr><td>${i + 1}</td><td>${esc(itBy[l.item_id]?.code || '')}</td><td>${esc(l.description || '')}${l.details ? `<div style="font-size:.9em;color:#444">${esc(l.details).replace(/\n/g, '<br>')}</div>` : ''}</td><td class="n">${num(l.qty)}</td><td class="n">${fmtNum(l.unit_price)}</td><td class="n">${num(l.discount) ? fmtNum(l.discount) : ''}</td><td class="n">${fmtNum(l.sub)}</td></tr>`).join('')}</tbody></table>
      <table class="pt" style="width:45%;margin:10px 0 0 auto;margin-inline-start:auto"><tr><td>قبل الضريبة</td><td class="n">${fmtNum(sub)}</td></tr><tr><td>الضريبة</td><td class="n">${fmtNum(tax)}</td></tr><tr class="tot"><td>الإجمالي</td><td class="n">${fmtNum(sub + tax)}</td></tr></table>
      <div class="amount-box">${amountToWords(sub + tax)}</div>${ord.notes ? `<p><b>ملاحظات:</b> ${esc(ord.notes)}</p>` : ''}`, { kind: 'invoice' });
}

async function orderEditor(type, ord, ctx) {
  const O = ORD[type];
  const [parties, items] = await Promise.all([loadParties(), loadItems(), loadLookups()]);
  const myParties = parties.filter(p => p.party_type === O.partyType && p.is_active), pById = Object.fromEntries(parties.map(p => [p.id, p])), itById = Object.fromEntries(items.map(i => [i.id, i]));
  let lines = [];
  if (ord) lines = (await sb.from('order_lines').select('*').eq('order_id', ord.id).order('line_no')).data || [];
  const ro = (ord && ord.status !== 'open') || (ord ? !can(O.screen, 'edit') : !can(O.screen, 'add')) ? 'disabled' : '';
  const o0 = ord || { order_date: today(), party_id: null, reference: '', notes: '' };
  let rows = lines.map(l => ({ item: itemLabel(itById[l.item_id]), desc: l.description || '', details: l.details || '', qty: num(l.qty), price: num(l.unit_price), disc: num(l.discount), rate: num(l.tax_rate) }));
  if (!rows.length) rows.push({ item: '', desc: '', qty: 1, price: 0, disc: 0, rate: 16 });
  const m = modal({ title: ord ? `${O.label} رقم ${ord.order_no}` : `${O.label} جديد`, body: `
    ${ord ? `<div style="margin:-6px 0 12px">${obadge(ord.status)}</div>` : ''}
    <form id="o-form"><div class="grid cols-3">
      <div class="field"><label>التاريخ *</label><input type="date" name="order_date" value="${esc(o0.order_date)}" ${ro}></div>
      <div class="field"><label>صالح لغاية</label><input type="date" name="valid_until" value="${esc(o0.valid_until || '')}" ${ro}></div>
      <div class="field"><label>المرجع</label><input name="reference" value="${esc(o0.reference || '')}" ${ro}></div>
      ${type === 'sales_order' ? `<div class="field"><label>المشروع</label><input name="project" value="${esc(o0.project || '')}" ${ro}></div>` : ''}
      <div class="field" style="grid-column:span 2"><label>${O.partyLabel}</label><input list="party-list" id="party" value="${esc(partyLabel(pById[o0.party_id]))}" placeholder="رقم أو اسم ${O.partyLabel}…" ${ro}>${partyDatalist(myParties)}</div>
      <div class="field"><label>الاسم (بدون بطاقة)</label><input name="party_name" value="${esc(o0.party_name || '')}" ${ro}></div>
      ${type === 'sales_order' && hasReps() ? `<div class="field"><label>المندوب</label><select name="sales_rep_id" ${ro}><option value="">—</option>${repOptions(o0.sales_rep_id)}</select></div>` : ''}
      <div class="field" style="grid-column:span 2"><label>ملاحظات</label><input name="notes" value="${esc(o0.notes || '')}" ${ro}></div>
    </div></form>
    <datalist id="item-list">${items.filter(i => i.is_active).map(i => `<option value="${esc(itemLabel(i))}">`).join('')}</datalist>
    <div class="table-wrap"><table class="t lines"><thead><tr><th>#</th><th>الصنف</th><th>البيان</th><th>الكمية</th><th>السعر</th><th>الخصم</th><th>الضريبة %</th><th>المجموع</th><th></th></tr></thead><tbody id="ol"></tbody></table></div>
    ${ro ? '' : '<button class="btn sm" id="add-line" type="button">➕ سطر</button>'}
    <div class="inv-totals"><div><span>قبل الضريبة</span><b id="t-sub" dir="ltr"></b></div><div><span>الضريبة</span><b id="t-tax" dir="ltr"></b></div><div><span>الإجمالي</span><b id="t-tot" dir="ltr"></b></div></div>
    <div id="o-audit"></div>`,
    foot: `${!ro ? '<button class="btn primary" data-save>💾 حفظ</button>' : ''}
      ${ord && ord.status === 'open' && can(INVSCR[O.inv], 'add') ? `<button class="btn" data-conv>🧾 تحويل لفاتورة ${O.inv === 'sale' ? 'بيع' : 'شراء'}</button>` : ''}
      ${ord && ord.status === 'converted' ? '<span class="muted">تحوّل لفاتورة — شوفها من شاشة الفواتير</span>' : ''}
      ${ord && ord.status === 'open' && can(O.screen, 'edit') ? '<button class="btn" data-cancelord>🚫 إلغاء الطلب</button>' : ''}
      ${ord && can(O.screen, 'print') ? '<button class="btn" data-print>🖨️ طباعة</button>' : ''}
      ${ord && ord.status === 'open' && can(O.screen, 'delete') ? '<button class="btn danger" data-del>حذف</button>' : ''}
      <button class="btn" data-close>إغلاق</button>` });
  m.el.querySelector('.modal').style.maxWidth = '1000px';
  const tb = m.el.querySelector('#ol');
  const calc = (r) => { const g = r3(num(r.qty) * num(r.price) - num(r.disc)); const t = r3(g * num(r.rate) / 100); return { g, t, tot: g + t }; };
  const totals = () => { let s = 0, t = 0; rows.forEach((r, i) => { const c = calc(r); s += c.g; t += c.t; const el = tb.querySelector(`[data-tot="${i}"]`); if (el) el.textContent = fmtNum(c.tot); });
    m.el.querySelector('#t-sub').textContent = fmtNum(s); m.el.querySelector('#t-tax').textContent = fmtNum(t); m.el.querySelector('#t-tot').textContent = fmtNum(s + t); };
  const draw = () => { tb.innerHTML = rows.map((r, i) => `<tr><td class="muted">${i + 1}</td>
      <td><input list="item-list" class="cell" data-i="${i}" data-k="item" value="${esc(r.item)}" ${ro}></td><td><input class="cell" data-i="${i}" data-k="desc" value="${esc(r.desc)}" ${ro}>${!ro || r.details ? `<textarea class="cell" data-i="${i}" data-k="details" rows="${Math.max(1, (r.details || '').split('\n').length)}" placeholder="تفاصيل (أسطر إضافية)" style="font-size:12px;resize:vertical;min-height:26px;margin-top:2px" ${ro}>${esc(r.details || '')}</textarea>` : ''}</td>
      ${['qty', 'price', 'disc', 'rate'].map(k => `<td><input class="cell n" dir="ltr" inputmode="decimal" data-i="${i}" data-k="${k}" value="${esc(r[k] || '')}" ${ro}></td>`).join('')}
      <td class="n" data-tot="${i}"></td><td>${ro ? '' : `<button class="btn sm" type="button" data-rm="${i}">✕</button>`}</td></tr>`).join(''); totals(); };
  draw();
  tb.addEventListener('input', (e) => { const t = e.target; if (!t.dataset.k) return; rows[+t.dataset.i][t.dataset.k] = t.value; totals(); });
  tb.addEventListener('change', (e) => { const t = e.target; if (t.dataset.k !== 'item') return; const it = resolveItem(items, t.value), r = rows[+t.dataset.i];
    t.classList.toggle('bad', !!t.value && !it);
    if (it) { r.item = itemLabel(it); r.desc = r.desc || it.name; r.price = num(type === 'sales_order' ? it.sale_price : it.purchase_price) || r.price; r.rate = num(it.tax_rate); draw(); } });
  tb.addEventListener('click', (e) => { const b = e.target.closest('[data-rm]'); if (!b) return; rows.splice(+b.dataset.rm, 1); if (!rows.length) rows.push({ item: '', desc: '', qty: 1, price: 0, disc: 0, rate: 16 }); draw(); });
  m.el.querySelector('#add-line')?.addEventListener('click', () => { rows.push({ item: '', desc: '', qty: 1, price: 0, disc: 0, rate: 16 }); draw(); });
  if (ord) attachAudit(m.el, ord);
  m.el.querySelector('[data-print]')?.addEventListener('click', () => printOrder(type, ord, lines, pById[ord.party_id], items));
  const collect = () => {
    const out = [];
    for (const [k, r] of rows.entries()) {
      if (!r.item && !r.desc && !num(r.price)) continue;
      const it = resolveItem(items, r.item); if (r.item && !it) { toast(`السطر ${k + 1}: الصنف مش موجود`, 'err'); return null; }
      if (num(r.qty) <= 0) { toast(`السطر ${k + 1}: الكمية لازم تكون أكبر من صفر`, 'err'); return null; }
      if (num(r.disc) > num(r.qty) * num(r.price)) { toast(`السطر ${k + 1}: الخصم أكبر من قيمة السطر`, 'err'); return null; }
      out.push({ item_id: it?.id || null, description: r.desc || it?.name || null, details: (r.details || '').trim() || null, qty: num(r.qty), unit_price: num(r.price), discount: num(r.disc), tax_rate: num(r.rate) });
    }
    if (!out.length) { toast('ضيف سطر واحد على الأقل', 'err'); return null; }
    return out;
  };
  m.el.querySelector('[data-save]')?.addEventListener('click', async (e) => {
    const h = formData(m.el.querySelector('#o-form')); const pv = m.el.querySelector('#party').value; const p = resolveParty(myParties, pv);
    if (pv && !p) return toast(`${O.partyLabel} مش موجود بالقائمة`, 'err');
    const out = collect(); if (!out) return;
    const header = { order_date: h.order_date, valid_until: h.valid_until || null, reference: h.reference || null, party_id: p?.id || null, party_name: h.party_name || p?.name || null, notes: h.notes || null, ...('project' in h ? { project: h.project || null } : {}),
      ...('sales_rep_id' in h ? { sales_rep_id: h.sales_rep_id || null } : {}) };
    e.target.disabled = true;
    try {
      let id = ord?.id;
      if (id) { const u = await sb.from('orders').update(header).eq('id', id); if (u.error) throw u.error; const d = await sb.from('order_lines').delete().eq('order_id', id); if (d.error) throw d.error; }
      else { const ins = await sb.from('orders').insert({ ...header, company_id: S.company.id, order_type: type }).select().single(); if (ins.error) throw ins.error; id = ins.data.id; }
      const li = await sb.from('order_lines').insert(out.map((l, k) => ({ ...l, order_id: id, line_no: k + 1 }))); if (li.error) throw li.error;
      toast('انحفظ', 'ok'); m.close(); ctx.rerender();
      const { data } = await sb.from('orders').select('*').eq('id', id).single(); if (data) orderEditor(type, data, ctx);
    } catch (err) { e.target.disabled = false; toast(arError(err), 'err'); }
  });
  m.el.querySelector('[data-conv]')?.addEventListener('click', async () => {
    const { data: cur } = await sb.from('orders').select('status').eq('id', ord.id).single();
    if (cur?.status !== 'open') { toast('الطلب مش مفتوح، يمكن حدا حوّله من قبل', 'err'); m.close(); return ctx.rerender(); }
    m.close();
    openInvoicePrefill(O.inv, { inv: { inv_type: O.inv, party_id: ord.party_id, party_name: ord.party_name, payment_type: 'credit', sales_rep_id: ord.sales_rep_id, notes: ord.notes, project: ord.project },
      lines, ref: `من ${O.label} رقم ${ord.order_no}${ord.reference ? ' — ' + ord.reference : ''}`,
      onSaved: async (invId) => { const { error } = await sb.rpc('link_order_invoice', { p_order: ord.id, p_invoice: invId }); if (error) toast(arError(error), 'err'); else toast('الطلب تحوّل لفاتورة', 'ok'); } }, ctx);
  });
  m.el.querySelector('[data-cancelord]')?.addEventListener('click', async () => {
    if (!(await confirmBox(`إلغاء ${O.label} رقم ${ord.order_no}؟`))) return;
    const { error } = await sb.from('orders').update({ status: 'cancelled' }).eq('id', ord.id); if (error) return toast(arError(error), 'err');
    toast('انلغى', 'ok'); m.close(); ctx.rerender();
  });
  m.el.querySelector('[data-del]')?.addEventListener('click', async () => {
    if (!(await confirmBox(`حذف ${O.label} رقم ${ord.order_no}؟`))) return;
    const { error } = await sb.from('orders').delete().eq('id', ord.id); if (error) return toast(arError(error), 'err');
    toast('انحذف', 'ok'); m.close(); ctx.rerender();
  });
}
const INVSCR = { sale: 'sales_invoices', purchase: 'purchase_invoices' };

// ---------------------------------------------------------------------
//  العروض الترويجية
// ---------------------------------------------------------------------
async function viewPromotions(v) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const [pR, items, cR] = await Promise.all([sb.from('promotions').select('*').eq('company_id', S.company.id).order('date_from', { ascending: false }), loadItems(),
    sb.from('item_categories').select('id,name').eq('company_id', S.company.id).order('code')]);
  if (pR.error) throw pR.error;
  const rows = pR.data || [], cats = cR.data || [], itById = Object.fromEntries(items.map(i => [i.id, i])), catById = Object.fromEntries(cats.map(c => [c.id, c]));
  const scope = (p) => p.item_id ? '🏷️ ' + esc(itById[p.item_id]?.name || '') : p.category_id ? '🗂️ فئة ' + esc(catById[p.category_id]?.name || '') : '🌐 كل الأصناف';
  const live = (p) => p.is_active && p.date_from <= today() && p.date_to >= today();
  const ed = can('marketing', 'edit');
  v.innerHTML = `<div class="page-head"><h2>📢 العروض الترويجية</h2><div class="spacer"></div>${ed ? '<button class="btn primary" id="add">➕ عرض جديد</button>' : ''}</div>
    <p class="muted" style="font-size:13px">العرض بيعطي خصم % لحاله بفاتورة البيع لما تختار الصنف، إذا تاريخ الفاتورة جوّا فترة العرض والكمية فوق الحد الأدنى. إذا في أكثر من عرض بياخذ الأكبر.</p>
    <div class="card table-wrap"><table class="t"><thead><tr><th>العرض</th><th>على</th><th>الخصم %</th><th>من</th><th>إلى</th><th>أقل كمية</th><th>الحالة</th><th></th></tr></thead>
      <tbody>${rows.map(p => `<tr><td><b>${esc(p.name)}</b></td><td>${scope(p)}</td><td class="n">${num(p.discount_pct)}</td><td>${fmtDate(p.date_from)}</td><td>${fmtDate(p.date_to)}</td><td class="n">${num(p.min_qty) || ''}</td>
        <td>${live(p) ? '<span class="badge ok">شغّال</span>' : p.date_to < today() ? '<span class="badge">منتهي</span>' : p.is_active ? '<span class="badge warn">لسا ما بلّش</span>' : '<span class="badge">موقوف</span>'}</td>
        <td class="actions">${ed ? `<button class="btn sm" data-edit="${p.id}">تعديل</button><button class="btn sm danger" data-del="${p.id}">حذف</button>` : ''}</td></tr>`).join('') || '<tr><td colspan="8" class="empty">ما في عروض</td></tr>'}</tbody></table></div>`;
  const open = (p) => {
    p = p || { name: '', date_from: today(), date_to: today(), discount_pct: 10, min_qty: 0, is_active: true };
    const kind = p.item_id ? 'item' : p.category_id ? 'cat' : 'all';
    const m = modal({ title: p.id ? '✏️ تعديل عرض' : '➕ عرض جديد', size: 'sm', body: `<form id="pf">
      <div class="field"><label>اسم العرض *</label><input name="name" value="${esc(p.name)}"></div>
      <div class="field"><label>العرض على</label><select name="kind"><option value="all" ${kind === 'all' ? 'selected' : ''}>كل الأصناف</option><option value="cat" ${kind === 'cat' ? 'selected' : ''}>فئة مواد</option><option value="item" ${kind === 'item' ? 'selected' : ''}>صنف واحد</option></select></div>
      <div class="field" data-w="cat"><label>الفئة</label><select name="category_id">${cats.map(c => `<option value="${c.id}" ${c.id === p.category_id ? 'selected' : ''}>${esc(c.name)}</option>`).join('')}</select></div>
      <div class="field" data-w="item"><label>الصنف</label><select name="item_id">${items.filter(i => i.is_active || i.id === p.item_id).map(i => `<option value="${i.id}" ${i.id === p.item_id ? 'selected' : ''}>${esc(itemLabel(i))}</option>`).join('')}</select></div>
      <div class="grid cols-2"><div class="field"><label>من *</label><input type="date" name="date_from" value="${esc(p.date_from)}"></div><div class="field"><label>إلى *</label><input type="date" name="date_to" value="${esc(p.date_to)}"></div></div>
      <div class="grid cols-2"><div class="field"><label>الخصم % *</label><input name="discount_pct" dir="ltr" value="${num(p.discount_pct)}"></div><div class="field"><label>أقل كمية</label><input name="min_qty" dir="ltr" value="${num(p.min_qty) || ''}"></div></div>
      <label class="check"><input type="checkbox" name="is_active" ${p.is_active ? 'checked' : ''}> فعّال</label></form>`,
      foot: '<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>' });
    const f = m.el.querySelector('#pf'); const sync = () => m.el.querySelectorAll('[data-w]').forEach(x => x.style.display = x.dataset.w === f.kind.value ? '' : 'none'); f.kind.onchange = sync; sync();
    m.el.querySelector('[data-save]').onclick = async () => {
      const d = formData(f);
      if (!d.name?.trim()) return toast('اكتب اسم العرض', 'err');
      if (!(num(d.discount_pct) > 0 && num(d.discount_pct) <= 100)) return toast('الخصم لازم بين 0 و100', 'err');
      if (d.date_to < d.date_from) return toast('تاريخ النهاية قبل البداية', 'err');
      const rec = { name: d.name.trim(), date_from: d.date_from, date_to: d.date_to, discount_pct: num(d.discount_pct), min_qty: num(d.min_qty), is_active: !!d.is_active,
        item_id: d.kind === 'item' ? d.item_id || null : null, category_id: d.kind === 'cat' ? d.category_id || null : null };
      const r = p.id ? await sb.from('promotions').update(rec).eq('id', p.id) : await sb.from('promotions').insert({ ...rec, company_id: S.company.id });
      if (r.error) return toast(arError(r.error), 'err');
      toast('انحفظ', 'ok'); m.close(); viewPromotions(v);
    };
  };
  v.querySelector('#add')?.addEventListener('click', () => open(null));
  v.querySelector('table').onclick = async (e) => {
    const a = e.target.closest('[data-edit]'), b = e.target.closest('[data-del]');
    if (a) open(rows.find(p => p.id === a.dataset.edit));
    if (b && await confirmBox('حذف العرض؟')) { const { error } = await sb.from('promotions').delete().eq('id', b.dataset.del); if (error) return toast(arError(error), 'err'); viewPromotions(v); }
  };
}

// ---------------------------------------------------------------------
//  بطاقات الولاء: النقاط = صافي المشتريات المرحّلة × نقاط لكل دينار
// ---------------------------------------------------------------------
async function viewLoyalty(v) {
  if (!S.company || !S.fy) return void (v.innerHTML = `<div class="notice info">اختار شركة وسنة مالية من فوق أول.</div>`);
  const [lk, parties] = await Promise.all([loadLookups(true), loadParties(true)]);
  const types = lk.filter(r => r.kind === 'loyalty_type'), tById = Object.fromEntries(types.map(t => [t.id, t]));
  const holders = parties.filter(p => p.party_type === 'customer' && p.loyalty_type_id);
  v.innerHTML = `<div class="page-head"><h2>💳 مركز تحكم بطاقات الولاء</h2><div class="spacer"></div><a class="btn sm" href="#/setup?k=loyalty_type">⚙️ أنواع البطاقات</a></div>
    ${types.length ? '' : '<div class="notice info">عرّف أنواع البطاقات أول من «إعداد ← أنواع بطاقات الولاء» (مثلاً فضية: نقطة لكل دينار)، وبعدين أعطي العميل بطاقة من بطاقته.</div>'}
    <div class="card no-print" style="display:flex;gap:10px;flex-wrap:wrap;align-items:end">
      <div class="field"><label>من</label><input type="date" id="from" value="${S.fy.start_date}"></div><div class="field"><label>إلى</label><input type="date" id="to" value="${S.fy.end_date}"></div>
      <div class="field" style="flex:1"><label>بحث</label><input id="q" placeholder="الاسم أو رقم البطاقة…"></div><button class="btn primary" id="go">🔎 عرض</button><button class="btn sm" id="csv">⬇️ Excel</button></div>
    <div class="grid cols-4" id="kp" style="margin:12px 0"></div><div class="card table-wrap"><table class="t rep" id="tb"></table></div>
    <p class="muted" style="font-size:12px">النقاط من كل فواتير البيع المرحّلة للعميل (بعد الخصم وقبل الضريبة، ناقص المردودات؛ ويلزم صلاحية عرض فواتير المبيعات). الفترة بتأثّر على عمود «مشتريات الفترة» بس. «استبدال» بيسجّل نقاط انصرفت للعميل.</p>`;
  let out = [];
  async function run() {
    const from = v.querySelector('#from').value, to = v.querySelector('#to').value, q = v.querySelector('#q').value.trim().toLowerCase();
    // النقاط من كل المشتريات (عشان الرصيد يضل صحيح مع المستبدل)، والفترة بس لعمود «مشتريات الفترة»
    const ids = holders.map(p => p.id);
    const { data, error } = ids.length ? await sb.from('invoices').select('party_id,inv_type,inv_date,subtotal,discount_total').eq('company_id', S.company.id).in('inv_type', ['sale', 'sale_return']).eq('status', 'posted').in('party_id', ids).limit(50000) : { data: [] };
    if (error) return toast(arError(error), 'err');
    const net = {}, per = {}; (data || []).forEach(i => { const x = (i.inv_type === 'sale' ? 1 : -1) * num(i.subtotal);   // subtotal بعد الخصم أصلاً
      net[i.party_id] = (net[i.party_id] || 0) + x; if (i.inv_date >= from && i.inv_date <= to) per[i.party_id] = (per[i.party_id] || 0) + x; });
    const list = holders.filter(p => !q || [p.name, p.code, p.loyalty_card_no].some(x => (x || '').toLowerCase().includes(q))).map(p => {
      const t = tById[p.loyalty_type_id], pts = Math.floor(Math.max(0, net[p.id] || 0) * num(t?.rate || 0));
      return { p, t, sales: per[p.id] || 0, pts, red: num(p.loyalty_redeemed), bal: pts - num(p.loyalty_redeemed) };
    }).sort((a, b) => b.bal - a.bal);
    const s = (k) => list.reduce((a, x) => a + x[k], 0);
    v.querySelector('#kp').innerHTML = [['حاملي البطاقات', list.length], ['مشترياتهم بالفترة', fmtNum(s('sales'))], ['النقاط المكتسبة', s('pts')], ['الرصيد المتاح', s('bal')]].map(([l, x]) => `<div class="card stat"><span class="k">${l}</span><span class="v" style="font-size:20px">${x}</span></div>`).join('');
    out = list.map(x => [x.p.code, x.p.name, x.p.loyalty_card_no || '', x.t?.name || '', fmtNum(x.sales), x.pts, x.red, x.bal]);
    v.querySelector('#tb').innerHTML = `<thead><tr><th>الرمز</th><th>العميل</th><th>رقم البطاقة</th><th>النوع</th><th>مشتريات الفترة</th><th>النقاط (كل الوقت)</th><th>المستبدلة</th><th>الرصيد</th><th></th></tr></thead>
      <tbody>${list.map(x => `<tr><td>${esc(x.p.code)}</td><td><b>${esc(x.p.name)}</b></td><td dir="ltr" style="text-align:right">${esc(x.p.loyalty_card_no || '')}</td><td>${esc(x.t?.name || '')}</td>
        <td class="n">${amt(x.sales)}</td><td class="n">${x.pts}</td><td class="n">${x.red || ''}</td><td class="n"><b>${x.bal}</b></td>
        <td>${can('customers', 'edit') && x.bal > 0 ? `<button class="btn sm" data-red="${x.p.id}" data-bal="${x.bal}">🎁 استبدال</button>` : ''}</td></tr>`).join('') || '<tr><td colspan="9" class="empty">ما في عملاء معهم بطاقات</td></tr>'}</tbody>`;
  }
  v.querySelector('#go').onclick = run;
  v.querySelector('#csv').onclick = () => downloadCSV('بطاقات الولاء.csv', [['الرمز', 'العميل', 'رقم البطاقة', 'النوع', 'صافي المشتريات', 'النقاط', 'المستبدلة', 'الرصيد']].concat(out));
  v.querySelector('#tb').onclick = async (e) => {
    const b = e.target.closest('[data-red]'); if (!b) return;
    const p = holders.find(x => x.id === b.dataset.red);
    const m = modal({ title: `🎁 استبدال نقاط: ${p.name}`, size: 'sm', body: `<p>الرصيد المتاح: <b>${b.dataset.bal}</b> نقطة</p><div class="field"><label>عدد النقاط</label><input id="pts" dir="ltr" value="${b.dataset.bal}"></div>`,
      foot: '<button class="btn primary" data-ok>تسجيل</button><button class="btn" data-close>إلغاء</button>' });
    m.el.querySelector('[data-ok]').onclick = async () => {
      const n = Math.floor(num(m.el.querySelector('#pts').value)); if (n <= 0 || n > +b.dataset.bal) return toast('العدد مش صحيح', 'err');
      const { error } = await sb.from('parties').update({ loyalty_redeemed: num(p.loyalty_redeemed) + n }).eq('id', p.id); if (error) return toast(arError(error), 'err');
      p.loyalty_redeemed = num(p.loyalty_redeemed) + n; toast('تسجّل الاستبدال', 'ok'); m.close(); run();
    };
  };
  run();
}

// ---------------------------------------------------------------------
//  الحقول الإضافية
// ---------------------------------------------------------------------
const CF_ENT = { customer: 'العملاء', supplier: 'الموردين', item: 'الأصناف' };
const CF_TYPES = { text: 'نص', number: 'رقم', date: 'تاريخ', select: 'اختيار من قائمة', check: 'نعم / لا' };
export async function loadCustomFields(force = false) {
  if (!S.company) return [];
  if (!force && S._cf?.cid === S.company.id) return S._cf.rows;
  const { data } = await sb.from('custom_fields').select('*').eq('company_id', S.company.id).order('sort');
  S._cf = { cid: S.company.id, rows: data || [] }; return S._cf.rows;
}
// حقول جاهزة للنموذج (بعد loadCustomFields)
export function cfFieldsHTML(entity, extra = {}, ro = '') {
  const fs = (S._cf?.cid === S.company?.id ? S._cf.rows : []).filter(f => f.entity === entity && f.is_active);
  if (!fs.length) return '';
  return `<div class="grid cols-2" data-cf>${fs.map(f => { const v = extra?.[f.key] ?? ''; const nm = `cf__${f.key}`;
    const inp = f.field_type === 'select' ? `<select name="${nm}" ${ro}><option value="">—</option>${String(f.options || '').split(',').map(o => o.trim()).filter(Boolean).map(o => `<option ${o === v ? 'selected' : ''}>${esc(o)}</option>`).join('')}</select>`
      : f.field_type === 'check' ? `<label class="check" style="margin:8px 0"><input type="checkbox" name="${nm}" ${v ? 'checked' : ''} ${ro}> نعم</label>`
      : `<input name="${nm}" type="${f.field_type === 'date' ? 'date' : 'text'}" ${f.field_type === 'number' ? 'dir="ltr" inputmode="decimal"' : ''} value="${esc(v)}" ${ro}>`;
    return `<div class="field"><label>${esc(f.label)}</label>${inp}</div>`; }).join('')}</div>`;
}
export function cfValues(form, entity, prev = {}) {
  const fs = (S._cf?.cid === S.company?.id ? S._cf.rows : []).filter(f => f.entity === entity);
  if (!fs.length) return null;
  const out = { ...(prev || {}) };
  for (const f of fs) { const el = form.querySelector(`[name="cf__${f.key}"]`); if (!el) continue;
    const v = f.field_type === 'check' ? el.checked : f.field_type === 'number' ? (el.value === '' ? null : num(el.value)) : (el.value || null);
    if (v === null || v === '' || v === false) delete out[f.key]; else out[f.key] = v; }
  return out;
}
async function viewCustomFields(v) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const ent = CF_ENT[qs().get('e')] ? qs().get('e') : 'customer';
  const rows = (await loadCustomFields(true)).filter(f => f.entity === ent), ed = can('lookups', 'edit');
  v.innerHTML = `<div class="page-head"><h2>🧩 الحقول الإضافية</h2><div class="spacer"></div>${ed ? '<button class="btn primary" id="add">➕ حقل جديد</button>' : ''}</div>
    <div class="tabs lk-tabs">${Object.entries(CF_ENT).map(([k, l]) => `<a class="tab ${k === ent ? 'active' : ''}" href="#/custom-fields?e=${k}">${l}</a>`).join('')}</div>
    <p class="muted" style="font-size:13px;margin:8px 0">حقول خاصة فيك بتطلع ببطاقة ${CF_ENT[ent]} (تبويب «إضافي»)، مثل: رقم السجل الصحي، تاريخ انتهاء الرخصة، اللون، المقاس…</p>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الترتيب</th><th>اسم الحقل</th><th>النوع</th><th>الاختيارات</th><th>الحالة</th><th></th></tr></thead>
      <tbody>${rows.map(f => `<tr><td>${f.sort}</td><td><b>${esc(f.label)}</b> <span class="muted" dir="ltr" style="font-size:11px">${esc(f.key)}</span></td><td>${CF_TYPES[f.field_type]}</td><td>${esc(f.options || '')}</td>
        <td>${f.is_active ? '<span class="badge ok">فعّال</span>' : '<span class="badge">موقوف</span>'}</td><td class="actions">${ed ? `<button class="btn sm" data-edit="${f.id}">تعديل</button><button class="btn sm danger" data-del="${f.id}">حذف</button>` : ''}</td></tr>`).join('')
        || '<tr><td colspan="6" class="empty">ما في حقول إضافية</td></tr>'}</tbody></table></div>`;
  const open = (f) => {
    f = f || { label: '', key: 'f' + (rows.length + 1), field_type: 'text', options: '', sort: rows.length + 1, is_active: true };
    const m = modal({ title: f.id ? '✏️ تعديل حقل' : '➕ حقل جديد', size: 'sm', body: `<form id="cff">
      <div class="field"><label>اسم الحقل (اللي بيطلع) *</label><input name="label" value="${esc(f.label)}"></div>
      <div class="field"><label>الرمز الداخلي (أحرف إنجليزي صغيرة وأرقام)</label><input name="key" dir="ltr" value="${esc(f.key)}" ${f.id ? 'disabled' : ''}></div>
      <div class="grid cols-2"><div class="field"><label>النوع</label><select name="field_type">${Object.entries(CF_TYPES).map(([k, l]) => `<option value="${k}" ${k === f.field_type ? 'selected' : ''}>${l}</option>`).join('')}</select></div>
        <div class="field"><label>الترتيب</label><input name="sort" dir="ltr" value="${f.sort}"></div></div>
      <div class="field"><label>الاختيارات (للنوع «اختيار») مفصولة بفاصلة</label><input name="options" value="${esc(f.options || '')}" placeholder="أحمر, أزرق, أخضر"></div>
      <label class="check"><input type="checkbox" name="is_active" ${f.is_active ? 'checked' : ''}> فعّال</label></form>`,
      foot: '<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>' });
    m.el.querySelector('[data-save]').onclick = async () => {
      const d = formData(m.el.querySelector('#cff'));
      if (!d.label?.trim()) return toast('اكتب اسم الحقل', 'err');
      const key = (f.id ? f.key : (d.key || '')).trim().toLowerCase();
      if (!/^[a-z][a-z0-9_]{0,30}$/.test(key)) return toast('الرمز الداخلي لازم يبلّش بحرف إنجليزي صغير، وبعده أحرف أو أرقام', 'err');
      const rec = { label: d.label.trim(), field_type: d.field_type, options: d.options || null, sort: parseInt(d.sort) || 0, is_active: !!d.is_active };
      const r = f.id ? await sb.from('custom_fields').update(rec).eq('id', f.id) : await sb.from('custom_fields').insert({ ...rec, key, entity: ent, company_id: S.company.id });
      if (r.error) return toast(/duplicate|unique/.test(r.error.message) ? 'الرمز مستعمل' : arError(r.error), 'err');
      toast('انحفظ', 'ok'); m.close(); viewCustomFields(v);
    };
  };
  v.querySelector('#add')?.addEventListener('click', () => open(null));
  v.querySelector('table').onclick = async (e) => {
    const a = e.target.closest('[data-edit]'), b = e.target.closest('[data-del]');
    if (a) open(rows.find(f => f.id === a.dataset.edit));
    if (b && await confirmBox('حذف الحقل؟ القيم المحفوظة بالبطاقات بتضل بس ما بتطلع.')) { const { error } = await sb.from('custom_fields').delete().eq('id', b.dataset.del); if (error) return toast(arError(error), 'err'); viewCustomFields(v); }
  };
}

export const ORDER_ROUTES = { 'orders': viewOrders, 'promotions': viewPromotions, 'loyalty': viewLoyalty, 'custom-fields': viewCustomFields };
