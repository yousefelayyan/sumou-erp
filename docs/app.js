// =====================================================================
//  السمو ERP — الهيكل الرئيسي وشاشات المرحلة 1
// =====================================================================
import { AUDIT_ENTITIES, AUDIT_COLS } from './audit.js';
import { downloadCSV } from './finance.js';
import { APP_NAME, APP_VERSION } from './config.js';
import { ACTIONS, ACTIVITY_TYPES, COMPANY_TYPES, INSTANCE, signOutHere, S, SCREENS, arError, can, confirmBox, esc, fmtDate, fmtDateTime, fmtNum, formData, hasUnsavedModal, canHiddenYears, THEMES, applyTheme, canTheme, canBranchReports, isAdmin, isSuper, loadContext, loadFiscalYears, loadProfile, localStorageGet, localStorageSet, log, modal, num, sb, setupTabs, toast, today } from './core.js';
import { FINANCE_ROUTES } from './finance.js';
import { REPORT_ROUTES } from './reports.js';
import { PARTY_ROUTES } from './parties.js';
import { INVOICE_ROUTES } from './invoices.js';
import { OBLIGATION_ROUTES, obligationsSummary } from './obligations.js';
import { CHEQUE_ROUTES } from './cheques.js';
import { INVENTORY_ROUTES } from './inventory.js';
import { PRINTSET_ROUTES } from './printset.js';
import { NUMBERING_ROUTES } from './numbering.js';
import { POSTING_ROUTES } from './posting.js';
import { CENTER_ROUTES } from './centers.js';
import { DEPARTMENT_ROUTES } from './departments.js';
import { permEditor } from './perms.js';
import { LOOKUP_ROUTES } from './lookups.js';
import { DAYBOOK_ROUTES, DAYBOOKS } from './daybook.js';
import { ORDER_ROUTES } from './orders.js';
import { MFG_ROUTES, enhanceReportTables } from './mfg.js';
import { EXTRA_ROUTES, dashboardPanel } from './extras.js';
import { PAYROLL_ROUTES } from './payroll.js';
import { ASSET_ROUTES } from './assets.js';
import { SUPPLY_ROUTES } from './supply.js';
import { ASK_ROUTES } from './ask.js';
import { REP_ROUTES } from './rep.js';
import { LOAN_ROUTES } from './loans.js';
import { ATTENDANCE_ROUTES } from './attendance.js';
import { DOCTYPE_ROUTES } from './doctypes.js';
import { PRICE_ROUTES } from './prices.js';
import { DISCOUNT_ROUTES } from './discounts.js';
import { MESSAGE_ROUTES } from './messages.js';
import { LANDED_ROUTES } from './landed.js';
import { LEAVE_ROUTES } from './leaves.js';
import { PROFILE_ROUTES } from './profile.js';
import { BATCH_ROUTES } from './batches.js';
import { BUDGET_ROUTES } from './budgets.js';
import { NOTE_ROUTES } from './notes.js';
import { CONTRACT_ROUTES } from './contracts.js';
import { COLLECTION_ROUTES } from './collection.js';
import { COMMISSION_ROUTES } from './commissions.js';
import { FOLLOW_ROUTES } from './follow.js';
import { PARTYDOC_ROUTES } from './partydocs.js';
import { COMPARE_ROUTES } from './compare.js';
import { TOOLS_ROUTES, autoBackup, autoLocalBackup } from './tools.js';
import { TENANT_ROUTES, subBannerHTML } from './tenants.js';
import { POS_ROUTES } from './pos.js';

const $app = document.getElementById('app');
// ---------------------------------------------------------------------
//  شاشات الدخول
// ---------------------------------------------------------------------
function renderAuth(mode = 'login') {
  if (mode === 'trial') return renderTrialSignup();
  const titles = { login: 'تسجيل الدخول', signup: 'حساب جديد', reset: 'نسيت كلمة السر' };
  $app.innerHTML = `
    <div class="auth-wrap"><div class="auth-card">
      <div class="auth-logo"><img src="icons/icon.svg" alt=""><h1>${APP_NAME}</h1></div>
      <p class="auth-sub">${titles[mode]}</p>
      <form id="auth-form">
        ${mode === 'signup' ? `<div class="field"><label>الاسم الكامل</label><input name="full_name" required></div>` : ''}
        ${mode === 'login' ? `<div class="field"><label>رمز المشترك <span class="muted" style="font-weight:400">(إذا عندك)</span></label><input name="tenant" dir="ltr" autocomplete="organization" autocapitalize="none" value="${esc(localStorageGet('sumou.tenant') || '')}"></div>` : ''}
        <div class="field"><label>${mode === 'login' ? 'اسم المستخدم أو الإيميل' : 'الإيميل'}</label><input name="email" type="${mode === 'login' ? 'text' : 'email'}" dir="ltr" required autocomplete="username" autocapitalize="none"></div>
        ${mode !== 'reset' ? `<div class="field"><label>كلمة السر</label><input name="password" type="password" dir="ltr" required minlength="${mode === 'login' ? 4 : 6}" autocomplete="${mode === 'login' ? 'current-password' : 'new-password'}"></div>` : ''}
        <button class="btn primary block" type="submit">${mode === 'login' ? 'دخول' : mode === 'signup' ? 'إنشاء الحساب' : 'إرسال رابط تغيير كلمة السر'}</button>
      </form>
      <div class="auth-switch">
        ${mode === 'login' ? `<a data-mode="reset">نسيت كلمة السر؟</a>` : `<a data-mode="login">رجوع لتسجيل الدخول</a>`}
      </div>
      ${mode === 'login' ? `<button type="button" class="btn block" data-mode="trial" style="margin-top:14px;border:2px dashed var(--brand);color:var(--brand);font-weight:700">🧪 جرّب البرنامج مجاناً 14 يوم</button>` : ''}
      <p class="muted" style="text-align:center;font-size:12px;margin-top:18px">الإصدار ${APP_VERSION}</p>
    </div></div>`;
  $app.querySelectorAll('[data-mode]').forEach(a => a.onclick = () => renderAuth(a.dataset.mode));
  const form = document.getElementById('auth-form');
  form.onsubmit = async (e) => {
    e.preventDefault();
    const btn = form.querySelector('button'); btn.disabled = true;
    const f = formData(form);
    try {
      if (mode === 'login') {
        const code = (f.tenant || '').trim().toLowerCase();
        localStorageSet('sumou.tenant', code);
        const domain = !code || code === 'sumou' ? 'sumou.local' : code + '.sumou.local';
        const { error } = await sb.auth.signInWithPassword({ email: f.email.includes('@') ? f.email.trim() : f.email.trim().toLowerCase() + '@' + domain, password: f.password });
        if (error) throw error;
      } else if (mode === 'signup') {
        const { data, error } = await sb.auth.signUp({ email: f.email, password: f.password,
          options: { data: { full_name: f.full_name }, emailRedirectTo: location.origin + location.pathname } });
        if (error) throw error;
        if (!data.session) {
          modal({ title: 'تم إنشاء الحساب', size: 'sm',
            body: `<p>وصلك إيميل تأكيد على <b dir="ltr">${esc(f.email)}</b>. افتح الإيميل واضغط رابط التأكيد، وبعدها سجّل دخول.</p>
                   <p class="muted">إذا ما كنت أول مستخدم، حسابك بيحتاج موافقة مدير النظام.</p>`,
            foot: `<button class="btn primary" data-close>تمام</button>` });
          renderAuth('login');
        }
      } else {
        const { error } = await sb.auth.resetPasswordForEmail(f.email, { redirectTo: location.origin + location.pathname });
        if (error) throw error;
        toast('أرسلنا رابط تغيير كلمة السر على إيميلك', 'ok');
        renderAuth('login');
      }
    } catch (err) { toast(arError(err), 'err'); }
    finally { btn.disabled = false; }
  };
}

function renderTrialSignup() {
  $app.innerHTML = `
    <div class="auth-wrap"><div class="auth-card" style="max-width:460px">
      <div class="auth-logo"><img src="icons/icon.svg" alt=""><h1>${APP_NAME}</h1></div>
      <p class="auth-sub">🧪 جرّب البرنامج مجاناً</p>
      <p class="muted" style="font-size:13px;text-align:center;margin-top:-6px">14 يوم، شركة جاهزة فيها عملاء وأصناف وفواتير وقيود، وكل التقارير. بدون أي التزام.</p>
      <form id="trial-form">
        <div class="field"><label>اسمك *</label><input name="name" required maxlength="80" autocomplete="name"></div>
        <div class="field"><label>اسم الشركة أو النشاط *</label><input name="company" required maxlength="100" autocomplete="organization"></div>
        <div class="grid cols-2"><div class="field"><label>الموبايل *</label><input name="phone" required dir="ltr" inputmode="tel" placeholder="07xxxxxxxx" autocomplete="tel"></div>
          <div class="field"><label>الإيميل</label><input name="email" type="email" dir="ltr" autocomplete="email"></div></div>
        <div class="grid cols-2"><div class="field"><label>اسم المستخدم *</label><input name="username" required dir="ltr" autocapitalize="none" pattern="[A-Za-z0-9._-]{3,30}" title="أحرف إنجليزي أو أرقام" autocomplete="username"></div>
          <div class="field"><label>كلمة السر *</label><input name="password" type="password" required minlength="6" dir="ltr" autocomplete="new-password"></div></div>
        <button class="btn primary block" type="submit">🚀 ابدأ التجربة</button>
      </form>
      <div class="auth-switch"><a data-mode="login">عندي حساب، رجوع لتسجيل الدخول</a></div>
    </div></div>`;
  $app.querySelector('[data-mode]').onclick = () => renderAuth('login');
  const form = document.getElementById('trial-form');
  form.onsubmit = async (e) => {
    e.preventDefault();
    const btn = form.querySelector('button'); btn.disabled = true; btn.textContent = 'جاري إنشاء حسابك…';
    const f = formData(form);
    try {
      const { data, error } = await sb.rpc('trial_signup', { p: { name: f.name, company: f.company, phone: f.phone, email: f.email, username: f.username, password: f.password } });
      if (error) throw error;
      localStorageSet('sumou.tenant', data.code);
      const { error: e2 } = await sb.auth.signInWithPassword({ email: data.username + '@' + data.code + '.sumou.local', password: f.password });
      if (e2) throw e2;
      localStorageSet('sumou.trialWelcome', JSON.stringify({ code: data.code, username: data.username, expires_at: data.expires_at }));
    } catch (err) { toast(arError(err), 'err'); btn.disabled = false; btn.textContent = '🚀 ابدأ التجربة'; }
  };
}

function renderNewPassword() {
  $app.innerHTML = `
    <div class="auth-wrap"><div class="auth-card">
      <div class="auth-logo"><img src="icons/icon.svg" alt=""><h1>${APP_NAME}</h1></div>
      <p class="auth-sub">اختار كلمة سر جديدة</p>
      <form id="pw-form">
        <div class="field"><label>كلمة السر الجديدة</label><input name="password" type="password" dir="ltr" minlength="6" required></div>
        <button class="btn primary block">حفظ</button>
      </form></div></div>`;
  document.getElementById('pw-form').onsubmit = async (e) => {
    e.preventDefault();
    const { error } = await sb.auth.updateUser({ password: e.target.password.value });
    if (error) return toast(arError(error), 'err');
    toast('تم تغيير كلمة السر', 'ok'); history.replaceState(null, '', location.pathname + '#/home'); boot();
  };
}

// تغيير كلمة السر (المستخدم لحاله) — change_my_password بيفحص القديمة والسياسة
const policyHint = (pol) => !pol ? '' : [`${pol.min_len || 4} أحرف على الأقل`, pol.require_digit && 'فيها رقم', pol.require_letter && 'فيها حرف إنجليزي',
  pol.require_mixed && 'حرف كبير وصغير', pol.require_symbol && 'فيها رمز'].filter(Boolean).join('، ');
function pwFormHTML(pol) {
  return `<div class="field"><label>كلمة السر الحالية</label><input name="old" type="password" dir="ltr" required autocomplete="current-password"></div>
    <div class="field"><label>كلمة السر الجديدة</label><input name="new1" type="password" dir="ltr" required autocomplete="new-password"><span class="hint">${esc(policyHint(pol))}</span></div>
    <div class="field"><label>أعد كتابتها</label><input name="new2" type="password" dir="ltr" required autocomplete="new-password"></div>`;
}
async function submitPw(f) {
  if (f.new1.value !== f.new2.value) { toast('كلمتين السر الجديدات مش متطابقات', 'err'); return false; }
  const { error } = await sb.rpc('change_my_password', { p_old: f.old.value, p_new: f.new1.value });
  if (error) { toast(arError(error), 'err'); return false; }
  toast('تغيّرت كلمة السر', 'ok'); return true;
}
function renderForcedPassword(st) {
  $app.innerHTML = `
    <div class="auth-wrap"><div class="auth-card">
      <div class="auth-logo"><img src="icons/icon.svg" alt=""><h1>${APP_NAME}</h1></div>
      <p class="auth-sub">${st.expired ? 'انتهت صلاحية كلمة السر. اختار كلمة سر جديدة.' : 'لازم تغيّر كلمة السر قبل ما تكمّل.'}</p>
      <form id="pw-form">${pwFormHTML(st.policy)}<button class="btn primary block">حفظ</button></form>
      <div class="auth-links"><a onclick="window.__logout()">تسجيل خروج</a></div></div></div>`;
  document.getElementById('pw-form').onsubmit = async (e) => { e.preventDefault(); if (await submitPw(e.target)) boot(); };
}
export async function changePasswordDialog() {
  const { data } = await sb.rpc('my_password_status');
  const m = modal({ title: '🔑 تغيير كلمة السر', body: `<form id="cpf">${pwFormHTML(data?.policy)}</form>`, foot: '<button class="btn primary" data-ok>حفظ</button><button class="btn" data-close>إلغاء</button>' });
  m.el.querySelector('[data-ok]').onclick = async () => { if (await submitPw(m.el.querySelector('#cpf'))) m.close(); };
}
async function passwordPolicyDialog() {
  const { data: pol = {} } = await sb.rpc('password_policy');
  const m = modal({ title: '🔐 سياسة كلمات السر', body: `<form id="ppf" class="grid cols-2">
    <div class="field"><label>أقل عدد أحرف</label><input type="number" name="min_len" min="4" max="32" value="${pol.min_len || 4}"></div>
    <div class="field"><label>تنتهي كل (يوم)</label><input type="number" name="expiry_days" min="0" max="730" value="${pol.expiry_days || 0}"><span class="hint">0 = ما بتنتهي</span></div>
    ${[['require_digit', 'لازم فيها رقم'], ['require_letter', 'لازم فيها حرف إنجليزي'], ['require_mixed', 'لازم حرف كبير وحرف صغير'], ['require_symbol', 'لازم فيها رمز (@ # ! …)'],
       ['force_change', 'المستخدم بيغيّر كلمة السر اللي بيحطها المدير أول ما يدخل']].map(([k, l]) => `<label class="check" style="grid-column:span 2"><input type="checkbox" name="${k}" ${pol[k] ? 'checked' : ''}> ${l}</label>`).join('')}</form>
    <p class="muted" style="font-size:12px">السياسة بتنطبق على كلمات السر الجديدة (إضافة مستخدم، تعديل كلمة سره، وتغيير المستخدم لكلمة سره). الانتهاء بيطلب من المستخدم يغيّرها بالدخول.</p>`,
    foot: '<button class="btn primary" data-ok>💾 حفظ</button><button class="btn" data-close>إلغاء</button>' });
  m.el.querySelector('[data-ok]').onclick = async () => {
    const f = m.el.querySelector('#ppf'), d = formData(f);
    const p = { min_len: +d.min_len || 4, expiry_days: +d.expiry_days || 0 };
    ['require_digit', 'require_letter', 'require_mixed', 'require_symbol', 'force_change'].forEach(k => p[k] = f[k].checked);
    const { error } = await sb.rpc('set_password_policy', { p }); if (error) return toast(arError(error), 'err');
    toast('انحفظت السياسة', 'ok'); m.close();
  };
}

function renderSuspended() {
  $app.innerHTML = `
    <div class="auth-wrap"><div class="auth-card">
      <div class="auth-logo"><img src="icons/icon.svg" alt=""><h1>${APP_NAME}</h1></div>
      <div class="notice">اشتراك <b>${esc(S.sub?.name || '')}</b> موقوف حالياً. بياناتك محفوظة، وبترجع تشوفها أول ما ينفعّل الاشتراك. تواصل معنا.</div>
      <button class="btn block" id="refresh">تحديث</button>
      <div style="height:8px"></div>
      <button class="btn danger block" id="logout">تسجيل خروج</button>
    </div></div>`;
  document.getElementById('refresh').onclick = boot;
  document.getElementById('logout').onclick = () => signOutHere();
}

function renderPending() {
  $app.innerHTML = `
    <div class="auth-wrap"><div class="auth-card">
      <div class="auth-logo"><img src="icons/icon.svg" alt=""><h1>${APP_NAME}</h1></div>
      <div class="notice">حسابك <b>بانتظار موافقة مدير النظام</b>. أول ما يفعّل حسابك ويعطيك صلاحية على شركة، بتقدر تدخل.</div>
      <p class="muted">الإيميل: <span dir="ltr">${esc(S.session.user.email)}</span></p>
      <button class="btn block" id="refresh">تحديث</button>
      <div style="height:8px"></div>
      <button class="btn danger block" id="logout">تسجيل خروج</button>
    </div></div>`;
  document.getElementById('refresh').onclick = boot;
  document.getElementById('logout').onclick = () => signOutHere();
}

// ---------------------------------------------------------------------
//  الهيكل الرئيسي
// ---------------------------------------------------------------------
// بدون شركات (للعرض على الزباين): المدير بيشوف كل الشاشات، والشاشة اللي بدها شركة بتطلب إضافة شركة
const DEMO = () => !S.company && isAdmin();
const NO_CO_ROUTES = new Set(['home', 'companies', 'users', 'groups', 'backup', 'log', 'subscription', 'tenants', 'obligations']);
function viewNeedCompany(v, r) {
  const it = NAV().flatMap(g => g.items.map(x => ({ ...x, g: g.title }))).find(x => x.r && (x.r === r || x.r.split('?')[0] === r));
  v.innerHTML = `<div class="page-head"><h2>${it ? `${it.i} ${esc(it.l)}` : 'الشاشة'}</h2></div>
    <div class="card" style="text-align:center;padding:30px">
      <div style="font-size:46px">🏢</div>
      <h3>هالشاشة بتشتغل على شركة</h3>
      <p class="muted">${it ? `«${esc(it.l)}» من مجموعة «${esc(it.g)}». ` : ''}أضف شركة أول، وبعدها بتفتح الشاشة ببياناتها.</p>
      <button class="btn primary" id="need-co" style="font-size:16px;padding:10px 20px">➕ إضافة شركة جديدة</button></div>`;
  v.querySelector('#need-co').onclick = () => openCompanyForm(null);
}
const NAV = () => [
  { title: 'الرئيسية', items: [{ r: 'home', i: '🏠', l: 'لوحة التحكم' }] },
  { title: 'ملف', items: [
    { r: 'company', i: '🏢', l: 'بيانات الشركة', show: () => S.company && can('companies', 'view') },
    { r: 'fiscal-years', i: '📅', l: 'السنوات المالية', show: () => S.company && can('fiscal_years', 'view') },
    { act: 'year', i: '🔄', l: 'تبديل السنة المالية', show: () => S.company && S.fiscalYears.length > 0 },
    { r: 'departments', i: '🏛️', l: 'الدوائر', show: () => S.company && can('departments', 'view') },
    { r: 'settings', i: '🔗', l: 'حسابات الربط والضريبة', show: () => S.company && can('companies', 'edit') },
    { r: 'import', i: '📥', l: 'الاستيراد من إكسل', show: () => S.company && ['customers', 'suppliers', 'items', 'accounts', 'opening_balances', 'payroll'].some(x => can(x, 'add') || can(x, 'edit')) },
    { r: 'companies', i: '🗂️', l: 'الشركات', show: isAdmin },
    { r: 'users', i: '👥', l: 'المستخدمين', show: isAdmin },
    { r: 'groups', i: '🔐', l: 'المجموعات والصلاحيات', show: isAdmin },
  ]},
  { title: 'إعداد', items: [
    { r: 'doc-types', i: '🗂️', l: 'أنواع السندات (اليوميات)', show: () => !!S.company },
    { r: 'setup?k=payment_method', i: '💳', l: 'وسائل الدفع', show: () => S.company && can('lookups', 'view') },
    { r: 'setup?k=bank', i: '🏦', l: 'البنوك', show: () => S.company && can('lookups', 'view') },
    { r: 'setup?k=bank_branch', i: '🏧', l: 'فروع البنوك', show: () => S.company && can('lookups', 'view') },
    { r: 'setup?k=cheque_type', i: '🧾', l: 'أنواع الأوراق التجارية', show: () => S.company && can('lookups', 'view') },
    { r: 'setup?k=country', i: '🌍', l: 'الدول / البلاد', show: () => S.company && can('lookups', 'view') },
    { r: 'setup?k=region', i: '🗺️', l: 'المناطق / الأقاليم', show: () => S.company && can('lookups', 'view') },
    { r: 'setup?k=sales_rep', i: '🧑‍💼', l: 'مندوبي المبيعات', show: () => S.company && can('lookups', 'view') },
    { r: 'setup?k=route', i: '🛣️', l: 'المسارات', show: () => S.company && can('lookups', 'view') },
    { r: 'setup?k=brand', i: '🏷️', l: 'الماركات', show: () => S.company && can('lookups', 'view') },
    { r: 'doc-statuses', i: '📌', l: 'حالات المتابعة على المستندات', show: () => S.company && can('doc_types', 'view') },
    { r: 'cost-centers', i: '💱', l: 'العملات وأسعار التحويل', show: () => S.company && can('accounts', 'view') },
    { r: 'custom-fields', i: '🧩', l: 'الحقول الإضافية', show: () => S.company && can('lookups', 'view') },
    { r: 'field-layout', i: '🧱', l: 'تنسيق الحقول', show: () => S.company && can('companies', 'view') },
  ]},
  { title: 'المالية', items: [
    { r: 'accounts', i: '🌳', l: 'دليل الحسابات', show: () => S.company && can('accounts', 'view') },
    { r: 'account-center', i: '📗', l: 'الأستاذ العام للحسابات', show: () => S.company && can('reports', 'view') },
    { r: 'opening', i: '🧮', l: 'الأرصدة الافتتاحية', show: () => S.company && can('opening_balances', 'view') },
    { r: 'journal', i: '📒', l: 'سندات القيد', show: () => S.company && can('journal_entries', 'view') },
    { r: 'receipts', i: '📥', l: 'سندات القبض', show: () => S.company && can('receipt_vouchers', 'view') },
    { r: 'payments', i: '📤', l: 'سندات الصرف', show: () => S.company && can('payment_vouchers', 'view') },
    { r: 'cheques', i: '💳', l: 'محفظة الشيكات', show: () => S.company && can('cheques', 'view') },
    { r: 'cheques-dash', i: '📈', l: 'لوحة الشيكات', show: () => S.company && can('cheques', 'view') },
    { r: 'guarantees', i: '🛡️', l: 'شيكات الضمان', show: () => S.company && can('cheques', 'view') },
    { r: 'pending', i: '⏳', l: 'بانتظار الترحيل', show: () => S.company },
    { r: 'recurring', i: '🔁', l: 'القيود المتكررة', show: () => S.company && can('journal_entries', 'view') },
    { r: 'budgets', i: '📐', l: 'الموازنات التقديرية', show: () => S.company && can('budgets', 'view') },
    { r: 'bank-recon', i: '🏦', l: 'التسوية البنكية', show: () => S.company && can('bank_recon', 'view') },
    { r: 'cost-centers', i: '🎯', l: 'مراكز الكلفة والعملات', show: () => S.company && can('accounts', 'view') },
  ]},
  { title: 'الموظفين والرواتب', items: [
    { r: 'employees', i: '👷', l: 'الموظفين', show: () => S.company && can('payroll', 'view') },
    { r: 'payroll', i: '💵', l: 'الرواتب والضمان', show: () => S.company && can('payroll', 'view') },
    { r: 'loans', i: '💳', l: 'القروض والسلف', show: () => S.company && can('payroll', 'view') },
    { r: 'attendance', i: '🕘', l: 'الحضور والانصراف', show: () => S.company && can('payroll', 'view') },
    { r: 'leaves', i: '🌴', l: 'الإجازات', show: () => S.company && can('payroll', 'view') },
    { r: 'me', i: '💼', l: 'راتبي (حضوري وقسيمتي وقروضي وإجازاتي)', show: () => !!S.company },
    { r: 'employee-center', i: '📒', l: 'أستاذ مساعد الموظفين', show: () => S.company && can('payroll', 'view') },
    { r: 'employee-tb', i: '⚖️', l: 'ميزان مراجعة الموظفين', show: () => S.company && (can('payroll', 'view') || can('reports', 'view')) },
  ]},
  { title: 'الأصول الثابتة', items: [
    { r: 'assets', i: '🏢', l: 'الأصول الثابتة والاستهلاك', show: () => S.company && can('fixed_assets', 'view') },
    { r: 'asset-moves', i: '🔁', l: 'حركات الأصول الثابتة', show: () => S.company && can('fixed_assets', 'view') },
    { r: 'asset-custody', i: '🧾', l: 'عهد الأصول الثابتة', show: () => S.company && can('asset_custody', 'view') },
    { r: 'asset-center', i: '📒', l: 'أستاذ مساعد الأصول الثابتة', show: () => S.company && can('fixed_assets', 'view') },
  ]},
  { title: 'المصاريف', items: [
    { r: 'expenses', i: '💸', l: 'بطاقات المصاريف', show: () => S.company && can('expense_cards', 'view') },
    { r: 'account-center?cat=expenses', i: '💸', l: 'مركز تحكم المصاريف', show: () => S.company && can('reports', 'view') },
    { r: 'party-center?type=expense', i: '📒', l: 'أستاذ مساعد المصاريف', show: () => S.company && can('reports', 'view') },
    { r: 'payments', i: '📤', l: 'سندات الصرف', show: () => S.company && can('payment_vouchers', 'view') },
    { r: 'party-categories?type=expense', i: '🗂️', l: 'فئات المصاريف', show: () => S.company && can('expense_cards', 'view') },
  ]},
  { title: 'المخزون', items: [
    { r: 'items', i: '🏷️', l: 'الأصناف والخدمات', show: () => S.company && can('items', 'view') },
    { r: 'price-lists', i: '💲', l: 'قوائم الأسعار', show: () => S.company && can('items', 'view') },
    { r: 'stock', i: '📦', l: 'رصيد المخزون', show: () => S.company && can('inventory', 'view') },
    { r: 'batches', i: '🧪', l: 'الدفعات وتواريخ الانتهاء', show: () => S.company && can('inventory', 'view') },
    { r: 'stock-docs?type=in', i: '📥', l: 'سندات الإدخال والإخراج', show: () => S.company && can('inventory', 'view') },
    { r: 'stock-docs?type=count', i: '📋', l: 'الجرد والتسوية', show: () => S.company && can('inventory', 'view') },
    { r: 'supply', i: '🚚', l: 'طلبات التزويد', show: () => S.company && (can('supply_requests', 'view') || can('inventory', 'view')) },
    { r: 'item-card', i: '🗂️', l: 'بطاقة صنف', show: () => S.company && can('inventory', 'view') },
    { r: 'warehouses', i: '🏬', l: 'المستودعات', show: () => S.company && can('inventory', 'view') },
  ]},
  { title: 'العملاء والذمم المدينة', items: [
    { r: 'customers', i: '🧑‍💼', l: 'العملاء', show: () => S.company && can('customers', 'view') },
    { r: 'party-profile', i: '📊', l: 'ملف العميل الإحصائي', show: () => S.company && can('customers', 'view') },
    { r: 'party-docs', i: '📄', l: 'وثائق العملاء والموردين', show: () => S.company && (can('customers', 'view') || can('suppliers', 'view')) },
    { r: 'rep', i: '📱', l: 'تطبيق المندوب (زيارات ودفعات)', show: () => S.company && can('rep_visits', 'view') },
    { r: 'obligations', i: '🔔', l: 'متابعة إقرارات العملاء', show: () => S.companies.some(c => can('obligations', 'view', c.id)) },
    { r: 'party-center?type=customer', i: '📒', l: 'أستاذ مساعد العملاء', show: () => S.company && can('reports', 'view') },
    { r: 'orders?t=sales_order', i: '📝', l: 'طلبات المبيعات / عروض الأسعار', show: () => S.company && can('sales_orders', 'view') },
    { r: 'pos', i: '🛒', l: 'نقطة البيع (الكاشير)', show: () => S.company && can('pos', 'view') },
    { r: 'pos-day', i: '🧾', l: 'ملخص الكاشير اليومي', show: () => S.company && (can('pos', 'edit') || can('sales_invoices', 'view')) },
    { r: 'sales?t=sale', i: '🧾', l: 'فواتير المبيعات', show: () => S.company && can('sales_invoices', 'view') },
    { r: 'sales?t=sale_return', i: '↩️', l: 'مردودات المبيعات', show: () => S.company && can('sales_invoices', 'view') },
    { r: 'contracts', i: '🔁', l: 'العقود والرسوم المتكررة', show: () => S.company && can('contracts', 'view') },
    { r: 'notes?type=customer', i: '🧾', l: 'إشعارات العملاء (مدين/دائن)', show: () => S.company && can('customer_notes', 'view') },
    { r: 'rep-aging?type=customer&mode=summary', i: '⏳', l: 'أعمار ذمم العملاء — تجميعي', show: () => S.company && can('reports', 'view') },
    { r: 'rep-aging?type=customer&mode=detail', i: '⏳', l: 'أعمار ذمم العملاء — تفصيلي', show: () => S.company && can('reports', 'view') },
    { r: 'commissions', i: '💼', l: 'عمولات المندوبين والأهداف', show: () => S.company && (can('rep_commissions', 'view') || (S._lk?.rows || []).some(r => r.kind === 'sales_rep' && r.user_id === S.session?.user?.id)) },
    { r: 'collection?type=customer&t=open', i: '💰', l: 'فواتير العملاء غير المسددة', show: () => S.company && (can('reports', 'view') || can('sales_invoices', 'view') || can('receipt_vouchers', 'view')) },
    { r: 'collection?type=customer&t=coll', i: '⏱️', l: 'تحصيل الفواتير وأيام السداد', show: () => S.company && (can('reports', 'view') || can('sales_invoices', 'view') || can('receipt_vouchers', 'view')) },
    { r: 'party-categories?type=customer', i: '🗂️', l: 'فئات العملاء', show: () => S.company && can('customers', 'view') },
    { r: 'discounts', i: '🎁', l: 'خصومات العملاء والتسويات', show: () => S.company && can('customer_discounts', 'view') },
  ]},
  { title: 'الموردين والذمم الدائنة', items: [
    { r: 'suppliers', i: '🏭', l: 'الموردين', show: () => S.company && can('suppliers', 'view') },
    { r: 'party-profile?s=1', i: '📊', l: 'ملف المورد الإحصائي', show: () => S.company && can('suppliers', 'view') },
    { r: 'party-center?type=supplier', i: '📒', l: 'أستاذ مساعد الموردين', show: () => S.company && can('reports', 'view') },
    { r: 'orders?t=purchase_order', i: '📋', l: 'طلبات التزويد', show: () => S.company && can('purchase_orders', 'view') },
    { r: 'landed-costs', i: '🚢', l: 'الكلفة المحمّلة (شحن وجمارك)', show: () => S.company && can('landed_costs', 'view') },
    { r: 'purchases?t=purchase', i: '🛒', l: 'فواتير المشتريات', show: () => S.company && can('purchase_invoices', 'view') },
    { r: 'purchases?t=purchase_return', i: '↩️', l: 'مردودات المشتريات', show: () => S.company && can('purchase_invoices', 'view') },
    { r: 'notes?type=supplier', i: '🧾', l: 'إشعارات الموردين (مدين/دائن)', show: () => S.company && can('supplier_notes', 'view') },
    { r: 'rep-aging?type=supplier&mode=summary', i: '⏳', l: 'أعمار ذمم الموردين — تجميعي', show: () => S.company && can('reports', 'view') },
    { r: 'rep-aging?type=supplier&mode=detail', i: '⏳', l: 'أعمار ذمم الموردين — تفصيلي', show: () => S.company && can('reports', 'view') },
    { r: 'collection?type=supplier&t=open', i: '💰', l: 'فواتير الموردين غير المسددة', show: () => S.company && (can('reports', 'view') || can('purchase_invoices', 'view') || can('payment_vouchers', 'view')) },
    { r: 'collection?type=supplier&t=coll', i: '⏱️', l: 'سداد فواتير الموردين وأيامه', show: () => S.company && (can('reports', 'view') || can('purchase_invoices', 'view') || can('payment_vouchers', 'view')) },
    { r: 'party-categories?type=supplier', i: '🗂️', l: 'فئات الموردين', show: () => S.company && can('suppliers', 'view') },
  ]},
  { title: 'التصنيع', items: [
    { r: 'boms', i: '🧪', l: 'الوصفات (قوائم المواد)', show: () => S.company && can('manufacturing', 'view') },
    { r: 'production', i: '🏭', l: 'أوامر الإنتاج', show: () => S.company && can('manufacturing', 'view') },
  ]},
  { title: 'الصيانة', items: [
    { r: 'service', i: '🔧', l: 'بطاقات الصيانة', show: () => S.company && can('maintenance', 'view') },
  ]},
  { title: 'التسويق', items: [
    { r: 'promotions', i: '📢', l: 'العروض الترويجية', show: () => S.company && can('marketing', 'view') },
    { r: 'messages', i: '💬', l: 'الرسائل والواتساب', show: () => S.company && can('marketing', 'view') },
    { r: 'loyalty', i: '💳', l: 'مركز تحكم بطاقات الولاء', show: () => S.company && can('customers', 'view') },
    { r: 'loyalty-cashback', i: '🏅', l: 'مراتب الولاء والاسترداد النقدي', show: () => S.company && can('marketing', 'view') },
    { r: 'setup?k=loyalty_type', i: '🎫', l: 'أنواع بطاقات الولاء', show: () => S.company && can('lookups', 'view') },
    { r: 'setup?k=sales_rep', i: '🧑‍💼', l: 'مندوبي المبيعات', show: () => S.company && can('lookups', 'view') },
    { r: 'rep-sales-reps', i: '📈', l: 'مبيعات وتحصيلات المندوبين', show: () => S.company && can('reports', 'view') },
  ]},
  { title: 'التقارير', items: [
    { r: 'ask', i: '💬', l: 'اسأل السمو (تقارير بالكلام)', show: () => S.company && (can('sales_invoices', 'view') || can('reports', 'view')) },
    { r: 'rep-ledger', i: '📄', l: 'كشف حساب', show: () => S.company && can('reports', 'view') },
    { r: 'rep-journal', i: '📚', l: 'اليومية العامة', show: () => S.company && can('reports', 'view') },
    { r: 'rep-trial', i: '⚖️', l: 'ميزان المراجعة', show: () => S.company && canBranchReports() },
    { r: 'rep-income', i: '📈', l: 'قائمة الدخل', show: () => S.company && canBranchReports() },
    { r: 'compare', i: '⚖️', l: 'مقارنة الفترات (نسبة النمو)', show: () => S.company && (can('reports', 'view') || can('sales_invoices', 'view')) },
    { r: 'rep-balance', i: '🏦', l: 'الميزانية العمومية', show: () => S.company && canBranchReports() },
    { r: 'whatif', i: '🔮', l: 'ماذا لو؟ (دراسة الأرباح)', show: () => S.company && canBranchReports() },
    { r: 'rep-party', i: '👤', l: 'كشف حساب عميل/مورد', show: () => S.company && can('reports', 'view') },
    { r: 'rep-aging?type=customer&mode=summary', i: '⏳', l: 'أعمار الذمم', show: () => S.company && can('reports', 'view') },
    { r: 'rep-salestax', i: '🏛️', l: 'إقرار ضريبة المبيعات', show: () => S.company && can('reports', 'view') },
    { r: 'rep-cc', i: '🎯', l: 'تقرير مراكز الكلفة', show: () => S.company && can('reports', 'view') },
    { r: 'rep-fx', i: '💱', l: 'أرصدة العملات', show: () => S.company && can('reports', 'view') },
    { r: 'rep-sales-reps', i: '🧑‍💼', l: 'مبيعات وتحصيلات المندوبين', show: () => S.company && can('reports', 'view') },
    { r: 'stock-analysis?k=aging', i: '⏳', l: 'تعمير المخزون', show: () => S.company && can('inventory', 'view') },
    { r: 'stock-analysis?k=slow', i: '🐢', l: 'المخزون بطيء الحركة', show: () => S.company && can('inventory', 'view') },
    { r: 'stock-analysis?k=turnover', i: '🔄', l: 'معدل دوران المخزون', show: () => S.company && can('inventory', 'view') },
  ]},
  { title: 'اليوميات', items: Object.entries(DAYBOOKS).map(([k, d]) => ({ r: 'daybook?k=' + k, i: d.icon, l: d.label, show: () => S.company && can('reports', 'view') })) },
  { title: 'قريباً', items: [
 { soon: true, i: '🧾', l: 'الفوترة الإلكترونية (جوفوترة)' },
  ]},
  { title: 'الأدوات', items: [
    { r: 'posting', i: '📮', l: 'الترحيل', show: () => S.company && ['journal_entries', 'sales_invoices', 'purchase_invoices', 'inventory', 'companies'].some(x => can(x, 'post') || can(x, 'unpost') || can(x, 'edit')) },
    { r: 'numbering', i: '🔢', l: 'طريقة الترقيم', show: () => S.company && can('companies', 'edit') },
    { r: 'backup', i: '💾', l: 'النسخ الاحتياطي', show: isAdmin },
    { r: 'print-settings', i: '🖨️', l: 'نماذج الطباعة', show: () => S.company && can('companies', 'edit') },
    { r: 'log', i: '📜', l: 'سجل النشاط', show: isAdmin },
    { r: 'subscription', i: '🎫', l: 'اشتراكي', show: () => isAdmin() && S.sub && !S.sub.is_default },
    { r: 'tenants', i: '🏷️', l: 'إدارة المشتركين', show: isSuper },
  ]},
];

const GROUP_ICONS = { 'الرئيسية': '🏠', 'ملف': '🗂️', 'إعداد': '⚙️', 'المالية': '💰', 'الموظفين والرواتب': '👷', 'الأصول الثابتة': '🏗️', 'المصاريف': '💸', 'المخزون': '📦', 'العملاء والذمم المدينة': '🧑‍💼', 'الموردين والذمم الدائنة': '🏭', 'التقارير': '📊', 'اليوميات': '📚', 'التسويق': '📢', 'التصنيع': '🏭', 'الصيانة': '🔧', 'قريباً': '⏳', 'الأدوات': '🛠️' };
// القائمة الجانبية: العناوين بس، وبالضغط على العنوان بيفتح فرعه (فرع واحد مفتوح بنفس الوقت)
function groupOfRoute(route) {
  const g = NAV().find(g => g.items.some(it => it.r && it.r.split('?')[0] === route));
  return g?.title || null;
}
function setOpenGroup(title) {
  document.querySelectorAll('.nav-group').forEach(el => {
    const on = el.dataset.g === title; el.classList.toggle('open', on);
    el.querySelector('.nav-title')?.setAttribute('aria-expanded', on);
  });
  localStorageSet('sumou.nav.open', title || '');
}

// مستخدم نقطة البيع بس: شاشة الكاشير لحالها بدون قائمة
function renderPosShell() {
  if (location.hash !== '#/pos') history.replaceState(null, '', '#/pos');
  const td = new Date().toLocaleDateString('en-CA');
  if (!(S.fy && !S.fy.is_closed && td >= S.fy.start_date && td <= S.fy.end_date)) S.fy = S.fiscalYears.find(y => !y.is_closed && td >= y.start_date && td <= y.end_date) || S.fy;
  const multi = S.companies.filter(c => c.is_active).length > 1;
  $app.innerHTML = `
    <div class="pos-shell">
      <header class="pos-bar">
        <div class="pb-brand"><img src="icons/icon.svg" alt=""><b>${esc(S.company?.name || APP_NAME)}</b></div>
        <div class="spacer"></div>
        <span class="pb-user">👤 ${esc(S.profile.full_name || S.profile.username || '')}</span>
        ${multi ? '<button class="btn sm" id="pb-co">🏢 تبديل الشركة</button>' : ''}
        <button class="btn sm" id="pb-out">🚪 خروج</button>
      </header>
      ${subBannerHTML()}
      <section class="content pos-content" id="view"></section>
    </div>`;
  document.getElementById('pb-out').onclick = async () => { if (!(await confirmBox('بدك تطلع من الكاشير؟'))) return; await log('خروج', 'auth'); signOutHere(); };
  document.getElementById('pb-co')?.addEventListener('click', () => switchCompanyDialog());
}

function renderShell() {
  if (S.profile?.pos_only) return renderPosShell();
  const route = currentRoute();
  const openGroup = groupOfRoute(route) || localStorageGet('sumou.nav.open') || '';
  const initials = (S.profile.full_name || S.profile.email || '?').trim().charAt(0);
  $app.innerHTML = `
    <div class="layout">
      <aside class="sidebar" id="sidebar">
        <div class="side-brand"><img src="icons/icon.svg" alt=""><b>${APP_NAME}</b></div>
        <nav class="nav">
          ${NAV().map(g => {
            const items = g.items.filter(it => it.soon || !it.show || it.show() || (DEMO() && it.r));
            if (!items.length) return '';
            const open = g.title === openGroup;
            return `<div class="nav-group ${open ? 'open' : ''}" data-g="${esc(g.title)}"><button type="button" class="nav-title" aria-expanded="${open}"><span class="ico">${GROUP_ICONS[g.title] || '📁'}</span>${g.title}<span class="chev">›</span></button>
              <div class="nav-items">${items.map(it => it.soon
                ? `<div class="soon"><span class="ico">${it.i}</span>${it.l}<small>قريباً</small></div>`
                : it.href ? `<a href="${it.href}" target="_blank" rel="noopener"><span class="ico">${it.i}</span>${it.l} ↗</a>`
                : it.act ? `<a href="#" data-act="${it.act}"><span class="ico">${it.i}</span>${it.l}</a>`
                : `<a href="#/${it.r}" class="${('#/' + it.r) === location.hash ? 'active' : ''}"><span class="ico">${it.i}</span>${it.l}</a>`).join('')}
            </div></div>`;
          }).join('')}
        </nav>
        <div class="side-tools">
          <button type="button" data-tool="home" title="الرئيسية"><span>🏠</span><small>الرئيسية</small></button>
          <button type="button" data-tool="company" title="تبديل الشركة"><span>🏢</span><small>تبديل الشركة</small></button>
          <button type="button" data-tool="year" title="تبديل السنة المالية"><span>📅</span><small>تبديل السنة</small></button>
          <button type="button" data-tool="user" title="تبديل المستخدم"><span>👤</span><small>تبديل المستخدم</small></button>
          <button type="button" data-tool="instance" title="مثيل جديد: نافذة جديدة بتسجيل دخول لحاله"><span>🪟</span><small>مثيل جديد</small></button>
          <button type="button" data-tool="exit" title="خروج"><span>🚪</span><small>خروج</small></button>
        </div>
      </aside>
      <div class="main">
        <div class="tabs-head no-print">
          <div class="co-tabs" id="co-tabs">${coTabsHTML()}</div>
          <div class="pg-bar"><div class="pg-nav">
            <button type="button" data-nav="back" title="رجوع للشاشة السابقة">→</button>
            <button type="button" data-nav="fwd" title="للأمام">←</button>
            <button type="button" data-nav="up" title="أزرار مجموعة هالشاشة">▦</button>
            <button type="button" data-nav="home" title="الرئيسية">🏠</button></div>
          <div class="pg-tabs" id="pg-tabs">${pgTabsHTML()}</div></div>
        </div>
        ${subBannerHTML()}
        <section class="content" id="view"></section>
        <div class="watermark" id="watermark" aria-hidden="true"></div>
      </div>
    </div>`;
  updateWatermark();
  document.querySelector('.side-tools').addEventListener('click', async (e) => {
    const t = e.target.closest('[data-tool]')?.dataset.tool; if (!t) return;
    if (t === 'home') location.hash = '#/home';
    if (t === 'company') switchCompanyDialog();
    if (t === 'year') switchYearDialog();
    if (t === 'instance') window.open(location.pathname + '?instance=' + Date.now() + '#/home', '_blank', 'noopener');
    if (t === 'user') { if (!(await confirmBox('تبديل المستخدم؟ رح تطلع من هالحساب وتدخل بحساب ثاني.'))) return; await log('خروج', 'auth', null, { switch: true }); await signOutHere(); }
    if (t === 'exit') {
      if (!(await confirmBox('بدك تطلع من البرنامج؟'))) return;
      await log('خروج', 'auth'); await signOutHere();
      if (INSTANCE) window.close();   // نافذة «مثيل جديد» بتتسكّر
    }
  });
  document.getElementById('co-tabs').addEventListener('click', (e) => {
    if (e.target.closest('#menu-btn')) return document.getElementById('sidebar').classList.toggle('open');
    const x = e.target.closest('[data-close-tab]'); if (x) { e.stopPropagation(); return closeCompanyTab(x.dataset.closeTab); }
    if (e.target.closest('[data-add-tab]')) return switchCompanyDialog();
    const t = e.target.closest('[data-co-tab]'); if (t && t.dataset.coTab !== S.company?.id) activateCompany(t.dataset.coTab);
  });
  document.querySelector('.pg-nav')?.addEventListener('click', (e) => {
    const b = e.target.closest('[data-nav]'); if (!b) return;
    const k = b.dataset.nav;
    if (k === 'back') { if (history.length > 1) history.back(); else location.hash = '#/home'; } else if (k === 'fwd') history.forward(); else if (k === 'home') location.hash = '#/home';
    else {
      const r = curHash().replace(/^#\//, ''), r0 = r.split('?')[0];
      const g = NAV().find(g => g.items.some(it => it.r && (it.r === r || it.r.split('?')[0] === r0)));
      location.hash = g && g.title !== 'الرئيسية' ? `#/home?g=${encodeURIComponent(g.title)}` : '#/home';
    }
  });
  document.getElementById('pg-tabs').addEventListener('click', (e) => {
    const x = e.target.closest('[data-close-pg]'); if (x) { e.stopPropagation(); return closePageTab(x.dataset.closePg); }
    const t = e.target.closest('[data-pg]'); if (t && t.dataset.pg !== location.hash) location.hash = t.dataset.pg;
  });
  document.querySelectorAll('.nav a').forEach(a => a.addEventListener('click', (e) => {
    document.getElementById('sidebar').classList.remove('open');
    if (a.dataset.act === 'year') { e.preventDefault(); switchYearDialog(); }
  }));
  document.querySelectorAll('.nav-title').forEach(b => b.addEventListener('click', () => {
    const g = b.closest('.nav-group'); setOpenGroup(g.classList.contains('open') ? null : g.dataset.g);
  }));
}

// تبديل الشركة من نافذة صغيرة
function switchCompanyDialog() {
  const list = S.companies.filter(c => c.is_active);
  const m = modal({ title: '🏢 تبديل الشركة', body: `<input class="search" id="sc-q" placeholder="بحث بالاسم أو الرمز…" style="width:100%;margin-bottom:10px">
    <div id="sc-list" style="display:grid;gap:6px;max-height:60vh;overflow:auto"></div>`, foot: '<button class="btn" data-close>إلغاء</button>' });
  const draw = () => { const q = m.el.querySelector('#sc-q').value.trim().toLowerCase();
    m.el.querySelector('#sc-list').innerHTML = list.filter(c => !q || [c.code, c.name].some(x => (x || '').toLowerCase().includes(q))).map(c => `
      <button type="button" class="btn ${c.id === S.company?.id ? 'primary' : ''}" data-co="${c.id}" style="justify-content:flex-start;text-align:start">
        <b dir="ltr" style="min-width:42px">${esc(c.code)}</b> ${esc(c.name)}</button>`).join('') || '<div class="empty">ما في شركات</div>'; };
  draw(); m.el.querySelector('#sc-q').oninput = draw; m.el.querySelector('#sc-q').focus();
  m.el.querySelector('#sc-list').onclick = async (e) => {
    const b = e.target.closest('[data-co]'); if (!b) return;
    m.close(); await activateCompany(b.dataset.co);
  };
}

// تبديل السنة المالية: بيدخل على نفس الشاشة بالسنة الجديدة
function switchYearDialog() {
  if (!S.company) return;
  const m = modal({ title: '📅 تبديل السنة المالية', size: 'sm', body: `<div class="notice" style="margin:0 0 10px;font-size:13.5px">⚠️ <b>تنبيه:</b> أنت هلّق على <b>${esc(S.fy ? (S.fy.name || S.fy.code) : '—')}</b>. لما تبدّل، كل شاشات «${esc(S.company.name)}» بتصير على السنة اللي بتختارها.</div><div style="display:grid;gap:6px">${S.fiscalYears.map(y => `
      <button type="button" class="btn ${y.id === S.fy?.id ? 'primary' : ''}" data-fy="${y.id}" style="justify-content:space-between">
        <b>${esc(y.name || y.code)}${y.unavailable ? ' <span class="badge warn">غير متاح</span>' : ''}</b><span class="muted" style="font-size:12px">${fmtDate(y.start_date)} ← ${fmtDate(y.end_date)}${y.is_closed ? ' · مغلقة' : ''}</span></button>`).join('')
      || '<div class="empty">ما في سنوات مالية لهالشركة</div>'}</div>`, foot: '<button class="btn" data-close>إلغاء</button>' });
  m.el.querySelector('.modal-body').addEventListener('click', (e) => {
    const b = e.target.closest('[data-fy]'); if (!b) return;
    m.close();
    S.fy = S.fiscalYears.find(y => y.id === b.dataset.fy) || null;
    localStorageSet('sumou.fy.' + S.company.id, S.fy?.id);
    updateWatermark(); route_();
    toast('صرت على ' + (S.fy?.name || S.fy?.code || ''), 'ok');
  });
}

// ---------------------------------------------------------------------
//  تبويبات الشركات (مثل تبويبات كروم): كل شركة مفتوحة إلها تبويب، وكل تبويب بيتذكّر صفحته
// ---------------------------------------------------------------------
const TABS_KEY = 'sumou.cotabs' + (INSTANCE ? '.' + INSTANCE : '');
function tabsLoad() {
  let t; try { t = JSON.parse((INSTANCE ? sessionStorage : localStorage).getItem(TABS_KEY) || 'null'); } catch { t = null; }
  t = t && Array.isArray(t.ids) ? t : { ids: [], hash: {} };
  t.hash = t.hash || {};
  t.ids = t.ids.filter(id => S.companies.some(c => c.id === id && c.is_active));
  if (S.company && !t.ids.includes(S.company.id)) t.ids.push(S.company.id);
  return t;
}
function tabsSave(t) { try { (INSTANCE ? sessionStorage : localStorage).setItem(TABS_KEY, JSON.stringify(t)); } catch {} }
function coTabsHTML() {
  const menu = `<button type="button" class="co-menu" id="menu-btn" title="القائمة">☰</button>`;
  if (!S.company) return menu;
  const t = tabsLoad(); tabsSave(t);
  return menu + t.ids.map(id => { const c = S.companies.find(x => x.id === id); return `<div class="co-tab ${id === S.company.id ? 'active' : ''}" data-co-tab="${id}" title="${esc(c.name)}">
      <span class="co-code" dir="ltr">${esc(c.code)}</span><span class="co-name">${esc(c.name)}</span>
      ${t.ids.length > 1 ? `<button type="button" class="co-x" data-close-tab="${id}" title="سكّر التبويب">×</button>` : ''}</div>`; }).join('')
    + `<button type="button" class="co-add" data-add-tab title="فتح شركة بتبويب جديد">＋</button>`;
}
async function activateCompany(id, closing = false) {
  if (closing) S.company = null;   // الشركة المسكّرة ما ترجع تنضاف للتبويبات
  const t = tabsLoad();
  if (S.company) t.hash[S.company.id] = location.hash || '#/home';
  if (!t.ids.includes(id)) t.ids.push(id);
  tabsSave(t);
  S.company = S.companies.find(c => c.id === id) || null;
  localStorageSet('sumou.company', S.company?.id);
  document.getElementById('modal-root').innerHTML = '';
  await loadFiscalYears(); renderShell();
  const h = t.hash[id] || '#/home';
  if (location.hash !== h) location.hash = h; else route_();
}
// تبويبات الشاشات جوّا كل شركة: كل شاشة بتنفتح إلها تبويب
const PG_MAX = 12;
const curHash = () => { const h = location.hash; return !h || h === '#' || h === '#/' ? '#/home' : h; };
function navInfo(hash) {
  const items = NAV().flatMap(g => g.items).filter(it => it.r);
  const exact = items.find(it => '#/' + it.r === hash);
  const base = exact || items.find(it => ('#/' + it.r).split('?')[0] === hash.split('?')[0]);
  return base ? { l: base.l, i: base.i } : null;
}
function pgTabsHTML() {
  if (!S.company) return '';
  const t = tabsLoad(); const list = (t.pages || {})[S.company.id] || [];
  const cur = curHash();
  return list.map(p => `<div class="pg-tab ${p.h === cur ? 'active' : ''}" data-pg="${esc(p.h)}" title="${esc(p.l)}">
      <span>${esc(p.i || '📄')}</span><span class="pg-name">${esc(p.l)}</span>
      <button type="button" class="co-x" data-close-pg="${esc(p.h)}" title="سكّر">×</button></div>`).join('');
}
function notePageTab() {
  if (!S.company) return;
  const h = curHash().startsWith('#/home?') ? '#/home' : curHash();   // أزرار المجموعات جوّا نفس تبويب الرئيسية
  const t = tabsLoad(); t.pages = t.pages || {};
  const list = t.pages[S.company.id] = t.pages[S.company.id] || [];
  const info = navInfo(h) || { l: (document.querySelector('#view .page-head h2')?.textContent || 'شاشة').replace(/^[^\p{L}]+/u, '').trim().slice(0, 40), i: '📄' };
  const p = list.find(x => x.h === h);
  if (p) Object.assign(p, info); else list.push({ h, ...info });
  while (list.length > PG_MAX) { const k = list.findIndex(x => x.h !== h); list.splice(k, 1); }
  tabsSave(t);
  const el = document.getElementById('pg-tabs'); if (el) el.innerHTML = pgTabsHTML();
  el?.querySelector('.pg-tab.active')?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
}
function closePageTab(h) {
  const t = tabsLoad(); const list = (t.pages || {})[S.company.id] || [];
  const i = list.findIndex(x => x.h === h); if (i < 0) return;
  list.splice(i, 1); tabsSave(t);
  if (h === curHash()) location.hash = (list[Math.max(0, i - 1)] || { h: '#/home' }).h;
  else document.getElementById('pg-tabs').innerHTML = pgTabsHTML();
}
async function closeCompanyTab(id) {
  const t = tabsLoad(); if (t.ids.length < 2) return;
  const c = S.companies.find(x => x.id === id);
  if (id === S.company?.id && hasUnsavedModal()) return toast('ما بتقدر تسكّر الشركة: في سند مفتوح ومش محفوظ. احفظه أو سكّره أول', 'err');
  let posCart = []; try { posCart = JSON.parse(localStorageGet('sumou.pos.cart.' + id) || '[]') || []; } catch {}
  if (posCart.length) return toast(`ما بتقدر تسكّر «${c?.name || ''}»: في فاتورة بنقطة البيع مش مكمّلة (${posCart.length} صنف). كمّلها أو فرّغها أول`, 'err');
  if (!(await confirmBox(`بدك تسكّر «${c?.name || ''}» وكل شاشاتها المفتوحة؟`))) return;
  const i = t.ids.indexOf(id); t.ids.splice(i, 1); delete t.hash[id]; if (t.pages) delete t.pages[id]; tabsSave(t);
  if (id === S.company?.id) activateCompany(t.ids[Math.max(0, i - 1)], true);
  else document.getElementById('co-tabs').innerHTML = coTabsHTML();
}

// علامة مائية على الخلفية: اسم الشركة والسنة المالية الحالية
function updateWatermark() {
  const wm = document.getElementById('watermark'); if (!wm) return;
  if (!S.company) { wm.innerHTML = ''; return; }
  const year = S.fy ? (S.fy.name || S.fy.code) : '';
  const who = S.profile?.full_name || S.profile?.username || (S.profile?.email || '').split('@')[0];
  wm.innerHTML = `<div class="wm-inner"><div class="wm-name">${esc(S.company.name)}</div>${year ? `<div class="wm-year">${esc(year)}</div>` : ''}${who ? `<div class="wm-user">${esc(who)}</div>` : ''}</div>`;
}

function currentRoute() { return (location.hash.replace(/^#\/?/, '').split('?')[0]) || 'home'; }

const ROUTES = {
  ...FINANCE_ROUTES, ...REPORT_ROUTES, ...PARTY_ROUTES, ...INVOICE_ROUTES, ...OBLIGATION_ROUTES, ...CHEQUE_ROUTES, ...INVENTORY_ROUTES, ...PRINTSET_ROUTES, ...NUMBERING_ROUTES, ...POSTING_ROUTES, ...CENTER_ROUTES, ...DEPARTMENT_ROUTES, ...LOOKUP_ROUTES, ...DAYBOOK_ROUTES, ...ORDER_ROUTES, ...MFG_ROUTES, ...EXTRA_ROUTES, ...PAYROLL_ROUTES, ...ASSET_ROUTES, ...SUPPLY_ROUTES, ...ASK_ROUTES, ...REP_ROUTES, ...LOAN_ROUTES, ...ATTENDANCE_ROUTES, ...DOCTYPE_ROUTES, ...PRICE_ROUTES, ...DISCOUNT_ROUTES, ...MESSAGE_ROUTES, ...LANDED_ROUTES, ...LEAVE_ROUTES, ...PROFILE_ROUTES, ...BATCH_ROUTES, ...BUDGET_ROUTES, ...NOTE_ROUTES, ...CONTRACT_ROUTES, ...COLLECTION_ROUTES, ...COMMISSION_ROUTES, ...FOLLOW_ROUTES, ...PARTYDOC_ROUTES, ...COMPARE_ROUTES, ...TOOLS_ROUTES, ...TENANT_ROUTES, ...POS_ROUTES,
  'home': viewHome, 'company': viewCompany, 'companies': viewCompanies,
  'fiscal-years': viewFiscalYears, 'users': viewUsers, 'groups': viewGroups, 'log': viewLog,
};

async function route_() {
  if (S.profile?.pos_only && currentRoute() !== 'pos') { location.hash = '#/pos'; return; }
  const r = currentRoute();
  const fullHash = location.hash || '#/';
  const exact = [...document.querySelectorAll('.nav a')].some(a => a.getAttribute('href') === fullHash);
  document.querySelectorAll('.nav a').forEach(a => a.classList.toggle('active', exact ? a.getAttribute('href') === fullHash : a.getAttribute('href').split('?')[0] === '#/' + r));
  const og = document.querySelector('.nav a.active')?.closest('.nav-group')?.dataset.g || groupOfRoute(r); if (og && !document.querySelector(`.nav-group.open[data-g="${CSS.escape(og)}"]`)) setOpenGroup(og);
  if (S.company) { const t = tabsLoad(); t.hash[S.company.id] = location.hash || '#/home'; tabsSave(t); }
  const view = document.getElementById('view'); if (!view) return;
  view.innerHTML = '<div class="empty">جاري التحميل…</div>';
  if (DEMO() && !NO_CO_ROUTES.has(r) && ROUTES[r]) { viewNeedCompany(view, r); try { notePageTab(); } catch {} return; }
  try { await (ROUTES[r] || viewHome)(view, { rerender: route_, renderShell }); try { enhanceReportTables(view, location.hash.slice(2)); } catch {} try { notePageTab(); } catch {} }
  catch (err) { view.innerHTML = `<div class="notice">${esc(arError(err))}</div>`; }
}
window.addEventListener('hashchange', () => { document.getElementById('modal-root').innerHTML = ''; if (S.profile?.is_active) route_(); });

// ---------------------------------------------------------------------
//  لوحة التحكم
// ---------------------------------------------------------------------
// الواجهة الرئيسية: مجموعات القائمة كأزرار كبيرة، والكبسة بتفتح فروعها
function launcherHTML() {
  const gsel = new URLSearchParams(location.hash.split('?')[1] || '').get('g');
  const groups = NAV().filter(g => g.title !== 'الرئيسية').map(g => ({ ...g, items: g.items.filter(it => !it.soon && (!it.show || it.show() || (DEMO() && it.r))) })).filter(g => g.items.length);
  const g = gsel && groups.find(x => x.title === gsel);
  if (g) return `<div class="launch-head"><a class="btn" href="#/home">→ رجوع</a><h3><span>${GROUP_ICONS[g.title] || '📁'}</span> ${esc(g.title)}</h3></div>
    <div class="launch-grid">${g.items.map(it => it.href ? `<a class="launch-tile sub" href="${it.href}" target="_blank" rel="noopener"><span class="li">${it.i}</span><b>${it.l}</b></a>`
      : it.act ? `<a class="launch-tile sub" href="#" data-act="${it.act}"><span class="li">${it.i}</span><b>${it.l}</b></a>`
      : `<a class="launch-tile sub" href="#/${it.r}"><span class="li">${it.i}</span><b>${it.l}</b></a>`).join('')}</div>`;
  return `<div class="launch-grid">${groups.map(x => `<a class="launch-tile" href="#/home?g=${encodeURIComponent(x.title)}"><span class="li">${GROUP_ICONS[x.title] || '📁'}</span><b>${esc(x.title)}</b><small>${x.items.length} شاشة</small></a>`).join('')}</div>`;
}
function wireLauncher(v) {
  v.querySelectorAll('.launch-tile[data-act]').forEach(a => a.onclick = (e) => { e.preventDefault(); if (a.dataset.act === 'year') switchYearDialog(); });
}

async function viewHome(v) {
  if (!S.company) {
    v.innerHTML = `<div class="page-head"><h2>أهلاً ${esc(S.profile.full_name || '')} 👋</h2></div>
      <div class="notice info">${isAdmin()
        ? 'ما في شركات لسا. ابدأ بإضافة أول شركة من <a href="#/companies">الشركات</a>.'
        : 'ما عندك صلاحية على أي شركة لسا. تواصل مع مدير النظام.'}</div>
      ${isAdmin() ? '<button class="btn primary" id="first-co" style="margin-top:12px;font-size:17px;padding:12px 22px">➕ إضافة شركة جديدة</button>' : ''}
      <div style="margin-top:16px">${launcherHTML()}</div>`;
    v.querySelector('#first-co')?.addEventListener('click', () => openCompanyForm(null)); wireLauncher(v);
    return;
  }
  const tw = localStorageGet('sumou.trialWelcome');
  if (tw) {
    localStorageSet('sumou.trialWelcome', '');
    try { const w = JSON.parse(tw); setTimeout(() => modal({ title: '🎉 حسابك التجريبي جاهز', size: 'sm',
      body: `<p>شركتك التجريبية جاهزة وفيها بيانات للتجربة. جرّب الفواتير والسندات والتقارير براحتك.</p>
        <p>احفظ هالمعلومات عشان تدخل مرة ثانية:</p>
        <div class="card" style="font-size:18px;line-height:2"><div>رمز المشترك: <b dir="ltr">${esc(w.code)}</b></div><div>اسم المستخدم: <b dir="ltr">${esc(w.username)}</b></div></div>
        <p class="muted">التجربة لحد ${fmtDate(w.expires_at)}.</p>`,
      foot: '<button class="btn primary" data-close>يلا نبلّش</button>' }), 300); } catch {}
  }
  const c = S.company;
  if (new URLSearchParams(location.hash.split('?')[1] || '').get('g')) { v.innerHTML = launcherHTML(); wireLauncher(v); return; }
  v.innerHTML = `
    <div class="page-head"><h2>${esc(c.name)}</h2><span class="badge brand">${esc(c.code)}</span></div>
    ${launcherHTML()}
    <div class="grid cols-4" style="margin-top:16px">
      <div class="card stat"><span class="k">السنة المالية الحالية</span><span class="v" style="font-size:18px">${esc(S.fy ? (S.fy.name || S.fy.code) : '—')}</span>
        <span class="muted">${S.fy ? fmtDate(S.fy.start_date) + ' ← ' + fmtDate(S.fy.end_date) : 'ما في سنة مالية'}</span>
        ${S.fiscalYears.length ? '<button class="btn sm" id="home-fy" style="margin-top:8px;align-self:flex-start">🔄 تبديل السنة المالية</button>' : ''}</div>
      <div class="card stat"><span class="k">نوع الشركة</span><span class="v" style="font-size:18px">${esc(c.company_type || '—')}</span></div>
      <div class="card stat"><span class="k">ضريبة المبيعات</span><span class="v" style="font-size:18px">${c.subject_to_sales_tax ? 'خاضعة' : 'غير خاضعة'}</span>
        <span class="muted">${c.subject_to_sales_tax ? (c.sales_tax_period === 'monthly' ? 'إقرار شهري' : 'إقرار كل شهرين') : ''}</span></div>
      <div class="card stat"><span class="k">عدد الشركات المتاحة</span><span class="v">${S.companies.filter(x => x.is_active).length}</span></div>
    </div>
    <div id="ob-sum"></div><div id="dash"></div>
    ${!S.fy && can('fiscal_years', 'add') ? `<div class="notice" style="margin-top:14px">هالشركة ما إلها سنة مالية. <a href="#/fiscal-years">أضف سنة مالية</a> قبل ما تبلّش القيود.</div>` : ''}
    <div class="card" style="margin-top:14px">
      <h3 style="margin-top:0">ابدأ من هون</h3>
      <div style="display:flex;gap:8px;flex-wrap:wrap">
        ${can('accounts', 'view') ? '<a class="btn" href="#/accounts">🌳 دليل الحسابات</a>' : ''}
        ${can('opening_balances', 'view') ? '<a class="btn" href="#/opening">🧮 الأرصدة الافتتاحية</a>' : ''}
        ${can('journal_entries', 'add') ? '<a class="btn" href="#/journal">📒 سند قيد</a>' : ''}
        ${can('receipt_vouchers', 'add') ? '<a class="btn" href="#/receipts">📥 سند قبض</a>' : ''}
        ${can('payment_vouchers', 'add') ? '<a class="btn" href="#/payments">📤 سند صرف</a>' : ''}
        ${can('reports', 'view') ? '<a class="btn" href="#/rep-trial">⚖️ ميزان المراجعة</a>' : ''}
      </div>
    </div>`;
  v.querySelector('#home-fy')?.addEventListener('click', switchYearDialog); wireLauncher(v);
  // لون الواجهة: كل مستخدم بيختار لونه (إذا المدير سامحله من الصلاحيات)
  if (canTheme()) {
    const cur = S.profile?.theme || 'purple';
    const box = document.createElement('div'); box.className = 'card'; box.style.marginTop = '14px';
    box.innerHTML = `<h3 style="margin-top:0">🎨 لون الواجهة</h3><div class="theme-sw">${THEMES.map(t => `<button type="button" data-th="${t.key}" class="${t.key === cur ? 'on' : ''}"><i style="background:${t.c}"></i>${esc(t.label)}</button>`).join('')}</div>`;
    v.appendChild(box);
    box.onclick = async (e) => {
      const b = e.target.closest('[data-th]'); if (!b) return;
      applyTheme(b.dataset.th); box.querySelectorAll('[data-th]').forEach(x => x.classList.toggle('on', x === b));
      const { error } = await sb.from('profiles').update({ theme: b.dataset.th }).eq('id', S.profile.id);
      if (error) return toast(arError(error), 'err');
      S.profile.theme = b.dataset.th; toast('تغيّر اللون', 'ok');
    };
  }
  { const pb = document.createElement('div'); pb.style.marginTop = '10px'; pb.innerHTML = '<button class="btn" id="my-pw">🔑 تغيير كلمة السر</button>'; v.appendChild(pb); pb.querySelector('#my-pw').onclick = () => changePasswordDialog(); }
  dashboardPanel(v.querySelector('#dash')).catch(() => {});
  if (S.companies.some(c => can('obligations', 'view', c.id))) {
    obligationsSummary().then(({ late, soon }) => { const el = v.querySelector('#ob-sum'); if (!el || (!late && !soon)) return;
      el.innerHTML = `<a href="#/obligations" class="notice ${late ? '' : 'info'}" style="display:block;margin-top:14px;text-decoration:none">🔔 متابعة الإقرارات: ${late ? `<b>${late} متأخرة</b>` : ''}${late && soon ? ' و' : ''}${soon ? `<b>${soon}</b> خلال 14 يوم` : ''} — اضغط للتفاصيل</a>`; }).catch(() => {});
  }
}

// ---------------------------------------------------------------------
//  نموذج الشركة (مشترك بين "بيانات الشركة" و"الشركات")
// ---------------------------------------------------------------------
function companyFormHTML(c = {}, readOnly = false) {
  const ro = readOnly ? 'disabled' : '';
  const opt = (list, val) => `<option value="">— اختار —</option>` + list.map(x => `<option ${x === val ? 'selected' : ''}>${esc(x)}</option>`).join('');
  return `
  <form id="company-form">
    <div class="tabs">
      <div class="tab active" data-tab="general">عام</div>
      <div class="tab" data-tab="tax">الضرائب والتسجيل</div>
      <div class="tab" data-tab="contact">العنوان والاتصال</div>
      <div class="tab" data-tab="logo">الشعار</div>
      <div class="tab" data-tab="notes">ملاحظات</div>
    </div>
    <div class="tab-panel active" data-tab="general">
      <div class="grid cols-2">
        <div class="field"><label>رمز الشركة *</label>${S._coAuto ? `<input value="${esc(c.code || 'تلقائي')}" disabled dir="ltr"><span class="hint">الترقيم تلقائي (01، 02…) — بيتغيّر من «طريقة الترقيم ← الشركات»</span>` : `<input name="code" required value="${esc(c.code)}" ${ro} dir="ltr"><span class="hint">ترقيم يدوي: اكتب رمز ما بيتكرر</span>`}</div>
        <div class="field"><label>اسم الشركة *</label><input name="name" required value="${esc(c.name)}" ${ro}></div>
        <div class="field"><label>الاسم القانوني</label><input name="legal_name" value="${esc(c.legal_name)}" ${ro}></div>
        <div class="field"><label>الاسم التجاري</label><input name="trade_name" value="${esc(c.trade_name)}" ${ro}></div>
        <div class="field"><label>الاسم بالإنجليزي (للفاتورة الثنائية)</label><input name="name_en" value="${esc(c.name_en || '')}" dir="ltr" ${ro}></div>
        <div class="field"><label>نوع الشركة</label><select name="company_type" ${ro}>${opt(COMPANY_TYPES, c.company_type)}</select></div>
        <div class="field"><label>نوع النشاط</label><select name="activity_type" ${ro}>${opt(ACTIVITY_TYPES, c.activity_type)}</select></div>
        <div class="field"><label>العملة</label><select name="currency" ${ro}>
          ${[['JOD','دينار أردني'],['USD','دولار أمريكي'],['EUR','يورو'],['SAR','ريال سعودي'],['AED','درهم إماراتي']].map(([k,l]) => `<option value="${k}" ${(c.currency || 'JOD') === k ? 'selected' : ''}>${l}</option>`).join('')}
        </select></div>
      </div>
      <label class="check"><input type="checkbox" name="is_active" ${c.is_active !== false ? 'checked' : ''} ${ro || (!isAdmin() ? 'disabled' : '')}> الشركة فعّالة</label>
    </div>
    <div class="tab-panel" data-tab="tax">
      <div class="grid cols-2">
        <div class="field"><label>الرقم الوطني للمنشأة</label><input name="national_no" value="${esc(c.national_no)}" ${ro} dir="ltr"></div>
        <div class="field"><label>رقم السجل التجاري</label><input name="commercial_reg_no" value="${esc(c.commercial_reg_no)}" ${ro} dir="ltr"></div>
        <div class="field"><label>الرقم الضريبي (ضريبة الدخل)</label><input name="income_tax_no" value="${esc(c.income_tax_no)}" ${ro} dir="ltr"></div>
        <div class="field"><label>رقم ضريبة المبيعات</label><input name="sales_tax_no" value="${esc(c.sales_tax_no)}" ${ro} dir="ltr"></div>
        <div class="field"><label>دورية إقرار ضريبة المبيعات</label><select name="sales_tax_period" ${ro}>
          <option value="bimonthly" ${c.sales_tax_period !== 'monthly' ? 'selected' : ''}>كل شهرين</option>
          <option value="monthly" ${c.sales_tax_period === 'monthly' ? 'selected' : ''}>شهري</option></select></div>
        <div></div>
        <div class="field"><label>رمز الاستيراد</label><input name="import_code" value="${esc(c.import_code)}" ${ro} dir="ltr"></div>
        <div class="field"><label>رمز التصدير</label><input name="export_code" value="${esc(c.export_code)}" ${ro} dir="ltr"></div>
      </div>
      <label class="check"><input type="checkbox" name="subject_to_sales_tax" ${c.subject_to_sales_tax ? 'checked' : ''} ${ro}> خاضعة لضريبة المبيعات</label>
    </div>
    <div class="tab-panel" data-tab="contact">
      <div class="grid cols-2">
        <div class="field"><label>المدينة</label><input name="city" value="${esc(c.city)}" ${ro}></div>
        <div class="field"><label>العنوان</label><input name="address" value="${esc(c.address)}" ${ro}></div>
        <div class="field"><label>الهاتف</label><input name="phone" value="${esc(c.phone)}" ${ro} dir="ltr"></div>
        <div class="field"><label>الموبايل</label><input name="mobile" value="${esc(c.mobile)}" ${ro} dir="ltr"></div>
        <div class="field"><label>الإيميل</label><input name="email" type="email" value="${esc(c.email)}" ${ro} dir="ltr"></div>
        <div class="field"><label>الموقع الإلكتروني</label><input name="website" value="${esc(c.website)}" ${ro} dir="ltr"></div>
        <div class="field"><label>العنوان بالإنجليزي</label><input name="address_en" value="${esc(c.address_en || '')}" ${ro} dir="ltr"></div>
      </div>
    </div>
    <div class="tab-panel" data-tab="logo">
      <div style="display:flex;gap:16px;align-items:center;flex-wrap:wrap">
        <div class="logo-preview" id="logo-preview">${c.logo_url ? `<img src="${esc(c.logo_url)}" alt="">` : '<span class="muted">بدون شعار</span>'}</div>
        <div style="flex:1;min-width:220px">
          <div class="field"><label>رابط الشعار</label><input name="logo_url" value="${esc(c.logo_url)}" ${ro} dir="ltr" placeholder="https://..."></div>
          ${!readOnly ? `<div class="field"><label>أو اختار صورة من جهازك (أقل من 300 كيلوبايت)</label><input type="file" id="logo-file" accept="image/*"></div>` : ''}
        </div>
      </div>
    </div>
    <div class="tab-panel" data-tab="notes">
      <div class="field"><label>ملاحظات</label><textarea name="notes" ${ro}>${esc(c.notes)}</textarea></div>
    </div>
  </form>`;
}

function wireLogo(root) {
  const file = root.querySelector('#logo-file'); if (!file) return;
  const urlInput = root.querySelector('[name=logo_url]');
  const preview = root.querySelector('#logo-preview');
  const show = (src) => preview.innerHTML = src ? `<img src="${esc(src)}" alt="">` : '<span class="muted">بدون شعار</span>';
  urlInput.addEventListener('input', () => show(urlInput.value));
  file.onchange = () => {
    const f = file.files[0]; if (!f) return;
    if (f.size > 300 * 1024) { toast('الصورة كبيرة، اختار صورة أقل من 300 كيلوبايت', 'err'); file.value = ''; return; }
    const rd = new FileReader();
    rd.onload = () => { urlInput.value = rd.result; show(rd.result); };
    rd.readAsDataURL(f);
  };
}

async function saveCompany(form, id) {
  const d = formData(form);
  if ((!S._coAuto && !d.code) || !d.name) { toast('رمز الشركة واسمها مطلوبين', 'err'); return null; }
  if (S._coAuto) delete d.code;
  if (!isAdmin()) delete d.is_active;
  let res;
  if (id) res = await sb.from('companies').update(d).eq('id', id).select().single();
  else res = await sb.from('companies').insert({ ...d, created_by: S.session.user.id }).select().single();
  if (res.error) { toast(arError(res.error), 'err'); return null; }
  await log(id ? 'تعديل' : 'إضافة', 'companies', res.data.id, { code: res.data.code, name: d.name });
  toast('تم الحفظ', 'ok');
  return res.data;
}

// ---------------------------------------------------------------------
//  بيانات الشركة الحالية
// ---------------------------------------------------------------------
async function viewCompany(v, ctx, editing = false) {
  if (editing) { const cr = await sb.rpc('company_numbering'); S._coAuto = !cr.error && (cr.data || { mode: 'auto' }).mode !== 'manual'; }
  if (!S.company) return viewHome(v);
  const editable = can('companies', 'edit');
  editing = editing && editable;
  v.innerHTML = `
    <div class="page-head"><h2>بيانات الشركة</h2>${editing ? '<span class="badge warn">وضع التعديل</span>' : ''}<div class="spacer"></div>
      ${isAdmin() && !editing ? `<button class="btn no-print" id="new">➕ شركة جديدة</button>` : ''}
      ${can('companies', 'print') && !editing ? `<button class="btn no-print" id="print">🖨️ طباعة</button>` : ''}
      ${editable && !editing ? `<button class="btn primary no-print" id="edit">✏️ تعديل</button>` : ''}
      ${editing ? `<button class="btn no-print" id="cancel">إلغاء</button><button class="btn primary no-print" id="save">💾 حفظ</button>` : ''}</div>
    <div class="card">${companyFormHTML(S.company, !editing)}</div>`;
  setupTabs(v); if (editing) wireLogo(v);
  v.querySelector('#print')?.addEventListener('click', () => { v.querySelectorAll('.tab-panel').forEach(p => p.classList.add('active')); window.print(); v.querySelectorAll('.tab-panel:not([data-tab=general])').forEach(p => p.classList.remove('active')); });
  v.querySelector('#new')?.addEventListener('click', () => openCompanyForm(null));
  v.querySelector('#edit')?.addEventListener('click', () => viewCompany(v, ctx, true));
  v.querySelector('#cancel')?.addEventListener('click', () => viewCompany(v, ctx, false));
  v.querySelector('#save')?.addEventListener('click', async () => {
    const saved = await saveCompany(v.querySelector('#company-form'), S.company.id);
    if (saved) { Object.assign(S.company, saved); const i = S.companies.findIndex(c => c.id === saved.id); if (i > -1) S.companies[i] = saved; renderShell(); route_(); }
  });
}

// نموذج شركة جديدة أو تعديل شركة (نافذة)
// رمز الشركة الجاي: تلقائي بخانتين 01، 02، 03… (وبتقدر تكتبه يدوي)
async function nextCompanyCode() {
  const { data } = await sb.from('companies').select('code');
  const nums = (data || []).map(x => String(x.code || '').trim()).filter(x => /^\d+$/.test(x)).map(Number);
  return String((nums.length ? Math.max(...nums) : 0) + 1).padStart(2, '0');
}

async function openCompanyForm(c) {
  const cr = await sb.rpc('company_numbering'); const cn = cr.error ? { mode: 'manual' } : (cr.data || { mode: 'auto', digits: 2 });
  S._coAuto = cn.mode !== 'manual';
  if (!c) c = { code: S._coAuto ? '' : await nextCompanyCode(), is_active: true, currency: 'JOD' };
  const isNew = !c.id;
  const m = modal({ title: !isNew ? 'تعديل شركة: ' + c.name : 'شركة جديدة', body: companyFormHTML(c),
    foot: `<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>` });
  setupTabs(m.el); wireLogo(m.el);
  m.el.querySelector('[data-save]').onclick = async () => {
    const saved = await saveCompany(m.el.querySelector('#company-form'), c.id);
    if (saved) { m.close(); await loadContext(); if (!S.company) S.company = saved; renderShell(); route_(); }
  };
}

// ---------------------------------------------------------------------
//  الشركات (للمدير)
// ---------------------------------------------------------------------
async function viewCompanies(v) {
  if (!isAdmin()) return viewHome(v);
  const { data, error } = await sb.from('companies').select('*').order('code');
  if (error) throw error;
  v.innerHTML = `
    <div class="page-head"><h2>الشركات</h2><span class="badge brand">${data.length}</span><div class="spacer"></div>
      <input class="search" id="q" placeholder="بحث بالاسم أو الرمز أو الرقم الضريبي…">
      <button class="btn primary" id="add">➕ شركة جديدة</button></div>
    <div class="card table-wrap"><table class="t">
      <thead><tr><th>الرمز</th><th>اسم الشركة</th><th>النوع</th><th>الرقم الضريبي</th><th>ضريبة المبيعات</th><th>الحالة</th><th></th></tr></thead>
      <tbody id="rows"></tbody></table></div>`;
  const draw = (q = '') => {
    const rows = data.filter(c => !q || [c.code, c.name, c.legal_name, c.income_tax_no, c.sales_tax_no].some(x => (x || '').toLowerCase().includes(q.toLowerCase())));
    v.querySelector('#rows').innerHTML = rows.map(c => `
      <tr><td dir="ltr" style="text-align:right">${esc(c.code)}</td><td><b>${esc(c.name)}</b><div class="muted" style="font-size:12px">${esc(c.legal_name || '')}</div></td>
      <td>${esc(c.company_type || '')}</td><td dir="ltr" style="text-align:right">${esc(c.income_tax_no || '')}</td>
      <td>${c.subject_to_sales_tax ? '<span class="badge brand">خاضعة</span>' : '<span class="muted">—</span>'}</td>
      <td>${c.is_active ? '<span class="badge ok">فعّالة</span>' : '<span class="badge bad">موقوفة</span>'}</td>
      <td class="actions"><button class="btn sm" data-edit="${c.id}">تعديل</button> <button class="btn sm danger" data-del="${c.id}">حذف</button>${isSuper() ? ` <button class="btn sm" data-tpl="${c.id}" title="كل مشترك تجريبي بياخذ نسخة من هالشركة">🧪 قالب التجربة</button>` : ''}</td></tr>`).join('')
      || `<tr><td colspan="7" class="empty">ما في شركات</td></tr>`;
  };
  draw();
  v.querySelector('#q').oninput = (e) => draw(e.target.value);
  const open = openCompanyForm;
  v.querySelector('#add').onclick = () => open(null);
  v.querySelector('#rows').onclick = async (e) => {
    const ed = e.target.closest('[data-edit]'), dl = e.target.closest('[data-del]');
    if (ed) open(data.find(x => x.id === ed.dataset.edit));
    const tp = e.target.closest('[data-tpl]');
    if (tp) {
      const c = data.find(x => x.id === tp.dataset.tpl);
      if (!(await confirmBox(`اعتماد «${c.name}» قالب للتجربة المجانية؟ كل حدا بيسجّل تجربة جديدة بياخذ نسخة من بياناتها الحالية (عملاء، أصناف، فواتير، قيود). ما تحط فيها بيانات حقيقية لزبون.`))) return;
      const r = await sb.rpc('super_set_demo_template', { p_company: c.id });
      return r.error ? toast(arError(r.error), 'err') : toast('صارت قالب التجربة ✅', 'ok');
    }
    if (dl) {
      const c = data.find(x => x.id === dl.dataset.del);
      const { data: act, error: ae } = await sb.rpc('company_activity', { p_company: c.id });
      if (ae) return toast(arError(ae), 'err');
      const keys = Object.entries(act || {});
      if (keys.length) {
        modal({ title: `ما بتنحذف: ${c.name}`, size: 'sm', body: `<p>الشركة فيها حركات، فما بتنحذف. إذا ما عاد بدك ياها <b>أوقفها</b> من «تعديل» (بتختفي من القوائم وبتضل بياناتها محفوظة).</p>
          <ul>${keys.map(([k, n]) => `<li>${esc(k)}: <b>${n}</b></li>`).join('')}</ul>`, foot: '<button class="btn" data-close>تمام</button>' });
        return;
      }
      if (!(await confirmBox(`الشركة «${c.name}» ما فيها ولا حركة. متأكد بدك تحذفها نهائياً؟ (دليل الحسابات والبطاقات اللي فيها بتنحذف معها)`))) return;
      const { error } = await sb.from('companies').delete().eq('id', c.id);
      if (error) return toast(arError(error), 'err');
      await log('حذف', 'companies', c.id, { code: c.code, name: c.name });
      toast('تم الحذف', 'ok'); await loadContext(); renderShell(); route_();
    }
  };
}

// ---------------------------------------------------------------------
//  السنوات المالية
// ---------------------------------------------------------------------
// فترات السنة: قفل للمالية/للمخزون، وقفل لكل قسم (locked_sections)
const PERIOD_SECTIONS = [['sales', 'المبيعات'], ['purchases', 'المشتريات'], ['receipts', 'القبض'], ['payments', 'الصرف'], ['journal', 'القيود'],
  ['cheques', 'الشيكات'], ['payroll', 'الرواتب'], ['assets', 'الأصول'], ['stock_docs', 'سندات المخزون'], ['orders', 'الطلبات']];
async function periodsDialog(y) {
  const load = async () => (await sb.from('fiscal_periods').select('*').eq('fiscal_year_id', y.id).order('start_date')).data || [];
  let rows = await load();
  const canLock = can('fiscal_years', 'edit'), canOpen = isAdmin() || can('fiscal_years', 'unpost');
  const m = modal({ title: `📆 فترات ${y.name || y.code}`, body: '<div id="pd"></div>', foot: '<button class="btn" data-close>إغلاق</button>' });
  m.el.querySelector('.modal').style.maxWidth = '1180px';
  const box = m.el.querySelector('#pd');
  const isOn = (p, k) => k.startsWith('s:') ? (p.locked_sections || []).includes(k.slice(2)) : !!p[k];
  const patch = (p, k, on) => {
    if (!k.startsWith('s:')) return { [k]: on };
    const set = new Set(p.locked_sections || []); on ? set.add(k.slice(2)) : set.delete(k.slice(2));
    return { locked_sections: [...set] };
  };
  const cols = [['gl_locked', 'المالية (الترحيل)'], ['stock_locked', 'حركات المخزون'], ...PERIOD_SECTIONS.map(([k, l]) => ['s:' + k, l])];
  const cb = 'style="width:17px;height:17px;accent-color:var(--brand)"';
  const draw = () => {
    box.innerHTML = rows.length ? `
      <div class="table-wrap"><table class="t" style="font-size:13px"><thead><tr><th>#</th><th>الفترة</th><th>من — إلى</th>
        ${cols.map(([k, l], i) => { const all = rows.every(p => isOn(p, k)); return `<th style="text-align:center;white-space:normal;min-width:62px;${i === 2 ? 'border-inline-start:2px solid var(--line)' : ''}">${l}
          ${canLock && (!all || canOpen) ? `<br><button class="btn sm" data-all="${k}" data-on="${all ? 0 : 1}" title="${all ? 'فتح كل الفترات' : 'قفل كل الفترات'}" style="padding:1px 6px;margin-top:3px">${all ? '🔓' : '🔒'}</button>` : ''}</th>`; }).join('')}
        <th style="white-space:normal">آخر تغيير</th></tr></thead>
      <tbody>${rows.map((p, i) => `<tr><td class="muted">${i + 1}</td><td dir="ltr" style="text-align:right"><b>${esc(p.code)}</b></td><td dir="ltr" style="font-size:12px;white-space:nowrap;text-align:right">${fmtDate(p.start_date).slice(0, 5)} — ${fmtDate(p.end_date).slice(0, 5)}</td>
        ${cols.map(([k], j) => { const on = isOn(p, k); return `<td style="text-align:center;${j === 2 ? 'border-inline-start:2px solid var(--line);' : ''}${on ? 'background:var(--tint)' : ''}"><input type="checkbox" data-id="${p.id}" data-k="${k}" ${on ? 'checked' : ''}
          ${(!canLock || (on && !canOpen)) ? 'disabled' : ''} ${cb}></td>`; }).join('')}
        <td class="muted" style="font-size:11px">${p.locked_at ? fmtDateTime(p.locked_at) : ''}</td></tr>`).join('')}</tbody></table></div>
      <p class="muted" style="font-size:12px;margin:8px 0 0;white-space:normal">«المالية»: ما بينرحّل قيد بالفترة ولا بينلغى ترحيله. «حركات المخزون»: ما بتنضاف ولا بتنشال حركة مخزون.
        الأقسام: ما بينضاف ولا بينعدّل ولا بينحذف ولا بينرحّل مستند من القسم تاريخه بالفترة (حتى المسودات). القيد العكسي أو الإلغاء بتاريخ فترة مفتوحة مسموح.
        القفل بصلاحية «تعديل» على السنوات المالية، والفتح من جديد بصلاحية «إلغاء ترحيل» أو للمدير.</p>`
      : `<div class="empty">ما في فترات لهالسنة. <button class="btn sm primary" data-gen>توليد 12 فترة شهرية</button></div>`;
    box.querySelectorAll('[data-k]').forEach(c => c.onchange = async () => {
      const p = rows.find(r => r.id === c.dataset.id);
      const { error } = await sb.from('fiscal_periods').update(patch(p, c.dataset.k, c.checked)).eq('id', p.id);
      if (error) { c.checked = !c.checked; return toast(arError(error), 'err'); }
      rows = await load(); draw(); toast(c.checked ? 'انقفلت الفترة' : 'انفتحت الفترة', 'ok');
    });
    box.querySelectorAll('[data-all]').forEach(b => b.onclick = async () => {
      const k = b.dataset.all, on = b.dataset.on === '1';
      for (const p of rows) {
        if (isOn(p, k) === on) continue;
        const { error } = await sb.from('fiscal_periods').update(patch(p, k, on)).eq('id', p.id);
        if (error) { toast(arError(error), 'err'); break; }
      }
      rows = await load(); draw(); toast('تم', 'ok');
    });
    box.querySelector('[data-gen]')?.addEventListener('click', async () => {
      const { error } = await sb.rpc('ensure_fiscal_periods', { p_fy: y.id });
      if (error) return toast(arError(error), 'err');
      rows = await load(); draw();
    });
  };
  draw();
}

async function viewFiscalYears(v) {
  if (!S.company) return viewHome(v);
  await loadFiscalYears();
  const rows = S.fiscalYears;
  v.innerHTML = `
    <div class="page-head"><h2>السنوات المالية</h2><span class="muted">${esc(S.company.name)}</span><div class="spacer"></div>
      ${can('fiscal_years', 'add') ? `<button class="btn primary" id="add">➕ سنة مالية جديدة</button>` : ''}</div>
    <div class="card table-wrap"><table class="t">
      <thead><tr><th>الرمز</th><th>الاسم</th><th>من</th><th>إلى</th><th>الحالة</th><th></th></tr></thead>
      <tbody>${rows.map(y => `
        <tr><td>${esc(y.code)}</td><td>${esc(y.name || '')}</td><td>${fmtDate(y.start_date)}</td><td>${fmtDate(y.end_date)}</td>
        <td>${y.is_closed ? '<span class="badge bad">مغلقة</span>' : '<span class="badge ok">مفتوحة</span>'}${y.unavailable ? ' <span class="badge warn" title="مفتوحة بدري: المستخدمين ما بينتقلوا لها لحد ما يبدأ تاريخها">غير متاح</span>' : ''}</td>
        <td class="actions">
          ${isAdmin() && !y.is_closed ? `<button class="btn sm primary" data-close-year="${y.id}">🔒 إغلاق وتدوير</button>` : ''}
          ${isAdmin() && y.is_closed ? `<button class="btn sm" data-reopen="${y.id}">🔓 إعادة فتح</button>` : ''}
          <button class="btn sm" data-periods="${y.id}">📆 الفترات</button>
          ${can('fiscal_years', 'edit') && (!y.is_closed || isAdmin()) ? `<button class="btn sm" data-edit="${y.id}">تعديل</button>` : ''}
          ${can('fiscal_years', 'delete') && !y.is_closed ? `<button class="btn sm danger" data-del="${y.id}">حذف</button>` : ''}
        </td></tr>`).join('') || `<tr><td colspan="6" class="empty">ما في سنوات مالية لهالشركة</td></tr>`}</tbody></table></div>
    <p class="muted" style="font-size:13px">إغلاق السنة بيمنع أي تعديل عليها. بس مدير النظام بيقدر يفتحها من جديد.<br>
      «غير متاح» = السنة الجاية مفتوحة بدري (تجديد عقود، موازنات، أرصدة)، والمستخدمين بيضلّوا على السنة الحالية لحد ما يبدأ تاريخها.</p>
    ${can('companies', 'edit') ? `<label class="check" style="font-size:13px"><input type="checkbox" id="fy-auto"> إتاحة السنة «غير المتاحة» تلقائياً لما يبدأ تاريخها</label>` : ''}`;
  if (can('companies', 'edit')) {
    const { data: cs } = await sb.from('company_settings').select('fy_auto_release').eq('company_id', S.company.id).maybeSingle();
    const box = v.querySelector('#fy-auto'); box.checked = cs?.fy_auto_release !== false;
    box.onchange = async () => { const { error } = await sb.from('company_settings').update({ fy_auto_release: box.checked }).eq('company_id', S.company.id);
      if (error) { box.checked = !box.checked; return toast(arError(error), 'err'); } toast('تم الحفظ', 'ok'); };
  }
  const open = (y) => {
    const yr = new Date().getFullYear();
    y = y || { code: String(yr), name: 'السنة المالية ' + yr, start_date: yr + '-01-01', end_date: yr + '-12-31' };
    const m = modal({ title: y.id ? 'تعديل سنة مالية' : 'سنة مالية جديدة', size: 'sm', body: `
      <form id="fy-form">
        <div class="field"><label>الرمز *</label><input name="code" required value="${esc(y.code)}"></div>
        <div class="field"><label>الاسم</label><input name="name" value="${esc(y.name)}"></div>
        <div class="grid cols-2">
          <div class="field"><label>من *</label><input type="date" name="start_date" required value="${esc(y.start_date)}"></div>
          <div class="field"><label>إلى *</label><input type="date" name="end_date" required value="${esc(y.end_date)}"></div>
        </div>
        ${y.id ? `<label class="check"><input type="checkbox" name="is_closed" ${y.is_closed ? 'checked' : ''} ${y.is_closed && !isAdmin() ? 'disabled' : ''}> السنة مغلقة</label>` : ''}
        ${canHiddenYears() ? `<label class="check"><input type="checkbox" name="unavailable" ${y.unavailable ? 'checked' : ''}> «غير متاح» (مفتوحة بدري، المستخدمين ما بينتقلوا لها)</label>` : ''}
      </form>`, foot: `<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>` });
    m.el.querySelector('[data-save]').onclick = async () => {
      const d = formData(m.el.querySelector('#fy-form'));
      if (canHiddenYears()) d.unavailable = !!d.unavailable;
      if (!d.code || !d.start_date || !d.end_date) return toast('عبّي الحقول المطلوبة', 'err');
      if (!y.id) {   // فراغ بين السنوات
        const prev = S.fiscalYearsAll.filter(o => o.end_date < d.start_date).sort((a, b) => b.end_date.localeCompare(a.end_date))[0];
        if (prev) { const nx = new Date(prev.end_date + 'T00:00:00Z'); nx.setUTCDate(nx.getUTCDate() + 1);
          if (nx.toISOString().slice(0, 10) < d.start_date && !(await confirmBox(`في أيام بين نهاية «${prev.name || prev.code}» (${fmtDate(prev.end_date)}) وبداية هالسنة رح تضل بدون سنة مالية. بدك تكمّل؟`))) return; }
      }
      if (d.end_date <= d.start_date) return toast('تاريخ النهاية لازم يكون بعد تاريخ البداية', 'err');
      const overlap = S.fiscalYears.find(o => o.id !== y.id && d.start_date <= o.end_date && d.end_date >= o.start_date);
      if (overlap && !(await confirmBox(`هالفترة متداخلة مع «${overlap.name || overlap.code}». بدك تكمّل؟`))) return;
      const res = y.id ? await sb.from('fiscal_years').update(d).eq('id', y.id)
                       : await sb.from('fiscal_years').insert({ ...d, company_id: S.company.id });
      if (res.error) return toast(arError(res.error), 'err');
      await log(y.id ? 'تعديل' : 'إضافة', 'fiscal_years', y.id || d.code, d);
      toast('تم الحفظ', 'ok'); m.close(); await loadFiscalYears(); renderShell(); route_();
    };
  };
  v.querySelector('#add')?.addEventListener('click', () => open(null));
  v.querySelectorAll('[data-periods]').forEach(b => b.onclick = () => periodsDialog(rows.find(y => y.id === b.dataset.periods)));
  v.querySelector('tbody').onclick = async (e) => {
    const ed = e.target.closest('[data-edit]'), dl = e.target.closest('[data-del]');
    const cy = e.target.closest('[data-close-year]'), ro = e.target.closest('[data-reopen]');
    if (cy) return closeYearDialog(rows.find(x => x.id === cy.dataset.closeYear), rows);
    if (ro) {
      const y = rows.find(x => x.id === ro.dataset.reopen);
      if (!(await confirmBox(`إعادة فتح «${y.name || y.code}»؟ رح ينحذف قيد الإقفال والأرصدة المدوّرة تلقائياً للسنة اللي بعدها (إذا موجودة). بعد التعديل بتقدر تغلقها من جديد.`))) return;
      const { error } = await sb.rpc('reopen_fiscal_year', { p_fy: y.id });
      if (error) return toast(arError(error), 'err');
      toast('انفتحت السنة', 'ok'); await loadFiscalYears(); renderShell(); route_(); return;
    }
    if (ed) open(rows.find(x => x.id === ed.dataset.edit));
    if (dl) {
      const y = rows.find(x => x.id === dl.dataset.del);
      if (!(await confirmBox(`حذف السنة المالية «${y.name || y.code}»؟`))) return;
      const { error } = await sb.from('fiscal_years').delete().eq('id', y.id);
      if (error) return toast(arError(error), 'err');
      await log('حذف', 'fiscal_years', y.id, { code: y.code });
      toast('تم الحذف', 'ok'); await loadFiscalYears(); renderShell(); route_();
    }
  };
}

// إغلاق السنة وتدوير الأرصدة
async function closeYearDialog(y, years) {
  const next = years.filter(n => n.start_date > y.end_date && !n.is_closed).sort((a, b) => a.start_date.localeCompare(b.start_date));
  const { data: accs } = await sb.from('accounts').select('id,code,name,category,is_group').eq('company_id', S.company.id).eq('category', 'equity').eq('is_group', false).order('code');
  const def = (accs || []).find(a => a.code === '3103') || (accs || [])[0];
  const ns = new Date(y.end_date + 'T00:00:00Z'); ns.setUTCDate(ns.getUTCDate() + 1);
  const ne = new Date(ns); ne.setUTCFullYear(ne.getUTCFullYear() + 1); ne.setUTCDate(ne.getUTCDate() - 1);
  const nyYear = ns.getUTCFullYear(), nsIso = ns.toISOString().slice(0, 10), neIso = ne.toISOString().slice(0, 10);
  const m = modal({ title: `إغلاق ${y.name || y.code} وتدوير الأرصدة`, body: `
    <div class="notice info">رح يصير هيك:<br>1) قيد إقفال بتاريخ ${fmtDate(y.end_date)} بيصفّر الإيرادات والمصاريف، وبيحوّل صافي الربح أو الخسارة لحساب الأرباح المدورة.<br>
      2) قيد افتتاحي مرحّل بالسنة الجديدة، فيه أرصدة الموجودات والمطلوبات وحقوق الملكية والعملاء والموردين.<br>3) السنة بتنقفل، وما حدا بيقدر يعدّل عليها إلا المدير.</div>
    <form id="cy-form">
      <div class="field"><label>السنة الجديدة</label><select name="next">${next.map(n => `<option value="${n.id}">${esc(n.name || n.code)} (${fmtDate(n.start_date)})</option>`).join('')}
        <option value="__new">➕ إنشاء السنة المالية ${nyYear} تلقائياً</option></select></div>
      <div class="field"><label>حساب الأرباح المدورة</label><select name="ret">${(accs || []).map(a => `<option value="${a.id}" ${a.id === def?.id ? 'selected' : ''}>${esc(a.code)} — ${esc(a.name)}</option>`).join('')}</select></div>
    </form>
    <p class="muted" style="font-size:13px">لازم ما يكون في سندات أو فواتير مسودة بالسنة. وإذا السنة الجديدة إلها أرصدة افتتاحية مدخلة يدوياً ومرحّلة، احذفها أو اعكسها أول.</p>`,
    foot: `<button class="btn primary" data-go>🔒 إغلاق وتدوير</button><button class="btn" data-close>إلغاء</button>` });
  if (!accs?.length) m.el.querySelector('[data-go]').disabled = true;
  m.el.querySelector('[data-go]').onclick = async (e) => {
    const d = formData(m.el.querySelector('#cy-form')); e.target.disabled = true;
    let nextId = d.next;
    if (nextId === '__new') {
      const ins = await sb.from('fiscal_years').insert({ company_id: S.company.id, code: String(nyYear), name: 'السنة المالية ' + nyYear, start_date: nsIso, end_date: neIso }).select().single();
      if (ins.error) { e.target.disabled = false; return toast(arError(ins.error), 'err'); }
      nextId = ins.data.id;
    }
    const { data, error } = await sb.rpc('close_fiscal_year', { p_fy: y.id, p_next_fy: nextId, p_retained: d.ret });
    if (error) { e.target.disabled = false; return toast(arError(error), 'err'); }
    const p = Number(data?.profit || 0);
    toast(`تم الإغلاق والتدوير. ${p >= 0 ? 'صافي الربح' : 'صافي الخسارة'}: ${Math.abs(p).toFixed(3)}`, 'ok');
    m.close(); await loadFiscalYears(); renderShell(); route_();
  };
}

// ---------------------------------------------------------------------
//  المستخدمين (للمدير)
// ---------------------------------------------------------------------
async function viewUsers(v) {
  if (!isAdmin()) return viewHome(v);
  const [p, uc, c, dp] = await Promise.all([
    sb.from('profiles').select('*').order('created_at'),
    sb.from('user_companies').select('*'),
    sb.from('companies').select('id,code,name').order('code'),
    sb.from('departments').select('id,company_id,code,name,kind,is_active').order('code'),
  ]);
  if (p.error) throw p.error;
  const depts = (dp.data || []).filter(d => d.kind === 'sub');
  const users = p.data, links = uc.data || [], comps = c.data || [];
  const pending = users.filter(u => !u.is_active).length;
  const login = (u) => u.username || u.email;
  v.innerHTML = `
    <div class="page-head"><h2>👥 المستخدمين</h2><span class="badge brand">${users.length}</span>
      ${pending ? `<span class="badge warn">${pending} بانتظار الموافقة</span>` : ''}<div class="spacer"></div>
      <button class="btn" id="u-pol">🔐 سياسة كلمات السر</button><button class="btn primary" id="u-add">➕ مستخدم جديد</button></div>
    <div class="card table-wrap"><table class="t">
      <thead><tr><th>الاسم</th><th>اسم الدخول</th><th>النوع</th><th>الشاشات</th><th>الشركات</th><th>الحالة</th><th></th></tr></thead>
      <tbody>${users.map(u => {
        const mine = links.filter(l => l.user_id === u.id);
        const np = Object.keys(u.permissions || {}).length;
        return `<tr><td><b>${esc(u.full_name || '')}</b></td><td dir="ltr" style="text-align:right">${esc(login(u))}</td>
          <td>${u.is_admin ? '<span class="badge brand">مدير النظام</span>' : 'موظف'}</td>
          <td>${u.is_admin ? '<span class="muted">الكل</span>' : (np ? np + ' شاشة' : '<span class="muted">—</span>')}</td>
          <td>${u.is_admin ? '<span class="muted">كل الشركات</span>' : (mine.length ? mine.length + ' شركة' : '<span class="muted">—</span>')}</td>
          <td>${u.is_active ? '<span class="badge ok">مفعّل</span>' : '<span class="badge warn">موقوف</span>'}</td>
          <td class="actions"><button class="btn sm" data-edit="${u.id}" title="تعديل">✏️ تعديل</button></td></tr>`;
      }).join('')}</tbody></table></div>`;
  v.querySelector('#u-add').onclick = () => userEditor(null, links, comps, depts);
  v.querySelector('#u-pol').onclick = () => passwordPolicyDialog();
  v.querySelector('tbody').onclick = (e) => {
    const b = e.target.closest('[data-edit]'); if (!b) return;
    userEditor(users.find(x => x.id === b.dataset.edit), links, comps, depts);
  };
}

function userEditor(u, links, comps, depts = []) {
  const link = (cid) => (u ? links.find(l => l.user_id === u.id && l.company_id === cid) : null) || {};
  const isNew = !u, self = !!u && u.id === S.session.user.id;
  const perms = u?.permissions || {};
  const myComps = new Set(u ? links.filter(l => l.user_id === u.id).map(l => l.company_id) : comps.map(c => c.id));
  const groups = [...new Set(SCREENS.map(s => s.group))];
  const box = 'style="width:20px;height:20px;accent-color:var(--brand);cursor:pointer;flex:none"';
  const row = (attr, label, on) => `<label class="perm-row" style="display:flex;align-items:center;justify-content:space-between;gap:10px;padding:8px 12px;border-bottom:1px solid var(--line);cursor:pointer">
      <span>${label}</span><input type="checkbox" ${attr} ${on ? 'checked' : ''} ${box}></label>`;
  const has = (k, a) => perms[k] === true || !!perms[k]?.[a];
  const prow = (sc) => { const any = ACTIONS.some(a => has(sc.key, a.key));
    return `<div class="perm-row" data-row="${sc.key}" style="display:flex;align-items:center;gap:10px;padding:8px 12px;border-bottom:1px solid var(--line);flex-wrap:wrap">
      <label style="display:flex;align-items:center;gap:10px;cursor:pointer;flex:1;min-width:150px"><span style="flex:1;font-weight:600">${esc(sc.label)}</span></label>
      <span class="acts" style="display:flex;gap:4px;flex-wrap:wrap">${ACTIONS.map(a => `<label title="${a.label}" style="display:inline-flex;align-items:center;gap:3px;font-size:12px;padding:2px 7px;border:1px solid var(--line);border-radius:999px;cursor:pointer;background:#fff">
        <input type="checkbox" data-a="${a.key}" ${has(sc.key, a.key) ? 'checked' : ''} style="width:14px;height:14px;accent-color:var(--brand)">${a.label}</label>`).join('')}</span>
      <input type="checkbox" data-p="${sc.key}" ${any ? 'checked' : ''} ${box} title="كل الصلاحيات على الشاشة"></div>`; };
  const m = modal({ title: isNew ? '➕ مستخدم جديد' : '✏️ تعديل المستخدم: ' + esc(u.full_name || u.username || u.email), body: `
    <form id="u-form" autocomplete="off"><div class="grid cols-3">
      <div class="field"><label>اسم المستخدم (للدخول) *</label><input name="username" dir="ltr" autocapitalize="none" value="${esc(u?.username || '')}" placeholder="hala"></div>
      <div class="field"><label>الاسم الكامل</label><input name="full_name" value="${esc(u?.full_name || '')}"></div>
      <div class="field"><label>كلمة السر ${isNew ? '*' : ''}</label><input name="password" dir="ltr" autocomplete="new-password" placeholder="${isNew ? '' : 'اتركها فاضية إذا ما بدك تغيّرها'}"></div>
    </div>
    ${!isNew && !u.username ? `<p class="muted" style="margin:0 0 8px;font-size:13px">هالحساب بيدخل بالإيميل: <span dir="ltr">${esc(u.email)}</span>. إذا كتبت اسم مستخدم بيصير يقدر يدخل فيه كمان.</p>` : ''}
    <div style="display:flex;gap:18px;flex-wrap:wrap">
      <label class="check"><input type="checkbox" name="is_active" ${isNew || u.is_active ? 'checked' : ''} ${self ? 'disabled' : ''}> الحساب مفعّل</label>
      <label class="check"><input type="checkbox" name="is_admin" ${u?.is_admin ? 'checked' : ''} ${self ? 'disabled' : ''}> مدير النظام (كل الصلاحيات)</label>
      <label class="check" title="لما يدخل بتطلعله شاشة الكاشير بس. أعطيه مجموعة «كاشير» بالشركة"><input type="checkbox" name="pos_only" ${u?.pos_only ? 'checked' : ''} ${self ? 'disabled' : ''}> 🛒 مستخدم نقطة بيع بس</label>
    </div></form>
    <div id="perm-area">
    <h3 style="margin:16px 0 6px">🔐 الصلاحيات الخاصة</h3>
    <p class="muted" style="font-size:13px;margin:0 0 8px">بتنضاف على صلاحيات مجموعته بكل شركة. اختار الشاشة من الشجرة وأشّر على العمليات.</p>
    <div id="u-perms"></div>
    <h3 style="margin:16px 0 6px">🏢 الشركات اللي بيشتغل عليها</h3>
    <div class="card" style="padding:0;overflow:hidden">${comps.map(c => { const ds = depts.filter(d => d.company_id === c.id), l = link(c.id);
      return row(`data-c="${c.id}"`, `${esc(c.name)} <span class="muted">(${esc(c.code)})</span>`, myComps.has(c.id))
        + (ds.length ? `<div class="uc-dept" data-ucd="${c.id}" style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;padding:6px 12px 10px 42px;border-bottom:1px solid var(--line);font-size:13px">
          <span class="muted">الدائرة:</span><select data-dep style="max-width:260px"><option value="">— بدون —</option>${ds.map(d => `<option value="${d.id}" ${d.id === l.department_id ? 'selected' : ''}>${esc(d.code)} — ${esc(d.name)}${d.is_active ? '' : ' (غير مفعّل)'}</option>`).join('')}</select>
          <label class="check" style="margin:0"><input type="checkbox" data-hide ${l.hide_departments ? 'checked' : ''}> إخفاء الدوائر (ما بيغيّر الدائرة بالمستندات)</label>
          <label class="check" style="margin:0" title="ما بيشوف ولا بيدخل حركات فروع ثانية، وتقاريره لفرعه بس"><input type="checkbox" data-bo ${l.branch_only ? 'checked' : ''}> 🔒 بيشوف دائرته بس</label></div>` : ''); }).join('') || '<p class="muted" style="padding:10px">ما في شركات</p>'}</div>
    </div>`,
    foot: `<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>
      ${!isNew && !self ? `<button class="btn" data-force>🔑 ${u.must_change_password ? 'إلغاء إجبار تغيير كلمة السر' : 'إجبار تغيير كلمة السر بالدخول الجاي'}</button><button class="btn danger" data-del style="margin-inline-start:auto">حذف المستخدم</button>` : ''}` });
  m.el.querySelector('.modal').style.maxWidth = '920px';
  const pe = permEditor(m.el.querySelector('#u-perms'), perms);
  const f = m.el.querySelector('#u-form');
  // كلمة السر الافتراضية = اسم المستخدم
  if (isNew) { let touched = false; f.password.oninput = () => touched = true; f.username.oninput = () => { if (!touched) f.password.value = f.username.value.trim().toLowerCase(); }; }
  const adminToggle = () => { m.el.querySelector('#perm-area').style.opacity = f.is_admin.checked ? .45 : 1; };
  f.is_admin.onchange = adminToggle; adminToggle();
  m.el.querySelector('[data-save]').onclick = async (e) => {
    const d = formData(f);
    const username = (d.username || '').trim().toLowerCase();
    if (isNew && !username) return toast('اكتب اسم المستخدم', 'err');
    if (username && !/^[a-z0-9._-]{2,30}$/.test(username)) return toast('اسم المستخدم لازم يكون أحرف إنجليزي أو أرقام بدون فراغات', 'err');
    if (isNew && (d.password || '').length < 4) return toast('كلمة السر لازم تكون 4 أحرف على الأقل', 'err');   // السياسة الكاملة بتتفحص بقاعدة البيانات
    const permissions = pe.user();
    const companies = [...m.el.querySelectorAll('[data-c]')].filter(x => x.checked).map(x => x.dataset.c);
    e.target.disabled = true;
    const r = isNew
      ? await sb.rpc('admin_create_user', { p_username: username, p_full_name: d.full_name, p_password: d.password, p_permissions: permissions, p_companies: companies, p_is_admin: !!d.is_admin })
      : await sb.rpc('admin_update_user', { p_id: u.id, p_username: username || null, p_full_name: d.full_name, p_password: d.password || null, p_permissions: permissions, p_companies: companies, p_is_admin: !!d.is_admin, p_is_active: !!d.is_active });
    if (r.error) { e.target.disabled = false; return toast(arError(r.error), 'err'); }
    const uid = isNew ? r.data : u.id;
    if (uid && !self && !!d.pos_only !== !!u?.pos_only) {
      const x = await sb.from('profiles').update({ pos_only: !!d.pos_only }).eq('id', uid); if (x.error) toast(arError(x.error), 'err');
    }
    for (const box of m.el.querySelectorAll('[data-ucd]')) {
      const cid = box.dataset.ucd; if (!companies.includes(cid) || !uid) continue;
      const dep = box.querySelector('[data-dep]').value || null, hide = box.querySelector('[data-hide]').checked, bo = box.querySelector('[data-bo]').checked, l = link(cid);
      if (bo && !dep) { toast('«بيشوف دائرته بس» بدها دائرة للمستخدم', 'err'); continue; }
      if (!isNew && (l.department_id || null) === dep && !!l.hide_departments === hide && !!l.branch_only === bo) continue;
      if (!dep && !hide && !bo && isNew) continue;
      const x = await sb.from('user_companies').update({ department_id: dep, hide_departments: hide, branch_only: bo }).eq('user_id', uid).eq('company_id', cid);
      if (x.error) toast(arError(x.error), 'err');
    }
    toast(isNew ? `تم إنشاء المستخدم «${username}» — بيدخل باسم المستخدم وكلمة السر` : 'تم الحفظ', 'ok');
    if (self) await loadProfile();
    m.close(); route_();
  };
  m.el.querySelector('[data-force]')?.addEventListener('click', async () => {
    const { error } = await sb.rpc('admin_force_password_change', { p_user: u.id, p_on: !u.must_change_password });
    if (error) return toast(arError(error), 'err'); toast('تم', 'ok'); m.close(); route_();
  });
  m.el.querySelector('[data-del]')?.addEventListener('click', async () => {
    if (!(await confirmBox(`حذف المستخدم «${u.username || u.email}» نهائياً؟ (الأفضل توقف الحساب بدل الحذف)`))) return;
    const { error } = await sb.rpc('admin_delete_user', { p_id: u.id });
    if (error) return toast(arError(error), 'err');
    toast('تم الحذف', 'ok'); m.close(); route_();
  });
}

// ---------------------------------------------------------------------
//  المجموعات والصلاحيات (للمدير)
// ---------------------------------------------------------------------
async function viewGroups(v) {
  if (!isAdmin()) return viewHome(v);
  const { data, error } = await sb.from('user_groups').select('*').order('name');
  if (error) throw error;
  S.groups = data;
  v.innerHTML = `
    <div class="page-head"><h2>المجموعات والصلاحيات</h2><div class="spacer"></div><button class="btn primary" id="add">➕ مجموعة جديدة</button></div>
    <p class="muted">الصلاحيات بتنعطى للمجموعة، وكل موظف بياخذ صلاحيات مجموعته بكل شركة. مدير النظام إله كل الصلاحيات دائماً.</p>
    <div class="grid cols-3">${data.map(g => {
      const n = Object.values(g.permissions || {}).reduce((a, s) => a + Object.values(s).filter(Boolean).length, 0);
      return `<div class="card"><h3 style="margin:0 0 6px">${esc(g.name)}</h3><p class="muted" style="margin:0 0 12px;min-height:20px">${esc(g.description || '')}</p>
        <span class="badge brand">${n} صلاحية</span>
        <div style="margin-top:12px;display:flex;gap:6px"><button class="btn sm" data-edit="${g.id}">تعديل</button><button class="btn sm danger" data-del="${g.id}">حذف</button></div></div>`;
    }).join('') || '<div class="empty">ما في مجموعات</div>'}</div>`;
  const open = (g) => {
    g = g || { name: '', description: '', permissions: {} };
    const m = modal({ title: g.id ? 'تعديل مجموعة' : 'مجموعة جديدة', body: `
      <form id="g-form"><div class="grid cols-2">
        <div class="field"><label>اسم المجموعة *</label><input name="name" required value="${esc(g.name)}"></div>
        <div class="field"><label>الوصف</label><input name="description" value="${esc(g.description)}"></div></div></form>
      <div style="display:flex;gap:6px;align-items:center;margin:4px 0 8px"><span class="muted" style="font-size:13px">نسخ الصلاحيات من مجموعة:</span>
        <select id="g-copy"><option value="">—</option>${data.filter(x => x.id !== g.id).map(x => `<option value="${x.id}">${esc(x.name)}</option>`).join('')}</select></div>
      <div id="g-perms"></div>`,
      foot: `<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>` });
    m.el.querySelector('.modal').style.maxWidth = '920px';
    const pe = permEditor(m.el.querySelector('#g-perms'), g.permissions || {});
    m.el.querySelector('#g-copy').onchange = (e) => { const src = data.find(x => x.id === e.target.value); if (src) pe.set(src.permissions || {}); };
    m.el.querySelector('[data-save]').onclick = async () => {
      const d = formData(m.el.querySelector('#g-form'));
      if (!d.name) return toast('اسم المجموعة مطلوب', 'err');
      const perms = pe.group();
      const row = { name: d.name, description: d.description, permissions: perms };
      const res = g.id ? await sb.from('user_groups').update(row).eq('id', g.id) : await sb.from('user_groups').insert(row);
      if (res.error) return toast(arError(res.error), 'err');
      await log(g.id ? 'تعديل' : 'إضافة', 'groups', g.id || d.name, row);
      toast('تم الحفظ', 'ok'); m.close(); route_();
    };
  };
  v.querySelector('#add').onclick = () => open(null);
  v.querySelector('.grid').onclick = async (e) => {
    const ed = e.target.closest('[data-edit]'), dl = e.target.closest('[data-del]');
    if (ed) open(data.find(x => x.id === ed.dataset.edit));
    if (dl) {
      const g = data.find(x => x.id === dl.dataset.del);
      if (!(await confirmBox(`حذف مجموعة «${g.name}»؟ الموظفين اللي فيها رح يصيروا بدون صلاحيات.`))) return;
      const { error } = await sb.from('user_groups').delete().eq('id', g.id);
      if (error) return toast(arError(error), 'err');
      await log('حذف', 'groups', g.id, { name: g.name });
      toast('تم الحذف', 'ok'); route_();
    }
  };
}

// ---------------------------------------------------------------------
//  سجل النشاط (للمدير)
// ---------------------------------------------------------------------
async function viewLog(v) {
  if (!isAdmin()) return viewHome(v);
  const [p, c] = await Promise.all([sb.from('profiles').select('id,full_name,username,email').order('full_name'), sb.from('companies').select('id,code,name').order('code')]);
  const uName = Object.fromEntries((p.data || []).map(x => [x.id, x.full_name || x.username || x.email]));
  const cName = Object.fromEntries((c.data || []).map(x => [x.id, x.name]));
  const ent = { companies: 'الشركات', fiscal_years: 'السنوات المالية', users: 'المستخدمين', groups: 'المجموعات', auth: 'الدخول والخروج', ...AUDIT_ENTITIES };
  const today = new Date().toISOString().slice(0, 10), d7 = new Date(Date.now() - 7 * 864e5).toISOString().slice(0, 10);
  const TABS = [['all', '📋 كل الحركات'], ['auth', '🔑 الدخول والخروج'], ['sessions', '⏱️ جلسات المستخدمين'], ['users', '👥 ملخص المستخدمين'],
    ['add', '➕ الإضافة'], ['edit', '✏️ التعديل'], ['post', '📮 الترحيل وإلغاؤه'], ['del', '🗑️ الحذف']];
  v.innerHTML = `
    <div class="page-head"><h2>📜 سجل النشاط والتتبع</h2><span class="muted" id="upd"></span><div class="spacer"></div>
      <label class="check" style="margin:0"><input type="checkbox" id="auto"> تحديث تلقائي كل دقيقة</label>
      <button class="btn sm" id="refresh">🔄 تحديث</button><button class="btn sm" id="csv">⬇️ Excel</button><button class="btn sm" id="prn">🖨️ طباعة</button></div>
    <div class="tabs" id="lt">${TABS.map(([k, l], i) => `<div class="tab ${i ? '' : 'active'}" data-k="${k}">${l}</div>`).join('')}</div>
    <div class="card no-print" style="display:flex;gap:10px;flex-wrap:wrap;align-items:end">
      <div class="field"><label>المستخدم</label><select id="fu"><option value="">الكل</option>${(p.data || []).map(x => `<option value="${x.id}">${esc(uName[x.id])}</option>`).join('')}</select></div>
      <div class="field"><label>الشركة</label><select id="fc"><option value="">الكل</option>${(c.data || []).map(x => `<option value="${x.id}">${esc(x.code)} — ${esc(x.name)}</option>`).join('')}</select></div>
      <div class="field"><label>الفترة</label><select id="fp"><option value="today">اليوم</option><option value="7" selected>آخر 7 أيام</option><option value="30">آخر 30 يوم</option><option value="custom">فترة محددة</option></select></div>
      <div class="field"><label>من</label><input type="date" id="ff" value="${d7}"></div>
      <div class="field"><label>إلى</label><input type="date" id="ft" value="${today}"></div>
      <div class="field" style="flex:1;min-width:160px"><label>بحث</label><input id="fq" placeholder="رقم السند أو الاسم…"></div></div>
    <div class="grid cols-3" id="stats" style="margin-bottom:12px"></div>
    <div class="card table-wrap"><table class="t" id="tbl"></table></div>
    <p class="muted" id="cnt"></p>`;
  const $ = (q) => v.querySelector(q);
  let kind = 'all', data = [], out = { head: [], rows: [] }, timer = null;
  const det = (r) => { const d = r.details || {}; const ch = (d.changes || []).map(x => AUDIT_COLS[x]).filter(Boolean).filter((x, i, a) => a.indexOf(x) === i);
    return [d.no ? `رقم/رمز: ${d.no}` : '', d.name || d.code || d.email || d.doc || '', ch.length ? `تغيّر: ${ch.join('، ')}` : ''].filter(Boolean).join(' — '); };
  const isPost = (a) => /ترحيل|^إلغاء$|قيد عكسي/.test(a || '');
  const dur = (ms) => { const m = Math.round(ms / 60000); return m < 60 ? `${m} دقيقة` : `${Math.floor(m / 60)} ساعة و${m % 60} دقيقة`; };
  $('#fp').onchange = () => { const x = $('#fp').value; if (x !== 'custom') { $('#ft').value = today; $('#ff').value = x === 'today' ? today : new Date(Date.now() - (+x) * 864e5).toISOString().slice(0, 10); load(); } };
  ['#ff', '#ft'].forEach(id => $(id).onchange = () => { $('#fp').value = 'custom'; load(); });
  ['#fu', '#fc'].forEach(id => $(id).onchange = load);
  $('#fq').oninput = () => draw();
  async function load() {
    let q = sb.from('activity_log').select('*').gte('created_at', $('#ff').value).lte('created_at', $('#ft').value + 'T23:59:59.999').order('created_at', { ascending: false }).limit(5000);
    if ($('#fu').value) q = q.eq('user_id', $('#fu').value); if ($('#fc').value) q = q.eq('company_id', $('#fc').value);
    const r = await q; if (r.error) return toast(arError(r.error), 'err');
    data = r.data || []; $('#upd').textContent = 'آخر تحديث: ' + new Date().toLocaleTimeString('ar-JO'); draw();
  }
  function draw() {
    const fq = $('#fq').value.trim().toLowerCase();
    const base = data.filter(r => !fq || [det(r), uName[r.user_id], r.action, cName[r.company_id]].some(x => (x || '').toLowerCase().includes(fq)));
    const auth = base.filter(r => r.entity === 'auth');
    const st = (l, n, s = '') => `<div class="card stat"><span class="k">${l}</span><span class="v">${n}</span>${s ? `<span class="muted" style="font-size:12px">${s}</span>` : ''}</div>`;
    $('#stats').innerHTML = st('كل الحركات', base.length) + st('مرات الدخول', auth.filter(r => r.action === 'دخول').length, `${new Set(auth.map(r => r.user_id)).size} مستخدم`)
      + st('إضافة / تعديل / حذف', `${base.filter(r => r.action === 'إضافة').length} / ${base.filter(r => r.action === 'تعديل').length} / ${base.filter(r => r.action === 'حذف').length}`);
    const ACT = (r) => r.entity === 'auth' ? (r.action === 'دخول' ? '<span class="badge ok">دخول</span>' : '<span class="badge">خروج</span>')
      : r.action === 'حذف' ? '<span class="badge bad">حذف</span>' : isPost(r.action) ? `<span class="badge brand">${esc(r.action)}</span>` : esc(r.action);
    let head, rows, html;
    if (kind === 'users') {
      const by = {};
      base.forEach(r => { const u = by[r.user_id] ||= { in: 0, add: 0, edit: 0, del: 0, post: 0, last_in: null, last_out: null, last: null };
        if (r.entity === 'auth') { if (r.action === 'دخول') { u.in++; u.last_in ||= r.created_at; } else u.last_out ||= r.created_at; }
        else if (r.action === 'إضافة') u.add++; else if (r.action === 'حذف') u.del++; else if (isPost(r.action)) u.post++; else u.edit++;
        u.last ||= r.created_at; });
      head = ['المستخدم', 'مرات الدخول', 'إضافة', 'تعديل', 'ترحيل', 'حذف', 'آخر دخول', 'آخر خروج', 'آخر حركة'];
      rows = Object.entries(by).map(([id, u]) => [uName[id] || '—', u.in, u.add, u.edit, u.post, u.del, u.last_in ? fmtDateTime(u.last_in) : '—', u.last_out ? fmtDateTime(u.last_out) : '—', fmtDateTime(u.last)]);
      html = rows.map(x => `<tr>${x.map((c, i) => `<td ${i > 5 ? 'dir="ltr" style="text-align:right"' : ''}>${i ? esc(String(c)) : `<b>${esc(c)}</b>`}</td>`).join('')}</tr>`).join('');
    } else if (kind === 'sessions') {
      // كل دخول مع أول خروج بعده لنفس المستخدم
      const asc = [...auth].reverse(), open = {}, ses = [];
      asc.forEach(r => { if (r.action === 'دخول') { if (open[r.user_id]) ses.push({ ...open[r.user_id] }); open[r.user_id] = { u: r.user_id, in: r.created_at, c: r.company_id }; }
        else if (open[r.user_id]) { ses.push({ ...open[r.user_id], out: r.created_at }); delete open[r.user_id]; } else ses.push({ u: r.user_id, out: r.created_at }); });
      Object.values(open).forEach(o => ses.push({ ...o, now: true }));
      ses.sort((a, b) => String(b.in || b.out).localeCompare(String(a.in || a.out)));
      head = ['المستخدم', 'الدخول', 'الخروج', 'المدة'];
      rows = ses.map(s => [uName[s.u] || '—', s.in ? fmtDateTime(s.in) : '—', s.out ? fmtDateTime(s.out) : (s.now ? 'لسا داخل / ما كبس خروج' : '—'), s.in && s.out ? dur(new Date(s.out) - new Date(s.in)) : '']);
      html = rows.map(x => `<tr><td><b>${esc(x[0])}</b></td><td dir="ltr" style="text-align:right">${esc(x[1])}</td><td ${x[2].includes(':') ? 'dir="ltr" style="text-align:right"' : 'class="muted"'}>${esc(x[2])}</td><td>${esc(x[3])}</td></tr>`).join('');
    } else {
      const f = { all: () => true, auth: r => r.entity === 'auth', add: r => r.action === 'إضافة', edit: r => r.entity !== 'auth' && r.action === 'تعديل', post: r => isPost(r.action), del: r => r.action === 'حذف' }[kind];
      const list = base.filter(f);
      head = ['الوقت', 'المستخدم', 'العملية', 'الشاشة', 'الشركة', 'التفاصيل'];
      rows = list.map(r => [fmtDateTime(r.created_at), uName[r.user_id] || '', r.action, ent[r.entity] || r.entity || '', cName[r.company_id] || '', det(r)]);
      html = list.map(r => `<tr><td dir="ltr" style="text-align:right">${fmtDateTime(r.created_at)}</td><td>${esc(uName[r.user_id] || '')}</td><td>${ACT(r)}</td>
        <td>${esc(ent[r.entity] || r.entity || '')}</td><td>${esc(cName[r.company_id] || '')}</td><td class="muted" style="font-size:12px">${esc(det(r))}</td></tr>`).join('');
    }
    out = { head, rows };
    $('#tbl').innerHTML = `<thead><tr>${head.map(h => `<th>${h}</th>`).join('')}</tr></thead><tbody>${html || `<tr><td colspan="${head.length}" class="empty">ما في حركات بهالفترة</td></tr>`}</tbody>`;
    $('#cnt').textContent = `${rows.length} سطر${data.length >= 5000 ? ' — أول 5000 حركة بس، ضيّق الفترة' : ''}`;
  }
  $('#lt').onclick = (e) => { const t = e.target.closest('.tab'); if (!t) return; v.querySelectorAll('#lt .tab').forEach(x => x.classList.toggle('active', x === t)); kind = t.dataset.k; draw(); };
  $('#refresh').onclick = load;
  $('#auto').onchange = () => { clearInterval(timer); timer = $('#auto').checked ? setInterval(() => { if (document.body.contains($('#tbl'))) load(); else clearInterval(timer); }, 60000) : null; };
  $('#csv').onclick = () => downloadCSV('سجل النشاط.csv', [out.head].concat(out.rows));
  $('#prn').onclick = () => window.print();
  load();
}

// ---------------------------------------------------------------------
//  التشغيل
// ---------------------------------------------------------------------
let booting = false;
async function boot() {
  if (booting) return; booting = true;
  try {
    const { data } = await sb.auth.getSession();
    S.session = data.session;
    if (!S.session) return renderAuth('login');
    await loadProfile();
    if (!S.profile) { // الملف الشخصي لسا ما انعمل (احتياط)
      $app.innerHTML = `<div class="auth-wrap"><div class="auth-card"><div class="notice">ما لقينا ملفك الشخصي. تأكد إن ملف قاعدة البيانات (SQL) انشغّل كامل، وبعدين اعمل تحديث للصفحة.</div>
        <button class="btn danger block" onclick="window.__logout()">تسجيل خروج</button></div></div>`;
      return;
    }
    if (!S.profile.is_active) return renderPending();
    if (S.sub?.status === 'suspended') return renderSuspended();
    if (S.trial && !S.trial.has_company && S.profile.is_admin) {
      $app.innerHTML = `<div class="auth-wrap"><div class="auth-card" style="text-align:center"><div style="font-size:44px">⏳</div><h3>جاري تجهيز شركتك التجريبية…</h3><p class="muted">بنعبّيلك عملاء وأصناف وفواتير وقيود عشان تشوف التقارير فوراً. ثواني بس.</p></div></div>`;
      const r = await sb.rpc('trial_setup');
      if (r.error) toast(arError(r.error), 'err'); else S.trial.has_company = true;
    }
    const ps = await sb.rpc('my_password_status');   // سياسة كلمات السر (المرحلة 84)
    if (!ps.error && ps.data && (ps.data.must_change || ps.data.expired)) return renderForcedPassword(ps.data);
    if (!ps.error && ps.data?.days_left != null && ps.data.days_left <= 7) setTimeout(() => toast(`كلمة السر بتنتهي بعد ${Math.max(ps.data.days_left, 0)} يوم — غيّرها من لوحة التحكم`, 'err'), 2500);
    await loadContext();
    applyTheme(canTheme() ? (S.profile?.theme || 'purple') : 'purple');
    renderShell(); route_();
    setTimeout(() => autoBackup().catch(() => {}), 4000);
    setTimeout(() => autoLocalBackup().catch(() => {}), 7000);
  } catch (err) {
    $app.innerHTML = `<div class="auth-wrap"><div class="auth-card"><div class="notice">${esc(arError(err))}</div>
      <button class="btn block" onclick="location.reload()">إعادة المحاولة</button></div></div>`;
  } finally { booting = false; }
}
window.__logout = () => signOutHere();

sb.auth.onAuthStateChange((event, session) => {
  if (event === 'PASSWORD_RECOVERY') { S.session = session; return renderNewPassword(); }
  if (event === 'SIGNED_IN' && !S.profile) { setTimeout(async () => { await boot(); if (S.profile?.is_active) log('دخول', 'auth'); }, 0); }
  if (event === 'SIGNED_OUT') { Object.assign(S, { session: null, profile: null, companies: [], company: null }); renderAuth('login'); }
});

if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
boot();
