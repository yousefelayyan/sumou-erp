// =====================================================================
//  السمو ERP — الطباعة والتفقيط
// =====================================================================
import { translateDoc, LANG } from './i18n.js';
import { S, sb, esc, fmtDateTime } from './core.js';

// ---------------------------------------------------------------------
//  إعدادات نماذج الطباعة لكل شركة (company_settings.print_settings)
// ---------------------------------------------------------------------
export const PRINT_DEFAULTS = {
  template: 'classic',          // classic | modern | simple
  color: '#5b2a86',
  paper: 'A4',                  // A4 | A5
  invoice_paper: 'A4',          // A4 | A5 | 80mm
  font: 12.5,
  watermark: true,
  show_tax_numbers: true,
  show_printed_by: true,
  header_note: '',
  footer_text: '',
  invoice_title: '',
  invoice_layout: 'standard',   // standard | bilingual
  invoice_title_en: '',
  invoice_terms: '',
  invoice_item_images: false,   // صورة الصنف جنب التفاصيل بالفاتورة
  sig: {
    invoice: 'المستلِم، المحاسب',
    receipt: 'المحاسب، المدير المالي، المستلِم',
    payment: 'المحاسب، المدير المالي، المستلِم',
    journal: 'المحاسب، المدير المالي، المدقق',
    cheque: 'المستلِم، المحاسب',
    stock: 'أمين المستودع، المحاسب',
    payroll: 'المحاسب، المدير العام',
  },
};
export const SIG_KINDS = { invoice: 'الفواتير', receipt: 'سند القبض', payment: 'سند الصرف', journal: 'سند القيد', cheque: 'الشيكات', stock: 'سندات المخزون', payroll: 'الرواتب' };
const cfgCache = {};
export function mergePrint(ps) { const o = { ...PRINT_DEFAULTS, ...(ps || {}) }; o.sig = { ...PRINT_DEFAULTS.sig, ...(ps?.sig || {}) }; return o; }
export async function loadPrintSettings(force = false) {
  const id = S.company?.id; if (!id) return mergePrint();
  if (!force && cfgCache[id]) return cfgCache[id];
  const { data } = await sb.from('company_settings').select('print_settings').eq('company_id', id).maybeSingle();
  return (cfgCache[id] = mergePrint(data?.print_settings));
}
export function clearPrintCache() { for (const k in cfgCache) delete cfgCache[k]; }

function css(cfg, { landscape, thermal, paper }) {
  const col = /^#[0-9a-f]{3,8}$/i.test(cfg.color) ? cfg.color : '#5b2a86';
  const fs = thermal ? 10.5 : (paper === 'A5' ? Math.max(9.5, cfg.font - 2) : cfg.font);
  const base = `
    @page { size: ${thermal ? '80mm auto' : `${paper} ${landscape ? 'landscape' : 'portrait'}`}; margin: ${thermal ? '3mm' : paper === 'A5' ? '8mm' : '12mm'}; }
    * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    body { font-family: 'Tajawal', sans-serif; color: #111; font-size: ${fs}px; margin: 0; ${thermal ? 'width: 72mm;' : ''} }
    .head { display: flex; align-items: center; gap: 14px; padding-bottom: 10px; margin-bottom: 12px; }
    .head img { max-height: ${thermal ? 46 : 64}px; max-width: 130px; object-fit: contain }
    .head .co { flex: 1 } .head .co h1 { margin: 0; font-size: ${thermal ? 15 : 19}px } .head .co div { font-size: ${thermal ? 10 : 12}px }
    .head .meta2 { text-align: left; font-size: 11px }
    h2.title { text-align: center; margin: 6px 0 2px; font-size: ${thermal ? 14 : 18}px } .sub { text-align: center; color: #555; margin-bottom: 12px }
    table { width: 100%; border-collapse: collapse }
    table.pt th, table.pt td { padding: ${thermal ? '3px 2px' : '5px 7px'}; text-align: right }
    .n { text-align: left !important; direction: ltr; white-space: nowrap; font-variant-numeric: tabular-nums }
    table.meta td { padding: 4px; border-bottom: 1px dashed #ccc }
    .amount-box { border-radius: 8px; padding: 10px 14px; margin: 12px 0; font-size: ${thermal ? 12 : 15}px }
    .amount-box span { font-size: 13px; color: #333 }
    .signs { display: flex; justify-content: space-around; gap: 10px; margin-top: 50px; page-break-inside: avoid } .signs div { border-top: 1px solid #333; padding-top: 6px; width: 160px; text-align: center }
    .wm { position: fixed; inset: 0; display: flex; align-items: center; justify-content: center; pointer-events: none; z-index: -1 }
    .wm div { transform: rotate(-24deg); font-size: 64px; font-weight: 800; color: ${col}; opacity: .06; text-align: center }
    .foot { margin-top: 16px; font-size: 10.5px; color: #777; display: flex; justify-content: space-between; gap: 8px; border-top: 1px solid #ddd; padding-top: 6px; flex-wrap: wrap }
    .note-top { text-align: center; font-size: 12px; margin-top: -6px; margin-bottom: 8px; color: #444 }
    .foot-text { text-align: center; margin-top: 12px; font-size: 12px; color: #333; white-space: pre-line }
    h3.sec { margin: 16px 0 6px; font-size: 14px; color: ${col} }
    .draft-stamp { color: #b45309; text-align: center } .cancel-stamp { color: #b91c1c; text-align: center }
    @media screen { body { padding: 16px; max-width: ${thermal ? '80mm' : paper === 'A5' ? '148mm' : landscape ? '297mm' : '210mm'}; margin: 0 auto; background: #fff } html { background: #eee } }`;
  const t = {
    classic: `
    .head { border-bottom: 3px solid ${col} } .head .co h1 { color: ${col} } .head .co div, .head .meta2 { color: #555 }
    table.pt th, table.pt td { border: 1px solid #bbb } table.pt th { background: ${col}1f } table.pt tfoot td { background: #f6f6f6 }
    table.pt tr.grp td { font-weight: 700; background: ${col}0f } table.pt tr.tot td { font-weight: 800; background: ${col}1a }
    .amount-box { border: 2px solid ${col} }`,
    modern: `
    .head { background: ${col}; color: #fff; border-radius: 12px; padding: 14px 16px } .head .co h1 { color: #fff } .head .co div, .head .meta2 { color: #fff; opacity: .9 }
    .head img { background: #fff; border-radius: 8px; padding: 4px }
    h2.title { color: ${col} }
    table.pt { border-radius: 10px; overflow: hidden } table.pt th { background: ${col}; color: #fff; border: 0 } table.pt td { border: 0; border-bottom: 1px solid #e5e5e5 }
    table.pt tbody tr:nth-child(even) td { background: #fafafa } table.pt tfoot td { background: ${col}14; font-weight: 700 }
    table.pt tr.grp td { font-weight: 700; background: ${col}0f } table.pt tr.tot td { font-weight: 800; background: ${col}22 }
    .amount-box { background: ${col}12; border-right: 5px solid ${col} }`,
    simple: `
    .head { border-bottom: 1.5px solid #000 } .head .co h1 { color: #000 } .head .co div, .head .meta2 { color: #222 }
    table.pt th, table.pt td { border-bottom: 1px solid #999 } table.pt th { border-bottom: 1.5px solid #000; font-weight: 800 }
    table.pt tr.tot td, table.pt tfoot td { font-weight: 800; border-top: 1.5px solid #000 }
    .amount-box { border: 1px solid #000 } .wm div { color: #000 }`,
  };
  const th = thermal ? `
    .head { flex-direction: column; text-align: center; gap: 4px; border-radius: 0 } .head .meta2 { display: none }
    .signs { margin-top: 28px } .signs div { width: auto; flex: 1; font-size: 10px }
    table.meta td { display: block; border: 0; padding: 1px 0 } .foot { font-size: 9px }` : '';
  return base + (t[cfg.template] || t.classic) + th;
}

// يفتح نافذة طباعة فيها ترويسة الشركة + المحتوى.
// html ممكن يكون نص أو دالة (cfg, {thermal}) => نص. kind بيحدد التواقيع وحجم الورق (invoice بياخذ ورق الفواتير).
// شريط فوق نافذة الطباعة (ما بيطلع بالورق): رجوع للبرنامج + طباعة.
// على الآيباد والتطبيق المثبّت النافذة بتفتح على كامل الشاشة وما في زر إغلاق.
// شريط نافذة الطباعة + «النموذج»: عادي / بدون ترويسة (ورق مطبوع) / بدون أسعار (سند تسليم) — بيتذكّر لكل نوع مستند
//  الأعمدة والجداول اللي فيها أسعار عليها كلاس pr، والعنوان اللي بيتغيّر بدون أسعار عليه data-np
export function printBarHTML(kind = '') {
  const app = location.origin + location.pathname, key = 'sumou.printvar.' + (kind || 'doc');
  return `<style>.sumou-bar{position:sticky;top:0;z-index:99;display:flex;gap:10px;justify-content:center;align-items:center;flex-wrap:wrap;padding:10px;background:#f3eefa;border-bottom:1px solid #ddd;margin:-10px -10px 12px}
    .sumou-bar button,.sumou-bar select{font:700 16px Tajawal,Tahoma,Arial;padding:10px 18px;border-radius:10px;border:1px solid #5b2a86;background:#fff;color:#5b2a86;cursor:pointer}
    .sumou-bar button.p{background:#5b2a86;color:#fff}@media print{.sumou-bar{display:none!important}}
    body.v-nohead .head,body.v-nohead .wm,body.v-nohead .note-top,body.v-nohead .bl-head,body.v-nohead .bl-bottom,body.v-nohead .foot-text{visibility:hidden}
    body.v-noprice .pr{display:none!important}</style>
  <div class="sumou-bar"><button type="button" onclick="(function(){window.close();setTimeout(function(){if(history.length>1)history.back();else location.href=${JSON.stringify(app).replace(/"/g, '&quot;')};},300)})()">→ رجوع للبرنامج</button>
  <select id="sumou-var" title="النموذج" onchange="(function(v){var b=document.body;b.classList.toggle('v-nohead',v==='nohead'||v==='both');b.classList.toggle('v-noprice',v==='noprice'||v==='both');
    document.querySelectorAll('[data-np]').forEach(function(t){if(!t.dataset.org)t.dataset.org=t.textContent;t.textContent=(v==='noprice'||v==='both')?t.dataset.np:t.dataset.org;});
    try{localStorage.setItem('${key}',v)}catch(e){}})(this.value)">
    <option value="">📄 نموذج عادي</option><option value="nohead">🧾 بدون ترويسة (ورق مطبوع)</option><option value="noprice">📦 بدون أسعار (سند تسليم)</option><option value="both">بدون ترويسة وبدون أسعار</option></select>
  <button type="button" class="p" onclick="window.print()">🖨️ طباعة</button></div>
  <script>document.addEventListener('DOMContentLoaded',function(){try{var v=localStorage.getItem('${key}')||'';if(v){var s=document.getElementById('sumou-var');s.value=v;s.onchange();}}catch(e){}});<\/script>`;
}

export function printDoc(title, html, { subtitle = '', landscape = false, kind = null, preview = null, cfg: given = null, branch = null, copies = 1, win = null, npTitle = '' } = {}) {
  const w = preview || win || window.open('', '_blank');
  if (!w) { alert('المتصفح منع نافذة الطباعة. اسمح بالنوافذ المنبثقة لهالموقع.'); return; }
  if (!preview) { w.document.write('<p dir="rtl" style="font-family:sans-serif;padding:20px">جاري تحضير الطباعة…</p>'); }
  Promise.all([given ? Promise.resolve(given) : loadPrintSettings(), Promise.resolve(branch).catch(() => null)]).then(([cfg, branchData]) => {
    // ترويسة الفرع: اسم الفرع وعنوانه وأرقامه الضريبية (الفاضي بياخذ تبع الشركة)
    const b = branchData || null;
    const c = b ? { ...(S.company || {}), branchName: b.name, address: b.address || S.company?.address, city: b.city || S.company?.city, phone: b.phone || S.company?.phone,
      income_tax_no: b.income_tax_no || S.company?.income_tax_no, sales_tax_no: b.sales_tax_no || S.company?.sales_tax_no } : (S.company || {});
    const paper = kind === 'invoice' ? cfg.invoice_paper : cfg.paper;
    const thermal = paper === '80mm';
    let body = typeof html === 'function' ? html(cfg, { thermal }) : html;
    if (body && typeof body === 'object' && body.bare) {   // نموذج كامل جاهز (مثل الفاتورة الثنائية): بدون ترويسة وتواقيع البرنامج
      const t0 = typeof title === 'function' ? title(cfg) : title;
      const d0 = `<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><title>${esc(t0)}</title>
  <link href="https://fonts.googleapis.com/css2?family=Tajawal:wght@400;700;800&display=swap" rel="stylesheet">
  <style>${css(cfg, { landscape, thermal, paper: paper === 'A5' ? 'A5' : 'A4' })}${body.css || ''}</style></head><body>
  ${preview ? '' : printBarHTML(kind)}${body.html}
  ${preview ? '' : '<script>window.onload = () => setTimeout(() => window.print(), 450);<\/script>'}</body></html>`;
      w.document.open(); w.document.write(d0); w.document.close(); translateDoc(w.document); return;
    }
    if (typeof title === 'function') title = title(cfg);
    const sigs = kind && cfg.sig[kind] ? String(cfg.sig[kind]).split(/[،,]/).map(x => x.trim()).filter(Boolean) : [];
    const fy = S.fy ? (S.fy.name || S.fy.code) : '';
    const doc = `<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><title>${esc(title)}</title>
  <link href="https://fonts.googleapis.com/css2?family=Tajawal:wght@400;700;800&display=swap" rel="stylesheet">
  <style>${css(cfg, { landscape, thermal, paper: paper === 'A5' ? 'A5' : 'A4' })}</style></head><body>
  ${preview ? '' : printBarHTML(kind)}
  ${Array.from({ length: Math.min(Math.max(+copies || 1, 1), 5) }, (_, ci, arr) => `${ci ? '<div style="page-break-before:always"></div>' : ''}${(+copies || 1) > 1 ? `<div style="text-align:left;font-size:11px;color:#666">نسخة ${ci + 1} من ${Math.min(+copies, 5)}</div>` : ''}
  ${cfg.watermark && !thermal ? `<div class="wm"><div>${esc(c.name || '')}<br>${esc(fy)}</div></div>` : ''}
  <div class="head">${c.logo_url ? `<img src="${esc(c.logo_url)}">` : ''}
    <div class="co"><h1>${esc(c.name || '')}</h1>${c.branchName ? `<div style="font-weight:700">${esc(c.branchName)}</div>` : ''}<div>${esc([c.address, c.city].filter(Boolean).join(' - '))}${c.phone ? ' | هاتف: ' + esc(c.phone) : ''}</div>
      ${cfg.show_tax_numbers && (c.income_tax_no || c.sales_tax_no) ? `<div>${c.income_tax_no ? 'الرقم الضريبي: ' + esc(c.income_tax_no) : ''}${c.income_tax_no && c.sales_tax_no ? ' | ' : ''}${c.sales_tax_no ? 'رقم ضريبة المبيعات: ' + esc(c.sales_tax_no) : ''}</div>` : ''}</div>
    <div class="meta2">${esc(fy)}</div></div>
  ${cfg.header_note ? `<div class="note-top">${esc(cfg.header_note)}</div>` : ''}
  <h2 class="title"${npTitle ? ` data-np="${esc(npTitle)}"` : ''}>${esc(title)}</h2>${subtitle ? `<div class="sub">${esc(subtitle)}</div>` : ''}
  ${body}
  ${sigs.length ? `<div class="signs">${sigs.map(x => `<div>${esc(x)}</div>`).join('')}</div>` : ''}
  ${cfg.footer_text ? `<div class="foot-text">${esc(cfg.footer_text)}</div>` : ''}
  <div class="foot">${cfg.show_printed_by ? `<span>طُبع بواسطة: ${esc(S.profile?.full_name || S.profile?.email || '')}</span>` : '<span></span>'}<span>${fmtDateTime(new Date())}</span></div>`).join('')}
  ${preview ? '' : '<script>window.onload = () => setTimeout(() => window.print(), 450);<\/script>'}</body></html>`;
    w.document.open(); w.document.write(doc); w.document.close(); translateDoc(w.document);
  }).catch(e => { w.document.body.innerHTML = '<p dir="rtl">ما قدرت أحضّر الطباعة: ' + esc(e.message) + '</p>'; });
}

// ---------------------------------------------------------------------
//  التفقيط: تحويل المبلغ لكلام (دينار أردني وفلس)
// ---------------------------------------------------------------------
const ONES = ['', 'واحد', 'اثنان', 'ثلاثة', 'أربعة', 'خمسة', 'ستة', 'سبعة', 'ثمانية', 'تسعة', 'عشرة',
  'أحد عشر', 'اثنا عشر', 'ثلاثة عشر', 'أربعة عشر', 'خمسة عشر', 'ستة عشر', 'سبعة عشر', 'ثمانية عشر', 'تسعة عشر'];
const TENS = ['', '', 'عشرون', 'ثلاثون', 'أربعون', 'خمسون', 'ستون', 'سبعون', 'ثمانون', 'تسعون'];
const HUNDS = ['', 'مائة', 'مائتان', 'ثلاثمائة', 'أربعمائة', 'خمسمائة', 'ستمائة', 'سبعمائة', 'ثمانمائة', 'تسعمائة'];

function under1000(n) {
  const h = Math.floor(n / 100), r = n % 100, parts = [];
  if (h) parts.push(HUNDS[h]);
  if (r) parts.push(r < 20 ? ONES[r] : (r % 10 ? ONES[r % 10] + ' و' + TENS[Math.floor(r / 10)] : TENS[Math.floor(r / 10)]));
  return parts.join(' و');
}

function scale(n, one, two, plural) {
  if (n === 1) return one;
  if (n === 2) return two;
  if (n >= 3 && n <= 10) return under1000(n) + ' ' + plural;
  return under1000(n) + ' ' + one;
}

export function intToWords(n) {
  n = Math.floor(Math.abs(n));
  if (n === 0) return 'صفر';
  const b = Math.floor(n / 1e9), m = Math.floor(n / 1e6) % 1000, t = Math.floor(n / 1e3) % 1000, r = n % 1000, parts = [];
  if (b) parts.push(scale(b, 'مليار', 'ملياران', 'مليارات'));
  if (m) parts.push(scale(m, 'مليون', 'مليونان', 'ملايين'));
  if (t) parts.push(scale(t, 'ألف', 'ألفان', 'آلاف'));
  if (r) parts.push(under1000(r));
  return parts.join(' و');
}

// التفقيط بالإنجليزي (لما لغة الواجهة إنجليزي)
function enWords(n) {
  const O = ['', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen'];
  const T = ['', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety'];
  const h = (x) => { const a = Math.floor(x / 100), r = x % 100; const t = r < 20 ? O[r] : T[Math.floor(r / 10)] + (r % 10 ? '-' + O[r % 10] : '');
    return [a ? O[a] + ' hundred' : '', t].filter(Boolean).join(' and '); };
  if (!n) return 'zero';
  const S2 = ['', ' thousand', ' million', ' billion']; const out = []; let i = 0;
  while (n > 0 && i < S2.length) { const c = n % 1000; if (c) out.unshift(h(c) + S2[i]); n = Math.floor(n / 1000); i++; }
  return out.join(' ');
}
export function amountToWords(amount) {
  if (LANG === 'en') { const a = Math.round(Math.abs(Number(amount) || 0) * 1000), jd = Math.floor(a / 1000), fils = a % 1000;
    const w = [jd ? enWords(jd) + (jd === 1 ? ' Jordanian dinar' : ' Jordanian dinars') : '', fils ? enWords(fils) + ' fils' : ''].filter(Boolean).join(' and ');
    return 'Only ' + (w || 'zero dinars') + ' (no more)'; }
  const a = Math.round(Math.abs(Number(amount) || 0) * 1000);
  const jd = Math.floor(a / 1000), fils = a % 1000;
  const jdW = jd ? (jd === 1 ? 'دينار واحد' : jd === 2 ? 'ديناران' : intToWords(jd) + (jd % 100 >= 3 && jd % 100 <= 10 ? ' دنانير' : ' دينار')) : '';
  const fW = fils ? intToWords(fils) + ' فلس' : '';
  return 'فقط ' + [jdW, fW].filter(Boolean).join(' و') + ' لا غير';
}
