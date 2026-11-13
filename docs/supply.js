// =====================================================================
//  السمو ERP — طلبات التزويد بين المستودعات + حدود الأصناف بالمستودع
//  الطلب: في الانتظار ← مثبت ← سند إخراج (المصدر) ← سند إدخال (الوجهة) بنفس الكلفة.
// =====================================================================
import { S, sb, esc, fmtDate, fmtNum, num, today, toast, arError, modal, confirmBox, formData, can, fmtQty } from './core.js';
import { loadWarehouses } from './inventory.js';
import { loadItems } from './invoices.js';
import { printDoc } from './print.js';

const q = (k) => new URLSearchParams(location.hash.split('?')[1] || '').get(k);
const ST = { pending: ['في الانتظار', 'warn'], confirmed: ['مثبت', 'brand'], rejected: ['مرفوض', 'bad'], cancelled: ['ملغى', 'bad'] };
const canSee = () => can('supply_requests', 'view') || can('inventory', 'view');
// الحالة الظاهرة: من حالة الطلب وسنداته
function stage(r, docs) {
  const o = docs[r.out_doc_id], i = docs[r.in_doc_id];
  if (i?.status === 'posted') return ['تم الاستلام', 'ok'];
  if (i) return ['سند إدخال (مسودة)', 'brand'];
  if (o?.status === 'posted') return ['تم الإخراج — بانتظار الاستلام', 'brand'];
  if (o) return ['سند إخراج (مسودة)', 'warn'];
  return ST[r.status];
}

async function viewSupply(v, ctx) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  if (q('t') === 'limits') return viewLimits(v, ctx);
  const [reqs, whs] = await Promise.all([sb.from('supply_requests').select('*').eq('company_id', S.company.id).order('req_no', { ascending: false }), loadWarehouses()]);
  if (reqs.error) throw reqs.error;
  const R = reqs.data || [], ids = R.flatMap(r => [r.out_doc_id, r.in_doc_id]).filter(Boolean);
  const docs = ids.length ? Object.fromEntries(((await sb.from('stock_docs').select('id,doc_no,doc_code,status,doc_type').in('id', ids)).data || []).map(d => [d.id, d])) : {};
  const wn = (id) => whs.find(w => w.id === id)?.name || '';
  v.innerHTML = `<div class="page-head"><h2>🚚 طلبات التزويد</h2><span class="badge brand">${R.length}</span><div class="spacer"></div>
      ${can('supply_requests', 'add') ? '<button class="btn primary" id="add">➕ طلب تزويد</button>' : ''}</div>
    <p class="muted">المندوب بيجهّز الطلب ويثبّته ← أمين المستودع بيصدر سند الإخراج ويرحّله ← المستودع الوجهة بيصدر سند الإدخال عند الاستلام.</p>
    <div class="tabs" style="margin-bottom:10px"><a style="text-decoration:none" class="tab active" href="#/supply">الطلبات</a><a style="text-decoration:none" class="tab" href="#/supply?t=limits">الحد الأدنى والأعلى</a></div>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرقم</th><th>التاريخ</th><th>من مستودع</th><th>إلى مستودع</th><th>المرجع</th><th>الحالة</th></tr></thead><tbody>
    ${R.map(r => { const s = stage(r, docs); return `<tr class="click" data-open="${r.id}"><td><b>${r.req_no}</b></td><td>${fmtDate(r.req_date)}</td><td>${esc(wn(r.from_warehouse_id))}</td><td>${esc(wn(r.to_warehouse_id))}</td><td>${esc(r.reference || '')}</td><td><span class="badge ${s[1]}">${s[0]}</span></td></tr>`; }).join('')
      || '<tr><td colspan="6" class="empty">ما في طلبات</td></tr>'}</tbody></table></div>`;
  v.querySelector('#add')?.addEventListener('click', () => openReq(ctx, {}, whs, docs));
  v.querySelector('tbody').onclick = (e) => { const r = e.target.closest('[data-open]'); if (r) openReq(ctx, R.find(x => x.id === r.dataset.open), whs, docs); };
}

async function openReq(ctx, r, whs, docs) {
  const isNew = !r.id, items = (await loadItems()).filter(i => i.item_type === 'goods' && i.track_stock !== false);
  const iby = Object.fromEntries(items.map(i => [i.id, i]));
  let lines = isNew ? [] : ((await sb.from('supply_request_lines').select('*').eq('request_id', r.id).order('line_no')).data || []).map(l => ({ ...l }));
  const st = r.status || 'pending', editable = st === 'pending' && !r.out_doc_id && (isNew ? can('supply_requests', 'add') : can('supply_requests', 'edit')), ro = editable ? '' : 'disabled';
  const active = whs.filter(w => w.is_active || w.id === r.from_warehouse_id || w.id === r.to_warehouse_id);
  const wsel = (n, val) => `<select name="${n}" ${ro}><option value="">— اختار —</option>${active.map(w => `<option value="${w.id}" ${w.id === val ? 'selected' : ''}>${esc(w.code)} — ${esc(w.name)}</option>`).join('')}</select>`;
  const o = docs[r.out_doc_id], i = docs[r.in_doc_id], sg = isNew ? ST.pending : stage(r, docs);
  const dn = (d) => d ? (d.doc_code || d.doc_no) : '';
  const md = modal({ title: isNew ? 'طلب تزويد جديد' : `طلب تزويد رقم ${r.req_no} (${sg[0]})`, size: 'lg', body: `<form id="f"><div class="grid cols-3">
      <div class="field"><label>التاريخ *</label><input type="date" name="req_date" value="${esc(r.req_date || today())}" ${ro}></div>
      <div class="field"><label>من مستودع (المصدر) *</label>${wsel('from_warehouse_id', r.from_warehouse_id)}</div>
      <div class="field"><label>إلى مستودع (الوجهة) *</label>${wsel('to_warehouse_id', r.to_warehouse_id)}</div>
      <div class="field"><label>المرجع</label><input name="reference" value="${esc(r.reference || '')}" ${ro}></div>
      <div class="field" style="grid-column:span 2"><label>الملاحظات</label><input name="notes" value="${esc(r.notes || '')}" ${ro}></div></div></form>
    ${editable ? `<div style="display:flex;gap:8px;flex-wrap:wrap;margin:6px 0"><input id="pick" list="sup-items" placeholder="➕ أضف صنف (رمز أو اسم)…" style="flex:1;min-width:220px"><datalist id="sup-items">${items.filter(x => x.is_active).map(x => `<option value="${esc(x.code)} — ${esc(x.name)}">`).join('')}</datalist>
      <button type="button" class="btn" id="fill">📈 تعبئة للحد الأدنى</button></div><div id="fillbox"></div>` : ''}
    <div class="table-wrap"><table class="t" id="ln"><thead><tr><th>#</th><th>الصنف</th><th>الوحدة</th><th>رصيد المصدر</th><th>رصيد الوجهة</th><th>الحد الأدنى / الأعلى</th><th>الكمية</th><th>ملاحظة</th>${editable ? '<th></th>' : ''}</tr></thead><tbody></tbody></table></div>
    ${!isNew ? `<div class="card" style="margin-top:10px;padding:10px;display:flex;gap:14px;flex-wrap:wrap;align-items:center">
      <span>📤 سند الإخراج: ${o ? `<a href="#/stock-docs?type=out"><b>${esc(dn(o))}</b></a> (${o.status === 'posted' ? 'مرحّل' : 'مسودة'})` : '—'}</span>
      <span>📥 سند الإدخال: ${i ? `<a href="#/stock-docs?type=in"><b>${esc(dn(i))}</b></a> (${i.status === 'posted' ? 'مرحّل' : 'مسودة'})` : '—'}</span></div>` : ''}`,
    foot: `${editable ? '<button class="btn primary" data-save>💾 حفظ</button>' : ''}
      ${!isNew && !r.out_doc_id && st === 'pending' && can('supply_requests', 'post') ? '<button class="btn primary" data-st="confirmed">✅ تثبيت</button><button class="btn danger" data-st="rejected">رفض</button>' : ''}
      ${!isNew && !r.out_doc_id && st === 'confirmed' && can('supply_requests', 'post') ? '<button class="btn" data-st="pending">↩️ إرجاع للانتظار</button>' : ''}
      ${!isNew && !r.out_doc_id && (st === 'pending' || st === 'confirmed') && can('supply_requests', st === 'confirmed' ? 'post' : 'edit') ? '<button class="btn danger" data-st="cancelled">إلغاء</button>' : ''}
      ${!isNew && !r.out_doc_id && (st === 'rejected' || st === 'cancelled') && can('supply_requests', 'edit') ? '<button class="btn" data-st="pending">↩️ إرجاع للانتظار</button>' : ''}
      ${!isNew && st === 'confirmed' && !r.out_doc_id && can('inventory', 'add') ? '<button class="btn primary" data-out>📤 إصدار سند الإخراج</button>' : ''}
      ${!isNew && o?.status === 'posted' && !r.in_doc_id && can('inventory', 'add') ? '<button class="btn primary" data-in>📥 إصدار سند الإدخال</button>' : ''}
      ${!isNew ? '<button class="btn" data-prn>🖨️ طباعة</button>' : ''}
      ${!isNew && !r.out_doc_id && st !== 'confirmed' && can('supply_requests', 'delete') ? '<button class="btn danger" data-del style="margin-inline-start:auto">حذف</button>' : ''}
      <button class="btn" data-close>إغلاق</button>` });
  const el = md.el, tb = el.querySelector('#ln tbody');
  const val = (n) => el.querySelector(`[name=${n}]`)?.value || r[n];
  let bal = {};   // item -> {src, dst, min, max}
  const loadBal = async () => {
    const fw = val('from_warehouse_id'), tw = val('to_warehouse_id'); bal = {};
    if (!fw || !tw || fw === tw || !lines.length) return draw();
    const { data } = await sb.rpc('supply_balances', { p_company: S.company.id, p_from: fw, p_to: tw, p_date: val('req_date') || today(), p_items: lines.map(l => l.item_id) });
    (data || []).forEach(x => { bal[x.item_id] = { src: num(x.src_qty), dst: num(x.dest_qty), min: x.min_qty == null ? null : num(x.min_qty), max: x.max_qty == null ? null : num(x.max_qty) }; });
    draw();
  };
  const draw = () => {
    tb.innerHTML = lines.map((l, n) => { const it = iby[l.item_id] || {}, b = bal[l.item_id] || {};
      const low = b.min != null && num(b.dst) + num(l.qty) < b.min;
      return `<tr><td>${n + 1}</td><td><b>${esc(it.code || '')}</b> ${esc(it.name || '')}</td><td>${esc(it.unit || '')}</td>
        <td class="n" style="${num(b.src) < num(l.qty) ? 'color:var(--bad,#c0392b);font-weight:700' : ''}">${fmtNum(b.src || 0)}</td><td class="n">${fmtNum(b.dst || 0)}</td>
        <td class="n">${b.min != null ? `${fmtNum(b.min)}${b.max != null ? ' / ' + fmtNum(b.max) : ''}` : '—'}</td>
        <td>${editable ? `<input data-q="${n}" value="${esc(l.qty ?? '')}" inputmode="decimal" dir="ltr" style="width:90px">${b.min != null && low ? ` <button type="button" class="btn sm" data-tomin="${n}" title="إلى الحد الأدنى">⬆️</button>` : ''}` : `<span class="n">${fmtQty(l.qty)}</span>`}</td>
        <td>${editable ? `<input data-nt="${n}" value="${esc(l.note || '')}">` : esc(l.note || '')}</td>
        ${editable ? `<td><button type="button" class="btn sm danger" data-rm="${n}">✕</button></td>` : ''}</tr>`; }).join('') || '<tr><td colspan="9" class="empty">أضف الأصناف أو استعمل «تعبئة للحد الأدنى»</td></tr>';
  };
  el.querySelectorAll('[name=from_warehouse_id],[name=to_warehouse_id],[name=req_date]').forEach(s => s.addEventListener('change', loadBal));
  loadBal();
  el.querySelector('#pick')?.addEventListener('change', (e) => {
    const t = e.target.value.split('—')[0].trim(), it = items.find(x => x.code === t) || items.find(x => x.name === e.target.value.trim() || x.barcode === e.target.value.trim());
    if (!it) return toast('الصنف مش موجود', 'err');
    if (lines.some(l => l.item_id === it.id)) toast('الصنف موجود بالطلب', 'err'); else lines.push({ item_id: it.id, qty: 1 });
    e.target.value = ''; loadBal();
  });
  tb.addEventListener('input', (e) => { const a = e.target.dataset.q, b = e.target.dataset.nt; if (a != null) lines[+a].qty = e.target.value; if (b != null) lines[+b].note = e.target.value; });
  tb.addEventListener('change', (e) => { if (e.target.dataset.q != null) draw(); });
  tb.addEventListener('click', (e) => {
    const rm = e.target.closest('[data-rm]'); if (rm) { lines.splice(+rm.dataset.rm, 1); return draw(); }
    const tm = e.target.closest('[data-tomin]'); if (tm) { const l = lines[+tm.dataset.tomin], b = bal[l.item_id] || {}; l.qty = Math.max(0, Math.round((b.min - num(b.dst)) * 1000) / 1000); draw(); }
  });
  el.querySelector('#fill')?.addEventListener('click', async () => {
    const fw = val('from_warehouse_id'), tw = val('to_warehouse_id'); if (!fw || !tw) return toast('اختار المستودعين أول', 'err');
    const { data, error } = await sb.rpc('supply_min_suggest', { p_company: S.company.id, p_from: fw, p_to: tw, p_date: val('req_date') });
    if (error) return toast(arError(error), 'err');
    const STL = { ok: ['متوفر', 'ok'], partial: ['جزئي', 'warn'], unavailable: ['رصيد المصدر ما بيكفي', 'bad'], covered: ['واصل للحد الأدنى', ''] };
    const rows = (data || []).map(x => ({ ...x, inCart: lines.some(l => l.item_id === x.item_id) }));
    const toAdd = rows.filter(x => !x.inCart && num(x.suggest) > 0);
    const box = el.querySelector('#fillbox');
    box.innerHTML = `<div class="card" style="padding:10px;margin:8px 0;border:2px solid var(--brand)"><b>📈 مراجعة التعبئة للحد الأدنى</b>
      <p class="muted" style="margin:4px 0">مواد للإضافة: <b>${toAdd.length}</b> · غير متاحة: <b>${rows.filter(x => x.state === 'unavailable').length}</b> · مغطاة مسبقاً: <b>${rows.filter(x => x.state === 'covered').length}</b></p>
      <div class="table-wrap"><table class="t"><thead><tr><th>الصنف</th><th>رصيد الوجهة</th><th>الحد الأدنى</th><th>رصيد المصدر</th><th>المطلوب</th><th>المقترح</th><th>الحالة</th></tr></thead><tbody>
      ${rows.map(x => `<tr><td><b>${esc(x.code)}</b> ${esc(x.name)}${x.inCart ? ' <span class="badge">بالطلب</span>' : ''}</td><td class="n">${fmtNum(x.dest_qty)}</td><td class="n">${fmtNum(x.min_qty)}</td><td class="n">${fmtNum(x.src_qty)}</td><td class="n">${fmtNum(x.need)}</td><td class="n"><b>${fmtNum(x.suggest)}</b></td><td><span class="badge ${STL[x.state][1]}">${STL[x.state][0]}</span></td></tr>`).join('')
        || '<tr><td colspan="7" class="empty">ما في حدود معرّفة لمستودع الوجهة. عرّفها من تبويب «الحد الأدنى والأعلى».</td></tr>'}</tbody></table></div>
      <div style="display:flex;gap:8px;margin-top:6px"><button type="button" class="btn primary" data-apply ${toAdd.length ? '' : 'disabled'}>تطبيق (${toAdd.length})</button><button type="button" class="btn" data-fclose>إخفاء</button></div></div>`;
    box.querySelector('[data-apply]').onclick = () => { toAdd.forEach(x => lines.push({ item_id: x.item_id, qty: num(x.suggest) })); box.innerHTML = ''; loadBal(); };
    box.querySelector('[data-fclose]').onclick = () => { box.innerHTML = ''; };
  });
  // تأكيد بيستبدل النافذة؛ إذا انلغى بنرجع نفتح الطلب
  const ask = async (msg) => { if (await confirmBox(msg)) return true; openAgain(); return false; };
  // التعبئة بتفتح نافذة فوق؛ بعد الإغلاق بنرجع نفتح الطلب بنفس السطور
  const openAgain = () => { const f = editable ? formData(el.querySelector('#f')) : {}; if (!r.id && !lines.length) return; openReq(ctx, { ...r, ...f, _lines: lines }, whs, docs); };
  if (r._lines) { lines = r._lines; delete r._lines; loadBal(); }

  const done = (msg) => { toast(msg, 'ok'); md.close(); ctx.rerender(); };
  el.querySelector('[data-save]')?.addEventListener('click', async () => {
    const f = formData(el.querySelector('#f'));
    if (!lines.length) return toast('أضف صنف واحد على الأقل', 'err');
    if (lines.some(l => num(l.qty) <= 0)) return toast('في كمية صفر', 'err');
    const { error } = await sb.rpc('supply_save', { p: { ...f, id: r.id || null, company_id: S.company.id, lines: lines.map(l => ({ item_id: l.item_id, qty: num(l.qty), note: l.note || '' })) } });
    if (error) return toast(arError(error), 'err'); done('انحفظ الطلب');
  });
  el.querySelectorAll('[data-st]').forEach(b => b.onclick = async () => {
    const to = b.dataset.st, msg = { confirmed: 'تثبيت طلب التزويد؟', rejected: 'رفض الطلب؟', cancelled: 'إلغاء الطلب؟', pending: 'إرجاع الطلب للانتظار؟' }[to];
    if (!(await ask(msg))) return;
    const { error } = await sb.rpc('supply_set_status', { p_id: r.id, p_status: to }); if (error) return toast(arError(error), 'err'); done('تغيّرت الحالة');
  });
  el.querySelector('[data-out]')?.addEventListener('click', async () => {
    if (!(await ask('إصدار سند الإخراج من مستودع المصدر؟ (بينعمل مسودة، رحّله من سندات المخزون)'))) return;
    const { error } = await sb.rpc('supply_issue_out', { p_id: r.id }); if (error) return toast(arError(error), 'err'); done('انصدر سند الإخراج');
  });
  el.querySelector('[data-in]')?.addEventListener('click', async () => {
    if (!(await ask('إصدار سند الإدخال لمستودع الوجهة؟ الكميات والكلفة من سند الإخراج.'))) return;
    const { error } = await sb.rpc('supply_issue_in', { p_id: r.id }); if (error) return toast(arError(error), 'err'); done('انصدر سند الإدخال');
  });
  el.querySelector('[data-del]')?.addEventListener('click', async () => {
    if (!(await ask('حذف الطلب؟'))) return;
    const { error } = await sb.rpc('supply_delete', { p_id: r.id }); if (error) return toast(arError(error), 'err'); done('انحذف');
  });
  el.querySelector('[data-prn]')?.addEventListener('click', () => {
    const wn = (id) => whs.find(w => w.id === id)?.name || '';
    const rows = lines.map((l, n) => { const it = iby[l.item_id] || {}; return `<tr><td>${n + 1}</td><td>${esc(it.code || '')}</td><td>${esc(it.name || '')}</td><td>${esc(it.unit || '')}</td><td class="n">${fmtQty(l.qty)}</td><td>${esc(l.note || '')}</td></tr>`; }).join('');
    printDoc(`طلب تزويد رقم ${r.req_no}`, `<p><b>التاريخ:</b> ${fmtDate(r.req_date)} &nbsp;·&nbsp; <b>من:</b> ${esc(wn(r.from_warehouse_id))} &nbsp;·&nbsp; <b>إلى:</b> ${esc(wn(r.to_warehouse_id))}${r.reference ? ` &nbsp;·&nbsp; <b>المرجع:</b> ${esc(r.reference)}` : ''}</p>${r.notes ? `<p>${esc(r.notes)}</p>` : ''}
      <table class="t"><thead><tr><th>#</th><th>الرمز</th><th>الصنف</th><th>الوحدة</th><th>الكمية</th><th>ملاحظة</th></tr></thead><tbody>${rows}</tbody></table>
      <div style="display:flex;justify-content:space-around;margin-top:50px"><div>طالب التزويد: ............</div><div>أمين المستودع: ............</div><div>المستلِم: ............</div></div>`, { subtitle: sg[0] });
  });
}

// الحد الأدنى والأعلى لكل صنف بمستودع
async function viewLimits(v, ctx) {
  const whs = await loadWarehouses(), wh = q('wh') || whs.find(w => w.is_active)?.id;
  const [items, lim] = await Promise.all([loadItems(), wh ? sb.from('item_wh_limits').select('*').eq('company_id', S.company.id).eq('warehouse_id', wh) : { data: [] }]);
  const L = Object.fromEntries((lim.data || []).map(x => [x.item_id, x])), ed = can('inventory', 'edit');
  const goods = items.filter(i => i.item_type === 'goods' && i.track_stock !== false && (i.is_active || L[i.id]));
  v.innerHTML = `<div class="page-head"><h2>🚚 طلبات التزويد</h2><div class="spacer"></div>${ed ? '<button class="btn primary" id="save">💾 حفظ الحدود</button>' : ''}</div>
    <div class="tabs" style="margin-bottom:10px"><a style="text-decoration:none" class="tab" href="#/supply">الطلبات</a><a style="text-decoration:none" class="tab active" href="#/supply?t=limits">الحد الأدنى والأعلى</a></div>
    <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:10px"><label>المستودع:</label><select id="wh">${whs.map(w => `<option value="${w.id}" ${w.id === wh ? 'selected' : ''}>${esc(w.code)} — ${esc(w.name)}</option>`).join('')}</select>
      <input id="flt" placeholder="🔎 بحث بالصنف…" style="max-width:240px"><span class="muted">«التعبئة للحد الأدنى» بطلب التزويد بتكمّل رصيد المستودع الوجهة لهالحد.</span></div>
    <div class="card table-wrap"><table class="t" id="lt"><thead><tr><th>الرمز</th><th>الصنف</th><th>الوحدة</th><th>الحد الأدنى</th><th>الحد الأعلى</th></tr></thead><tbody>
    ${goods.map(i => `<tr data-item="${i.id}"><td>${esc(i.code)}</td><td>${esc(i.name)}</td><td>${esc(i.unit || '')}</td>
      <td><input data-k="min" value="${L[i.id] ? num(L[i.id].min_qty) : ''}" inputmode="decimal" dir="ltr" style="width:100px" ${ed ? '' : 'disabled'}></td>
      <td><input data-k="max" value="${L[i.id]?.max_qty ?? ''}" inputmode="decimal" dir="ltr" style="width:100px" ${ed ? '' : 'disabled'}></td></tr>`).join('') || '<tr><td colspan="5" class="empty">ما في أصناف مخزنية</td></tr>'}</tbody></table></div>`;
  v.querySelector('#wh').onchange = (e) => { location.hash = `#/supply?t=limits&wh=${e.target.value}`; };
  v.querySelector('#flt').oninput = (e) => { const t = e.target.value.trim(); v.querySelectorAll('#lt tbody tr').forEach(tr => tr.style.display = !t || tr.textContent.includes(t) ? '' : 'none'); };
  v.querySelector('#save')?.addEventListener('click', async () => {
    const ups = [], dels = [];
    for (const tr of v.querySelectorAll('#lt tbody tr[data-item]')) {
      const id = tr.dataset.item, mn = tr.querySelector('[data-k=min]').value.trim(), mx = tr.querySelector('[data-k=max]').value.trim();
      if (!mn && !mx) { if (L[id]) dels.push(L[id].id); continue; }
      if (mx && num(mx) < num(mn)) return toast(`الحد الأعلى أقل من الأدنى (${tr.children[1].textContent})`, 'err');
      const cur = L[id]; if (cur && num(cur.min_qty) === num(mn) && String(cur.max_qty ?? '') === (mx ? String(num(mx)) : '')) continue;
      ups.push({ company_id: S.company.id, item_id: id, warehouse_id: wh, min_qty: num(mn), max_qty: mx ? num(mx) : null });
    }
    if (ups.length) { const x = await sb.from('item_wh_limits').upsert(ups, { onConflict: 'item_id,warehouse_id' }); if (x.error) return toast(arError(x.error), 'err'); }
    if (dels.length) { const x = await sb.from('item_wh_limits').delete().in('id', dels); if (x.error) return toast(arError(x.error), 'err'); }
    toast(`انحفظت الحدود (${ups.length + dels.length})`, 'ok'); ctx.rerender();
  });
}

export const SUPPLY_ROUTES = { 'supply': (v, ctx) => (canSee() ? viewSupply(v, ctx) : void (v.innerHTML = '<div class="notice">ما عندك صلاحية</div>')) };
