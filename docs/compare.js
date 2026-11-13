// =====================================================================
//  السمو ERP — مقارنة الفترات بنسبة النمو (route compare?t=pl|sales)
//  قائمة الدخل: rep_trial_balance لفترتين (كل فترة على سنتها المالية). المبيعات: ask_sales لفترتين بنفس التجميع.
//  الفترة المقارنة: السابقة بنفس الطول / نفس الفترة من السنة الماضية / يدوي. ما في SQL جديد.
// =====================================================================
import { S, sb, esc, fmtNum, fmtDate, num, toast, arError, can, today } from './core.js';
import { loadAccounts } from './finance.js';
import { printDoc } from './print.js';

const qp = () => new URLSearchParams(location.hash.split('?')[1] || '');
const iso = (d) => d.toISOString().slice(0, 10);
const addDays = (s, n) => { const d = new Date(s + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return iso(d); };
const addYears = (s, n) => { const d = new Date(s + 'T00:00:00Z'); d.setUTCFullYear(d.getUTCFullYear() + n); return iso(d); };
const pct = (a, b) => num(b) === 0 ? (num(a) === 0 ? '' : '—') : num(a) === num(b) ? '0%' : `${(num(a) - num(b)) / Math.abs(num(b)) * 100 >= 0 ? '▲' : '▼'} ${Math.abs(Math.round((num(a) - num(b)) / Math.abs(num(b)) * 1000) / 10)}%`;
const pctColor = (a, b, goodUp = true) => { const d = num(a) - num(b); if (!d || !num(b)) return ''; return (d > 0) === goodUp ? 'color:var(--ok)' : 'color:var(--bad)'; };
const fyFor = (d) => (S.fiscalYearsAll || S.fiscalYears || []).find(y => y.start_date <= d && y.end_date >= d);

function compRange(from, to, mode, cf, ct) {
  if (mode === 'custom') return [cf, ct];
  if (mode === 'prev') { const len = Math.round((new Date(to) - new Date(from)) / 864e5) + 1; return [addDays(from, -len), addDays(from, -1)]; }
  return [addYears(from, -1), addYears(to, -1)];
}

async function plData(from, to) {
  const fy = fyFor(from);
  if (!fy) return null;
  const { data, error } = await sb.rpc('rep_trial_balance', { p_company: S.company.id, p_fy: fy.id, p_from: from, p_to: to, p_depts: null, p_exclude: null });
  if (error) throw error;
  return Object.fromEntries((data || []).map(r => [r.account_id, num(r.period_debit) - num(r.period_credit)]));
}

async function viewCompare(v) {
  if (!S.company || !S.fy) return void (v.innerHTML = '<div class="notice info">اختار شركة وسنة مالية من فوق أول.</div>');
  const t = qp().get('t') || 'pl';
  const td = today() <= S.fy.end_date ? today() : S.fy.end_date;
  const from = qp().get('from') || td.slice(0, 8) + '01', to = qp().get('to') || td;
  const mode = qp().get('m') || 'year';
  const [cf, ct] = compRange(from, to, mode, qp().get('cf') || addYears(from, -1), qp().get('ct') || addYears(to, -1));
  const grp = qp().get('g') || 'customer', lvl = +(qp().get('lvl') || 2);
  const canPL = can('reports', 'view'), canSales = can('sales_invoices', 'view') || can('reports', 'view');
  const tabs = [['pl', '📈 قائمة الدخل', canPL], ['sales', '🧾 المبيعات', canSales]].filter(x => x[2]);
  if (!tabs.length) return void (v.innerHTML = '<div class="notice">ما عندك صلاحية التقارير</div>');
  v.innerHTML = `<div class="page-head"><h2>⚖️ مقارنة الفترات</h2><div class="spacer"></div><button class="btn" id="pr">🖨️ طباعة</button></div>
    <div class="tabs" style="margin-bottom:10px">${tabs.map(([k, l]) => `<a class="tab ${t === k ? 'active' : ''}" href="#/compare?t=${k}">${l}</a>`).join('')}</div>
    <div class="card filters no-print" style="display:flex;gap:10px;align-items:end;flex-wrap:wrap">
      <div class="field"><label>الفترة الحالية من</label><input type="date" id="from" value="${from}"></div><div class="field"><label>إلى</label><input type="date" id="to" value="${to}"></div>
      <div class="field"><label>قارن مع</label><select id="m"><option value="year" ${mode === 'year' ? 'selected' : ''}>نفس الفترة من السنة الماضية</option><option value="prev" ${mode === 'prev' ? 'selected' : ''}>الفترة السابقة (نفس الطول)</option><option value="custom" ${mode === 'custom' ? 'selected' : ''}>فترة بختارها</option></select></div>
      <div class="field" id="cfw" style="${mode === 'custom' ? '' : 'display:none'}"><label>من</label><input type="date" id="cf" value="${cf}"></div><div class="field" id="ctw" style="${mode === 'custom' ? '' : 'display:none'}"><label>إلى</label><input type="date" id="ct" value="${ct}"></div>
      ${t === 'sales' ? `<div class="field"><label>حسب</label><select id="g">${[['customer', 'العميل'], ['item', 'الصنف'], ['item_category', 'فئة الصنف'], ['customer_category', 'فئة العميل'], ['rep', 'المندوب'], ['department', 'الدائرة/الفرع'], ['none', 'الإجمالي']].map(([k, l]) => `<option value="${k}" ${k === grp ? 'selected' : ''}>${l}</option>`).join('')}</select></div>`
        : `<div class="field"><label>المستوى</label><select id="lvl">${[1, 2, 3, 4].map(n => `<option ${n === lvl ? 'selected' : ''}>${n}</option>`).join('')}</select></div>`}
      <button class="btn primary" id="go">عرض</button></div>
    <div id="out"><div class="muted">بيحمّل…</div></div>`;
  v.querySelector('#m').onchange = (e) => { const c = e.target.value === 'custom'; v.querySelector('#cfw').style.display = c ? '' : 'none'; v.querySelector('#ctw').style.display = c ? '' : 'none'; };
  v.querySelector('#go').onclick = () => {
    const q = new URLSearchParams({ t, from: v.querySelector('#from').value, to: v.querySelector('#to').value, m: v.querySelector('#m').value, cf: v.querySelector('#cf').value, ct: v.querySelector('#ct').value });
    if (t === 'sales') q.set('g', v.querySelector('#g').value); else q.set('lvl', v.querySelector('#lvl').value);
    location.hash = '#/compare?' + q.toString();
  };
  const out = v.querySelector('#out');
  const sub = `الحالية: ${fmtDate(from)} — ${fmtDate(to)} · المقارنة: ${fmtDate(cf)} — ${fmtDate(ct)}`;
  const head = `<p class="muted" style="margin:6px 0">${sub}</p>`;
  try {
    if (t === 'pl') {
      const [accs, A, B] = await Promise.all([loadAccounts(), plData(from, to), plData(cf, ct)]);
      if (!A) return void (out.innerHTML = '<div class="notice">ما في سنة مالية للفترة الحالية</div>');
      const kids = {}; accs.forEach(a => (kids[a.parent_id || 'root'] ||= []).push(a));
      Object.values(kids).forEach(l => l.sort((x, y) => x.code.localeCompare(y.code, 'en', { numeric: true })));
      const tot = (a, M) => (M?.[a.id] || 0) + (kids[a.id] || []).reduce((s, c) => s + tot(c, M), 0);
      const rows = [];
      const walk = (a, depth, sign) => {
        const x = tot(a, A) * sign, y = tot(a, B) * sign;
        if (!x && !y) return;
        rows.push(`<tr style="${depth === 1 ? 'font-weight:700' : ''}"><td style="padding-inline-start:${(depth - 1) * 18 + 8}px">${esc(a.code)} — ${esc(a.name)}</td><td class="n">${fmtNum(x)}</td><td class="n">${fmtNum(y)}</td><td class="n">${fmtNum(x - y)}</td>
          <td class="n" style="${pctColor(x, y, a.category === 'revenue')}">${pct(x, y)}</td></tr>`);
        if (depth < lvl) (kids[a.id] || []).forEach(c => walk(c, depth + 1, sign));
      };
      const roots = kids.root || [];
      const rev = roots.filter(a => a.category === 'revenue'), exp = roots.filter(a => a.category === 'expenses');
      rev.forEach(a => walk(a, 1, -1));
      const rA = -rev.reduce((s, a) => s + tot(a, A), 0), rB = -rev.reduce((s, a) => s + tot(a, B), 0);
      rows.push(`<tr style="background:var(--tint)"><td><b>مجموع الإيرادات</b></td><td class="n"><b>${fmtNum(rA)}</b></td><td class="n"><b>${fmtNum(rB)}</b></td><td class="n">${fmtNum(rA - rB)}</td><td class="n" style="${pctColor(rA, rB)}"><b>${pct(rA, rB)}</b></td></tr>`);
      exp.forEach(a => walk(a, 1, 1));
      const eA = exp.reduce((s, a) => s + tot(a, A), 0), eB = exp.reduce((s, a) => s + tot(a, B), 0);
      rows.push(`<tr style="background:var(--tint)"><td><b>مجموع المصاريف</b></td><td class="n"><b>${fmtNum(eA)}</b></td><td class="n"><b>${fmtNum(eB)}</b></td><td class="n">${fmtNum(eA - eB)}</td><td class="n" style="${pctColor(eA, eB, false)}"><b>${pct(eA, eB)}</b></td></tr>`);
      const nA = rA - eA, nB = rB - eB;
      rows.push(`<tr style="background:var(--tint-2);font-size:15px"><td><b>صافي الربح / الخسارة</b></td><td class="n"><b>${fmtNum(nA)}</b></td><td class="n"><b>${fmtNum(nB)}</b></td><td class="n"><b>${fmtNum(nA - nB)}</b></td><td class="n" style="${pctColor(nA, nB)}"><b>${pct(nA, nB)}</b></td></tr>`);
      out.innerHTML = `${head}${!B ? '<div class="notice info">ما في سنة مالية لفترة المقارنة، فطلعت أصفار.</div>' : ''}
        <div class="grid cols-3" style="margin-bottom:10px">
          <div class="card stat"><span class="k">الإيرادات</span><span class="v">${fmtNum(rA)}</span><span class="muted" style="${pctColor(rA, rB)}">${pct(rA, rB)}</span></div>
          <div class="card stat"><span class="k">المصاريف</span><span class="v">${fmtNum(eA)}</span><span class="muted" style="${pctColor(eA, eB, false)}">${pct(eA, eB)}</span></div>
          <div class="card stat"><span class="k">صافي الربح</span><span class="v">${fmtNum(nA)}</span><span class="muted" style="${pctColor(nA, nB)}">${pct(nA, nB)}</span></div></div>
        <div class="card table-wrap"><table class="t rep"><thead><tr><th>الحساب</th><th style="text-align:left">الفترة الحالية</th><th style="text-align:left">فترة المقارنة</th><th style="text-align:left">الفرق</th><th style="text-align:left">النمو</th></tr></thead><tbody>${rows.join('')}</tbody></table></div>`;
    } else {
      const call = (f, tt) => sb.rpc('ask_sales', { p_company: S.company.id, p_from: f, p_to: tt, p_group: grp, p_filters: {}, p_top: null, p_group2: null });
      const [a, b] = await Promise.all([call(from, to), call(cf, ct)]);
      if (a.error) throw a.error; if (b.error) throw b.error;
      const m = {};
      (a.data || []).forEach(r => { m[r.k1] = { label: r.label1, a: num(r.net), aq: num(r.qty), b: 0, bq: 0 }; });
      (b.data || []).forEach(r => { m[r.k1] ||= { label: r.label1, a: 0, aq: 0, b: 0, bq: 0 }; m[r.k1].b = num(r.net); m[r.k1].bq = num(r.qty); });
      const list = Object.values(m).sort((x, y) => y.a - x.a || y.b - x.b);
      const sa = list.reduce((s, r) => s + r.a, 0), sb2 = list.reduce((s, r) => s + r.b, 0);
      const up = list.filter(r => r.a > r.b).length, down = list.filter(r => r.a < r.b).length, lost = list.filter(r => r.b > 0 && r.a === 0).length, fresh = list.filter(r => r.a > 0 && r.b === 0).length;
      out.innerHTML = `${head}<div class="grid cols-4" style="margin-bottom:10px">
          <div class="card stat"><span class="k">صافي المبيعات</span><span class="v">${fmtNum(sa)}</span><span class="muted" style="${pctColor(sa, sb2)}">${pct(sa, sb2)} (كانت ${fmtNum(sb2)})</span></div>
          <div class="card stat"><span class="k">طالعين ▲</span><span class="v" style="color:var(--ok)">${up}</span></div>
          <div class="card stat"><span class="k">نازلين ▼</span><span class="v" style="color:var(--bad)">${down}</span></div>
          <div class="card stat"><span class="k">جديد / توقّف</span><span class="v">${fresh} / ${lost}</span></div></div>
        <div class="card table-wrap"><table class="t rep"><thead><tr><th>البند</th><th style="text-align:left">الكمية الحالية</th><th style="text-align:left">المبيعات الحالية</th><th style="text-align:left">كمية المقارنة</th><th style="text-align:left">مبيعات المقارنة</th><th style="text-align:left">الفرق</th><th style="text-align:left">النمو</th><th style="text-align:left">الحصة</th></tr></thead><tbody>
        ${list.map(r => `<tr><td>${esc(r.label || '')}${r.b > 0 && r.a === 0 ? ' <span class="badge bad">توقّف</span>' : r.a > 0 && r.b === 0 ? ' <span class="badge ok">جديد</span>' : ''}</td><td class="n">${fmtNum(r.aq)}</td><td class="n">${fmtNum(r.a)}</td><td class="n">${fmtNum(r.bq)}</td><td class="n">${fmtNum(r.b)}</td>
          <td class="n">${fmtNum(r.a - r.b)}</td><td class="n" style="${pctColor(r.a, r.b)}">${pct(r.a, r.b)}</td><td class="n">${sa ? Math.round(r.a / sa * 1000) / 10 + '%' : ''}</td></tr>`).join('') || '<tr><td colspan="8" class="empty">ما في مبيعات بالفترتين</td></tr>'}
        </tbody><tfoot><tr><td><b>المجموع</b></td><td></td><td class="n"><b>${fmtNum(sa)}</b></td><td></td><td class="n"><b>${fmtNum(sb2)}</b></td><td class="n"><b>${fmtNum(sa - sb2)}</b></td><td class="n" style="${pctColor(sa, sb2)}"><b>${pct(sa, sb2)}</b></td><td></td></tr></tfoot></table></div>
        <p class="muted" style="font-size:12px">المبيعات صافي بعد المرتجعات وقبل الضريبة، من الفواتير المرحّلة.</p>`;
    }
  } catch (e) { out.innerHTML = `<div class="notice">${esc(arError(e))}</div>`; }
  v.querySelector('#pr').onclick = () => { const tb = out.querySelector('table'); if (tb) printDoc(t === 'pl' ? 'مقارنة قائمة الدخل' : 'مقارنة المبيعات', tb.outerHTML.replace('class="t rep"', 'class="pt"'), { subtitle: sub }); };
}

export const COMPARE_ROUTES = { compare: viewCompare };
