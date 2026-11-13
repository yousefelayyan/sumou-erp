// =====================================================================
//  السمو ERP — متابعة إقرارات العملاء ومواعيدها (شاشة المكتب لكل الشركات)
// =====================================================================
import { S, sb, esc, fmtDate, fmtNum, num, today, toast, arError, modal, confirmBox, formData, can, isAdmin, log, qm } from './core.js';
import { downloadCSV } from './finance.js';
import { printDoc } from './print.js';

export const OB_TYPES = { sales_tax: 'ضريبة المبيعات', income_tax: 'ضريبة الدخل', withholding: 'الاقتطاعات', social_security: 'الضمان الاجتماعي',
  registration: 'تجديد سجل/رخصة', license: 'رخصة مهن', audit: 'تدقيق/ميزانية', other: 'أخرى' };
const daysTo = (d) => Math.round((new Date(d) - new Date(today())) / 86400000);
function stateOf(o) {
  if (o.status === 'done') return ['منجز', 'ok'];
  if (o.status === 'not_required') return ['غير مطلوب', 'brand'];
  const d = daysTo(o.due_date);
  if (d < 0) return [`متأخر ${-d} يوم`, 'bad'];
  if (d === 0) return ['اليوم!', 'bad'];
  if (d <= 7) return [`باقي ${d} يوم`, 'warn'];
  return [`باقي ${d} يوم`, ''];
}

// ملخص للوحة التحكم
export async function obligationsSummary() {
  const { data } = await sb.from('obligations').select('id,due_date,status').eq('status', 'pending').lte('due_date', new Date(Date.now() + 14 * 86400000).toISOString().slice(0, 10)).limit(1000);
  const late = (data || []).filter(o => daysTo(o.due_date) < 0).length;
  return { late, soon: (data || []).length - late };
}

async function viewObligations(v, ctx) {
  const companies = S.companies.filter(c => c.is_active && can('obligations', 'view', c.id));
  if (!companies.length) return void (v.innerHTML = `<div class="notice info">ما عندك صلاحية على متابعة الإقرارات بأي شركة.</div>`);
  const ids = companies.map(c => c.id);
  const { data, error } = await sb.from('obligations').select('*').in('company_id', ids).order('due_date').limit(5000);
  if (error) throw error;
  const cName = Object.fromEntries(companies.map(c => [c.id, c.name]));
  const y = new Date().getFullYear();
  const late = data.filter(o => o.status === 'pending' && daysTo(o.due_date) < 0).length;
  const week = data.filter(o => o.status === 'pending' && daysTo(o.due_date) >= 0 && daysTo(o.due_date) <= 7).length;
  const month = data.filter(o => o.status === 'pending' && daysTo(o.due_date) >= 0 && daysTo(o.due_date) <= 30).length;
  v.innerHTML = `<div class="page-head"><h2>🔔 متابعة إقرارات العملاء</h2><div class="spacer"></div>
      ${companies.some(c => can('obligations', 'add', c.id)) ? `<button class="btn" id="gen">⚙️ توليد مواعيد سنة</button><button class="btn primary" id="add">➕ التزام جديد</button>` : ''}</div>
    <div class="grid cols-4" style="margin-bottom:14px">
      <div class="card stat"><span class="k">متأخرة</span><span class="v" style="color:var(--bad)">${late}</span></div>
      <div class="card stat"><span class="k">خلال 7 أيام</span><span class="v" style="color:var(--warn)">${week}</span></div>
      <div class="card stat"><span class="k">خلال 30 يوم</span><span class="v">${month}</span></div>
      <div class="card stat"><span class="k">عدد الشركات</span><span class="v">${companies.length}</span></div></div>
    <div class="card no-print filters">
      <div class="field"><label>الشركة</label><select id="f-c"><option value="">كل الشركات</option>${companies.map(c => `<option value="${c.id}">${esc(c.name)}</option>`).join('')}</select></div>
      <div class="field"><label>النوع</label><select id="f-t"><option value="">الكل</option>${Object.entries(OB_TYPES).map(([k, l]) => `<option value="${k}">${l}</option>`).join('')}</select></div>
      <div class="field"><label>الحالة</label><select id="f-s"><option value="open">المفتوحة (متأخرة + قادمة)</option><option value="late">المتأخرة بس</option><option value="30">خلال 30 يوم</option><option value="done">المنجزة</option><option value="">الكل</option></select></div>
      <div class="field"><label>بحث</label><input id="f-q" placeholder="عنوان، فترة، مرجع…"></div>
      <div class="field" style="justify-content:flex-end;flex-direction:row;gap:6px"><button class="btn" id="prn">🖨️ طباعة</button><button class="btn" id="csv">⬇️ Excel</button></div></div>
    <div class="card table-wrap" style="margin-top:12px"><table class="t"><thead><tr><th>الموعد</th><th>الشركة</th><th>الالتزام</th><th>الفترة</th><th>الحالة</th><th>المبلغ</th><th>المرجع</th><th></th></tr></thead><tbody id="rows"></tbody></table></div>
    <p class="muted" style="font-size:13px">المواعيد المولّدة تلقائياً افتراضية: ضريبة الدخل 30 نيسان، ضريبة المبيعات والاقتطاعات خلال 30 يوم من نهاية الفترة، الضمان الاجتماعي لغاية 15 من الشهر التالي. عدّل أي موعد حسب الحالة.</p>`;
  let shown = [];
  const draw = () => {
    const fc = v.querySelector('#f-c').value, ft = v.querySelector('#f-t').value, fs = v.querySelector('#f-s').value, q = v.querySelector('#f-q').value.trim().toLowerCase();
    shown = data.filter(o => (!fc || o.company_id === fc) && (!ft || o.ob_type === ft)
      && (fs === '' || (fs === 'open' && o.status === 'pending' && daysTo(o.due_date) <= 45) || (fs === 'late' && o.status === 'pending' && daysTo(o.due_date) < 0)
          || (fs === '30' && o.status === 'pending' && daysTo(o.due_date) >= 0 && daysTo(o.due_date) <= 30) || (fs === 'done' && o.status !== 'pending'))
      && (!q || qm([o.title, o.period_label, o.reference, o.notes, cName[o.company_id]], q)));
    v.querySelector('#rows').innerHTML = shown.map(o => { const [l, c] = stateOf(o);
      return `<tr><td><b>${fmtDate(o.due_date)}</b></td><td>${esc(cName[o.company_id] || '')}</td><td>${esc(o.title)} <span class="muted" style="font-size:12px">(${OB_TYPES[o.ob_type]})</span></td>
        <td>${esc(o.period_label || '')}</td><td><span class="badge ${c}">${l}</span></td><td dir="ltr" style="text-align:left">${o.amount ? fmtNum(o.amount) : ''}</td><td>${esc(o.reference || '')}</td>
        <td class="actions">${o.status === 'pending' && can('obligations', 'edit', o.company_id) ? `<button class="btn sm primary" data-done="${o.id}">✓ منجز</button>` : ''}
          ${can('obligations', 'edit', o.company_id) ? `<button class="btn sm" data-edit="${o.id}">تعديل</button>` : ''}</td></tr>`; }).join('')
      || '<tr><td colspan="8" class="empty">ما في التزامات بهالفلتر 🎉</td></tr>';
  };
  draw(); ['#f-c', '#f-t', '#f-s', '#f-q'].forEach(s => v.querySelector(s).addEventListener('input', draw));
  const form = (o) => {
    const isNew = !o; o = o || { company_id: S.company?.id || companies[0].id, ob_type: 'other', title: '', due_date: today(), status: 'pending' };
    const m = modal({ title: isNew ? 'التزام جديد' : 'تعديل: ' + o.title, body: `<form id="o-form"><div class="grid cols-2">
      <div class="field"><label>الشركة</label><select name="company_id" ${isNew ? '' : 'disabled'}>${companies.map(c => `<option value="${c.id}" ${c.id === o.company_id ? 'selected' : ''}>${esc(c.name)}</option>`).join('')}</select></div>
      <div class="field"><label>النوع</label><select name="ob_type">${Object.entries(OB_TYPES).map(([k, l]) => `<option value="${k}" ${o.ob_type === k ? 'selected' : ''}>${l}</option>`).join('')}</select></div>
      <div class="field"><label>العنوان *</label><input name="title" value="${esc(o.title)}"></div>
      <div class="field"><label>الفترة</label><input name="period_label" value="${esc(o.period_label)}" placeholder="مثلاً: آذار - نيسان 2026"></div>
      <div class="field"><label>الموعد النهائي *</label><input type="date" name="due_date" value="${esc(o.due_date)}"></div>
      <div class="field"><label>الحالة</label><select name="status"><option value="pending" ${o.status === 'pending' ? 'selected' : ''}>بانتظار الإنجاز</option><option value="done" ${o.status === 'done' ? 'selected' : ''}>منجز</option><option value="not_required" ${o.status === 'not_required' ? 'selected' : ''}>غير مطلوب</option></select></div>
      <div class="field"><label>تاريخ الإنجاز</label><input type="date" name="done_date" value="${esc(o.done_date)}"></div>
      <div class="field"><label>المبلغ</label><input name="amount" value="${o.amount ?? ''}" inputmode="decimal" dir="ltr"></div>
      <div class="field"><label>رقم الإقرار / الإيصال</label><input name="reference" value="${esc(o.reference)}"></div></div>
      <div class="field"><label>ملاحظات</label><textarea name="notes" style="min-height:60px">${esc(o.notes)}</textarea></div></form>`,
      foot: `<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>${!isNew && can('obligations', 'delete', o.company_id) ? '<button class="btn danger" data-del style="margin-inline-start:auto">حذف</button>' : ''}` });
    m.el.querySelector('[data-save]').onclick = async () => {
      const d = formData(m.el.querySelector('#o-form'));
      if (!d.title || !d.due_date) return toast('العنوان والموعد مطلوبين', 'err');
      d.amount = d.amount ? num(d.amount) : null; if (d.status === 'done' && !d.done_date) d.done_date = today();
      if (!isNew) delete d.company_id;
      const res = isNew ? await sb.from('obligations').insert(d) : await sb.from('obligations').update(d).eq('id', o.id);
      if (res.error) return toast(arError(res.error), 'err');
      toast('تم الحفظ', 'ok'); m.close(); ctx.rerender();
    };
    m.el.querySelector('[data-del]')?.addEventListener('click', async () => {
      if (!(await confirmBox('حذف هالالتزام؟'))) return;
      const { error } = await sb.from('obligations').delete().eq('id', o.id); if (error) return toast(arError(error), 'err'); toast('تم الحذف', 'ok'); m.close(); ctx.rerender();
    });
  };
  v.querySelector('#add')?.addEventListener('click', () => form(null));
  v.querySelector('#rows').onclick = async (e) => {
    const dn = e.target.closest('[data-done]'), ed = e.target.closest('[data-edit]');
    if (ed) form(data.find(o => o.id === ed.dataset.edit));
    if (dn) {
      const o = data.find(x => x.id === dn.dataset.done);
      const ref = prompt(`تسجيل «${o.title} - ${o.period_label || ''}» كمنجز.\nرقم الإقرار أو الإيصال (اختياري):`, o.reference || '');
      if (ref === null) return;
      const { error } = await sb.from('obligations').update({ status: 'done', done_date: today(), reference: ref || o.reference }).eq('id', o.id);
      if (error) return toast(arError(error), 'err'); toast('تم ✓', 'ok'); ctx.rerender();
    }
  };
  v.querySelector('#gen')?.addEventListener('click', () => {
    const m = modal({ title: 'توليد مواعيد سنة كاملة', size: 'sm', body: `<form id="g-form">
      <div class="field"><label>الشركات</label><select name="company" ><option value="__all">كل الشركات المسموحة</option>${companies.filter(c => can('obligations', 'add', c.id)).map(c => `<option value="${c.id}">${esc(c.name)}</option>`).join('')}</select></div>
      <div class="field"><label>السنة</label><input name="year" value="${y}" inputmode="numeric" dir="ltr"></div>
      <label class="check"><input type="checkbox" name="social" checked> الضمان الاجتماعي الشهري</label>
      <label class="check"><input type="checkbox" name="wh" checked> كشف الاقتطاعات الشهري</label>
      <p class="muted" style="font-size:13px">ضريبة المبيعات بتنولّد بس للشركات المعلّمة «خاضعة لضريبة المبيعات» ببياناتها، وحسب دوريتها. اللي موجود من قبل ما بيتكرر.</p></form>`,
      foot: `<button class="btn primary" data-go>توليد</button><button class="btn" data-close>إلغاء</button>` });
    m.el.querySelector('[data-go]').onclick = async () => {
      const d = formData(m.el.querySelector('#g-form')); const yr = parseInt(d.year);
      if (!yr) return toast('السنة غلط', 'err');
      const list = d.company === '__all' ? companies.filter(c => can('obligations', 'add', c.id)).map(c => c.id) : [d.company];
      let total = 0;
      for (const id of list) { const r = await sb.rpc('generate_obligations', { p_company: id, p_year: yr, p_social: d.social, p_withholding: d.wh }); if (r.error) return toast(arError(r.error), 'err'); total += r.data || 0; }
      toast(`انضاف ${total} موعد جديد`, 'ok'); m.close(); ctx.rerender();
    };
  });
  v.querySelector('#csv').onclick = () => downloadCSV('متابعة الإقرارات.csv', [['الموعد', 'الشركة', 'الالتزام', 'النوع', 'الفترة', 'الحالة', 'المبلغ', 'المرجع', 'ملاحظات']]
    .concat(shown.map(o => [o.due_date, cName[o.company_id], o.title, OB_TYPES[o.ob_type], o.period_label, stateOf(o)[0], o.amount ?? '', o.reference ?? '', o.notes ?? ''])));
  v.querySelector('#prn').onclick = () => printDoc('متابعة إقرارات العملاء', `<table class="pt"><thead><tr><th>الموعد</th><th>الشركة</th><th>الالتزام</th><th>الفترة</th><th>الحالة</th><th>المرجع</th></tr></thead><tbody>
    ${shown.map(o => `<tr><td>${fmtDate(o.due_date)}</td><td>${esc(cName[o.company_id])}</td><td>${esc(o.title)}</td><td>${esc(o.period_label || '')}</td><td>${stateOf(o)[0]}</td><td>${esc(o.reference || '')}</td></tr>`).join('')}</tbody></table>`, { subtitle: `بتاريخ ${fmtDate(today())}` });
}

export const OBLIGATION_ROUTES = { 'obligations': viewObligations };
