// =====================================================================
//  السمو ERP — قوائم الأسعار (route price-lists): قائمة لكل فئة زبائن (جملة، موزعين…) وسعر كل صنف فيها
// =====================================================================
import { S, sb, esc, fmtNum, num, toast, arError, modal, can, fmtPrice } from './core.js';
import { loadItems } from './invoices.js';

async function listEditor(list, ctx) {
  const items = (await loadItems()).filter(i => i.is_active);
  const isNew = !list;
  let prices = {};
  if (!isNew) { const { data } = await sb.from('price_list_items').select('item_id,price').eq('list_id', list.id); (data || []).forEach(r => prices[r.item_id] = num(r.price)); }
  const ed = can('items', 'edit');
  const m = modal({ title: isNew ? '➕ قائمة أسعار جديدة' : `قائمة الأسعار: ${list.name}`, size: 'lg', body: `
    <div class="grid cols-3"><div class="field"><label>الرمز</label><input id="pl-code" value="${esc(list?.code || '')}" ${ed ? '' : 'disabled'}></div>
      <div class="field"><label>الاسم</label><input id="pl-name" value="${esc(list?.name || '')}" placeholder="مثلاً: أسعار الجملة" ${ed ? '' : 'disabled'}></div>
      <div class="field" style="align-self:end"><label class="check"><input type="checkbox" id="pl-act" ${list?.is_active !== false ? 'checked' : ''} ${ed ? '' : 'disabled'}> فعّالة</label></div></div>
    <div style="display:flex;gap:8px;align-items:end;flex-wrap:wrap;margin:6px 0">
      <input id="pl-q" placeholder="بحث بالصنف…" style="flex:1;min-width:160px">
      ${ed ? `<label>تعبئة الكل: سعر البيع ±<input id="pl-pct" dir="ltr" style="width:70px" placeholder="-5">%</label><button class="btn sm" id="pl-fill" type="button">تطبيق</button>` : ''}</div>
    <div class="table-wrap" style="max-height:52vh"><table class="t"><thead><tr><th>الرمز</th><th>الصنف</th><th>سعر البيع العادي</th><th style="width:140px">سعر القائمة</th></tr></thead>
    <tbody>${items.map(i => `<tr data-row="${esc((i.code + ' ' + i.name).toLowerCase())}"><td>${esc(i.code)}</td><td>${esc(i.name)}</td><td class="n">${fmtPrice(i.sale_price)}</td>
      <td><input class="cell n" dir="ltr" inputmode="decimal" data-it="${i.id}" value="${prices[i.id] ?? ''}" ${ed ? '' : 'disabled'}></td></tr>`).join('')}</tbody></table></div>
    <p class="muted" style="font-size:12px">الصنف اللي سعره فاضي بياخذ سعر البيع العادي. القائمة بتنربط بالزبون من بطاقته، والفاتورة بتاخذ السعر لحالها.</p>`,
    foot: `${ed ? '<button class="btn primary" data-save>💾 حفظ</button>' : ''}${!isNew && can('items', 'delete') ? '<button class="btn danger" data-del>حذف القائمة</button>' : ''}<button class="btn" data-close>إغلاق</button>` });
  m.el.querySelector('#pl-q').oninput = (e) => { const q = e.target.value.trim().toLowerCase(); m.el.querySelectorAll('[data-row]').forEach(tr => tr.style.display = !q || tr.dataset.row.includes(q) ? '' : 'none'); };
  m.el.querySelector('#pl-fill')?.addEventListener('click', () => {
    const pct = num(m.el.querySelector('#pl-pct').value);
    items.forEach(i => { const el = m.el.querySelector(`[data-it="${i.id}"]`); if (el && num(i.sale_price)) el.value = (Math.round(num(i.sale_price) * (1 + pct / 100) * 1000) / 1000).toString(); });
  });
  m.el.querySelector('[data-save]')?.addEventListener('click', async (e) => {
    const code = m.el.querySelector('#pl-code').value.trim(), name = m.el.querySelector('#pl-name').value.trim();
    if (!code || !name) return toast('الرمز والاسم مطلوبين', 'err');
    e.target.disabled = true;
    try {
      let id = list?.id;
      const rec = { code, name, is_active: m.el.querySelector('#pl-act').checked };
      if (id) { const r = await sb.from('price_lists').update(rec).eq('id', id); if (r.error) throw r.error; }
      else { const r = await sb.from('price_lists').insert({ ...rec, company_id: S.company.id }).select().single(); if (r.error) throw r.error; id = r.data.id; }
      const rows = [...m.el.querySelectorAll('[data-it]')].filter(x => x.value.trim() !== '').map(x => ({ list_id: id, item_id: x.dataset.it, price: num(x.value) }));
      const d = await sb.from('price_list_items').delete().eq('list_id', id); if (d.error) throw d.error;
      for (let k = 0; k < rows.length; k += 500) { const r = await sb.from('price_list_items').insert(rows.slice(k, k + 500)); if (r.error) throw r.error; }
      toast('انحفظت قائمة الأسعار', 'ok'); m.close(true); ctx.rerender();
    } catch (err) { e.target.disabled = false; toast(/duplicate|unique/.test(err.message) ? 'الرمز مستعمل' : arError(err), 'err'); }
  });
  m.el.querySelector('[data-del]')?.addEventListener('click', async (e) => {
    if (!e.target.dataset.sure) { e.target.dataset.sure = 1; e.target.textContent = 'متأكد؟'; return; }
    const { error } = await sb.from('price_lists').delete().eq('id', list.id); if (error) return toast(arError(error), 'err');
    toast('انحذفت', 'ok'); m.close(true); ctx.rerender();
  });
}

async function viewPriceLists(v, ctx) {
  if (!S.company) return void (v.innerHTML = '<div class="notice info">اختار شركة من فوق أول.</div>');
  const [{ data: lists = [] }, { data: cnt = [] }, { data: cust = [] }] = await Promise.all([
    sb.from('price_lists').select('*').eq('company_id', S.company.id).order('code'),
    sb.from('price_list_items').select('list_id'),
    sb.from('parties').select('price_list_id').eq('company_id', S.company.id).not('price_list_id', 'is', null)]);
  const n = (id, arr) => (arr || []).filter(x => (x.list_id || x.price_list_id) === id).length;
  v.innerHTML = `<div class="page-head"><h2>🏷️ قوائم الأسعار</h2><div class="spacer"></div>${can('items', 'edit') ? '<button class="btn primary" id="add">➕ قائمة جديدة</button>' : ''}</div>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرمز</th><th>الاسم</th><th>عدد الأصناف</th><th>عدد الزبائن</th><th>الحالة</th></tr></thead><tbody>
    ${(lists || []).map(l => `<tr data-l="${l.id}" style="cursor:pointer"><td>${esc(l.code)}</td><td>${esc(l.name)}</td><td class="n">${n(l.id, cnt)}</td><td class="n">${n(l.id, cust)}</td>
      <td>${l.is_active ? '<span class="badge ok">فعّالة</span>' : '<span class="badge">موقوفة</span>'}</td></tr>`).join('') || '<tr><td colspan="5" class="empty">ما في قوائم أسعار</td></tr>'}</tbody></table></div>
    <div class="card" style="margin-top:12px"><h4 style="margin-top:0">🛡️ ضوابط سعر البيع</h4>
      <ul class="muted" style="margin:0;line-height:1.9"><li>ببطاقة الصنف: «أقل سعر بيع» و«أعلى نسبة خصم».</li><li>بفئات المواد: أعلى خصم وأقل هامش ربح فوق الكلفة للأصناف اللي ما إلها حد.</li>
      <li>بحسابات الربط: «منع البيع بسعر أقل من الكلفة».</li><li>التجاوز للمدير أو لمين إله صلاحية «تجاوز ضوابط الأسعار».</li></ul></div>`;
  v.querySelector('#add')?.addEventListener('click', () => listEditor(null, ctx));
  v.querySelector('tbody').onclick = (e) => { const tr = e.target.closest('[data-l]'); if (tr) listEditor(lists.find(l => l.id === tr.dataset.l), ctx); };
}

export const PRICE_ROUTES = { 'price-lists': viewPriceLists };
