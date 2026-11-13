// =====================================================================
//  السمو ERP — الدفعات وتواريخ الانتهاء (route batches?t=balance|expiry)
//  أرصدة كل دفعة بكل مستودع من batch_balances، والمنتهية والقريبة حسب company_settings.expiry_warn_days،
//  سجل الدفعة (batch_history)، وتعديل تاريخ الانتهاء (inventory edit).
// =====================================================================
import { S, sb, esc, fmtDate, fmtQty, toast, arError, modal, can } from './core.js';
import { loadItems } from './invoices.js';
import { loadWarehouses } from './inventory.js';
import { printDoc } from './print.js';

const qp = () => new URLSearchParams(location.hash.split('?')[1] || '');
const KIND = { sale: 'فاتورة بيع', sale_return: 'مرتجع بيع', purchase: 'فاتورة شراء', purchase_return: 'مرتجع شراء',
  stock_in: 'سند إدخال', stock_out: 'سند إخراج', stock_transfer: 'سند تحويل', stock_count: 'جرد' };

async function viewBatches(v) {
  if (!S.company) return void (v.innerHTML = '<div class="notice info">اختار شركة من فوق أول.</div>');
  const t = qp().get('t') || 'balance';
  const [items, whs, st, bal] = await Promise.all([loadItems(), loadWarehouses(),
    sb.from('company_settings').select('expiry_warn_days').eq('company_id', S.company.id).maybeSingle().then(r => r.data || {}),
    sb.rpc('batch_balances', { p_company: S.company.id, p_warehouse: null, p_item: null, p_all: false })]);
  if (bal.error) return void (v.innerHTML = `<div class="notice">${esc(arError(bal.error))}</div>`);
  const warn = st.expiry_warn_days ?? 60;
  const itById = Object.fromEntries(items.map(i => [i.id, i])), whById = Object.fromEntries(whs.map(w => [w.id, w]));
  const tracked = items.filter(i => i.batch_mode && i.batch_mode !== 'none').length;
  const all = (bal.data || []).filter(x => itById[x.item_id]);
  const status = (x) => !x.batch_id ? ['بدون دفعة', ''] : x.expiry_date == null ? ['بدون تاريخ', ''] : x.days_left < 0 ? ['منتهية', 'bad'] : x.days_left <= warn ? ['قرّبت', 'warn'] : ['سليمة', 'ok'];
  const pos = all.filter(x => x.qty > 0);
  const expired = pos.filter(x => x.batch_id && x.days_left != null && x.days_left < 0), soon = pos.filter(x => x.batch_id && x.days_left != null && x.days_left >= 0 && x.days_left <= warn);
  const card = (l, val, c = '') => `<div class="card" style="padding:12px;text-align:center"><div class="muted" style="font-size:12px">${l}</div><div style="font-size:22px;font-weight:800;${c ? 'color:' + c : ''}">${val}</div></div>`;
  v.innerHTML = `<div class="page-head"><h2>🧪 الدفعات وتواريخ الانتهاء</h2><div class="spacer"></div><button class="btn" id="pr">🖨️ طباعة</button></div>
    <div class="tabs" style="margin-bottom:10px">${[['balance', '📦 أرصدة الدفعات'], ['expiry', `⏰ المنتهية والقريبة (${expired.length + soon.length})`]]
      .map(([k, l]) => `<a class="tab ${t === k ? 'active' : ''}" href="#/batches?t=${k}">${l}</a>`).join('')}</div>
    ${!tracked ? '<div class="notice info">ما في أصناف عليها دفعات. من بطاقة الصنف اختار «🧪 الدفعات وتاريخ الانتهاء».</div>' : ''}
    <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin-bottom:10px">
      ${card('أصناف بدفعات', tracked)}${card('دفعات فيها رصيد', pos.filter(x => x.batch_id).length)}
      ${card('منتهية', expired.length, expired.length ? 'var(--bad)' : '')}${card(`بتنتهي خلال ${warn} يوم`, soon.length, soon.length ? '#b45309' : '')}</div>
    <div class="card" style="display:flex;gap:8px;flex-wrap:wrap;align-items:end;margin-bottom:10px">
      <div class="field" style="margin:0;min-width:180px"><label>المستودع</label><select id="f-w"><option value="">الكل</option>${whs.map(w => `<option value="${w.id}">${esc(w.name)}</option>`).join('')}</select></div>
      <div class="field" style="margin:0;flex:1;min-width:200px"><label>بحث</label><input id="f-q" placeholder="صنف أو رقم دفعة"></div>
      ${t === 'balance' ? `<div class="field" style="margin:0"><label>الحالة</label><select id="f-s"><option value="">الكل</option><option value="bad">منتهية</option><option value="warn">قرّبت</option><option value="ok">سليمة</option><option value="none">بدون دفعة/تاريخ</option></select></div>` : ''}</div>
    <div class="card table-wrap" id="tbl"></div>`;
  const draw = () => {
    const w = v.querySelector('#f-w').value, q = v.querySelector('#f-q').value.trim().toLowerCase(), s = v.querySelector('#f-s')?.value || '';
    let rows = (t === 'expiry' ? [...expired, ...soon] : pos).filter(x => (!w || x.warehouse_id === w)
      && (!q || `${itById[x.item_id].code} ${itById[x.item_id].name} ${x.batch_no || ''}`.toLowerCase().includes(q))
      && (!s || (s === 'none' ? !status(x)[1] : status(x)[1] === s)));
    if (t === 'expiry') rows.sort((a, b) => a.days_left - b.days_left);
    const tot = rows.reduce((a, x) => a + Number(x.qty), 0);
    v.querySelector('#tbl').innerHTML = `<table class="t"><thead><tr><th>الصنف</th><th>المستودع</th><th>الدفعة</th><th>تاريخ الانتهاء</th><th>باقي</th><th style="text-align:left">الكمية</th><th>الحالة</th>${can('inventory', 'edit') ? '<th></th>' : ''}</tr></thead><tbody>
      ${rows.map(x => { const [l, c] = status(x); const it = itById[x.item_id];
        return `<tr ${x.batch_id ? `data-b="${x.batch_id}" style="cursor:pointer"` : ''}><td>${esc(it.code)} — ${esc(it.name)}</td><td>${esc(whById[x.warehouse_id]?.name || '')}</td>
          <td><b>${esc(x.batch_no || '—')}</b></td><td>${fmtDate(x.expiry_date)}</td><td class="n">${x.days_left == null || !x.batch_id ? '' : x.days_left < 0 ? `منتهية من ${-x.days_left} يوم` : `${x.days_left} يوم`}</td>
          <td class="n">${fmtQty(x.qty)}</td><td>${c ? `<span class="badge ${c}">${l}</span>` : `<span class="muted">${l}</span>`}</td>
          ${can('inventory', 'edit') ? `<td>${x.batch_id ? `<button class="btn sm" data-ed="${x.batch_id}" title="تعديل تاريخ الانتهاء">✏️</button>` : ''}</td>` : ''}</tr>`; }).join('')
        || `<tr><td colspan="8" class="empty">${t === 'expiry' ? 'ما في دفعات منتهية أو قريبة 👍' : 'ما في أرصدة'}</td></tr>`}</tbody>
      ${rows.length ? `<tfoot><tr><th colspan="5">المجموع (${rows.length})</th><th class="n">${fmtQty(tot)}</th><th colspan="2"></th></tr></tfoot>` : ''}</table>`;
  };
  draw();
  ['#f-w', '#f-q', '#f-s'].forEach(s => v.querySelector(s)?.addEventListener('input', draw));
  v.querySelector('#tbl').addEventListener('click', async (e) => {
    const ed = e.target.closest('[data-ed]');
    if (ed) { e.stopPropagation(); return editBatch(ed.dataset.ed, () => viewBatches(v)); }
    const tr = e.target.closest('[data-b]'); if (tr) batchHistory(tr.dataset.b, itById, whById);
  });
  v.querySelector('#pr').addEventListener('click', () => printDoc(t === 'expiry' ? 'الدفعات المنتهية والقريبة' : 'أرصدة الدفعات', v.querySelector('#tbl').innerHTML.replace(/class="t"/g, 'class="pt"')));
}

async function editBatch(id, done) {
  const { data: b, error } = await sb.from('item_batches').select('*').eq('id', id).single();
  if (error) return toast(arError(error), 'err');
  const m = modal({ title: `✏️ الدفعة ${esc(b.batch_no)}`, body: `<form id="bf"><div class="grid cols-2">
    <div class="field"><label>تاريخ الانتهاء</label><input type="date" name="expiry_date" value="${esc(b.expiry_date || '')}"></div>
    <div class="field"><label>تاريخ الإنتاج</label><input type="date" name="mfg_date" value="${esc(b.mfg_date || '')}"></div>
    <div class="field" style="grid-column:span 2"><label>ملاحظات</label><input name="notes" value="${esc(b.notes || '')}"></div></div></form>`,
    foot: '<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>' });
  m.el.querySelector('[data-save]').onclick = async () => {
    const f = m.el.querySelector('#bf');
    const { error: e2 } = await sb.from('item_batches').update({ expiry_date: f.expiry_date.value || null, mfg_date: f.mfg_date.value || null, notes: f.notes.value.trim() || null }).eq('id', id);
    if (e2) return toast(arError(e2), 'err');
    toast('تم الحفظ', 'ok'); m.close(); done();
  };
}

export async function batchHistory(id, itById, whById) {
  const [{ data: b }, { data: rows, error }] = await Promise.all([sb.from('item_batches').select('*').eq('id', id).single(), sb.rpc('batch_history', { p_batch: id })]);
  if (error) return toast(arError(error), 'err');
  if (!b) return toast('الدفعة مش موجودة', 'err');
  const it = itById[b.item_id]; let run = {};
  const m = modal({ title: `🧪 سجل الدفعة ${esc(b.batch_no)} — ${esc(it?.name || '')}`, body: `
    <p class="muted" style="margin:0 0 8px">تاريخ الانتهاء: <b>${fmtDate(b.expiry_date) || '—'}</b>${b.mfg_date ? ` · الإنتاج: ${fmtDate(b.mfg_date)}` : ''}${b.notes ? ` · ${esc(b.notes)}` : ''}</p>
    <div class="table-wrap"><table class="t"><thead><tr><th>التاريخ</th><th>المستند</th><th>المستودع</th><th style="text-align:left">داخل</th><th style="text-align:left">طالع</th><th style="text-align:left">الرصيد</th></tr></thead><tbody>
    ${(rows || []).map(r => { run[r.warehouse_id] = (run[r.warehouse_id] || 0) + Number(r.qty); const q = Number(r.qty);
      return `<tr><td>${fmtDate(r.move_date)}</td><td>${r.source_type === 'invoice_cancel' ? 'إلغاء ' : ''}${KIND[r.doc_kind] || ''} ${esc(r.doc_no || '')}</td><td>${esc(whById[r.warehouse_id]?.name || '')}</td>
        <td class="n">${q > 0 ? fmtQty(q) : ''}</td><td class="n">${q < 0 ? fmtQty(-q) : ''}</td><td class="n">${fmtQty(run[r.warehouse_id])}</td></tr>`; }).join('') || '<tr><td colspan="6" class="empty">ما في حركات</td></tr>'}</tbody></table></div>`,
    foot: '<button class="btn" data-close>إغلاق</button>' });
  m.el.querySelector('.modal').style.maxWidth = '820px';
}

export const BATCH_ROUTES = { batches: viewBatches };
