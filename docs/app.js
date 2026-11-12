// =====================================================================
//  السمو ERP — الهيكل الرئيسي وشاشات المرحلة 1
// =====================================================================
import { APP_NAME, APP_VERSION } from './config.js';
import { ACTIONS, ACTIVITY_TYPES, COMPANY_TYPES, S, SCREENS, arError, can, confirmBox, esc, fmtDate, fmtDateTime, fmtNum, formData, isAdmin, loadContext, loadFiscalYears, loadProfile, localStorageGet, localStorageSet, log, modal, num, sb, setupTabs, toast, today } from './core.js';
import { FINANCE_ROUTES } from './finance.js';
import { REPORT_ROUTES } from './reports.js';
import { PARTY_ROUTES } from './parties.js';
import { INVOICE_ROUTES } from './invoices.js';
import { OBLIGATION_ROUTES, obligationsSummary } from './obligations.js';
import { CHEQUE_ROUTES } from './cheques.js';
import { INVENTORY_ROUTES } from './inventory.js';
import { PRINTSET_ROUTES } from './printset.js';
import { NUMBERING_ROUTES } from './numbering.js';
import { EXTRA_ROUTES, dashboardPanel } from './extras.js';
import { PAYROLL_ROUTES } from './payroll.js';
import { TOOLS_ROUTES, autoBackup } from './tools.js';

const $app = document.getElementById('app');
// ---------------------------------------------------------------------
//  شاشات الدخول
// ---------------------------------------------------------------------
function renderAuth(mode = 'login') {
  const titles = { login: 'تسجيل الدخول', signup: 'حساب جديد', reset: 'نسيت كلمة السر' };
  $app.innerHTML = `
    <div class="auth-wrap"><div class="auth-card">
      <div class="auth-logo"><img src="icons/icon.svg" alt=""><h1>${APP_NAME}</h1></div>
      <p class="auth-sub">${titles[mode]}</p>
      <form id="auth-form">
        ${mode === 'signup' ? `<div class="field"><label>الاسم الكامل</label><input name="full_name" required></div>` : ''}
        <div class="field"><label>${mode === 'login' ? 'اسم المستخدم أو الإيميل' : 'الإيميل'}</label><input name="email" type="${mode === 'login' ? 'text' : 'email'}" dir="ltr" required autocomplete="username" autocapitalize="none"></div>
        ${mode !== 'reset' ? `<div class="field"><label>كلمة السر</label><input name="password" type="password" dir="ltr" required minlength="${mode === 'login' ? 4 : 6}" autocomplete="${mode === 'login' ? 'current-password' : 'new-password'}"></div>` : ''}
        <button class="btn primary block" type="submit">${mode === 'login' ? 'دخول' : mode === 'signup' ? 'إنشاء الحساب' : 'إرسال رابط تغيير كلمة السر'}</button>
      </form>
      <div class="auth-switch">
        ${mode === 'login' ? `<a data-mode="signup">إنشاء حساب جديد</a> · <a data-mode="reset">نسيت كلمة السر؟</a>` : `<a data-mode="login">رجوع لتسجيل الدخول</a>`}
      </div>
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
        const { error } = await sb.auth.signInWithPassword({ email: f.email.includes('@') ? f.email.trim() : f.email.trim().toLowerCase() + '@sumou.local', password: f.password });
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
  document.getElementById('logout').onclick = () => sb.auth.signOut();
}

// ---------------------------------------------------------------------
//  الهيكل الرئيسي
// ---------------------------------------------------------------------
const NAV = () => [
  { title: 'الرئيسية', items: [{ r: 'home', i: '🏠', l: 'لوحة التحكم' },
    { r: 'obligations', i: '🔔', l: 'متابعة إقرارات العملاء', show: () => S.companies.some(c => can('obligations', 'view', c.id)) },
    { href: './pdf/', i: '📕', l: 'السمو PDF' }] },
  { title: 'ملف', items: [
    { r: 'company', i: '🏢', l: 'بيانات الشركة', show: () => S.company && can('companies', 'view') },
    { r: 'fiscal-years', i: '📅', l: 'السنوات المالية', show: () => S.company && can('fiscal_years', 'view') },
    { r: 'settings', i: '🔗', l: 'حسابات الربط والضريبة', show: () => S.company && can('companies', 'edit') },
    { r: 'import', i: '📥', l: 'الاستيراد من إكسل', show: () => S.company && ['customers', 'suppliers', 'items', 'accounts', 'opening_balances', 'payroll'].some(x => can(x, 'add') || can(x, 'edit')) },
    { r: 'companies', i: '🗂️', l: 'الشركات', show: isAdmin },
    { r: 'users', i: '👥', l: 'المستخدمين', show: isAdmin },
    { r: 'groups', i: '🔐', l: 'المجموعات والصلاحيات', show: isAdmin },
    { r: 'log', i: '📜', l: 'سجل النشاط', show: isAdmin },
  ]},
  { title: 'المالية', items: [
    { r: 'accounts', i: '🌳', l: 'دليل الحسابات', show: () => S.company && can('accounts', 'view') },
    { r: 'opening', i: '🧮', l: 'الأرصدة الافتتاحية', show: () => S.company && can('opening_balances', 'view') },
    { r: 'journal', i: '📒', l: 'سندات القيد', show: () => S.company && can('journal_entries', 'view') },
    { r: 'receipts', i: '📥', l: 'سندات القبض', show: () => S.company && can('receipt_vouchers', 'view') },
    { r: 'payments', i: '📤', l: 'سندات الصرف', show: () => S.company && can('payment_vouchers', 'view') },
    { r: 'cheques', i: '💳', l: 'محفظة الشيكات', show: () => S.company && can('cheques', 'view') },
    { r: 'pending', i: '⏳', l: 'بانتظار الترحيل', show: () => S.company },
    { r: 'recurring', i: '🔁', l: 'القيود المتكررة', show: () => S.company && can('journal_entries', 'view') },
    { r: 'bank-recon', i: '🏦', l: 'التسوية البنكية', show: () => S.company && can('bank_recon', 'view') },
    { r: 'cost-centers', i: '🎯', l: 'مراكز الكلفة والعملات', show: () => S.company && can('accounts', 'view') },
  ]},
  { title: 'الموظفين والرواتب', items: [
    { r: 'employees', i: '👷', l: 'الموظفين', show: () => S.company && can('payroll', 'view') },
    { r: 'payroll', i: '💵', l: 'الرواتب والضمان', show: () => S.company && can('payroll', 'view') },
  ]},
  { title: 'الأصول الثابتة', items: [
    { r: 'assets', i: '🏢', l: 'الأصول الثابتة والاستهلاك', show: () => S.company && can('fixed_assets', 'view') },
  ]},
  { title: 'المخزون', items: [
    { r: 'items', i: '🏷️', l: 'الأصناف والخدمات', show: () => S.company && can('items', 'view') },
    { r: 'stock', i: '📦', l: 'رصيد المخزون', show: () => S.company && can('inventory', 'view') },
    { r: 'stock-docs?type=in', i: '📥', l: 'سندات الإدخال والإخراج', show: () => S.company && can('inventory', 'view') },
    { r: 'stock-docs?type=count', i: '📋', l: 'الجرد والتسوية', show: () => S.company && can('inventory', 'view') },
    { r: 'item-card', i: '🗂️', l: 'بطاقة صنف', show: () => S.company && can('inventory', 'view') },
    { r: 'warehouses', i: '🏬', l: 'المستودعات', show: () => S.company && can('inventory', 'view') },
  ]},
  { title: 'العملاء والذمم المدينة', items: [
    { r: 'customers', i: '🧑‍💼', l: 'العملاء', show: () => S.company && can('customers', 'view') },
    { r: 'sales?t=sale', i: '🧾', l: 'فواتير المبيعات', show: () => S.company && can('sales_invoices', 'view') },
    { r: 'sales?t=sale_return', i: '↩️', l: 'مردودات المبيعات', show: () => S.company && can('sales_invoices', 'view') },
    { r: 'party-categories?type=customer', i: '🗂️', l: 'فئات العملاء', show: () => S.company && can('customers', 'view') },
  ]},
  { title: 'الموردين والذمم الدائنة', items: [
    { r: 'suppliers', i: '🏭', l: 'الموردين', show: () => S.company && can('suppliers', 'view') },
    { r: 'purchases?t=purchase', i: '🛒', l: 'فواتير المشتريات', show: () => S.company && can('purchase_invoices', 'view') },
    { r: 'purchases?t=purchase_return', i: '↩️', l: 'مردودات المشتريات', show: () => S.company && can('purchase_invoices', 'view') },
    { r: 'party-categories?type=supplier', i: '🗂️', l: 'فئات الموردين', show: () => S.company && can('suppliers', 'view') },
  ]},
  { title: 'التقارير', items: [
    { r: 'rep-ledger', i: '📄', l: 'كشف حساب', show: () => S.company && can('reports', 'view') },
    { r: 'rep-journal', i: '📚', l: 'اليومية العامة', show: () => S.company && can('reports', 'view') },
    { r: 'rep-trial', i: '⚖️', l: 'ميزان المراجعة', show: () => S.company && can('reports', 'view') },
    { r: 'rep-income', i: '📈', l: 'قائمة الدخل', show: () => S.company && can('reports', 'view') },
    { r: 'rep-balance', i: '🏦', l: 'الميزانية العمومية', show: () => S.company && can('reports', 'view') },
    { r: 'rep-party', i: '👤', l: 'كشف حساب عميل/مورد', show: () => S.company && can('reports', 'view') },
    { r: 'rep-aging', i: '⏳', l: 'أعمار الذمم', show: () => S.company && can('reports', 'view') },
    { r: 'rep-salestax', i: '🏛️', l: 'إقرار ضريبة المبيعات', show: () => S.company && can('reports', 'view') },
    { r: 'rep-cc', i: '🎯', l: 'تقرير مراكز الكلفة', show: () => S.company && can('reports', 'view') },
    { r: 'rep-fx', i: '💱', l: 'أرصدة العملات', show: () => S.company && can('reports', 'view') },
  ]},
  { title: 'قريباً', items: [
 { soon: true, i: '🧾', l: 'الفوترة الإلكترونية (جوفوترة)' },
  ]},
  { title: 'الأدوات', items: [
    { r: 'numbering', i: '🔢', l: 'طريقة الترقيم', show: () => S.company && can('companies', 'edit') },
    { r: 'backup', i: '💾', l: 'النسخ الاحتياطي', show: isAdmin },
    { r: 'print-settings', i: '🖨️', l: 'نماذج الطباعة', show: () => S.company && can('companies', 'edit') },
  ]},
];

const GROUP_ICONS = { 'الرئيسية': '🏠', 'ملف': '🗂️', 'المالية': '💰', 'الموظفين والرواتب': '👷', 'الأصول الثابتة': '🏗️', 'المخزون': '📦', 'العملاء والذمم المدينة': '🧑‍💼', 'الموردين والذمم الدائنة': '🏭', 'التقارير': '📊', 'قريباً': '⏳', 'الأدوات': '🛠️' };
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

function renderShell() {
  const route = currentRoute();
  const openGroup = groupOfRoute(route) || localStorageGet('sumou.nav.open') || '';
  const initials = (S.profile.full_name || S.profile.email || '?').trim().charAt(0);
  $app.innerHTML = `
    <div class="layout">
      <aside class="sidebar" id="sidebar">
        <div class="side-brand"><img src="icons/icon.svg" alt=""><b>${APP_NAME}</b></div>
        <nav class="nav">
          ${NAV().map(g => {
            const items = g.items.filter(it => it.soon || !it.show || it.show());
            if (!items.length) return '';
            const open = g.title === openGroup;
            return `<div class="nav-group ${open ? 'open' : ''}" data-g="${esc(g.title)}"><button type="button" class="nav-title" aria-expanded="${open}"><span class="ico">${GROUP_ICONS[g.title] || '📁'}</span>${g.title}<span class="chev">›</span></button>
              <div class="nav-items">${items.map(it => it.soon
                ? `<div class="soon"><span class="ico">${it.i}</span>${it.l}<small>قريباً</small></div>`
                : it.href ? `<a href="${it.href}" target="_blank" rel="noopener"><span class="ico">${it.i}</span>${it.l} ↗</a>`
                : `<a href="#/${it.r}" class="${('#/' + it.r) === location.hash ? 'active' : ''}"><span class="ico">${it.i}</span>${it.l}</a>`).join('')}
            </div></div>`;
          }).join('')}
        </nav>
      </aside>
      <div class="main">
        <header class="topbar">
          <button class="btn sm menu-btn" id="menu-btn">☰</button>
          <div class="pill-select"><label>الشركة</label>
            <select id="company-select">
              ${S.companies.filter(c => c.is_active).map(c => `<option value="${c.id}" ${c.id === S.company?.id ? 'selected' : ''}>${esc(c.name)}</option>`).join('') || '<option>لا يوجد شركات</option>'}
            </select></div>
          <div class="pill-select"><label>السنة المالية</label>
            <select id="fy-select">
              ${S.fiscalYears.map(y => `<option value="${y.id}" ${y.id === S.fy?.id ? 'selected' : ''}>${esc(y.name || y.code)}${y.is_closed ? ' (مغلقة)' : ''}</option>`).join('') || '<option>—</option>'}
            </select></div>
          <div class="spacer"></div>
          <a class="btn sm" href="./pdf/" target="_blank" rel="noopener" title="السمو PDF — قارئ ومحرّر الملفات">📕 السمو PDF</a>
          <div class="user-chip"><span>${esc(S.profile.full_name || S.profile.email)}</span><div class="avatar">${esc(initials)}</div></div>
          <button class="btn sm" id="logout">خروج</button>
        </header>
        <section class="content" id="view"></section>
        <div class="watermark" id="watermark" aria-hidden="true"></div>
      </div>
    </div>`;
  updateWatermark();
  document.getElementById('menu-btn').onclick = () => document.getElementById('sidebar').classList.toggle('open');
  document.getElementById('logout').onclick = async () => { await log('خروج', 'auth'); sb.auth.signOut(); };
  document.getElementById('company-select').onchange = async (e) => {
    S.company = S.companies.find(c => c.id === e.target.value) || null;
    localStorageSet('sumou.company', S.company?.id);
    await loadFiscalYears(); renderShell(); route_();
  };
  document.getElementById('fy-select').onchange = (e) => {
    S.fy = S.fiscalYears.find(y => y.id === e.target.value) || null;
    localStorageSet('sumou.fy.' + S.company.id, S.fy?.id);
    updateWatermark(); route_();
  };
  document.querySelectorAll('.nav a').forEach(a => a.addEventListener('click', () => document.getElementById('sidebar').classList.remove('open')));
  document.querySelectorAll('.nav-title').forEach(b => b.addEventListener('click', () => {
    const g = b.closest('.nav-group'); setOpenGroup(g.classList.contains('open') ? null : g.dataset.g);
  }));
}

// علامة مائية على الخلفية: اسم الشركة والسنة المالية الحالية
function updateWatermark() {
  const wm = document.getElementById('watermark'); if (!wm) return;
  if (!S.company) { wm.innerHTML = ''; return; }
  const year = S.fy ? (S.fy.name || S.fy.code) : '';
  wm.innerHTML = `<div class="wm-inner"><div class="wm-name">${esc(S.company.name)}</div>${year ? `<div class="wm-year">${esc(year)}</div>` : ''}</div>`;
}

function currentRoute() { return (location.hash.replace(/^#\/?/, '').split('?')[0]) || 'home'; }

const ROUTES = {
  ...FINANCE_ROUTES, ...REPORT_ROUTES, ...PARTY_ROUTES, ...INVOICE_ROUTES, ...OBLIGATION_ROUTES, ...CHEQUE_ROUTES, ...INVENTORY_ROUTES, ...PRINTSET_ROUTES, ...NUMBERING_ROUTES, ...EXTRA_ROUTES, ...PAYROLL_ROUTES, ...TOOLS_ROUTES,
  'home': viewHome, 'company': viewCompany, 'companies': viewCompanies,
  'fiscal-years': viewFiscalYears, 'users': viewUsers, 'groups': viewGroups, 'log': viewLog,
};

async function route_() {
  const r = currentRoute();
  const fullHash = location.hash || '#/';
  const exact = [...document.querySelectorAll('.nav a')].some(a => a.getAttribute('href') === fullHash);
  document.querySelectorAll('.nav a').forEach(a => a.classList.toggle('active', exact ? a.getAttribute('href') === fullHash : a.getAttribute('href').split('?')[0] === '#/' + r));
  const og = document.querySelector('.nav a.active')?.closest('.nav-group')?.dataset.g || groupOfRoute(r); if (og && !document.querySelector(`.nav-group.open[data-g="${CSS.escape(og)}"]`)) setOpenGroup(og);
  const view = document.getElementById('view'); if (!view) return;
  view.innerHTML = '<div class="empty">جاري التحميل…</div>';
  try { await (ROUTES[r] || viewHome)(view, { rerender: route_, renderShell }); }
  catch (err) { view.innerHTML = `<div class="notice">${esc(arError(err))}</div>`; }
}
window.addEventListener('hashchange', () => { document.getElementById('modal-root').innerHTML = ''; if (S.profile?.is_active) route_(); });

// ---------------------------------------------------------------------
//  لوحة التحكم
// ---------------------------------------------------------------------
async function viewHome(v) {
  if (!S.company) {
    v.innerHTML = `<div class="page-head"><h2>أهلاً ${esc(S.profile.full_name || '')} 👋</h2></div>
      <div class="notice info">${isAdmin()
        ? 'ما في شركات لسا. ابدأ بإضافة أول شركة من <a href="#/companies">الشركات</a>.'
        : 'ما عندك صلاحية على أي شركة لسا. تواصل مع مدير النظام.'}</div>`;
    return;
  }
  const c = S.company;
  v.innerHTML = `
    <div class="page-head"><h2>${esc(c.name)}</h2><span class="badge brand">${esc(c.code)}</span></div>
    <div class="grid cols-4">
      <div class="card stat"><span class="k">السنة المالية الحالية</span><span class="v" style="font-size:18px">${esc(S.fy ? (S.fy.name || S.fy.code) : '—')}</span>
        <span class="muted">${S.fy ? fmtDate(S.fy.start_date) + ' ← ' + fmtDate(S.fy.end_date) : 'ما في سنة مالية'}</span></div>
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
        <div class="field"><label>رمز الشركة *</label><input name="code" required value="${esc(c.code)}" ${ro} dir="ltr"></div>
        <div class="field"><label>اسم الشركة *</label><input name="name" required value="${esc(c.name)}" ${ro}></div>
        <div class="field"><label>الاسم القانوني</label><input name="legal_name" value="${esc(c.legal_name)}" ${ro}></div>
        <div class="field"><label>الاسم التجاري</label><input name="trade_name" value="${esc(c.trade_name)}" ${ro}></div>
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
  if (!d.code || !d.name) { toast('رمز الشركة واسمها مطلوبين', 'err'); return null; }
  if (!isAdmin()) delete d.is_active;
  let res;
  if (id) res = await sb.from('companies').update(d).eq('id', id).select().single();
  else res = await sb.from('companies').insert({ ...d, created_by: S.session.user.id }).select().single();
  if (res.error) { toast(arError(res.error), 'err'); return null; }
  await log(id ? 'تعديل' : 'إضافة', 'companies', res.data.id, { code: d.code, name: d.name });
  toast('تم الحفظ', 'ok');
  return res.data;
}

// ---------------------------------------------------------------------
//  بيانات الشركة الحالية
// ---------------------------------------------------------------------
async function viewCompany(v, ctx, editing = false) {
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
function openCompanyForm(c) {
  const m = modal({ title: c ? 'تعديل شركة: ' + c.name : 'شركة جديدة', body: companyFormHTML(c || {}),
    foot: `<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>` });
  setupTabs(m.el); wireLogo(m.el);
  m.el.querySelector('[data-save]').onclick = async () => {
    const saved = await saveCompany(m.el.querySelector('#company-form'), c?.id);
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
      <td class="actions"><button class="btn sm" data-edit="${c.id}">تعديل</button> <button class="btn sm danger" data-del="${c.id}">حذف</button></td></tr>`).join('')
      || `<tr><td colspan="7" class="empty">ما في شركات</td></tr>`;
  };
  draw();
  v.querySelector('#q').oninput = (e) => draw(e.target.value);
  const open = openCompanyForm;
  v.querySelector('#add').onclick = () => open(null);
  v.querySelector('#rows').onclick = async (e) => {
    const ed = e.target.closest('[data-edit]'), dl = e.target.closest('[data-del]');
    if (ed) open(data.find(x => x.id === ed.dataset.edit));
    if (dl) {
      const c = data.find(x => x.id === dl.dataset.del);
      if (!(await confirmBox(`متأكد بدك تحذف «${c.name}»؟ كل بياناتها رح تنحذف ومش رح ترجع. الأفضل توقفها بدل الحذف.`))) return;
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
        <td>${y.is_closed ? '<span class="badge bad">مغلقة</span>' : '<span class="badge ok">مفتوحة</span>'}</td>
        <td class="actions">
          ${isAdmin() && !y.is_closed ? `<button class="btn sm primary" data-close-year="${y.id}">🔒 إغلاق وتدوير</button>` : ''}
          ${isAdmin() && y.is_closed ? `<button class="btn sm" data-reopen="${y.id}">🔓 إعادة فتح</button>` : ''}
          ${can('fiscal_years', 'edit') && (!y.is_closed || isAdmin()) ? `<button class="btn sm" data-edit="${y.id}">تعديل</button>` : ''}
          ${can('fiscal_years', 'delete') && !y.is_closed ? `<button class="btn sm danger" data-del="${y.id}">حذف</button>` : ''}
        </td></tr>`).join('') || `<tr><td colspan="6" class="empty">ما في سنوات مالية لهالشركة</td></tr>`}</tbody></table></div>
    <p class="muted" style="font-size:13px">إغلاق السنة بيمنع أي تعديل عليها. بس مدير النظام بيقدر يفتحها من جديد.</p>`;
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
      </form>`, foot: `<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>` });
    m.el.querySelector('[data-save]').onclick = async () => {
      const d = formData(m.el.querySelector('#fy-form'));
      if (!d.code || !d.start_date || !d.end_date) return toast('عبّي الحقول المطلوبة', 'err');
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
  const [p, uc, c] = await Promise.all([
    sb.from('profiles').select('*').order('created_at'),
    sb.from('user_companies').select('*'),
    sb.from('companies').select('id,code,name').order('code'),
  ]);
  if (p.error) throw p.error;
  const users = p.data, links = uc.data || [], comps = c.data || [];
  const pending = users.filter(u => !u.is_active).length;
  const login = (u) => u.username || u.email;
  v.innerHTML = `
    <div class="page-head"><h2>👥 المستخدمين</h2><span class="badge brand">${users.length}</span>
      ${pending ? `<span class="badge warn">${pending} بانتظار الموافقة</span>` : ''}<div class="spacer"></div>
      <button class="btn primary" id="u-add">➕ مستخدم جديد</button></div>
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
  v.querySelector('#u-add').onclick = () => userEditor(null, links, comps);
  v.querySelector('tbody').onclick = (e) => {
    const b = e.target.closest('[data-edit]'); if (!b) return;
    userEditor(users.find(x => x.id === b.dataset.edit), links, comps);
  };
}

function userEditor(u, links, comps) {
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
    </div></form>
    <div id="perm-area">
    <div style="display:flex;align-items:center;margin:16px 0 6px"><h3 style="margin:0">🔐 الصلاحيات</h3><div class="spacer" style="flex:1"></div>
      <button class="btn sm" type="button" data-all="1">تحديد الكل</button> <button class="btn sm" type="button" data-all="0">إلغاء الكل</button></div>
    <p class="muted" style="font-size:13px;margin:0 0 8px">المربع الكبير = كل شي على الشاشة. وإذا بدك تحدد، أشّر بس على العمليات الصغيرة (مثلاً «عرض» و«طباعة» بس).</p>
    <div style="display:grid;gap:12px">
      ${groups.map(g => `<div class="card" style="padding:0;overflow:hidden">
        <div style="padding:8px 12px;background:var(--brand-soft, #f1ebf8);font-weight:700">${esc(g)}</div>
        ${SCREENS.filter(s => s.group === g).map(prow).join('')}</div>`).join('')}
    </div>
    <h3 style="margin:16px 0 6px">🏢 الشركات اللي بيشتغل عليها</h3>
    <div class="card" style="padding:0;overflow:hidden">${comps.map(c => row(`data-c="${c.id}"`, `${esc(c.name)} <span class="muted">(${esc(c.code)})</span>`, myComps.has(c.id))).join('') || '<p class="muted" style="padding:10px">ما في شركات</p>'}</div>
    </div>`,
    foot: `<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>
      ${!isNew && !self ? `<button class="btn danger" data-del style="margin-inline-start:auto">حذف المستخدم</button>` : ''}` });
  m.el.querySelector('.modal').style.maxWidth = '860px';
  const f = m.el.querySelector('#u-form');
  // كلمة السر الافتراضية = اسم المستخدم
  if (isNew) { let touched = false; f.password.oninput = () => touched = true; f.username.oninput = () => { if (!touched) f.password.value = f.username.value.trim().toLowerCase(); }; }
  const adminToggle = () => { m.el.querySelector('#perm-area').style.opacity = f.is_admin.checked ? .45 : 1; };
  f.is_admin.onchange = adminToggle; adminToggle();
  const syncRow = (r) => { const as = [...r.querySelectorAll('[data-a]')]; const n = as.filter(x => x.checked).length; const p = r.querySelector('[data-p]');
    p.checked = n > 0; p.indeterminate = n > 0 && n < as.length; };
  m.el.querySelectorAll('[data-row]').forEach(r => { syncRow(r);
    r.querySelector('[data-p]').onchange = (e) => { r.querySelectorAll('[data-a]').forEach(x => x.checked = e.target.checked); syncRow(r); };
    r.querySelectorAll('[data-a]').forEach(x => x.onchange = () => { if (x.checked && x.dataset.a !== 'view') r.querySelector('[data-a="view"]').checked = true; syncRow(r); }); });
  m.el.querySelectorAll('[data-all]').forEach(b => b.onclick = () => m.el.querySelectorAll('[data-row]').forEach(r => { r.querySelectorAll('[data-a]').forEach(x => x.checked = b.dataset.all === '1'); syncRow(r); }));
  m.el.querySelector('[data-save]').onclick = async (e) => {
    const d = formData(f);
    const username = (d.username || '').trim().toLowerCase();
    if (isNew && !username) return toast('اكتب اسم المستخدم', 'err');
    if (username && !/^[a-z0-9._-]{2,30}$/.test(username)) return toast('اسم المستخدم لازم يكون أحرف إنجليزي أو أرقام بدون فراغات', 'err');
    if (isNew && (d.password || '').length < 4) return toast('كلمة السر لازم تكون 4 أحرف على الأقل', 'err');
    const permissions = {};
    m.el.querySelectorAll('[data-row]').forEach(r => { const on = [...r.querySelectorAll('[data-a]')].filter(x => x.checked).map(x => x.dataset.a);
      if (on.length === ACTIONS.length) permissions[r.dataset.row] = true; else if (on.length) permissions[r.dataset.row] = Object.fromEntries(on.map(a => [a, true])); });
    const companies = [...m.el.querySelectorAll('[data-c]')].filter(x => x.checked).map(x => x.dataset.c);
    e.target.disabled = true;
    const r = isNew
      ? await sb.rpc('admin_create_user', { p_username: username, p_full_name: d.full_name, p_password: d.password, p_permissions: permissions, p_companies: companies, p_is_admin: !!d.is_admin })
      : await sb.rpc('admin_update_user', { p_id: u.id, p_username: username || null, p_full_name: d.full_name, p_password: d.password || null, p_permissions: permissions, p_companies: companies, p_is_admin: !!d.is_admin, p_is_active: !!d.is_active });
    if (r.error) { e.target.disabled = false; return toast(arError(r.error), 'err'); }
    toast(isNew ? `تم إنشاء المستخدم «${username}» — بيدخل باسم المستخدم وكلمة السر` : 'تم الحفظ', 'ok');
    if (self) await loadProfile();
    m.close(); route_();
  };
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
      <div class="table-wrap"><table class="t perm-table">
        <thead><tr><th>الشاشة</th>${ACTIONS.map(a => `<th>${a.label}</th>`).join('')}<th>الكل</th></tr></thead>
        <tbody>${SCREENS.map(s => `<tr><td>${s.label}</td>
          ${ACTIONS.map(a => `<td><input type="checkbox" data-s="${s.key}" data-a="${a.key}" ${g.permissions?.[s.key]?.[a.key] ? 'checked' : ''}></td>`).join('')}
          <td><input type="checkbox" data-all="${s.key}"></td></tr>`).join('')}</tbody></table></div>
      <p class="muted" style="font-size:13px">«ترحيل» يعني الموظف بيقدر يرحّل السندات ويعمل قيد عكسي. رح تنضاف شاشات جديدة هون مع كل مرحلة.</p>`,
      foot: `<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>` });
    m.el.querySelectorAll('[data-all]').forEach(cb => cb.onchange = () =>
      m.el.querySelectorAll(`[data-s="${cb.dataset.all}"]`).forEach(x => x.checked = cb.checked));
    m.el.querySelector('[data-save]').onclick = async () => {
      const d = formData(m.el.querySelector('#g-form'));
      if (!d.name) return toast('اسم المجموعة مطلوب', 'err');
      const perms = {};
      m.el.querySelectorAll('[data-s]').forEach(x => { if (x.checked) (perms[x.dataset.s] ||= {})[x.dataset.a] = true; });
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
  const [l, p, c] = await Promise.all([
    sb.from('activity_log').select('*').order('created_at', { ascending: false }).limit(300),
    sb.from('profiles').select('id,full_name,email'),
    sb.from('companies').select('id,name'),
  ]);
  if (l.error) throw l.error;
  const uName = Object.fromEntries((p.data || []).map(x => [x.id, x.full_name || x.email]));
  const cName = Object.fromEntries((c.data || []).map(x => [x.id, x.name]));
  const ent = { companies: 'الشركات', fiscal_years: 'السنوات المالية', users: 'المستخدمين', groups: 'المجموعات', auth: 'الدخول' };
  v.innerHTML = `
    <div class="page-head"><h2>سجل النشاط</h2><span class="muted">آخر 300 عملية</span></div>
    <div class="card table-wrap"><table class="t">
      <thead><tr><th>الوقت</th><th>المستخدم</th><th>العملية</th><th>الشاشة</th><th>الشركة</th><th>التفاصيل</th></tr></thead>
      <tbody>${l.data.map(r => `<tr><td dir="ltr" style="text-align:right">${fmtDateTime(r.created_at)}</td><td>${esc(uName[r.user_id] || '')}</td>
        <td>${esc(r.action)}</td><td>${esc(ent[r.entity] || r.entity || '')}</td><td>${esc(cName[r.company_id] || '')}</td>
        <td class="muted" style="font-size:12px">${esc(r.details ? (r.details.name || r.details.code || r.details.email || '') : '')}</td></tr>`).join('')
        || '<tr><td colspan="6" class="empty">ما في نشاط لسا</td></tr>'}</tbody></table></div>`;
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
    await loadContext();
    renderShell(); route_();
    setTimeout(() => autoBackup().catch(() => {}), 4000);
  } catch (err) {
    $app.innerHTML = `<div class="auth-wrap"><div class="auth-card"><div class="notice">${esc(arError(err))}</div>
      <button class="btn block" onclick="location.reload()">إعادة المحاولة</button></div></div>`;
  } finally { booting = false; }
}
window.__logout = () => sb.auth.signOut();

sb.auth.onAuthStateChange((event, session) => {
  if (event === 'PASSWORD_RECOVERY') { S.session = session; return renderNewPassword(); }
  if (event === 'SIGNED_IN' && !S.profile) { setTimeout(async () => { await boot(); if (S.profile?.is_active) log('دخول', 'auth'); }, 0); }
  if (event === 'SIGNED_OUT') { Object.assign(S, { session: null, profile: null, companies: [], company: null }); renderAuth('login'); }
});

if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
boot();
