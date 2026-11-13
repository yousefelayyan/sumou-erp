// =====================================================================
//  السمو ERP — خصومات العملاء (route discounts?t=voucher|settle|types)
//  سند خصم (customer_discount) + تسوية الأرصدة الصغيرة (settle_small_balances) + أنواع الخصم (discount_types)
// =====================================================================
import { S, sb, esc, fmtNum, num, today, toast, arError, modal, can } from './core.js';
import { loadParties, partyLabel, partyDatalist, resolveParty } from './parties.js';
import { loadAccounts, leafAccounts, accLabel } from './finance.js';

const qp = () => new URLSearchParams(location.hash.split('?')[1] || '');

async function voucherTab(v, head, types) {
  const parties = (await loadParties()).filter(p => p.party_type === 'customer' && p.is_active);
  const act = types.filter(t => t.is_active);
  if (!act.length) return void (v.innerHTML = `${head}<div class="notice">عرّف «نوع خصم» واحد على الأقل من تبويب «أنواع الخصم».</div>`);
  let rows = [{ party: '', type: act[0].id, amount: '', invoice: '', note: '' }];
  const openInv = {};
  v.innerHTML = `${head}<div class="card">
    <div class="grid cols-3"><div class="field"><label>التاريخ</label><input type="date" id="d-date" value="${today()}"></div>
      <div class="field" style="grid-column:span 2"><label>البيان</label><input id="d-desc" placeholder="خصومات عملاء"></div></div>
    ${partyDatalist(parties, 'dc-parties')}
    <div class="table-wrap"><table class="t"><thead><tr><th>الزبون</th><th>نوع الخصم</th><th style="width:120px">المبلغ</th><th>على فاتورة (اختياري)</th><th>ملاحظة</th><th></th></tr></thead><tbody id="d-rows"></tbody>
      <tfoot><tr><td colspan="2"><button class="btn sm" id="d-add" type="button">➕ سطر</button></td><td><b id="d-tot" dir="ltr"></b></td><td colspan="3"></td></tr></tfoot></table></div>
    <div style="display:flex;gap:8px;margin-top:10px"><button class="btn" id="d-save">💾 حفظ مسودة</button>${can('journal_entries', 'post') ? '<button class="btn primary" id="d-post">✔ حفظ وترحيل</button>' : ''}</div>
    <p class="muted" style="font-size:12px">القيد: حساب نوع الخصم مدين، والزبون دائن. إذا اخترت فاتورة والسند انرحّل، الخصم بينوزّع عليها لحاله.</p></div>`;
  const tb = v.querySelector('#d-rows');
  const draw = () => {
    tb.innerHTML = rows.map((r, i) => `<tr><td><input list="dc-parties" data-i="${i}" data-k="party" value="${esc(r.party)}" placeholder="رقم أو اسم الزبون"></td>
      <td><select data-i="${i}" data-k="type">${act.map(t => `<option value="${t.id}" ${t.id === r.type ? 'selected' : ''}>${esc(t.name)}</option>`).join('')}</select></td>
      <td><input class="cell n" dir="ltr" inputmode="decimal" data-i="${i}" data-k="amount" value="${r.amount}"></td>
      <td><select data-i="${i}" data-k="invoice"><option value="">—</option>${(openInv[r.pid] || []).map(x => `<option value="${x.invoice_id}" ${x.invoice_id === r.invoice ? 'selected' : ''}>${esc(x.doc_code || String(x.inv_no))} — متبقي ${fmtNum(x.remaining)}</option>`).join('')}</select></td>
      <td><input data-i="${i}" data-k="note" value="${esc(r.note)}"></td><td><button class="btn sm" data-del="${i}" type="button">×</button></td></tr>`).join('');
    v.querySelector('#d-tot').textContent = fmtNum(rows.reduce((s, r) => s + num(r.amount), 0));
  };
  draw();
  tb.addEventListener('input', (e) => { const t = e.target; if (!t.dataset.k) return; rows[+t.dataset.i][t.dataset.k] = t.value; if (t.dataset.k === 'amount') v.querySelector('#d-tot').textContent = fmtNum(rows.reduce((s, r) => s + num(r.amount), 0)); });
  tb.addEventListener('change', async (e) => {
    const t = e.target; if (t.dataset.k !== 'party') return;
    const r = rows[+t.dataset.i], p = resolveParty(parties, t.value);
    t.classList.toggle('bad', !!t.value && !p); r.pid = p?.id; r.party = p ? partyLabel(p) : t.value; r.invoice = '';
    if (p && !openInv[p.id]) { const { data } = await sb.rpc('party_open_invoices', { p_company: S.company.id, p_party: p.id }); openInv[p.id] = (data || []).filter(x => num(x.remaining) > 0); }
    draw();
  });
  tb.addEventListener('click', (e) => { const b = e.target.closest('[data-del]'); if (b) { rows.splice(+b.dataset.del, 1); if (!rows.length) rows.push({ party: '', type: act[0].id, amount: '', invoice: '', note: '' }); draw(); } });
  v.querySelector('#d-add').onclick = () => { rows.push({ party: '', type: act[0].id, amount: '', invoice: '', note: '' }); draw(); };
  const save = async (post) => {
    const lines = [];
    for (const [i, r] of rows.entries()) {
      if (!r.party && !num(r.amount)) continue;
      const p = resolveParty(parties, r.party); if (!p) return toast(`السطر ${i + 1}: الزبون مش موجود`, 'err');
      if (num(r.amount) <= 0) return toast(`السطر ${i + 1}: المبلغ مطلوب`, 'err');
      lines.push({ party_id: p.id, discount_type_id: r.type, amount: num(r.amount), invoice_id: r.invoice || null, note: r.note || null });
    }
    if (!lines.length) return toast('أضف سطر واحد على الأقل', 'err');
    const { data, error } = await sb.rpc('customer_discount', { p: { company_id: S.company.id, date: v.querySelector('#d-date').value, description: v.querySelector('#d-desc').value, post, lines } });
    if (error) return toast(arError(error), 'err');
    toast(post ? 'انرحّل سند الخصم' : 'انحفظ سند الخصم مسودة (بتلاقيه بسندات القيد)', 'ok');
    rows = [{ party: '', type: act[0].id, amount: '', invoice: '', note: '' }]; draw();
    return data;
  };
  v.querySelector('#d-save').onclick = () => save(false);
  v.querySelector('#d-post')?.addEventListener('click', () => save(true));
}

async function settleTab(v, head) {
  const [accs, { data: cs }] = await Promise.all([loadAccounts(), sb.from('company_settings').select('settle_account_id').eq('company_id', S.company.id).maybeSingle()]);
  v.innerHTML = `${head}<div class="card">
    <div class="grid cols-4">
      <div class="field"><label>النوع</label><select id="s-type"><option value="customer">العملاء</option><option value="supplier">الموردين</option></select></div>
      <div class="field"><label>من (قيمة مطلقة)</label><input id="s-min" dir="ltr" value="0.001"></div>
      <div class="field"><label>إلى</label><input id="s-max" dir="ltr" value="1"></div>
      <div class="field"><label>تاريخ القيد</label><input type="date" id="s-date" value="${today()}"></div>
      <div class="field" style="grid-column:span 3"><label>حساب تسوية الأرصدة الصغيرة</label><select id="s-acc" ${can('companies', 'edit') ? '' : 'disabled'}><option value="">— اختار —</option>
        ${leafAccounts(accs).map(a => `<option value="${a.id}" ${a.id === cs?.settle_account_id ? 'selected' : ''}>${esc(accLabel(a))}</option>`).join('')}</select></div>
      <div class="field" style="align-self:end"><button class="btn" id="s-prev">🔍 معاينة</button></div></div>
    <div id="s-out"></div></div>`;
  v.querySelector('#s-acc').onchange = async (e) => {
    const { error } = await sb.from('company_settings').update({ settle_account_id: e.target.value || null }).eq('company_id', S.company.id);
    toast(error ? arError(error) : 'انحفظ حساب التسوية', error ? 'err' : 'ok');
  };
  const run = async (apply) => {
    const args = { p_company: S.company.id, p_type: v.querySelector('#s-type').value, p_min: num(v.querySelector('#s-min').value), p_max: num(v.querySelector('#s-max').value), p_date: v.querySelector('#s-date').value, p_apply: apply };
    const { data, error } = await sb.rpc('settle_small_balances', args);
    if (error) return toast(arError(error), 'err');
    const tot = (data || []).reduce((s, r) => s + num(r.balance), 0);
    v.querySelector('#s-out').innerHTML = `<div class="table-wrap" style="margin-top:10px"><table class="t"><thead><tr><th>الرمز</th><th>الاسم</th><th>الرصيد</th></tr></thead><tbody>
      ${(data || []).map(r => `<tr><td>${esc(r.code)}</td><td>${esc(r.name)}</td><td class="n" dir="ltr">${fmtNum(r.balance)}</td></tr>`).join('') || '<tr><td colspan="3" class="empty">ما في أرصدة ضمن الحدود</td></tr>'}</tbody>
      <tfoot><tr><td colspan="2"><b>${(data || []).length} حساب</b></td><td class="n" dir="ltr"><b>${fmtNum(tot)}</b></td></tr></tfoot></table></div>
      ${apply ? '<div class="notice info" style="margin-top:8px">✔ انعمل قيد التسوية (بتلاقيه بسندات القيد)</div>' : (data || []).length && can('customer_discounts', 'add') ? '<button class="btn primary" id="s-go" style="margin-top:8px">✔ تنفيذ التسوية بقيد واحد</button>' : ''}`;
    v.querySelector('#s-go')?.addEventListener('click', () => run(true));
  };
  v.querySelector('#s-prev').onclick = () => run(false);
}

async function typesTab(v, head, types, ctx) {
  const accs = await loadAccounts(); const leaves = leafAccounts(accs);
  const ed = can('customer_discounts', 'edit');
  v.innerHTML = `${head}<div class="page-head"><div class="spacer"></div>${ed ? '<button class="btn primary" id="t-add">➕ نوع خصم</button>' : ''}</div>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرمز</th><th>الاسم</th><th>الحساب</th><th>الحالة</th></tr></thead><tbody>
    ${types.map(t => `<tr data-t="${t.id}" ${ed ? 'style="cursor:pointer"' : ''}><td>${esc(t.code)}</td><td>${esc(t.name)}</td><td>${esc(accLabel(accs.find(a => a.id === t.account_id)))}</td><td>${t.is_active ? '<span class="badge ok">فعّال</span>' : '<span class="badge">موقوف</span>'}</td></tr>`).join('') || '<tr><td colspan="4" class="empty">ما في أنواع (مثلاً: خصم نقدي، خصم كمية، خصم تسوية)</td></tr>'}</tbody></table></div>`;
  const form = (t) => {
    const r = t || { code: String(types.length + 1).padStart(2, '0'), name: '', is_active: true };
    const m = modal({ title: t ? 'تعديل نوع خصم' : 'نوع خصم جديد', body: `<div class="grid cols-2">
      <div class="field"><label>الرمز</label><input id="f-code" value="${esc(r.code)}"></div><div class="field"><label>الاسم</label><input id="f-name" value="${esc(r.name)}" placeholder="خصم نقدي"></div>
      <div class="field" style="grid-column:1/-1"><label>الحساب (مصروف خصم مسموح به)</label><select id="f-acc"><option value="">— اختار —</option>${leaves.map(a => `<option value="${a.id}" ${a.id === r.account_id ? 'selected' : ''}>${esc(accLabel(a))}</option>`).join('')}</select></div>
      <label class="check"><input type="checkbox" id="f-act" ${r.is_active ? 'checked' : ''}> فعّال</label></div>`,
      foot: '<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>' });
    m.el.querySelector('[data-save]').onclick = async () => {
      const rec = { code: m.el.querySelector('#f-code').value.trim(), name: m.el.querySelector('#f-name').value.trim(), account_id: m.el.querySelector('#f-acc').value || null, is_active: m.el.querySelector('#f-act').checked };
      if (!rec.code || !rec.name || !rec.account_id) return toast('الرمز والاسم والحساب مطلوبين', 'err');
      const { error } = t ? await sb.from('discount_types').update(rec).eq('id', t.id) : await sb.from('discount_types').insert({ ...rec, company_id: S.company.id });
      if (error) return toast(/duplicate|unique/.test(error.message) ? 'الرمز مستعمل' : arError(error), 'err');
      toast('انحفظ', 'ok'); m.close(true); ctx.rerender();
    };
  };
  v.querySelector('#t-add')?.addEventListener('click', () => form(null));
  if (ed) v.querySelector('tbody').onclick = (e) => { const tr = e.target.closest('[data-t]'); if (tr) form(types.find(x => x.id === tr.dataset.t)); };
}

async function viewDiscounts(v, ctx) {
  if (!S.company) return void (v.innerHTML = '<div class="notice info">اختار شركة من فوق أول.</div>');
  if (!can('customer_discounts', 'view')) return void (v.innerHTML = '<div class="notice">ما عندك صلاحية على خصومات العملاء</div>');
  const t = qp().get('t') || 'voucher';
  const { data: types = [] } = await sb.from('discount_types').select('*').eq('company_id', S.company.id).order('code');
  const head = `<div class="page-head"><h2>🎁 خصومات العملاء والتسويات</h2></div>
    <div class="tabs" style="margin-bottom:10px">${[['voucher', '🧾 سند خصم'], ['settle', '🧹 تسوية الأرصدة الصغيرة'], ['types', '🗂️ أنواع الخصم']].map(([k, l]) => `<a class="tab ${t === k ? 'active' : ''}" href="#/discounts?t=${k}">${l}</a>`).join('')}</div>`;
  if (t === 'settle') return settleTab(v, head);
  if (t === 'types') return typesTab(v, head, types || [], ctx);
  return voucherTab(v, head, types || []);
}

export const DISCOUNT_ROUTES = { discounts: viewDiscounts };
