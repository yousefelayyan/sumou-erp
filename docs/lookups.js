// =====================================================================
//  السمو ERP — قوائم الإعداد: وسائل الدفع، البنوك وفروعها، الدول والمناطق، أنواع الأوراق التجارية
// =====================================================================
import { S, sb, esc, toast, arError, can, modal, confirmBox, formData, num } from './core.js';
import { loadAccounts, leafAccounts, accLabel } from './finance.js';

export const LK = {
  payment_method: { label: 'وسائل الدفع', one: 'وسيلة دفع', icon: '💳', hint: 'صندوق المبيعات (Cash)، فيزا (Visa)، كليك (CliQ)… كل وسيلة مربوطة على حساب من الشجرة (هو الطرف المدين بالقيد)، وبتختار وين تظهر: فواتير المبيعات، فواتير المشتريات، نقطة البيع.' },
  bank:           { label: 'البنوك', one: 'بنك', icon: '🏦', hint: 'أسماء البنوك اللي بتطلع اختيارات جاهزة بالشيكات.' },
  bank_branch:    { label: 'فروع البنوك', one: 'فرع بنك', icon: '🏧', parent: 'bank', parentLabel: 'البنك' },
  country:        { label: 'الدول / البلاد', one: 'دولة', icon: '🌍' },
  region:         { label: 'المناطق / الأقاليم', one: 'منطقة', icon: '🗺️', parent: 'country', parentLabel: 'الدولة', hint: 'المدن والمناطق بتطلع اختيارات جاهزة بعنوان العميل والمورد.' },
  cheque_type:    { label: 'أنواع الأوراق التجارية', one: 'نوع', icon: '🧾', hint: 'شيك، كمبيالة، سند لأمر…' },
  loyalty_type:   { label: 'أنواع بطاقات الولاء', one: 'نوع بطاقة', icon: '💳', hint: 'مثلاً: فضية، ذهبية. «النسبة» هون = عدد النقاط لكل دينار مشتريات.' },
  brand:          { label: 'الماركات', one: 'ماركة', icon: '🏷️', hint: 'ماركة الصنف (مثلاً: Milwaukee، Bosch). بتنختار ببطاقة الصنف وبتنفلتر فيها قائمة الأصناف.' },
  route:          { label: 'المسارات (خطوط التوزيع)', one: 'مسار', icon: '🛣️', hint: 'خط سير المندوب أو التوزيع (مثلاً: خط الزرقاء، خط إربد). بينربط على بطاقة العميل.' },
  sales_rep:      { label: 'مندوبي المبيعات', one: 'مندوب', icon: '🧑‍💼', hint: 'المندوب بينربط على العميل وعلى فاتورة المبيعات، وإله نسبة عمولة على صافي مبيعاته.' },
};

export async function loadLookups(force = false) {
  if (!S.company) return [];
  if (!force && S._lk?.cid === S.company.id) return S._lk.rows;
  const { data, error } = await sb.from('lookups').select('*').eq('company_id', S.company.id).order('code');
  S._lk = { cid: S.company.id, rows: error ? [] : (data || []) };
  return S._lk.rows;
}
// datalist جاهزة لحقل نص (اسم البنك، المدينة…)
export async function lookupDatalist(id, kinds) {
  const rows = (await loadLookups()).filter(r => kinds.includes(r.kind) && r.is_active);
  return `<datalist id="${id}">${rows.map(r => `<option value="${esc(r.name)}">`).join('')}</datalist>`;
}
export function lookupDatalistSync(id, kinds) {
  const rows = (S._lk?.cid === S.company?.id ? S._lk.rows : []).filter(r => kinds.includes(r.kind) && r.is_active);
  return `<datalist id="${id}">${rows.map(r => `<option value="${esc(r.name)}">`).join('')}</datalist>`;
}
// خيارات «وسيلة الدفع» فوق قائمة الصندوق/البنك (القيمة = حساب الوسيلة)
export function pmOptions(where = '') {
  const rows = (S._lk?.cid === S.company?.id ? S._lk.rows : []).filter(r => r.kind === 'payment_method' && r.is_active && r.account_id
    && (where === 'sales' ? r.use_sales !== false : where === 'purchases' ? r.use_purchases !== false : true));
  return rows.length ? `<optgroup label="وسائل الدفع">${rows.map(r => `<option value="${r.account_id}" data-pm="${r.id}">💳 ${esc(r.name)}${num(r.rate) && r.commission_account_id ? ` (عمولة ${num(r.rate)}%)` : ''}</option>`).join('')}</optgroup><optgroup label="الحسابات">` : '';
}
export function repOptions(sel) {
  const rows = (S._lk?.cid === S.company?.id ? S._lk.rows : []).filter(r => r.kind === 'sales_rep' && (r.is_active || r.id === sel));
  return rows.map(r => `<option value="${r.id}" ${r.id === sel ? 'selected' : ''}>${esc(r.code)} — ${esc(r.name)}</option>`).join('');
}
export function loyaltyOptions(sel) {
  const rows = (S._lk?.cid === S.company?.id ? S._lk.rows : []).filter(r => r.kind === 'loyalty_type' && (r.is_active || r.id === sel));
  return rows.map(r => `<option value="${r.id}" ${r.id === sel ? 'selected' : ''}>${esc(r.name)}</option>`).join('');
}
export const hasLoyalty = () => (S._lk?.cid === S.company?.id ? S._lk.rows : []).some(r => r.kind === 'loyalty_type' && r.is_active);
export const hasReps = () => (S._lk?.cid === S.company?.id ? S._lk.rows : []).some(r => r.kind === 'sales_rep' && r.is_active);
export async function posMethods() { return (await loadLookups()).filter(r => r.kind === 'payment_method' && r.is_active && r.account_id && r.use_pos); }
export async function paymentMethods() { return (await loadLookups()).filter(r => r.kind === 'payment_method' && r.is_active && r.account_id); }

async function viewLookups(v) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const kind = LK[new URLSearchParams(location.hash.split('?')[1] || '').get('k')] ? new URLSearchParams(location.hash.split('?')[1]).get('k') : 'payment_method';
  const [rows, accs] = await Promise.all([loadLookups(true), loadAccounts()]);
  const K = LK[kind], byId = Object.fromEntries(rows.map(r => [r.id, r]));
  const list = rows.filter(r => r.kind === kind);
  const cashAccs = leafAccounts(accs).filter(a => a.category === 'assets');
  const leafAll = leafAccounts(accs);
  const users = kind === 'sales_rep' ? ((await sb.from('profiles').select('id,username,full_name').eq('is_active', true).order('username')).data || []) : [];
  v.innerHTML = `<div class="page-head"><h2>⚙️ الإعداد</h2><div class="spacer"></div>
      ${can('lookups', 'add') ? `<button class="btn primary" id="add">➕ ${esc(K.one)} جديد${kind === 'payment_method' || kind === 'country' || kind === 'region' ? 'ة' : ''}</button>` : ''}</div>
    <div class="tabs lk-tabs">${Object.entries(LK).map(([k, x]) => `<a class="tab ${k === kind ? 'active' : ''}" href="#/setup?k=${k}">${x.icon} ${esc(x.label)} <span class="muted" style="font-size:11px">${rows.filter(r => r.kind === k).length}</span></a>`).join('')}</div>
    ${K.hint ? `<p class="muted" style="font-size:13px;margin:8px 0">${esc(K.hint)}</p>` : ''}
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرمز</th><th>الاسم</th><th>الاسم 2</th>${K.parent ? `<th>${esc(K.parentLabel)}</th>` : ''}${kind === 'payment_method' ? '<th>الحساب</th><th>بتظهر في</th>' : ''}${kind === 'sales_rep' ? '<th>العمولة %</th>' : ''}${kind === 'loyalty_type' ? '<th>نقاط/دينار</th>' : ''}<th>الحالة</th><th></th></tr></thead>
      <tbody>${list.map(r => `<tr><td dir="ltr" style="text-align:right">${esc(r.code)}</td><td><b>${esc(r.name)}</b></td><td>${esc(r.name2 || '')}</td>
        ${K.parent ? `<td>${esc(byId[r.parent_id]?.name || '')}</td>` : ''}${kind === 'payment_method' ? `<td>${esc(accLabel(accs.find(a => a.id === r.account_id)) || '')}</td><td style="font-size:12.5px">${[r.use_sales !== false && 'المبيعات', r.use_purchases !== false && 'المشتريات', r.use_pos && `نقطة البيع${r.pos_label ? ' («' + esc(r.pos_label) + '»)' : ''}`].filter(Boolean).join('، ') || '—'}</td>` : ''}${kind === 'sales_rep' || kind === 'loyalty_type' ? `<td class="n">${r.rate ?? ''}</td>` : ''}
        <td>${r.is_active ? '<span class="badge ok">فعّال</span>' : '<span class="badge">غير فعّال</span>'}</td>
        <td class="actions">${can('lookups', 'edit') ? `<button class="btn sm" data-edit="${r.id}">تعديل</button>` : ''}${can('lookups', 'delete') ? `<button class="btn sm danger" data-del="${r.id}">حذف</button>` : ''}</td></tr>`).join('')
        || `<tr><td colspan="7" class="empty">ما في ${esc(K.label)} لسا</td></tr>`}</tbody></table></div>`;
  const open = (r) => {
    const isNew = !r;
    const next = String(Math.max(0, ...list.map(x => /^\d+$/.test(x.code) ? +x.code : 0)) + 1).padStart(2, '0');
    r = r || { code: next, name: '', is_active: true };
    const parents = K.parent ? rows.filter(x => x.kind === K.parent) : [];
    const m = modal({ title: `${isNew ? '➕' : '✏️'} ${esc(K.one)}`, size: 'sm', body: `<form id="lk-form" autocomplete="off">
      <div class="grid cols-2"><div class="field"><label>الرمز *</label><input name="code" dir="ltr" value="${esc(r.code)}"></div>
        <div class="field"><label>${kind === 'payment_method' ? 'الاسم بالعربي' : 'الاسم'} *</label><input name="name" value="${esc(r.name)}" ${kind === 'payment_method' ? 'placeholder="صندوق المبيعات"' : ''}></div></div>
      <div class="field"><label>${kind === 'payment_method' ? 'الاسم بالإنجليزي' : 'الاسم 2 (إنجليزي مثلاً)'}</label><input name="name2" dir="auto" value="${esc(r.name2 || '')}" ${kind === 'payment_method' ? 'placeholder="Cash"' : ''}></div>
      ${kind === 'payment_method' ? `<div class="field"><label>الاسم الظاهر على كبسة نقطة البيع</label><input name="pos_label" value="${esc(r.pos_label || '')}" placeholder="💵 كاش"></div>
      <div class="field"><label>بتظهر في</label><div style="display:flex;gap:16px;flex-wrap:wrap">
        <label class="check"><input type="checkbox" name="use_sales" ${r.use_sales !== false ? 'checked' : ''}> فاتورة المبيعات</label>
        <label class="check"><input type="checkbox" name="use_purchases" ${r.use_purchases !== false ? 'checked' : ''}> فاتورة المشتريات</label>
        <label class="check"><input type="checkbox" name="use_pos" ${r.use_pos ? 'checked' : ''}> نقطة البيع</label></div></div>` : ''}
      ${K.parent ? `<div class="field"><label>${esc(K.parentLabel)}</label><select name="parent_id"><option value="">—</option>${parents.map(p => `<option value="${p.id}" ${p.id === r.parent_id ? 'selected' : ''}>${esc(p.name)}</option>`).join('')}</select></div>` : ''}
      ${kind === 'payment_method' ? `<div class="field"><label>الحساب المرتبط من الشجرة (الطرف المدين) *</label><select name="account_id"><option value="">— اختار —</option>${cashAccs.map(a => `<option value="${a.id}" ${a.id === r.account_id ? 'selected' : ''}>${esc(accLabel(a))}${['cash', 'bank'].includes(a.account_type) ? ' ★' : ''}</option>`).join('')}</select></div>` : ''}
      ${kind === 'payment_method' ? `<div class="field"><label>نسبة العمولة % (فيزا مثلاً، بتنخصم بسند القبض)</label><input name="rate" dir="ltr" inputmode="decimal" value="${r.rate ?? ''}" placeholder="2.25"></div>
        <div class="field"><label>حساب العمولة (مصروف)</label><select name="commission_account_id"><option value="">—</option>${leafAll.map(a => `<option value="${a.id}" ${a.id === r.commission_account_id ? 'selected' : ''}>${esc(accLabel(a))}</option>`).join('')}</select></div>` : ''}
      ${kind === 'loyalty_type' ? `<div class="field"><label>نقاط لكل دينار</label><input name="rate" dir="ltr" inputmode="decimal" value="${r.rate ?? 1}"></div>` : ''}
      ${kind === 'sales_rep' ? `<div class="field"><label>نسبة العمولة %</label><input name="rate" dir="ltr" inputmode="decimal" value="${r.rate ?? ''}"></div>
        <div class="field"><label>الدور</label><select name="rep_role"><option value="">—</option>${[['rep', 'مندوب'], ['supervisor', 'مشرف'], ['manager', 'مدير مبيعات']].map(([k, l]) => `<option value="${k}" ${k === r.rep_role ? 'selected' : ''}>${l}</option>`).join('')}</select></div>
        <div class="field"><label>المشرف / الرئيس المباشر</label><select name="supervisor_id"><option value="">—</option>${rows.filter(x => x.kind === 'sales_rep' && x.id !== r.id && (x.is_active || x.id === r.supervisor_id)).map(x => `<option value="${x.id}" ${x.id === r.supervisor_id ? 'selected' : ''}>${esc(x.code)} — ${esc(x.name)}</option>`).join('')}</select></div>
        <div class="field"><label>مستخدم البرنامج (لتطبيق المندوب و«زبائني»)</label><select name="user_id"><option value="">—</option>${(users || []).map(u => `<option value="${u.id}" ${u.id === r.user_id ? 'selected' : ''}>${esc(u.full_name || u.username || '')}</option>`).join('')}</select></div>` : ''}
      ${kind === 'route' ? `<div class="field"><label>أيام المسار</label><div style="display:flex;gap:10px;flex-wrap:wrap">${['الأحد', 'الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت'].map((dn, i) => `<label class="check"><input type="checkbox" name="wd${i}" ${(r.weekdays || []).includes(i) ? 'checked' : ''}> ${dn}</label>`).join('')}</div></div>` : ''}
      <div class="field"><label>ملاحظات</label><input name="notes" value="${esc(r.notes || '')}"></div>
      <label class="check"><input type="checkbox" name="inactive" ${r.is_active ? '' : 'checked'}> غير مفعّل</label></form>`,
      foot: `<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>` });
    m.el.querySelector('[data-save]').onclick = async (e) => {
      const d = formData(m.el.querySelector('#lk-form'));
      if (!d.code?.trim() || !d.name?.trim()) return toast('الرمز والاسم مطلوبين', 'err');
      if (kind === 'payment_method' && !d.account_id) return toast('اختار الحساب', 'err');
      const rec = { code: d.code.trim(), name: d.name.trim(), name2: d.name2 || null, parent_id: d.parent_id || null, account_id: d.account_id || null, notes: d.notes || null, is_active: !d.inactive, ...(kind === 'sales_rep' || kind === 'loyalty_type' ? { rate: d.rate === '' || d.rate == null ? null : Number(d.rate) } : {}),
        ...(kind === 'sales_rep' ? { user_id: d.user_id || null, supervisor_id: d.supervisor_id || null, rep_role: d.rep_role || null } : {}), ...(kind === 'route' ? { weekdays: [0, 1, 2, 3, 4, 5, 6].filter(i => d['wd' + i]) } : {}),
        ...(kind === 'payment_method' ? { rate: d.rate === '' || d.rate == null ? null : num(d.rate), commission_account_id: d.commission_account_id || null, pos_label: (d.pos_label || '').trim() || null, use_sales: !!d.use_sales, use_purchases: !!d.use_purchases, use_pos: !!d.use_pos } : {}) };
      e.target.disabled = true;
      const res = isNew ? await sb.from('lookups').insert({ ...rec, company_id: S.company.id, kind }) : await sb.from('lookups').update(rec).eq('id', r.id);
      if (res.error) { e.target.disabled = false; return toast(/duplicate|unique/.test(res.error.message) ? 'الرمز مستعمل' : arError(res.error), 'err'); }
      toast('انحفظ', 'ok'); m.close(); viewLookups(v);
    };
  };
  v.querySelector('#add')?.addEventListener('click', () => open(null));
  v.querySelector('table').onclick = async (e) => {
    const ed = e.target.closest('[data-edit]'), dl = e.target.closest('[data-del]');
    if (ed) open(byId[ed.dataset.edit]);
    if (dl) {
      if (!(await confirmBox(`حذف «${byId[dl.dataset.del].name}»؟`))) return;
      const { error } = await sb.from('lookups').delete().eq('id', dl.dataset.del);
      if (error) return toast(/foreign key|violates/.test(error.message) ? 'مستعمل (إله فروع)، أوقفه بدل الحذف' : arError(error), 'err');
      toast('انحذف', 'ok'); viewLookups(v);
    }
  };
}

export const LOOKUP_ROUTES = { 'setup': viewLookups };
