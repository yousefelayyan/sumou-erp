// =====================================================================
//  السمو ERP — المشتركين والاشتراكات
//  «إدارة المشتركين» لمدير المنصة: إضافة مشترك ومديره، الحدود والأقسام،
//  التمديد بتسجيل دفعة (كليك/تحويل)، الإيقاف، ومستخدمي كل مشترك.
//  «اشتراكي» لمدير المشترك: تفاصيل اشتراكه ودفعاته.
// =====================================================================
import { SALES_WHATSAPP } from './config.js';
import { S, sb, esc, toast, arError, modal, confirmBox, formData, fmtDate, fmtDateTime, fmtNum, num, today, isSuper, MODULES, qm } from './core.js';

const METHODS = ['كليك', 'تحويل بنكي', 'نقدي', 'شيك'];
const modLabel = (k) => MODULES.find(m => m.key === k)?.label || k;
const modsText = (mods) => !Array.isArray(mods) ? 'كل الأقسام' : mods.length ? mods.map(modLabel).join('، ') : 'الأساسي بس';

function expiryBadge(t) {
  if (t.is_default) return '<span class="badge brand">مفتوح</span>';
  if (t.status === 'suspended') return '<span class="badge bad">موقوف</span>';
  if (!t.expires_at) return '<span class="badge ok">بدون انتهاء</span>';
  const days = Math.round((new Date(t.expires_at) - new Date(today())) / 864e5);
  if (days < 0) return `<span class="badge bad">منتهي من ${-days} يوم</span>`;
  if (days <= 14) return `<span class="badge warn">باقي ${days} يوم</span>`;
  return `<span class="badge ok">ساري — باقي ${days} يوم</span>`;
}
const limit = (used, max) => `${used}${max ? ' / ' + max : ''}`;

// ---------------------------------------------------------------------
//  إدارة المشتركين (مدير المنصة)
// ---------------------------------------------------------------------
async function viewTenants(v, ctx) {
  if (!isSuper()) return void (v.innerHTML = `<div class="notice">هالشاشة لمدير المنصة بس.</div>`);
  const { data, error } = await sb.rpc('super_tenants');
  if (error) return void (v.innerHTML = `<div class="notice">${esc(arError(error))}</div>`);
  const [ex, tpl] = await Promise.all([sb.rpc('super_tenant_extras'), sb.rpc('super_demo_template_info')]);
  const X = Object.fromEntries((ex.data || []).map(x => [x.id, x]));
  const rows = (data || []).map(t => ({ ...t, ...(X[t.id] || {}) }));
  let q = '', onlyTrial = false;
  const active = rows.filter(t => !t.is_default && t.status === 'active' && (!t.expires_at || t.expires_at >= today())).length;
  const soon = rows.filter(t => !t.is_default && t.status === 'active' && t.expires_at && t.expires_at >= today() && (new Date(t.expires_at) - new Date(today())) / 864e5 <= 14).length;
  const expired = rows.filter(t => !t.is_default && t.expires_at && t.expires_at < today()).length;
  const paid = rows.reduce((s, t) => s + Number(t.paid_total || 0), 0);
  const draw = () => {
    const list = rows.filter(t => (!onlyTrial || t.is_trial) && (!q || qm([t.code, t.name, t.contact_name, t.phone], q)));
    v.querySelector('tbody').innerHTML = list.map(t => `<tr>
      <td><b dir="ltr">${esc(t.code)}</b></td><td><b>${esc(t.name)}</b>${t.is_trial ? ` <span class="badge warn">🧪 تجربة · ${t.docs_used || 0}/${t.max_docs || '∞'} حركة</span>` : ''}${t.plan ? `<div class="muted" style="font-size:12px">${esc(t.plan)}</div>` : ''}</td>
      <td>${esc(t.contact_name || '')}${t.phone ? `<div class="muted" dir="ltr" style="font-size:12px">${esc(t.phone)}</div>` : ''}</td>
      <td>${t.expires_at ? fmtDate(t.expires_at) : '—'}<div>${expiryBadge(t)}</div></td>
      <td class="n">${limit(t.users_active, t.max_users)}</td><td class="n">${limit(t.companies_count, t.max_companies)}</td>
      <td style="font-size:12px" title="${esc(modsText(t.modules))}">${!Array.isArray(t.modules) ? 'الكل' : t.modules.length + ' من ' + MODULES.length}</td>
      <td class="muted" style="font-size:12px">${t.last_login ? fmtDateTime(t.last_login) : '—'}</td>
      <td class="n">${fmtNum(t.paid_total)}</td>
      <td class="actions" style="white-space:nowrap">${t.is_default ? '' : `<button class="btn sm primary" data-pay="${t.id}" title="تسجيل دفعة وتمديد">💳 تمديد</button> `}<button class="btn sm" data-ed="${t.id}">تعديل</button>${t.is_trial ? ` <button class="btn sm danger" data-del="${t.id}" title="حذف التجربة وكل بياناتها">🗑️</button>` : ''} <button class="btn sm" data-us="${t.id}" title="المستخدمين">👥</button></td></tr>`).join('')
      || '<tr><td colspan="10" class="empty">ما في مشتركين</td></tr>';
  };
  v.innerHTML = `
    <div class="page-head"><h2>🏷️ إدارة المشتركين</h2><div class="spacer"></div>
      <input id="q" placeholder="بحث بالرمز أو الاسم أو الهاتف" style="max-width:240px">
      <label class="check" style="margin:0"><input type="checkbox" id="ot"> التجارب بس (${rows.filter(t => t.is_trial).length})</label>
      <button class="btn primary" id="add">➕ مشترك جديد</button></div>
    <div class="notice info" style="margin-bottom:12px">🧪 <b>قالب التجربة المجانية:</b> ${tpl.data ? `«${esc(tpl.data.company_name || '')}» (آخر تحديث ${fmtDateTime(tpl.data.updated_at)})` : 'لسا ما انختار، والتسجيل التجريبي مسكّر'}.
      لتغييره افتح الشركة اللي بدك ياها من «ملف ← الشركات» واضغط «🧪 اعتمدها قالب للتجربة». كل مشترك تجريبي بياخذ نسخة منها.</div>
    <div class="grid cols-4" style="margin-bottom:14px">
      <div class="card stat"><span class="k">مشتركين فعّالين</span><span class="v">${active}</span></div>
      <div class="card stat"><span class="k">بينتهوا خلال أسبوعين</span><span class="v">${soon}</span></div>
      <div class="card stat"><span class="k">منتهين</span><span class="v">${expired}</span></div>
      <div class="card stat"><span class="k">مجموع الدفعات</span><span class="v">${fmtNum(paid)}</span></div>
    </div>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرمز</th><th>المشترك</th><th>التواصل</th><th>الانتهاء</th><th>المستخدمين</th><th>الشركات</th><th>الأقسام</th><th>آخر دخول</th><th>المدفوع</th><th></th></tr></thead><tbody></tbody></table></div>
    <p class="muted" style="font-size:13px">المستخدم عند المشترك بيدخل بـ «رمز المشترك» + اسم المستخدم + كلمة السر. بعد تاريخ الانتهاء البرنامج بيصير للعرض والطباعة بس، والموقوف ما بيقدر يشوف شي.</p>`;
  draw();
  v.querySelector('#q').oninput = (e) => { q = e.target.value.trim().toLowerCase(); draw(); };
  v.querySelector('#add').onclick = () => editTenant(null, ctx);
  v.querySelector('#ot').onchange = (e) => { onlyTrial = e.target.checked; draw(); };
  v.querySelector('tbody').onclick = (e) => {
    const b = e.target.closest('button'); if (!b) return;
    const t = rows.find(x => x.id === (b.dataset.ed || b.dataset.pay || b.dataset.us || b.dataset.del));
    if (b.dataset.del) return void (async () => {
      if (!(await confirmBox(`حذف التجربة «${t.name}» (${t.code}) مع شركتها ومستخدميها وكل حركاتها؟ ما بترجع.`))) return ctx.rerender();
      const r = await sb.rpc('super_delete_trial', { p_tenant: t.id });
      if (r.error) toast(arError(r.error), 'err'); else toast('انحذفت التجربة', 'ok');
      ctx.rerender();
    })();
    if (b.dataset.ed) editTenant(t, ctx); else if (b.dataset.pay) payments(t, ctx); else if (b.dataset.us) tenantUsers(t);
  };
}

function editTenant(t, ctx) {
  const isNew = !t;
  t = t || { status: 'active', modules: MODULES.map(m => m.key), expires_at: new Date(Date.now() + 30 * 864e5).toISOString().slice(0, 10), max_users: 3, max_companies: 1 };
  const all = !Array.isArray(t.modules);
  const m = modal({ title: isNew ? '➕ مشترك جديد' : '✏️ تعديل المشترك: ' + t.name, size: 'lg', body: `<form id="tf" autocomplete="off">
    <div class="grid cols-3">
      <div class="field"><label>رمز المشترك (للدخول) *</label>${isNew ? `<input name="code" dir="ltr" autocapitalize="none" placeholder="mustafa-office">` : `<div class="ro-val" dir="ltr">${esc(t.code)}</div>`}</div>
      <div class="field" style="grid-column:span 2"><label>اسم المشترك *</label><input name="name" value="${esc(t.name || '')}" placeholder="مكتب مصطفى للمحاسبة"></div>
      <div class="field"><label>الباقة</label><input name="plan" value="${esc(t.plan || '')}" placeholder="أساسية / متقدمة"></div>
      <div class="field"><label>الحالة</label><select name="status" ${t.is_default ? 'disabled' : ''}><option value="active" ${t.status === 'active' ? 'selected' : ''}>فعّال</option><option value="suspended" ${t.status === 'suspended' ? 'selected' : ''}>موقوف</option></select></div>
      <div class="field"><label>تاريخ الانتهاء (آخر يوم)</label><input type="date" name="expires_at" value="${esc(t.expires_at || '')}" ${t.is_default ? 'disabled' : ''}></div>
      <div class="field"><label>أقصى عدد مستخدمين</label><input name="max_users" inputmode="numeric" dir="ltr" value="${t.max_users ?? ''}" placeholder="فاضي = بدون حد"></div>
      <div class="field"><label>أقصى عدد شركات</label><input name="max_companies" inputmode="numeric" dir="ltr" value="${t.max_companies ?? ''}" placeholder="فاضي = بدون حد"></div>
      <div class="field"><label>اسم الشخص المسؤول</label><input name="contact_name" value="${esc(t.contact_name || '')}"></div>
      <div class="field"><label>الهاتف</label><input name="phone" dir="ltr" value="${esc(t.phone || '')}"></div>
      <div class="field" style="grid-column:span 2"><label>الإيميل</label><input name="email" dir="ltr" value="${esc(t.email || '')}"></div>
    </div>
    ${t.is_default ? '<p class="muted">هذا مشتركك الأساسي: كل الأقسام مفتوحة وما إله انتهاء.</p>' : `
    <div class="field"><label>الأقسام المفتوحة <span class="muted">(الحسابات والقيود والسندات والتقارير والأصناف دايماً مفتوحة)</span></label>
      <label class="check"><input type="checkbox" id="m-all" ${all ? 'checked' : ''}> كل الأقسام (والأقسام الجديدة لما تنضاف)</label>
      <div class="grid cols-3" id="m-list">${MODULES.map(x => `<label class="check"><input type="checkbox" name="m_${x.key}" ${all || t.modules.includes(x.key) ? 'checked' : ''}> ${esc(x.label)}</label>`).join('')}</div></div>`}
    ${isNew ? `<h4 style="margin:14px 0 6px">مدير المشترك (أول مستخدم)</h4><div class="grid cols-3">
      <div class="field"><label>اسم المستخدم *</label><input name="admin_username" dir="ltr" autocapitalize="none" placeholder="admin"></div>
      <div class="field"><label>الاسم الكامل</label><input name="admin_full_name"></div>
      <div class="field"><label>كلمة السر *</label><input name="admin_password" dir="ltr" autocomplete="new-password"></div></div>` : ''}
    <div class="field"><label>ملاحظات</label><textarea name="notes" rows="2">${esc(t.notes || '')}</textarea></div></form>`,
    foot: '<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>' });
  const f = m.el.querySelector('#tf');
  const syncAll = () => { const a = f.querySelector('#m-all'); if (!a) return; f.querySelectorAll('#m-list input').forEach(i => { i.disabled = a.checked; if (a.checked) i.checked = true; }); };
  f.querySelector('#m-all')?.addEventListener('change', syncAll); syncAll();
  m.el.querySelector('[data-save]').onclick = async (ev) => {
    const d = formData(f);
    const p = { name: (d.name || '').trim(), plan: d.plan, status: t.is_default ? 'active' : d.status, expires_at: d.expires_at || '',
      max_users: d.max_users ? String(Math.trunc(num(d.max_users))) : '', max_companies: d.max_companies ? String(Math.trunc(num(d.max_companies))) : '',
      contact_name: d.contact_name, phone: d.phone, email: d.email, notes: d.notes };
    if (!t.is_default && !f.querySelector('#m-all').checked) p.modules = MODULES.filter(x => f.querySelector(`[name=m_${x.key}]`).checked).map(x => x.key);
    if (!p.name) return toast('اكتب اسم المشترك', 'err');
    if (isNew) {
      p.code = (d.code || '').trim().toLowerCase();
      if (!/^[a-z0-9][a-z0-9-]{1,19}$/.test(p.code)) return toast('رمز المشترك: أحرف إنجليزي صغيرة وأرقام وشرطة، من 2 لـ 20', 'err');
      if (!/^[a-z0-9._-]{2,30}$/.test((d.admin_username || '').trim().toLowerCase())) return toast('اكتب اسم مستخدم للمدير (أحرف إنجليزي أو أرقام)', 'err');
      if ((d.admin_password || '').length < 4) return toast('كلمة سر المدير 4 أحرف على الأقل', 'err');
    }
    ev.target.disabled = true;
    const r = await sb.rpc('super_save_tenant', { p_id: isNew ? null : t.id, p });
    if (r.error) { ev.target.disabled = false; return toast(arError(r.error), 'err'); }
    if (isNew) {
      const a = await sb.rpc('super_create_tenant_admin', { p_tenant: r.data, p_username: d.admin_username.trim().toLowerCase(), p_full_name: d.admin_full_name, p_password: d.admin_password });
      if (a.error) { toast('انعمل المشترك بس المدير لا: ' + arError(a.error), 'err'); m.close(); return ctx.rerender(); }
      m.close();
      modal({ title: '✅ انعمل المشترك', size: 'sm', body: `<p>ابعت للمشترك بيانات الدخول:</p>
        <div class="card" style="padding:12px;line-height:2">الرابط: <span dir="ltr">${esc(location.origin + location.pathname)}</span><br>
        رمز المشترك: <b dir="ltr">${esc(p.code)}</b><br>اسم المستخدم: <b dir="ltr">${esc(d.admin_username.trim().toLowerCase())}</b><br>كلمة السر: <b dir="ltr">${esc(d.admin_password)}</b></div>
        <p class="muted" style="font-size:13px">بعد ما يدخل بيعمل شركته من «تبديل الشركة»، وبيضيف موظفينه من «المستخدمين».</p>`,
        foot: '<button class="btn primary" data-close>تمام</button>' });
      return ctx.rerender();
    }
    toast('تم الحفظ', 'ok'); m.close(); ctx.rerender();
  };
}

async function payments(t, ctx) {
  const { data, error } = await sb.from('tenant_payments').select('*').eq('tenant_id', t.id).order('paid_at', { ascending: false }).order('created_at', { ascending: false });
  if (error) return toast(arError(error), 'err');
  const m = modal({ title: '💳 الدفعات والتمديد: ' + t.name, size: 'lg', body: `
    <div class="notice info">الانتهاء الحالي: <b>${t.expires_at ? fmtDate(t.expires_at) : 'بدون'}</b> ${expiryBadge(t)}. التمديد بيبدأ من آخر يوم بالاشتراك، أو من اليوم إذا كان منتهي.</div>
    <form id="pf" class="grid cols-3" autocomplete="off">
      <div class="field"><label>التاريخ</label><input type="date" name="paid_at" value="${today()}"></div>
      <div class="field"><label>المبلغ (دينار)</label><input name="amount" inputmode="decimal" dir="ltr" placeholder="0.000"></div>
      <div class="field"><label>التمديد</label><select name="months">${[0, 1, 2, 3, 6, 12, 24].map(n => `<option value="${n}" ${n === 12 ? 'selected' : ''}>${n === 0 ? 'بدون تمديد' : n === 1 ? 'شهر' : n === 2 ? 'شهرين' : n + (n > 10 ? ' شهر' : ' شهور')}</option>`).join('')}</select></div>
      <div class="field"><label>طريقة الدفع</label><select name="method">${METHODS.map(x => `<option>${x}</option>`).join('')}</select></div>
      <div class="field"><label>رقم المرجع / الحوالة</label><input name="reference" dir="ltr"></div>
      <div class="field"><label>ملاحظات</label><input name="notes"></div>
    </form>
    <div style="margin:4px 0 14px"><button class="btn primary" id="addpay">💾 سجّل الدفعة</button></div>
    <div class="card table-wrap"><table class="t"><thead><tr><th>التاريخ</th><th>المبلغ</th><th>الطريقة</th><th>التمديد</th><th>الانتهاء صار</th><th>المرجع</th><th>ملاحظات</th><th></th></tr></thead><tbody>
    ${(data || []).map(p => `<tr><td>${fmtDate(p.paid_at)}</td><td class="n">${fmtNum(p.amount)}</td><td>${esc(p.method || '')}</td><td>${p.months ? p.months + ' شهر' : '—'}</td>
      <td>${p.expires_after ? fmtDate(p.expires_after) : '—'}</td><td dir="ltr">${esc(p.reference || '')}</td><td>${esc(p.notes || '')}</td>
      <td><button class="btn sm danger" data-rm="${p.id}">حذف</button></td></tr>`).join('') || '<tr><td colspan="8" class="empty">ما في دفعات</td></tr>'}</tbody></table></div>`,
    foot: '<button class="btn" data-close>إغلاق</button>' });
  m.el.querySelector('#addpay').onclick = async (ev) => {
    const d = formData(m.el.querySelector('#pf'));
    const amount = num(d.amount), months = parseInt(d.months, 10) || 0;
    if (amount <= 0 && !months) return toast('اكتب المبلغ أو اختار مدة التمديد', 'err');
    ev.target.disabled = true;
    const r = await sb.rpc('super_add_payment', { p_tenant: t.id, p_amount: amount, p_months: months, p_method: d.method, p_paid_at: d.paid_at || today(), p_reference: d.reference || null, p_notes: d.notes || null });
    if (r.error) { ev.target.disabled = false; return toast(arError(r.error), 'err'); }
    toast(r.data ? 'انسجّلت الدفعة — الاشتراك ساري لـ ' + fmtDate(r.data) : 'انسجّلت الدفعة', 'ok'); m.close(); ctx.rerender();
  };
  m.el.querySelector('tbody').onclick = async (e) => {
    const b = e.target.closest('[data-rm]'); if (!b) return;
    if (!(await confirmBox('حذف الدفعة؟ إذا كانت آخر دفعة بيرجع تاريخ الانتهاء لقبلها.'))) return;
    const r = await sb.rpc('super_delete_payment', { p_id: b.dataset.rm });
    if (r.error) return toast(arError(r.error), 'err'); toast('انحذفت', 'ok'); m.close(); ctx.rerender();
  };
}

async function tenantUsers(t) {
  const { data, error } = await sb.rpc('super_tenant_users', { p_tenant: t.id });
  if (error) return toast(arError(error), 'err');
  const m = modal({ title: '👥 مستخدمين: ' + t.name, size: 'lg', body: `
    <p class="muted" style="font-size:13px">رمز الدخول: <b dir="ltr">${esc(t.code)}</b>. من هون بتقدر تغيّر كلمة سر مستخدم (مثلاً إذا مديرهم نسي كلمة سره)، أو توقفه، أو تضيف مدير ثاني.</p>
    <div class="card table-wrap"><table class="t"><thead><tr><th>اسم المستخدم</th><th>الاسم</th><th>النوع</th><th>الحالة</th><th>آخر دخول</th><th></th></tr></thead><tbody>
    ${(data || []).map(u => `<tr><td dir="ltr"><b>${esc(u.username || '')}</b></td><td>${esc(u.full_name || '')}</td><td>${u.is_admin ? '<span class="badge brand">مدير</span>' : 'مستخدم'}</td>
      <td>${u.is_active ? '<span class="badge ok">فعّال</span>' : '<span class="badge bad">موقوف</span>'}</td><td class="muted" style="font-size:12px">${u.last_login ? fmtDateTime(u.last_login) : '—'}</td>
      <td class="actions"><button class="btn sm" data-pw="${u.id}">🔑 كلمة سر</button> <button class="btn sm" data-tg="${u.id}" data-on="${u.is_active ? 1 : 0}">${u.is_active ? 'إيقاف' : 'تفعيل'}</button></td></tr>`).join('') || '<tr><td colspan="6" class="empty">ما في مستخدمين</td></tr>'}</tbody></table></div>
    <h4 style="margin:14px 0 6px">➕ مدير جديد لهالمشترك</h4>
    <form id="na" class="grid cols-3" autocomplete="off"><div class="field"><label>اسم المستخدم</label><input name="username" dir="ltr" autocapitalize="none"></div>
      <div class="field"><label>الاسم الكامل</label><input name="full_name"></div><div class="field"><label>كلمة السر</label><input name="password" dir="ltr" autocomplete="new-password"></div></form>
    <button class="btn primary" id="mkadmin">إضافة المدير</button>`,
    foot: '<button class="btn" data-close>إغلاق</button>' });
  const reload = () => { m.close(); tenantUsers(t); };
  m.el.querySelector('tbody').onclick = async (e) => {
    const b = e.target.closest('button'); if (!b) return;
    if (b.dataset.pw) {
      const pw = prompt('كلمة السر الجديدة (4 أحرف على الأقل):'); if (!pw) return;
      const r = await sb.rpc('super_set_user', { p_user: b.dataset.pw, p_password: pw, p_is_active: null });
      if (r.error) return toast(arError(r.error), 'err'); toast('تغيّرت كلمة السر', 'ok');
    } else if (b.dataset.tg) {
      const r = await sb.rpc('super_set_user', { p_user: b.dataset.tg, p_password: null, p_is_active: b.dataset.on !== '1' });
      if (r.error) return toast(arError(r.error), 'err'); toast('تم', 'ok'); reload();
    }
  };
  m.el.querySelector('#mkadmin').onclick = async () => {
    const d = formData(m.el.querySelector('#na'));
    const r = await sb.rpc('super_create_tenant_admin', { p_tenant: t.id, p_username: (d.username || '').trim().toLowerCase(), p_full_name: d.full_name, p_password: d.password });
    if (r.error) return toast(arError(r.error), 'err'); toast('انضاف المدير', 'ok'); reload();
  };
}

// ---------------------------------------------------------------------
//  اشتراكي (مدير المشترك)
// ---------------------------------------------------------------------
async function viewSubscription(v) {
  const s = S.sub;
  if (!s) return void (v.innerHTML = `<div class="notice">ما قدرنا نجيب تفاصيل الاشتراك.</div>`);
  const { data } = await sb.from('tenant_payments').select('*').order('paid_at', { ascending: false });
  const t = { ...s, is_default: s.is_default };
  v.innerHTML = `
    <div class="page-head"><h2>🎫 اشتراكي</h2></div>
    <div class="grid cols-4" style="margin-bottom:14px">
      <div class="card stat"><span class="k">المشترك</span><span class="v" style="font-size:18px">${esc(s.name)}</span><span class="muted" dir="ltr">${esc(s.code)}</span></div>
      <div class="card stat"><span class="k">الانتهاء</span><span class="v" style="font-size:18px">${s.expires_at ? fmtDate(s.expires_at) : 'بدون'}</span>${expiryBadge(t)}</div>
      <div class="card stat"><span class="k">المستخدمين الفعّالين</span><span class="v">${limit(s.users_used, s.max_users)}</span></div>
      <div class="card stat"><span class="k">الشركات</span><span class="v">${limit(s.companies_used, s.max_companies)}</span></div>
    </div>
    <div class="card" style="padding:14px;margin-bottom:14px"><b>الأقسام المفتوحة:</b> ${esc(modsText(s.modules))}${s.plan ? ` — <b>الباقة:</b> ${esc(s.plan)}` : ''}</div>
    <div class="card table-wrap"><table class="t"><thead><tr><th>تاريخ الدفعة</th><th>المبلغ</th><th>الطريقة</th><th>التمديد</th><th>الاشتراك لغاية</th><th>المرجع</th></tr></thead><tbody>
    ${(data || []).map(p => `<tr><td>${fmtDate(p.paid_at)}</td><td class="n">${fmtNum(p.amount)}</td><td>${esc(p.method || '')}</td><td>${p.months ? p.months + ' شهر' : '—'}</td><td>${p.expires_after ? fmtDate(p.expires_after) : '—'}</td><td dir="ltr">${esc(p.reference || '')}</td></tr>`).join('') || '<tr><td colspan="6" class="empty">ما في دفعات مسجّلة</td></tr>'}</tbody></table></div>
    <p class="muted" style="font-size:13px">للتجديد أو زيادة المستخدمين أو فتح أقسام جديدة: ادفع بكليك أو تحويل بنكي وتواصل معنا، وبنفعّلك فوراً.</p>`;
}

// شريط تنبيه الاشتراك فوق المحتوى
export function subBannerHTML() {
  const tr = S.trial;
  if (tr) {
    const wa = `https://wa.me/${SALES_WHATSAPP}?text=${encodeURIComponent('مرحبا، بدي أشترك ببرنامج السمو ERP (رمز التجربة ' + tr.code + ')')}`;
    const left = Math.max(0, tr.days_left ?? 0), used = tr.docs_used || 0, max = tr.max_docs || 0;
    const over = S.sub?.writable === false || (max && used >= max);
    return `<div class="sub-banner ${over ? 'bad' : 'warn'}" style="display:flex;gap:10px;align-items:center;flex-wrap:wrap">
      <span>🧪 <b>نسخة تجريبية</b> (رمز المشترك <b dir="ltr">${esc(tr.code)}</b>)</span>
      <span>${S.sub?.writable === false ? '⛔ خلصت مدة التجربة، البرنامج للعرض بس' : `⏳ باقي <b>${left}</b> يوم`}</span>
      ${max ? `<span>📄 الحركات: <b>${used}</b> من ${max}</span>` : ''}
      <a class="btn sm primary" target="_blank" rel="noopener" href="${wa}" style="margin-inline-start:auto">💬 اشترك الآن</a></div>`;
  }
  const s = S.sub; if (!s || s.is_default) return '';
  if (s.writable === false) return `<div class="sub-banner bad">⛔ انتهى اشتراكك بتاريخ ${fmtDate(s.expires_at)}. البرنامج هلّق <b>للعرض والطباعة بس</b>، وبياناتك محفوظة. للتجديد تواصل معنا.</div>`;
  if (s.days_left != null && s.days_left <= 14) return `<div class="sub-banner warn">⏳ اشتراكك بينتهي بعد <b>${s.days_left} يوم</b> (${fmtDate(s.expires_at)}). جدّد قبلها عشان ما يتوقف الإدخال.</div>`;
  return '';
}

export const TENANT_ROUTES = { tenants: viewTenants, subscription: viewSubscription };
