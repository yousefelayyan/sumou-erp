// =====================================================================
//  السمو ERP — سجل التتبع: مين أدخل السند ومين عدّل عليه ومتى، وكل حركاته
// =====================================================================
import { sb, esc, fmtDateTime } from './core.js';

const nameCache = {};
async function names(ids) {
  const need = [...new Set(ids.filter(x => x && !(x in nameCache)))];
  if (need.length) {
    const { data } = await sb.rpc('user_names', { p_ids: need });
    (data || []).forEach(r => { nameCache[r.id] = r.name; });
    need.forEach(id => { if (!(id in nameCache)) nameCache[id] = ''; });
  }
  return nameCache;
}

const ENT = { journal_entries: 'قيد/سند', invoices: 'فاتورة', stock_docs: 'سند مخزون', parties: 'عميل/مورد', items: 'صنف', accounts: 'حساب',
  cheques: 'شيك', warehouses: 'مستودع', employees: 'موظف', fixed_assets: 'أصل', payroll_runs: 'رواتب', item_categories: 'فئة مواد',
  party_categories: 'فئة', cost_centers: 'مركز كلفة', fiscal_years: 'سنة مالية', companies: 'شركة' };
const COLS = { status: 'الحالة', entry_date: 'التاريخ', inv_date: 'التاريخ', doc_date: 'التاريخ', description: 'البيان', reference: 'المرجع',
  total: 'المبلغ', subtotal: 'المبلغ', party_id: 'الطرف', party_name: 'الاسم', notes: 'الملاحظات', name: 'الاسم', code: 'الرمز',
  stock_posted: 'المخزون', entry_id: 'القيد', cash_account_id: 'الصندوق', payment_type: 'طريقة الدفع', warehouse_id: 'المستودع',
  cost_center_id: 'مركز الكلفة', account_id: 'الحساب', is_active: 'فعّال', entry_no: 'الرقم', inv_no: 'الرقم', doc_no: 'الرقم', doc_code: 'الرقم' };

// شريط «أدخله / آخر تعديل» + كبسة «سجل التتبع» أعلى نافذة السند
export async function attachAudit(root, row) {
  if (!row?.id) return;
  const body = root.querySelector('.modal-body'); if (!body) return;
  const nm = await names([row.created_by, row.updated_by]);
  const box = document.createElement('div');
  box.className = 'audit-bar no-print';
  box.innerHTML = `<span>👤 أدخله: <b>${esc(nm[row.created_by] || '—')}</b>${row.created_at ? ` <span dir="ltr">${fmtDateTime(row.created_at)}</span>` : ''}</span>
    ${row.updated_by || row.updated_at ? `<span>✏️ آخر تعديل: <b>${esc(nm[row.updated_by] || '—')}</b>${row.updated_at ? ` <span dir="ltr">${fmtDateTime(row.updated_at)}</span>` : ''}</span>` : ''}
    <button type="button" class="btn sm" data-hist>🕓 سجل التتبع</button><div class="audit-hist" hidden></div>`;
  body.prepend(box);
  box.querySelector('[data-hist]').onclick = async () => {
    const h = box.querySelector('.audit-hist');
    if (!h.hidden) { h.hidden = true; return; }
    h.hidden = false; h.innerHTML = '<div class="muted">جاري التحميل…</div>';
    const { data, error } = await sb.rpc('doc_history', { p_id: row.id });
    if (error) { h.innerHTML = `<div class="notice">${esc(error.message)}</div>`; return; }
    h.innerHTML = `<table class="t"><thead><tr><th>الوقت</th><th>المستخدم</th><th>العملية</th><th>شو تغيّر</th></tr></thead><tbody>
      ${(data || []).map(r => `<tr><td dir="ltr" style="text-align:right">${fmtDateTime(r.created_at)}</td><td>${esc(r.user_name || '')}</td><td>${esc(r.action)}</td>
        <td class="muted" style="font-size:12px">${esc((r.details?.changes || []).map(c => COLS[c]).filter(Boolean).filter((x, i, a) => a.indexOf(x) === i).join('، '))}</td></tr>`).join('')
        || '<tr><td colspan="4" class="empty">ما في حركات مسجّلة</td></tr>'}</tbody></table>`;
  };
}

export { ENT as AUDIT_ENTITIES, COLS as AUDIT_COLS };
