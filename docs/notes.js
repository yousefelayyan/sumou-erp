// =====================================================================
//  السمو ERP — الإشعارات المدينة والدائنة (route notes?type=customer|supplier)
//  مستند على طرف بحساب مقابل وضريبة؛ الحفظ/الترحيل/الإلغاء/الحذف من الدوال note_save/note_post/note_cancel/note_delete.
// =====================================================================
import { S, sb, esc, fmtDate, fmtNum, num, toast, arError, modal, confirmBox, can, today, qm } from './core.js';
import { loadParties, partyLabel, partyDatalist, resolveParty } from './parties.js';
import { loadAccounts, leafAccounts, accLabel } from './finance.js';
import { deptField, deptValue } from './departments.js';
import { printDoc, amountToWords } from './print.js';

const qp = () => new URLSearchParams(location.hash.split('?')[1] || '');
const T = {
  customer: { screen: 'customer_notes', who: 'العميل', plural: 'العملاء', inv: 'sale',
    kinds: { credit: ['إشعار دائن', 'بينزّل ذمة العميل: خصم لاحق، تخفيض سعر، تعويض'], debit: ['إشعار مدين', 'بيزيد ذمة العميل: فرق سعر، مصاريف إضافية، فوائد تأخير'] } },
  supplier: { screen: 'supplier_notes', who: 'المورد', plural: 'الموردين', inv: 'purchase',
    kinds: { debit: ['إشعار مدين', 'بينزّل ذمتنا للمورد: خصم من المورد، تخفيض سعر، بضاعة ناقصة'], credit: ['إشعار دائن', 'بيزيد ذمتنا للمورد: فرق سعر، مصاريف إضافية'] } },
};
const ST = { draft: ['مسودة', 'warn'], posted: ['مرحّل', 'ok'], cancelled: ['ملغى', 'bad'] };

async function viewNotes(v, ctx) {
  if (!S.company || !S.fy) return void (v.innerHTML = '<div class="notice info">اختار شركة وسنة مالية أول.</div>');
  const type = qp().get('type') === 'supplier' ? 'supplier' : 'customer', D = T[type];
  const [{ data: rows, error }, parties] = await Promise.all([
    sb.from('party_notes').select('*').eq('company_id', S.company.id).eq('party_type', type).eq('fiscal_year_id', S.fy.id).order('note_date', { ascending: false }).order('note_no', { ascending: false }).limit(1000),
    loadParties()]);
  if (error) return void (v.innerHTML = `<div class="notice">${esc(arError(error))}</div>`);
  const pById = Object.fromEntries(parties.map(p => [p.id, p]));
  v.innerHTML = `<div class="page-head"><h2>🧾 إشعارات ${D.plural} (مدين / دائن)</h2><div class="spacer"></div>
      ${can(D.screen, 'add') ? Object.entries(D.kinds).map(([k, [l]]) => `<button class="btn ${k === Object.keys(D.kinds)[0] ? 'primary' : ''}" data-new="${k}">➕ ${l}</button>`).join(' ') : ''}</div>
    <div class="card" style="display:flex;gap:8px;flex-wrap:wrap;align-items:end;margin-bottom:10px">
      <div class="field" style="margin:0"><label>النوع</label><select id="f-k"><option value="">الكل</option>${Object.entries(D.kinds).map(([k, [l]]) => `<option value="${k}">${l}</option>`).join('')}</select></div>
      <div class="field" style="margin:0"><label>الحالة</label><select id="f-s"><option value="">الكل</option>${Object.entries(ST).map(([k, [l]]) => `<option value="${k}">${l}</option>`).join('')}</select></div>
      <div class="field" style="margin:0;flex:1;min-width:200px"><label>بحث</label><input id="f-q" placeholder="${D.who} أو بيان أو مرجع"></div></div>
    <div class="card table-wrap" id="tbl"></div>`;
  const draw = () => {
    const k = v.querySelector('#f-k').value, s = v.querySelector('#f-s').value, q = v.querySelector('#f-q').value.trim().toLowerCase();
    const list = (rows || []).filter(n => (!k || n.note_kind === k) && (!s || n.status === s)
      && (!q || qm(`${pById[n.party_id]?.name || ''} ${n.description || ''} ${n.reference || ''}`, q)));
    const sum = list.filter(n => n.status === 'posted').reduce((a, n) => a + (n.note_kind === 'debit' ? 1 : -1) * num(n.total), 0);
    v.querySelector('#tbl').innerHTML = `<table class="t"><thead><tr><th>النوع</th><th>الرقم</th><th>التاريخ</th><th>${D.who}</th><th>البيان</th><th style="text-align:left">المبلغ</th><th style="text-align:left">الضريبة</th><th style="text-align:left">المجموع</th><th>الحالة</th></tr></thead><tbody>
      ${list.map(n => `<tr class="click" data-open="${n.id}"><td><span class="badge ${n.note_kind === 'debit' ? 'warn' : 'ok'}">${D.kinds[n.note_kind][0]}</span></td><td><b>${n.note_no}</b></td><td>${fmtDate(n.note_date)}</td>
        <td>${esc(pById[n.party_id]?.name || '')}</td><td>${esc(n.description || '')}</td><td class="n">${fmtNum(n.amount)}</td><td class="n">${num(n.tax_amount) ? fmtNum(n.tax_amount) : ''}</td>
        <td class="n"><b>${fmtNum(n.total)}</b></td><td><span class="badge ${ST[n.status][1]}">${ST[n.status][0]}</span></td></tr>`).join('') || '<tr><td colspan="9" class="empty">ما في إشعارات</td></tr>'}</tbody>
      ${list.length ? `<tfoot><tr><th colspan="7">صافي المرحّل (المدين موجب)</th><th class="n">${fmtNum(sum)}</th><th></th></tr></tfoot>` : ''}</table>`;
  };
  draw();
  ['#f-k', '#f-s', '#f-q'].forEach(s => v.querySelector(s).addEventListener('input', draw));
  v.querySelectorAll('[data-new]').forEach(b => b.addEventListener('click', () => noteEditor(type, b.dataset.new, null, () => viewNotes(v, ctx))));
  v.querySelector('#tbl').addEventListener('click', (e) => { const tr = e.target.closest('[data-open]'); if (!tr) return; const n = rows.find(x => x.id === tr.dataset.open); noteEditor(type, n.note_kind, n, () => viewNotes(v, ctx)); });
}

async function noteEditor(type, kind, n, done) {
  const D = T[type], [kl, kd] = D.kinds[kind];
  const [parties, accs, { data: st }] = await Promise.all([loadParties(), loadAccounts(),
    sb.from('company_settings').select('default_tax_rate').eq('company_id', S.company.id).maybeSingle()]);
  const myP = parties.filter(p => p.party_type === type && (p.is_active || p.id === n?.party_id));
  const leaf = leafAccounts(accs).filter(a => !['customer', 'supplier'].includes(a.account_type));
  const ro = n && (n.status !== 'draft' || !can(D.screen, 'edit'));
  const n0 = n || { note_date: today() >= S.fy.start_date && today() <= S.fy.end_date ? today() : S.fy.start_date, amount: '', tax_rate: num(st?.default_tax_rate ?? 16), status: 'draft' };
  const p0 = parties.find(p => p.id === n0.party_id);
  const dept = await deptField(n?.department_id, ro ? 'disabled' : '', !n);
  const m = modal({ title: n ? `${kl} رقم ${n.note_no} — ${D.who}` : `${kl} جديد — ${D.who}`, body: `
    <div class="notice info" style="margin-bottom:10px">${kd}.</div>
    ${n ? `<p><span class="badge ${ST[n.status][1]}">${ST[n.status][0]}</span></p>` : ''}
    <form id="nf"><div class="grid cols-3">
      <div class="field"><label>التاريخ</label><input type="date" name="note_date" value="${esc(n0.note_date)}" ${ro ? 'disabled' : ''}></div>
      <div class="field" style="grid-column:span 2"><label>${D.who} *</label><input id="np" list="np-list" value="${esc(p0 ? partyLabel(p0) : '')}" ${ro ? 'disabled' : ''}>${partyDatalist(myP, 'np-list')}</div>
      <div class="field" style="grid-column:span 2"><label>الفاتورة المرجعية (اختياري)</label><select name="invoice_id" id="ninv" ${ro ? 'disabled' : ''}><option value="">—</option></select></div>
      <div class="field"><label>رقم المرجع</label><input name="reference" value="${esc(n0.reference || '')}" ${ro ? 'disabled' : ''}></div>
      <div class="field" style="grid-column:span 3"><label>الحساب المقابل * <small class="muted">(مثلاً خصم مسموح به / مكتسب، أو حساب الإيراد/المصروف)</small></label>
        <input id="nacc" list="nacc-list" value="${esc(accLabel(accs.find(a => a.id === n0.account_id)))}" ${ro ? 'disabled' : ''}><datalist id="nacc-list">${leaf.map(a => `<option value="${esc(accLabel(a))}"></option>`).join('')}</datalist></div>
      <div class="field"><label>المبلغ قبل الضريبة *</label><input name="amount" inputmode="decimal" value="${n0.amount || ''}" ${ro ? 'disabled' : ''}></div>
      <div class="field"><label>نسبة الضريبة %</label><input name="tax_rate" inputmode="decimal" value="${n0.tax_rate}" ${ro ? 'disabled' : ''}></div>
      <div class="field"><label>المجموع</label><input id="ntot" disabled></div>
      <div class="field" style="grid-column:span 3"><label>البيان</label><input name="description" value="${esc(n0.description || '')}" ${ro ? 'disabled' : ''}></div>
      ${dept}</div></form>`,
    foot: `${!ro ? '<button class="btn" data-save>💾 حفظ</button>' : ''}
      ${(!n || n.status === 'draft') && can(D.screen, 'post') && !ro ? '<button class="btn primary" data-post>✅ حفظ وترحيل</button>' : ''}
      ${n?.status === 'posted' && can(D.screen, 'post') ? '<button class="btn danger" data-cancel>⛔ إلغاء الإشعار</button>' : ''}
      ${n && n.status !== 'draft' && can(D.screen, 'print') ? '<button class="btn" data-print>🖨️ طباعة</button>' : ''}
      ${n?.status === 'draft' && can(D.screen, 'delete') ? '<button class="btn danger" data-del style="margin-inline-start:auto">حذف</button>' : ''}
      <button class="btn" data-close>إغلاق</button>` });
  m.el.querySelector('.modal').style.maxWidth = '820px';
  const f = m.el.querySelector('#nf');
  const tot = () => { const a = num(f.amount.value), r = num(f.tax_rate.value); m.el.querySelector('#ntot').value = fmtNum(a + Math.round(a * r / 100 * 1000) / 1000); };
  tot(); f.amount.addEventListener('input', tot); f.tax_rate.addEventListener('input', tot);
  const loadInv = async () => {
    const p = resolveParty(myP, m.el.querySelector('#np').value), sel = m.el.querySelector('#ninv');
    if (!p) { sel.innerHTML = '<option value="">—</option>'; return; }
    const { data } = await sb.from('invoices').select('id,inv_no,doc_code,inv_date,total').eq('company_id', S.company.id).eq('party_id', p.id).eq('inv_type', D.inv).eq('status', 'posted').order('inv_date', { ascending: false }).limit(200);
    sel.innerHTML = '<option value="">—</option>' + (data || []).map(i => `<option value="${i.id}" ${i.id === n0.invoice_id ? 'selected' : ''}>${esc(i.doc_code || String(i.inv_no))} — ${fmtDate(i.inv_date)} — ${fmtNum(i.total)}</option>`).join('');
  };
  loadInv(); m.el.querySelector('#np').addEventListener('change', loadInv);
  const payload = () => {
    const p = resolveParty(myP, m.el.querySelector('#np').value); if (!p) { toast(`اختار ${D.who} من القائمة`, 'err'); return null; }
    const c = m.el.querySelector('#nacc').value.split('—')[0].trim(), a = leaf.find(x => x.code === c);
    if (!a) { toast('اختار الحساب المقابل من القائمة', 'err'); return null; }
    if (num(f.amount.value) <= 0) { toast('المبلغ لازم أكبر من صفر', 'err'); return null; }
    return { id: n?.id || null, company_id: S.company.id, party_type: type, note_kind: kind, party_id: p.id, account_id: a.id, invoice_id: f.invoice_id.value || null,
      note_date: f.note_date.value, amount: num(f.amount.value), tax_rate: num(f.tax_rate.value), description: f.description.value, reference: f.reference.value, ...deptValue(f) };
  };
  const save = async (post) => {
    const pl = payload(); if (!pl) return;
    const { data: id, error } = await sb.rpc('note_save', { p: pl }); if (error) return toast(arError(error), 'err');
    if (post) { const r = await sb.rpc('note_post', { p_id: id }); if (r.error) { toast('انحفظ مسودة، بس الترحيل ما زبط: ' + arError(r.error), 'err'); m.close(); return done(); } }
    toast(post ? 'تم الحفظ والترحيل' : 'تم الحفظ', 'ok'); m.close(); done();
  };
  m.el.querySelector('[data-save]')?.addEventListener('click', () => save(false));
  m.el.querySelector('[data-post]')?.addEventListener('click', () => save(true));
  m.el.querySelector('[data-cancel]')?.addEventListener('click', async () => {
    if (!(await confirmBox(`إلغاء ${kl} رقم ${n.note_no}؟ رح ينعمل قيد عكسي بتاريخ اليوم.`))) return;
    const { error } = await sb.rpc('note_cancel', { p_id: n.id, p_date: null }); if (error) return toast(arError(error), 'err');
    toast('انلغى الإشعار', 'ok'); m.close(); done();
  });
  m.el.querySelector('[data-del]')?.addEventListener('click', async () => {
    if (!(await confirmBox('حذف المسودة؟'))) return;
    const { error } = await sb.rpc('note_delete', { p_id: n.id }); if (error) return toast(arError(error), 'err');
    m.close(); done();
  });
  m.el.querySelector('[data-print]')?.addEventListener('click', () => {
    const p = parties.find(x => x.id === n.party_id), a = accs.find(x => x.id === n.account_id), inv = m.el.querySelector('#ninv').selectedOptions[0];
    printDoc(`${kl} رقم ${n.note_no}`, `<table class="pt" style="margin-bottom:12px"><tbody>
        <tr><th style="width:160px">التاريخ</th><td>${fmtDate(n.note_date)}</td></tr>
        <tr><th>${D.who}</th><td>${esc(p ? partyLabel(p) : '')}</td></tr>
        ${n.invoice_id && inv ? `<tr><th>الفاتورة المرجعية</th><td>${esc(inv.textContent)}</td></tr>` : ''}
        ${n.reference ? `<tr><th>المرجع</th><td>${esc(n.reference)}</td></tr>` : ''}
        <tr><th>البيان</th><td>${esc(n.description || '')}</td></tr>
        <tr><th>الحساب المقابل</th><td>${esc(accLabel(a))}</td></tr></tbody></table>
      <table class="pt"><thead><tr><th>المبلغ قبل الضريبة</th><th>الضريبة (${num(n.tax_rate)}%)</th><th>المجموع</th></tr></thead>
        <tbody><tr><td class="n">${fmtNum(n.amount)}</td><td class="n">${fmtNum(n.tax_amount)}</td><td class="n"><b>${fmtNum(n.total)}</b></td></tr></tbody></table>
      <p>فقط ${esc(amountToWords(num(n.total)))}</p>
      ${n.status === 'cancelled' ? '<p style="color:#b91c1c;font-weight:700">ملغى</p>' : ''}`, { subtitle: kd });
  });
}

export const NOTE_ROUTES = { notes: viewNotes };
