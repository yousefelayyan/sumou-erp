// =====================================================================
//  السمو ERP — المرحلة 5 و6: الفواتير وضريبة المبيعات
//  حسابات الربط، الأصناف والخدمات، فواتير البيع والشراء والمرتجعات، تقرير الإقرار
// =====================================================================
import { attachAudit } from './audit.js';
import { docTypeField, docTypeValue, docCopies, docTypeName, loadDocTypes, docCommittee } from './doctypes.js';
import { attachDocNav, setNavList } from './docnav.js';
import { deptField, deptValue } from './departments.js';
import { loadLookups, pmOptions, repOptions, hasReps } from './lookups.js';
import { loadCustomFields, cfFieldsHTML, cfValues } from './orders.js';
import { loadFieldLayout, applyLayout, checkRequired } from './mfg.js';
import { docNo, loadNumbering, isManual, manualField, readManual, masterCode, ruleSync } from './numbering.js';
import { loadPosting, postFlag, postBarHTML, wirePostBar } from './posting.js';
import { S, sb, esc, fmtDate, fmtNum, num, today, toast, arError, modal, confirmBox, formData, can, log, isAdmin, fmtPrice, fmtQty, DEC } from './core.js';
import { loadAccounts, leafAccounts, accLabel, downloadCSV } from './finance.js';
import { loadParties, partyDatalist, resolveParty, partyLabel } from './parties.js';
import { printDoc, amountToWords, loadPrintSettings } from './print.js';
import { msgTemplates, fillTpl, sendWhatsApp } from './messages.js';
import { attachFollow, followMap, followBadge, loadStatuses } from './follow.js';
import { openAttachments } from './attach.js';

export const INV = {
  sale:            { label: 'فاتورة بيع',   group: 'sales',     screen: 'sales_invoices',    partyType: 'customer', partyLabel: 'العميل' },
  sale_return:     { label: 'مرتجع بيع',    group: 'sales',     screen: 'sales_invoices',    partyType: 'customer', partyLabel: 'العميل' },
  purchase:        { label: 'فاتورة شراء',  group: 'purchases', screen: 'purchase_invoices', partyType: 'supplier', partyLabel: 'المورد' },
  purchase_return: { label: 'مرتجع شراء',   group: 'purchases', screen: 'purchase_invoices', partyType: 'supplier', partyLabel: 'المورد' },
};
const ST = { draft: ['مسودة', 'warn'], posted: ['مرحّلة', 'ok'], cancelled: ['ملغاة', 'bad'] };
const badge = (s) => `<span class="badge ${ST[s][1]}">${ST[s][0]}</span>`;
const r3 = (x) => Math.round(x * 1000) / 1000;

function guard(v) {
  if (!S.company) { v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`; return false; }
  if (!S.fy) { v.innerHTML = `<div class="notice">هالشركة ما إلها سنة مالية. <a href="#/fiscal-years">أضف سنة مالية</a> أول.</div>`; return false; }
  return true;
}

async function loadSettings() {
  await sb.rpc('ensure_company_settings', { p_company: S.company.id });
  const { data } = await sb.from('company_settings').select('*').eq('company_id', S.company.id).maybeSingle();
  return data || { default_tax_rate: 16 };
}

const itemRule = () => ruleSync('m_item');
// فئات المواد: إضافة وتعديل وحذف
function categoriesDialog(cats, items, ctx) {
  const canAdd = can('items', 'add'), canEd = can('items', 'edit'), canDel = can('items', 'delete');
  const used = (id) => items.filter(i => i.category_id === id).length;
  const m = modal({ title: '🗂️ فئات المواد', body: `
    <p class="muted" style="margin-top:0">الفئة بتجمّع الأصناف (مثلاً: مشروبات، قرطاسية). من «طريقة الترقيم» بتقدر تخلّي رقم الصنف يبدأ برمز فئته.</p>
    <div class="table-wrap"><table class="t"><thead><tr><th style="width:110px">الرمز</th><th>اسم الفئة</th><th title="أعلى نسبة خصم للأصناف اللي ما إلها حد">أعلى خصم %</th><th title="أقل ربح فوق الكلفة">أقل هامش %</th><th>عدد الأصناف</th><th>فعّالة</th><th></th></tr></thead><tbody id="crows"></tbody></table></div>
    ${canAdd ? '<button class="btn sm" id="c-add" type="button" style="margin-top:8px">➕ فئة جديدة</button>' : ''}`,
    foot: `<button class="btn" data-close>إغلاق</button>` });
  let changed = false;
  const draw = () => {
    m.el.querySelector('#crows').innerHTML = cats.map(c => `<tr data-id="${c.id}"><td><input data-f="code" value="${esc(c.code)}" dir="ltr" ${canEd ? '' : 'disabled'}></td>
      <td><input data-f="name" value="${esc(c.name)}" ${canEd ? '' : 'disabled'}></td>
      <td><input data-f="max_discount_pct" value="${c.max_discount_pct ?? ''}" dir="ltr" style="width:70px" ${canEd ? '' : 'disabled'}></td>
      <td><input data-f="min_margin_pct" value="${c.min_margin_pct ?? ''}" dir="ltr" style="width:70px" ${canEd ? '' : 'disabled'}></td><td>${used(c.id)}</td>
      <td><input type="checkbox" data-f="is_active" ${c.is_active ? 'checked' : ''} ${canEd ? '' : 'disabled'}></td>
      <td class="actions">${canEd ? '<button class="btn sm" data-save type="button">💾</button>' : ''} ${canDel && !used(c.id) ? '<button class="btn sm danger" data-del type="button">حذف</button>' : ''}</td></tr>`).join('')
      || '<tr><td colspan="7" class="empty">ما في فئات لسا</td></tr>';
  };
  draw();
  m.el.querySelector('#c-add')?.addEventListener('click', async () => {
    const code = masterCode('m_item_category', cats.map(c => c.code)) ?? String(Math.max(0, ...cats.map(c => parseInt(c.code, 10) || 0)) + 1);
    const { data, error } = await sb.from('item_categories').insert({ company_id: S.company.id, code, name: 'فئة جديدة' }).select().single();
    if (error) return toast(arError(error), 'err');
    cats.push(data); changed = true; draw(); m.el.querySelector(`[data-id="${data.id}"] [data-f=name]`)?.select();
  });
  m.el.querySelector('#crows').addEventListener('click', async (e) => {
    const tr = e.target.closest('[data-id]'); if (!tr) return; const c = cats.find(x => x.id === tr.dataset.id);
    if (e.target.closest('[data-save]')) {
      const d = { code: tr.querySelector('[data-f=code]').value.trim(), name: tr.querySelector('[data-f=name]').value.trim(), is_active: tr.querySelector('[data-f=is_active]').checked, max_discount_pct: (v => v === '' ? null : num(v))(tr.querySelector('[data-f=max_discount_pct]').value.trim()), min_margin_pct: (v => v === '' ? null : num(v))(tr.querySelector('[data-f=min_margin_pct]').value.trim()) };
      if (!d.code || !d.name) return toast('الرمز والاسم مطلوبين', 'err');
      const { error } = await sb.from('item_categories').update(d).eq('id', c.id); if (error) return toast(arError(error), 'err');
      Object.assign(c, d); changed = true; await log('تعديل', 'item_categories', c.id, { name: d.name }); toast('تم الحفظ', 'ok');
    }
    if (e.target.closest('[data-del]')) {
      const b = e.target.closest('[data-del]'); if (!b.dataset.sure) { b.dataset.sure = '1'; b.textContent = 'متأكد؟'; return; }
      const { error } = await sb.from('item_categories').delete().eq('id', c.id); if (error) return toast(arError(error), 'err');
      cats.splice(cats.indexOf(c), 1); changed = true; draw();
    }
  });
  m.el.addEventListener('click', (e) => { if (changed && (e.target === m.el || e.target.closest('[data-close]'))) ctx.rerender(); });
}

// تصغير الصورة لـ 320 بكسل (JPEG) عشان تنحفظ مع الصنف وتفتح بسرعة بالكاشير
export function shrinkImage(file, max = 320) {
  return new Promise((res, rej) => {
    const url = URL.createObjectURL(file), img = new Image();
    img.onload = () => {
      const k = Math.min(1, max / Math.max(img.width, img.height));
      const c = document.createElement('canvas'); c.width = Math.round(img.width * k); c.height = Math.round(img.height * k);
      const g = c.getContext('2d'); g.fillStyle = '#fff'; g.fillRect(0, 0, c.width, c.height); g.drawImage(img, 0, 0, c.width, c.height);
      URL.revokeObjectURL(url); res(c.toDataURL('image/jpeg', 0.8));
    };
    img.onerror = () => { URL.revokeObjectURL(url); rej(new Error('img')); };
    img.src = url;
  });
}

export async function loadItems(force = false) {
  if (!force && S.items && S.itemsCompany === S.company.id) return S.items;
  // بدون الصورة (ثقيلة)؛ محرر الصنف بيجيبها لحاله
  const { data, error } = await sb.from('items').select('id,company_id,code,name,item_type,unit,barcode,sale_price,purchase_price,tax_rate,sales_account_id,purchase_account_id,is_active,notes,created_at,track_stock,qty_check_ignore,batch_mode,category_id,brand_id,origin_id,model,color,size,min_price,max_discount_pct,created_by,updated_by,updated_at,extra').eq('company_id', S.company.id).order('code').limit(5000);
  if (error) throw error;
  S.items = data; S.itemsCompany = S.company.id; return data;
}
const itemLabel = (i) => i ? `${i.code} — ${i.name}` : '';
const resolveItem = (items, t) => { t = (t || '').trim(); if (!t) return null; const c = t.split('—')[0].trim(); return items.find(i => i.code === c) || items.find(i => i.name === t || i.barcode === t) || null; };

// ---------------------------------------------------------------------
//  حسابات الربط والضريبة
// ---------------------------------------------------------------------
async function viewSettings(v, ctx) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const [accs, st] = await Promise.all([loadAccounts(), loadSettings()]);
  await sb.rpc('ensure_payroll_settings', { p_company: S.company.id }).then(() => null, () => null);
  Object.assign(st, (await sb.from('company_settings').select('*').eq('company_id', S.company.id).maybeSingle()).data || {});
  const editable = can('companies', 'edit');
  const leaves = leafAccounts(accs);
  const sel = (name, hint) => `<div class="field"><label>${hint}</label><select name="${name}" ${editable ? '' : 'disabled'}><option value="">— غير محدد —</option>
    ${leaves.map(a => `<option value="${a.id}" ${st[name] === a.id ? 'selected' : ''}>${esc(accLabel(a))}</option>`).join('')}</select></div>`;
  v.innerHTML = `<div class="page-head"><h2>🔗 حسابات الربط والضريبة</h2><div class="spacer"></div>${editable ? '<button class="btn primary" id="save">💾 حفظ</button>' : ''}</div>
    ${!accs.length ? `<div class="notice">لازم يكون في دليل حسابات أول. <a href="#/accounts">روح لدليل الحسابات</a></div>` : ''}
    <p class="muted">هاي الحسابات اللي بتنقيّد عليها الفواتير تلقائياً لما ترحّلها. إذا الدليل جاهز، انعبّت لحالها.</p>
    <form id="st-form" class="card"><div class="grid cols-2">
      <div class="field"><label>نسبة ضريبة المبيعات الافتراضية %</label><input name="default_tax_rate" value="${st.default_tax_rate ?? 16}" inputmode="decimal" dir="ltr" ${editable ? '' : 'disabled'}></div><div></div>
      ${sel('sales_account_id', 'حساب المبيعات')}${sel('sales_return_account_id', 'حساب مردودات المبيعات')}
      ${sel('purchase_account_id', 'حساب المشتريات')}${sel('purchase_return_account_id', 'حساب مردودات المشتريات')}
      ${sel('output_tax_account_id', 'ضريبة المبيعات - مخرجات (على المبيعات)')}${sel('input_tax_account_id', 'ضريبة المبيعات - مدخلات (على المشتريات)')}
      ${sel('cash_account_id', 'الصندوق الافتراضي للفواتير النقدية')}<div></div>
      ${sel('cheques_in_account_id', 'شيكات برسم التحصيل (الواردة)')}${sel('cheques_out_account_id', 'شيكات آجلة الدفع (الصادرة)')}
    </div>
    <h3 style="margin:16px 0 6px">📦 طريقة قيد المخزون</h3>
    <label class="check"><input type="checkbox" name="perpetual_inventory" ${st.perpetual_inventory ? 'checked' : ''} ${editable ? '' : 'disabled'}> <b>جرد مستمر</b>: كلفة البضاعة المباعة بتنقيّد لحالها مع كل فاتورة بيع، والمشتريات بتروح لحساب المخزون</label>
    <p class="muted" style="font-size:13px;margin:4px 0 8px">إذا مش مأشّر (جرد دوري): المشتريات بتنقيّد مصروف، وقيمة المخزون آخر السنة بتاخذها من تقرير رصيد المخزون. الأفضل تختار الطريقة أول السنة وما تغيّرها بنصّها.</p>
    <div class="grid cols-2">${sel('inventory_account_id', 'حساب المخزون')}${sel('cogs_account_id', 'حساب كلفة البضاعة المباعة (وفروقات الجرد)')}
      ${sel('wip_account_id', 'الإنتاج تحت التشغيل (لأوامر الإنتاج)')}
      <div class="field"><label>&nbsp;</label>${editable && !st.wip_account_id ? '<button type="button" class="btn sm" id="mk-wip">➕ اعمل حساب «الإنتاج تحت التشغيل» لحاله</button>' : ''}</div></div>
    <p class="muted" style="font-size:12px;margin:4px 0 8px">أمر الإنتاج: إخراج المواد من ح/ الإنتاج تحت التشغيل إلى ح/ المخزون، وإدخال المنتج من ح/ المخزون إلى ح/ الإنتاج تحت التشغيل. قيّد الأجور والتشغيل على نفس الحساب بسند قيد عشان يتصفّر.</p>
    <h3 style="margin:16px 0 6px">💵 الرواتب والضمان</h3>
    <div class="grid cols-3">
      <div class="field"><label>ضمان الموظف %</label><input name="ss_employee_rate" value="${st.ss_employee_rate ?? 7.5}" inputmode="decimal" dir="ltr" ${editable ? '' : 'disabled'}></div>
      <div class="field"><label>ضمان المنشأة %</label><input name="ss_employer_rate" value="${st.ss_employer_rate ?? 14.25}" inputmode="decimal" dir="ltr" ${editable ? '' : 'disabled'}></div>
      <div class="field"><label>سقف الأجر الخاضع (0 = بدون)</label><input name="ss_ceiling" value="${st.ss_ceiling ?? 0}" inputmode="decimal" dir="ltr" ${editable ? '' : 'disabled'}></div></div>
    <div class="grid cols-2">${sel('salaries_account_id', 'مصروف الرواتب والأجور')}${sel('ss_expense_account_id', 'مصروف حصة المنشأة بالضمان')}
      ${sel('ss_payable_account_id', 'أمانات الضمان الاجتماعي')}${sel('wht_payable_account_id', 'أمانات ضريبة الدخل')}
      ${sel('salaries_payable_account_id', 'رواتب مستحقة (الصافي)')}${sel('advances_account_id', 'سلف وذمم الموظفين')}</div>
    <h3 style="margin:16px 0 6px">🏢 الأصول الثابتة</h3>
    <div class="grid cols-2">${sel('depreciation_account_id', 'مصروف الاستهلاك (الافتراضي)')}${sel('accum_dep_account_id', 'مجمع الاستهلاك (الافتراضي)')}
      ${sel('asset_disposal_account_id', 'أرباح وخسائر بيع وشطب الأصول')}
      <div class="field"><label>&nbsp;</label>${editable && !st.asset_disposal_account_id ? '<button type="button" class="btn sm" id="mk-disp">➕ اعمل حساب «أرباح (خسائر) بيع وشطب أصول» لحاله</button>' : ''}</div></div><h3 style="margin:16px 0 6px">🏅 بطاقات الولاء</h3><div class="grid cols-2">${sel('cashback_account_id', 'مصروف الاسترداد النقدي (حساب مصاريف)')}</div><div class="field"><label>ملاحظة أسفل الفاتورة المطبوعة</label><textarea name="invoice_footer" style="min-height:60px" ${editable ? '' : 'disabled'}>${esc(st.invoice_footer)}</textarea></div>
      <h3 style="margin:16px 0 6px">📦 المخزون</h3>
      <div class="field" style="max-width:520px"><label>سقف الائتمان للزبائن (الفاتورة الآجلة)</label><select name="credit_limit_mode" ${editable ? '' : 'disabled'}>
        <option value="warn" ${st.credit_limit_mode !== 'block' ? 'selected' : ''}>تنبيه بس</option>
        <option value="block" ${st.credit_limit_mode === 'block' ? 'selected' : ''}>منع الترحيل فوق السقف (إلا لمين إله صلاحية «تجاوز سقف الائتمان»)</option></select></div>
      <label class="check"><input type="checkbox" name="block_below_cost" ${st.block_below_cost ? 'checked' : ''} ${editable ? '' : 'disabled'}> منع البيع بسعر أقل من الكلفة (إلا لمين إله صلاحية «تجاوز ضوابط الأسعار»)</label>
      <label class="check"><input type="checkbox" name="use_last_price" ${st.use_last_price ? 'checked' : ''} ${editable ? '' : 'disabled'}> 🕘 الفاتورة بتاخذ آخر سعر بعته للزبون (أو اشتريته من المورد) لما تختار الصنف — قائمة الأسعار أولى</label>
      <div class="grid cols-2" style="max-width:640px;margin:6px 0"><div class="field"><label>🧪 نبّهني قبل انتهاء الدفعة بـ (يوم)</label><input type="number" name="expiry_warn_days" min="0" max="730" value="${st.expiry_warn_days ?? 60}" ${editable ? '' : 'disabled'}></div><div></div></div>
      <label class="check"><input type="checkbox" name="block_expired_sale" ${st.block_expired_sale ? 'checked' : ''} ${editable ? '' : 'disabled'}> 🧪 منع بيع دفعة منتهية (والبيع التلقائي دايماً بيتخطّى المنتهي)</label>
      <label class="check"><input type="checkbox" name="block_negative_stock" ${st.block_negative_stock ? 'checked' : ''} ${editable ? '' : 'disabled'}> منع البيع والإخراج بأكثر من الكمية المتوفرة بالمستودع (البيع بالسالب)</label>
      <p class="muted" style="font-size:12px;margin:2px 0 0">الصنف اللي مأشّر عليه «تجاهل تتبع الكمية» بنوع المستند ما بيتفحص.</p>
      <h3 style="margin:16px 0 6px">🔢 الخانات العشرية بالعرض والطباعة</h3>
      <div class="grid cols-3" style="max-width:640px">${[['amount', 'المبالغ'], ['qty', 'الكميات'], ['price', 'الأسعار']].map(([k, l]) => `<div class="field"><label>${l}</label><select data-dec="${k}" ${editable ? '' : 'disabled'}>${[0, 1, 2, 3].map(n => `<option value="${n}" ${((st.decimals || {})[k] ?? 3) === n ? 'selected' : ''}>${n} — ${(1234.5678).toLocaleString('en-US', { minimumFractionDigits: n, maximumFractionDigits: n })}</option>`).join('')}</select></div>`).join('')}</div>
      <p class="muted" style="font-size:12px;margin:2px 0 0">بتأثر على طريقة عرض الأرقام بالشاشات والطباعة بس؛ الحسابات والتخزين بيضلوا بثلاث خانات.</p>
      <h3 style="margin:16px 0 6px">🧾 بيان قيود الشيكات</h3>
      <p class="muted" style="font-size:12px;margin:0 0 6px">اكتب البيان لكل عملية، واستعمل الكلمات: <b>[رقم الشيك]</b> <b>[الطرف]</b> <b>[البنك]</b> <b>[الاستحقاق]</b> <b>[المبلغ]</b> <b>[ملاحظات]</b>. الفاضي بياخذ البيان الافتراضي.</p>
      <div class="grid cols-2">${[['receive', 'استلام شيك وارد'], ['deposit', 'إيداع بالبنك'], ['collect_in', 'تحصيل وارد'], ['return_in', 'إرجاع وارد'], ['undeposit', 'سحب من الإيداع'], ['issue', 'إصدار شيك صادر'], ['collect_out', 'صرف صادر'], ['return_out', 'إرجاع/إلغاء صادر']]
        .map(([k, l]) => `<div class="field"><label>${l}</label><input data-ctpl="${k}" value="${esc((st.cheque_templates || {})[k] || '')}" placeholder="${k === 'deposit' ? 'إيداع شيك وارد رقم: [رقم الشيك] / [البنك] حق [الاستحقاق]' : ''}" ${editable ? '' : 'disabled'}></div>`).join('')}</div></form>`;
  v.querySelector('#save')?.addEventListener('click', async () => {
    const d = formData(v.querySelector('#st-form')); d.default_tax_rate = num(d.default_tax_rate);
    d.block_negative_stock = !!d.block_negative_stock; d.block_below_cost = !!d.block_below_cost; d.use_last_price = !!d.use_last_price; d.block_expired_sale = !!d.block_expired_sale; d.expiry_warn_days = Math.max(0, Math.min(730, Math.round(num(d.expiry_warn_days ?? 60)))); d.credit_limit_mode = d.credit_limit_mode === 'block' ? 'block' : 'warn';
    d.decimals = Object.fromEntries([...v.querySelectorAll('[data-dec]')].map(i => [i.dataset.dec, +i.value]));
    d.cheque_templates = Object.fromEntries([...v.querySelectorAll('[data-ctpl]')].map(i => [i.dataset.ctpl, i.value.trim()]).filter(([, x]) => x));
    ['ss_employee_rate', 'ss_employer_rate', 'ss_ceiling'].forEach(k => d[k] = num(d[k])); d.company_id = S.company.id; d.updated_at = new Date().toISOString();
    const { error } = await sb.from('company_settings').upsert(d);
    if (error) return toast(arError(error), 'err');
    Object.assign(DEC, d.decimals);
    await log('تعديل', 'settings', S.company.id); toast('تم الحفظ', 'ok');
  });
  v.querySelector('#mk-disp')?.addEventListener('click', async () => {
    const { error } = await sb.rpc('ensure_asset_disposal_account', { p_company: S.company.id }); if (error) return toast(arError(error), 'err');
    toast('انعمل الحساب وانربط', 'ok'); S.accounts = null; viewSettings(v);
  });
  v.querySelector('#mk-wip')?.addEventListener('click', async () => {
    const { error } = await sb.rpc('ensure_wip_account', { p_company: S.company.id }); if (error) return toast(arError(error), 'err');
    toast('انعمل الحساب وانربط', 'ok'); S.accounts = null; viewSettings(v);
  });
}

// ---------------------------------------------------------------------
//  الأصناف والخدمات
// ---------------------------------------------------------------------
async function viewItems(v, ctx) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const [items, accs, st, , catR] = await Promise.all([loadItems(true), loadAccounts(), loadSettings(), loadNumbering(true),
    sb.from('item_categories').select('*').eq('company_id', S.company.id).order('code'), loadCustomFields(), loadFieldLayout()]);
  const cats = catR.data || [], catById = Object.fromEntries(cats.map(c => [c.id, c]));
  const lks = await loadLookups(), brands = lks.filter(l => l.kind === 'brand'), countries = lks.filter(l => l.kind === 'country'), brById = Object.fromEntries(brands.map(b => [b.id, b]));
  v.innerHTML = `<div class="page-head"><h2>🏷️ الأصناف والخدمات</h2><span class="badge brand">${items.length}</span><div class="spacer"></div>
      <select class="search" id="fc" style="min-width:140px"><option value="">كل الفئات</option>${cats.map(c => `<option value="${c.id}">${esc(c.name)}</option>`).join('')}<option value="-">بدون فئة</option></select>
      ${brands.length ? `<select class="search" id="fb" style="min-width:130px"><option value="">كل الماركات</option>${brands.map(b => `<option value="${b.id}">${esc(b.name)}</option>`).join('')}<option value="-">بدون ماركة</option></select>` : ''}
      <input class="search" id="q" placeholder="بحث بالاسم أو الرقم أو الباركود…"><button class="btn sm" id="cats">🗂️ فئات المواد</button><button class="btn sm" id="csv">⬇️ Excel</button>
      ${can('items', 'add') ? '<button class="btn primary" id="add">➕ صنف / خدمة</button>' : ''}</div>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرقم</th><th>الاسم</th><th>الفئة</th><th>الماركة</th><th>النوع</th><th>الوحدة</th><th style="text-align:left">سعر البيع</th><th style="text-align:left">سعر الشراء</th><th>الضريبة</th><th>الحالة</th><th></th></tr></thead><tbody id="rows"></tbody></table></div>`;
  const draw = () => {
    const q = v.querySelector('#q').value.trim().toLowerCase(), fc = v.querySelector('#fc').value, fb = v.querySelector('#fb')?.value || '';
    v.querySelector('#rows').innerHTML = items.filter(i => (!fc || (fc === '-' ? !i.category_id : i.category_id === fc)) && (!fb || (fb === '-' ? !i.brand_id : i.brand_id === fb)) && (!q || [i.code, i.name, i.barcode, i.model].some(x => (x || '').toLowerCase().includes(q)))).map(i => `<tr>
      <td>${esc(i.code)}</td><td><b>${esc(i.name)}</b></td><td>${esc(catById[i.category_id]?.name || '')}</td><td>${esc(brById[i.brand_id]?.name || '')}</td><td>${i.item_type === 'service' ? 'خدمة' : 'سلعة'}</td><td>${esc(i.unit || '')}</td>
      <td dir="ltr" style="text-align:left">${fmtPrice(i.sale_price)}</td><td dir="ltr" style="text-align:left">${fmtPrice(i.purchase_price)}</td><td>${num(i.tax_rate)}%</td>
      <td>${i.is_active ? '<span class="badge ok">فعّال</span>' : '<span class="badge bad">موقوف</span>'}</td>
      <td class="actions">${can('items', 'edit') ? `<button class="btn sm" data-edit="${i.id}">تعديل</button>` : ''} ${can('items', 'delete') ? `<button class="btn sm danger" data-del="${i.id}">حذف</button>` : ''}</td></tr>`).join('')
      || '<tr><td colspan="11" class="empty">ما في أصناف. الأصناف اختيارية، بتقدر تكتب بيان السطر بالفاتورة مباشرة.</td></tr>';
  };
  draw(); v.querySelector('#q').oninput = draw; v.querySelector('#fc').onchange = draw; if (v.querySelector('#fb')) v.querySelector('#fb').onchange = draw;
  v.querySelector('#cats').onclick = () => categoriesDialog(cats, items, ctx);
  v.querySelector('#csv').onclick = () => downloadCSV('الأصناف.csv', [['الرقم', 'الاسم', 'الفئة', 'الماركة', 'الطراز', 'النوع', 'الوحدة', 'الباركود', 'سعر البيع', 'سعر الشراء', 'الضريبة']].concat(items.map(i => [i.code, i.name, catById[i.category_id]?.name || '', brById[i.brand_id]?.name || '', i.model || '', i.item_type === 'service' ? 'خدمة' : 'سلعة', i.unit, i.barcode, i.sale_price, i.purchase_price, i.tax_rate])));
  const open = async (it) => {
    const isNew = !it;
    if (it && it.image === undefined) { const { data: im } = await sb.from('items').select('image').eq('id', it.id).maybeSingle(); it.image = im?.image || null; }
    const suggest = (catId) => { const c = catById[catId], byCat = itemRule()?.by_category;
      return masterCode('m_item', items.filter(x => !byCat || (x.category_id || null) === (catId || null)).map(x => x.code), byCat ? c?.code || null : null)
        ?? String((items.map(x => parseInt(x.code)).filter(n => !isNaN(n)).sort((a, b) => b - a)[0] || 0) + 1); };
    it = it || { code: suggest(null), category_id: null, name: '', item_type: 'goods', unit: 'حبة', sale_price: 0, purchase_price: 0, tax_rate: st.default_tax_rate ?? 16, is_active: true };
    const leaves = leafAccounts(accs);
    const accSel = (name, def) => `<select name="${name}"><option value="">— الافتراضي (${esc(accs.find(a => a.id === def)?.name || 'من حسابات الربط')}) —</option>${leaves.map(a => `<option value="${a.id}" ${it[name] === a.id ? 'selected' : ''}>${esc(accLabel(a))}</option>`).join('')}</select>`;
    const m = modal({ title: isNew ? 'صنف / خدمة جديدة' : 'تعديل: ' + it.name, body: `<form id="i-form"><div class="grid cols-2">
      <div class="field"><label>الرقم *</label><input name="code" value="${esc(it.code)}" dir="ltr"></div>
      <div class="field"><label>الاسم *</label><input name="name" value="${esc(it.name)}"></div>
      <div class="field"><label>الفئة</label><select name="category_id"><option value="">— بدون فئة —</option>${cats.filter(c => c.is_active || c.id === it.category_id).map(c => `<option value="${c.id}" ${c.id === it.category_id ? 'selected' : ''}>${esc(c.code)} — ${esc(c.name)}</option>`).join('')}</select></div>
      <div class="field"><label>النوع</label><select name="item_type"><option value="goods" ${it.item_type === 'goods' ? 'selected' : ''}>سلعة</option><option value="service" ${it.item_type === 'service' ? 'selected' : ''}>خدمة</option></select></div>
      <div class="field"><label>الوحدة</label><input name="unit" value="${esc(it.unit)}"></div>
      <div class="field"><label>سعر البيع</label><input name="sale_price" value="${it.sale_price || ''}" inputmode="decimal" dir="ltr"></div>
      <div class="field"><label>سعر الشراء</label><input name="purchase_price" value="${it.purchase_price || ''}" inputmode="decimal" dir="ltr"></div>
      <div class="field"><label>أقل سعر بيع (بعد الخصم)</label><input name="min_price" value="${it.min_price ?? ''}" inputmode="decimal" dir="ltr" placeholder="فاضي = بدون"></div>
      <div class="field"><label>أعلى نسبة خصم %</label><input name="max_discount_pct" value="${it.max_discount_pct ?? ''}" inputmode="decimal" dir="ltr" placeholder="فاضي = حسب الفئة"></div>
      <div class="field"><label>نسبة الضريبة %</label><input name="tax_rate" value="${it.tax_rate ?? 16}" inputmode="decimal" dir="ltr"><span class="hint">16 عام، 0 للمعفى أو الصفري، أو أي نسبة خاصة</span></div>
      <div class="field"><label>الباركود</label><input name="barcode" value="${esc(it.barcode)}" dir="ltr"></div>
      <div class="field"><label>حساب المبيعات</label>${accSel('sales_account_id', st.sales_account_id)}</div>
      <div class="field"><label>حساب المشتريات</label>${accSel('purchase_account_id', st.purchase_account_id)}</div></div>
      <details style="margin:8px 0" ${it.brand_id || it.model || it.color || it.size || it.origin_id ? 'open' : ''}><summary style="cursor:pointer;font-weight:700">🏷️ الماركة والطراز</summary><div class="grid cols-2" style="margin-top:6px">
      <div class="field"><label>الماركة</label><select name="brand_id"><option value="">—</option>${brands.filter(b => b.is_active !== false || b.id === it.brand_id).map(b => `<option value="${b.id}" ${b.id === it.brand_id ? 'selected' : ''}>${esc(b.name)}</option>`).join('')}</select></div>
      <div class="field"><label>الطراز / الموديل</label><input name="model" value="${esc(it.model || '')}" dir="auto"></div>
      <div class="field"><label>بلد المنشأ</label><select name="origin_id"><option value="">—</option>${countries.filter(b => b.is_active !== false || b.id === it.origin_id).map(b => `<option value="${b.id}" ${b.id === it.origin_id ? 'selected' : ''}>${esc(b.name)}</option>`).join('')}</select></div>
      <div class="field"><label>اللون</label><input name="color" value="${esc(it.color || '')}"></div>
      <div class="field"><label>المقاس</label><input name="size" value="${esc(it.size || '')}"></div></div>
      ${brands.length ? '' : '<p class="muted" style="font-size:12px;margin:0">الماركات بتنضاف من «إعداد ← الماركات».</p>'}</details>
      <div class="field"><label>صورة الصنف (لنقطة البيع)</label><div class="img-pick">
        <span class="img-prev" id="i-img-prev">${it.image ? `<img src="${esc(it.image)}" alt="">` : '📷'}</span>
        <label class="btn sm">اختيار صورة<input type="file" accept="image/*" id="i-img" hidden></label>
        <button type="button" class="btn sm" id="i-img-rm" ${it.image ? '' : 'hidden'}>شيل الصورة</button></div></div>
      ${cfFieldsHTML('item', it.extra) ? `<h4 style="margin:12px 0 6px">🧩 حقول إضافية</h4>${cfFieldsHTML('item', it.extra)}` : ''}
      <div class="field" style="max-width:420px"><label>🧪 الدفعات وتاريخ الانتهاء</label><select name="batch_mode">
        ${[['none', 'بدون دفعات'], ['batch', 'رقم دفعة'], ['expiry', 'رقم دفعة + تاريخ انتهاء']].map(([k, l]) => `<option value="${k}" ${(it.batch_mode || 'none') === k ? 'selected' : ''}>${l}</option>`).join('')}</select></div>
      <details style="margin:8px 0"><summary style="cursor:pointer;font-weight:700">📦 تجاهل تتبع الكمية</summary>
        <p class="muted" style="font-size:12px;margin:4px 0">بالمستندات المأشّرة ما بيتفحص رصيد هالصنف (ما بيطلع تنبيه نقص ولا بيمنع البيع بالسالب). مفيد للخدمات والتركيب.</p>
        <div style="display:flex;flex-wrap:wrap;gap:6px 16px">${[['sale', 'فواتير المبيعات'], ['sale_return', 'مردودات المبيعات'], ['pos', 'نقطة البيع'], ['sales_order', 'طلبات المبيعات'], ['purchase', 'فواتير المشتريات'], ['purchase_return', 'مردودات المشتريات'], ['stock_out', 'سندات الإخراج'], ['stock_transfer', 'سندات التحويل'], ['production', 'سندات الإنتاج']].map(([k, l]) => `<label class="check" style="margin:0"><input type="checkbox" data-qi="${k}" ${(it.qty_check_ignore || []).includes(k) ? 'checked' : ''}> ${l}</label>`).join('')}</div></details>
      <label class="check"><input type="checkbox" name="is_active" ${it.is_active ? 'checked' : ''}> فعّال</label></form>`,
      foot: `<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>` });
    if (!isNew) attachAudit(m.el, it);
    applyLayout(m.el.querySelector('#i-form'), 'item');
    let image = it.image || null;
    const imgPrev = m.el.querySelector('#i-img-prev'), imgRm = m.el.querySelector('#i-img-rm');
    m.el.querySelector('#i-img').onchange = async (e) => {
      const f = e.target.files[0]; if (!f) return;
      try { image = await shrinkImage(f); imgPrev.innerHTML = `<img src="${image}" alt="">`; imgRm.hidden = false; }
      catch { toast('ما قدرنا نقرأ الصورة', 'err'); }
    };
    imgRm.onclick = () => { image = null; imgPrev.textContent = '📷'; imgRm.hidden = true; };
    if (isNew) { let lastSug = it.code; const codeEl = m.el.querySelector('[name=code]');
      m.el.querySelector('[name=category_id]').onchange = (e) => { if (codeEl.value === lastSug) { lastSug = suggest(e.target.value || null); codeEl.value = lastSug; } }; }
    m.el.querySelector('[data-save]').onclick = async () => {
      const d = formData(m.el.querySelector('#i-form'));
      if (!d.code || !d.name) return toast('الرقم والاسم مطلوبين', 'err');
      { const rq = checkRequired(m.el.querySelector('#i-form'), 'item'); if (rq) return toast(rq, 'err'); }
      d.category_id = d.category_id || null; d.brand_id = d.brand_id || null; d.origin_id = d.origin_id || null;
      ['model', 'color', 'size'].forEach(k => { d[k] = (d[k] || '').trim() || null; });
      d.qty_check_ignore = [...m.el.querySelectorAll('[data-qi]')].filter(x => x.checked).map(x => x.dataset.qi);
      { const ex = cfValues(m.el.querySelector('#i-form'), 'item', it.extra); Object.keys(d).filter(k => k.startsWith('cf__')).forEach(k => delete d[k]); if (ex) d.extra = ex; }
      d.sale_price = num(d.sale_price); d.purchase_price = num(d.purchase_price); d.tax_rate = num(d.tax_rate);
      d.min_price = d.min_price === '' || d.min_price == null ? null : num(d.min_price); d.max_discount_pct = d.max_discount_pct === '' || d.max_discount_pct == null ? null : num(d.max_discount_pct);
      if (isNew) d.company_id = S.company.id;
      if ((it.image || null) !== image) d.image = image;
      const res = isNew ? await sb.from('items').insert(d) : await sb.from('items').update(d).eq('id', it.id);
      if (res.error) return toast(arError(res.error), 'err');
      await log(isNew ? 'إضافة' : 'تعديل', 'items', it.id || d.code, { name: d.name }); S.items = null; toast('تم الحفظ', 'ok'); m.close(); ctx.rerender();
    };
  };
  v.querySelector('#add')?.addEventListener('click', () => open(null));
  v.querySelector('#rows').onclick = async (e) => {
    const ed = e.target.closest('[data-edit]'), dl = e.target.closest('[data-del]');
    if (ed) open(items.find(i => i.id === ed.dataset.edit));
    if (dl) { const it = items.find(i => i.id === dl.dataset.del); if (!(await confirmBox(`حذف «${it.name}»؟`))) return;
      const { error } = await sb.from('items').delete().eq('id', it.id); if (error) return toast(arError(error), 'err'); S.items = null; toast('تم الحذف', 'ok'); ctx.rerender(); }
  };
}

// ---------------------------------------------------------------------
//  قوائم الفواتير
// ---------------------------------------------------------------------
function invoiceList(group) {
  return async function (v, ctx) {
    if (!guard(v)) return;
    const types = Object.entries(INV).filter(([, t]) => t.group === group).map(([k]) => k);
    const screen = INV[types[0]].screen;
    const [{ data, error }, parties] = await Promise.all([
      sb.from('invoices').select('*').eq('company_id', S.company.id).eq('fiscal_year_id', S.fy.id).in('inv_type', types).order('inv_date', { ascending: false }).order('inv_no', { ascending: false }).limit(3000),
      loadParties()]);
    if (error) throw error;
    const pName = Object.fromEntries(parties.map(p => [p.id, p.name]));
    const fmap = await followMap(data.map(i => i.id)), fsts = (await loadStatuses()).filter(s => types.includes(s.kind));
    const preT = new URLSearchParams(location.hash.split('?')[1] || '').get('t');
    const only = types.includes(preT) ? preT : '';
    const posted = data.filter(i => i.status === 'posted');
    const sum = (t) => posted.filter(i => i.inv_type === t).reduce((s, i) => s + num(i.total), 0);
    const heading = only === 'sale' ? '🧾 فواتير المبيعات' : only === 'sale_return' ? '↩️ مردودات المبيعات' : only === 'purchase' ? '🛒 فواتير المشتريات' : only === 'purchase_return' ? '↩️ مردودات المشتريات' : group === 'sales' ? '🧾 المبيعات' : '🛒 المشتريات';
    v.innerHTML = `<div class="page-head"><h2>${heading}</h2><span class="badge brand">${data.length}</span><div class="spacer"></div>
        <select class="search" id="ft" style="min-width:140px"><option value="">كل الأنواع</option>${types.map(t => `<option value="${t}" ${t === only ? 'selected' : ''}>${INV[t].label}</option>`).join('')}</select>
        <select class="search" id="fs" style="min-width:120px"><option value="">كل الحالات</option><option value="draft">مسودة</option><option value="posted">مرحّلة</option><option value="cancelled">ملغاة</option></select>
        ${fsts.length ? `<select class="search" id="ff" style="min-width:130px"><option value="">كل المتابعات</option>${fsts.map(s => `<option value="${s.id}">${esc(s.name)}</option>`).join('')}<option value="-">بدون متابعة</option></select>` : ''}
        <input class="search" id="q" placeholder="بحث بالرقم أو الاسم أو المرجع…">
        ${can(screen, 'add') ? types.filter(t => !only || t === only).map(t => `<button class="btn ${t.endsWith('return') ? '' : 'primary'}" data-new="${t}">➕ ${INV[t].label}</button>`).join('') : ''}</div>
      <div class="grid cols-3" style="margin-bottom:14px">
        <div class="card stat"><span class="k">${INV[types[0]].label}ات المرحّلة</span><span class="v" dir="ltr">${fmtNum(sum(types[0]))}</span></div>
        <div class="card stat"><span class="k">المرتجعات</span><span class="v" dir="ltr">${fmtNum(sum(types[1]))}</span></div>
        <div class="card stat"><span class="k">الصافي</span><span class="v" dir="ltr">${fmtNum(sum(types[0]) - sum(types[1]))}</span></div></div>
      <div class="card table-wrap"><table class="t"><thead><tr><th>النوع</th><th>الرقم</th><th>التاريخ</th><th>${INV[types[0]].partyLabel}</th><th>الدفع</th><th>المرجع</th><th style="text-align:left">قبل الضريبة</th><th style="text-align:left">الضريبة</th><th style="text-align:left">الإجمالي</th><th>الحالة</th></tr></thead><tbody id="rows"></tbody></table></div>`;
    const draw = () => {
      const q = v.querySelector('#q').value.trim().toLowerCase(), ft = v.querySelector('#ft').value, fs = v.querySelector('#fs').value, ff = v.querySelector('#ff')?.value || '';
      v.querySelector('#rows').innerHTML = data.filter(i => (!ft || i.inv_type === ft) && (!fs || i.status === fs) && (!ff || (ff === '-' ? !fmap[i.id] : fmap[i.id]?.id === ff)) && (!q || [docNo(i), String(i.inv_no), pName[i.party_id], i.party_name, i.reference].some(x => (x || '').toLowerCase().includes(q))))
        .map(i => `<tr class="click" data-open="${i.id}"><td>${i.inv_type.endsWith('return') ? `<span class="badge warn">${INV[i.inv_type].label}</span>` : INV[i.inv_type].label}</td><td><b dir="ltr">${esc(docNo(i))}</b></td><td>${fmtDate(i.inv_date)}</td>
          <td>${esc(pName[i.party_id] || i.party_name || '')}</td><td>${i.payment_type === 'cash' ? 'نقدي' : 'آجل'}</td><td>${esc(i.reference || '')}</td>
          <td dir="ltr" style="text-align:left">${i.status === 'draft' && !i.stock_posted ? '—' : fmtNum(i.subtotal)}</td><td dir="ltr" style="text-align:left">${i.status === 'draft' && !i.stock_posted ? '—' : fmtNum(i.tax_total)}</td>
          <td dir="ltr" style="text-align:left"><b>${i.status === 'draft' && !i.stock_posted ? '—' : fmtNum(i.total)}</b></td><td>${badge(i.status)}${i.stock_posted ? ' <span class="badge ok" title="مرحّلة للمخزون">📦</span>' : ''} ${followBadge(fmap[i.id])}</td></tr>`).join('')
        || '<tr><td colspan="10" class="empty">ما في فواتير بهالسنة المالية</td></tr>';
    };
    draw(); ['#q', '#ft', '#fs', '#ff'].forEach(s => v.querySelector(s)?.addEventListener('input', draw));
    v.querySelectorAll('[data-new]').forEach(b => b.onclick = () => invoiceEditor(b.dataset.new, null, ctx));
    v.querySelector('#rows').onclick = (e) => { const r = e.target.closest('[data-open]'); if (r) { setNavList('inv', [...v.querySelectorAll('#rows [data-open]')].map(tr => data.find(x => x.id === tr.dataset.open)).filter(Boolean)); const i = data.find(x => x.id === r.dataset.open); invoiceEditor(i.inv_type, i, ctx); } };
  };
}

// ---------------------------------------------------------------------
//  محرّر الفاتورة
// ---------------------------------------------------------------------
async function invoiceEditor(type, inv, ctx) {
  const T = INV[type];
  const [accs, parties, items, st, whr, ccr] = await Promise.all([loadAccounts(), loadParties(), loadItems(), loadSettings(),
    sb.from('warehouses').select('id,code,name,is_active').eq('company_id', S.company.id).order('code'),
    sb.from('cost_centers').select('id,code,name,is_active').eq('company_id', S.company.id).order('code')]);
  const ccs = (ccr.data || []).filter(c => c.is_active || c.id === inv?.cost_center_id);
  const whs = (whr.data || []).filter(w => w.is_active || w.id === inv?.warehouse_id);
  let lines = [];
  if (inv) { const r = await sb.from('invoice_lines').select('*').eq('invoice_id', inv.id).order('line_no'); lines = r.data || []; }
  const myParties = parties.filter(p => p.party_type === T.partyType);
  const isSale = T.group === 'sales';
  const promos = type === 'sale' ? ((await sb.from('promotions').select('*').eq('company_id', S.company.id).eq('is_active', true)).data || []) : [];
  const readOnly = (inv && (inv.status !== 'draft' || inv.stock_posted)) || (inv ? !can(T.screen, 'edit') : !can(T.screen, 'add'));
  const ro = readOnly ? 'disabled' : '';
  const manual = await isManual(type);
  await loadPosting();
  const bar = inv && inv.status !== 'cancelled' ? postBarHTML([
    postFlag(type, 'gl') || inv.status === 'posted' ? { key: 'gl', posted: inv.status === 'posted', canPost: inv.status === 'draft' && can(T.screen, 'post') && postFlag(type, 'gl'), canUnpost: inv.status === 'posted' && can(T.screen, 'unpost') } : null,
    postFlag(type, 'stock') || inv.stock_posted ? { key: 'stock', posted: !!inv.stock_posted, canPost: !inv.stock_posted && can(T.screen, 'post') && postFlag(type, 'stock'), canUnpost: inv.stock_posted && can(T.screen, 'unpost') } : null]) : '';
  const pre = !inv && returnPrefill ? returnPrefill : null; returnPrefill = null;
  const i0 = inv || { inv_date: today() >= S.fy.start_date && today() <= S.fy.end_date ? today() : S.fy.start_date, payment_type: pre?.inv.payment_type || 'credit',
    prices_include_tax: pre?.inv.prices_include_tax || false, cash_account_id: pre?.inv.cash_account_id || st.cash_account_id, party_id: pre?.inv.party_id,
    party_name: pre?.inv.party_name, reference: pre ? (pre.fromOrder ? pre.ref : `مرتجع من ${INV[pre.inv.inv_type].label} ${docNo(pre.inv)}`) : '',
    original_invoice_id: pre && !pre.fromOrder ? pre.inv.id : null, sales_rep_id: pre?.inv.sales_rep_id || null, department_id: pre?.inv.department_id || null, notes: pre?.inv.notes || '', project: pre?.inv.project || '' };
  if (pre) lines = pre.lines;
  const pById = Object.fromEntries(parties.map(p => [p.id, p])), itById = Object.fromEntries(items.map(i => [i.id, i]));
  let rows = lines.map(l => ({ item: itemLabel(itById[l.item_id]), desc: l.description || '', details: l.details || '', qty: num(l.qty), price: num(l.unit_price), disc: num(l.discount), rate: num(l.tax_rate), batch: l.batch_no || '', exp: l.expiry_date || '' }));
  if (!rows.length) rows.push({ item: '', desc: '', qty: 1, price: 0, disc: 0, rate: num(st.default_tax_rate ?? 16) });
  const cashAccs = leafAccounts(accs).filter(a => ['cash', 'bank'].includes(a.account_type)).concat(leafAccounts(accs).filter(a => !['cash', 'bank'].includes(a.account_type)));
  const dept = await deptField(inv?.department_id, ro, !inv); await loadLookups(); const dtf = await docTypeField(type, inv?.doc_type_id, ro);
  const m = modal({ title: inv ? `${T.label} رقم ${docNo(inv)}` : `${T.label} جديدة`, body: `
    ${bar}${inv ? `<div style="margin:-6px 0 12px">${badge(inv.status)} ${readOnly && (inv.status !== 'draft' || inv.stock_posted) ? '<span class="muted" style="font-size:13px">— الفاتورة المرحّلة ما بتنعدّل. للتعديل ألغِ ترحيلها، أو ألغيها، أو اعمل مرتجع.</span>' : ''}</div>` : ''}
    <form id="inv-form"><div class="grid cols-3">
      ${manualField(manual, inv?.inv_no, ro)}
      <div class="field"><label>التاريخ *</label><input type="date" name="inv_date" value="${esc(i0.inv_date)}" min="${S.fy.start_date}" max="${S.fy.end_date}" ${ro}></div>
      <div class="field"><label>طريقة الدفع</label><select name="payment_type" ${ro}><option value="credit" ${i0.payment_type === 'credit' ? 'selected' : ''}>آجل (على الحساب)</option><option value="cash" ${i0.payment_type === 'cash' ? 'selected' : ''}>نقدي</option></select></div>
      <div class="field"><label>تاريخ الاستحقاق</label><input type="date" name="due_date" value="${esc(i0.due_date)}" ${ro}></div>
      <div class="field" style="grid-column:span 2"><label>${T.partyLabel} <span id="p-req">*</span></label><input list="party-list" id="party" value="${esc(partyLabel(pById[i0.party_id]))}" placeholder="رقم أو اسم ${T.partyLabel}…" ${ro}>${partyDatalist(myParties)}</div>
      <div class="field" id="pn-box"><label>الاسم (للنقدي بدون بطاقة)</label><input name="party_name" value="${esc(i0.party_name)}" ${ro}></div>
      <div class="field" id="cash-box"><label>الصندوق / البنك</label><select name="cash_account_id" ${ro}><option value="">— اختار —</option>${pmOptions(isSale ? 'sales' : 'purchases')}${cashAccs.map(a => `<option value="${a.id}" ${a.id === i0.cash_account_id ? 'selected' : ''}>${esc(accLabel(a))}</option>`).join('')}</select></div>
      <div class="field"><label>${isSale ? 'رقم الطلب / المرجع' : 'رقم فاتورة المورد'}</label><input name="reference" value="${esc(i0.reference)}" ${ro}></div>
      ${isSale ? `<div class="field"><label>المشروع</label><input name="project" value="${esc(i0.project || '')}" ${ro}></div>` : ''}
      ${ccs.length ? `<div class="field"><label>مركز الكلفة</label><select name="cost_center_id" ${ro}><option value="">—</option>${ccs.map(c => `<option value="${c.id}" ${c.id === i0.cost_center_id ? 'selected' : ''}>${esc(c.name)}</option>`).join('')}</select></div>` : ''}
      ${dept}${dtf}
      ${isSale && hasReps() ? `<div class="field"><label>المندوب</label><select name="sales_rep_id" ${ro}><option value="">— مندوب العميل —</option>${repOptions(i0.sales_rep_id)}</select></div>` : ''}
      ${whs.length > 1 ? `<div class="field"><label>المستودع</label><select name="warehouse_id" ${ro}>${whs.map(w => `<option value="${w.id}" ${w.id === (i0.warehouse_id || pre?.inv.warehouse_id) ? 'selected' : ''}>${esc(w.name)}</option>`).join('')}</select></div>` : ''}
      <div class="field" style="justify-content:flex-end"><label class="check" style="margin:0 0 10px"><input type="checkbox" name="prices_include_tax" ${i0.prices_include_tax ? 'checked' : ''} ${ro}> الأسعار شاملة الضريبة</label></div>
    </div></form>
    <datalist id="item-list">${items.filter(i => i.is_active).map(i => `<option value="${esc(itemLabel(i))}"></option>`).join('')}</datalist>
    <div class="table-wrap"><table class="t lines" id="il"><thead><tr><th style="width:32px">#</th><th style="min-width:180px">الصنف (اختياري)</th><th style="min-width:180px">البيان</th><th style="width:80px">الكمية</th><th style="width:110px">السعر</th><th style="width:90px">الخصم</th><th style="width:70px">ض%</th><th style="width:120px">الإجمالي</th><th style="width:30px"></th></tr></thead>
      <tbody></tbody></table></div>
    ${!readOnly ? '<button class="btn sm" id="add-line" type="button" style="margin-top:6px">➕ سطر</button>' : ''}
    <div class="inv-totals"><div><span>المجموع قبل الضريبة</span><b id="t-sub" dir="ltr"></b></div><div><span>الخصومات</span><b id="t-disc" dir="ltr"></b></div>
      <div><span>ضريبة المبيعات</span><b id="t-tax" dir="ltr"></b></div><div class="big"><span>الإجمالي</span><b id="t-tot" dir="ltr"></b></div><div class="muted" id="t-words" style="font-size:13px"></div></div>
    <div class="field" style="margin-top:10px"><label>ملاحظات</label><input form="inv-form" name="notes" value="${esc(i0.notes)}" ${ro}></div><div id="stock-warn"></div>`,
    foot: `${!readOnly ? '<button class="btn primary" data-save>💾 حفظ</button>' : ''}
      ${inv?.status === 'posted' && can(T.screen, 'post') ? '<button class="btn danger" data-cancel>⛔ إلغاء الفاتورة</button>' : ''}
      ${inv?.status === 'posted' && !type.endsWith('return') && can(T.screen, 'add') ? `<button class="btn" data-return>↩️ ${type === 'sale' ? 'مرتجع بيع' : 'مرتجع شراء'} منها</button>` : ''}
      ${inv && can(T.screen, 'print') ? '<button class="btn" data-print>🖨️ طباعة</button>' : ''}
      ${inv && inv.party_id && isSaleType(type) && inv.status !== 'cancelled' ? '<button class="btn" data-wa>💬 واتساب</button>' : ''}
      ${inv ? '<button class="btn" data-attach>📎 مرفقات</button>' : ''}
      ${inv?.status === 'draft' && !inv.stock_posted && can(T.screen, 'delete') ? '<button class="btn danger" data-del style="margin-inline-start:auto">حذف</button>' : ''}
      <button class="btn" data-close>إغلاق</button>` });
  m.el.querySelector('.modal').style.maxWidth = '1100px';
  attachDocNav(m, inv, { key: 'inv', open: (r) => invoiceEditor(r.inv_type, r, ctx), onNew: can(T.screen, 'add') ? () => invoiceEditor(type, null, ctx) : null, table: 'invoices', canFreeze: can(T.screen, 'edit'), editable: !readOnly });
  if (inv) { attachAudit(m.el, inv); attachFollow(m.el, 'invoices', inv, inv.inv_type, T.screen); }
  const f = m.el.querySelector('#inv-form'), tb = m.el.querySelector('#il tbody');
  const incl = () => f.prices_include_tax.checked;
  const calc = (r) => { const g = r3(num(r.qty) * num(r.price) - num(r.disc)); const rate = num(r.rate);
    if (incl()) { const sub = r3(g / (1 + rate / 100)); return { sub, tax: r3(g - sub), tot: g }; }
    const tax = r3(g * rate / 100); return { sub: g, tax, tot: r3(g + tax) }; };
  const togglePay = () => { const cash = f.payment_type.value === 'cash';
    m.el.querySelector('#cash-box').style.display = cash ? '' : 'none'; m.el.querySelector('#pn-box').style.display = cash ? '' : 'none';
    m.el.querySelector('#p-req').style.display = cash ? 'none' : ''; };
  togglePay(); f.payment_type.onchange = togglePay;
  const draw = () => {
    tb.innerHTML = rows.map((r, i) => `<tr><td class="muted">${i + 1}</td>
      <td><input class="cell" list="item-list" data-i="${i}" data-k="item" value="${esc(r.item)}" ${ro}>${lpHint(r, i)}</td>
      <td><input class="cell" data-i="${i}" data-k="desc" value="${esc(r.desc)}" ${ro}>${!readOnly || r.details ? `<textarea class="cell" data-i="${i}" data-k="details" rows="${Math.max(1, (r.details || '').split('\n').length)}" placeholder="تفاصيل (أسطر إضافية، اختياري)" style="font-size:12px;resize:vertical;min-height:26px;margin-top:2px" ${ro}>${esc(r.details || '')}</textarea>` : ''}${batchCell(r, i)}</td>
      <td><input class="cell n" data-i="${i}" data-k="qty" value="${r.qty || ''}" inputmode="decimal" ${ro}></td>
      <td><input class="cell n" data-i="${i}" data-k="price" value="${r.price || ''}" inputmode="decimal" ${ro}></td>
      <td><input class="cell n" data-i="${i}" data-k="disc" value="${r.disc || ''}" inputmode="decimal" ${ro}></td>
      <td><input class="cell n" data-i="${i}" data-k="rate" value="${r.rate}" inputmode="decimal" ${ro}></td>
      <td class="n" data-tot="${i}"></td><td>${!readOnly ? `<button class="x" type="button" data-rm="${i}">×</button>` : ''}</td></tr>`).join('');
    totals();
  };
  // الدفعات وتاريخ الانتهاء (المرحلة 64): الداخل بيكتب الدفعة (وتاريخها)، والطالع بيختار من أرصدة المستودع أو بيتركها للأقرب انتهاء
  const inbound = ['purchase', 'sale_return'].includes(type);
  let bal = [];
  const loadBal = async () => { if (!items.some(x => x.batch_mode && x.batch_mode !== 'none')) return;
    const wh = f.warehouse_id?.value || whs[0]?.id || null;
    const { data } = await sb.rpc('batch_balances', { p_company: S.company.id, p_warehouse: wh, p_item: null, p_all: false }); bal = (data || []).filter(x => x.batch_id); draw(); };
  const batchCell = (r, i) => { const it = resolveItem(items, r.item); if (!it || !it.batch_mode || it.batch_mode === 'none') return '';
    const opts = bal.filter(x => x.item_id === it.id), exp = it.batch_mode === 'expiry';
    return `<div class="batch-cell"><span>🧪</span><input class="cell" data-i="${i}" data-k="batch" value="${esc(r.batch)}" list="bl-${i}" placeholder="${inbound ? 'رقم الدفعة' : 'الدفعة (فاضي = الأقرب انتهاء)'}" ${ro}>
      <datalist id="bl-${i}">${opts.map(x => `<option value="${esc(x.batch_no)}">${fmtQty(x.qty)}${x.expiry_date ? ' · ينتهي ' + fmtDate(x.expiry_date) : ''}</option>`).join('')}</datalist>
      ${inbound && exp ? `<input class="cell" type="date" data-i="${i}" data-k="exp" value="${esc(r.exp)}" title="تاريخ الانتهاء" ${ro}>` : ''}
      ${!inbound && r.batch ? (() => { const b = opts.find(x => x.batch_no === r.batch); return b ? `<small class="${b.days_left != null && b.days_left < 0 ? 'bad-txt' : 'muted'}">${fmtQty(b.qty)}${b.expiry_date ? ' · ' + fmtDate(b.expiry_date) : ''}</small>` : '<small class="bad-txt">مش موجودة</small>'; })() : ''}</div>`; };
  // سجل أسعار الصنف للطرف: آخر سعر تحت الصنف، وكبسة بتفتح السجل
  let lastPx = {};
  const lpHint = (r, i) => { const it = resolveItem(items, r.item), x = it && lastPx[it.id]; if (!x) return '';
    const cur = num(r.price) && Math.abs(num(r.price) - num(x.last_unit_price)) > 0.0005;
    return `<div class="lp-hint${cur ? ' diff' : ''}" data-lph="${i}" title="سجل أسعار الصنف لهالطرف">🕘 آخر سعر <b dir="ltr">${fmtPrice(x.last_price)}</b> · ${fmtDate(x.last_date)}${x.times > 1 ? ` · ${x.times} مرات (${fmtPrice(x.min_price)}–${fmtPrice(x.max_price)})` : ''}</div>`; };
  const loadLastPrices = async (p) => { lastPx = {}; if (p) {
    const { data } = await sb.rpc('party_last_prices', { p_company: S.company.id, p_party: p.id, p_kind: isSale ? 'sale' : 'purchase' });
    (data || []).forEach(x => lastPx[x.item_id] = x); } draw(); };
  const lastPrice = (it) => { const x = lastPx[it.id]; if (!x || !st.use_last_price) return null;
    return incl() ? Math.round(num(x.last_price) * (1 + num(it.tax_rate) / 100) * 1000) / 1000 : num(x.last_price); };
  const totals = () => {
    let sub = 0, tax = 0, disc = 0;
    rows.forEach((r, i) => { const c = calc(r); sub += c.sub; tax += c.tax; disc += num(r.disc); const el = tb.querySelector(`[data-tot="${i}"]`); if (el) el.textContent = fmtNum(c.tot); });
    m.el.querySelector('#t-sub').textContent = fmtNum(sub); m.el.querySelector('#t-disc').textContent = fmtNum(disc);
    m.el.querySelector('#t-tax').textContent = fmtNum(tax); m.el.querySelector('#t-tot').textContent = fmtNum(sub + tax);
    m.el.querySelector('#t-words').textContent = sub + tax ? amountToWords(sub + tax) : '';
  };
  draw();
  f.prices_include_tax.onchange = totals;
  tb.addEventListener('input', (e) => { const t = e.target; if (!t.dataset.k) return; const r = rows[+t.dataset.i]; r[t.dataset.k] = t.dataset.k === 'item' || t.dataset.k === 'desc' ? t.value : t.value; totals(); });
  tb.addEventListener('change', (e) => {
    const t = e.target; if (t.dataset.k !== 'item') return;
    const it = resolveItem(items, t.value), r = rows[+t.dataset.i];
    t.classList.toggle('bad', !!t.value && !it);
    if (it) { r.item = itemLabel(it); r.desc = r.desc || it.name; r.price = num(isSale && listPrice[it.id] != null ? listPrice[it.id] : lastPrice(it) ?? (isSale ? it.sale_price : it.purchase_price)) || r.price; r.rate = num(it.tax_rate);
      r.manualDisc = false; applyPromo(r, it, true); draw(); }
  });
  // العرض الترويجي بيتحدّث مع الكمية والسعر والتاريخ، والخصم اليدوي بيلغي العرض عن السطر
  const applyPromo = (r, it, announce) => {
    if (!(isSale && type === 'sale') || !it || r.manualDisc) return false;
    const pr = bestPromo(promos, it, f.inv_date.value, num(r.qty)), had = !!r.promo;
    r.promo = pr ? num(pr.discount_pct) : 0;
    if (pr) { r.disc = r3(num(r.qty) * num(r.price) * r.promo / 100); if (announce) toast(`عرض «${pr.name}»: خصم ${r.promo}%`, 'ok'); }
    else if (had) r.disc = 0;
    return true;
  };
  tb.addEventListener('change', (e) => { const t = e.target, r = rows[+t.dataset.i]; if (!r) return;
    if (t.dataset.k === 'disc') { r.manualDisc = true; r.promo = 0; return; }
    if (t.dataset.k === 'batch' && !inbound) { const b = bal.find(x => x.batch_no === t.value.trim() && x.item_id === resolveItem(items, r.item)?.id); r.exp = b?.expiry_date || ''; draw(); return; }
    if (['qty', 'price'].includes(t.dataset.k) && applyPromo(r, resolveItem(items, r.item), false)) draw(); });
  f.inv_date.addEventListener('change', () => { let ch = false; rows.forEach(r => { ch = applyPromo(r, resolveItem(items, r.item), false) || ch; }); if (ch) draw(); });
  tb.addEventListener('click', (e) => { const h = e.target.closest("[data-lph]"); if (!h) return;
    const r = rows[+h.dataset.lph], it = resolveItem(items, r.item), p = resolveParty(myParties, m.el.querySelector('#party').value);
    if (it && p) priceHistory(p, it, isSale ? 'sale' : 'purchase', readOnly ? null : (pr) => {
      r.price = incl() ? Math.round(pr * (1 + num(r.rate) / 100) * 1000) / 1000 : pr; r.disc = 0; r.manualDisc = true; r.promo = 0; draw(); }); });
  tb.addEventListener('click', (e) => { const b = e.target.closest('[data-rm]'); if (!b) return; rows.splice(+b.dataset.rm, 1); if (!rows.length) rows.push({ item: '', desc: '', qty: 1, price: 0, disc: 0, rate: num(st.default_tax_rate ?? 16) }); draw(); });
  m.el.querySelector('#add-line')?.addEventListener('click', () => { rows.push({ item: '', desc: '', qty: 1, price: 0, disc: 0, rate: num(st.default_tax_rate ?? 16) }); draw(); });
  let listPrice = {};   // سعر الصنف من قائمة أسعار الزبون
  const loadListPrices = async (p) => { listPrice = {}; if (!isSale || !p?.price_list_id) return;
    const { data } = await sb.rpc('party_item_prices', { p_company: S.company.id, p_party: p.id }); (data || []).forEach(x => listPrice[x.item_id] = num(x.price)); };
  const partyInput = m.el.querySelector('#party');
  loadBal(); f.warehouse_id?.addEventListener('change', loadBal);
  if (inv?.party_id || pre?.inv?.party_id) { const p0 = myParties.find(x => x.id === (inv?.party_id || pre?.inv?.party_id)); loadListPrices(p0); loadLastPrices(p0); }
  const docWarn = async (p) => {   // وثائق الطرف الناقصة أو المنتهية
    m.el.querySelector('#pdoc-warn')?.remove(); if (!p) return;
    const { data } = await sb.rpc('party_doc_issues', { p_company: S.company.id, p_party: p.id, p_date: f.inv_date.value || null });
    const bad = (data || []).filter(x => x.on_missing !== 'none');
    if (!bad.length) return;
    const blk = bad.some(x => x.on_missing === 'block' && x.problem !== 'expiring');
    const box = document.createElement('div'); box.id = 'pdoc-warn'; box.className = 'notice' + (blk ? '' : ' info'); box.style.margin = '0 0 10px';
    box.innerHTML = `${blk ? '⛔' : '⚠️'} وثائق ${esc(p.name)}: ${bad.map(x => `<b>${esc(x.type_name)}</b> ${x.problem === 'missing' ? 'ناقصة' : x.problem === 'expired' ? 'منتهية ' + fmtDate(x.expiry_date) : 'بتنتهي ' + fmtDate(x.expiry_date)}`).join('، ')}${blk ? ' — الفاتورة ما رح تترحّل لحد ما تتجدد.' : ''} <a href="#/party-docs?t=docs&party=${p.id}">فتح الوثائق</a>`;
    m.el.querySelector('#inv-form')?.before(box);
  };
  if ((inv?.party_id && inv.status === 'draft') || pre?.inv?.party_id) docWarn(myParties.find(x => x.id === (inv?.party_id || pre?.inv?.party_id)));
  partyInput.addEventListener('change', () => {
    const p = resolveParty(myParties, partyInput.value); partyInput.classList.toggle('bad', !!partyInput.value && !p);
    loadListPrices(p); loadLastPrices(p);
    docWarn(p);
    if (p) { partyInput.value = partyLabel(p); if (p.payment_terms_days && !f.due_date.value) { const d = new Date(f.inv_date.value); d.setDate(d.getDate() + p.payment_terms_days); f.due_date.value = d.toISOString().slice(0, 10); } }
  });

  const save = async (post) => {
    const h = formData(f); const p = resolveParty(myParties, partyInput.value);
    if (partyInput.value && !p) return toast(`${T.partyLabel} مش موجود بالقائمة`, 'err');
    if (h.payment_type === 'credit' && !p) return toast(`الفاتورة الآجلة لازم يكون إلها ${T.partyLabel}`, 'err');
    if (h.payment_type === 'cash' && !h.cash_account_id) return toast('اختار الصندوق أو البنك', 'err');
    if (h.inv_date < S.fy.start_date || h.inv_date > S.fy.end_date) return toast('التاريخ لازم يكون جوّا السنة المالية الحالية', 'err');
    const out = [];
    for (const [k, r] of rows.entries()) {
      if (!r.item && !r.desc && !num(r.price)) continue;
      const it = resolveItem(items, r.item);
      if (r.item && !it) return toast(`السطر ${k + 1}: الصنف مش موجود`, 'err');
      if (num(r.qty) <= 0) return toast(`السطر ${k + 1}: الكمية لازم تكون أكبر من صفر`, 'err');
      if (num(r.disc) > num(r.qty) * num(r.price)) return toast(`السطر ${k + 1}: الخصم أكبر من قيمة السطر`, 'err');
      const c = calc(r);
      const bm = it?.batch_mode && it.batch_mode !== 'none';
      if (bm && inbound && !(r.batch || '').trim()) return toast(`السطر ${k + 1}: ${it.name} بده رقم دفعة`, 'err');
      if (bm && inbound && it.batch_mode === 'expiry' && !r.exp) return toast(`السطر ${k + 1}: ${it.name} بده تاريخ انتهاء`, 'err');
      out.push({ batch_no: bm ? (r.batch || '').trim() || null : null, expiry_date: bm && r.exp && (inbound || r.batch) ? r.exp : null, item_id: it?.id || null, description: r.desc || it?.name || null, details: (r.details || '').trim() || null, qty: num(r.qty), unit_price: num(r.price), discount: num(r.disc), tax_rate: num(r.rate),
                 account_id: (isSale ? it?.sales_account_id : it?.purchase_account_id) || null, subtotal: c.sub, tax_amount: c.tax, line_total: c.tot });
    }
    if (!out.length) return toast('أضف سطر واحد على الأقل', 'err');
    // تنبيه: الكمية المطلوبة أكبر من المتوفرة بالمستودع (فاتورة البيع)
    if (type === 'sale' && !stockAck) {
      const ign = new Set(items.filter(i => (i.qty_check_ignore || []).includes('sale')).map(i => i.id));
      const need = {}; out.forEach(l => { if (l.item_id && !ign.has(l.item_id)) need[l.item_id] = (need[l.item_id] || 0) + l.qty; });
      const ids = Object.keys(need);
      if (ids.length) {
        const { data: av } = await sb.rpc('items_available', { p_company: S.company.id, p_warehouse: h.warehouse_id || null, p_date: h.inv_date, p_items: ids });
        // الكمية الموجودة بنفس الفاتورة لو كانت مرحّلة للمخزون من قبل ما بتنحسب (التعديل ممنوع بعد الترحيل أصلاً)
        const short = (av || []).filter(x => need[x.item_id] > num(x.available) + 0.0005);
        if (short.length) {
          const box = m.el.querySelector('#stock-warn');
          box.innerHTML = `<div class="notice" style="border:2px solid #d97706;background:#fff7ed;margin-top:10px"><b>⚠️ تنبيهات فاتورة المبيعات: الكمية المطلوبة أكبر من الكمية المتوفرة</b>
            <table class="t" style="margin:6px 0"><thead><tr><th>الصنف</th><th>المطلوب</th><th>المتوفر</th><th>النقص</th></tr></thead><tbody>
            ${short.map(x => `<tr><td>${esc(x.code)} — ${esc(x.name)}</td><td class="n">${fmtNum(need[x.item_id])}</td><td class="n">${fmtNum(x.available)}</td><td class="n" style="color:#b91c1c">${fmtNum(need[x.item_id] - num(x.available))}</td></tr>`).join('')}</tbody></table>
            ${st.block_negative_stock ? '<div style="color:#b91c1c;margin:4px 0"><b>البيع بالسالب ممنوع بإعدادات الشركة:</b> بتقدر تحفظ الفاتورة مسودة، بس ترحيلها للمخزون ما بيمشي قبل ما يتوفر الرصيد.</div>' : ''}
            <button type="button" class="btn primary" id="sw-go">${st.block_negative_stock ? 'حفظ كمسودة' : 'متابعة الحفظ رغم النقص'}</button> <button type="button" class="btn" id="sw-no">رجوع للتعديل</button></div>`;
          box.scrollIntoView({ block: 'nearest' });
          box.querySelector('#sw-go').onclick = () => { stockAck = true; box.innerHTML = ''; save(st.block_negative_stock ? false : post); };
          box.querySelector('#sw-no').onclick = () => { box.innerHTML = ''; };
          return;
        }
      }
    }
    const mn = readManual(m.el.querySelector('#inv-form'), manual);
    if (!mn.ok) return toast('الترقيم يدوي: اكتب رقم الفاتورة (رقم صحيح أكبر من صفر)', 'err');
    const header = { ...(mn.value ? { inv_no: mn.value } : {}), inv_date: h.inv_date, due_date: h.due_date, payment_type: h.payment_type, party_id: p?.id || null,
      party_name: h.payment_type === 'cash' ? (h.party_name || p?.name || null) : null, cash_account_id: h.payment_type === 'cash' ? h.cash_account_id : null,
      reference: h.reference, ...(isSale ? { project: h.project || null } : {}), prices_include_tax: h.prices_include_tax, notes: h.notes, ...(whs.length > 1 ? { warehouse_id: h.warehouse_id } : {}), ...deptValue(m.el.querySelector('#inv-form')), ...docTypeValue(m.el.querySelector('#inv-form')), ...(isSale && hasReps() ? { sales_rep_id: h.sales_rep_id || null } : {}), ...(ccs.length ? { cost_center_id: h.cost_center_id || null } : {}),
      subtotal: r3(out.reduce((s, l) => s + l.subtotal, 0)), tax_total: r3(out.reduce((s, l) => s + l.tax_amount, 0)), discount_total: r3(out.reduce((s, l) => s + l.discount, 0)) };
    header.total = r3(header.subtotal + header.tax_total);
    if (p && isSale && type === 'sale' && p.credit_limit > 0 && h.payment_type === 'credit') {
      const { data: b } = await sb.from('party_balances').select('debit,credit').eq('party_id', p.id).eq('fiscal_year_id', S.fy.id).maybeSingle();
      const bal = b ? num(b.debit) - num(b.credit) : 0;
      if (bal + header.total > p.credit_limit && !(await confirmBox(`تنبيه: رصيد العميل رح يصير ${fmtNum(bal + header.total)} وهو أكثر من سقف الائتمان ${fmtNum(p.credit_limit)}.${st.credit_limit_mode === 'block' && !can('credit_override', 'edit') ? ' الترحيل ممنوع فوق السقف، بتقدر تحفظها مسودة بس.' : ''} بدك تكمّل؟`))) return;
      if (bal + header.total > p.credit_limit && st.credit_limit_mode === 'block' && !can('credit_override', 'edit') && !isAdmin()) post = false;   // بتنحفظ مسودة
    }
    const btns = m.el.querySelectorAll('.modal-foot .btn'); btns.forEach(b => b.disabled = true);
    try {
      let id = inv?.id;
      if (id) { const u = await sb.from('invoices').update(header).eq('id', id); if (u.error) throw u.error; const d = await sb.from('invoice_lines').delete().eq('invoice_id', id); if (d.error) throw d.error; }
      else { const ins = await sb.from('invoices').insert({ ...header, company_id: S.company.id, fiscal_year_id: S.fy.id, inv_type: type, original_invoice_id: i0.original_invoice_id || null }).select().single(); if (ins.error) throw ins.error; id = ins.data.id; inv = ins.data; }
      const li = await sb.from('invoice_lines').insert(out.map((l, k) => ({ ...l, invoice_id: id, line_no: k + 1 }))); if (li.error) throw li.error;
      if (pre?.onSaved && !pre.done) { pre.done = true; await pre.onSaved(id); }
      await log(inv ? 'تعديل' : 'إضافة', T.screen, id, { type });
      if (post) { const r = post === 'gl' ? await sb.rpc('post_invoice', { p_id: id }) : await sb.rpc('post_invoice_stock', { p_id: id });
        if (r.error) { toast(arError(r.error), 'err'); return reopen(id); }
        toast(post === 'gl' ? 'انحفظت وانرحّلت للمحاسبة' : 'انحفظت وانرحّلت للمخزون', 'ok'); }
      else toast('تم الحفظ', 'ok');
      reopen(id);
    } catch (err) { toast(arError(err), 'err'); btns.forEach(b => b.disabled = false); }
  };
  // بعد الحفظ أو الترحيل: الفاتورة بتضل مفتوحة عشان تبيّن كبسات الترحيل
  const reopen = async (id) => {
    m.close(); ctx.rerender();
    const { data } = await sb.from('invoices').select('*').eq('id', id).single();
    if (data) invoiceEditor(data.inv_type, data, ctx);
  };
  let stockAck = false;
  tb.addEventListener('input', () => { stockAck = false; });
  m.el.querySelector('[data-save]')?.addEventListener('click', () => save(false));
  // الترحيل من مسودة لسا بتنعدّل: بيحفظ التعديلات أول
  m.el.querySelectorAll('[data-postdo]').forEach(b => b.addEventListener('click', (ev) => { if (!readOnly) { ev.stopImmediatePropagation(); save(b.dataset.postdo); } }));
  if (inv) wirePostBar(m.el, 'invoice', inv.id, () => reopen(inv.id));
  m.el.querySelector('[data-del]')?.addEventListener('click', async () => {
    if (!(await confirmBox(`حذف ${T.label} رقم ${docNo(inv)}؟`))) return;
    const { error } = await sb.from('invoices').delete().eq('id', inv.id); if (error) return toast(arError(error), 'err');
    await log('حذف', T.screen, inv.id, { no: docNo(inv) }); toast('تم الحذف', 'ok'); m.close(); ctx.rerender();
  });
  m.el.querySelector('[data-cancel]')?.addEventListener('click', async () => {
    if (!(await confirmBox(`إلغاء ${T.label} رقم ${docNo(inv)}؟ رح ينعمل قيد عكسي بتاريخ اليوم.`))) return;
    const d = today() >= S.fy.start_date && today() <= S.fy.end_date ? today() : inv.inv_date;
    const { error } = await sb.rpc('cancel_invoice', { p_id: inv.id, p_date: d }); if (error) return toast(arError(error), 'err');
    toast('تم إلغاء الفاتورة', 'ok'); m.close(); ctx.rerender();
  });
  m.el.querySelector('[data-return]')?.addEventListener('click', () => {
    m.close();
    returnPrefill = { inv, lines };
    invoiceEditor(type === 'sale' ? 'sale_return' : 'purchase_return', null, ctx)
      .then(() => toast('عدّل الكميات المرتجعة، واحذف السطور اللي ما رجعت', ''));
  });
  m.el.querySelector('[data-print]')?.addEventListener('click', () => printInvoice(type, inv, lines, pById[inv.party_id], st));
  m.el.querySelector('[data-wa]')?.addEventListener('click', async () => {
    const p = pById[inv.party_id]; const ph = p?.mobile || p?.phone;
    if (!ph) return toast('ما في رقم جوال للعميل ببطاقته', 'err');
    const [tpl, b] = await Promise.all([msgTemplates(), sb.from('party_balances').select('debit,credit').eq('party_id', p.id).eq('fiscal_year_id', inv.fiscal_year_id).maybeSingle()]);
    const body = fillTpl(tpl.invoice, { name: p.name, no: docNo(inv), date: inv.inv_date, amount: inv.total, balance: b.data ? num(b.data.debit) - num(b.data.credit) : null });
    sendWhatsApp({ party_id: p.id, phone: ph, kind: 'invoice', ref_id: inv.id, body });
  });
  m.el.querySelector('[data-attach]')?.addEventListener('click', () => openAttachments('invoice', inv.id, `${T.label} رقم ${docNo(inv)}`));
}
let returnPrefill = null;
// فتح فاتورة جديدة معبّاة من طلب (طلب مبيعات/تزويد)
function bestPromo(promos, it, date, qty) {
  return promos.filter(p => p.date_from <= date && p.date_to >= date && num(qty) >= num(p.min_qty) && (p.item_id ? p.item_id === it.id : p.category_id ? p.category_id === it.category_id : true))
    .sort((a, b) => num(b.discount_pct) - num(a.discount_pct))[0] || null;
}
export function openInvoicePrefill(type, prefill, ctx) { returnPrefill = { ...prefill, fromOrder: true }; return invoiceEditor(type, null, ctx); }

async function printInvoice(type, inv, lines, party, st) {
  const T = INV[type], c = S.company;
  const win = window.open('', '_blank');   // قبل أي انتظار عشان المتصفح ما يمنع النافذة
  let images = {};
  const pcfg = await loadPrintSettings().catch(() => ({}));
  const ids = [...new Set(lines.map(l => l.item_id).filter(Boolean))];
  if (pcfg.invoice_item_images && ids.length) { const { data } = await sb.from('items').select('id,image').in('id', ids); (data || []).forEach(x => { if (x.image) images[x.id] = x.image; }); }
  const stamp = inv.status === 'cancelled' ? '<h2 class="cancel-stamp">— فاتورة ملغاة —</h2>' : inv.status === 'draft' ? '<h3 class="draft-stamp">— مسودة غير مرحّلة —</h3>' : '';
  const full = () => `
    <table class="meta"><tr><td><b>رقم الفاتورة:</b> ${esc(docNo(inv))}</td><td><b>التاريخ:</b> ${fmtDate(inv.inv_date)}</td><td><b>طريقة الدفع:</b> ${inv.payment_type === 'cash' ? 'نقدي' : 'آجل'}</td></tr>
      <tr><td colspan="2"><b>${T.partyLabel}:</b> ${esc(party?.name || inv.party_name || '')} ${party?.tax_no ? ` — الرقم الضريبي: ${esc(party.tax_no)}` : ''}</td><td>${inv.due_date ? `<b>الاستحقاق:</b> ${fmtDate(inv.due_date)}` : ''}</td></tr>
      ${party?.address || party?.phone ? `<tr><td colspan="3">${esc([party.address, party.city, party.mobile || party.phone].filter(Boolean).join(' — '))}</td></tr>` : ''}
      ${inv.reference ? `<tr><td colspan="3"><b>المرجع:</b> ${esc(inv.reference)}</td></tr>` : ''}</table>
    <table class="pt" style="margin-top:10px"><thead><tr><th>#</th><th>البيان</th><th>الكمية</th><th>السعر</th><th>الخصم</th><th>قبل الضريبة</th><th>ض%</th><th>الضريبة</th><th>الإجمالي</th></tr></thead><tbody>
      ${lines.map((l, i) => `<tr><td>${i + 1}</td><td>${imgOk(images[l.item_id]) ? `<img src="${images[l.item_id]}" style="float:left;max-width:90px;max-height:80px;margin-inline-start:6px;object-fit:contain">` : ''}${esc(l.description || '')}${l.details ? `<div style="font-size:11px;color:#555">${esc(l.details).replace(/\n/g, '<br>')}</div>` : ''}${l.batch_no ? `<div style="font-size:11px;color:#555">دفعة ${esc(l.batch_no)}${l.expiry_date ? ' · ينتهي ' + fmtDate(l.expiry_date) : ''}</div>` : ''}</td><td class="n">${num(l.qty)}</td><td class="n">${fmtPrice(l.unit_price)}</td><td class="n">${num(l.discount) ? fmtNum(l.discount) : ''}</td>
        <td class="n">${fmtNum(l.subtotal)}</td><td class="n">${num(l.tax_rate)}%</td><td class="n">${fmtNum(l.tax_amount)}</td><td class="n">${fmtNum(l.line_total)}</td></tr>`).join('')}</tbody></table>
    <table class="pt" style="width:45%;margin:10px 0 0 auto;margin-inline-start:auto"><tr><td>المجموع قبل الضريبة</td><td class="n">${fmtNum(inv.subtotal)}</td></tr>
      ${num(inv.discount_total) ? `<tr><td>الخصومات</td><td class="n">${fmtNum(inv.discount_total)}</td></tr>` : ''}
      <tr><td>ضريبة المبيعات</td><td class="n">${fmtNum(inv.tax_total)}</td></tr><tr class="tot"><td>الإجمالي (دينار)</td><td class="n">${fmtNum(inv.total)}</td></tr></table>
    <div class="amount-box">${amountToWords(inv.total)}</div>
    ${inv.notes ? `<p><b>ملاحظات:</b> ${esc(inv.notes)}</p>` : ''}${st.invoice_footer ? `<p style="color:#555">${esc(st.invoice_footer)}</p>` : ''}${stamp}`;
  // نسخة الورق الحراري (80 ملم)
  const slim = () => `
    <table class="meta"><tr><td><b>رقم:</b> ${esc(docNo(inv))} — ${fmtDate(inv.inv_date)} — ${inv.payment_type === 'cash' ? 'نقدي' : 'آجل'}</td></tr>
      ${party?.name || inv.party_name ? `<tr><td><b>${T.partyLabel}:</b> ${esc(party?.name || inv.party_name)}</td></tr>` : ''}</table>
    <table class="pt" style="margin-top:6px"><thead><tr><th>الصنف</th><th>كمية</th><th>المبلغ</th></tr></thead><tbody>
      ${lines.map(l => `<tr><td>${esc(l.description || '')}<br><small>${fmtPrice(l.unit_price)} × ${num(l.qty)}</small></td><td class="n">${num(l.qty)}</td><td class="n">${fmtNum(l.line_total)}</td></tr>`).join('')}</tbody>
      <tfoot><tr><td colspan="2">قبل الضريبة</td><td class="n">${fmtNum(inv.subtotal)}</td></tr><tr><td colspan="2">الضريبة</td><td class="n">${fmtNum(inv.tax_total)}</td></tr>
      <tr class="tot"><td colspan="2">الإجمالي</td><td class="n">${fmtNum(inv.total)}</td></tr></tfoot></table>
    ${st.invoice_footer ? `<p style="text-align:center">${esc(st.invoice_footer)}</p>` : ''}${stamp}`;
  const arTitle = (cfg) => (type === 'sale' && cfg.invoice_title) ? cfg.invoice_title : `${T.label}${c.subject_to_sales_tax && type === 'sale' ? ' ضريبية' : ''}`;
  const go = (orderNo) => printDoc(arTitle,
    (cfg, { thermal }) => thermal ? slim() : (cfg.invoice_layout === 'bilingual' && isSaleType(type)) ? bilingualDoc({
      cfg, titleAr: arTitle(cfg), titleEn: cfg.invoice_title_en || (type === 'sale_return' ? 'Sales Return' : 'Sales Invoice'),
      no: docNo(inv), date: inv.inv_date, pay: inv.payment_type === 'cash' ? 'نقدي / Cash' : 'آجل / Credit', orderNo, project: inv.project,
      party, partyName: party?.name || inv.party_name, lines, sub: inv.subtotal, disc: inv.discount_total, tax: inv.tax_total, total: inv.total, notes: inv.notes, stamp,
      footer: st.invoice_footer, images }) : full(), { kind: 'invoice', win, copies: docCopies(inv.doc_type_id), branch: inv.department_id ? sb.from('departments').select('name,address,city,phone,income_tax_no,sales_tax_no').eq('id', inv.department_id).maybeSingle().then(r => r.data || null) : null });
  if (isSaleType(type)) sb.from('orders').select('order_no').eq('invoice_id', inv.id).limit(1).then(({ data }) => go(data?.[0]?.order_no || '')); else go('');
}
const isSaleType = (t) => t === 'sale' || t === 'sale_return';
const imgOk = (u) => typeof u === 'string' && /^data:image\/(png|jpe?g|webp);base64,[A-Za-z0-9+/=]+$/.test(u);

// نموذج ثنائي اللغة (عربي/إنجليزي) للفاتورة وطلب المبيعات — مثل نماذج الشركات التجارية
export function bilingualDoc({ cfg, titleAr, titleEn, no, date, pay, orderNo, project, party, partyName, lines, sub, disc, tax, total, notes, stamp = '', footer = '', noLabel = ['رقم الفاتورة', 'Invoice No.'], images = {} }) {
  const c = S.company || {}, col = cfg.color || '#2e6b4f';
  const itBy = Object.fromEntries((S.items || []).map(i => [i.id, i]));
  const L = (ar, en) => `<span class="ar">${ar}</span><span class="en">${en}</span>`;
  const rows = lines.map((l, i) => { const it = itBy[l.item_id] || {};
    return `<tr><td class="c">${i + 1}</td><td class="c">${esc(it.code || '')}</td>
      <td class="desc">${imgOk(images[l.item_id]) ? `<img src="${images[l.item_id]}" style="float:left;max-width:120px;max-height:110px;margin:2px 0 2px 8px;object-fit:contain">` : ''}<b>${esc(l.description || '')}</b>${l.details ? `<div class="det">${esc(l.details).replace(/\n/g, '<br>')}</div>` : ''}${l.batch_no ? `<div class="det">Batch / دفعة ${esc(l.batch_no)}${l.expiry_date ? ' · Exp ' + fmtDate(l.expiry_date) : ''}</div>` : ''}</td>
      <td class="c">${esc(it.unit || '')}</td><td class="c">${num(l.qty)}</td><td class="n">${fmtPrice(l.unit_price)}</td><td class="n">${fmtNum(num(l.qty) * num(l.unit_price) - num(l.discount))}</td></tr>`; }).join('');
  const filler = `<tr class="fill"><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>`;
  const html = `<div class="bl">
    <div class="bl-head">
      <div class="bl-ar"><div class="nm">${esc(c.name || '')}</div><div>${esc([c.address, c.city].filter(Boolean).join(' - '))}</div></div>
      <div class="bl-logo">${c.logo_url ? `<img src="${esc(c.logo_url)}">` : ''}</div>
      <div class="bl-en"><div class="nm">${esc(c.name_en || c.name || '')}</div><div>${esc(c.address_en || '')}</div></div></div>
    <div class="bl-titles"><div class="t-ar">${esc(titleAr)}</div><div class="tax">${c.sales_tax_no || c.income_tax_no ? `الرقم الضريبي: <b>${esc(c.sales_tax_no || c.income_tax_no)}</b>` : ''}</div><div class="t-en">${esc(titleEn)}</div></div>
    <table class="bl-meta"><tr>
      <td class="lbl">${L('السيد / السادة:', 'Messrs:')}</td><td class="val big">${esc(partyName || '')}</td>
      <td class="lbl">${L(noLabel[0] + ':', noLabel[1] + ':')}</td><td class="val">${esc(no)}</td></tr>
      <tr><td class="lbl">${L('رقم الهاتف:', 'Phone:')}</td><td class="val" dir="ltr">${esc([party?.mobile, party?.phone].filter(Boolean).join(' - '))}</td>
      <td class="lbl">${L('التاريخ:', 'Date:')}</td><td class="val">${fmtDate(date)}</td></tr>
      <tr><td class="lbl">${L('بريد إلكتروني:', 'E-Mail:')}</td><td class="val" dir="ltr">${esc(party?.email || '')}</td>
      <td class="lbl">${L('وسيلة الدفع:', 'Payment:')}</td><td class="val">${esc(pay || '')}</td></tr>
      <tr><td class="lbl">${L('المشروع:', 'Project:')}</td><td class="val">${esc(project || '')}</td>
      <td class="lbl">${L('رقم الطلب:', 'Order#:')}</td><td class="val">${esc(orderNo || '')}</td></tr>
      ${party?.tax_no ? `<tr><td class="lbl">${L('رقم العميل الضريبي:', 'Customer TRN:')}</td><td class="val">${esc(party.tax_no)}</td><td></td><td></td></tr>` : ''}</table>
    <table class="bl-lines"><thead><tr><th class="c">${L('رقم', 'No.')}</th><th class="c">${L('رقم المادة', 'Item No.')}</th><th>${L('التفاصيل', 'Description')}</th><th class="c">${L('الوحدة', 'Unit')}</th><th class="c">${L('الكمية', 'Qty.')}</th><th>${L('سعر الوحدة', 'Unit Price')}</th><th>${L('المجموع', 'Total')}</th></tr></thead>
      <tbody>${rows}${filler}</tbody></table>
    <table class="bl-foot"><tr>
      <td class="sig"><div class="sg"><div>${L('اسم وتوقيع البائع', 'Prepared By')}</div><div class="ln"></div></div><div class="sg"><div>${L('اسم وتوقيع العميل', 'Authenticated By')}</div><div class="ln"></div></div></td>
      <td class="tots"><table>
        <tr><td>${L('المجموع', 'Total')}</td><td class="n">${fmtNum(num(sub) + num(disc))}</td></tr>
        <tr><td>${L('الخصم', 'Discount')}</td><td class="n">${fmtNum(disc)}</td></tr>
        <tr><td>${L('الصافي', 'Net')}</td><td class="n">${fmtNum(sub)}</td></tr>
        <tr><td>${L('الضريبة', 'VAT')}</td><td class="n">${fmtNum(tax)}</td></tr>
        <tr class="due"><td>${L('المطلوب', 'Net Due')}</td><td class="n">${fmtNum(total)}</td></tr></table></td></tr>
      <tr><td colspan="2" class="words">${esc(amountToWords(total))}</td></tr></table>
    ${notes ? `<div class="bl-note"><b>ملاحظات / Notes:</b> ${esc(notes)}</div>` : ''}
    ${cfg.invoice_terms ? `<div class="bl-note">- ${esc(cfg.invoice_terms)}</div>` : ''}${footer ? `<div class="bl-note">${esc(footer)}</div>` : ''}${stamp}
    <div class="bl-bottom" dir="ltr">${esc([c.address_en || c.address, c.city].filter(Boolean).join(' | '))}${c.mobile ? ` | Mobile: ${esc(c.mobile)}` : ''}${c.phone ? ` | Phone: ${esc(c.phone)}` : ''}<br>${c.website ? `Website: ${esc(c.website)}` : ''}${c.email ? ` | Email: ${esc(c.email)}` : ''}</div></div>`;
  const css = `.bl{font-size:12px}.bl .en{display:block;font-size:.82em;direction:ltr;opacity:.85}.bl .ar{display:block}
    .bl-head{display:flex;align-items:center;justify-content:space-between;border-bottom:3px solid ${col};padding-bottom:6px;gap:10px}
    .bl-head .nm{font-size:1.35em;font-weight:800;color:${col}}.bl-en{direction:ltr;text-align:left;flex:1}.bl-ar{text-align:right;flex:1}.bl-logo img{max-height:70px;max-width:160px}
    .bl-titles{display:flex;justify-content:space-between;align-items:center;margin:8px 0}.bl-titles .t-ar,.bl-titles .t-en{font-size:1.5em;font-weight:800;color:${col}}.bl-titles .t-en{direction:ltr}
    .bl-meta{width:100%;border-collapse:collapse;margin-bottom:6px}.bl-meta td{padding:3px 6px;vertical-align:top}.bl-meta .lbl{white-space:nowrap;color:#444;width:1%}.bl-meta .val{border-bottom:1px dotted #bbb}.bl-meta .big{font-weight:700;font-size:1.1em}
    .bl-lines{width:100%;border-collapse:collapse;border:1px solid #888}.bl-lines th{background:${col};color:#fff;padding:5px;font-size:.92em;border:1px solid #888}
    .bl-lines td{border-inline:1px solid #888;padding:5px;vertical-align:top}.bl-lines tbody tr:not(.fill) td{border-bottom:1px solid #ddd}.bl-lines .fill td{height:120px}
    .bl-lines .c{text-align:center}.bl-lines .n{text-align:left;direction:ltr}.bl-lines .desc{text-align:left;direction:ltr}.bl-lines .desc .det{font-size:.9em;color:#333;white-space:normal;margin-top:2px}
    .bl-foot{width:100%;border-collapse:collapse;margin-top:6px}.bl-foot td{vertical-align:top}.bl-foot .sig{display:flex;gap:20px;justify-content:space-around;padding-top:10px}.bl-foot .sg{text-align:center;min-width:160px}.bl-foot .ln{border-bottom:1px solid #555;height:40px}
    .bl-foot .tots{width:36%}.bl-foot .tots table{width:100%;border-collapse:collapse}.bl-foot .tots td{border:1px solid #888;padding:4px 6px}.bl-foot .tots td:first-child{background:${col};color:#fff;width:45%}
    .bl-foot .tots .due td{font-weight:800;font-size:1.1em}.bl-foot .n{text-align:left;direction:ltr}
    .bl-foot .words{background:${col};color:#fff;text-align:center;padding:5px;font-weight:700}.bl-note{margin-top:6px;font-size:.92em}
    .bl-bottom{margin-top:12px;border-top:2px solid ${col};padding-top:6px;text-align:center;font-size:.9em;color:#333}`;
  return { bare: true, html, css };
}

// ---------------------------------------------------------------------
//  تقرير إقرار ضريبة المبيعات
// ---------------------------------------------------------------------
async function viewSalesTax(v) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const c = S.company, y = S.fy ? new Date(S.fy.start_date).getFullYear() : new Date().getFullYear();
  const periods = c.sales_tax_period === 'monthly'
    ? Array.from({ length: 12 }, (_, i) => [`${y}-${String(i + 1).padStart(2, '0')}-01`, new Date(y, i + 1, 0)])
    : Array.from({ length: 6 }, (_, i) => [`${y}-${String(i * 2 + 1).padStart(2, '0')}-01`, new Date(y, i * 2 + 2, 0)]);
  const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const MONTHS = ['كانون الثاني', 'شباط', 'آذار', 'نيسان', 'أيار', 'حزيران', 'تموز', 'آب', 'أيلول', 'تشرين الأول', 'تشرين الثاني', 'كانون الأول'];
  const cur = periods.findIndex(([s, e]) => today() >= s && today() <= iso(e));
  v.innerHTML = `<div class="page-head"><h2>🏛️ إقرار ضريبة المبيعات</h2><span class="muted">${c.subject_to_sales_tax ? (c.sales_tax_period === 'monthly' ? 'إقرار شهري' : 'إقرار كل شهرين') : '⚠️ الشركة مش مسجّلة كخاضعة لضريبة المبيعات ببياناتها'}</span></div>
    <div class="card no-print filters">
      <div class="field"><label>الفترة</label><select id="f-per">${periods.map(([s, e], i) => `<option value="${i}" ${i === Math.max(cur, 0) ? 'selected' : ''}>${c.sales_tax_period === 'monthly' ? MONTHS[i] : MONTHS[i * 2] + ' - ' + MONTHS[i * 2 + 1]} ${y}</option>`).join('')}<option value="x">فترة مخصصة…</option></select></div>
      <div class="field"><label>من</label><input type="date" id="f-from"></div><div class="field"><label>إلى</label><input type="date" id="f-to"></div>
      <div class="field" style="justify-content:flex-end"><button class="btn primary" id="f-run">عرض</button></div>
      <div class="field" style="justify-content:flex-end;flex-direction:row;gap:6px"><button class="btn" id="f-print">🖨️ طباعة</button><button class="btn" id="f-csv">⬇️ Excel</button></div></div>
    <div id="out"></div>`;
  const setPer = () => { const i = v.querySelector('#f-per').value; if (i === 'x') return; v.querySelector('#f-from').value = periods[i][0]; v.querySelector('#f-to').value = iso(periods[i][1]); };
  setPer(); v.querySelector('#f-per').onchange = () => { setPer(); run(); };
  let last = null;
  const run = async () => {
    const from = v.querySelector('#f-from').value, to = v.querySelector('#f-to').value, out = v.querySelector('#out');
    const { data, error } = await sb.rpc('rep_sales_tax', { p_company: c.id, p_from: from, p_to: to });
    if (error) return void (out.innerHTML = `<div class="notice">${esc(arError(error))}</div>`);
    const g = (t, pred = () => true) => data.filter(r => r.inv_type === t && pred(num(r.tax_rate))).reduce((s, r) => ({ sub: s.sub + num(r.subtotal), tax: s.tax + num(r.tax) }), { sub: 0, tax: 0 });
    const salesStd = g('sale', x => x === 16), salesOther = g('sale', x => x > 0 && x !== 16), salesZero = g('sale', x => x === 0), sRet = g('sale_return');
    const purTax = g('purchase', x => x > 0), purZero = g('purchase', x => x === 0), pRet = g('purchase_return');
    const sDn = g('sale_dn'), sCn = g('sale_cn'), pDn = g('purchase_dn'), pCn = g('purchase_cn');   // الإشعارات
    const outTax = salesStd.tax + salesOther.tax - sRet.tax + sDn.tax - sCn.tax, inTax = purTax.tax - pRet.tax + pCn.tax - pDn.tax, net = outTax - inTax;
    const R = (l, a, b, cls = '') => `<tr class="${cls}"><td>${l}</td><td class="n">${a === null ? '' : fmtNum(a)}</td><td class="n">${b === null ? '' : fmtNum(b)}</td></tr>`;
    const table = `<table class="t pt rep statement"><thead><tr><th>البند</th><th>القيمة قبل الضريبة</th><th>الضريبة</th></tr></thead><tbody>
      <tr class="sec"><td colspan="3">المبيعات (ضريبة المخرجات)</td></tr>
      ${R('مبيعات خاضعة بالنسبة العامة 16%', salesStd.sub, salesStd.tax)}${R('مبيعات خاضعة بنسب أخرى', salesOther.sub, salesOther.tax)}
      ${R('مبيعات معفاة أو بنسبة صفر', salesZero.sub, 0)}${R('ينزل: مردودات المبيعات', -sRet.sub, -sRet.tax)}
      ${sDn.sub ? R('يضاف: إشعارات مدينة للعملاء', sDn.sub, sDn.tax) : ''}${sCn.sub ? R('ينزل: إشعارات دائنة للعملاء', -sCn.sub, -sCn.tax) : ''}
      ${R('صافي ضريبة المخرجات', null, outTax, 'tot')}
      <tr class="sec"><td colspan="3">المشتريات (ضريبة المدخلات)</td></tr>
      ${R('مشتريات خاضعة للضريبة', purTax.sub, purTax.tax)}${R('مشتريات معفاة أو بنسبة صفر', purZero.sub, 0)}${R('ينزل: مردودات المشتريات', -pRet.sub, -pRet.tax)}
      ${pCn.sub ? R('يضاف: إشعارات دائنة من الموردين', pCn.sub, pCn.tax) : ''}${pDn.sub ? R('ينزل: إشعارات مدينة للموردين', -pDn.sub, -pDn.tax) : ''}
      ${R('صافي ضريبة المدخلات القابلة للخصم', null, inTax, 'tot')}
      <tr class="net ${net >= 0 ? 'neg' : 'pos'}"><td>${net >= 0 ? 'الضريبة المستحقة للدفع' : 'رصيد دائن (قابل للتدوير أو الاسترداد)'}</td><td></td><td class="n">${fmtNum(Math.abs(net))}</td></tr></tbody></table>`;
    out.innerHTML = `<div class="card table-wrap" style="margin-top:12px">${table}</div>
      <p class="muted" style="font-size:13px">من الفواتير والإشعارات المرحّلة من ${fmtDate(from)} إلى ${fmtDate(to)}. راجع الأرقام مع نموذج الإقرار على بوابة دائرة ضريبة الدخل والمبيعات قبل التقديم.</p>`;
    last = { from, to, table, rows: [['مبيعات 16%', salesStd.sub, salesStd.tax], ['مبيعات بنسب أخرى', salesOther.sub, salesOther.tax], ['مبيعات معفاة/صفرية', salesZero.sub, 0], ['مردودات المبيعات', -sRet.sub, -sRet.tax], ['مشتريات خاضعة', purTax.sub, purTax.tax], ['مشتريات معفاة', purZero.sub, 0], ['مردودات المشتريات', -pRet.sub, -pRet.tax], ['إشعارات مدينة للعملاء', sDn.sub, sDn.tax], ['إشعارات دائنة للعملاء', -sCn.sub, -sCn.tax], ['إشعارات دائنة من الموردين', pCn.sub, pCn.tax], ['إشعارات مدينة للموردين', -pDn.sub, -pDn.tax], ['الضريبة المستحقة', '', net]] };
  };
  v.querySelector('#f-run').onclick = run;
  if (!can('reports', 'print')) v.querySelector('#f-print').style.display = 'none';
  v.querySelector('#f-print').onclick = () => last && printDoc('كشف إقرار ضريبة المبيعات', last.table, { subtitle: `الفترة من ${fmtDate(last.from)} إلى ${fmtDate(last.to)} — رقم ضريبة المبيعات: ${c.sales_tax_no || '—'}` });
  v.querySelector('#f-csv').onclick = () => last && downloadCSV(`إقرار ضريبة المبيعات ${last.from}.csv`, [['البند', 'القيمة', 'الضريبة']].concat(last.rows.map(r => r.map(x => typeof x === 'number' ? x.toFixed(3) : x))));
  run();
}

export const INVOICE_ROUTES = {
  'settings': viewSettings, 'items': viewItems,
  'sales': invoiceList('sales'), 'purchases': invoiceList('purchases'),
  'rep-salestax': viewSalesTax,
};

// سجل أسعار الصنف لطرف: كل الفواتير المرحّلة، وكبسة «استعمل» بترجّع السعر للفاتورة
export async function priceHistory(p, it, kind, onPick) {
  const { data, error } = await sb.rpc('party_price_history', { p_company: S.company.id, p_party: p.id, p_item: it.id, p_kind: kind, p_limit: 100 });
  if (error) return toast(arError(error), 'err');
  const rows = data || [], last = rows[0];
  const nets = rows.map(r => num(r.net_price));
  const m = modal({ title: `🕘 سجل أسعار ${esc(it.name)} — ${esc(p.name)}`, body: !rows.length ? '<p class="muted">ما في فواتير مرحّلة لهالصنف مع هالطرف.</p>' : `
    <div class="cards" style="display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:8px;margin-bottom:10px">
      <div class="card" style="padding:8px"><div class="muted" style="font-size:12px">آخر سعر صافي</div><b dir="ltr">${fmtPrice(last.net_price)}</b></div>
      <div class="card" style="padding:8px"><div class="muted" style="font-size:12px">أقل / أعلى</div><b dir="ltr">${fmtPrice(Math.min(...nets))} – ${fmtPrice(Math.max(...nets))}</b></div>
      <div class="card" style="padding:8px"><div class="muted" style="font-size:12px">المتوسط</div><b dir="ltr">${fmtPrice(nets.reduce((a, b) => a + b, 0) / nets.length)}</b></div>
      <div class="card" style="padding:8px"><div class="muted" style="font-size:12px">عدد الفواتير</div><b>${new Set(rows.map(r => r.invoice_id)).size}</b></div></div>
    <div class="table-wrap"><table class="t"><thead><tr><th>التاريخ</th><th>الفاتورة</th><th>الكمية</th><th>السعر</th><th>الخصم</th><th>الصافي للوحدة</th><th>الضريبة</th>${onPick ? '<th></th>' : ''}</tr></thead><tbody>
    ${rows.map(r => `<tr><td>${fmtDate(r.inv_date)}</td><td>${esc(r.doc_no)}</td><td class="n">${fmtQty(r.qty)}</td><td class="n">${fmtPrice(r.unit_price)}${r.include_tax ? ' <span class="muted" style="font-size:11px">شامل</span>' : ''}</td>
      <td class="n">${num(r.discount) ? fmtNum(r.discount) : ''}</td><td class="n"><b>${fmtPrice(r.net_price)}</b></td><td class="n">${num(r.tax_rate)}%</td>
      ${onPick ? `<td><button class="btn sm" data-use="${r.net_price}">استعمل</button></td>` : ''}</tr>`).join('')}</tbody></table></div>
    <p class="muted" style="font-size:12px">الصافي = بعد خصم السطر وقبل الضريبة. الفواتير المرحّلة بس.</p>`,
    foot: '<button class="btn" data-close>إغلاق</button>' });
  m.el.querySelector('.modal').style.maxWidth = '820px';
  m.el.querySelectorAll('[data-use]').forEach(b => b.onclick = () => { onPick(num(b.dataset.use)); m.close(); });
}
