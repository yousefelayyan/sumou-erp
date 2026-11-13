// =====================================================================
//  السمو ERP — الحضور والانصراف (route attendance?t=day|summary|locations|settings)
//  الموظف بيسجّل من «راتبي» بالموقع (attendance_punch)، والمشرف (payroll edit) بيعدّل (attendance_set)
// =====================================================================
import { S, sb, esc, fmtDate, fmtNum, today, toast, arError, modal, formData, can } from './core.js';
import { printDoc } from './print.js';

const hm = (t) => t ? new Date(t).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Amman' }) : '';
const dur = (a, b) => { if (!a || !b) return ''; const m = Math.round((new Date(b) - new Date(a)) / 60000); return `${Math.floor(m / 60)}:${String(m % 60).padStart(2, '0')}`; };
const getPos = () => new Promise((res, rej) => {
  if (!navigator.geolocation) return rej(new Error('الجهاز ما بيدعم تحديد الموقع'));
  navigator.geolocation.getCurrentPosition(p => res(p.coords), () => rej(new Error('لازم تسمح للبرنامج يعرف موقعك')), { enableHighAccuracy: true, timeout: 15000, maximumAge: 0 });
});
const qp = () => new URLSearchParams(location.hash.split('?')[1] || '');

// بطاقة الحضور بشاشة «راتبي»
export async function punchCard(el, empId) {
  const { data: a } = await sb.from('attendance').select('*').eq('employee_id', empId).eq('day', today()).maybeSingle();
  const st = !a?.check_in ? 'in' : !a?.check_out ? 'out' : 'done';
  el.innerHTML = `<div class="card" style="display:flex;gap:12px;align-items:center;flex-wrap:wrap;margin-bottom:10px">
    <div style="flex:1;min-width:180px"><b>🕘 حضور اليوم</b> <span class="muted">${fmtDate(today())}</span>
      <div class="muted" style="font-size:13px">${a?.check_in ? `دخول ${hm(a.check_in)}` : 'لسا ما سجّلت حضور'}${a?.check_out ? ` · خروج ${hm(a.check_out)} · ${dur(a.check_in, a.check_out)} ساعة` : ''}${a?.outside ? ' · <span class="badge warn">برّا الموقع</span>' : ''}</div></div>
    ${st === 'in' ? '<button class="btn primary" data-p="in" style="font-size:16px;padding:10px 22px">✅ تسجيل حضور</button>'
      : st === 'out' ? '<button class="btn danger" data-p="out" style="font-size:16px;padding:10px 22px">🚪 تسجيل انصراف</button>' : '<span class="badge ok">✔ خلص دوام اليوم</span>'}</div>`;
  el.querySelector('[data-p]')?.addEventListener('click', async (e) => {
    const b = e.currentTarget; b.disabled = true; b.textContent = '📍 بنحدد موقعك…';
    try {
      const c = await getPos();
      const { data, error } = await sb.rpc('attendance_punch', { p_company: S.company.id, p_kind: b.dataset.p, p_lat: +c.latitude.toFixed(6), p_lng: +c.longitude.toFixed(6) });
      if (error) throw new Error(arError(error));
      toast(`${b.dataset.p === 'in' ? 'انسجّل حضورك' : 'انسجّل انصرافك'}${data?.location ? ` — ${data.location}` : ''}`, 'ok');
    } catch (err) { toast(err.message, 'err'); }
    punchCard(el, empId);
  });
}

function dayForm(ctx, emps, row = {}) {
  const t = (x) => x ? hm(x) : '';
  const m = modal({ title: row.id ? 'تعديل الحضور' : '➕ إدخال حضور يدوي', body: `<form class="grid cols-2">
    <div class="field"><label>الموظف</label><select name="employee_id" ${row.employee_id ? 'disabled' : ''} required>${emps.map(e => `<option value="${e.id}" ${e.id === row.employee_id ? 'selected' : ''}>${esc(e.code)} — ${esc(e.name)}</option>`).join('')}</select></div>
    <div class="field"><label>اليوم</label><input type="date" name="day" value="${row.day || today()}" max="${today()}" ${row.id ? 'disabled' : ''} required></div>
    <div class="field"><label>وقت الحضور</label><input type="time" name="check_in" value="${t(row.check_in)}"></div>
    <div class="field"><label>وقت الانصراف</label><input type="time" name="check_out" value="${t(row.check_out)}"></div>
    <div class="field" style="grid-column:1/-1"><label>ملاحظات</label><input name="notes" value="${esc(row.notes || '')}" maxlength="300"></div></form>
    <p class="muted" style="font-size:12px">إذا فضّيت الوقتين بينشال سجل اليوم.</p>`,
    foot: '<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>' });
  m.el.querySelector('[data-save]').onclick = async () => {
    const f = formData(m.el.querySelector('form'));
    const { error } = await sb.rpc('attendance_set', { p: { company_id: S.company.id, employee_id: row.employee_id || f.employee_id, day: row.day || f.day, check_in: f.check_in || null, check_out: f.check_out || null, notes: f.notes } });
    if (error) return toast(arError(error), 'err'); toast('انحفظ', 'ok'); m.close(true); ctx.rerender();
  };
}

function locForm(ctx, row = {}) {
  const m = modal({ title: row.id ? 'تعديل موقع عمل' : '➕ موقع عمل جديد', body: `<form class="grid cols-2">
    <div class="field" style="grid-column:1/-1"><label>الاسم</label><input name="name" value="${esc(row.name || '')}" required></div>
    <div class="field"><label>خط العرض</label><input name="lat" type="number" step="0.000001" value="${row.lat ?? ''}" required></div>
    <div class="field"><label>خط الطول</label><input name="lng" type="number" step="0.000001" value="${row.lng ?? ''}" required></div>
    <div class="field"><label>نصف القطر المسموح (متر)</label><input name="radius_m" type="number" min="20" max="5000" value="${row.radius_m ?? 150}"></div>
    <div class="field"><label><input type="checkbox" name="is_active" ${row.is_active !== false ? 'checked' : ''}> فعّال</label></div></form>
    <button class="btn" data-here>📍 خذ موقعي الحالي</button>`,
    foot: '<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>' });
  const f = m.el.querySelector('form');
  m.el.querySelector('[data-here]').onclick = async () => {
    try { const c = await getPos(); f.lat.value = c.latitude.toFixed(6); f.lng.value = c.longitude.toFixed(6); } catch (e) { toast(e.message, 'err'); }
  };
  m.el.querySelector('[data-save]').onclick = async () => {
    if (!f.reportValidity()) return;
    const d = formData(f);
    const rec = { company_id: S.company.id, name: d.name.trim(), lat: +d.lat, lng: +d.lng, radius_m: +d.radius_m || 150, is_active: f.is_active.checked };
    const { error } = row.id ? await sb.from('work_locations').update(rec).eq('id', row.id) : await sb.from('work_locations').insert(rec);
    if (error) return toast(arError(error), 'err'); toast('انحفظ', 'ok'); m.close(true); ctx.rerender();
  };
}

async function viewAttendance(v, ctx) {
  if (!S.company) return void (v.innerHTML = '<div class="notice info">اختار شركة من فوق أول.</div>');
  if (!can('payroll', 'view')) return void (v.innerHTML = '<div class="notice">ما عندك صلاحية على الرواتب</div>');
  const t = qp().get('t') || 'day', sup = can('payroll', 'edit');
  const tabs = [['day', '📋 يومي'], ['summary', '📊 ملخص الفترة'], ['locations', '📍 مواقع العمل'], ['settings', '⚙️ الدوام']];
  const head = `<div class="page-head"><h2>🕘 الحضور والانصراف</h2></div>
    <div class="tabs" style="margin-bottom:10px">${tabs.map(([k, l]) => `<a class="tab ${t === k ? 'active' : ''}" href="#/attendance?t=${k}">${l}</a>`).join('')}</div>`;
  const { data: emps = [] } = await sb.from('employees').select('id,code,name,is_active,work_location_id').eq('company_id', S.company.id).order('code');
  const eBy = Object.fromEntries((emps || []).map(e => [e.id, e]));
  const { data: locs = [] } = await sb.from('work_locations').select('*').eq('company_id', S.company.id).order('name');
  const lBy = Object.fromEntries((locs || []).map(l => [l.id, l]));

  if (t === 'day') {
    const d = qp().get('d') || today();
    const { data: rows = [] } = await sb.from('attendance').select('*').eq('company_id', S.company.id).eq('day', d);
    const aBy = Object.fromEntries((rows || []).map(a => [a.employee_id, a]));
    const act = (emps || []).filter(e => e.is_active || aBy[e.id]);
    const pres = act.filter(e => aBy[e.id]?.check_in).length;
    v.innerHTML = `${head}<div class="card" style="display:flex;gap:10px;align-items:end;flex-wrap:wrap;margin-bottom:10px">
      <div class="field"><label>اليوم</label><input type="date" id="d" value="${d}" max="${today()}"></div>
      <span class="badge ok">حاضر ${pres}</span><span class="badge bad">غايب ${act.length - pres}</span><div class="spacer"></div>
      ${sup ? '<button class="btn primary" id="add">➕ إدخال يدوي</button>' : ''}<button class="btn" id="pr">🖨️ طباعة</button></div>
      <div class="card table-wrap"><table class="t rep"><thead><tr><th>الرمز</th><th>الموظف</th><th>الحضور</th><th>الانصراف</th><th>المدة</th><th>الموقع</th><th>المصدر</th><th>ملاحظات</th></tr></thead><tbody>
      ${act.map(e => { const a = aBy[e.id]; return `<tr data-e="${e.id}" ${sup ? 'style="cursor:pointer"' : ''}><td>${esc(e.code)}</td><td>${esc(e.name)}</td>
        <td>${a?.check_in ? hm(a.check_in) : '<span class="badge bad">غايب</span>'}</td><td>${hm(a?.check_out)}</td><td>${dur(a?.check_in, a?.check_out)}</td>
        <td>${a ? esc(lBy[a.location_id]?.name || '') : ''}${a?.outside ? ' <span class="badge warn">برّا</span>' : ''}${a?.in_dist != null ? ` <small class="muted">${a.in_dist} م</small>` : ''}</td>
        <td>${a ? (a.source === 'supervisor' ? 'المشرف' : 'الموظف') : ''}</td><td>${esc(a?.notes || '')}</td></tr>`; }).join('') || '<tr><td colspan="8" class="empty">ما في موظفين</td></tr>'}</tbody></table></div>`;
    v.querySelector('#d').onchange = (e) => { location.hash = `#/attendance?t=day&d=${e.target.value}`; };
    v.querySelector('#add')?.addEventListener('click', () => dayForm(ctx, act.filter(e => e.is_active), { day: d }));
    if (sup) v.querySelector('tbody').onclick = (e) => { const tr = e.target.closest('[data-e]'); if (tr) dayForm(ctx, act, { ...(aBy[tr.dataset.e] || {}), employee_id: tr.dataset.e, day: d }); };
    v.querySelector('#pr').onclick = () => printDoc(`كشف الحضور — ${fmtDate(d)}`, v.querySelector('table').outerHTML.replace('class="t rep"', 'class="pt"'));
  } else if (t === 'summary') {
    const from = qp().get('from') || today().slice(0, 8) + '01', to = qp().get('to') || today();
    const { data: rows = [], error } = await sb.rpc('attendance_summary', { p_company: S.company.id, p_from: from, p_to: to });
    if (error) toast(arError(error), 'err');
    v.innerHTML = `${head}<div class="card" style="display:flex;gap:10px;align-items:end;flex-wrap:wrap;margin-bottom:10px">
      <div class="field"><label>من</label><input type="date" id="f" value="${from}"></div><div class="field"><label>إلى</label><input type="date" id="to" value="${to}"></div>
      <button class="btn primary" id="go">عرض</button><div class="spacer"></div><button class="btn" id="pr">🖨️ طباعة</button></div>
      <div class="card table-wrap"><table class="t rep"><thead><tr><th>الرمز</th><th>الموظف</th><th>أيام الحضور</th><th>الساعات</th><th>أيام التأخير</th><th>دقائق التأخير</th><th>الغياب</th><th>برّا الموقع</th><th>بدون انصراف</th></tr></thead><tbody>
      ${(rows || []).map(r => `<tr><td>${esc(r.code)}</td><td>${esc(r.name)}</td><td class="n">${r.days}</td><td class="n">${fmtNum(r.hours, 2)}</td><td class="n">${r.late_days}</td><td class="n">${r.late_minutes}</td>
        <td class="n" ${r.absent_days ? 'style="color:var(--bad)"' : ''}>${r.absent_days}</td><td class="n">${r.outside_days}</td><td class="n">${r.open_days}</td></tr>`).join('') || '<tr><td colspan="9" class="empty">ما في بيانات</td></tr>'}</tbody></table></div>
      <p class="muted" style="font-size:12px">أيام العمل = كل الأيام ما عدا الجمعة لحد اليوم. التأخير بعد بداية الدوام + فترة السماح (من تبويب «الدوام»).</p>`;
    v.querySelector('#go').onclick = () => { location.hash = `#/attendance?t=summary&from=${v.querySelector('#f').value}&to=${v.querySelector('#to').value}`; };
    v.querySelector('#pr').onclick = () => printDoc(`ملخص الحضور ${fmtDate(from)} — ${fmtDate(to)}`, v.querySelector('table').outerHTML.replace('class="t rep"', 'class="pt"'));
  } else if (t === 'locations') {
    v.innerHTML = `${head}<div class="page-head"><div class="spacer"></div>${sup ? '<button class="btn primary" id="add">➕ موقع جديد</button>' : ''}</div>
      <div class="card table-wrap"><table class="t"><thead><tr><th>الاسم</th><th>الإحداثيات</th><th>نصف القطر</th><th>الموظفين المربوطين</th><th>الحالة</th></tr></thead><tbody>
      ${(locs || []).map(l => `<tr data-l="${l.id}" ${sup ? 'style="cursor:pointer"' : ''}><td>${esc(l.name)}</td><td><a href="https://maps.google.com/?q=${l.lat},${l.lng}" target="_blank" rel="noopener">${l.lat}, ${l.lng}</a></td>
        <td class="n">${l.radius_m} م</td><td class="n">${(emps || []).filter(e => e.work_location_id === l.id).length}</td><td>${l.is_active ? '<span class="badge ok">فعّال</span>' : '<span class="badge">موقوف</span>'}</td></tr>`).join('') || '<tr><td colspan="5" class="empty">ما في مواقع — الموظف بيسجّل من أي مكان</td></tr>'}</tbody></table></div>
      <p class="muted" style="font-size:12px">الموظف بيسجّل بس وهو جوّا نطاق موقعه (من بطاقة الموظف ← «موقع العمل»)، أو أقرب موقع فعّال إذا ما إله موقع محدد.</p>`;
    v.querySelector('#add')?.addEventListener('click', () => locForm(ctx));
    if (sup) v.querySelector('tbody').onclick = (e) => { const tr = e.target.closest('[data-l]'); if (tr) locForm(ctx, lBy[tr.dataset.l]); };
  } else {
    const { data: cs } = await sb.from('company_settings').select('attendance').eq('company_id', S.company.id).maybeSingle();
    const c = cs?.attendance || {};
    v.innerHTML = `${head}<div class="card" style="max-width:520px"><form class="grid cols-2">
      <div class="field"><label>بداية الدوام</label><input type="time" name="start" value="${c.start || '08:00'}"></div>
      <div class="field"><label>نهاية الدوام</label><input type="time" name="end" value="${c.end || '16:00'}"></div>
      <div class="field"><label>فترة السماح بالتأخير (دقيقة)</label><input type="number" name="grace" min="0" max="120" value="${c.grace ?? 10}"></div>
      <div class="field"><label><input type="checkbox" name="allow_outside" ${c.allow_outside ? 'checked' : ''}> السماح بالتسجيل من برّا الموقع (بينعلّم «برّا»)</label></div></form>
      ${sup ? '<button class="btn primary" id="save">💾 حفظ</button>' : ''}</div>`;
    v.querySelector('#save')?.addEventListener('click', async () => {
      const f = v.querySelector('form'), d = formData(f);
      const { error } = await sb.from('company_settings').upsert({ company_id: S.company.id, attendance: { start: d.start, end: d.end, grace: +d.grace || 0, allow_outside: f.allow_outside.checked } }, { onConflict: 'company_id' });
      if (error) return toast(arError(error), 'err'); toast('انحفظ', 'ok');
    });
  }
}

export const ATTENDANCE_ROUTES = { attendance: viewAttendance };
