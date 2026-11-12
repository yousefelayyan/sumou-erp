// =====================================================================
//  السمو ERP — الدوائر: شجرة فروع/أقسام الشركة (رئيسية وفرعية)
//  الدائرة الفرعية بتنختار على القيود والفواتير وسندات المخزون، وكل مستخدم إله دائرة افتراضية.
// =====================================================================
import { S, sb, esc, toast, arError, can, modal, confirmBox, formData, setupTabs } from './core.js';
import { masterCode, loadNumbering } from './numbering.js';
import { attachAudit } from './audit.js';

// ---------------------------------------------------------------------
//  أدوات للمستندات
// ---------------------------------------------------------------------
export async function loadDepartments(force = false) {
  if (!S.company) return [];
  if (!force && S._depts?.cid === S.company.id) return S._depts.rows;
  const { data, error } = await sb.from('departments').select('*').eq('company_id', S.company.id).order('code');
  if (error) { S._depts = { cid: S.company.id, rows: [] }; return []; }
  S._depts = { cid: S.company.id, rows: data || [] };
  return S._depts.rows;
}
const myMembership = () => (S.memberships || []).find(m => m.company_id === S.company?.id) || {};
// حقل «الدائرة» بالمستند: بيظهر بس إذا في دوائر فرعية وما انخفى للمستخدم
export async function deptField(current, ro = '', isNew = !current) {
  const rows = (await loadDepartments()).filter(d => d.kind === 'sub' && (d.is_active || d.id === current));
  if (!rows.length || (myMembership().hide_departments && !current)) return '';
  const def = current || (isNew ? myMembership().department_id : '') || '';
  return `<div class="field"><label>الدائرة</label><select name="department_id" ${ro} ${myMembership().hide_departments ? 'disabled' : ''}>
    <option value="">— الافتراضية —</option>${rows.map(d => `<option value="${d.id}" ${d.id === def ? 'selected' : ''}>${esc(d.code)} — ${esc(d.name)}</option>`).join('')}</select></div>`;
}
// قيمة الدائرة من النموذج (فاضي = اتركها لقاعدة البيانات تحط الافتراضية)
export function deptValue(form) {
  const el = form.querySelector('[name=department_id]');
  if (!el || el.disabled) return {};
  return { department_id: el.value || null };
}
export const deptName = (id) => { const d = S._depts?.rows?.find(x => x.id === id); return d ? `${d.code} — ${d.name}` : ''; };

// ---------------------------------------------------------------------
//  شاشة الدوائر
// ---------------------------------------------------------------------
async function viewDepartments(v) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const [rows, , whR, ccR] = await Promise.all([loadDepartments(true), loadNumbering?.(),
    sb.from('warehouses').select('id,code,name').eq('company_id', S.company.id).order('code'),
    sb.from('cost_centers').select('id,code,name').eq('company_id', S.company.id).order('code')]);
  const whs = whR.data || [], ccs = ccR.data || [];
  const byId = Object.fromEntries(rows.map(d => [d.id, d]));
  let sel = rows.find(d => d.id === S._deptSel) || rows[0] || null;
  let editing = null;   // null = عرض، {} = جديد، row = تعديل
  let q = '';
  const kids = (pid) => rows.filter(d => (d.parent_id || null) === pid).sort((a, b) => a.code.localeCompare(b.code, 'en', { numeric: true }));
  const match = (d) => !q || [d.code, d.name, d.name2].some(x => (x || '').toLowerCase().includes(q)) || kids(d.id).some(match);
  const node = (d) => {
    if (!match(d)) return '';
    const ch = kids(d.id);
    return `<li><div class="dt-node ${sel?.id === d.id ? 'on' : ''} ${d.is_active ? '' : 'off'}" data-id="${d.id}">
        <span class="dt-ico">${d.kind === 'main' ? '🏛️' : '🏢'}</span><span dir="ltr" class="dt-code">${esc(d.code)}</span> ${esc(d.name)}${d.is_active ? '' : ' <span class="badge">غير مفعّل</span>'}</div>
      ${ch.length ? `<ul>${ch.map(node).join('')}</ul>` : ''}</li>`;
  };
  const val = (x) => esc(x ?? '');
  const show = (x) => x ? esc(x) : '<span class="muted">—</span>';
  function formHTML(d, ro) {
    const mains = rows.filter(x => x.kind === 'main' && x.id !== d.id);
    const inp = (n, l, extra = '') => `<div class="field"><label>${l}</label>${ro ? `<div class="ro-val">${show(d[n])}</div>` : `<input name="${n}" value="${val(d[n])}" ${extra}>`}</div>`;
    return `<form id="dp-form" autocomplete="off">
      <div class="grid cols-3">
        ${inp('code', 'رمز الدائرة *', 'dir="ltr"')}
        <div class="field" style="grid-column:span 2"><label>الوصف *</label>${ro ? `<div class="ro-val">${show(d.name)}</div>` : `<input name="name" value="${val(d.name)}">`}</div>
        <div class="field" style="grid-column:span 2"><label>الوصف 2</label>${ro ? `<div class="ro-val">${show(d.name2)}</div>` : `<input name="name2" value="${val(d.name2)}">`}</div>
        <div class="field"><label>نوع الدائرة</label>${ro ? `<div class="ro-val">${d.kind === 'main' ? 'دائرة رئيسية' : 'دائرة فرعية'}</div>` : `<select name="kind"><option value="sub" ${d.kind !== 'main' ? 'selected' : ''}>دائرة فرعية</option><option value="main" ${d.kind === 'main' ? 'selected' : ''}>دائرة رئيسية</option></select>`}</div>
        <div class="field" style="grid-column:span 2"><label>الدائرة الرئيسية</label>${ro ? `<div class="ro-val">${d.parent_id ? esc(byId[d.parent_id]?.code + ' — ' + byId[d.parent_id]?.name) : '<span class="muted">— بدون (أعلى الشجرة) —</span>'}</div>`
          : `<select name="parent_id"><option value="">— بدون (أعلى الشجرة) —</option>${mains.map(x => `<option value="${x.id}" ${x.id === d.parent_id ? 'selected' : ''}>${esc(x.code)} — ${esc(x.name)}</option>`).join('')}</select>`}</div>
        <div class="field"><label>&nbsp;</label><label class="check"><input type="checkbox" name="inactive" ${d.is_active === false ? 'checked' : ''} ${ro ? 'disabled' : ''}> غير مفعّل</label></div>
      </div>
      <div class="tabs">
        <div class="tab active" data-tab="g">عام</div><div class="tab" data-tab="a">العنوان</div><div class="tab" data-tab="s">المخزون والكلفة</div><div class="tab" data-tab="n">ملاحظات</div>
      </div>
      <div class="tab-panel active" data-tab="g"><div class="grid cols-3">
        <div class="field"><label>اسم الشركة</label><div class="ro-val">${esc(S.company.name)}</div></div>
        ${inp('sales_tax_no', 'رقم ضريبة المبيعات', 'dir="ltr"')}${inp('income_tax_no', 'رقم ضريبة الدخل', 'dir="ltr"')}
        ${inp('national_no', 'الرقم الوطني للمنشأة', 'dir="ltr"')}${inp('currency', 'العملة', 'dir="ltr" placeholder="' + esc(S.company.currency || 'JOD') + '"')}
      </div><p class="muted" style="font-size:12px;margin:0">إذا تركت الأرقام فاضية بتنستعمل أرقام الشركة.</p></div>
      <div class="tab-panel" data-tab="a"><div class="grid cols-3">
        ${inp('city', 'المدينة')}<div class="field" style="grid-column:span 2"><label>العنوان</label>${ro ? `<div class="ro-val">${show(d.address)}</div>` : `<input name="address" value="${val(d.address)}">`}</div>
        ${inp('phone', 'الهاتف', 'dir="ltr"')}${inp('mobile', 'الموبايل', 'dir="ltr"')}${inp('email', 'الإيميل', 'dir="ltr"')}
      </div></div>
      <div class="tab-panel" data-tab="s"><div class="grid cols-2">
        <div class="field"><label>المستودع الافتراضي</label>${ro ? `<div class="ro-val">${show(whs.find(w => w.id === d.warehouse_id)?.name)}</div>` : `<select name="warehouse_id"><option value="">—</option>${whs.map(w => `<option value="${w.id}" ${w.id === d.warehouse_id ? 'selected' : ''}>${esc(w.code)} — ${esc(w.name)}</option>`).join('')}</select>`}</div>
        <div class="field"><label>مركز الكلفة</label>${ro ? `<div class="ro-val">${show(ccs.find(c => c.id === d.cost_center_id)?.name)}</div>` : `<select name="cost_center_id"><option value="">—</option>${ccs.map(c => `<option value="${c.id}" ${c.id === d.cost_center_id ? 'selected' : ''}>${esc(c.code)} — ${esc(c.name)}</option>`).join('')}</select>`}</div>
      </div></div>
      <div class="tab-panel" data-tab="n"><div class="field">${ro ? `<div class="ro-val" style="min-height:80px;white-space:pre-wrap">${show(d.notes)}</div>` : `<textarea name="notes" rows="5">${val(d.notes)}</textarea>`}</div></div>
    </form>`;
  }
  function draw() {
    const roots = kids(null);
    const cur = editing || sel;
    const ro = !editing;
    v.innerHTML = `<div class="page-head"><h2>🏛️ الدوائر</h2><div class="spacer"></div>
        ${can('departments', 'add') && !editing ? `<button class="btn primary" data-new="sub">➕ دائرة فرعية</button><button class="btn" data-new="main">➕ دائرة رئيسية</button>` : ''}</div>
      <div class="dept-layout">
        <div class="card dept-tree"><input class="dt-search" placeholder="🔎 بحث بالرمز أو الاسم…" value="${esc(q)}">
          <ul class="dt">${roots.map(node).join('') || '<li class="muted" style="padding:10px">ما في دوائر لسا. ابدأ بـ «دائرة رئيسية» (مثلاً الإدارة العامة) وبعدين الفرعية تحتها.</li>'}</ul>
          <p class="muted" style="font-size:12px;margin:8px 0 0">🏛️ رئيسية (بيتفرّع منها) — 🏢 فرعية (بتنختار على المستندات)</p></div>
        <div class="card dept-form">${cur ? `
          <div style="display:flex;gap:6px;align-items:center;margin-bottom:10px"><h3 style="margin:0">${editing ? (editing.id ? '✏️ تعديل الدائرة' : '➕ دائرة جديدة') : esc(cur.name)}</h3><div class="spacer" style="flex:1"></div>
            ${ro && can('departments', 'edit') ? '<button class="btn sm" data-edit>✏️ تعديل</button>' : ''}
            ${ro && can('departments', 'delete') ? '<button class="btn sm danger" data-del>🗑️ حذف</button>' : ''}</div>
          ${formHTML(cur, ro)}
          ${editing ? '<div style="display:flex;gap:6px;margin-top:12px"><button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-cancel>إلغاء</button></div>' : '<div id="dp-audit"></div>'}`
          : '<div class="empty">اختار دائرة من الشجرة</div>'}</div>
      </div>`;
    setupTabs(v);
    const s = v.querySelector('.dt-search');
    s.oninput = () => { q = s.value.trim().toLowerCase(); const pos = s.selectionStart; draw(); const n = v.querySelector('.dt-search'); n.focus(); n.setSelectionRange(pos, pos); };
    v.querySelector('.dt').onclick = (e) => { const n = e.target.closest('.dt-node'); if (!n || editing) return; sel = byId[n.dataset.id]; S._deptSel = sel.id; draw(); };
    v.querySelectorAll('[data-new]').forEach(b => b.onclick = () => {
      const kind = b.dataset.new, parent = sel?.kind === 'main' ? sel.id : (sel?.parent_id || null);
      editing = { kind, parent_id: kind === 'sub' ? parent : (sel?.kind === 'main' ? sel.id : null), is_active: true,
        code: masterCode('m_department', rows.map(x => x.code), parent ? byId[parent]?.code : null)
          ?? (kind === 'main' ? 'M' + (rows.filter(x => x.kind === 'main').length + 1) : String(Math.max(0, ...rows.map(x => /^\d+$/.test(x.code) ? +x.code : 0)) + 1)) };
      draw(); v.querySelector('[name=name]')?.focus();
    });
    v.querySelector('[data-edit]')?.addEventListener('click', () => { editing = { ...sel }; draw(); });
    v.querySelector('[data-cancel]')?.addEventListener('click', () => { editing = null; draw(); });
    v.querySelector('[data-del]')?.addEventListener('click', async () => {
      if (!(await confirmBox(`حذف الدائرة «${sel.name}»؟`))) return;
      const { error } = await sb.from('departments').delete().eq('id', sel.id);
      if (error) return toast(/foreign key|violates/.test(error.message) ? 'الدائرة مستعملة (عليها مستندات أو فروع أو مستخدمين)، أوقفها بدل الحذف' : arError(error), 'err');
      toast('انحذفت', 'ok'); S._deptSel = null; viewDepartments(v);
    });
    v.querySelector('[data-save]')?.addEventListener('click', async (e) => {
      const d = formData(v.querySelector('#dp-form'));
      const rec = { code: (d.code || '').trim(), name: (d.name || '').trim(), name2: d.name2 || null, kind: d.kind, parent_id: d.parent_id || null,
        is_active: !d.inactive, sales_tax_no: d.sales_tax_no || null, income_tax_no: d.income_tax_no || null, national_no: d.national_no || null,
        currency: d.currency || null, city: d.city || null, address: d.address || null, phone: d.phone || null, mobile: d.mobile || null, email: d.email || null,
        warehouse_id: d.warehouse_id || null, cost_center_id: d.cost_center_id || null, notes: d.notes || null };
      if (!rec.code) return toast('اكتب رمز الدائرة', 'err');
      if (!rec.name) return toast('اكتب وصف الدائرة', 'err');
      e.target.disabled = true;
      const r = editing.id ? await sb.from('departments').update(rec).eq('id', editing.id).select().single()
                           : await sb.from('departments').insert({ ...rec, company_id: S.company.id }).select().single();
      if (r.error) { e.target.disabled = false; return toast(/duplicate|unique/.test(r.error.message) ? 'الرمز مستعمل لدائرة ثانية' : arError(r.error), 'err'); }
      toast('انحفظت', 'ok'); S._deptSel = r.data.id; editing = null; viewDepartments(v);
    });
    if (!editing && sel) attachAudit(v.querySelector('#dp-audit'), sel);
  }
  draw();
}

export const DEPARTMENT_ROUTES = { 'departments': viewDepartments };
