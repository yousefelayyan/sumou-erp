// =====================================================================
//  السمو ERP — لغة الواجهة (عربي / English)
//  الواجهة مكتوبة بالعربي، وبالإنجليزي بنترجم النصوص من القاموس docs/i18n/en.js وقت العرض:
//  MutationObserver بيمر على أي نص أو placeholder/title جديد. بيانات المستخدم (أسماء، أصناف…) ما بتتغيّر
//  لأنها مش بالقاموس. القاموس بيتولّد من dev/i18n/ar.txt + en.txt (dev/i18n_extract.py ثم dev/i18n_build.py).
// =====================================================================
const KEY = 'sumou.lang';
export let LANG = (() => { try { return localStorage.getItem(KEY) === 'en' ? 'en' : 'ar'; } catch { return 'ar'; } })();
let DICT = null, NUMD = null;
const MISS = (() => { try { return localStorage.getItem('sumou.i18n.debug') ? (window.__i18nMissing = new Set()) : null; } catch { return null; } })();   // للفحص: النصوص اللي ما إلها ترجمة
const AR = /[؀-ۿ]/;
const EDGE = /^[\s:•·—–\-*()،.؟?!«»"'/|,;؛✓✔⚠️…]+|[\s:•·—–\-*()،.؟?!«»"'/|,;؛✓✔⚠️…]+$/g;
const PHRASE = /[؀-ۿ«][؀-ۿ\s«»ـ]*[؀-ۿ»]|[؀-ۿ]/g;
const NUM = /[\d٠-٩]+(?:[.,:\/-][\d٠-٩]+)*/g;

function lookup(t) {
  const k = t.replace(/\s+/g, ' ').replace(EDGE, '');
  if (!k) return null;
  const v = DICT[k]; if (v == null) return null;
  return t.replace(k, v);   // بنحافظ على الترقيم حوالين النص
}
export function tr(text) {
  if (LANG !== 'en' || !DICT || !text || !AR.test(text)) return text;
  const whole = lookup(text.trim()); if (whole != null) return text.replace(text.trim(), whole);
  // نص فيه أرقام: «باقي 12 يوم» ← «باقي # يوم»
  const nums = []; const pat = text.trim().replace(NUM, (m) => { nums.push(m); return '#'; });
  if (nums.length && NUMD[pat] != null) { let k = 0; return NUMD[pat].replace(/#/g, () => nums[k++] ?? ''); }
  if (nums.length === 1) {   // «9 شاشة» / «باقي 12»: الرقم بالأول أو بالآخر والباقي نص معروف
    const m = pat.match(/^#\s*(.+)$/) || pat.match(/^(.+?)\s*#$/);
    const x = m && lookup(m[1]); if (x != null) return pat.startsWith('#') ? `${nums[0]} ${x}` : `${x} ${nums[0]}`;
  }
  // كل جملة عربية لحالها — بس الجمل اللي فيها أكثر من كلمة (الكلمة الوحدة ممكن تكون من بيانات المستخدم)
  return text.replace(PHRASE, (p) => { if (!/\s/.test(p.trim())) return p; const x = lookup(p); if (x == null && MISS) MISS.add(p.trim()); return x == null ? p : x; });
}
const ATTRS = ['placeholder', 'title', 'aria-label'];
function walk(root) {
  if (!root) return;
  if (root.nodeType === 3) { if (AR.test(root.nodeValue)) { const v = tr(root.nodeValue); if (v !== root.nodeValue) root.nodeValue = v; } return; }
  if (root.nodeType !== 1 && root.nodeType !== 11) return;
  if (root.nodeType === 1) {
    if (root.closest?.('[data-noi18n], [contenteditable="true"], textarea, script, style')) return;
    for (const a of ATTRS) { const v = root.getAttribute?.(a); if (v && AR.test(v)) { const t2 = tr(v); if (t2 !== v) root.setAttribute(a, t2); } }
  }
  const tw = (root.ownerDocument || root).createTreeWalker(root, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, {
    acceptNode: (n) => n.nodeType === 1 && (n.matches('[data-noi18n], [contenteditable="true"], textarea, script, style')) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT });
  let n; while ((n = tw.nextNode())) {
    if (n.nodeType === 3) { if (AR.test(n.nodeValue)) { const v = tr(n.nodeValue); if (v !== n.nodeValue) n.nodeValue = v; } }
    else for (const a of ATTRS) { const v = n.getAttribute(a); if (v && AR.test(v)) { const t2 = tr(v); if (t2 !== v) n.setAttribute(a, t2); } }
  }
}
export async function initLang() {
  document.documentElement.lang = LANG; document.documentElement.dir = LANG === 'en' ? 'ltr' : 'rtl';
  document.documentElement.classList.toggle('lang-en', LANG === 'en');
  if (LANG !== 'en') return;
  DICT = (await import('./i18n/en.js')).default;
  NUMD = {};
  for (const [k, v] of Object.entries(DICT)) { if (NUM.test(k)) { NUM.lastIndex = 0; NUMD[k.replace(NUM, '#')] = v.replace(NUM, '#'); } NUM.lastIndex = 0; }
  walk(document.body);
  new MutationObserver((ms) => {
    for (const m of ms) {
      if (m.type === 'characterData') walk(m.target);
      else if (m.type === 'attributes') walk(m.target);
      else m.addedNodes.forEach(walk);
    }
  }).observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ATTRS });
  const tt = document.title; if (AR.test(tt)) document.title = tr(tt);
}
// نافذة الطباعة (وثيقة ثانية)
export function translateDoc(doc) {
  if (LANG !== 'en' || !DICT || !doc) return;
  doc.documentElement.dir = 'ltr'; doc.documentElement.lang = 'en';
  walk(doc.body); if (AR.test(doc.title)) doc.title = tr(doc.title);
}
export function setLang(l) { try { localStorage.setItem(KEY, l === 'en' ? 'en' : 'ar'); } catch { } }
