// =====================================================================
//  السمو ERP — الأساسيات المشتركة (الاتصال، الحالة، الأدوات، الصلاحيات)
// =====================================================================
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import { SUPABASE_URL, SUPABASE_KEY, APP_NAME, APP_VERSION } from './config.js';

// «مثيل جديد»: نافذة لحالها بتسجيل دخول لحاله (الجلسة بتنحفظ بالنافذة بس، مش مشتركة مع باقي النوافذ)
export const INSTANCE = (() => {
  try {
    const qs = new URLSearchParams(location.search);
    if (qs.has('instance')) {
      sessionStorage.setItem('sumou.instance', qs.get('instance') || String(Date.now()));
      history.replaceState(null, '', location.pathname + location.hash);
    }
    return sessionStorage.getItem('sumou.instance');
  } catch { return null; }
})();
export const sb = createClient(SUPABASE_URL, SUPABASE_KEY, INSTANCE
  ? { auth: { storage: window.sessionStorage, storageKey: 'sumou-auth-' + INSTANCE, persistSession: true } } : {});
// الخروج بيطلّع هالنافذة بس (النوافذ الثانية بتضل داخلة)
export const signOutHere = () => sb.auth.signOut({ scope: 'local' });

// ---------------------------------------------------------------------
//  الحالة العامة
// ---------------------------------------------------------------------
export const S = {
  session: null, profile: null,
  companies: [], memberships: [], groups: [],
  company: null, fiscalYears: [], fy: null,
};

// الشاشات اللي إلها صلاحيات (بتزيد مع كل مرحلة)
export const SCREENS = [
  { key: 'companies',        label: 'بيانات الشركة',       group: 'ملف' },
  { key: 'fiscal_years',     label: 'السنوات المالية والفترات', group: 'ملف' },
  { key: 'departments',      label: 'الدوائر',             group: 'ملف' },
  { key: 'lookups',          label: 'قوائم الإعداد (وسائل الدفع، البنوك، الدول…)', group: 'إعداد' },
  { key: 'accounts',         label: 'دليل الحسابات ومراكز الكلفة', group: 'المالية' },
  { key: 'opening_balances', label: 'الأرصدة الافتتاحية',  group: 'المالية' },
  { key: 'journal_entries',  label: 'سندات القيد',          group: 'المالية' },
  { key: 'receipt_vouchers', label: 'سندات القبض',          group: 'المالية' },
  { key: 'payment_vouchers', label: 'سندات الصرف',          group: 'المالية' },
  { key: 'cheques',          label: 'محفظة الشيكات',        group: 'المالية' },
  { key: 'bank_recon',       label: 'التسوية البنكية',      group: 'المالية' },
  { key: 'payroll',          label: 'الموظفين والرواتب',    group: 'الموظفين والرواتب' },
  { key: 'fixed_assets',     label: 'الأصول الثابتة والاستهلاك', group: 'الأصول الثابتة' },
  { key: 'expense_cards',    label: 'بطاقات المصاريف وفئاتها', group: 'المصاريف' },
  { key: 'items',            label: 'الأصناف وفئات المواد', group: 'المخزون' },
  { key: 'inventory',        label: 'المستودعات وسندات المخزون والجرد', group: 'المخزون' },
  { key: 'customers',        label: 'العملاء وفئاتهم',      group: 'العملاء والذمم المدينة' },
  { key: 'sales_invoices',   label: 'فواتير ومردودات المبيعات', group: 'العملاء والذمم المدينة' },
  { key: 'sales_orders',     label: 'طلبات المبيعات وعروض الأسعار', group: 'العملاء والذمم المدينة' },
  { key: 'suppliers',        label: 'الموردين وفئاتهم',     group: 'الموردين والذمم الدائنة' },
  { key: 'purchase_invoices',label: 'فواتير ومردودات المشتريات', group: 'الموردين والذمم الدائنة' },
  { key: 'purchase_orders',  label: 'طلبات التزويد', group: 'الموردين والذمم الدائنة' },
  { key: 'marketing',        label: 'العروض الترويجية', group: 'التسويق' },
  { key: 'reports',          label: 'التقارير والأستاذ العام والمساعد', group: 'التقارير' },
  { key: 'obligations',      label: 'متابعة إقرارات العملاء', group: 'المكتب' },
];
export const ACTIONS = [
  { key: 'view', label: 'عرض' }, { key: 'add', label: 'إضافة' },
  { key: 'edit', label: 'تعديل' }, { key: 'delete', label: 'حذف' }, { key: 'print', label: 'طباعة' }, { key: 'post', label: 'ترحيل' }, { key: 'unpost', label: 'إلغاء ترحيل' },
];

export const COMPANY_TYPES = ['مؤسسة فردية','شركة تضامن','شركة توصية بسيطة','شركة ذات مسؤولية محدودة','شركة مساهمة خاصة','شركة مساهمة عامة','شركة غير ربحية','جمعية','أخرى'];
export const ACTIVITY_TYPES = ['تجارية','صناعية','خدمية','مقاولات','تعليمية','زراعية','سياحية','أخرى'];

// ---------------------------------------------------------------------
//  أدوات مساعدة
// ---------------------------------------------------------------------
export const esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export const fmtDate = (d) => d ? new Date(d).toLocaleDateString('en-GB') : '';
export const fmtNum = (n, dec = 3) => (Number(n) || 0).toLocaleString('en-US', { minimumFractionDigits: dec, maximumFractionDigits: dec });
export const num = (v) => { const x = parseFloat(String(v ?? '').replace(/,/g, '')); return isFinite(x) ? Math.round(x * 1000) / 1000 : 0; };
export const today = () => new Date().toISOString().slice(0, 10);
export const fmtDateTime = (d) => d ? new Date(d).toLocaleString('en-GB', { hour12: false }) : '';

export function toast(msg, type = '') {
  const el = document.createElement('div');
  el.className = 'toast ' + type; el.textContent = msg;
  document.getElementById('toast-root').appendChild(el);
  setTimeout(() => el.remove(), 3800);
}

export function arError(err) {
  const m = (err && (err.message || err.error_description)) || String(err);
  if (/Invalid login credentials/i.test(m)) return 'الإيميل أو كلمة السر غلط';
  if (/Email not confirmed/i.test(m)) return 'لازم تأكد الإيميل أول. افتح الإيميل اللي وصلك واضغط رابط التأكيد';
  if (/User already registered/i.test(m)) return 'هذا الإيميل مسجّل من قبل';
  if (/Password should be at least/i.test(m)) return 'كلمة السر لازم تكون 6 أحرف أو أكثر';
  if (/duplicate key/i.test(m)) return 'الرمز مستخدم من قبل، اختار رمز ثاني';
  if (/row-level security|permission denied/i.test(m)) return 'ما عندك صلاحية لهالعملية';
  if (/fiscal_years_check|end_date/i.test(m)) return 'تاريخ النهاية لازم يكون بعد تاريخ البداية';
  if (/check constraint/i.test(m)) return 'في قيمة مش مسموحة (مثلاً مبلغ أو كمية سالبة، أو مدين ودائن بنفس السطر)';
  if (/foreign key constraint/i.test(m)) return 'ما بينحذف لأنه مستخدم (عليه حسابات أو قيود)';
  if (/Failed to fetch|NetworkError/i.test(m)) return 'في مشكلة بالاتصال بالإنترنت';
  return m;
}

export function modal({ title, body, foot = '', size = '' }) {
  const root = document.getElementById('modal-root');
  root.innerHTML = `
    <div class="modal-back">
      <div class="modal ${size}">
        <div class="modal-head"><h3>${esc(title)}</h3><button class="x" data-close>×</button></div>
        <div class="modal-body">${body}</div>
        ${foot ? `<div class="modal-foot">${foot}</div>` : ''}
      </div>
    </div>`;
  const back = root.firstElementChild;
  const close = () => { root.innerHTML = ''; };
  back.addEventListener('click', e => { if (e.target === back || e.target.closest('[data-close]')) close(); });
  return { el: back, close };
}

export function confirmBox(text) {
  return new Promise(resolve => {
    const m = modal({ title: 'تأكيد', size: 'sm', body: `<p>${esc(text)}</p>`,
      foot: `<button class="btn primary" data-yes>نعم</button><button class="btn" data-close>إلغاء</button>` });
    m.el.querySelector('[data-yes]').onclick = () => { m.close(); resolve(true); };
    m.el.querySelectorAll('[data-close]').forEach(b => b.addEventListener('click', () => resolve(false)));
  });
}

export function formData(form) {
  const o = {};
  form.querySelectorAll('[name]').forEach(el => {
    if (el.type === 'checkbox') o[el.name] = el.checked;
    else o[el.name] = el.value.trim() === '' ? null : el.value.trim();
  });
  return o;
}

export function setupTabs(root) {
  root.querySelectorAll('.tabs').forEach(tabs => {
    tabs.addEventListener('click', e => {
      const t = e.target.closest('.tab'); if (!t) return;
      const scope = tabs.parentElement;
      scope.querySelectorAll(':scope > .tabs .tab').forEach(x => x.classList.toggle('active', x === t));
      scope.querySelectorAll(':scope > .tab-panel').forEach(p => p.classList.toggle('active', p.dataset.tab === t.dataset.tab));
    });
  });
}

export async function log(action, entity, entity_id = null, details = null) {
  try {
    await sb.from('activity_log').insert({ user_id: S.session.user.id, company_id: S.company?.id ?? null, action, entity, entity_id, details });
  } catch (_) { /* السجل ما لازم يوقف الشغل */ }
}

// ---------------------------------------------------------------------
//  الصلاحيات (للواجهة فقط — الحماية الحقيقية بقاعدة البيانات)
// ---------------------------------------------------------------------
export const isAdmin = () => !!(S.profile?.is_admin && S.profile?.is_active);
export function can(screen, act, companyId = S.company?.id) {
  if (isAdmin()) return true;
  const m = S.memberships.find(x => x.company_id === companyId);
  const up = S.profile?.permissions?.[screen];
  if (m && (up === true || up?.[act])) return true;
  const g = m && S.groups.find(x => x.id === m.group_id);
  return !!g?.permissions?.[screen]?.[act];
}

// ---------------------------------------------------------------------
//  تحميل البيانات
// ---------------------------------------------------------------------
export async function loadProfile() {
  const { data, error } = await sb.from('profiles').select('*').eq('id', S.session.user.id).maybeSingle();
  if (error) throw error;
  S.profile = data;
}

export async function loadContext() {
  const [c, m, g] = await Promise.all([
    sb.from('companies').select('*').order('code'),
    sb.from('user_companies').select('*').eq('user_id', S.session.user.id),
    sb.from('user_groups').select('*').order('name'),
  ]);
  if (c.error) throw c.error;
  S.companies = c.data || [];
  S.memberships = m.data || [];
  S.groups = g.data || [];
  const saved = localStorageGet('sumou.company') || S.profile.default_company_id;
  S.company = S.companies.find(x => x.id === saved && x.is_active) || S.companies.find(x => x.is_active) || null;
  await loadFiscalYears();
}

export async function loadFiscalYears() {
  S.fiscalYears = []; S.fy = null;
  if (!S.company) return;
  const { data } = await sb.from('fiscal_years').select('*').eq('company_id', S.company.id).order('start_date', { ascending: false });
  S.fiscalYears = data || [];
  const saved = localStorageGet('sumou.fy.' + S.company.id);
  const today = new Date().toISOString().slice(0, 10);
  S.fy = S.fiscalYears.find(x => x.id === saved)
      || S.fiscalYears.find(x => x.start_date <= today && x.end_date >= today)
      || S.fiscalYears[0] || null;
}

export function localStorageGet(k) { try { return localStorage.getItem(k); } catch { return null; } }
export function localStorageSet(k, v) { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch {} }
