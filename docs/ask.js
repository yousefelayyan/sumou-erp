// =====================================================================
//  السمو ERP — «اسأل السمو»: تقارير المبيعات بسؤال عادي
//  مثال: «اعطيني مبيعات شهر 7 تجميعي حسب العميل»، «أعلى 10 أصناف هذا الشهر»،
//        «مبيعات شهر 6 حسب الفئة والعميل للمندوب عقاب»، «قارن مبيعات المندوبين هذا الشهر بالشهر الماضي»
//  التحليل بالواجهة (قواعد بسيطة)، والأرقام من الدالة ask_sales.
// =====================================================================
import { S, sb, esc, fmtNum, fmtDate, num, today, toast, arError, can } from './core.js';
import { loadParties } from './parties.js';
import { loadItems } from './invoices.js';
import { loadLookups } from './lookups.js';
import { downloadCSV } from './finance.js';
import { printDoc } from './print.js';

const MONTHS = [['كانون الثاني', 'يناير'], ['شباط', 'فبراير'], ['آذار', 'مارس'], ['نيسان', 'أبريل', 'ابريل'], ['أيار', 'مايو'], ['حزيران', 'يونيو'], ['تموز', 'يوليو'], ['آب', 'أغسطس', 'اغسطس'], ['أيلول', 'سبتمبر'], ['تشرين الأول', 'أكتوبر', 'اكتوبر'], ['تشرين الثاني', 'نوفمبر'], ['كانون الأول', 'ديسمبر']];
const GL = { customer: 'الزبون', item: 'الصنف', item_category: 'فئة الصنف', customer_category: 'فئة الزبون', rep: 'المندوب', department: 'الدائرة', warehouse: 'المستودع', month: 'الشهر', day: 'اليوم', none: '' };
const SUGGEST = ['شو مبيعاتي هذا الأسبوع؟', 'أعلى 10 أصناف هذا الشهر', 'قارن مبيعات المندوبين هذا الشهر بالشهر الماضي', 'مبيعات فئات الأصناف هذا الشهر', 'مبيعات هذه السنة شهري'];
const W = (x) => new RegExp(`(?<![\u0600-\u06FF])(?:${x})(?![\u0600-\u06FF])`);
const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const norm = (t) => String(t || '').replace(/[أإآ]/g, 'ا').replace(/ة/g, 'ه').replace(/ى/g, 'ي').replace(/[ً-ْ]/g, '').replace(/[٠-٩]/g, d => '٠١٢٣٤٥٦٧٨٩'.indexOf(d)).toLowerCase();

// تحليل السؤال → { from, to, label, groups[], top, filters{}, names[] (أسماء لازم تتطابق), compare }
export function parseQuestion(q) {
  const t = norm(q), now = new Date(today());
  const fyY = S.fy ? new Date(S.fy.start_date).getFullYear() : now.getFullYear();
  let from, to, label;
  const m1 = t.match(/شهر\s*(\d{1,2})(?!\d)(?:\s*(?:\/|لسنه|سنه|-)?\s*(\d{4}))?/);
  const yM = t.match(/(?:سنه|عام)\s*(\d{4})/);
  const monthName = MONTHS.findIndex(ns => ns.some(n => W(norm(n)).test(t)));
  const range = t.match(/من\s*(\d{4}-\d{2}-\d{2})\s*(?:الي|حتي|ل)\s*(\d{4}-\d{2}-\d{2})/);
  if (range) { from = range[1]; to = range[2]; label = `من ${fmtDate(from)} إلى ${fmtDate(to)}`; }
  else if ((m1 && +m1[1] >= 1 && +m1[1] <= 12) || (!m1 && monthName >= 0)) {
    const mo = m1 ? +m1[1] - 1 : monthName, y = m1?.[2] ? +m1[2] : yM ? +yM[1] : fyY;
    from = iso(new Date(y, mo, 1)); to = iso(new Date(y, mo + 1, 0)); label = `شهر ${mo + 1} لسنة ${y}`;
  } else if (/الشهر الماضي|الشهر السابق/.test(t)) { from = iso(new Date(now.getFullYear(), now.getMonth() - 1, 1)); to = iso(new Date(now.getFullYear(), now.getMonth(), 0)); label = 'الشهر الماضي'; }
  else if (/هذا الشهر|هالشهر|الشهر الحالي/.test(t)) { from = iso(new Date(now.getFullYear(), now.getMonth(), 1)); to = today(); label = 'هذا الشهر'; }
  else if (/الاسبوع الماضي/.test(t)) { const d = new Date(now); d.setDate(d.getDate() - d.getDay() - 7); from = iso(d); d.setDate(d.getDate() + 6); to = iso(d); label = 'الأسبوع الماضي'; }
  else if (/اسبوع/.test(t)) { const d = new Date(now); d.setDate(d.getDate() - d.getDay()); from = iso(d); to = today(); label = 'هذا الأسبوع'; }
  else if (W('امس|مبارح').test(t)) { const d = new Date(now); d.setDate(d.getDate() - 1); from = to = iso(d); label = 'أمس'; }
  else if (W('اليوم').test(t) && !/حسب اليوم|يومي/.test(t)) { from = to = today(); label = 'اليوم'; }
  else if (yM) { from = `${yM[1]}-01-01`; to = `${yM[1]}-12-31`; label = `سنة ${yM[1]}`; }
  else if (S.fy) { from = S.fy.start_date; to = S.fy.end_date; label = `السنة المالية ${S.fy.name || S.fy.code || ''}`; }
  else { from = `${now.getFullYear()}-01-01`; to = today(); label = 'هذه السنة'; }

  // التجميع: بالترتيب اللي انذكر فيه
  const G = [
    ['customer_category', /فئه (?:ال)?(?:زبون|زباين|عميل|عملاء)|فئات (?:ال)?(?:زبائن|عملاء)/],
    ['item_category', /فئه (?:ال)?(?:صنف|اصناف|ماده|مواد)|فئات (?:ال)?(?:اصناف|مواد)|(?:حسب|و) ?(?:ال)?فئ(?:ه|ات)(?! (?:ال)?(?:زبون|عميل|زبائن|عملاء))|بالفئه/],
    ['customer', /(?:حسب|و|بال) ?(?:ال)?(?:عميل|عملاء|زبون|زباين|زبائن)|العملاء|الزبائن|(?<![\u0600-\u06FF])(?:زبائن|زباين|عملاء)(?![\u0600-\u06FF])/],
    ['item', /(?:حسب|و|بال) ?(?:ال)?(?:صنف|اصناف|ماده|مواد)|اصناف|المواد/],
    ['rep', /المندوبين|(?:حسب|و|بال) ?(?:ال)?مندوب(?!\s+[^\s]+\s*$)|حسب المندوب/],
    ['department', /(?:حسب|و|بال) ?(?:ال)?(?:دائره|دوائر|فرع|فروع)/],
    ['warehouse', /(?:حسب|و|بال) ?(?:ال)?(?:مستودع|مستودعات)/],
    ['day', /يومي|حسب اليوم|حسب الايام/],
    ['month', /شهري|حسب الشهر|حسب الاشهر|حسب الشهور/],
  ];
  const found = [];
  for (const [g, re] of G) { const m = t.match(re); if (m && !found.some(f => f.g === g)) found.push({ g, at: m.index }); }
  // «فئه» لحالها بعد «حسب» = فئة الصنف؛ ما نكرر customer إذا customer_category موجودة
  let groups = found.sort((a, b) => a.at - b.at).map(f => f.g);
  if (groups.includes('customer_category')) groups = groups.filter(g => g !== 'customer' || /(?:حسب|و) ?(?:ال)?(?:عميل|زبون)/.test(t.replace(/فئه (?:ال)?(?:زبون|عميل)/g, '')));
  if (groups.includes('item_category')) groups = groups.filter(g => g !== 'item' || /(?:حسب|و) ?(?:ال)?(?:صنف|ماده)/.test(t.replace(/فئه (?:ال)?(?:صنف|ماده)/g, '')));
  const topM = t.match(/اعلي\s*(\d+)|اكثر\s*(\d+)|افضل\s*(\d+)/);
  const top = topM ? +(topM[1] || topM[2] || topM[3]) : null;
  if (!groups.length) groups = top ? ['item'] : ['none'];

  // الفلاتر بالاسم: «للمندوب X»، «للعميل X»، «للصنف X»، «لفئه X»
  const names = [];
  const grab = (re, kind) => { const m = t.match(re); if (m) names.push({ kind, text: m[1].trim() }); };
  grab(/(?:لل|ل)?مندوب\s+([^\s،,؟?]+(?:\s+[^\s،,؟?]+)?)\s*$/, 'rep');
  grab(/(?:للعميل|للزبون|العميل|الزبون)\s+([^\s،,؟?]+(?:\s+[^\s،,؟?]+)?)\s*$/, 'party');
  grab(/(?:للصنف|للماده)\s+([^،,؟?]+)$/, 'item');
  if (names.some(n => n.kind === 'rep')) groups = groups.filter(g => g !== 'rep').length ? groups.filter(g => g !== 'rep') : ['none'];
  const compare = /قارن|مقارنه/.test(t) && /الشهر الماضي|الشهر السابق/.test(t);
  if (compare) { from = iso(new Date(now.getFullYear(), now.getMonth(), 1)); to = today(); label = 'هذا الشهر مقارنة بالشهر الماضي'; if (groups[0] === 'none') groups = ['rep']; }
  return { from, to, label, groups: groups.slice(0, 2), top, names, compare };
}

async function resolveNames(names, el) {
  const filters = {}, problems = [];
  if (!names.length) return { filters };
  const [parties, items, lks] = await Promise.all([loadParties(), loadItems(), loadLookups()]);
  for (const n of names) {
    const pool = n.kind === 'rep' ? lks.filter(l => l.kind === 'sales_rep') : n.kind === 'party' ? parties.filter(p => p.party_type === 'customer') : items;
    const key = norm(n.text);
    const hits = pool.filter(x => norm(x.name).includes(key) || norm(x.code) === key);
    const exact = hits.filter(x => norm(x.name) === key);
    const pick = exact.length === 1 ? exact : hits;
    if (pick.length === 1) filters[n.kind === 'rep' ? 'rep_id' : n.kind === 'party' ? 'party_id' : 'item_id'] = pick[0].id;
    else problems.push({ ...n, hits });
  }
  return { filters, problems };
}

async function viewAsk(v) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const hist = (await sb.from('ask_history').select('id,question,created_at').eq('company_id', S.company.id).order('created_at', { ascending: false }).limit(40)).data || [];
  v.innerHTML = `<style>.askw{display:grid;grid-template-columns:1fr 260px;gap:12px}.askq{display:flex;gap:8px}.askq textarea{flex:1;min-height:56px;font-size:16px}
    .asks{display:flex;gap:8px;flex-wrap:wrap;margin:8px 0}.asks a{cursor:pointer;color:var(--brand);text-decoration:underline;font-size:13px}
    .askh{max-height:520px;overflow:auto;font-size:13px}.askh div{padding:5px 6px;border-bottom:1px solid var(--line,#eee);cursor:pointer}.askh div:hover{background:var(--tint)}
    .askund{background:var(--tint);border-radius:8px;padding:6px 10px;font-size:13px;margin:8px 0}.asksum{font-size:15px;line-height:1.8;margin:6px 0 10px}
    @media(max-width:900px){.askw{grid-template-columns:1fr}}</style>
    <div class="page-head"><h2>💬 اسأل السمو — المبيعات</h2></div>
    <div class="askw"><div>
      <div class="askq"><textarea id="q" placeholder="اكتب سؤالك… مثلاً: اعطيني مبيعات شهر 7 تجميعي حسب العميل"></textarea><button class="btn primary" id="go" style="min-width:90px">اسأل</button></div>
      <div class="asks">${SUGGEST.map(x => `<a data-s="${esc(x)}">${esc(x)}</a>`).join('')}</div>
      <div id="out"><div class="muted">بتقدر تسأل عن: فترة (شهر 7، هذا الشهر، الشهر الماضي، هذا الأسبوع، سنة 2026، من 2026-01-01 إلى 2026-03-31)، والتجميع (حسب العميل، الصنف، الفئة، فئة العميل، المندوب، الدائرة، المستودع، يومي، شهري)، وأعلى 10، و«للمندوب فلان» أو «للعميل فلان».</div></div>
    </div><div class="card" style="padding:8px"><b>أسئلتي السابقة</b><div class="askh" id="hist">${hist.map(h => `<div data-h="${esc(h.question)}" title="${fmtDate(h.created_at)}">${esc(h.question)}</div>`).join('') || '<div class="muted">ما في</div>'}</div></div></div>`;
  const q = v.querySelector('#q'), out = v.querySelector('#out');
  const run = async (question, forced = {}) => {
    question = (question || '').trim(); if (!question) return;
    q.value = question;
    const P = parseQuestion(question);
    out.innerHTML = '<div class="muted">… جاري التحضير</div>';
    const { filters, problems = [] } = await resolveNames(P.names);
    Object.assign(filters, forced);
    const und = `<div class="askund">فهمت سؤالك هيك: <b>الفترة:</b> ${fmtDate(P.from)} - ${fmtDate(P.to)} &nbsp;|&nbsp; <b>تجميع حسب:</b> ${P.groups.map(g => GL[g]).filter(Boolean).join('، ') || 'الإجمالي'}${P.top ? ` &nbsp;|&nbsp; <b>أعلى:</b> ${P.top}` : ''}${P.names.length ? ` &nbsp;|&nbsp; ${P.names.map(n => `<b>${n.kind === 'rep' ? 'المندوب' : n.kind === 'party' ? 'الزبون' : 'الصنف'}:</b> ${esc(n.text)}`).join(' ')}` : ''}</div>`;
    const unresolved = problems.filter(p => !forced[p.kind === 'rep' ? 'rep_id' : p.kind === 'party' ? 'party_id' : 'item_id']);
    if (unresolved.length) {
      const p = unresolved[0];
      out.innerHTML = und + (p.hits.length ? `<p>في أكثر من ${p.kind === 'rep' ? 'مندوب' : p.kind === 'party' ? 'زبون' : 'صنف'} اسمه بيحتوي على «${esc(p.text)}». اختار المقصود:</p>
        <div style="display:flex;gap:6px;flex-wrap:wrap">${p.hits.slice(0, 30).map(h => `<button class="btn sm" data-pick="${h.id}">${esc(h.code || '')} — ${esc(h.name)}</button>`).join('')}</div>`
        : `<div class="notice">ما لقيت ${p.kind === 'rep' ? 'مندوب' : p.kind === 'party' ? 'زبون' : 'صنف'} اسمه «${esc(p.text)}».</div>`);
      out.querySelectorAll('[data-pick]').forEach(b => b.onclick = () => run(question, { ...forced, [p.kind === 'rep' ? 'rep_id' : p.kind === 'party' ? 'party_id' : 'item_id']: b.dataset.pick }));
      return;
    }
    const call = (from, to) => sb.rpc('ask_sales', { p_company: S.company.id, p_from: from, p_to: to, p_group: P.groups[0], p_filters: filters, p_top: P.top, p_group2: P.groups[1] || null });
    const { data, error } = await call(P.from, P.to);
    if (error) return void (out.innerHTML = und + `<div class="notice">${esc(arError(error))}</div>`);
    let prev = null;
    if (P.compare) { const d = new Date(P.from); const pf = iso(new Date(d.getFullYear(), d.getMonth() - 1, 1)), pt = iso(new Date(d.getFullYear(), d.getMonth(), 0)); prev = (await call(pf, pt)).data || []; }
    sb.from('ask_history').insert({ company_id: S.company.id, question }).then(() => {});
    const T = data.reduce((s, r) => ({ q: s.q + num(r.qty), n: s.n + num(r.net), t: s.t + num(r.tax), c: s.c + num(r.invoices) }), { q: 0, n: 0, t: 0, c: 0 });
    const two = P.groups.length > 1, pv = prev ? Object.fromEntries(prev.map(r => [r.k1 + '|' + r.k2, num(r.net)])) : null;
    const top3 = [...data].sort((a, b) => num(b.net) - num(a.net)).slice(0, 3).map(r => `${esc(r.label1)}${two ? ' / ' + esc(r.label2) : ''} (${fmtNum(r.net)})`).join('، ');
    const sum = `إجمالي مبيعات ${esc(P.label)}: الكمية <b>${fmtNum(T.q)}</b> والصافي <b>${fmtNum(T.n)}</b> دينار${P.groups[0] !== 'none' ? ` موزّعة على <b>${data.length}</b> ${GL[P.groups[0]]}` : ''}${data.length > 1 && P.groups[0] !== 'none' ? `. الأعلى: ${top3}` : ''}.`
      + (pv ? ` الشهر الماضي: <b>${fmtNum(prev.reduce((s, r) => s + num(r.net), 0))}</b>.` : '');
    const head = [GL[P.groups[0]] || 'البيان', ...(two ? [GL[P.groups[1]]] : []), 'الكمية', 'الصافي', 'الضريبة', 'عدد الفواتير', ...(pv ? ['الشهر الماضي', 'الفرق'] : [])];
    const body = data.map((r, i) => [r.label1, ...(two ? [r.label2] : []), num(r.qty), num(r.net), num(r.tax), r.invoices, ...(pv ? [pv[r.k1 + '|' + r.k2] || 0, num(r.net) - (pv[r.k1 + '|' + r.k2] || 0)] : [])]);
    const table = `<table class="t pt rep" id="ans"><thead><tr><th>#</th>${head.map(h => `<th>${esc(h)}</th>`).join('')}</tr></thead><tbody>
      ${body.map((r, i) => `<tr><td>${i + 1}</td>${r.map((c, j) => `<td class="${typeof c === 'number' ? 'n' : ''}">${typeof c === 'number' ? (head[j] === 'عدد الفواتير' ? c : fmtNum(c)) : esc(c)}</td>`).join('')}</tr>`).join('') || `<tr><td colspan="${head.length + 1}" class="empty">ما في مبيعات مرحّلة بهالفترة</td></tr>`}</tbody>
      <tfoot><tr class="tot"><td></td><td colspan="${two ? 2 : 1}">الإجمالي</td><td class="n">${fmtNum(T.q)}</td><td class="n">${fmtNum(T.n)}</td><td class="n">${fmtNum(T.t)}</td><td></td>${pv ? `<td class="n">${fmtNum(prev.reduce((s, r) => s + num(r.net), 0))}</td><td></td>` : ''}</tr></tfoot></table>`;
    out.innerHTML = und + `<div class="asksum">${sum}</div><div style="display:flex;gap:8px;margin-bottom:6px"><button class="btn sm" id="xls">⬇️ Excel</button><button class="btn sm" id="prn">🖨️ طباعة</button></div><div class="card table-wrap">${table}</div>`;
    out.querySelector('#xls').onclick = () => downloadCSV('اسأل-السمو.csv', [head, ...body]);
    out.querySelector('#prn').onclick = () => printDoc(question, `<p>${sum}</p>` + table, { subtitle: `${fmtDate(P.from)} - ${fmtDate(P.to)}` });
    const h = v.querySelector('#hist'); h.querySelector('.muted')?.remove(); if (!h.querySelector(`[data-h="${CSS.escape(question)}"]`)) h.insertAdjacentHTML('afterbegin', `<div data-h="${esc(question)}">${esc(question)}</div>`);
  };
  v.querySelector('#go').onclick = () => run(q.value);
  q.addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); run(q.value); } });
  v.querySelectorAll('[data-s]').forEach(a => a.onclick = () => run(a.dataset.s));
  v.querySelector('#hist').onclick = (e) => { const d = e.target.closest('[data-h]'); if (d) run(d.dataset.h); };
}

export const ASK_ROUTES = { 'ask': (v) => (can('sales_invoices', 'view') || can('reports', 'view')) ? viewAsk(v) : void (v.innerHTML = '<div class="notice">ما عندك صلاحية تقارير المبيعات</div>') };
