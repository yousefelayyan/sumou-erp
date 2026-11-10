// =====================================================================
//  السمو ERP — الطباعة والتفقيط
// =====================================================================
import { S, esc, fmtDateTime } from './core.js';

// يفتح نافذة طباعة فيها ترويسة الشركة + المحتوى
export function printDoc(title, html, { subtitle = '', landscape = false } = {}) {
  const c = S.company || {};
  const w = window.open('', '_blank');
  if (!w) { alert('المتصفح منع نافذة الطباعة. اسمح بالنوافذ المنبثقة لهالموقع.'); return; }
  w.document.write(`<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><title>${esc(title)}</title>
  <link href="https://fonts.googleapis.com/css2?family=Tajawal:wght@400;700;800&display=swap" rel="stylesheet">
  <style>
    @page { size: A4 ${landscape ? 'landscape' : 'portrait'}; margin: 12mm; }
    body { font-family: 'Tajawal', sans-serif; color: #111; font-size: 12.5px; margin: 0; }
    .head { display: flex; align-items: center; gap: 14px; border-bottom: 3px solid #5b2a86; padding-bottom: 10px; margin-bottom: 12px; }
    .head img { max-height: 64px; max-width: 120px; }
    .head .co { flex: 1 } .head .co h1 { margin: 0; font-size: 19px; color: #5b2a86 } .head .co div { color: #555; font-size: 12px }
    .head .meta2 { text-align: left; font-size: 11px; color: #555 }
    h2.title { text-align: center; margin: 6px 0 2px; font-size: 18px } .sub { text-align: center; color: #555; margin-bottom: 12px }
    table { width: 100%; border-collapse: collapse }
    table.pt th, table.pt td { border: 1px solid #bbb; padding: 5px 7px; text-align: right }
    table.pt th { background: #efe7f7 } table.pt tfoot td { background: #f6f6f6 }
    table.pt tr.grp td { font-weight: 700; background: #f6f2fa } table.pt tr.tot td { font-weight: 800; background: #ece4f5 }
    .n { text-align: left !important; direction: ltr; white-space: nowrap; font-variant-numeric: tabular-nums }
    table.meta td { padding: 5px 4px; border-bottom: 1px dashed #ccc }
    .amount-box { border: 2px solid #5b2a86; border-radius: 8px; padding: 10px 14px; margin: 12px 0; font-size: 15px }
    .amount-box span { font-size: 13px; color: #333 }
    .signs { display: flex; justify-content: space-around; margin-top: 50px } .signs div { border-top: 1px solid #333; padding-top: 6px; width: 160px; text-align: center }
    .wm { position: fixed; inset: 0; display: flex; align-items: center; justify-content: center; pointer-events: none; z-index: -1 }
    .wm div { transform: rotate(-24deg); font-size: 64px; font-weight: 800; color: #5b2a86; opacity: .06; text-align: center }
    .foot { margin-top: 16px; font-size: 10.5px; color: #777; display: flex; justify-content: space-between; border-top: 1px solid #ddd; padding-top: 6px }
    h3.sec { margin: 16px 0 6px; font-size: 14px; color: #5b2a86 }
  </style></head><body>
  <div class="wm"><div>${esc(c.name || '')}<br>${esc(S.fy ? (S.fy.name || S.fy.code) : '')}</div></div>
  <div class="head">${c.logo_url ? `<img src="${esc(c.logo_url)}">` : ''}
    <div class="co"><h1>${esc(c.name || '')}</h1><div>${esc([c.address, c.city].filter(Boolean).join(' - '))} ${c.phone ? ' | هاتف: ' + esc(c.phone) : ''}</div>
      <div>${c.income_tax_no ? 'الرقم الضريبي: ' + esc(c.income_tax_no) : ''} ${c.sales_tax_no ? ' | رقم ضريبة المبيعات: ' + esc(c.sales_tax_no) : ''}</div></div>
    <div class="meta2">${esc(S.fy ? (S.fy.name || S.fy.code) : '')}</div></div>
  <h2 class="title">${esc(title)}</h2>${subtitle ? `<div class="sub">${esc(subtitle)}</div>` : ''}
  ${html}
  <div class="foot"><span>طُبع بواسطة: ${esc(S.profile?.full_name || S.profile?.email || '')}</span><span>${fmtDateTime(new Date())}</span><span>السمو ERP</span></div>
  <script>window.onload = () => setTimeout(() => window.print(), 400);<\/script></body></html>`);
  w.document.close();
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

export function amountToWords(amount) {
  const a = Math.round(Math.abs(Number(amount) || 0) * 1000);
  const jd = Math.floor(a / 1000), fils = a % 1000;
  const jdW = jd ? (jd === 1 ? 'دينار واحد' : jd === 2 ? 'ديناران' : intToWords(jd) + (jd % 100 >= 3 && jd % 100 <= 10 ? ' دنانير' : ' دينار')) : '';
  const fW = fils ? intToWords(fils) + ' فلس' : '';
  return 'فقط ' + [jdW, fW].filter(Boolean).join(' و') + ' لا غير';
}
