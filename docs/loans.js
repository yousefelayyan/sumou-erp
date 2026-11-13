// =====================================================================
//  السمو ERP — القروض والسلف (loans) و«راتبي» (me)
// =====================================================================
import { S, sb, esc, fmtDate, fmtNum, num, today, toast, arError, modal, confirmBox, formData, can } from './core.js';
import { printDoc } from './print.js';
import { punchCard } from './attendance.js';
import { myLeavesCard } from './leaves.js';

const ST = { pending: ['بانتظار الموافقة', 'warn'], approved: ['تمت الموافقة', 'ok'], rejected: ['مرفوض', 'bad'], cancelled: ['ملغى', ''], closed: ['مسدّد', 'brand'] };
const KIND = { loan: 'قرض', advance: 'سلفة' };
const nextMonth = () => { const d = new Date(today()); d.setMonth(d.getMonth() + 1); return d.toISOString().slice(0, 7); };
const badge = (st) => `<span class="badge ${ST[st]?.[1] || ''}">${ST[st]?.[0] || st}</span>`;

// تفاصيل القرض: جدول الأقساط والتعليقات
async function loanDetails(l, ctx, { sup = false, mine = false } = {}) {
  const { data: inst } = await sb.from('loan_installments').select('*').eq('loan_id', l.id).order('due_month').order('seq');
  const paid = (inst || []).filter(i => i.status === 'paid').reduce((s, i) => s + num(i.amount), 0);
  const next = (inst || []).find(i => i.status === 'pending');
  const m = modal({ title: `${KIND[l.kind]} رقم ${String(l.loan_no).padStart(6, '0')} — ${esc(l.emp_name || '')}`, body: `
    <div class="grid cols-4" style="margin-bottom:10px">
      <div class="card stat"><span class="k">قيمة ال${KIND[l.kind]}</span><span class="v">${fmtNum(l.amount)}</span></div>
      <div class="card stat"><span class="k">المدفوع</span><span class="v" style="color:var(--ok)">${fmtNum(paid)}</span></div>
      <div class="card stat"><span class="k">المتبقي</span><span class="v" style="color:var(--bad)">${fmtNum(num(l.amount) - paid)}</span></div>
      <div class="card stat"><span class="k">القسط القادم</span><span class="v" style="font-size:16px">${next ? `${fmtNum(next.amount)}<br><small>${esc(next.due_month)}</small>` : '—'}</span></div></div>
    <p>${badge(l.status)} · تاريخ الطلب ${fmtDate(l.request_date)} · ${l.installments} قسط من ${esc(l.first_month)}${l.reason ? ` · ${esc(l.reason)}` : ''}</p>
    ${inst?.length ? `<h4>📅 جدول الأقساط</h4><div class="table-wrap"><table class="t"><thead><tr><th>#</th><th>شهر الاستحقاق</th><th>القسط</th><th>الحالة</th><th></th></tr></thead><tbody>
      ${inst.map(i => `<tr><td>${i.seq}</td><td>${esc(i.due_month)}${i.deferred ? ` <span class="badge">مؤجّل ${i.deferred}</span>` : ''}</td><td class="n">${fmtNum(i.amount)}</td>
        <td>${i.status === 'paid' ? '<span class="badge ok">مدفوع</span>' : '—'}</td>
        <td>${i.defer_request ? `<span class="badge warn" title="${esc(i.defer_request)}">⏸ طلب تأجيل</span> ` : ''}${sup && i.status === 'pending' && l.status === 'approved' ? `<button class="btn sm" data-defer="${i.id}">⏭ تأجيل</button>${i.defer_request ? ` <button class="btn sm" data-dreject="${i.id}">رفض الطلب</button>` : ''}` : ''}
          ${mine && !sup && i.status === 'pending' && l.status === 'approved' && !i.defer_request ? `<button class="btn sm" data-dreq="${i.id}">⏸ اطلب تأجيل</button>` : ''}</td></tr>`).join('')}</tbody></table></div>` : ''}
    <div id="rule-issues"></div>
    <h4>💬 التعليقات</h4>
    <div class="grid cols-2">
      <div class="field"><label>👤 تعليقات الموظف</label><textarea id="c-emp" rows="3" ${mine && ['pending', 'approved'].includes(l.status) ? '' : 'disabled'}>${esc(l.employee_note || '')}</textarea></div>
      <div class="field"><label>🛡️ تعليقات المشرف</label><textarea id="c-sup" rows="3" ${sup && !mine ? '' : 'disabled'}>${esc(l.supervisor_note || '')}</textarea></div></div>`,
    foot: `${(mine || sup) ? '<button class="btn" data-cm>💾 حفظ التعليق</button>' : ''}
      ${sup && l.status === 'pending' ? '<button class="btn primary" data-ok>✔ موافقة</button><button class="btn danger" data-no>✖ رفض</button>' : ''}
      ${(sup && ['pending', 'approved'].includes(l.status) && !paid) || (mine && l.status === 'pending') ? '<button class="btn danger" data-cancel style="margin-inline-start:auto">إلغاء الطلب</button>' : ''}
      <button class="btn" data-print>🖨️ طباعة</button><button class="btn" data-close>إغلاق</button>` });
  const done = () => { m.close(); ctx.rerender(); };
  if (sup && l.status === 'pending') sb.rpc('loan_rule_issues', { p_loan: l.id }).then(({ data }) => { if (data?.length) m.el.querySelector('#rule-issues').innerHTML = `<div class="notice" style="margin-top:8px">⚠️ مخالف لضوابط القروض: ${data.map(esc).join('، ')}.${S.profile?.is_admin ? ' بتقدر تعتمده كمدير.' : ' الاعتماد بس للمدير.'}</div>`; });
  m.el.querySelectorAll('[data-dreq]').forEach(b => b.onclick = () => {
    const q = modal({ title: '⏸ طلب تأجيل قسط', size: 'sm', stack: true, body: '<div class="field"><label>السبب</label><textarea id="dq" rows="3" maxlength="300"></textarea></div>',
      foot: '<button class="btn primary" data-go>إرسال</button><button class="btn" data-close>إلغاء</button>' });
    q.el.querySelector('[data-go]').onclick = async () => {
      const { error } = await sb.rpc('loan_defer_request', { p_inst: b.dataset.dreq, p_note: q.el.querySelector('#dq').value }); if (error) return toast(arError(error), 'err');
      toast('انبعث طلب التأجيل للمشرف', 'ok'); q.close(); m.close(); loanDetails(l, ctx, { sup, mine });
    };
  });
  m.el.querySelectorAll('[data-dreject]').forEach(b => b.onclick = async () => {
    const { error } = await sb.rpc('loan_defer_reject', { p_inst: b.dataset.dreject }); if (error) return toast(arError(error), 'err');
    toast('انرفض طلب التأجيل', 'ok'); m.close(); loanDetails(l, ctx, { sup, mine });
  });
  m.el.querySelector('[data-cm]')?.addEventListener('click', async () => {
    const note = (mine ? m.el.querySelector('#c-emp') : m.el.querySelector('#c-sup')).value;
    const { error } = await sb.rpc('loan_comment', { p_id: l.id, p_note: note }); if (error) return toast(arError(error), 'err'); toast('انحفظ التعليق', 'ok');
  });
  const decide = async (ok) => {
    const { error } = await sb.rpc('loan_decide', { p_id: l.id, p_approve: ok, p_note: m.el.querySelector('#c-sup').value });
    if (error) return toast(arError(error), 'err'); toast(ok ? 'تمت الموافقة وانعمل جدول الأقساط' : 'انرفض الطلب', 'ok'); done();
  };
  m.el.querySelector('[data-ok]')?.addEventListener('click', () => decide(true));
  m.el.querySelector('[data-no]')?.addEventListener('click', () => decide(false));
  m.el.querySelector('[data-cancel]')?.addEventListener('click', async () => {
    const { error } = await sb.rpc('loan_cancel', { p_id: l.id }); if (error) return toast(arError(error), 'err'); toast('انلغى الطلب', 'ok'); done();
  });
  m.el.querySelectorAll('[data-defer]').forEach(b => b.onclick = async () => {
    const { error } = await sb.rpc('loan_defer', { p_inst: b.dataset.defer }); if (error) return toast(arError(error), 'err');
    toast('تأجّل القسط لآخر الجدول', 'ok'); m.close(); loanDetails(l, ctx, { sup, mine });
  });
  m.el.querySelector('[data-print]').onclick = () => printDoc(`${KIND[l.kind]} رقم ${String(l.loan_no).padStart(6, '0')}`, `
    <table class="pt"><tbody><tr><td>الموظف</td><td>${esc(l.emp_name || '')}</td><td>المبلغ</td><td>${fmtNum(l.amount)}</td></tr>
    <tr><td>تاريخ الطلب</td><td>${fmtDate(l.request_date)}</td><td>الحالة</td><td>${ST[l.status]?.[0] || ''}</td></tr></tbody></table>
    <table class="pt"><thead><tr><th>#</th><th>الشهر</th><th>القسط</th><th>الحالة</th></tr></thead><tbody>${(inst || []).map(i => `<tr><td>${i.seq}</td><td>${esc(i.due_month)}</td><td>${fmtNum(i.amount)}</td><td>${i.status === 'paid' ? 'مدفوع' : ''}</td></tr>`).join('')}</tbody></table>`);
}

async function rulesForm() {
  const { data: r = {} } = await sb.rpc('loan_rules_get', { p_company: S.company.id });
  const F = [['max_multiple', 'أعلى قرض = كم ضعف الراتب الشهري', 'مثلاً 3'], ['max_inst_pct', 'أعلى قسط % من الراتب', 'مثلاً 25'], ['advance_max_pct', 'أعلى سلفة % من الراتب', 'مثلاً 50'],
    ['max_open', 'أكثر عدد قروض/سلف مفتوحة للموظف', 'مثلاً 1'], ['min_service_months', 'أقل مدة خدمة (شهور) قبل أول قرض', 'مثلاً 6'], ['max_installments', 'أكثر عدد أقساط', 'مثلاً 24']];
  const m = modal({ title: '⚙️ ضوابط القروض والسلف', size: 'sm', body: `<form id="rf"><p class="muted" style="margin-top:0;font-size:13px">الفاضي = بدون ضابط. الراتب = الأساسي + العلاوات. طلب الموظف لحاله المخالف بينرفض، وطلب المشرف بينحفظ بس اعتماده للمدير بس.</p>
    ${F.map(([k, l, ph]) => `<div class="field"><label>${l}</label><input name="${k}" inputmode="decimal" dir="ltr" value="${r?.[k] ?? ''}" placeholder="${ph}"></div>`).join('')}</form>`,
    foot: '<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>' });
  m.el.querySelector('[data-save]').onclick = async () => {
    const { error } = await sb.rpc('loan_rules_save', { p_company: S.company.id, p: formData(m.el.querySelector('#rf')) });
    if (error) return toast(arError(error), 'err'); toast('انحفظت الضوابط', 'ok'); m.close();
  };
}

function requestForm(ctx, { emps = null } = {}) {
  const m = modal({ title: '➕ طلب قرض / سلفة', size: 'sm', body: `<form id="lf">
    ${emps ? `<div class="field"><label>الموظف *</label><select name="employee_id">${emps.map(e => `<option value="${e.id}">${esc(e.code)} — ${esc(e.name)}</option>`).join('')}</select></div>` : ''}
    <div class="field"><label>النوع</label><select name="kind"><option value="loan">قرض (أقساط)</option><option value="advance">سلفة (من الراتب الجاي)</option></select></div>
    <div class="grid cols-2"><div class="field"><label>المبلغ *</label><input name="amount" inputmode="decimal" dir="ltr"></div>
      <div class="field"><label>عدد الأقساط</label><input name="installments" value="1" inputmode="numeric" dir="ltr"></div></div>
    <div class="field"><label>شهر أول قسط</label><input type="month" name="first_month" value="${nextMonth()}"></div>
    <div class="field"><label>السبب</label><input name="reason" maxlength="300"></div>
    <div class="field"><label>ملاحظة</label><textarea name="note" rows="2"></textarea></div></form>`,
    foot: '<button class="btn primary" data-go>إرسال الطلب</button><button class="btn" data-close>إلغاء</button>' });
  const f = m.el.querySelector('#lf');
  f.kind.onchange = () => { if (f.kind.value === 'advance') f.installments.value = 1; };
  m.el.querySelector('[data-go]').onclick = async (ev) => {
    const d = formData(f); ev.target.disabled = true;
    const { error } = await sb.rpc('loan_request', { p: { company_id: S.company.id, ...d } });
    if (error) { ev.target.disabled = false; return toast(arError(error), 'err'); }
    toast('انبعث الطلب للمشرف', 'ok'); m.close(); ctx.rerender();
  };
}

// شاشة القروض والسلف (الموارد البشرية والمشرف)
async function viewLoans(v, ctx) {
  if (!S.company) return void (v.innerHTML = '<div class="notice info">اختار شركة من فوق أول.</div>');
  if (!can('payroll', 'view')) return void (v.innerHTML = '<div class="notice">ما عندك صلاحية على الرواتب</div>');
  const st = new URLSearchParams(location.hash.split('?')[1] || '').get('st') || 'pending';
  const [lr, er] = await Promise.all([
    sb.from('employee_loans').select('*').eq('company_id', S.company.id).order('loan_no', { ascending: false }).limit(1000),
    sb.from('employees').select('id,code,name,is_active').eq('company_id', S.company.id).order('code')]);
  const emps = er.data || [], eBy = Object.fromEntries(emps.map(e => [e.id, e]));
  const all = (lr.data || []).map(l => ({ ...l, emp_name: eBy[l.employee_id]?.name || '' }));
  const ids = all.filter(l => l.status === 'approved').map(l => l.id);
  const paidBy = {};
  if (ids.length) { const { data } = await sb.from('loan_installments').select('loan_id,amount,status').in('loan_id', ids); (data || []).forEach(i => { if (i.status === 'paid') paidBy[i.loan_id] = (paidBy[i.loan_id] || 0) + num(i.amount); }); }
  const list = st === 'all' ? all : all.filter(l => l.status === st);
  const sup = can('payroll', 'post');
  const { data: myEmp } = await sb.rpc('my_employee', { p_company: S.company.id });
  const cnt = (k) => all.filter(l => l.status === k).length;
  const { data: dreq } = await sb.from('loan_installments').select('loan_id').not('defer_request', 'is', null).in('loan_id', all.map(l => l.id).slice(0, 500));
  const dreqSet = new Set((dreq || []).map(x => x.loan_id));
  v.innerHTML = `<div class="page-head"><h2>💳 القروض والسلف</h2><div class="spacer"></div>${can('payroll', 'edit') ? '<button class="btn" id="rules">⚙️ ضوابط القروض</button>' : ''}${can('payroll', 'add') ? '<button class="btn primary" id="add">➕ طلب جديد</button>' : ''}</div>
    ${dreqSet.size ? `<div class="notice info" style="margin-bottom:8px">⏸ في ${dreqSet.size} طلب تأجيل قسط بانتظار المشرف (معلّمة بالجدول).</div>` : ''}
    <div class="tabs" style="margin-bottom:10px">${[['pending', 'بانتظار الموافقة'], ['approved', 'قيد السداد'], ['closed', 'مسدّدة'], ['rejected', 'مرفوضة'], ['all', 'الكل']]
      .map(([k, lbl]) => `<a class="tab ${st === k ? 'active' : ''}" href="#/loans?st=${k}">${lbl}${k !== 'all' ? ` (${cnt(k)})` : ''}</a>`).join('')}</div>
    <div class="card table-wrap"><table class="t rep"><thead><tr><th>الرقم</th><th>الموظف</th><th>النوع</th><th>التاريخ</th><th>المبلغ</th><th>الأقساط</th><th>المتبقي</th><th>الحالة</th></tr></thead><tbody>
      ${list.map(l => `<tr data-l="${l.id}" style="cursor:pointer"><td>${String(l.loan_no).padStart(6, '0')}</td><td>${esc(l.emp_name)}</td><td>${KIND[l.kind]}</td><td>${fmtDate(l.request_date)}</td>
        <td class="n">${fmtNum(l.amount)}</td><td class="n">${l.installments}</td><td class="n">${l.status === 'approved' ? fmtNum(num(l.amount) - (paidBy[l.id] || 0)) : ''}</td><td>${badge(l.status)}${dreqSet.has(l.id) ? ' <span class="badge warn">⏸ تأجيل</span>' : ''}${l.entry_id ? ' <span class="badge" title="من سند صرف">🧾</span>' : ''}</td></tr>`).join('') || '<tr><td colspan="8" class="empty">ما في طلبات</td></tr>'}</tbody></table></div>
    <p class="muted" style="font-size:12px">الأقساط المستحقة بتنخصم لحالها بمسيّر الرواتب (عمود «خصم السلف»)، وبتصير مدفوعة لما يترحّل. الموافقة والرفض والتأجيل لمين إله «ترحيل» الرواتب.</p>`;
  v.querySelector('#add')?.addEventListener('click', () => requestForm(ctx, { emps: emps.filter(e => e.is_active) }));
  v.querySelector('#rules')?.addEventListener('click', () => rulesForm());
  v.querySelector('tbody').onclick = (e) => { const tr = e.target.closest('[data-l]'); if (tr) { const l = all.find(x => x.id === tr.dataset.l); loanDetails(l, ctx, { sup: sup && (l.employee_id !== myEmp || S.profile?.is_admin) }); } };
}

// «راتبي»: قسيمة الراتب لكل شهر، وقروضي
async function viewMe(v, ctx) {
  if (!S.company) return void (v.innerHTML = '<div class="notice info">اختار شركة من فوق أول.</div>');
  const [emp, pr] = await Promise.all([sb.rpc('my_employee', { p_company: S.company.id }), sb.rpc('my_payroll', { p_company: S.company.id })]);
  if (!emp.data) return void (v.innerHTML = '<div class="page-head"><h2>💼 راتبي</h2></div><div class="notice">حسابك مش مربوط بموظف. خلّي الموارد البشرية تربطك من «الموظفين ← مستخدم البرنامج».</div>');
  const rows = pr.data || [];
  const sel = new URLSearchParams(location.hash.split('?')[1] || '').get('p') || rows[0]?.period;
  const r = rows.find(x => x.period === sel);
  const { data: loans } = await sb.from('employee_loans').select('*').eq('employee_id', emp.data).order('loan_no', { ascending: false });
  const earn = r ? [['الراتب الأساسي', r.basic], ['العلاوات', r.allowances], ['العمل الإضافي', r.overtime], ['إضافات أخرى', r.other_add]].filter(x => num(x[1])) : [];
  const ded = r ? [['الضمان الاجتماعي', r.ss_employee], ['ضريبة الدخل', r.income_tax], ['أقساط القروض والسلف', r.advances], ['خصومات أخرى', r.other_ded]].filter(x => num(x[1])) : [];
  v.innerHTML = `<div style="max-width:720px;margin:0 auto"><div class="page-head"><h2>💼 راتبي</h2></div><div id="punch"></div>
    ${rows.length ? `<div class="tabs" style="overflow:auto;margin-bottom:10px">${rows.slice(0, 12).reverse().map(x => `<a class="tab ${x.period === sel ? 'active' : ''}" href="#/me?p=${x.period}">${esc(x.period)}</a>`).join('')}</div>` : ''}
    ${r ? `<div class="card" style="background:var(--brand);color:#fff;text-align:center;padding:18px;border-radius:16px">
        <div style="opacity:.85">صافي الراتب — ${esc(r.period)}</div><div style="font-size:34px;font-weight:800">${fmtNum(r.net)} د.أ</div></div>
      <div class="card" style="margin-top:10px"><h4 style="color:var(--ok)">📈 المستحقات <span style="float:left">${fmtNum(r.gross)}</span></h4>
        <table class="t"><tbody>${earn.map(([k, x]) => `<tr><td>${k}</td><td class="n">${fmtNum(x)}</td></tr>`).join('')}</tbody></table>
        <h4 style="color:var(--bad);margin-top:12px">📉 الاقتطاعات <span style="float:left">${fmtNum(ded.reduce((s, x) => s + num(x[1]), 0))}</span></h4>
        <table class="t"><tbody>${ded.map(([k, x]) => `<tr><td>${k}</td><td class="n" style="color:var(--bad)">-${fmtNum(x)}</td></tr>`).join('') || '<tr><td class="empty">ما في</td></tr>'}</tbody></table>
        ${r.notes ? `<p class="muted" style="font-size:12px">${esc(r.notes)}</p>` : ''}</div>`
      : '<div class="notice info">لسا ما في رواتب مرحّلة إلك.</div>'}
    <div class="page-head" style="margin-top:16px"><h3>💳 قروضي وسلفي</h3><div class="spacer"></div><button class="btn primary" id="req">➕ طلب جديد</button></div>
    ${(loans || []).map(l => `<div class="card" data-l="${l.id}" style="cursor:pointer;margin-bottom:8px;display:flex;gap:10px;align-items:center">
        <div style="flex:1"><b>${KIND[l.kind]} ${String(l.loan_no).padStart(6, '0')}</b> ${badge(l.status)}<div class="muted" style="font-size:12px">${fmtDate(l.request_date)} · ${l.installments} قسط من ${esc(l.first_month)}</div></div>
        <b>${fmtNum(l.amount)}</b></div>`).join('') || '<div class="empty">ما في طلبات</div>'}<div id="myleaves"></div></div>`;
  punchCard(v.querySelector('#punch'), emp.data);
  myLeavesCard(v.querySelector('#myleaves'), emp.data, ctx);
  v.querySelector('#req').onclick = () => requestForm(ctx);
  v.querySelectorAll('[data-l]').forEach(c => c.onclick = () => { const l = loans.find(x => x.id === c.dataset.l); loanDetails({ ...l, emp_name: r?.emp_name || '' }, ctx, { mine: true, sup: false }); });
}

export const LOAN_ROUTES = { loans: viewLoans, me: viewMe };
