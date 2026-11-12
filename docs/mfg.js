// =====================================================================
//  السمو ERP — التصنيع (الوصفات وأوامر الإنتاج)، الصيانة، تنسيق الحقول، تنسيق التقارير (اختيار الأعمدة)
// =====================================================================
import { S, sb, esc, toast, arError, can, modal, confirmBox, formData, fmtNum, fmtDate, num, today, localStorageGet, localStorageSet } from './core.js';
import { loadItems, openInvoicePrefill } from './invoices.js';
import { loadParties, partyDatalist, resolveParty, partyLabel } from './parties.js';
import { docNo } from './numbering.js';
import { downloadCSV } from './finance.js';
import { attachAudit } from './audit.js';

const qs = () => new URLSearchParams(location.hash.split('?')[1] || '');
const itemLabel = (it) => it ? `${it.code} — ${it.name}` : '';
const resolveItem = (items, v) => { v = (v || '').trim(); if (!v) return null; return items.find(i => itemLabel(i) === v || i.code === v || i.name === v) || null; };

// ---------------------------------------------------------------------
//  الوصفات (قوائم المواد)
// ---------------------------------------------------------------------
async function viewBoms(v) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const [bR, items] = await Promise.all([sb.from('boms').select('*, bom_lines(*)').eq('company_id', S.company.id).order('code'), loadItems(true)]);
  if (bR.error) throw bR.error;
  const rows = bR.data || [], itById = Object.fromEntries(items.map(i => [i.id, i])), goods = items.filter(i => i.item_type !== 'service');
  v.innerHTML = `<div class="page-head"><h2>🧪 الوصفات (قوائم المواد)</h2><div class="spacer"></div><a class="btn sm" href="#/production">🏭 أوامر الإنتاج</a>
      ${can('manufacturing', 'add') ? '<button class="btn primary" id="add">➕ وصفة جديدة</button>' : ''}</div>
    <p class="muted" style="font-size:13px">الوصفة بتقول: عشان تطلّع كمية من المنتج، بدك هالمواد الخام بهالكميات، وكلفة إضافية (عمالة وتشغيل) لكل دفعة.</p>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرمز</th><th>الوصفة</th><th>المنتج</th><th>بتطلّع</th><th>المواد</th><th>كلفة إضافية</th><th>الحالة</th><th></th></tr></thead>
      <tbody>${rows.map(b => `<tr><td>${esc(b.code)}</td><td><b>${esc(b.name)}</b></td><td>${esc(itById[b.item_id]?.name || '')}</td><td class="n">${fmtNum(b.output_qty)}</td>
        <td>${(b.bom_lines || []).sort((x, y) => x.line_no - y.line_no).map(l => `${esc(itById[l.item_id]?.name || '')} × ${fmtNum(l.qty)}`).join('، ')}</td><td class="n">${fmtNum(b.extra_cost)}</td>
        <td>${b.is_active ? '<span class="badge ok">فعّالة</span>' : '<span class="badge">موقوفة</span>'}</td>
        <td class="actions">${can('manufacturing', 'edit') ? `<button class="btn sm" data-edit="${b.id}">تعديل</button>` : ''}${can('manufacturing', 'delete') ? `<button class="btn sm danger" data-del="${b.id}">حذف</button>` : ''}</td></tr>`).join('')
        || '<tr><td colspan="8" class="empty">ما في وصفات</td></tr>'}</tbody></table></div>
    <datalist id="mfg-items">${goods.filter(i => i.is_active).map(i => `<option value="${esc(itemLabel(i))}">`).join('')}</datalist>`;
  const open = (b) => {
    const isNew = !b;
    b = b || { code: String(rows.length + 1).padStart(2, '0'), name: '', item_id: null, output_qty: 1, extra_cost: 0, is_active: true, bom_lines: [] };
    let lines = (b.bom_lines || []).sort((x, y) => x.line_no - y.line_no).map(l => ({ item: itemLabel(itById[l.item_id]), qty: num(l.qty) }));
    if (!lines.length) lines.push({ item: '', qty: 1 });
    const m = modal({ title: isNew ? '➕ وصفة جديدة' : '✏️ تعديل وصفة', body: `<form id="bf"><div class="grid cols-3">
      <div class="field"><label>الرمز *</label><input name="code" dir="ltr" value="${esc(b.code)}"></div>
      <div class="field" style="grid-column:span 2"><label>اسم الوصفة *</label><input name="name" value="${esc(b.name)}"></div>
      <div class="field" style="grid-column:span 2"><label>المنتج النهائي *</label><input name="item" list="mfg-items" value="${esc(itemLabel(itById[b.item_id]))}"></div>
      <div class="field"><label>الكمية اللي بتطلع</label><input name="output_qty" dir="ltr" value="${num(b.output_qty)}"></div>
      <div class="field"><label>كلفة إضافية لكل دفعة</label><input name="extra_cost" dir="ltr" value="${num(b.extra_cost) || ''}"></div>
      <div class="field"><label>&nbsp;</label><label class="check"><input type="checkbox" name="is_active" ${b.is_active ? 'checked' : ''}> فعّالة</label></div></div></form>
      <h4 style="margin:10px 0 6px">المواد الخام لكل دفعة</h4>
      <div class="table-wrap"><table class="t lines"><thead><tr><th>#</th><th>المادة</th><th>الكمية</th><th></th></tr></thead><tbody id="bl"></tbody></table></div>
      <button class="btn sm" type="button" id="addl">➕ مادة</button>`,
      foot: '<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>' });
    const tb = m.el.querySelector('#bl');
    const draw = () => tb.innerHTML = lines.map((l, i) => `<tr><td class="muted">${i + 1}</td><td><input class="cell" list="mfg-items" data-i="${i}" data-k="item" value="${esc(l.item)}"></td>
      <td><input class="cell n" dir="ltr" data-i="${i}" data-k="qty" value="${esc(l.qty)}"></td><td><button class="btn sm" type="button" data-rm="${i}">✕</button></td></tr>`).join('');
    draw();
    tb.oninput = (e) => { const t = e.target; if (t.dataset.k) lines[+t.dataset.i][t.dataset.k] = t.value; };
    tb.onclick = (e) => { const x = e.target.closest('[data-rm]'); if (x) { lines.splice(+x.dataset.rm, 1); if (!lines.length) lines.push({ item: '', qty: 1 }); draw(); } };
    m.el.querySelector('#addl').onclick = () => { lines.push({ item: '', qty: 1 }); draw(); };
    m.el.querySelector('[data-save]').onclick = async (e) => {
      const d = formData(m.el.querySelector('#bf')); const prod = resolveItem(goods, d.item);
      if (!d.code?.trim() || !d.name?.trim()) return toast('الرمز والاسم مطلوبين', 'err');
      if (!prod) return toast('اختار المنتج من القائمة', 'err');
      if (!(num(d.output_qty) > 0)) return toast('الكمية لازم أكبر من صفر', 'err');
      const out = [];
      for (const [k, l] of lines.entries()) { if (!l.item) continue; const it = resolveItem(goods, l.item);
        if (!it) return toast(`السطر ${k + 1}: المادة مش موجودة`, 'err'); if (it.id === prod.id) return toast('المنتج ما بيكون مادة بوصفته', 'err');
        if (!(num(l.qty) > 0)) return toast(`السطر ${k + 1}: الكمية لازم أكبر من صفر`, 'err'); out.push({ item_id: it.id, qty: num(l.qty) }); }
      if (!out.length) return toast('ضيف مادة وحدة على الأقل', 'err');
      e.target.disabled = true;
      const rec = { code: d.code.trim(), name: d.name.trim(), item_id: prod.id, output_qty: num(d.output_qty), extra_cost: num(d.extra_cost), is_active: !!d.is_active };
      try {
        let id = b.id;
        if (id) { const u = await sb.from('boms').update(rec).eq('id', id); if (u.error) throw u.error; const x = await sb.from('bom_lines').delete().eq('bom_id', id); if (x.error) throw x.error; }
        else { const ins = await sb.from('boms').insert({ ...rec, company_id: S.company.id }).select().single(); if (ins.error) throw ins.error; id = ins.data.id; }
        const li = await sb.from('bom_lines').insert(out.map((l, k) => ({ ...l, bom_id: id, line_no: k + 1 }))); if (li.error) throw li.error;
        toast('انحفظت', 'ok'); m.close(); viewBoms(v);
      } catch (err) { e.target.disabled = false; toast(/duplicate|unique/.test(err.message) ? 'الرمز مستعمل' : arError(err), 'err'); }
    };
  };
  v.querySelector('#add')?.addEventListener('click', () => open(null));
  v.querySelector('table').onclick = async (e) => {
    const a = e.target.closest('[data-edit]'), b = e.target.closest('[data-del]');
    if (a) open(rows.find(x => x.id === a.dataset.edit));
    if (b && await confirmBox('حذف الوصفة؟')) { const { error } = await sb.from('boms').delete().eq('id', b.dataset.del);
      if (error) return toast(/foreign key|violates/.test(error.message) ? 'الوصفة مستعملة بأوامر إنتاج، أوقفها بدل الحذف' : arError(error), 'err'); viewBoms(v); }
  };
}

// ---------------------------------------------------------------------
//  أوامر الإنتاج
// ---------------------------------------------------------------------
async function viewProduction(v) {
  if (!S.company || !S.fy) return void (v.innerHTML = `<div class="notice info">اختار شركة وسنة مالية من فوق أول.</div>`);
  const [pR, bR, wR, items] = await Promise.all([sb.from('productions').select('*').eq('company_id', S.company.id).order('prod_no', { ascending: false }).limit(2000),
    sb.from('boms').select('*').eq('company_id', S.company.id).order('code'), sb.from('warehouses').select('id,name,is_active').eq('company_id', S.company.id).order('code'), loadItems()]);
  if (pR.error) throw pR.error;
  const rows = pR.data || [], boms = bR.data || [], whs = (wR.data || []).filter(w => w.is_active), bById = Object.fromEntries(boms.map(b => [b.id, b])), itById = Object.fromEntries(items.map(i => [i.id, i]));
  const docIds = rows.flatMap(p => [p.out_doc_id, p.in_doc_id]).filter(Boolean);
  const docs = docIds.length ? Object.fromEntries(((await sb.from('stock_docs').select('id,doc_no,doc_code,status').in('id', docIds)).data || []).map(d => [d.id, d])) : {};
  const st = (id) => docs[id] ? `<a href="#/stock-docs?type=in">${esc(docNo(docs[id]))}</a> ${docs[id].status === 'posted' ? '<span class="badge ok">مرحّل</span>' : '<span class="badge warn">مسودة</span>'}` : '<span class="muted">—</span>';
  v.innerHTML = `<div class="page-head"><h2>🏭 أوامر الإنتاج</h2><div class="spacer"></div><a class="btn sm" href="#/boms">🧪 الوصفات</a>
      ${can('manufacturing', 'add') && boms.some(b => b.is_active) ? '<button class="btn primary" id="add">➕ أمر إنتاج</button>' : ''}</div>
    <p class="muted" style="font-size:13px">أمر الإنتاج بيعمل سندين مخزون مسودة: <b>إخراج</b> للمواد الخام و<b>إدخال</b> للمنتج. كبسة «ترحيل» هون بترحّل الإخراج أول، وبتحسب كلفة المنتج من الكلفة الفعلية للمواد + الكلفة الإضافية، وبعدين بترحّل الإدخال. (قيود الجرد المستمر بترحّلها للمحاسبة من شاشة الترحيل.)</p>
    <div class="card table-wrap"><table class="t rep"><thead><tr><th>الرقم</th><th>التاريخ</th><th>الوصفة</th><th>المنتج</th><th>الدفعات</th><th>الكمية المنتجة</th><th>الكلفة (بعد الترحيل)</th><th>كلفة الوحدة</th><th>سند الإخراج</th><th>سند الإدخال</th><th></th></tr></thead>
      <tbody>${rows.map(p => { const b = bById[p.bom_id] || {}; const q = num(b.output_qty) * num(p.batches);
        return `<tr><td><b>${p.prod_no}</b></td><td>${fmtDate(p.prod_date)}</td><td>${esc(b.name || '')}</td><td>${esc(itById[b.item_id]?.name || '')}</td><td class="n">${fmtNum(p.batches)}</td><td class="n">${fmtNum(q)}</td>
          <td class="n">${fmtNum(p.total_cost)}</td><td class="n">${q ? fmtNum(num(p.total_cost) / q) : ''}</td><td>${st(p.out_doc_id)}</td><td>${st(p.in_doc_id)}</td>
          <td class="actions">${can('manufacturing', 'post') && docs[p.in_doc_id]?.status !== 'posted' ? `<button class="btn sm primary" data-post="${p.id}">📤 ترحيل</button>` : ''}
            ${can('manufacturing', 'delete') && ![p.out_doc_id, p.in_doc_id].some(id => docs[id]?.status === 'posted') ? `<button class="btn sm danger" data-del="${p.id}">حذف</button>` : ''}</td></tr>`; }).join('')
        || '<tr><td colspan="11" class="empty">ما في أوامر إنتاج</td></tr>'}</tbody></table></div>`;
  v.querySelector('#add')?.addEventListener('click', () => {
    const m = modal({ title: '➕ أمر إنتاج', size: 'sm', body: `<form id="pf">
      <div class="field"><label>الوصفة *</label><select name="bom">${boms.filter(b => b.is_active).map(b => `<option value="${b.id}">${esc(b.code)} — ${esc(b.name)}</option>`).join('')}</select></div>
      <div class="grid cols-2"><div class="field"><label>عدد الدفعات *</label><input name="batches" dir="ltr" value="1"></div><div class="field"><label>التاريخ</label><input type="date" name="d" value="${today() >= S.fy.start_date && today() <= S.fy.end_date ? today() : S.fy.start_date}"></div></div>
      <div class="field"><label>المستودع</label><select name="wh">${whs.map(w => `<option value="${w.id}">${esc(w.name)}</option>`).join('')}</select></div>
      <div class="field"><label>ملاحظات</label><input name="notes"></div><p class="muted" id="pv" style="font-size:13px"></p></form>`,
      foot: '<button class="btn primary" data-ok>🏭 إنشاء</button><button class="btn" data-close>إلغاء</button>' });
    const f = m.el.querySelector('#pf');
    const pv = () => { const b = bById[f.bom.value]; if (b) m.el.querySelector('#pv').textContent = `رح ينتج ${fmtNum(num(b.output_qty) * num(f.batches.value))} من «${itById[b.item_id]?.name || ''}».`; };
    f.bom.onchange = pv; f.batches.oninput = pv; pv();
    m.el.querySelector('[data-ok]').onclick = async (e) => {
      const d = formData(f); if (!(num(d.batches) > 0)) return toast('عدد الدفعات لازم أكبر من صفر', 'err');
      e.target.disabled = true;
      const { error } = await sb.rpc('create_production', { p_bom: d.bom, p_batches: num(d.batches), p_date: d.d, p_warehouse: d.wh, p_notes: d.notes || null });
      if (error) { e.target.disabled = false; return toast(arError(error), 'err'); }
      toast('انعمل أمر الإنتاج وسنداته', 'ok'); m.close(); viewProduction(v);
    };
  });
  v.querySelector('table').onclick = async (e) => {
    const ps = e.target.closest('[data-post]');
    if (ps) { if (!(await confirmBox('ترحيل أمر الإنتاج للمخزون؟ المواد بتطلع والمنتج بيدخل بكلفتها.'))) return;
      const { data, error } = await sb.rpc('post_production', { p_id: ps.dataset.post }); if (error) return toast(arError(error), 'err');
      toast(`انرحّل — كلفة الإنتاج ${fmtNum(data)}`, 'ok'); return viewProduction(v); }
    const b = e.target.closest('[data-del]'); if (!b) return;
    if (!(await confirmBox('حذف أمر الإنتاج وسنداته (المسودة)؟'))) return;
    const { error } = await sb.rpc('delete_production', { p_id: b.dataset.del }); if (error) return toast(arError(error), 'err');
    toast('انحذف', 'ok'); viewProduction(v);
  };
}

// ---------------------------------------------------------------------
//  الصيانة
// ---------------------------------------------------------------------
const SVC = { received: ['استلام', 'warn'], in_progress: ['قيد الصيانة', 'brand'], waiting_parts: ['بانتظار قطع', 'warn'], ready: ['جاهز للتسليم', 'ok'], delivered: ['تسلّم', ''], cancelled: ['ملغى', 'bad'] };
async function viewService(v, ctx) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const [tR, parties] = await Promise.all([sb.from('service_tickets').select('*').eq('company_id', S.company.id).order('ticket_no', { ascending: false }).limit(3000), loadParties()]);
  if (tR.error) throw tR.error;
  const rows = tR.data || [], custs = parties.filter(p => p.party_type === 'customer'), pById = Object.fromEntries(parties.map(p => [p.id, p]));
  v.innerHTML = `<div class="page-head"><h2>🔧 الصيانة</h2><div class="spacer"></div>
      <input id="q" placeholder="بحث بالرقم، العميل، الجهاز، الرقم التسلسلي…" style="width:260px">
      ${can('maintenance', 'add') ? '<button class="btn primary" id="add">➕ استلام جهاز</button>' : ''}</div>
    <div class="grid cols-4" style="margin-bottom:12px">${Object.entries(SVC).filter(([k]) => k !== 'cancelled').map(([k, [l]]) => `<button class="card stat" type="button" data-fs="${k}" style="text-align:right;cursor:pointer"><span class="k">${l}</span><span class="v" style="font-size:20px">${rows.filter(t => t.status === k).length}</span></button>`).join('')}</div>
    <div class="card table-wrap"><table class="t rep"><thead><tr><th>الرقم</th><th>الاستلام</th><th>العميل</th><th>الهاتف</th><th>الجهاز</th><th>المشكلة</th><th>الفني</th><th>التقدير</th><th>الموعد</th><th>الحالة</th></tr></thead><tbody id="tb"></tbody></table></div>`;
  let fs = '';
  const draw = () => { const q = v.querySelector('#q').value.trim().toLowerCase();
    const list = rows.filter(t => (!fs || t.status === fs) && (!q || [String(t.ticket_no), t.customer_name, pById[t.party_id]?.name, t.device, t.serial_no, t.phone].some(x => (x || '').toLowerCase().includes(q))));
    v.querySelector('#tb').innerHTML = list.map(t => `<tr class="clickable" data-open="${t.id}"><td><b>${t.ticket_no}</b></td><td>${fmtDate(t.received_at)}</td><td>${esc(pById[t.party_id]?.name || t.customer_name || '')}</td>
      <td dir="ltr" style="text-align:right">${esc(t.phone || '')}</td><td>${esc(t.device)}${t.serial_no ? ` <span class="muted" style="font-size:11px">${esc(t.serial_no)}</span>` : ''}</td><td>${esc(t.problem || '')}</td><td>${esc(t.technician || '')}</td>
      <td class="n">${num(t.estimate) ? fmtNum(t.estimate) : ''}</td><td>${t.promised_at ? fmtDate(t.promised_at) + (t.promised_at < today() && !['delivered', 'cancelled', 'ready'].includes(t.status) ? ' <span class="badge bad">متأخر</span>' : '') : ''}</td>
      <td><span class="badge ${SVC[t.status][1]}">${SVC[t.status][0]}</span></td></tr>`).join('') || '<tr><td colspan="10" class="empty">ما في بطاقات</td></tr>'; };
  draw();
  v.querySelector('#q').oninput = draw;
  v.querySelectorAll('[data-fs]').forEach(b => b.onclick = () => { fs = fs === b.dataset.fs ? '' : b.dataset.fs; v.querySelectorAll('[data-fs]').forEach(x => x.style.outline = x.dataset.fs === fs ? '2px solid var(--brand)' : ''); draw(); });
  const open = (t) => {
    const isNew = !t, ro = (isNew ? !can('maintenance', 'add') : !can('maintenance', 'edit')) ? 'disabled' : '';
    t = t || { received_at: today(), status: 'received', estimate: 0 };
    const m = modal({ title: isNew ? '➕ استلام جهاز للصيانة' : `🔧 بطاقة صيانة رقم ${t.ticket_no}`, body: `<form id="sf"><div class="grid cols-3">
      <div class="field"><label>تاريخ الاستلام</label><input type="date" name="received_at" value="${esc(t.received_at)}" ${ro}></div>
      <div class="field" style="grid-column:span 2"><label>العميل (بطاقة)</label><input id="party" list="party-list" value="${esc(partyLabel(pById[t.party_id]))}" ${ro}>${partyDatalist(custs)}</div>
      <div class="field"><label>اسم العميل</label><input name="customer_name" value="${esc(t.customer_name || '')}" ${ro}></div>
      <div class="field"><label>الهاتف</label><input name="phone" dir="ltr" value="${esc(t.phone || '')}" ${ro}></div>
      <div class="field"><label>الحالة</label><select name="status" ${ro}>${Object.entries(SVC).map(([k, [l]]) => `<option value="${k}" ${k === t.status ? 'selected' : ''}>${l}</option>`).join('')}</select></div>
      <div class="field"><label>الجهاز *</label><input name="device" value="${esc(t.device || '')}" ${ro}></div>
      <div class="field"><label>الرقم التسلسلي</label><input name="serial_no" dir="ltr" value="${esc(t.serial_no || '')}" ${ro}></div>
      <div class="field"><label>الملحقات المستلمة</label><input name="accessories" value="${esc(t.accessories || '')}" placeholder="شاحن، شنطة…" ${ro}></div>
      <div class="field" style="grid-column:span 3"><label>المشكلة</label><input name="problem" value="${esc(t.problem || '')}" ${ro}></div>
      <div class="field"><label>الفني</label><input name="technician" value="${esc(t.technician || '')}" ${ro}></div>
      <div class="field"><label>الكلفة التقديرية</label><input name="estimate" dir="ltr" value="${num(t.estimate) || ''}" ${ro}></div>
      <div class="field"><label>موعد التسليم</label><input type="date" name="promised_at" value="${esc(t.promised_at || '')}" ${ro}></div>
      <div class="field" style="grid-column:span 3"><label>الشغل اللي انعمل</label><input name="work_done" value="${esc(t.work_done || '')}" ${ro}></div>
      <div class="field" style="grid-column:span 3"><label>ملاحظات</label><input name="notes" value="${esc(t.notes || '')}" ${ro}></div></div></form>`,
      foot: `${ro ? '' : '<button class="btn primary" data-save>💾 حفظ</button>'}
        ${!isNew && !t.invoice_id && can('sales_invoices', 'add') ? '<button class="btn" data-inv>🧾 فاتورة صيانة</button>' : ''}
        ${!isNew && t.invoice_id ? '<span class="muted">إلها فاتورة</span>' : ''}
        <button class="btn" data-print>🖨️ إيصال استلام</button><button class="btn" data-close>إغلاق</button>` });
    m.el.querySelector('.modal').style.maxWidth = '900px';
    if (!isNew) attachAudit(m.el, t);
    const save = async () => {
      const d = formData(m.el.querySelector('#sf')); const pv = m.el.querySelector('#party').value, p = resolveParty(custs, pv);
      if (pv && !p) { toast('العميل مش موجود بالقائمة', 'err'); return null; }
      if (!d.device?.trim()) { toast('اكتب الجهاز', 'err'); return null; }
      const rec = { ...d, party_id: p?.id || null, customer_name: d.customer_name || p?.name || null, phone: d.phone || p?.mobile || null, estimate: num(d.estimate), promised_at: d.promised_at || null };
      const r = isNew ? await sb.from('service_tickets').insert({ ...rec, company_id: S.company.id }).select().single() : await sb.from('service_tickets').update(rec).eq('id', t.id).select().single();
      if (r.error) { toast(arError(r.error), 'err'); return null; }
      return r.data;
    };
    m.el.querySelector('[data-save]')?.addEventListener('click', async () => { const x = await save(); if (x) { toast('انحفظت', 'ok'); m.close(); viewService(v, ctx); } });
    m.el.querySelector('[data-inv]')?.addEventListener('click', async () => {
      const x = ro ? t : await save(); if (!x) return; m.close();
      openInvoicePrefill('sale', { inv: { inv_type: 'sale', party_id: x.party_id, party_name: x.customer_name, payment_type: x.party_id ? 'credit' : 'cash', notes: `صيانة ${x.device}` },
        lines: [{ description: `صيانة ${x.device}${x.serial_no ? ' (' + x.serial_no + ')' : ''}${x.work_done ? ' — ' + x.work_done : ''}`, qty: 1, unit_price: num(x.estimate), discount: 0, tax_rate: 16 }],
        ref: `بطاقة صيانة رقم ${x.ticket_no}`,
        onSaved: async (invId) => { const { error } = await sb.from('service_tickets').update({ invoice_id: invId }).eq('id', x.id); if (error) toast(arError(error), 'err'); } }, ctx);
    });
    m.el.querySelector('[data-print]').onclick = () => {
      const w = window.open('', '_blank'); if (!w) return toast('اسمح بالنوافذ المنبثقة', 'err');
      w.document.write(`<html dir="rtl"><head><meta charset="utf-8"><title>إيصال استلام</title><style>body{font-family:Tahoma,Arial;padding:20px;max-width:600px;margin:auto}td{padding:6px;border-bottom:1px solid #ddd}h2{margin:0}</style></head><body>
        <h2>${esc(S.company.name)}</h2><p>إيصال استلام جهاز للصيانة رقم <b>${esc(t.ticket_no || '')}</b> — ${fmtDate(t.received_at)}</p>
        <table style="width:100%;border-collapse:collapse">${[['العميل', pById[t.party_id]?.name || t.customer_name], ['الهاتف', t.phone], ['الجهاز', t.device], ['الرقم التسلسلي', t.serial_no], ['الملحقات', t.accessories], ['المشكلة', t.problem], ['الكلفة التقديرية', num(t.estimate) ? fmtNum(t.estimate) : ''], ['موعد التسليم', t.promised_at ? fmtDate(t.promised_at) : '']].map(([a, b]) => `<tr><td><b>${a}</b></td><td>${esc(b || '')}</td></tr>`).join('')}</table>
        <p style="margin-top:40px">توقيع المستلم: ____________ &nbsp;&nbsp; توقيع العميل: ____________</p><script>print()<\/script></body></html>`); w.document.close();
    };
  };
  v.querySelector('#add')?.addEventListener('click', () => open(null));
  v.querySelector('#tb').onclick = (e) => { const tr = e.target.closest('[data-open]'); if (tr) open(rows.find(t => t.id === tr.dataset.open)); };
}

// ---------------------------------------------------------------------
//  تنسيق الحقول: إخفاء، تسمية، إلزامي — لبطاقات العملاء والموردين والأصناف
// ---------------------------------------------------------------------
export const FIELD_DEFS = {
  customer: { label: 'بطاقة العميل', fields: { trade_name: 'الاسم التجاري', tax_no: 'الرقم الضريبي', national_no: 'الرقم الوطني', category_id: 'الفئة', sales_rep_id: 'المندوب', contact_person: 'الشخص المسؤول', mobile: 'الموبايل', phone: 'الهاتف', email: 'الإيميل', city: 'المدينة', address: 'العنوان', credit_limit: 'سقف الائتمان', payment_terms_days: 'مدة السداد' } },
  supplier: { label: 'بطاقة المورد', fields: { trade_name: 'الاسم التجاري', tax_no: 'الرقم الضريبي', national_no: 'الرقم الوطني', category_id: 'الفئة', contact_person: 'الشخص المسؤول', mobile: 'الموبايل', phone: 'الهاتف', email: 'الإيميل', city: 'المدينة', address: 'العنوان', credit_limit: 'سقف الائتمان', payment_terms_days: 'مدة السداد' } },
  item: { label: 'بطاقة الصنف', fields: { category_id: 'الفئة', barcode: 'الباركود', unit: 'الوحدة', sale_price: 'سعر البيع', purchase_price: 'سعر الشراء', tax_rate: 'نسبة الضريبة' } },
};
export async function loadFieldLayout(force = false) {
  if (!S.company) return {};
  if (!force && S._fl?.cid === S.company.id) return S._fl.v;
  const { data } = await sb.from('company_settings').select('field_layout').eq('company_id', S.company.id).maybeSingle();
  S._fl = { cid: S.company.id, v: data?.field_layout || {} }; return S._fl.v;
}
// بعد ما ينرسم النموذج
export function applyLayout(form, entity) {
  const L = (S._fl?.cid === S.company?.id ? S._fl.v : {})[entity] || {};
  for (const [k, c] of Object.entries(L)) {
    const el = form.querySelector(`[name="${CSS.escape(k)}"]`); if (!el) continue;
    const box = el.closest('.field'); if (!box) continue;
    const lab = box.querySelector('label');
    if (c.label && lab) lab.textContent = c.label + (c.required ? ' *' : '');
    else if (c.required && lab && !lab.textContent.includes('*')) lab.textContent += ' *';
    if (c.hide && !c.required) box.style.display = 'none';
  }
}
export function checkRequired(form, entity) {
  const L = (S._fl?.cid === S.company?.id ? S._fl.v : {})[entity] || {};
  for (const [k, c] of Object.entries(L)) { if (!c.required) continue; const el = form.querySelector(`[name="${CSS.escape(k)}"]`);
    if (el && !String(el.value || '').trim()) return `«${c.label || FIELD_DEFS[entity]?.fields[k] || k}» مطلوب`; }
  return null;
}
async function viewFieldLayout(v) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const ent = FIELD_DEFS[qs().get('e')] ? qs().get('e') : 'customer', D = FIELD_DEFS[ent];
  const all = JSON.parse(JSON.stringify(await loadFieldLayout(true))); const L = all[ent] || {};
  const ed = can('companies', 'edit');
  v.innerHTML = `<div class="page-head"><h2>🧱 تنسيق الحقول</h2><div class="spacer"></div>${ed ? '<button class="btn primary" id="save">💾 حفظ</button>' : ''}</div>
    <div class="tabs lk-tabs">${Object.entries(FIELD_DEFS).map(([k, x]) => `<a class="tab ${k === ent ? 'active' : ''}" href="#/field-layout?e=${k}">${x.label}</a>`).join('')}</div>
    <p class="muted" style="font-size:13px;margin:8px 0">لكل حقل: بتقدر تغيّر اسمه اللي بيطلع، أو تخفيه عن الشاشة، أو تخلّيه إلزامي (الإلزامي ما بينخفى). الاسم والرمز دايماً موجودين.</p>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الحقل</th><th>الاسم اللي بيطلع</th><th>مخفي</th><th>إلزامي</th></tr></thead>
      <tbody>${Object.entries(D.fields).map(([k, l]) => `<tr data-k="${k}"><td><b>${esc(l)}</b></td><td><input data-f="label" value="${esc(L[k]?.label || '')}" placeholder="${esc(l)}" ${ed ? '' : 'disabled'}></td>
        <td><input type="checkbox" data-f="hide" ${L[k]?.hide ? 'checked' : ''} ${ed ? '' : 'disabled'}></td><td><input type="checkbox" data-f="required" ${L[k]?.required ? 'checked' : ''} ${ed ? '' : 'disabled'}></td></tr>`).join('')}</tbody></table></div>`;
  v.querySelector('#save')?.addEventListener('click', async () => {
    const out = {};
    v.querySelectorAll('tr[data-k]').forEach(tr => { const label = tr.querySelector('[data-f=label]').value.trim(), hide = tr.querySelector('[data-f=hide]').checked, required = tr.querySelector('[data-f=required]').checked;
      if (label || hide || required) out[tr.dataset.k] = { ...(label ? { label } : {}), ...(hide ? { hide } : {}), ...(required ? { required } : {}) }; });
    all[ent] = out;
    const { data: saved, error } = await sb.from('company_settings').upsert({ company_id: S.company.id, field_layout: all }, { onConflict: 'company_id' }).select('company_id');
    if (error) return toast(arError(error), 'err');
    if (!saved?.length) return toast('ما انحفظ — تأكد من صلاحية تعديل بيانات الشركة', 'err');
    S._fl = { cid: S.company.id, v: all }; toast('انحفظ التنسيق', 'ok');
  });
}

// ---------------------------------------------------------------------
//  تنسيق التقارير: زر «الأعمدة» على أي جدول تقرير، والاختيار بينحفظ لكل مستخدم
// ---------------------------------------------------------------------
const COLKEY = 'sumou.cols';
const colStore = () => { try { return JSON.parse(localStorageGet(COLKEY) || '{}'); } catch { return {}; } };
function colStyle() {
  let el = document.getElementById('col-style'); if (!el) { el = document.createElement('style'); el.id = 'col-style'; document.head.appendChild(el); }
  const st = colStore();
  el.textContent = Object.entries(st).flatMap(([k, cols]) => cols.map(n => `table[data-ck="${CSS.escape(k)}"] > thead > tr > :nth-child(${n}), table[data-ck="${CSS.escape(k)}"] > tbody > tr:not(.stmt-row) > :nth-child(${n}){display:none}`)).join('\n');
}
export function enhanceReportTables(view, route) {
  colStyle();
  // الجداول اللي بتنرسم بعدين (بعد «عرض»)
  view._colRoute = route;
  if (!view._colObs) { view._colObs = new MutationObserver(() => { clearTimeout(view._colT); view._colT = setTimeout(() => enhanceReportTables(view, view._colRoute), 50); });
    view._colObs.observe(view, { childList: true, subtree: true }); }
  const tables = [...view.querySelectorAll('table.rep')].filter(t => !t.closest('.stmt-row') && !t.closest('.modal') && t.querySelectorAll(':scope > thead > tr').length <= 1);
  tables.forEach((t, i) => {
    if (t.dataset.ck) return;
    const key = route.split('?')[0] + '#' + i; t.dataset.ck = key;
    const holder = t.closest('.card') || t.closest('.table-wrap') || t.parentElement;
    let bar = holder.previousElementSibling;
    if (!bar?.classList.contains('col-bar')) { bar = document.createElement('div'); bar.className = 'no-print col-bar'; holder.parentElement.insertBefore(bar, holder); }
    bar.innerHTML = ''; const b = document.createElement('button'); b.type = 'button'; b.className = 'btn sm'; b.textContent = '⚙️ الأعمدة'; bar.appendChild(b);
    b.onclick = () => {
      const ths = [...t.querySelectorAll('thead tr:first-child > th')]; if (!ths.length) return toast('اعرض التقرير أول', 'err');
      const st = colStore(), hidden = new Set(st[key] || []);
      const m = modal({ title: '⚙️ الأعمدة اللي بتطلع', size: 'sm', body: ths.map((th, j) => `<label class="check" style="display:flex;margin:6px 0"><input type="checkbox" data-n="${j + 1}" ${hidden.has(j + 1) ? '' : 'checked'}> ${esc(th.textContent.trim() || '#')}</label>`).join('')
        + '<p class="muted" style="font-size:12px">الاختيار بينحفظ على هالجهاز لهالتقرير.</p>', foot: '<button class="btn primary" data-ok>تطبيق</button><button class="btn" data-reset>رجّع الكل</button><button class="btn" data-close>إلغاء</button>' });
      m.el.querySelector('[data-ok]').onclick = () => { const off = [...m.el.querySelectorAll('[data-n]')].filter(x => !x.checked).map(x => +x.dataset.n); const s = colStore();
        if (off.length) s[key] = off; else delete s[key]; localStorageSet(COLKEY, JSON.stringify(s)); colStyle(); m.close(); };
      m.el.querySelector('[data-reset]').onclick = () => { const s = colStore(); delete s[key]; localStorageSet(COLKEY, JSON.stringify(s)); colStyle(); m.close(); };
    };
  });
}

export const MFG_ROUTES = { 'boms': viewBoms, 'production': viewProduction, 'service': viewService, 'field-layout': viewFieldLayout };
