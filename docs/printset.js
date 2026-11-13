// =====================================================================
//  السمو ERP — نماذج الطباعة (لكل شركة)
// =====================================================================
import { S, sb, esc, toast, arError, can, log } from './core.js';
import { printDoc, loadPrintSettings, clearPrintCache, mergePrint, SIG_KINDS, amountToWords } from './print.js';

const SAMPLE = {
  invoice: () => `<table class="meta"><tr><td><b>رقم الفاتورة:</b> 125</td><td><b>التاريخ:</b> 11/11/2026</td><td><b>طريقة الدفع:</b> آجل</td></tr>
    <tr><td colspan="3"><b>العميل:</b> شركة النور للتجارة — الرقم الضريبي: 12345678</td></tr></table>
    <table class="pt" style="margin-top:10px"><thead><tr><th>#</th><th>البيان</th><th>الكمية</th><th>السعر</th><th>قبل الضريبة</th><th>ض%</th><th>الإجمالي</th></tr></thead><tbody>
    <tr><td>1</td><td>خدمة استشارة ضريبية</td><td class="n">2</td><td class="n">150.000</td><td class="n">300.000</td><td class="n">16%</td><td class="n">348.000</td></tr>
    <tr><td>2</td><td>إعداد إقرار ضريبة الدخل</td><td class="n">1</td><td class="n">200.000</td><td class="n">200.000</td><td class="n">16%</td><td class="n">232.000</td></tr></tbody></table>
    <table class="pt" style="width:45%;margin:10px 0 0 auto"><tr><td>المجموع قبل الضريبة</td><td class="n">500.000</td></tr><tr><td>ضريبة المبيعات</td><td class="n">80.000</td></tr>
    <tr class="tot"><td>الإجمالي (دينار)</td><td class="n">580.000</td></tr></table><div class="amount-box">${amountToWords(580)}</div>`,
  slim: () => `<table class="meta"><tr><td><b>رقم:</b> 125 — 11/11/2026 — نقدي</td></tr></table>
    <table class="pt"><thead><tr><th>الصنف</th><th>كمية</th><th>المبلغ</th></tr></thead><tbody>
    <tr><td>كرتونة ماء<br><small>2.000 × 3</small></td><td class="n">3</td><td class="n">6.960</td></tr><tr><td>ورق تصوير<br><small>4.000 × 1</small></td><td class="n">1</td><td class="n">4.640</td></tr></tbody>
    <tfoot><tr class="tot"><td colspan="2">الإجمالي</td><td class="n">11.600</td></tr></tfoot></table>`,
  receipt: () => `<table class="meta"><tr><td><b>التاريخ:</b> 11/11/2026</td><td><b>المرجع:</b> شيك 10025</td></tr>
    <tr><td><b>استلمنا من السيد/السادة:</b> محمد القريوتي</td><td><b>إلى حساب:</b> النقد في الصندوق</td></tr><tr><td colspan="2"><b>البيان:</b> دفعة من الحساب</td></tr></table>
    <div class="amount-box">مبلغ وقدره: <b>750.000</b> دينار<br><span>${amountToWords(750)}</span></div>`,
};

async function viewPrintSettings(v) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const editable = can('companies', 'edit');
  let cfg = await loadPrintSettings(true);
  const dis = editable ? '' : 'disabled';
  const opt = (name, list) => list.map(([k, l]) => `<option value="${k}" ${cfg[name] === k ? 'selected' : ''}>${l}</option>`).join('');
  v.innerHTML = `<div class="page-head"><h2>🖨️ نماذج الطباعة</h2><div class="spacer"></div>${editable ? '<button class="btn primary" id="save">💾 حفظ</button>' : ''}</div>
    <p class="muted">هالإعدادات لهالشركة بس، وبتنطبق على كل المطبوعات: الفواتير، والسندات، والشيكات، وسندات المخزون، والكشوفات والتقارير.</p>
    <div class="grid cols-2" style="align-items:start;gap:16px">
    <form id="pf" class="card">
      <h3 style="margin-top:0">الشكل</h3>
      <div class="grid cols-2">
        <div class="field"><label>النموذج</label><select name="template" ${dis}>${opt('template', [['classic', 'كلاسيكي (خطوط وحدود)'], ['modern', 'حديث (ترويسة ملوّنة)'], ['simple', 'بسيط أبيض وأسود (توفير حبر)']])}</select></div>
        <div class="field"><label>اللون الأساسي</label><input type="color" name="color" value="${esc(cfg.color)}" style="height:42px;padding:3px" ${dis}></div>
        <div class="field"><label>ورق المستندات والتقارير</label><select name="paper" ${dis}>${opt('paper', [['A4', 'A4'], ['A5', 'A5 (نص صفحة)']])}</select></div>
        <div class="field"><label>ورق الفواتير</label><select name="invoice_paper" ${dis}>${opt('invoice_paper', [['A4', 'A4'], ['A5', 'A5 (نص صفحة)'], ['80mm', 'طابعة كاشير حرارية 80 ملم']])}</select></div>
        <div class="field"><label>حجم الخط</label><select name="font" ${dis}>${[11, 12, 12.5, 13, 14].map(n => `<option value="${n}" ${+cfg.font === n ? 'selected' : ''}>${n}</option>`).join('')}</select></div>
        <div class="field"><label>شكل الفاتورة وطلب المبيعات</label><select name="invoice_layout" ${dis}>${opt('invoice_layout', [['standard', 'عادي (عربي)'], ['bilingual', 'ثنائي اللغة عربي/إنجليزي (Messrs / Item No.)']])}</select></div>
        <div class="field"><label>عنوان الفاتورة بالإنجليزي (للثنائي)</label><input name="invoice_title_en" value="${esc(cfg.invoice_title_en || '')}" placeholder="Sales Invoice" dir="ltr" ${dis}></div>
        <div class="field" style="grid-column:span 2"><label>نص أسفل الفاتورة الثنائية (إقرار الاستلام)</label><input name="invoice_terms" value="${esc(cfg.invoice_terms || '')}" placeholder="إن توقيع المستلم يعتبر إقراراً باستلام البضاعة المبينة بالفاتورة كاملة وبحالة جيدة…" ${dis}></div>
        <div class="field"><label>عنوان فاتورة البيع (اختياري)</label><input name="invoice_title" value="${esc(cfg.invoice_title)}" placeholder="مثلاً: فاتورة ضريبية" ${dis}></div>
      </div>
      <label class="check"><input type="checkbox" name="watermark" ${cfg.watermark ? 'checked' : ''} ${dis}> علامة مائية باسم الشركة والسنة</label>
      <label class="check"><input type="checkbox" name="invoice_item_images" ${cfg.invoice_item_images ? 'checked' : ''} ${dis}> صورة الصنف بالفاتورة (جنب التفاصيل)</label>
      <label class="check"><input type="checkbox" name="show_tax_numbers" ${cfg.show_tax_numbers ? 'checked' : ''} ${dis}> إظهار الأرقام الضريبية بالترويسة</label>
      <label class="check"><input type="checkbox" name="show_printed_by" ${cfg.show_printed_by ? 'checked' : ''} ${dis}> إظهار «طُبع بواسطة» تحت</label>
      <h3>الشعار</h3>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <div id="logo-box" style="width:120px;height:70px;border:1px dashed var(--line);border-radius:10px;display:flex;align-items:center;justify-content:center;background:#fff">
          ${S.company.logo_url ? `<img src="${esc(S.company.logo_url)}" style="max-width:110px;max-height:62px">` : '<span class="muted">بدون شعار</span>'}</div>
        ${editable ? `<label class="btn sm">📷 اختيار صورة<input type="file" id="logo" accept="image/*" hidden></label>${S.company.logo_url ? '<button type="button" class="btn sm" id="logo-rm">إزالة</button>' : ''}` : ''}
      </div>
      <h3>نصوص إضافية</h3>
      <div class="field"><label>سطر تحت الترويسة (شعار أو عنوان فرعي)</label><input name="header_note" value="${esc(cfg.header_note)}" ${dis}></div>
      <div class="field"><label>نص أسفل كل المطبوعات (مثلاً الحساب البنكي أو الشروط)</label><textarea name="footer_text" style="min-height:60px" ${dis}>${esc(cfg.footer_text)}</textarea></div>
      <h3>التواقيع على كل نوع مستند</h3>
      <p class="muted" style="font-size:13px;margin-top:-6px">افصل بين التواقيع بفاصلة. اتركها فاضية إذا ما بدك تواقيع.</p>
      <div class="grid cols-2">${Object.entries(SIG_KINDS).map(([k, l]) => `<div class="field"><label>${l}</label><input data-sig="${k}" value="${esc(cfg.sig[k] || '')}" ${dis}></div>`).join('')}</div>
    </form>
    <div class="card" style="position:sticky;top:70px">
      <div style="display:flex;gap:8px;align-items:center;margin-bottom:8px"><b>معاينة</b><div class="spacer" style="flex:1"></div>
        <select id="pv-kind" class="search"><option value="invoice">فاتورة</option><option value="receipt">سند قبض</option></select>
        <button class="btn sm" id="pv-print">🖨️ تجربة طباعة</button></div>
      <iframe id="pv" style="width:100%;height:640px;border:1px solid var(--line);border-radius:10px;background:#fff"></iframe>
    </div></div>`;
  const f = v.querySelector('#pf');
  const read = () => {
    const d = {}; f.querySelectorAll('[name]').forEach(el => d[el.name] = el.type === 'checkbox' ? el.checked : el.value);
    d.font = +d.font; d.sig = {}; f.querySelectorAll('[data-sig]').forEach(el => d.sig[el.dataset.sig] = el.value.trim());
    return mergePrint(d);
  };
  const sample = (k, c) => k === 'invoice' ? (c.invoice_paper === '80mm' ? SAMPLE.slim() : SAMPLE.invoice()) : SAMPLE.receipt();
  const title = (k, c) => k === 'invoice' ? (c.invoice_title || 'فاتورة بيع ضريبية') : 'سند قبض رقم 58';
  const render = () => { const c = read(), k = v.querySelector('#pv-kind').value; const fr = v.querySelector('#pv');
    printDoc(title(k, c), sample(k, c), { kind: k, preview: fr.contentWindow, cfg: c }); };
  let t; f.addEventListener('input', () => { clearTimeout(t); t = setTimeout(render, 250); }); f.addEventListener('change', render);
  v.querySelector('#pv-kind').onchange = render;
  v.querySelector('#pv-print').onclick = () => { const c = read(), k = v.querySelector('#pv-kind').value; printDoc(title(k, c), sample(k, c), { kind: k, cfg: c }); };
  // الشعار: بيتصغّر وبينحفظ مع بيانات الشركة
  v.querySelector('#logo')?.addEventListener('change', async (e) => {
    const file = e.target.files[0]; if (!file) return;
    const img = new Image(); img.src = URL.createObjectURL(file); await img.decode().catch(() => null);
    if (!img.width) return toast('الصورة مش مقروءة', 'err');
    const sc = Math.min(1, 360 / Math.max(img.width, img.height)), cv = document.createElement('canvas');
    cv.width = Math.round(img.width * sc); cv.height = Math.round(img.height * sc); cv.getContext('2d').drawImage(img, 0, 0, cv.width, cv.height);
    const url = cv.toDataURL(file.type === 'image/jpeg' ? 'image/jpeg' : 'image/png', .9);
    const { error } = await sb.from('companies').update({ logo_url: url }).eq('id', S.company.id);
    if (error) return toast(arError(error), 'err');
    S.company.logo_url = url; toast('تم حفظ الشعار', 'ok'); viewPrintSettings(v);
  });
  v.querySelector('#logo-rm')?.addEventListener('click', async () => {
    const { error } = await sb.from('companies').update({ logo_url: null }).eq('id', S.company.id);
    if (error) return toast(arError(error), 'err'); S.company.logo_url = null; viewPrintSettings(v);
  });
  v.querySelector('#save')?.addEventListener('click', async () => {
    const c = read();
    await sb.rpc('ensure_company_settings', { p_company: S.company.id });
    const { error } = await sb.from('company_settings').update({ print_settings: c, updated_at: new Date().toISOString() }).eq('company_id', S.company.id);
    if (error) return toast(arError(error), 'err');
    clearPrintCache(); await log('تعديل', 'print_settings', S.company.id); toast('تم حفظ نماذج الطباعة', 'ok');
  });
  render();
}

export const PRINTSET_ROUTES = { 'print-settings': viewPrintSettings };
