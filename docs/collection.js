// =====================================================================
//  السمو ERP — تقارير تحصيل الفواتير (route collection?type=customer|supplier&t=open|coll)
//  open: الفواتير غير المسددة (rep_open_invoices) بأعمارها من الاستحقاق، تجميعي أو تفصيلي.
//  coll: تحصيل فواتير فترة (rep_invoice_collection): المحصّل ونسبته، وأقل/معدل/أعلى أيام التحصيل، والتأخير — لكل طرف أو مندوب.
// =====================================================================
import { S, sb, esc, fmtDate, fmtNum, num, today, arError, can } from './core.js';
import { loadParties } from './parties.js';
import { loadLookups, repOptions, hasReps } from './lookups.js';
import { downloadCSV } from './finance.js';
import { printDoc } from './print.js';
import { docNo } from './numbering.js';

const W = { customer: { label: 'العميل', plural: 'العملاء', inv: 'فواتير المبيعات', paid: 'المحصّل' }, supplier: { label: 'المورد', plural: 'الموردين', inv: 'فواتير المشتريات', paid: 'المسدّد' } };
const BK = [['غير مستحقة', -1e9, 0], ['1–30', 1, 30], ['31–60', 31, 60], ['61–90', 61, 90], ['+90', 91, 1e9]];
const daysBetween = (a, b) => Math.floor((new Date(a) - new Date(b)) / 86400000);

async function viewCollection(v) {
  if (!S.company || !S.fy) return void (v.innerHTML = '<div class="notice info">اختار شركة وسنة مالية أول.</div>');
  const q = new URLSearchParams(location.hash.split('?')[1] || '');
  const type = q.get('type') === 'supplier' ? 'supplier' : 'customer', t = q.get('t') === 'coll' ? 'coll' : 'open', P = W[type];
  const [parties, , catR] = await Promise.all([loadParties(), loadLookups(), sb.from('party_categories').select('id,name').eq('company_id', S.company.id).eq('party_type', type).order('code')]);
  const pById = Object.fromEntries(parties.map(p => [p.id, p]));
  const reps = type === 'customer' && hasReps();
  const repName = (id) => (S._lk?.rows || []).find(r => r.id === id)?.name || '';
  const from0 = S.fy.start_date, to0 = today() >= S.fy.start_date && today() <= S.fy.end_date ? today() : S.fy.end_date;
  v.innerHTML = `<div class="page-head"><h2>💰 ${t === 'open' ? 'الفواتير غير المسددة' : 'تحصيل الفواتير'} — ${P.plural}</h2><div class="spacer"></div>
      <div class="tabs" style="margin:0">${[['open', 'غير المسددة'], ['coll', 'التحصيل وأيام السداد']].map(([k, l]) => `<a class="tab ${t === k ? 'active' : ''}" href="#/collection?type=${type}&t=${k}">${l}</a>`).join('')}</div></div>
    <div class="card no-print filters">
      <div class="field"><label>الطرف</label><input id="f-p" list="co-pl" placeholder="الكل"><datalist id="co-pl">${parties.filter(p => p.party_type === type).map(p => `<option value="${esc(p.code)} — ${esc(p.name)}">`).join('')}</datalist></div>
      <div class="field"><label>الفئة</label><select id="f-cat"><option value="">الكل</option>${(catR.data || []).map(c => `<option value="${c.id}">${esc(c.name)}</option>`).join('')}</select></div>
      ${reps ? `<div class="field"><label>المندوب</label><select id="f-rep"><option value="">الكل</option>${repOptions('')}</select></div>` : ''}
      ${t === 'coll' ? `<div class="field"><label>فواتير من</label><input type="date" id="f-from" value="${from0}"></div><div class="field"><label>إلى</label><input type="date" id="f-to" value="${to0}"></div>
        <div class="field"><label>التجميع</label><select id="f-grp"><option value="party">حسب ${P.label}</option>${reps ? '<option value="rep">حسب المندوب</option>' : ''}<option value="inv">كل فاتورة</option></select></div>`
      : `<div class="field"><label>العرض</label><select id="f-mode"><option value="sum">تجميعي</option><option value="det">تفصيلي</option></select></div>
        <div class="field" style="justify-content:flex-end"><label class="check" style="margin:0 0 10px"><input type="checkbox" id="f-due"> المستحقة بس</label></div>`}
      <div class="field" style="justify-content:flex-end"><button class="btn primary" id="f-run">عرض التقرير</button></div>
      <div class="field" style="justify-content:flex-end;flex-direction:row;gap:6px">${can('reports', 'print') ? '<button class="btn" id="f-print">🖨️ طباعة</button>' : ''}<button class="btn" id="f-csv">⬇️ Excel</button></div>
    </div><div id="out"></div>`;
  const out = v.querySelector('#out');
  let last = null;
  const filt = (r) => { const p = pById[r.party_id] || {}, pq = v.querySelector('#f-p').value.split('—')[0].trim(), cat = v.querySelector('#f-cat').value, rep = v.querySelector('#f-rep')?.value;
    return (!pq || p.code === pq) && (!cat || p.category_id === cat) && (!rep || (r.sales_rep_id || p.sales_rep_id) === rep); };

  const runOpen = async () => {
    const { data, error } = await sb.rpc('rep_open_invoices', { p_company: S.company.id, p_type: type });
    if (error) return void (out.innerHTML = `<div class="notice">${esc(arError(error))}</div>`);
    const now = today(), onlyDue = v.querySelector('#f-due').checked, det = v.querySelector('#f-mode').value === 'det';
    const rows = (data || []).filter(filt).map(r => { const late = daysBetween(now, r.due_date); return { ...r, late, bi: BK.findIndex(b => late >= b[1] && late <= b[2]) }; })
      .filter(r => !onlyDue || r.late > 0);
    const by = {}; rows.forEach(r => { const g = (by[r.party_id] ||= { p: pById[r.party_id] || { name: '?' }, rows: [], b: [0, 0, 0, 0, 0], tot: 0 }); g.rows.push(r); g.b[r.bi] += num(r.remaining); g.tot += num(r.remaining); });
    const groups = Object.values(by).sort((a, b) => b.tot - a.tot), tot = [0, 0, 0, 0, 0]; groups.forEach(g => g.b.forEach((x, i) => tot[i] += x));
    const T = tot.reduce((s, x) => s + x, 0), cell = (x) => `<td class="n">${x > 0.0005 ? fmtNum(x) : ''}</td>`;
    const table = det
      ? `<table class="t pt rep"><thead><tr><th>الفاتورة</th><th>التاريخ</th><th>الاستحقاق</th><th>المبلغ</th><th>مرتجع</th><th>${P.paid}</th><th>المتبقي</th><th>أيام التأخير</th></tr></thead><tbody>
        ${groups.map(g => `<tr class="grp"><td colspan="8"><b>${esc(g.p.code || '')} — ${esc(g.p.name)}</b>${g.p.mobile || g.p.phone ? ` <small class="muted">${esc(g.p.mobile || g.p.phone)}</small>` : ''}</td></tr>
          ${g.rows.map(r => `<tr><td>${esc(docNo(r))}</td><td>${fmtDate(r.inv_date)}</td><td>${fmtDate(r.due_date)}</td><td class="n">${fmtNum(r.total)}</td><td class="n">${num(r.returned) ? fmtNum(r.returned) : ''}</td>
            <td class="n">${num(r.allocated) ? fmtNum(r.allocated) : ''}</td><td class="n"><b>${fmtNum(r.remaining)}</b></td><td class="n" ${r.late > 0 ? 'style="color:var(--bad)"' : ''}>${r.late > 0 ? r.late : '—'}</td></tr>`).join('')}
          <tr class="tot"><td colspan="6">مجموع ${esc(g.p.name)} (${g.rows.length})</td><td class="n">${fmtNum(g.tot)}</td><td></td></tr>`).join('') || '<tr><td colspan="8" class="empty">ما في فواتير مفتوحة</td></tr>'}</tbody>
        <tfoot><tr class="tot"><td colspan="6">المجموع العام</td><td class="n">${fmtNum(T)}</td><td></td></tr></tfoot></table>`
      : `<table class="t pt rep"><thead><tr><th>الرقم</th><th>${P.label}</th><th>عدد الفواتير</th>${BK.map(b => `<th>${b[0]}${b[1] > 0 ? ' يوم' : ''}</th>`).join('')}<th>المجموع</th><th>أقدم استحقاق</th></tr></thead><tbody>
        ${groups.map(g => `<tr><td>${esc(g.p.code || '')}</td><td>${esc(g.p.name)}</td><td class="n">${g.rows.length}</td>${g.b.map(cell).join('')}<td class="n"><b>${fmtNum(g.tot)}</b></td><td>${fmtDate(g.rows.reduce((m, r) => r.due_date < m ? r.due_date : m, '9999-12-31'))}</td></tr>`).join('') || '<tr><td colspan="10" class="empty">ما في فواتير مفتوحة</td></tr>'}</tbody>
        <tfoot><tr class="tot"><td colspan="3">المجموع (${groups.length})</td>${tot.map(x => `<td class="n">${fmtNum(x)}${T > 0.0005 ? ` <small class="muted">${Math.round(x / T * 100)}%</small>` : ''}</td>`).join('')}<td class="n">${fmtNum(T)}</td><td></td></tr></tfoot></table>`;
    out.innerHTML = `<div class="card table-wrap" style="margin-top:12px">${table}</div>
      <p class="muted" style="font-size:13px">من الفواتير الآجلة المرحّلة، بعد المرتجعات والدفعات الموزّعة عليها («🧾 توزيع على الفواتير» بسند القبض/الصرف). العمر من تاريخ الاستحقاق (أو تاريخ الفاتورة + مدة السداد) لليوم. الدفعة اللي ما انوزّعت ما بتنزّل من هون.</p>`;
    last = { title: `الفواتير غير المسددة — ${P.plural}`, sub: `كما في ${fmtDate(now)}`, table,
      csv: [['الرقم', 'الاسم', 'الفاتورة', 'التاريخ', 'الاستحقاق', 'المبلغ', 'مرتجع', P.paid, 'المتبقي', 'أيام التأخير']].concat(rows.map(r => [pById[r.party_id]?.code || '', pById[r.party_id]?.name || '', docNo(r), r.inv_date, r.due_date, num(r.total).toFixed(3), num(r.returned).toFixed(3), num(r.allocated).toFixed(3), num(r.remaining).toFixed(3), Math.max(0, r.late)])) };
  };

  const runColl = async () => {
    const from = v.querySelector('#f-from').value, to = v.querySelector('#f-to').value, grp = v.querySelector('#f-grp').value;
    const { data, error } = await sb.rpc('rep_invoice_collection', { p_company: S.company.id, p_type: type, p_from: from, p_to: to });
    if (error) return void (out.innerHTML = `<div class="notice">${esc(arError(error))}</div>`);
    const rows = (data || []).filter(filt);
    const keyOf = (r) => grp === 'rep' ? (r.sales_rep_id || pById[r.party_id]?.sales_rep_id || '-') : r.party_id;
    const nameOf = (k) => grp === 'rep' ? (k === '-' ? 'بدون مندوب' : repName(k)) : `${pById[k]?.code || ''} — ${pById[k]?.name || '?'}`;
    const agg = (list) => { const net = list.reduce((s, r) => s + num(r.total) - num(r.returned), 0), col = list.reduce((s, r) => s + num(r.collected), 0);
      const wd = list.reduce((s, r) => s + num(r.collected) * num(r.avg_days), 0), full = list.filter(r => r.full_days != null).map(r => r.full_days);
      return { n: list.length, net, col, rem: list.reduce((s, r) => s + num(r.remaining), 0), pct: net > 0 ? col / net * 100 : 0,
        avg: col > 0 ? wd / col : null, min: full.length ? Math.min(...full) : null, max: full.length ? Math.max(...full) : null, paidN: full.length,
        lateN: list.filter(r => r.late_days > 0).length, late: list.length ? list.reduce((s, r) => s + num(r.late_days), 0) / list.length : 0 }; };
    const d1 = (x) => x == null ? '—' : (Math.round(x * 10) / 10).toString();
    let table, csv;
    if (grp === 'inv') {
      table = `<table class="t pt rep"><thead><tr><th>${P.label}</th><th>الفاتورة</th><th>التاريخ</th><th>الاستحقاق</th><th>الصافي</th><th>${P.paid}</th><th>المتبقي</th><th>أول دفعة</th><th>آخر دفعة</th><th>معدل أيام التحصيل</th><th>السداد الكامل (يوم)</th><th>التأخير (يوم)</th></tr></thead><tbody>
        ${rows.map(r => `<tr><td>${esc(pById[r.party_id]?.name || '')}</td><td>${esc(docNo(r))}</td><td>${fmtDate(r.inv_date)}</td><td>${fmtDate(r.due_date)}</td><td class="n">${fmtNum(num(r.total) - num(r.returned))}</td>
          <td class="n">${num(r.collected) ? fmtNum(r.collected) : ''}</td><td class="n">${num(r.remaining) > 0.0005 ? `<b>${fmtNum(r.remaining)}</b>` : '✓'}</td><td>${fmtDate(r.first_pay)}</td><td>${fmtDate(r.last_pay)}</td>
          <td class="n">${d1(r.avg_days)}</td><td class="n">${r.full_days ?? '—'}</td><td class="n" ${r.late_days > 0 ? 'style="color:var(--bad)"' : ''}>${r.late_days || ''}</td></tr>`).join('') || '<tr><td colspan="12" class="empty">ما في فواتير بالفترة</td></tr>'}</tbody></table>`;
      csv = [[P.label, 'الفاتورة', 'التاريخ', 'الاستحقاق', 'الصافي', P.paid, 'المتبقي', 'أول دفعة', 'آخر دفعة', 'معدل أيام التحصيل', 'السداد الكامل', 'التأخير']].concat(rows.map(r => [pById[r.party_id]?.name || '', docNo(r), r.inv_date, r.due_date, (num(r.total) - num(r.returned)).toFixed(3), num(r.collected).toFixed(3), num(r.remaining).toFixed(3), r.first_pay || '', r.last_pay || '', r.avg_days ?? '', r.full_days ?? '', r.late_days ?? '']));
    } else {
      const by = {}; rows.forEach(r => (by[keyOf(r)] ||= []).push(r));
      const groups = Object.entries(by).map(([k, l]) => ({ k, ...agg(l) })).sort((a, b) => b.net - a.net), all = agg(rows);
      const tr = (g, name, cls = '') => `<tr class="${cls}"><td>${esc(name)}</td><td class="n">${g.n}</td><td class="n">${fmtNum(g.net)}</td><td class="n">${fmtNum(g.col)}</td><td class="n">${fmtNum(g.rem)}</td><td class="n">${Math.round(g.pct)}%</td>
        <td class="n">${g.min ?? '—'}</td><td class="n"><b>${d1(g.avg)}</b></td><td class="n">${g.max ?? '—'}</td><td class="n">${g.paidN}/${g.n}</td><td class="n">${g.lateN ? `${g.lateN} · ${d1(g.late)}` : ''}</td></tr>`;
      table = `<table class="t pt rep"><thead><tr><th>${grp === 'rep' ? 'المندوب' : P.label}</th><th>عدد الفواتير</th><th>الصافي</th><th>${P.paid}</th><th>المتبقي</th><th>نسبة التحصيل</th><th>أقل أيام سداد</th><th>معدل أيام التحصيل</th><th>أعلى أيام سداد</th><th>المسددة كاملة</th><th>المتأخرة · معدل التأخير</th></tr></thead><tbody>
        ${groups.map(g => tr(g, nameOf(g.k))).join('') || '<tr><td colspan="11" class="empty">ما في فواتير بالفترة</td></tr>'}</tbody>
        ${rows.length ? `<tfoot>${tr(all, 'المجموع', 'tot')}</tfoot>` : ''}</table>`;
      csv = [[grp === 'rep' ? 'المندوب' : P.label, 'عدد الفواتير', 'الصافي', P.paid, 'المتبقي', 'نسبة التحصيل', 'أقل أيام', 'معدل أيام التحصيل', 'أعلى أيام', 'المسددة كاملة', 'المتأخرة']].concat(groups.map(g => [nameOf(g.k), g.n, g.net.toFixed(3), g.col.toFixed(3), g.rem.toFixed(3), Math.round(g.pct), g.min ?? '', g.avg == null ? '' : g.avg.toFixed(1), g.max ?? '', g.paidN, g.lateN]));
    }
    out.innerHTML = `<div class="card table-wrap" style="margin-top:12px">${table}</div>
      <p class="muted" style="font-size:13px">${P.inv} الآجلة المرحّلة من ${fmtDate(from)} لـ ${fmtDate(to)}. «معدل أيام التحصيل» = أيام من تاريخ الفاتورة لتاريخ كل دفعة موزّعة عليها، موزونة بالمبلغ. «أقل/أعلى أيام سداد» للفواتير المسددة كاملة. التأخير من تاريخ الاستحقاق لآخر دفعة (أو لليوم إذا لسا مفتوحة).</p>`;
    last = { title: `تحصيل الفواتير — ${P.plural}`, sub: `فواتير من ${fmtDate(from)} لـ ${fmtDate(to)}`, table, csv };
  };

  v.querySelector('#f-run').onclick = () => (t === 'open' ? runOpen() : runColl());
  v.querySelector('#f-print')?.addEventListener('click', () => last && printDoc(last.title, last.table, { subtitle: last.sub, landscape: true }));
  v.querySelector('#f-csv').onclick = () => last && downloadCSV(`${last.title}.csv`, last.csv);
  (t === 'open' ? runOpen() : runColl());
}

export const COLLECTION_ROUTES = { collection: viewCollection };
