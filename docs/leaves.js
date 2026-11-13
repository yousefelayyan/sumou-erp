// =====================================================================
//  السمو ERP — الإجازات (route leaves?t=requests|balances|types) + myLeavesCard() ببطاقة «راتبي»
//  الكتابة من الدوال: leave_request / leave_decide / leave_cancel؛ الأنواع بصلاحية payroll edit.
// =====================================================================
import { S, sb, esc, fmtDate, fmtNum, num, today, toast, arError, modal, confirmBox, formData, can } from './core.js';

const ST = { pending: ['بالانتظار', 'warn'], approved: ['معتمدة', 'ok'], rejected: ['مرفوضة', 'bad'], cancelled: ['ملغاة', ''] };
const badge = (s) => `<span class="badge ${ST[s][1]}">${ST[s][0]}</span>`;
const qp = () => new URLSearchParams(location.hash.split('?')[1] || '');
const fmtDays = (d) => (num(d) % 1 ? fmtNum(d).replace(/0+$/, '') : String(num(d)));

async function loadTypes() {
  await sb.rpc('ensure_leave_types', { p_company: S.company.id });
  const { data } = await sb.from('leave_types').select('*').eq('company_id', S.company.id).order('code');
  return data || [];
}

// نافذة طلب إجازة (للموظف نفسه أو للمشرف لأي موظف)
export async function leaveForm(ctx, { employees = null, empId = null } = {}) {
  const types = (await loadTypes()).filter(t => t.is_active);
  const m = modal({ title: 'طلب إجازة', body: `<form id="lv-f"><div class="grid cols-2">
      ${employees ? `<div class="field" style="grid-column:span 2"><label>الموظف *</label><select name="employee_id"><option value="">— اختار —</option>${employees.map(e => `<option value="${e.id}" ${e.id === empId ? 'selected' : ''}>${esc(e.code)} — ${esc(e.name)}</option>`).join('')}</select></div>` : ''}
      <div class="field" style="grid-column:span 2"><label>نوع الإجازة *</label><select name="type_id">${types.map(t => `<option value="${t.id}">${esc(t.name)}${t.paid ? '' : ' (بدون راتب)'}${num(t.annual_days) ? ` — ${fmtDays(t.annual_days)} يوم بالسنة` : ''}</option>`).join('')}</select></div>
      <div class="field"><label>من *</label><input type="date" name="from_date" value="${today()}"></div>
      <div class="field"><label>إلى *</label><input type="date" name="to_date" value="${today()}"></div>
      <label class="check" style="grid-column:span 2"><input type="checkbox" name="half_day"> نص يوم (ليوم واحد)</label>
      <div class="field" style="grid-column:span 2"><label>السبب</label><input name="reason"></div></div>
      <p class="muted" style="font-size:12px" id="lv-days"></p></form>`,
    foot: '<button class="btn primary" data-save>📨 إرسال الطلب</button><button class="btn" data-close>إلغاء</button>' });
  const f = m.el.querySelector('#lv-f');
  const calc = () => {
    const d = formData(f); if (!d.from_date || !d.to_date || d.to_date < d.from_date) return void (m.el.querySelector('#lv-days').textContent = '');
    let n = 0; for (let x = new Date(d.from_date); x <= new Date(d.to_date); x.setDate(x.getDate() + 1)) if (x.getDay() !== 5) n++;
    m.el.querySelector('#lv-days').textContent = `عدد الأيام: ${d.half_day ? 'نص يوم' : n + ' يوم'} (بدون أيام الجمعة)`;
  };
  f.addEventListener('input', calc); calc();
  m.el.querySelector('[data-save]').onclick = async () => {
    const d = formData(f);
    if (employees && !d.employee_id) return toast('اختار الموظف', 'err');
    const { error } = await sb.rpc('leave_request', { p: { company_id: S.company.id, employee_id: d.employee_id || null, type_id: d.type_id, from_date: d.from_date, to_date: d.to_date, half_day: !!d.half_day, reason: d.reason } });
    if (error) return toast(arError(error), 'err');
    toast('انبعت الطلب', 'ok'); m.close(); ctx.rerender();
  };
}

// بطاقة «إجازاتي» بشاشة راتبي
export async function myLeavesCard(el, empId, ctx) {
  const yr = new Date().getFullYear();
  const [bal, req] = await Promise.all([sb.rpc('leave_balance', { p_company: S.company.id, p_employee: empId, p_year: yr }),
    sb.from('leave_requests').select('*,leave_types(name)').eq('employee_id', empId).order('from_date', { ascending: false }).limit(20)]);
  el.innerHTML = `<div class="page-head" style="margin-top:16px"><h3>🌴 إجازاتي ${yr}</h3><div class="spacer"></div><button class="btn primary" id="lv-new">➕ طلب إجازة</button></div>
    <div class="grid cols-3">${(bal.data || []).filter(b => num(b.entitled) || num(b.used) || num(b.pending)).map(b => `<div class="card" style="text-align:center;padding:10px">
      <div class="muted" style="font-size:12px">${esc(b.name)}</div>
      <div style="font-size:24px;font-weight:800">${b.remaining == null ? fmtDays(b.used) : fmtDays(b.remaining)}</div>
      <div class="muted" style="font-size:11px">${b.remaining == null ? 'يوم مستعمل' : `متبقي من ${fmtDays(b.entitled)}`}${num(b.pending) ? ` · ${fmtDays(b.pending)} بالانتظار` : ''}</div></div>`).join('') || '<div class="muted">ما في أنواع إجازات</div>'}</div>
    ${(req.data || []).map(r => `<div class="card" style="margin-top:8px;display:flex;gap:10px;align-items:center"><div style="flex:1"><b>${esc(r.leave_types?.name || '')}</b> ${badge(r.status)}
        <div class="muted" style="font-size:12px">${fmtDate(r.from_date)}${r.to_date !== r.from_date ? ' ← ' + fmtDate(r.to_date) : ''} · ${r.half_day ? 'نص يوم' : fmtDays(r.days) + ' يوم'}${r.decision_note ? ' · ' + esc(r.decision_note) : ''}</div></div>
        ${r.status === 'pending' ? `<button class="btn sm" data-lvc="${r.id}">إلغاء</button>` : ''}</div>`).join('')}`;
  el.querySelector('#lv-new').onclick = () => leaveForm(ctx);
  el.querySelectorAll('[data-lvc]').forEach(b => b.onclick = async () => {
    if (!(await confirmBox('إلغاء طلب الإجازة؟'))) return;
    const { error } = await sb.rpc('leave_cancel', { p_id: b.dataset.lvc }); if (error) return toast(arError(error), 'err');
    toast('انلغى', 'ok'); ctx.rerender();
  });
}

async function viewLeaves(v, ctx) {
  if (!S.company) return void (v.innerHTML = '<div class="notice info">اختار شركة من فوق أول.</div>');
  const t = qp().get('t') || 'requests';
  const head = `<div class="page-head"><h2>🌴 الإجازات</h2><div class="spacer"></div>
      ${can('payroll', 'add') ? '<button class="btn primary" id="lv-add">➕ إجازة لموظف</button>' : ''}</div>
    <div class="tabs" style="margin-bottom:10px">${[['requests', 'الطلبات'], ['balances', 'أرصدة الموظفين'], ['types', 'أنواع الإجازات']]
      .map(([k, l]) => `<a class="tab ${t === k ? 'active' : ''}" href="#/leaves?t=${k}">${l}</a>`).join('')}</div>`;
  const [types, empR] = await Promise.all([loadTypes(), sb.from('employees').select('id,code,name,is_active').eq('company_id', S.company.id).order('code')]);
  const emps = (empR.data || []).filter(e => e.is_active), eById = Object.fromEntries((empR.data || []).map(e => [e.id, e])), tById = Object.fromEntries(types.map(x => [x.id, x]));
  const wire = () => v.querySelector('#lv-add')?.addEventListener('click', () => leaveForm(ctx, { employees: emps }));

  if (t === 'types') {
    const ed = can('payroll', 'edit');
    v.innerHTML = `${head}<div class="card table-wrap"><table class="t"><thead><tr><th>الرمز</th><th>الاسم</th><th>مدفوعة</th><th>الأيام بالسنة</th><th>فعّال</th><th></th></tr></thead><tbody>
      ${types.map(x => `<tr><td>${esc(x.code)}</td><td>${esc(x.name)}</td><td>${x.paid ? '✓' : '<span class="badge warn">بدون راتب</span>'}</td><td>${num(x.annual_days) ? fmtDays(x.annual_days) : 'بدون حد'}</td><td>${x.is_active ? '✓' : '—'}</td>
        <td>${ed ? `<button class="btn sm" data-te="${x.id}">تعديل</button>` : ''}</td></tr>`).join('')}</tbody></table>
      ${ed ? '<button class="btn sm" id="t-add" style="margin-top:8px">➕ نوع</button>' : ''}
      <p class="muted" style="font-size:12px">«بدون راتب» بتنخصم لحالها بمسيّر الرواتب: (الأساسي + العلاوات) ÷ 30 × أيام الإجازة بالشهر، على «خصومات أخرى».</p></div>`;
    wire();
    const form = (x) => {
      x = x || { code: String(types.length + 1).padStart(2, '0'), name: '', paid: true, annual_days: 0, is_active: true };
      const m = modal({ title: x.id ? 'تعديل نوع إجازة' : 'نوع إجازة جديد', body: `<form id="tf"><div class="grid cols-2">
        <div class="field"><label>الرمز</label><input name="code" value="${esc(x.code)}"></div><div class="field"><label>الاسم</label><input name="name" value="${esc(x.name)}"></div>
        <div class="field"><label>الأيام بالسنة (0 = بدون حد)</label><input name="annual_days" value="${x.annual_days}" inputmode="decimal" dir="ltr"></div><div></div>
        <label class="check"><input type="checkbox" name="paid" ${x.paid ? 'checked' : ''}> مدفوعة الراتب</label><label class="check"><input type="checkbox" name="is_active" ${x.is_active ? 'checked' : ''}> فعّال</label></div></form>`,
        foot: '<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>' });
      m.el.querySelector('[data-save]').onclick = async () => {
        const d = formData(m.el.querySelector('#tf')); if (!d.code || !d.name) return toast('الرمز والاسم مطلوبين', 'err');
        const row = { code: d.code, name: d.name, annual_days: num(d.annual_days), paid: !!d.paid, is_active: !!d.is_active };
        const q = x.id ? sb.from('leave_types').update(row).eq('id', x.id) : sb.from('leave_types').insert({ ...row, company_id: S.company.id });
        const { error } = await q; if (error) return toast(arError(error), 'err');
        toast('تم الحفظ', 'ok'); m.close(); ctx.rerender();
      };
    };
    v.querySelector('#t-add')?.addEventListener('click', () => form(null));
    v.querySelectorAll('[data-te]').forEach(b => b.onclick = () => form(types.find(x => x.id === b.dataset.te)));
    return;
  }

  if (t === 'balances') {
    const yr = +(qp().get('y') || new Date().getFullYear());
    const { data: reqs } = await sb.from('leave_requests').select('employee_id,type_id,days,status').eq('company_id', S.company.id).in('status', ['approved', 'pending'])
      .gte('from_date', `${yr}-01-01`).lte('from_date', `${yr}-12-31`);
    const act = types.filter(x => x.is_active);
    const sum = (e, ty, st) => (reqs || []).filter(r => r.employee_id === e && r.type_id === ty && r.status === st).reduce((s, r) => s + num(r.days), 0);
    v.innerHTML = `${head}<div style="margin-bottom:8px"><label>السنة <select id="yr">${[yr - 1, yr, yr + 1].map(y => `<option ${y === yr ? 'selected' : ''}>${y}</option>`).join('')}</select></label></div>
      <div class="card table-wrap"><table class="t"><thead><tr><th>الموظف</th>${act.map(x => `<th style="text-align:center">${esc(x.name)}<div class="muted" style="font-size:11px;font-weight:400">${num(x.annual_days) ? 'مستعمل / ' + fmtDays(x.annual_days) : 'مستعمل'}</div></th>`).join('')}</tr></thead><tbody>
      ${emps.map(e => `<tr><td>${esc(e.code)} — ${esc(e.name)}</td>${act.map(x => { const u = sum(e.id, x.id, 'approved'), p = sum(e.id, x.id, 'pending'), over = num(x.annual_days) && u > num(x.annual_days);
        return `<td style="text-align:center;${over ? 'color:var(--bad);font-weight:700' : ''}">${u ? fmtDays(u) : '—'}${p ? ` <span class="muted" style="font-size:11px">(+${fmtDays(p)} بالانتظار)</span>` : ''}</td>`; }).join('')}</tr>`).join('') || `<tr><td colspan="${act.length + 1}" class="empty">ما في موظفين</td></tr>`}
      </tbody></table></div>`;
    wire();
    v.querySelector('#yr').onchange = (e) => { location.hash = `#/leaves?t=balances&y=${e.target.value}`; };
    return;
  }

  const st = qp().get('st') || 'pending';
  let q = sb.from('leave_requests').select('*').eq('company_id', S.company.id).order('from_date', { ascending: false }).limit(500);
  if (st !== 'all') q = q.eq('status', st);
  const { data: rows, error } = await q; if (error) throw error;
  v.innerHTML = `${head}<div class="tabs" style="margin-bottom:10px">${[['pending', 'بالانتظار'], ['approved', 'معتمدة'], ['rejected', 'مرفوضة'], ['cancelled', 'ملغاة'], ['all', 'الكل']]
      .map(([k, l]) => `<a class="tab ${st === k ? 'active' : ''}" href="#/leaves?t=requests&st=${k}">${l}</a>`).join('')}</div>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرقم</th><th>الموظف</th><th>النوع</th><th>من</th><th>إلى</th><th>الأيام</th><th>السبب</th><th>الحالة</th><th></th></tr></thead><tbody>
      ${(rows || []).map(r => `<tr><td>${r.req_no}</td><td>${esc(eById[r.employee_id]?.name || '')}</td><td>${esc(tById[r.type_id]?.name || '')}${tById[r.type_id] && !tById[r.type_id].paid ? ' <span class="badge warn">بدون راتب</span>' : ''}</td>
        <td>${fmtDate(r.from_date)}</td><td>${fmtDate(r.to_date)}</td><td>${r.half_day ? 'نص يوم' : fmtDays(r.days)}</td><td>${esc(r.reason || '')}${r.decision_note ? `<div class="muted" style="font-size:11px">${esc(r.decision_note)}</div>` : ''}</td><td>${badge(r.status)}</td>
        <td class="actions">${r.status === 'pending' && can('payroll', 'post') ? `<button class="btn sm primary" data-ok="${r.id}">اعتماد</button> <button class="btn sm" data-no="${r.id}">رفض</button>` : ''}
          ${(r.status === 'pending' || r.status === 'approved') && can('payroll', 'post') ? `<button class="btn sm" data-cx="${r.id}">إلغاء</button>` : ''}</td></tr>`).join('')
        || '<tr><td colspan="9" class="empty">ما في طلبات</td></tr>'}</tbody></table></div>`;
  wire();
  const act = async (fn, args, msg) => { const { error } = await sb.rpc(fn, args); if (error) return toast(arError(error), 'err'); toast(msg, 'ok'); ctx.rerender(); };
  v.querySelectorAll('[data-ok]').forEach(b => b.onclick = () => act('leave_decide', { p_id: b.dataset.ok, p_approve: true, p_note: null }, 'انعتمدت'));
  v.querySelectorAll('[data-no]').forEach(b => b.onclick = () => { const n = prompt('سبب الرفض (اختياري):', ''); if (n === null) return; act('leave_decide', { p_id: b.dataset.no, p_approve: false, p_note: n }, 'انرفضت'); });
  v.querySelectorAll('[data-cx]').forEach(b => b.onclick = async () => { if (await confirmBox('إلغاء الإجازة؟')) act('leave_cancel', { p_id: b.dataset.cx }, 'انلغت'); });
}

export const LEAVE_ROUTES = { leaves: viewLeaves };
