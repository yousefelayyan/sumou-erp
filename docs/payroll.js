// =====================================================================
//  السمو ERP — الموظفين والرواتب والضمان + الأصول الثابتة والاستهلاك
// =====================================================================
import { loadNumbering, masterCode } from './numbering.js';
import { S, sb, esc, fmtDate, fmtNum, num, today, toast, arError, modal, confirmBox, formData, can, log } from './core.js';
import { loadAccounts, leafAccounts, accLabel, downloadCSV } from './finance.js';
import { printDoc, amountToWords } from './print.js';
import { openAttachments } from './attach.js';
import { loadDepartments, deptName } from './departments.js';
import { custodyHistory } from './assets.js';

const noCo = (v) => void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
const q = (k) => new URLSearchParams(location.hash.split('?')[1] || '').get(k);
const loadCC = async () => (await sb.from('cost_centers').select('*').eq('company_id', S.company.id).eq('is_active', true).order('code')).data || [];
const ccSelect = (ccs, val, ro = '') => ccs.length ? `<div class="field"><label>مركز الكلفة</label><select name="cost_center_id" ${ro}><option value="">—</option>${ccs.map(c => `<option value="${c.id}" ${c.id === val ? 'selected' : ''}>${esc(c.name)}</option>`).join('')}</select></div>` : '';
const nextCode = (rows) => String(Math.max(0, ...rows.map(r => parseInt(r.code, 10) || 0)) + 1);

// ---------------------------------------------------------------------
//  الموظفين
// ---------------------------------------------------------------------
async function viewEmployees(v, ctx) {
  if (!S.company) return noCo(v);
  const [{ data, error }, ccs, , accs, usersR] = await Promise.all([sb.from('employees').select('*').eq('company_id', S.company.id).order('code'), loadCC(), loadNumbering(true), loadAccounts(),
    sb.rpc('company_users', { p_company: S.company.id }), ]);
  const users = usersR.data || [];
  const { data: wlocs = [] } = await sb.from('work_locations').select('id,name').eq('company_id', S.company.id).eq('is_active', true).order('name');
  const { data: shifts = [] } = await sb.from('work_shifts').select('id,code,name,start_time,end_time').eq('company_id', S.company.id).eq('is_active', true).order('code');
  const leaves = leafAccounts(accs);
  // الحساب المقترح للموظف الجديد: أول حساب نوعه «موظف» (ذمم الموظفين)
  const defEmpAcc = leaves.find(a => a.account_type === 'employee')?.id || '';
  if (error) throw error;
  const act = data.filter(e => e.is_active);
  v.innerHTML = `<div class="page-head"><h2>👷 الموظفين</h2><span class="badge brand">${act.length} فعّال</span><div class="spacer"></div>
      <a class="btn sm" href="#/payroll">💵 مسيّرات الرواتب</a> <button class="btn sm" id="csv">⬇️ Excel</button> ${can('payroll', 'edit') ? '<button class="btn primary" id="add">➕ موظف</button>' : ''}</div>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرقم</th><th>الاسم</th><th>الوظيفة</th><th>الأساسي</th><th>العلاوات</th><th>الضمان</th><th>ضريبة شهرية</th><th>الحالة</th><th></th></tr></thead><tbody>
    ${data.map(e => `<tr><td>${esc(e.code)}</td><td><b>${esc(e.name)}</b><div class="muted" style="font-size:12px">${esc(e.department || '')}</div></td><td>${esc(e.job_title || '')}</td>
      <td class="n">${fmtNum(e.basic_salary)}</td><td class="n">${num(e.allowances) ? fmtNum(e.allowances) : ''}</td><td>${e.ss_subject ? '✓' : '—'}</td><td class="n">${num(e.income_tax) ? fmtNum(e.income_tax) : ''}</td>
      <td>${e.is_active ? '<span class="badge ok">على رأس عمله</span>' : '<span class="badge bad">منتهي</span>'}</td>
      <td class="actions"><button class="btn sm" data-ed="${e.id}">${can('payroll', 'edit') ? 'تعديل' : 'عرض'}</button></td></tr>`).join('') || '<tr><td colspan="9" class="empty">ما في موظفين</td></tr>'}</tbody></table></div>`;
  v.querySelector('#csv').onclick = () => downloadCSV('الموظفين.csv', [['الرقم', 'الاسم', 'الرقم الوطني', 'رقم الضمان', 'الوظيفة', 'القسم', 'تاريخ التعيين', 'الأساسي', 'العلاوات', 'مشمول بالضمان', 'ضريبة شهرية', 'البنك', 'IBAN', 'موبايل']]
    .concat(data.map(e => [e.code, e.name, e.national_id, e.ss_no, e.job_title, e.department, e.hire_date, e.basic_salary, e.allowances, e.ss_subject ? 'نعم' : 'لا', e.income_tax, e.bank_name, e.iban, e.mobile])));
  const open = (e) => {
    const isNew = !e, ro = can('payroll', 'edit') ? '' : 'disabled';
    e = e || { code: masterCode('m_employee', data.map(x => x.code)) ?? nextCode(data), name: '', ss_subject: true, is_active: true, basic_salary: 0, allowances: 0, income_tax: 0, hire_date: today(), account_id: defEmpAcc };
    const m = modal({ title: isNew ? 'موظف جديد' : `الموظف: ${e.name}`, body: `<form id="f"><div class="grid cols-3">
      <div class="field"><label>الرقم</label><input name="code" value="${esc(e.code)}" ${ro}></div><div class="field" style="grid-column:span 2"><label>الاسم الكامل *</label><input name="name" value="${esc(e.name)}" ${ro}></div>
      <div class="field"><label>الرقم الوطني</label><input name="national_id" value="${esc(e.national_id)}" dir="ltr" ${ro}></div><div class="field"><label>رقم الضمان</label><input name="ss_no" value="${esc(e.ss_no)}" dir="ltr" ${ro}></div>
      <div class="field"><label>الموبايل</label><input name="mobile" value="${esc(e.mobile)}" dir="ltr" ${ro}></div>
      <div class="field"><label>الوظيفة</label><input name="job_title" value="${esc(e.job_title)}" ${ro}></div><div class="field"><label>القسم</label><input name="department" value="${esc(e.department)}" ${ro}></div>
      ${ccSelect(ccs, e.cost_center_id, ro) || '<div></div>'}
      <div class="field"><label>تاريخ التعيين</label><input type="date" name="hire_date" value="${esc(e.hire_date)}" ${ro}></div><div class="field"><label>تاريخ انتهاء الخدمة</label><input type="date" name="end_date" value="${esc(e.end_date)}" ${ro}></div><div></div>
      <div class="field"><label>الراتب الأساسي *</label><input name="basic_salary" value="${num(e.basic_salary)}" inputmode="decimal" dir="ltr" ${ro}></div>
      <div class="field"><label>علاوات ثابتة شهرية</label><input name="allowances" value="${num(e.allowances)}" inputmode="decimal" dir="ltr" ${ro}></div>
      <div class="field"><label>ضريبة دخل شهرية تقتطع</label><input name="income_tax" value="${num(e.income_tax)}" inputmode="decimal" dir="ltr" ${ro}></div>
      <div class="field" style="justify-content:flex-end"><label class="check"><input type="checkbox" name="ss_subject" ${e.ss_subject ? 'checked' : ''} ${ro}> مشمول بالضمان</label></div>
      <div class="field"><label>الأجر الخاضع للضمان (اختياري)</label><input name="ss_wage" value="${e.ss_wage ?? ''}" placeholder="فاضي = الأساسي + العلاوات" inputmode="decimal" dir="ltr" ${ro}></div><div></div>
      <div class="field"><label>البنك</label><input name="bank_name" value="${esc(e.bank_name)}" ${ro}></div><div class="field" style="grid-column:span 2"><label>IBAN</label><input name="iban" value="${esc(e.iban)}" dir="ltr" ${ro}></div>
      <div class="field" style="grid-column:span 3"><label>حساب الموظف بدليل الحسابات (ذمم الموظفين، سلف…)</label><select name="account_id" ${ro}><option value="">— بدون —</option>${leaves.sort((a, b) => (b.account_type === 'employee') - (a.account_type === 'employee')).map(a => `<option value="${a.id}" ${a.id === e.account_id ? 'selected' : ''}>${esc(accLabel(a))}${a.account_type === 'employee' ? ' ★' : ''}</option>`).join('')}</select></div>
      <div class="field" style="grid-column:span 3"><label>ملاحظات</label><input name="notes" value="${esc(e.notes)}" ${ro}></div>
      <div class="field" style="grid-column:span 3"><label>مستخدم البرنامج (لـ«راتبي» وطلب القروض والسلف)</label><select name="user_id" ${ro ? 'disabled' : ''}><option value="">—</option>${users.map(u => `<option value="${u.id}" ${u.id === e.user_id ? 'selected' : ''}>${esc(u.full_name || u.username || '')}${u.username ? ' (' + esc(u.username) + ')' : ''}</option>`).join('')}${e.user_id && !users.some(u => u.id === e.user_id) ? `<option value="${e.user_id}" selected>(مستخدم مربوط)</option>` : ''}</select></div>
      <div class="field" style="grid-column:span 3"><label>المناوبة / الدوام</label><select name="shift_id" ${ro ? 'disabled' : ''}><option value="">— دوام الشركة العام —</option>${(shifts || []).map(w => `<option value="${w.id}" ${w.id === e.shift_id ? 'selected' : ''}>${esc(w.name)} (${String(w.start_time).slice(0, 5)} – ${String(w.end_time).slice(0, 5)})</option>`).join('')}</select></div>
      <div class="field" style="grid-column:span 2"><label>موقع العمل (للحضور والانصراف)</label><select name="work_location_id" ${ro ? 'disabled' : ''}><option value="">— أي موقع فعّال —</option>${(wlocs || []).map(w => `<option value="${w.id}" ${w.id === e.work_location_id ? 'selected' : ''}>${esc(w.name)}</option>`).join('')}</select></div>
      <div class="field"><label>رقم البصمة (بالجهاز)</label><input name="device_code" value="${esc(e.device_code || '')}" dir="ltr" maxlength="30" placeholder="فاضي = رمز الموظف" ${ro}></div></div>
      <label class="check"><input type="checkbox" name="is_active" ${e.is_active ? 'checked' : ''} ${ro}> على رأس عمله</label></form>`,
      foot: `${!ro ? '<button class="btn primary" data-save>💾 حفظ</button>' : ''}${!isNew ? '<button class="btn" data-att>📎 مرفقات</button>' : ''}<button class="btn" data-close>إغلاق</button>` });
    m.el.querySelector('.modal').style.maxWidth = '820px';
    m.el.querySelector('[data-att]')?.addEventListener('click', () => openAttachments('employee', e.id, e.name));
    m.el.querySelector('[data-save]')?.addEventListener('click', async () => {
      const d = formData(m.el.querySelector('#f')); if (!d.name) return toast('الاسم مطلوب', 'err');
      ['basic_salary', 'allowances', 'income_tax'].forEach(k => d[k] = num(d[k])); d.ss_wage = d.ss_wage == null ? null : num(d.ss_wage);
      if (!ccs.length) delete d.cost_center_id;
      d.account_id = d.account_id || null; d.user_id = d.user_id || null; d.work_location_id = d.work_location_id || null; d.shift_id = d.shift_id || null; d.device_code = (d.device_code || '').trim() || null;
      if (!isNew && (d.user_id || null) === (e.user_id || null)) delete d.user_id;
      const res = isNew ? await sb.from('employees').insert({ ...d, company_id: S.company.id }) : await sb.from('employees').update(d).eq('id', e.id);
      if (res.error) return toast(arError(res.error), 'err'); toast('تم الحفظ', 'ok'); m.close(); ctx.rerender();
    });
  };
  v.querySelector('#add')?.addEventListener('click', () => open(null));
  v.querySelector('tbody').onclick = (ev) => { const b = ev.target.closest('[data-ed]'); if (b) open(data.find(x => x.id === b.dataset.ed)); };
}

// ---------------------------------------------------------------------
//  مسيّرات الرواتب
// ---------------------------------------------------------------------
const PR_ST = { draft: ['مسودة', 'warn'], posted: ['مرحّل', 'ok'], cancelled: ['ملغى', 'bad'] };
async function viewPayroll(v, ctx) {
  if (!S.company) return noCo(v);
  if (q('id')) return payrollRun(v, ctx, q('id'));
  const { data, error } = await sb.from('payroll_runs').select('*').eq('company_id', S.company.id).order('period', { ascending: false });
  if (error) throw error;
  v.innerHTML = `<div class="page-head"><h2>💵 مسيّرات الرواتب</h2><div class="spacer"></div><a class="btn sm" href="#/employees">👷 الموظفين</a> ${can('payroll', 'edit') ? '<button class="btn primary" id="add">➕ مسيّر شهر جديد</button>' : ''}</div>
    <p class="muted">كل شهر: اعمل مسيّر، البرنامج بيعبّيه من بيانات الموظفين ويحسب الضمان (${'٧٫٥٪ على الموظف و١٤٫٢٥٪ على المنشأة — بتتغيّر من «حسابات الربط»'})، عدّل الإضافي والخصومات، وبعدين رحّل. القيد بينعمل لحاله.</p>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الشهر</th><th>تاريخ القيد</th><th>الحالة</th><th></th></tr></thead><tbody>
    ${data.map(r => `<tr class="click" data-open="${r.id}"><td><b>${esc(r.period)}</b></td><td>${fmtDate(r.run_date)}</td><td><span class="badge ${PR_ST[r.status][1]}">${PR_ST[r.status][0]}</span></td><td><span class="btn sm">فتح</span></td></tr>`).join('')
      || '<tr><td colspan="4" class="empty">ما في مسيّرات</td></tr>'}</tbody></table></div>`;
  v.querySelector('tbody').onclick = (e) => { const r = e.target.closest('[data-open]'); if (r) location.hash = `#/payroll?id=${r.dataset.open}`; };
  v.querySelector('#add')?.addEventListener('click', () => {
    const d = new Date(), per = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
    const end = new Date(d.getFullYear(), d.getMonth() + 1, 0), iso = `${end.getFullYear()}-${String(end.getMonth() + 1).padStart(2, '0')}-${String(end.getDate()).padStart(2, '0')}`;
    const m = modal({ title: 'مسيّر رواتب جديد', size: 'sm', body: `<form id="f"><div class="field"><label>الشهر</label><input type="month" name="period" value="${per}"></div>
      <div class="field"><label>تاريخ القيد</label><input type="date" name="run_date" value="${iso}"></div></form>`,
      foot: '<button class="btn primary" data-save>إنشاء وتعبئة</button><button class="btn" data-close>إلغاء</button>' });
    m.el.querySelector('[data-save]').onclick = async () => {
      const f = formData(m.el.querySelector('#f')); if (!f.period || !f.run_date) return toast('عبّي الحقول', 'err');
      const { data: r, error: er } = await sb.from('payroll_runs').insert({ company_id: S.company.id, period: f.period, run_date: f.run_date }).select().single();
      if (er) return toast(arError(er), 'err');
      const fl = await sb.rpc('payroll_fill', { p_run: r.id }); if (fl.error) return toast(arError(fl.error), 'err');
      m.close(); location.hash = `#/payroll?id=${r.id}`;
    };
  });
}

async function payrollRun(v, ctx, id) {
  const [{ data: r, error }, ln, emps] = await Promise.all([sb.from('payroll_runs').select('*').eq('id', id).single(),
    sb.from('payroll_lines').select('*').eq('run_id', id), sb.from('employees').select('*').eq('company_id', S.company.id)]);
  if (error) throw error;
  const E = Object.fromEntries((emps.data || []).map(e => [e.id, e]));
  const lines = (ln.data || []).sort((a, b) => (E[a.employee_id]?.code || '').localeCompare(E[b.employee_id]?.code || '', 'en', { numeric: true }));
  const ed = r.status === 'draft' && can('payroll', 'edit');
  const cols = [['basic', 'الأساسي'], ['allowances', 'العلاوات'], ['overtime', 'إضافي'], ['other_add', 'إضافات أخرى'], ['ss_wage', 'الخاضع للضمان'], ['ss_employee', 'ضمان الموظف'],
    ['income_tax', 'ضريبة الدخل'], ['advances', 'سلف'], ['other_ded', 'خصومات أخرى']];
  const tot = (k) => lines.reduce((s, l) => s + num(l[k]), 0);
  v.innerHTML = `<div class="page-head"><h2>💵 رواتب شهر ${esc(r.period)}</h2><span class="badge ${PR_ST[r.status][1]}">${PR_ST[r.status][0]}</span><div class="spacer"></div>
      <a class="btn sm" href="#/payroll">↩️ رجوع</a>
      ${ed ? '<button class="btn" id="refill">🔄 إعادة تعبئة من الموظفين</button><button class="btn" id="ss">🧮 إعادة حساب الضمان</button>' : ''}
      <button class="btn" id="prn">🖨️ كشف الرواتب</button><button class="btn" id="slips">🧾 قسائم الرواتب</button><button class="btn" id="ssr">🛡️ كشف الضمان</button><button class="btn" id="csv">⬇️ Excel</button>
      ${ed && can('payroll', 'post') ? '<button class="btn primary" id="post">✅ ترحيل</button>' : ''}
      ${r.status === 'posted' && can('payroll', 'post') ? '<button class="btn danger" id="cancel">إلغاء المسيّر</button>' : ''}
      ${r.status === 'draft' && can('payroll', 'edit') ? '<button class="btn danger" id="del">حذف</button>' : ''}</div>
    ${ed ? '<p class="muted" style="font-size:13px">عدّل الأرقام بالجدول مباشرة وبتنحفظ لحالها. «صافي الراتب» بينحسب لحاله.</p>' : ''}
    <div class="card table-wrap"><table class="t" id="pt"><thead><tr><th>الموظف</th>${cols.map(c => `<th>${c[1]}</th>`).join('')}<th>الإجمالي</th><th>ضمان المنشأة</th><th>الصافي</th></tr></thead><tbody>
    ${lines.map(l => `<tr data-l="${l.id}"><td><b>${esc(E[l.employee_id]?.name || '')}</b><div class="muted" style="font-size:12px">${esc(E[l.employee_id]?.code || '')}</div></td>
      ${cols.map(([k]) => `<td>${ed ? `<input class="cell n" data-k="${k}" value="${num(l[k]) || ''}" inputmode="decimal" dir="ltr" style="min-width:80px">` : `<span class="n">${fmtNum(l[k])}</span>`}</td>`).join('')}
      <td class="n" data-g>${fmtNum(l.gross)}</td><td class="n">${fmtNum(l.ss_employer)}</td><td class="n" data-n><b>${fmtNum(l.net)}</b></td></tr>`).join('') || `<tr><td colspan="${cols.length + 4}" class="empty">ما في موظفين بهالمسيّر</td></tr>`}</tbody>
    <tfoot><tr class="tot"><td>المجموع (${lines.length})</td>${cols.map(([k]) => `<td class="n">${fmtNum(tot(k))}</td>`).join('')}<td class="n">${fmtNum(tot('gross'))}</td><td class="n">${fmtNum(tot('ss_employer'))}</td><td class="n">${fmtNum(tot('net'))}</td></tr></tfoot></table></div>`;
  const rerender = () => payrollRun(v, ctx, id);
  v.querySelector('#pt tbody').addEventListener('change', async (e) => {
    const t = e.target; if (!t.dataset.k) return; const lid = t.closest('[data-l]').dataset.l;
    const upd = { [t.dataset.k]: num(t.value) };
    const { error: er } = await sb.from('payroll_lines').update(upd).eq('id', lid); if (er) return toast(arError(er), 'err');
    if (t.dataset.k === 'ss_wage') await sb.rpc('payroll_recalc_ss', { p_run: id });
    rerender();
  });
  v.querySelector('#refill')?.addEventListener('click', async () => { if (!(await confirmBox('إعادة التعبئة بتمسح تعديلاتك على هالمسيّر. متأكد؟'))) return; const x = await sb.rpc('payroll_fill', { p_run: id }); if (x.error) return toast(arError(x.error), 'err'); rerender(); });
  v.querySelector('#ss')?.addEventListener('click', async () => { const x = await sb.rpc('payroll_recalc_ss', { p_run: id }); if (x.error) return toast(arError(x.error), 'err'); rerender(); });
  v.querySelector('#post')?.addEventListener('click', async () => { if (!(await confirmBox(`ترحيل رواتب ${r.period}؟ صافي الرواتب ${fmtNum(tot('net'))}`))) return; const x = await sb.rpc('post_payroll', { p_run: id }); if (x.error) return toast(arError(x.error), 'err'); toast('انرحّلت الرواتب وانعمل القيد', 'ok'); rerender(); });
  v.querySelector('#cancel')?.addEventListener('click', async () => { const d = prompt('تاريخ قيد الإلغاء (YYYY-MM-DD):', today()); if (!d) return; const x = await sb.rpc('cancel_payroll', { p_run: id, p_date: d }); if (x.error) return toast(arError(x.error), 'err'); toast('انلغى المسيّر بقيد عكسي', 'ok'); rerender(); });
  v.querySelector('#del')?.addEventListener('click', async () => { if (!(await confirmBox('حذف المسيّر؟'))) return; const x = await sb.from('payroll_runs').delete().eq('id', id); if (x.error) return toast(arError(x.error), 'err'); location.hash = '#/payroll'; });
  v.querySelector('#csv').onclick = () => downloadCSV(`رواتب ${r.period}.csv`, [['الرقم', 'الموظف', ...cols.map(c => c[1]), 'الإجمالي', 'ضمان المنشأة', 'الصافي', 'البنك', 'IBAN']]
    .concat(lines.map(l => [E[l.employee_id]?.code, E[l.employee_id]?.name, ...cols.map(([k]) => num(l[k]).toFixed(3)), num(l.gross).toFixed(3), num(l.ss_employer).toFixed(3), num(l.net).toFixed(3), E[l.employee_id]?.bank_name, E[l.employee_id]?.iban])));
  // كشف الرواتب: الدخل (بعد الغياب والخصومات الأخرى = مصروف الرواتب بالقيد) ← الاقتطاعات ← الصافي
  v.querySelector('#prn').onclick = () => { const inc = (l) => num(l.gross) - num(l.other_ded), ded = (l) => num(l.ss_employee) + num(l.income_tax) + num(l.advances);
    const td = (x) => `<td class="n">${fmtNum(x)}</td>`;
    printDoc(`كشف رواتب شهر ${r.period}`, `<table class="pt"><thead>
      <tr><th rowspan="2">الرقم</th><th rowspan="2">اسم الموظف</th><th colspan="5">الدخل</th><th rowspan="2">إجمالي الدخل</th><th colspan="3">الاقتطاعات</th><th rowspan="2">إجمالي الاقتطاعات</th><th rowspan="2">صافي الراتب</th><th rowspan="2">التوقيع</th></tr>
      <tr><th>الراتب الأساسي</th><th>البدلات</th><th>العمل الإضافي</th><th>مخصصات أخرى</th><th>(غياب وخصومات)</th><th>الضمان الاجتماعي</th><th>السلف</th><th>ضريبة الدخل</th></tr></thead><tbody>
    ${lines.map(l => `<tr><td>${esc(E[l.employee_id]?.code || '')}</td><td>${esc(E[l.employee_id]?.name || '')}</td>${td(l.basic)}${td(l.allowances)}${td(l.overtime)}${td(l.other_add)}<td class="n">${num(l.other_ded) ? '(' + fmtNum(l.other_ded) + ')' : fmtNum(0)}</td>
      <td class="n"><b>${fmtNum(inc(l))}</b></td>${td(l.ss_employee)}${td(l.advances)}${td(l.income_tax)}${td(ded(l))}<td class="n"><b>${fmtNum(l.net)}</b></td><td style="width:80px"></td></tr>`).join('')}</tbody>
    <tfoot><tr class="tot"><td colspan="2">المجموع الكلي</td>${['basic', 'allowances', 'overtime', 'other_add'].map(k => td(tot(k))).join('')}<td class="n">(${fmtNum(tot('other_ded'))})</td>
      <td class="n"><b>${fmtNum(tot('gross') - tot('other_ded'))}</b></td>${['ss_employee', 'advances', 'income_tax'].map(k => td(tot(k))).join('')}${td(tot('ss_employee') + tot('advances') + tot('income_tax'))}<td class="n"><b>${fmtNum(tot('net'))}</b></td><td></td></tr></tfoot></table>
    <p>صافي الرواتب: ${amountToWords(tot('net'))} — إجمالي الدخل (مصروف الرواتب بالقيد): ${fmtNum(tot('gross') - tot('other_ded'))}، وحصة المنشأة بالضمان: ${fmtNum(tot('ss_employer'))}</p>`, { landscape: true, kind: 'payroll' }); };
  v.querySelector('#ssr').onclick = () => printDoc(`كشف اشتراكات الضمان الاجتماعي — ${r.period}`, `<table class="pt"><thead><tr><th>#</th><th>رقم الضمان</th><th>الرقم الوطني</th><th>الاسم</th><th>الأجر الخاضع</th><th>حصة الموظف</th><th>حصة المنشأة</th><th>المجموع</th></tr></thead><tbody>
    ${lines.filter(l => num(l.ss_wage) > 0).map((l, i) => `<tr><td>${i + 1}</td><td>${esc(E[l.employee_id]?.ss_no || '')}</td><td>${esc(E[l.employee_id]?.national_id || '')}</td><td>${esc(E[l.employee_id]?.name || '')}</td>
      <td class="n">${fmtNum(l.ss_wage)}</td><td class="n">${fmtNum(l.ss_employee)}</td><td class="n">${fmtNum(l.ss_employer)}</td><td class="n">${fmtNum(num(l.ss_employee) + num(l.ss_employer))}</td></tr>`).join('')}</tbody>
    <tfoot><tr class="tot"><td colspan="4">المجموع</td><td class="n">${fmtNum(tot('ss_wage'))}</td><td class="n">${fmtNum(tot('ss_employee'))}</td><td class="n">${fmtNum(tot('ss_employer'))}</td><td class="n">${fmtNum(tot('ss_employee') + tot('ss_employer'))}</td></tr></tfoot></table>`, { kind: 'payroll' });
  v.querySelector('#slips').onclick = () => printDoc(`قسائم رواتب شهر ${r.period}`, lines.map(l => { const e = E[l.employee_id] || {};
    return `<div style="border:1px solid #bbb;border-radius:10px;padding:10px 14px;margin-bottom:14px;page-break-inside:avoid">
      <table class="meta"><tr><td><b>الموظف:</b> ${esc(e.name || '')} (${esc(e.code || '')})</td><td><b>الوظيفة:</b> ${esc(e.job_title || '')}</td><td><b>الشهر:</b> ${esc(r.period)}</td></tr></table>
      <table class="pt" style="margin-top:6px"><tr><th>الاستحقاقات</th><th></th><th>الاقتطاعات</th><th></th></tr>
        <tr><td>الراتب الأساسي</td><td class="n">${fmtNum(l.basic)}</td><td>الضمان الاجتماعي</td><td class="n">${fmtNum(l.ss_employee)}</td></tr>
        <tr><td>العلاوات</td><td class="n">${fmtNum(l.allowances)}</td><td>ضريبة الدخل</td><td class="n">${fmtNum(l.income_tax)}</td></tr>
        <tr><td>العمل الإضافي</td><td class="n">${fmtNum(l.overtime)}</td><td>السلف</td><td class="n">${fmtNum(l.advances)}</td></tr>
        <tr><td>إضافات أخرى</td><td class="n">${fmtNum(l.other_add)}</td><td>خصومات أخرى</td><td class="n">${fmtNum(l.other_ded)}</td></tr>
        <tr class="tot"><td>الإجمالي</td><td class="n">${fmtNum(l.gross)}</td><td>صافي الراتب</td><td class="n">${fmtNum(l.net)}</td></tr></table>
      <div style="display:flex;justify-content:space-between;margin-top:18px;font-size:12px"><span>${amountToWords(l.net)}</span><span>توقيع الموظف: ............</span></div></div>`; }).join(''));
}

// ---------------------------------------------------------------------
//  الأصول الثابتة
// ---------------------------------------------------------------------
async function viewAssets(v, ctx) {
  if (!S.company) return noCo(v);
  const [{ data, error }, accs, ccs, runs, , depts] = await Promise.all([sb.from('fixed_assets').select('*').eq('company_id', S.company.id).order('code'), loadAccounts(), loadCC(),
    sb.from('depreciation_runs').select('*').eq('company_id', S.company.id).order('created_at', { ascending: false }), loadNumbering(true), loadDepartments()]);
  if (error) throw error;
  const subs = depts.filter(d => d.kind === 'sub');
  await sb.rpc('ensure_payroll_settings', { p_company: S.company.id });
  const accum = {}; await Promise.all(data.map(async a => { const r = await sb.rpc('asset_accum', { p_asset: a.id }); accum[a.id] = num(r.data); }));
  const by = Object.fromEntries(accs.map(a => [a.id, a])), leaves = leafAccounts(accs);
  const t = data.reduce((s, a) => ({ c: s.c + num(a.cost), d: s.d + accum[a.id] }), { c: 0, d: 0 });
  const table = `<table class="t pt rep"><thead><tr><th>الرقم</th><th>الأصل</th><th>تاريخ الشراء</th><th>الكلفة</th><th>العمر</th><th>القسط الشهري</th><th>مجمع الاستهلاك</th><th>القيمة الدفترية</th><th>الحالة</th><th class="no-print"></th></tr></thead><tbody>
    ${data.map(a => `<tr><td>${esc(a.code)}</td><td><b>${esc(a.name)}</b><div class="muted" style="font-size:12px">${esc(a.category || '')} ${a.location ? '· ' + esc(a.location) : ''} ${a.department_id ? '· 🏬 ' + esc(deptName(a.department_id)) : ''}</div></td><td>${fmtDate(a.purchase_date)}</td>
      <td class="n">${fmtNum(a.cost)}</td><td>${a.life_months % 12 ? a.life_months + ' شهر' : a.life_months / 12 + ' سنة'}</td><td class="n">${fmtNum((num(a.cost) - num(a.salvage)) / a.life_months)}</td>
      <td class="n">${fmtNum(accum[a.id])}</td><td class="n"><b>${fmtNum(num(a.cost) - accum[a.id])}</b></td>
      <td>${a.status === 'active' ? '<span class="badge ok">مستخدم</span>' : '<span class="badge bad">مستبعد</span>'}</td><td class="no-print"><button class="btn sm" data-ed="${a.id}">تعديل</button></td></tr>`).join('') || '<tr><td colspan="10" class="empty">ما في أصول</td></tr>'}</tbody>
    <tfoot><tr class="tot"><td colspan="3">المجموع</td><td class="n">${fmtNum(t.c)}</td><td colspan="2"></td><td class="n">${fmtNum(t.d)}</td><td class="n">${fmtNum(t.c - t.d)}</td><td colspan="2"></td></tr></tfoot></table>`;
  v.innerHTML = `<div class="page-head"><h2>🏢 الأصول الثابتة</h2><span class="badge brand">${data.length}</span><div class="spacer"></div>
      <a class="btn" href="#/asset-moves">🔁 حركات الأصول</a> <button class="btn" id="prn">🖨️ سجل الأصول</button> ${can('fixed_assets', 'post') ? '<button class="btn primary" id="dep">📉 احتساب الاستهلاك</button>' : ''} ${can('fixed_assets', 'edit') ? '<button class="btn primary" id="add">➕ أصل</button>' : ''}</div>
    <p class="muted">الاستهلاك بطريقة القسط الثابت شهرياً. سجّل شراء الأصل بسند صرف أو قيد على حساب الأصل، وبعدين ضيفه هون عشان ينحسب استهلاكه.</p>
    <div class="card table-wrap">${table}</div>
    <h3>دورات الاستهلاك المرحّلة</h3><div class="card table-wrap"><table class="t" id="runs"><thead><tr><th>لغاية</th><th>المبلغ</th><th>الحالة</th><th></th></tr></thead><tbody>
    ${(runs.data || []).map((r, i) => `<tr><td>${fmtDate(r.period_to)}</td><td class="n">${fmtNum(r.total)}</td><td>${r.status === 'posted' ? '<span class="badge ok">مرحّل</span>' : '<span class="badge bad">ملغى</span>'}</td>
      <td>${r.status === 'posted' && can('fixed_assets', 'post') && (runs.data || []).findIndex(x => x.status === 'posted') === i ? `<button class="btn sm danger" data-cx="${r.id}">إلغاء</button>` : ''}</td></tr>`).join('') || '<tr><td colspan="4" class="empty">ما في</td></tr>'}</tbody></table></div>`;
  v.querySelector('#prn').onclick = () => printDoc('سجل الأصول الثابتة', table.replace(/<th class="no-print"><\/th>/, '').replace(/<td class="no-print">.*?<\/td>/g, ''), { subtitle: `كما في ${fmtDate(today())}`, landscape: true });
  v.querySelector('#dep')?.addEventListener('click', async () => {
    const m = modal({ title: '📉 احتساب الاستهلاك', body: `<div class="field"><label>لغاية آخر شهر</label><input type="month" id="to" value="${today().slice(0, 7)}"></div><div id="pv" class="muted">…</div>`,
      foot: '<button class="btn primary" data-go disabled>✅ ترحيل القيد</button><button class="btn" data-close>إلغاء</button>' });
    const pv = async () => {
      const to = m.el.querySelector('#to').value + '-01';
      const { data: p, error: er } = await sb.rpc('depreciation_preview', { p_company: S.company.id, p_to: to });
      if (er) return void (m.el.querySelector('#pv').innerHTML = esc(arError(er)));
      const nm = Object.fromEntries(data.map(a => [a.id, a.name]));
      m.el.querySelector('#pv').innerHTML = p.length ? `<table class="t"><thead><tr><th>الأصل</th><th>من</th><th>إلى</th><th>شهور</th><th>المبلغ</th></tr></thead><tbody>${p.map(x => `<tr><td>${esc(nm[x.asset_id])}</td><td>${fmtDate(x.from_date)}</td><td>${fmtDate(x.to_date)}</td><td>${x.months}</td><td class="n">${fmtNum(x.amount)}</td></tr>`).join('')}</tbody>
        <tfoot><tr class="tot"><td colspan="4">المجموع</td><td class="n">${fmtNum(p.reduce((s, x) => s + num(x.amount), 0))}</td></tr></tfoot></table>` : '<div class="empty">ما في استهلاك مستحق لهالتاريخ</div>';
      m.el.querySelector('[data-go]').disabled = !p.length;
    };
    m.el.querySelector('#to').onchange = pv; pv();
    m.el.querySelector('[data-go]').onclick = async () => { const x = await sb.rpc('post_depreciation', { p_company: S.company.id, p_to: m.el.querySelector('#to').value + '-01' }); if (x.error) return toast(arError(x.error), 'err'); toast('انرحّل قيد الاستهلاك', 'ok'); m.close(); ctx.rerender(); };
  });
  v.querySelector('#runs').onclick = (async (e) => {
    const c = e.target.closest('[data-cx]'); if (!c) return;
    const d = prompt('تاريخ قيد الإلغاء (YYYY-MM-DD):', today()); if (!d) return;
    const x = await sb.rpc('cancel_depreciation', { p_run: c.dataset.cx, p_date: d }); if (x.error) return toast(arError(x.error), 'err'); toast('انلغت الدورة', 'ok'); ctx.rerender();
  });
  const accSel = (name, val, filter) => `<select name="${name}"><option value="">— الافتراضي —</option>${leaves.filter(filter || (() => true)).map(a => `<option value="${a.id}" ${a.id === val ? 'selected' : ''}>${esc(accLabel(a))}</option>`).join('')}</select>`;
  const open = (a) => {
    const isNew = !a; a = a || { code: masterCode('m_asset', data.map(x => x.code)) ?? nextCode(data), purchase_date: today(), dep_start: today(), cost: '', salvage: 0, life_months: 60, opening_accum: 0, status: 'active' };
    const m = modal({ title: isNew ? 'أصل جديد' : `الأصل: ${a.name}`, body: `<form id="f"><div class="grid cols-3">
      <div class="field"><label>الرقم</label><input name="code" value="${esc(a.code)}"></div><div class="field" style="grid-column:span 2"><label>اسم الأصل *</label><input name="name" value="${esc(a.name)}"></div>
      <div class="field"><label>التصنيف</label><input name="category" value="${esc(a.category)}" placeholder="أجهزة، سيارات، أثاث…"></div><div class="field"><label>المكان</label><input name="location" value="${esc(a.location)}"></div><div class="field"><label>الرقم التسلسلي</label><input name="serial_no" value="${esc(a.serial_no)}" dir="ltr"></div>
      <div class="field"><label>تاريخ الشراء</label><input type="date" name="purchase_date" value="${esc(a.purchase_date)}"></div><div class="field"><label>بداية الاستهلاك</label><input type="date" name="dep_start" value="${esc(a.dep_start)}"></div>
      <div class="field"><label>العمر الإنتاجي (شهور)</label><input name="life_months" value="${a.life_months}" inputmode="numeric"></div>
      <div class="field"><label>الكلفة *</label><input name="cost" value="${a.cost}" inputmode="decimal" dir="ltr"></div><div class="field"><label>قيمة الخردة</label><input name="salvage" value="${num(a.salvage)}" inputmode="decimal" dir="ltr"></div>
      <div class="field"><label>مجمع استهلاك سابق (للأصول القديمة)</label><input name="opening_accum" value="${num(a.opening_accum)}" inputmode="decimal" dir="ltr"></div>
      <div class="field"><label>حساب الأصل</label>${accSel('asset_account_id', a.asset_account_id, x => x.category === 'assets')}</div>
      <div class="field"><label>حساب مجمع الاستهلاك</label>${accSel('accum_account_id', a.accum_account_id, x => x.category === 'assets')}</div>
      <div class="field"><label>حساب مصروف الاستهلاك</label>${accSel('expense_account_id', a.expense_account_id, x => x.category === 'expenses')}</div>
      ${ccSelect(ccs, a.cost_center_id)}
      ${subs.length ? `<div class="field"><label>الدائرة</label><select name="department_id"><option value="">—</option>${subs.filter(d => d.is_active || d.id === a.department_id).map(d => `<option value="${d.id}" ${d.id === a.department_id ? 'selected' : ''}>${esc(d.code)} — ${esc(d.name)}</option>`).join('')}</select></div>` : ''}
      <div class="field"><label>الحالة</label><select name="status"><option value="active" ${a.status === 'active' ? 'selected' : ''}>مستخدم</option><option value="disposed" ${a.status === 'disposed' ? 'selected' : ''}>مستبعد/مباع</option></select><small class="muted">الأفضل: استبعاد أو بيع من «حركات الأصول» عشان ينعمل القيد</small></div>
      <div class="field"><label>تاريخ الاستبعاد</label><input type="date" name="disposed_date" value="${esc(a.disposed_date)}"></div>
      <div class="field" style="grid-column:span 3"><label>ملاحظات</label><input name="notes" value="${esc(a.notes)}"></div></div></form>
      <p class="muted" style="font-size:13px">لما يكون الحساب «الافتراضي»: مصروف الاستهلاك ${esc(accs.find(x => x.code === '5213')?.name || '')} ومجمع الاستهلاك ${esc(accs.find(x => x.code === '1209')?.name || '')} (بتتغيّر من حسابات الربط).</p>`,
      foot: `${can('fixed_assets', 'edit') ? '<button class="btn primary" data-save>💾 حفظ</button>' : ''}${!isNew ? '<button class="btn" data-att>📎 مرفقات</button>' : ''}${!isNew && a.status === 'active' && can('fixed_assets', 'add') ? '<button class="btn" data-mv="dispose">🗑️ استبعاد</button><button class="btn" data-mv="sale">💰 بيع</button>' + (subs.length ? '<button class="btn" data-mv="transfer">🔀 نقل</button>' : '') : ''}${!isNew && can('asset_custody', 'view') ? '<button class="btn" data-hist>🧾 سجل العهدة</button>' : ''}${!isNew && can('fixed_assets', 'edit') ? '<button class="btn danger" data-del style="margin-inline-start:auto">حذف</button>' : ''}<button class="btn" data-close>إغلاق</button>` });
    m.el.querySelector('.modal').style.maxWidth = '860px';
    m.el.querySelector('[data-att]')?.addEventListener('click', () => openAttachments('asset', a.id, a.name));
    m.el.querySelector('[data-hist]')?.addEventListener('click', () => custodyHistory(a));
    m.el.querySelectorAll('[data-mv]').forEach(b => b.onclick = () => { m.close(); location.hash = `#/asset-moves?new=${b.dataset.mv}&asset=${a.id}`; });
    m.el.querySelector('[data-del]')?.addEventListener('click', async () => { if (!(await confirmBox('حذف الأصل؟'))) return; const x = await sb.from('fixed_assets').delete().eq('id', a.id); if (x.error) return toast(arError(x.error), 'err'); m.close(); ctx.rerender(); });
    m.el.querySelector('[data-save]')?.addEventListener('click', async () => {
      const d = formData(m.el.querySelector('#f')); if (!d.name || !num(d.cost)) return toast('الاسم والكلفة مطلوبين', 'err');
      d.cost = num(d.cost); d.salvage = num(d.salvage); d.opening_accum = num(d.opening_accum); d.life_months = Math.max(1, parseInt(d.life_months, 10) || 1);
      if (!ccs.length) delete d.cost_center_id;
      if (!subs.length) delete d.department_id; else d.department_id = d.department_id || null;
      const res = isNew ? await sb.from('fixed_assets').insert({ ...d, company_id: S.company.id }) : await sb.from('fixed_assets').update(d).eq('id', a.id);
      if (res.error) return toast(arError(res.error), 'err'); toast('تم الحفظ', 'ok'); m.close(); ctx.rerender();
    });
  };
  v.querySelector('#add')?.addEventListener('click', () => open(null));
  v.querySelector('.card tbody').onclick = (e) => { const b = e.target.closest('[data-ed]'); if (b) open(data.find(x => x.id === b.dataset.ed)); };
}

export const PAYROLL_ROUTES = { 'employees': viewEmployees, 'payroll': viewPayroll, 'assets': viewAssets };
