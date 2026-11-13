// =====================================================================
//  السمو ERP — الكلفة المحمّلة (route landed-costs)
//  مستند بيوزّع مصاريف الشحن والجمارك والتخليص على أصناف فواتير شراء مرحّلة (بالقيمة أو بالكمية).
//  الكتابة من الدوال بس: landed_save / landed_post / landed_cancel / landed_delete، والمعاينة landed_preview.
// =====================================================================
import { S, sb, esc, fmtDate, fmtNum, num, today, toast, arError, modal, confirmBox, can, fmtQty, qm } from './core.js';
import { loadParties, partyLabel, partyDatalist, resolveParty } from './parties.js';
import { loadAccounts, accountDatalist, resolveAccount, accLabel } from './finance.js';
import { loadItems } from './invoices.js';
import { printDoc, amountToWords } from './print.js';
import { docNo } from './numbering.js';

const ST = { draft: ['مسودة', 'warn'], posted: ['مرحّل', 'ok'], cancelled: ['ملغى', 'bad'] };
const badge = (s) => `<span class="badge ${ST[s][1]}">${ST[s][0]}</span>`;

async function viewLanded(v, ctx) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const { data, error } = await sb.from('landed_costs').select('*').eq('company_id', S.company.id).order('doc_no', { ascending: false }).limit(500);
  if (error) throw error;
  v.innerHTML = `<div class="page-head"><h2>🚢 الكلفة المحمّلة</h2><span class="badge brand">${data.length}</span><div class="spacer"></div>
      ${can('landed_costs', 'add') ? '<button class="btn primary" id="add">➕ مستند جديد</button>' : ''}</div>
    <p class="muted" style="margin-top:-6px">وزّع مصاريف الشحن والجمارك والتخليص على أصناف فواتير الشراء، فبترتفع كلفة الصنف بالمخزون. الجزء اللي انباع قبل المستند بيروح لكلفة المبيعات (بالجرد المستمر).</p>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرقم</th><th>التاريخ</th><th>البيان</th><th>التوزيع</th><th style="text-align:left">المجموع</th><th>الحالة</th></tr></thead><tbody>
      ${data.map(r => `<tr class="click" data-id="${r.id}"><td>${r.doc_no}</td><td>${fmtDate(r.doc_date)}</td><td>${esc(r.description || '')}</td><td>${r.method === 'qty' ? 'بالكمية' : 'بالقيمة'}</td>
        <td class="n">${fmtNum(r.total)}</td><td>${badge(r.status)}</td></tr>`).join('') || '<tr><td colspan="6" class="empty">ما في مستندات. اضغط «مستند جديد».</td></tr>'}
    </tbody></table></div>`;
  v.querySelector('#add')?.addEventListener('click', () => editor(null, ctx));
  v.querySelectorAll('tr[data-id]').forEach(tr => tr.onclick = () => editor(data.find(x => x.id === tr.dataset.id), ctx));
}

async function editor(doc, ctx) {
  const [parties, accs, items] = await Promise.all([loadParties(), loadAccounts(), loadItems()]);
  const sups = parties.filter(p => p.is_active && p.party_type !== 'customer');
  const pById = Object.fromEntries(parties.map(p => [p.id, p])), aById = Object.fromEntries(accs.map(a => [a.id, a])), iById = Object.fromEntries(items.map(i => [i.id, i]));
  let selInv = [], charges = [{ desc: '', party: '', acc: '', amount: '' }];
  if (doc) {
    const [li, lc] = await Promise.all([sb.from('landed_cost_invoices').select('invoice_id').eq('landed_id', doc.id), sb.from('landed_cost_charges').select('*').eq('landed_id', doc.id).order('line_no')]);
    selInv = (li.data || []).map(x => x.invoice_id);
    charges = (lc.data || []).map(c => ({ desc: c.description || '', party: c.party_id ? partyLabel(pById[c.party_id]) : '', acc: c.party_id ? '' : accLabel(aById[c.account_id]), amount: c.amount }));
  }
  const ro = doc && doc.status !== 'draft' || (doc ? !can('landed_costs', 'edit') : !can('landed_costs', 'add'));
  const dis = ro ? 'disabled' : '';
  // فواتير الشراء المرحّلة للمحاسبة والمخزون (آخر 300) + المختارة
  const { data: invs } = await sb.from('invoices').select('id,inv_no,doc_code,inv_date,party_id,subtotal,total,status,stock_posted')
    .eq('company_id', S.company.id).eq('inv_type', 'purchase').eq('status', 'posted').eq('stock_posted', true).order('inv_date', { ascending: false }).limit(300);
  const invList = invs || [];
  const missing = selInv.filter(id => !invList.some(i => i.id === id));
  if (missing.length) { const { data: more } = await sb.from('invoices').select('id,inv_no,doc_code,inv_date,party_id,subtotal,total,status,stock_posted').in('id', missing); invList.push(...(more || [])); }
  const d = doc || { doc_date: today(), description: '', method: 'value' };
  const m = modal({ title: doc ? `كلفة محمّلة رقم ${doc.doc_no}` : 'كلفة محمّلة جديدة', body: `
    ${doc ? `<div style="margin:-6px 0 10px">${badge(doc.status)}</div>` : ''}
    <div class="grid cols-3">
      <div class="field"><label>التاريخ *</label><input type="date" id="l-date" value="${esc(d.doc_date)}" ${dis}></div>
      <div class="field"><label>طريقة التوزيع</label><select id="l-method" ${dis}><option value="value" ${d.method === 'value' ? 'selected' : ''}>حسب قيمة الصنف بالفاتورة</option><option value="qty" ${d.method === 'qty' ? 'selected' : ''}>حسب الكمية</option></select></div>
      <div class="field"><label>البيان</label><input id="l-desc" value="${esc(d.description || '')}" placeholder="مثلاً: شحنة الصين — شحن وجمارك" ${dis}></div></div>
    <h4 style="margin:10px 0 6px">1) فواتير الشراء <span class="muted" style="font-size:12px;font-weight:400">(المرحّلة للمحاسبة والمخزون)</span></h4>
    ${ro ? '' : '<input class="search" id="l-q" placeholder="بحث برقم الفاتورة أو المورد…" style="margin-bottom:6px">'}
    <div class="table-wrap" style="max-height:220px;overflow:auto"><table class="t"><thead><tr><th style="width:34px"></th><th>رقم الفاتورة</th><th>التاريخ</th><th>المورد</th><th style="text-align:left">قبل الضريبة</th></tr></thead><tbody id="l-invs"></tbody></table></div>
    <h4 style="margin:12px 0 6px">2) المصاريف المحمّلة</h4>
    ${partyDatalist(sups, 'lc-parties')}${accountDatalist(accs, 'lc-accs')}
    <div class="table-wrap"><table class="t lines"><thead><tr><th>البيان</th><th>المورد (شركة الشحن، المخلّص…)</th><th>أو الحساب (صندوق، بنك…)</th><th style="width:130px">المبلغ</th><th style="width:36px"></th></tr></thead><tbody id="l-ch"></tbody>
      <tfoot><tr><td colspan="3">${ro ? '' : '<button class="btn sm" type="button" id="l-addch">➕ مصروف</button>'}</td><td class="n"><b id="l-tot"></b></td><td></td></tr></tfoot></table></div>
    <div id="l-prev"></div>`,
    foot: `${!ro ? '<button class="btn primary" data-save>💾 حفظ</button>' : ''}
      ${doc ? '<button class="btn" data-prev>🔍 التوزيع على الأصناف</button>' : ''}
      ${doc?.status === 'draft' && can('landed_costs', 'post') ? '<button class="btn" data-post>✔ ترحيل</button>' : ''}
      ${doc?.status === 'posted' && can('landed_costs', 'post') ? '<button class="btn" data-cancel>↩️ إلغاء</button>' : ''}
      ${doc && doc.status !== 'draft' && can('landed_costs', 'print') ? '<button class="btn" data-print>🖨️ طباعة</button>' : ''}
      ${doc?.status === 'draft' && can('landed_costs', 'delete') ? '<button class="btn danger" data-del style="margin-inline-start:auto">حذف</button>' : ''}
      <button class="btn" data-close>إغلاق</button>` });
  m.el.querySelector('.modal').style.maxWidth = '1050px';
  const invTb = m.el.querySelector('#l-invs');
  const drawInv = () => {
    const q = (m.el.querySelector('#l-q')?.value || '').trim().toLowerCase();
    const list = ro ? invList.filter(i => selInv.includes(i.id)) : invList.filter(i => selInv.includes(i.id) || !q || [docNo(i), pById[i.party_id]?.name].some(x => qm(String(x || ''), q)));
    invTb.innerHTML = list.map(i => `<tr><td><input type="checkbox" data-inv="${i.id}" ${selInv.includes(i.id) ? 'checked' : ''} ${dis}></td><td>${esc(docNo(i))}</td><td>${fmtDate(i.inv_date)}</td>
      <td>${esc(pById[i.party_id]?.name || '')}</td><td class="n">${fmtNum(i.subtotal)}</td></tr>`).join('') || '<tr><td colspan="5" class="empty">ما في فواتير شراء مرحّلة للمحاسبة والمخزون.</td></tr>';
  };
  drawInv();
  m.el.querySelector('#l-q')?.addEventListener('input', drawInv);
  invTb.addEventListener('change', (e) => { const id = e.target.dataset.inv; if (!id) return; selInv = e.target.checked ? [...new Set([...selInv, id])] : selInv.filter(x => x !== id); });
  const chTb = m.el.querySelector('#l-ch');
  const tot = () => { m.el.querySelector('#l-tot').textContent = fmtNum(charges.reduce((s, c) => s + num(c.amount), 0)); };
  const drawCh = () => {
    chTb.innerHTML = charges.map((c, i) => `<tr><td><input class="cell" data-i="${i}" data-k="desc" value="${esc(c.desc)}" placeholder="شحن، جمارك، تخليص، تأمين…" ${dis}></td>
      <td><input class="cell" list="lc-parties" data-i="${i}" data-k="party" value="${esc(c.party)}" ${dis}></td>
      <td><input class="cell" list="lc-accs" data-i="${i}" data-k="acc" value="${esc(c.acc)}" ${dis}></td>
      <td><input class="cell n" dir="ltr" inputmode="decimal" data-i="${i}" data-k="amount" value="${c.amount}" ${dis}></td>
      <td>${ro ? '' : `<button class="x" type="button" data-rm="${i}">×</button>`}</td></tr>`).join('');
    tot();
  };
  drawCh();
  chTb.addEventListener('input', (e) => { const t = e.target; if (!t.dataset.k) return; charges[+t.dataset.i][t.dataset.k] = t.value; if (t.dataset.k === 'amount') tot(); });
  chTb.addEventListener('click', (e) => { const b = e.target.closest('[data-rm]'); if (!b) return; charges.splice(+b.dataset.rm, 1); if (!charges.length) charges.push({ desc: '', party: '', acc: '', amount: '' }); drawCh(); });
  m.el.querySelector('#l-addch')?.addEventListener('click', () => { charges.push({ desc: '', party: '', acc: '', amount: '' }); drawCh(); });

  const showPreview = async (id) => {
    const { data, error } = await sb.rpc('landed_preview', { p_id: id });
    if (error) return toast(arError(error), 'err');
    const rows = doc?.status && doc.status !== 'draft' ? ((await sb.from('landed_cost_allocs').select('*').eq('landed_id', id)).data || []).map(r => ({ ...r, on_hand: null })) : data;
    const sum = (k) => rows.reduce((s, r) => s + num(r[k]), 0);
    m.el.querySelector('#l-prev').innerHTML = `<h4 style="margin:12px 0 6px">3) التوزيع على الأصناف ${doc?.status === 'posted' ? '(المرحّل)' : '(معاينة)'}</h4>
      <div class="table-wrap"><table class="t"><thead><tr><th>الصنف</th><th style="text-align:left">الكمية المشتراة</th><th style="text-align:left">القيمة</th><th style="text-align:left">نصيبه</th><th style="text-align:left">الكلفة الإضافية للوحدة</th><th style="text-align:left">على المخزون</th><th style="text-align:left">على كلفة المبيعات</th></tr></thead><tbody>
      ${rows.map(r => `<tr><td>${esc(iById[r.item_id] ? iById[r.item_id].code + ' — ' + iById[r.item_id].name : '')}</td><td class="n">${fmtQty(r.qty)}</td><td class="n">${fmtNum(r.base_value)}</td><td class="n"><b>${fmtNum(r.amount)}</b></td>
        <td class="n">${num(r.qty) ? fmtNum(num(r.amount) / num(r.qty)) : ''}</td><td class="n">${fmtNum(r.to_stock)}</td><td class="n">${fmtNum(r.to_cogs)}</td></tr>`).join('') || '<tr><td colspan="7" class="empty">ما في أصناف مخزنية بالفواتير المختارة.</td></tr>'}
      </tbody><tfoot><tr><td colspan="3"><b>المجموع</b></td><td class="n"><b>${fmtNum(sum('amount'))}</b></td><td></td><td class="n"><b>${fmtNum(sum('to_stock'))}</b></td><td class="n"><b>${fmtNum(sum('to_cogs'))}</b></td></tr></tfoot></table></div>`;
    return rows;
  };
  const reopen = async (id) => { m.close(); ctx.rerender(); const { data } = await sb.from('landed_costs').select('*').eq('id', id).single(); if (data) editor(data, ctx); };
  const save = async () => {
    const out = [];
    for (const [i, c] of charges.entries()) {
      if (!c.desc && !c.party && !c.acc && !num(c.amount)) continue;
      const p = c.party ? resolveParty(parties, c.party) : null, a = c.acc ? resolveAccount(accs, c.acc) : null;
      if (c.party && !p) return toast(`المصروف ${i + 1}: المورد مش موجود`, 'err');
      if (c.acc && !a) return toast(`المصروف ${i + 1}: اختار حساب فرعي من القائمة`, 'err');
      if (!p && !a) return toast(`المصروف ${i + 1}: اختار المورد أو الحساب`, 'err');
      if (!(num(c.amount) > 0)) return toast(`المصروف ${i + 1}: المبلغ مطلوب`, 'err');
      out.push({ description: c.desc || null, party_id: p?.id || null, account_id: p ? null : a.id, amount: num(c.amount) });
    }
    if (!selInv.length) return toast('اختار فاتورة شراء وحدة على الأقل', 'err');
    if (!out.length) return toast('أضف مصروف واحد على الأقل', 'err');
    { const { data: dup } = await sb.from('landed_cost_invoices').select('invoice_id,landed_costs!inner(doc_no,status)').in('invoice_id', selInv).neq('landed_id', doc?.id || '00000000-0000-0000-0000-000000000000');
      const live = (dup || []).filter(x => x.landed_costs?.status !== 'cancelled');
      if (live.length && !(await confirmBox(`انتبه: ${live.length === 1 ? 'فاتورة من المختارة موجودة' : 'في فواتير من المختارة موجودة'} بمستند كلفة محمّلة ثاني (رقم ${[...new Set(live.map(x => x.landed_costs.doc_no))].join('، ')}). متأكد إنه هالمصاريف مش مكررة؟`))) return; }
    const { data: id, error } = await sb.rpc('landed_save', { p: { id: doc?.id || null, company_id: S.company.id, doc_date: m.el.querySelector('#l-date').value,
      description: m.el.querySelector('#l-desc').value, method: m.el.querySelector('#l-method').value, invoices: selInv, charges: out } });
    if (error) return toast(arError(error), 'err');
    toast('تم الحفظ', 'ok'); reopen(id);
  };
  m.el.querySelector('[data-save]')?.addEventListener('click', save);
  m.el.querySelector('[data-prev]')?.addEventListener('click', () => showPreview(doc.id));
  m.el.querySelector('[data-post]')?.addEventListener('click', async () => {
    if (!(await confirmBox(`ترحيل الكلفة المحمّلة رقم ${doc.doc_no} بمبلغ ${fmtNum(doc.total)}؟ بينعمل قيد وبترتفع كلفة الأصناف.`))) return;
    const { error } = await sb.rpc('landed_post', { p_id: doc.id }); if (error) return toast(arError(error), 'err');
    toast('انرحّل', 'ok'); reopen(doc.id);
  });
  m.el.querySelector('[data-cancel]')?.addEventListener('click', async () => {
    const dt = prompt('تاريخ الإلغاء (YYYY-MM-DD):', today()); if (!dt) return;
    const { error } = await sb.rpc('landed_cancel', { p_id: doc.id, p_date: dt }); if (error) return toast(arError(error), 'err');
    toast('انلغى بقيد عكسي', 'ok'); reopen(doc.id);
  });
  m.el.querySelector('[data-del]')?.addEventListener('click', async () => {
    if (!(await confirmBox(`حذف المستند رقم ${doc.doc_no}؟`))) return;
    const { error } = await sb.rpc('landed_delete', { p_id: doc.id }); if (error) return toast(arError(error), 'err');
    toast('انحذف', 'ok'); m.close(); ctx.rerender();
  });
  m.el.querySelector('[data-print]')?.addEventListener('click', async () => {
    const rows = await showPreview(doc.id) || [];
    const inv = invList.filter(i => selInv.includes(i.id));
    printDoc(`كلفة محمّلة رقم ${doc.doc_no}`, `
      <table class="meta"><tr><td><b>التاريخ:</b> ${fmtDate(doc.doc_date)}</td><td><b>التوزيع:</b> ${doc.method === 'qty' ? 'بالكمية' : 'بالقيمة'}</td><td><b>الحالة:</b> ${ST[doc.status][0]}</td></tr>
        <tr><td colspan="3"><b>البيان:</b> ${esc(doc.description || '')}</td></tr>
        <tr><td colspan="3"><b>فواتير الشراء:</b> ${inv.map(i => esc(docNo(i)) + ' (' + esc(pById[i.party_id]?.name || '') + ')').join('، ')}</td></tr></table>
      <table class="pt"><thead><tr><th>#</th><th>المصروف</th><th>الجهة</th><th>المبلغ</th></tr></thead><tbody>
        ${charges.map((c, i) => `<tr><td>${i + 1}</td><td>${esc(c.desc)}</td><td>${esc(c.party || c.acc)}</td><td class="n">${fmtNum(c.amount)}</td></tr>`).join('')}</tbody>
        <tfoot><tr><td colspan="3"><b>المجموع</b> — ${amountToWords(doc.total)}</td><td class="n"><b>${fmtNum(doc.total)}</b></td></tr></tfoot></table>
      <h4>التوزيع على الأصناف</h4>
      <table class="pt"><thead><tr><th>الصنف</th><th>الكمية</th><th>القيمة</th><th>نصيبه</th><th>للوحدة</th></tr></thead><tbody>
        ${rows.map(r => `<tr><td>${esc(iById[r.item_id]?.name || '')}</td><td class="n">${fmtQty(r.qty)}</td><td class="n">${fmtNum(r.base_value)}</td><td class="n">${fmtNum(r.amount)}</td><td class="n">${num(r.qty) ? fmtNum(num(r.amount) / num(r.qty)) : ''}</td></tr>`).join('')}</tbody></table>`);
  });
  if (doc) showPreview(doc.id);
}

export const LANDED_ROUTES = { 'landed-costs': viewLanded };
