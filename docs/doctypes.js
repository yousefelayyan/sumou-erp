// =====================================================================
//  السمو ERP — أنواع السندات (اليوميات): route doc-types?k=…
//  حقل «نوع السند» بالمستندات (docTypeField/docTypeValue) وعدد نسخ الطباعة (docCopies)
// =====================================================================
import { S, sb, esc, toast, arError, modal, formData, can } from './core.js';

export const DOC_KINDS = [
  ['journal', 'سندات القيد'], ['opening', 'القيود الافتتاحية'], ['receipt', 'سندات القبض'], ['payment', 'سندات الصرف'],
  ['sale', 'فواتير المبيعات'], ['sale_return', 'مردودات المبيعات'], ['purchase', 'فواتير المشتريات'], ['purchase_return', 'مردودات المشتريات'],
  ['stock_in', 'سندات الإدخال'], ['stock_out', 'سندات الإخراج'], ['stock_transfer', 'سندات التحويل'], ['stock_count', 'الجرد'],
];
const KL = Object.fromEntries(DOC_KINDS);

export async function loadDocTypes(force = false) {
  if (!S.company) return [];
  if (!force && S._dtypes?.cid === S.company.id) return S._dtypes.rows;
  let { data, error } = await sb.from('doc_types').select('*').eq('company_id', S.company.id).order('kind').order('code');
  if (!error && !data?.length && can('doc_types', 'edit')) {   // أول مرة: الأنواع الافتراضية
    await sb.rpc('ensure_doc_types', { p_company: S.company.id });
    ({ data, error } = await sb.from('doc_types').select('*').eq('company_id', S.company.id).order('kind').order('code'));
  }
  S._dtypes = { cid: S.company.id, rows: error ? [] : (data || []) };
  return S._dtypes.rows;
}
export const docTypeName = (id) => S._dtypes?.rows?.find(t => t.id === id)?.name || '';
export const docCopies = (id) => S._dtypes?.rows?.find(t => t.id === id)?.print_copies || 1;
export const docCommittee = (id) => S._dtypes?.rows?.find(t => t.id === id)?.committee || '';

// حقل «نوع السند»: بيظهر إذا في أكثر من نوع فعّال (الفاضي = الافتراضي من قاعدة البيانات)
export async function docTypeField(kind, current, ro = '') {
  const rows = (await loadDocTypes()).filter(t => t.kind === kind && (t.is_active || t.id === current));
  if (rows.length < 2 && !(current && rows.length === 1 && !rows[0].is_default)) return '';
  const def = current || rows.find(t => t.is_default)?.id || '';
  return `<div class="field"><label>نوع السند (اليومية)</label><select name="doc_type_id" ${ro}>
    ${rows.map(t => `<option value="${t.id}" ${t.id === def ? 'selected' : ''}>${esc(t.code)} — ${esc(t.name)}</option>`).join('')}</select></div>`;
}
export function docTypeValue(form) {
  const el = form.querySelector('[name=doc_type_id]');
  if (!el || el.disabled) return {};
  return { doc_type_id: el.value || null };
}

const GL_KINDS = ['journal', 'opening', 'receipt', 'payment'];
async function typeForm(kind, row, ctx) {
  const gl = GL_KINDS.includes(kind);
  const accs = gl ? ((await sb.from('accounts').select('id,code,name,is_group').eq('company_id', S.company.id).order('code')).data || []) : [];
  const allowed = new Set(row?.allowed_accounts || []);
  const r = row || { kind, code: '', name: '', is_active: true, print_copies: 1 };
  const m = modal({ title: row ? `نوع سند: ${esc(r.name)}` : `➕ نوع جديد — ${KL[kind]}`, body: `<form class="grid cols-2">
    <div class="field"><label>الرمز</label><input name="code" value="${esc(r.code)}" required maxlength="10"></div>
    <div class="field"><label>الاسم</label><input name="name" value="${esc(r.name)}" required maxlength="80"></div>
    <div class="field"><label><input type="checkbox" name="is_default" ${r.is_default ? 'checked' : ''}> النوع الافتراضي</label></div>
    <div class="field"><label><input type="checkbox" name="is_active" ${r.is_active !== false ? 'checked' : ''}> فعّال</label></div>
    <div class="field"><label><input type="checkbox" name="own_seq" ${r.own_seq ? 'checked' : ''}> ترقيم لحاله (تسلسل خاص بهالنوع)</label></div>
    <div class="field"><label>بادئة الرقم (مع الترقيم الخاص)</label><input name="prefix" value="${esc(r.prefix || '')}" maxlength="15" placeholder="مثلاً PV-"></div>
    <div class="field"><label>عدد نسخ الطباعة</label><input type="number" name="print_copies" min="1" max="5" value="${r.print_copies || 1}"></div>
    <div class="field"><label>مدة التعديل/الحذف (يوم من يوم الإدخال، فاضي = بدون حد، 0 = نفس اليوم)</label><input type="number" name="edit_days" min="0" max="3650" value="${r.edit_days ?? ''}"></div>
    <div class="field"><label><input type="checkbox" name="date_today" ${r.date_today ? 'checked' : ''}> التاريخ لازم يكون تاريخ اليوم</label></div>
    <div class="field"><label><input type="checkbox" name="lock_dept" ${r.lock_dept ? 'checked' : ''}> الدائرة مقفولة على دائرة المستخدم</label></div>
    ${kind === 'stock_count' ? `<div class="field" style="grid-column:1/-1"><label>لجنة الجرد (الأسماء، بتنطبع بالتواقيع)</label><input name="committee" value="${esc(r.committee || '')}" placeholder="مثلاً: أحمد، سارة، محمود"></div>` : ''}
    ${gl ? `<div class="field"><label><input type="checkbox" name="require_attach" ${r.require_attach ? 'checked' : ''}> 📎 ما بيترحّل بدون مرفق</label></div>
    <div class="field"><label><input type="checkbox" name="require_party" ${r.require_party ? 'checked' : ''}> حساب الذمم بدّه عميل/مورد على السطر</label></div>
    <div class="field" style="grid-column:1/-1"><label>الحسابات المسموحة بهالنوع (فاضي = كل الحسابات؛ الحساب الرئيسي بيشمل فروعه)</label>
      <input id="acc-q" placeholder="🔍 بحث…" style="margin-bottom:4px"><div id="acc-box" style="max-height:170px;overflow:auto;border:1px solid var(--line,#e5e7eb);border-radius:8px;padding:6px;font-size:13px">
      ${accs.map(a => `<label style="display:flex;gap:6px;align-items:center;margin:2px 0;font-weight:${a.is_group ? 700 : 400}" data-acc="${esc(a.code + ' ' + a.name)}"><input type="checkbox" style="width:auto;margin:0" value="${a.id}" ${allowed.has(a.id) ? 'checked' : ''}> ${esc(a.code)} — ${esc(a.name)}</label>`).join('')}</div></div>` : ''}
    <div class="field" style="grid-column:1/-1"><label>ملاحظات</label><input name="notes" value="${esc(r.notes || '')}"></div></form>
    <p class="muted" style="font-size:12px">القيود (التاريخ، مدة التعديل، الدائرة) ما بتنطبق على المدير ولا على مين إله صلاحية تعديل «أنواع السندات».</p>`,
    foot: `<button class="btn primary" data-save>💾 حفظ</button>${row ? '<button class="btn danger" data-del>حذف</button>' : ''}<button class="btn" data-close>إلغاء</button>` });
  const f = m.el.querySelector('form');
  m.el.querySelector('#acc-q')?.addEventListener('input', (e) => { const q = e.target.value.trim(); m.el.querySelectorAll('#acc-box [data-acc]').forEach(l => l.hidden = !!q && !l.dataset.acc.includes(q)); });
  m.el.querySelector('[data-save]').onclick = async () => {
    if (!f.reportValidity()) return;
    const d = formData(f);
    if (f.own_seq.checked && !(d.prefix || '').trim()) return toast('الترقيم الخاص بدّه بادئة (مثلاً PV-) عشان ما يتكرر الرقم', 'err');
    const rec = { company_id: S.company.id, kind, code: d.code.trim(), name: d.name.trim(), notes: d.notes || null,
      is_default: f.is_default.checked, is_active: f.is_active.checked, own_seq: f.own_seq.checked, prefix: d.prefix || null,
      print_copies: Math.min(Math.max(+d.print_copies || 1, 1), 5), edit_days: d.edit_days === '' || d.edit_days == null ? null : +d.edit_days,
      date_today: f.date_today.checked, lock_dept: f.lock_dept.checked, ...(kind === 'stock_count' ? { committee: d.committee || null } : {}),
      ...(gl ? { require_attach: f.require_attach.checked, require_party: f.require_party.checked, allowed_accounts: (() => { const a = [...m.el.querySelectorAll('#acc-box input:checked')].map(x => x.value); return a.length ? a : null; })() } : {}) };
    const { error } = row ? await sb.from('doc_types').update(rec).eq('id', row.id) : await sb.from('doc_types').insert(rec);
    if (error) return toast(arError(error), 'err');
    toast('انحفظ', 'ok'); m.close(true); await loadDocTypes(true); ctx.rerender();
  };
  m.el.querySelector('[data-del]')?.addEventListener('click', async () => {
    const { error } = await sb.from('doc_types').delete().eq('id', row.id);
    if (error) return toast(/foreign key|violates/.test(error.message) ? 'عليه مستندات؛ وقّفه بدل الحذف' : arError(error), 'err');
    toast('انحذف', 'ok'); m.close(true); await loadDocTypes(true); ctx.rerender();
  });
}

async function viewDocTypes(v, ctx) {
  if (!S.company) return void (v.innerHTML = '<div class="notice info">اختار شركة من فوق أول.</div>');
  const k = new URLSearchParams(location.hash.split('?')[1] || '').get('k') || 'journal';
  const rows = (await loadDocTypes(true)).filter(t => t.kind === k);
  const ed = can('doc_types', 'edit');
  v.innerHTML = `<div class="page-head"><h2>🗂️ أنواع السندات (اليوميات)</h2><div class="spacer"></div>${ed ? '<button class="btn primary" id="add">➕ نوع جديد</button>' : ''}</div>
    <div class="tabs" style="margin-bottom:10px;overflow:auto">${DOC_KINDS.map(([x, l]) => `<a class="tab ${x === k ? 'active' : ''}" href="#/doc-types?k=${x}">${l}</a>`).join('')}</div>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرمز</th><th>الاسم</th><th>الترقيم</th><th>نسخ الطباعة</th><th>القيود</th><th>الحالة</th></tr></thead><tbody>
    ${rows.map(t => `<tr data-t="${t.id}" ${ed ? 'style="cursor:pointer"' : ''}><td>${esc(t.code)}</td><td>${esc(t.name)} ${t.is_default ? '<span class="badge brand">افتراضي</span>' : ''}</td>
      <td>${t.own_seq ? `تسلسل خاص${t.prefix ? ` (${esc(t.prefix)})` : ''}` : 'مع تسلسل النوع'}</td><td class="n">${t.print_copies}</td>
      <td>${[t.date_today ? 'تاريخ اليوم' : '', t.edit_days != null ? `تعديل ${t.edit_days} يوم` : '', t.lock_dept ? 'دائرة المستخدم' : '', t.committee ? `اللجنة: ${esc(t.committee)}` : '', t.require_attach ? '📎 مرفق إلزامي' : '', t.require_party ? 'طرف على الذمم' : '', t.allowed_accounts?.length ? `${t.allowed_accounts.length} حساب مسموح` : ''].filter(Boolean).join(' · ') || '—'}</td>
      <td>${t.is_active ? '<span class="badge ok">فعّال</span>' : '<span class="badge">موقوف</span>'}</td></tr>`).join('') || '<tr><td colspan="6" class="empty">ما في أنواع</td></tr>'}</tbody></table></div>
    <p class="muted" style="font-size:12px">كل مستند لازم يكون إله نوع؛ إذا ما اخترت بياخذ الافتراضي. النوع بيبيّن باليوميات وكشوف الحسابات، وبيحدد عدد نسخ الطباعة.</p>`;
  v.querySelector('#add')?.addEventListener('click', () => typeForm(k, null, ctx));
  if (ed) v.querySelector('tbody').onclick = (e) => { const tr = e.target.closest('[data-t]'); if (tr) typeForm(k, rows.find(t => t.id === tr.dataset.t), ctx); };
}

export const DOCTYPE_ROUTES = { 'doc-types': viewDocTypes };
