// =====================================================================
//  السمو ERP — المرحلة 3: التقارير المالية
// =====================================================================
import { S, sb, esc, fmtDate, fmtNum, num, toast, arError, can } from './core.js';
import { loadAccounts, accLabel, CATEGORIES, ENTRY_TYPES, downloadCSV } from './finance.js';
import { printDoc } from './print.js';

const hashParams = () => new URLSearchParams(location.hash.split('?')[1] || '');
const money = (n) => (Math.abs(n) < 0.0005 ? '' : fmtNum(n));
const drcr = (n) => (Math.abs(n) < 0.0005 ? ['', ''] : n > 0 ? [fmtNum(n), ''] : ['', fmtNum(-n)]);
const fyLabel = () => S.fy ? (S.fy.name || S.fy.code) : '';

function guard(v) {
  if (!S.company) { v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`; return false; }
  if (!S.fy) { v.innerHTML = `<div class="notice">هالشركة ما إلها سنة مالية. <a href="#/fiscal-years">أضف سنة مالية</a> أول.</div>`; return false; }
  return true;
}

function rangeBar(extra = '') {
  const p = hashParams();
  return `<div class="card no-print filters">
    <div class="field"><label>من تاريخ</label><input type="date" id="f-from" value="${esc(p.get('from') || S.fy.start_date)}" min="${S.fy.start_date}" max="${S.fy.end_date}"></div>
    <div class="field"><label>إلى تاريخ</label><input type="date" id="f-to" value="${esc(p.get('to') || S.fy.end_date)}" min="${S.fy.start_date}" max="${S.fy.end_date}"></div>
    ${extra}
    <div class="field" style="justify-content:flex-end"><button class="btn primary" id="f-run">عرض التقرير</button></div>
    <div class="field" style="justify-content:flex-end;flex-direction:row;gap:6px">
      <button class="btn" id="f-print">🖨️ طباعة</button><button class="btn" id="f-csv">⬇️ Excel</button></div>
  </div>`;
}
const getRange = (v) => ({ from: v.querySelector('#f-from').value || S.fy.start_date, to: v.querySelector('#f-to').value || S.fy.end_date });
const subtitleRange = (r) => `من ${fmtDate(r.from)} إلى ${fmtDate(r.to)} — ${fyLabel()}`;

function wireOutput(v, getPrint, getCSV) {
  const pb = v.querySelector('#f-print'), cb = v.querySelector('#f-csv');
  if (!can('reports', 'print')) pb.style.display = 'none';
  pb.onclick = () => { const p = getPrint(); if (p) printDoc(p.title, p.html, p.opts || {}); };
  cb.onclick = () => { const c = getCSV(); if (c) downloadCSV(c.name, c.rows); };
}

// ---------------------------------------------------------------------
//  ميزان المراجعة (أساس قائمة الدخل والميزانية)
// ---------------------------------------------------------------------
async function trialData(from, to) {
  const [accs, res] = await Promise.all([loadAccounts(),
    sb.rpc('rep_trial_balance', { p_company: S.company.id, p_fy: S.fy.id, p_from: from, p_to: to })]);
  if (res.error) throw res.error;
  const raw = Object.fromEntries((res.data || []).map(r => [r.account_id, r]));
  const kids = {}; accs.forEach(a => (kids[a.parent_id || 'root'] ||= []).push(a));
  Object.values(kids).forEach(l => l.sort((x, y) => x.code.localeCompare(y.code, 'en', { numeric: true })));
  const T = {};
  const roll = (a) => {
    const r = raw[a.id] || {};
    const t = { od: num(r.open_debit), oc: num(r.open_credit), pd: num(r.period_debit), pc: num(r.period_credit) };
    (kids[a.id] || []).forEach(c => { const x = roll(c); t.od += x.od; t.oc += x.oc; t.pd += x.pd; t.pc += x.pc; });
    t.open = t.od - t.oc; t.close = t.open + t.pd - t.pc;
    return T[a.id] = t;
  };
  (kids.root || []).forEach(roll);
  return { accs, kids, T };
}

async function viewTrial(v) {
  if (!guard(v)) return;
  v.innerHTML = `<div class="page-head"><h2>⚖️ ميزان المراجعة</h2></div>
    ${rangeBar(`<div class="field"><label>المستوى</label><select id="f-lvl"><option value="99">كل الحسابات الفرعية</option><option value="1">1</option><option value="2">2</option><option value="3">3</option><option value="4">4</option></select></div>
      <div class="field" style="justify-content:flex-end"><label class="check" style="margin:0 0 10px"><input type="checkbox" id="f-zero" checked> إخفاء الأصفار</label></div>`)}
    <div id="out"></div>`;
  let last = null;
  const run = async () => {
    const r = getRange(v), lvl = +v.querySelector('#f-lvl').value, hideZero = v.querySelector('#f-zero').checked;
    const out = v.querySelector('#out'); out.innerHTML = '<div class="empty">جاري التحميل…</div>';
    try {
      const { kids, T } = await trialData(r.from, r.to);
      const rows = [];
      const isZero = (t) => !t.od && !t.oc && !t.pd && !t.pc;
      const walk = (list) => list.forEach(a => {
        const t = T[a.id];
        const detail = lvl === 99 ? !a.is_group : (!a.is_group || a.level >= lvl);   // سطر بيدخل بالمجموع
        if (detail) { if (!(hideZero && isZero(t))) rows.push({ a, t, grp: false }); return; }
        if (lvl !== 99 && !(hideZero && isZero(t))) rows.push({ a, t, grp: true });     // عنوان رئيسي فوق فروعه
        walk(kids[a.id] || []);
      });
      walk(kids.root || []);
      const leaves = rows.filter(x => !x.grp);
      const sum = leaves.reduce((s, { t }) => { const o = drcr(t.open), c = drcr(t.close);
        s.od += t.open > 0 ? t.open : 0; s.oc += t.open < 0 ? -t.open : 0; s.pd += t.pd; s.pc += t.pc;
        s.cd += t.close > 0 ? t.close : 0; s.cc += t.close < 0 ? -t.close : 0; return s; }, { od: 0, oc: 0, pd: 0, pc: 0, cd: 0, cc: 0 });
      const ok = Math.abs(sum.cd - sum.cc) < 0.001 && Math.abs(sum.pd - sum.pc) < 0.001;
      const tr = (x) => { const o = drcr(x.t.open), c = drcr(x.t.close);
        return `<tr class="${x.grp ? 'grp' : ''}"><td dir="ltr" style="text-align:right">${esc(x.a.code)}</td><td style="padding-inline-start:${(x.a.level - 1) * 14 + 12}px">${esc(x.a.name)}</td>
          <td class="n">${o[0]}</td><td class="n">${o[1]}</td><td class="n">${money(x.t.pd)}</td><td class="n">${money(x.t.pc)}</td><td class="n">${c[0]}</td><td class="n">${c[1]}</td></tr>`; };
      const table = `<table class="t pt rep"><thead><tr><th rowspan="2">رقم الحساب</th><th rowspan="2">اسم الحساب</th><th colspan="2">رصيد أول المدة</th><th colspan="2">حركة الفترة</th><th colspan="2">رصيد آخر المدة</th></tr>
        <tr><th>مدين</th><th>دائن</th><th>مدين</th><th>دائن</th><th>مدين</th><th>دائن</th></tr></thead>
        <tbody>${rows.map(tr).join('') || '<tr><td colspan="8" class="empty">ما في حركات مرحّلة بهالفترة</td></tr>'}</tbody>
        <tfoot><tr class="tot"><td colspan="2">المجموع</td><td class="n">${fmtNum(sum.od)}</td><td class="n">${fmtNum(sum.oc)}</td><td class="n">${fmtNum(sum.pd)}</td><td class="n">${fmtNum(sum.pc)}</td><td class="n">${fmtNum(sum.cd)}</td><td class="n">${fmtNum(sum.cc)}</td></tr></tfoot></table>`;
      out.innerHTML = `<div class="notice ${ok ? 'info' : ''}" style="margin-top:12px">${ok ? '✓ الميزان متوازن' : '⚠️ الميزان مش متوازن! راجع الأرصدة الافتتاحية'}</div><div class="card table-wrap">${table}</div>`;
      last = { r, rows, sum, table };
    } catch (e) { out.innerHTML = `<div class="notice">${esc(arError(e))}</div>`; }
  };
  v.querySelector('#f-run').onclick = run;
  wireOutput(v, () => last && { title: 'ميزان المراجعة', html: last.table, opts: { subtitle: subtitleRange(last.r), landscape: true } },
    () => last && { name: `ميزان المراجعة - ${S.company.name}.csv`, rows: [['رقم الحساب', 'اسم الحساب', 'أول المدة مدين', 'أول المدة دائن', 'الحركة مدين', 'الحركة دائن', 'آخر المدة مدين', 'آخر المدة دائن']]
      .concat(last.rows.map(({ a, t }) => { const o = drcr(t.open), c = drcr(t.close); return [a.code, a.name, o[0], o[1], t.pd.toFixed(3), t.pc.toFixed(3), c[0], c[1]]; })) });
  run();
}

// ---------------------------------------------------------------------
//  كشف حساب
// ---------------------------------------------------------------------
async function viewLedger(v) {
  if (!guard(v)) return;
  const accs = await loadAccounts();
  const p = hashParams(), pre = accs.find(a => a.id === p.get('acc'));
  v.innerHTML = `<div class="page-head"><h2>📄 كشف حساب</h2></div>
    ${rangeBar(`<div class="field" style="min-width:300px;flex:1"><label>الحساب</label><input list="acc-all" id="f-acc" value="${esc(accLabel(pre))}" placeholder="رقم أو اسم الحساب (فرعي أو رئيسي)…">
      <datalist id="acc-all">${accs.map(a => `<option value="${esc(accLabel(a))}">${a.is_group ? 'رئيسي' : ''}</option>`).join('')}</datalist></div>`)}
    <div id="out"><div class="empty">اختار حساب واضغط «عرض التقرير»</div></div>`;
  let last = null;
  const run = async () => {
    const t = v.querySelector('#f-acc').value.trim(), code = t.split('—')[0].trim();
    const a = accs.find(x => x.code === code) || accs.find(x => x.name === t);
    if (!a) return toast('اختار حساب من القائمة', 'err');
    const r = getRange(v), out = v.querySelector('#out'); out.innerHTML = '<div class="empty">جاري التحميل…</div>';
    try {
      const [ob, mv] = await Promise.all([
        sb.rpc('rep_balance_before', { p_company: S.company.id, p_fy: S.fy.id, p_account: a.id, p_date: r.from }),
        sb.rpc('rep_ledger', { p_company: S.company.id, p_fy: S.fy.id, p_account: a.id, p_from: r.from, p_to: r.to })]);
      if (ob.error) throw ob.error; if (mv.error) throw mv.error;
      let run = num(ob.data), td = 0, tc = 0;
      const open = drcr(run);
      const body = mv.data.map(m => { run += num(m.debit) - num(m.credit); td += num(m.debit); tc += num(m.credit); const b = drcr(run);
        return `<tr><td>${fmtDate(m.entry_date)}</td><td>${ENTRY_TYPES[m.entry_type].label} ${m.entry_no}</td>${a.is_group ? `<td>${esc(m.account_code)} ${esc(m.account_name)}</td>` : ''}
          <td>${esc(m.line_description || m.description || '')}</td><td>${esc(m.reference || '')}</td>
          <td class="n">${money(num(m.debit))}</td><td class="n">${money(num(m.credit))}</td><td class="n">${b[0]}</td><td class="n">${b[1]}</td></tr>`; }).join('');
      const close = drcr(run);
      const table = `<table class="t pt rep"><thead><tr><th>التاريخ</th><th>السند</th>${a.is_group ? '<th>الحساب</th>' : ''}<th>البيان</th><th>المرجع</th><th>مدين</th><th>دائن</th><th>الرصيد مدين</th><th>الرصيد دائن</th></tr></thead>
        <tbody><tr class="grp"><td>${fmtDate(r.from)}</td><td colspan="${a.is_group ? 4 : 3}">رصيد أول المدة</td><td></td><td></td><td class="n">${open[0]}</td><td class="n">${open[1]}</td></tr>
        ${body || `<tr><td colspan="${a.is_group ? 9 : 8}" class="empty">ما في حركات مرحّلة بهالفترة</td></tr>`}</tbody>
        <tfoot><tr class="tot"><td colspan="${a.is_group ? 5 : 4}">المجموع / رصيد آخر المدة</td><td class="n">${fmtNum(td)}</td><td class="n">${fmtNum(tc)}</td><td class="n">${close[0]}</td><td class="n">${close[1]}</td></tr></tfoot></table>`;
      out.innerHTML = `<div class="grid cols-3" style="margin:12px 0">
          <div class="card stat"><span class="k">رصيد أول المدة</span><span class="v" dir="ltr" style="font-size:20px">${fmtNum(Math.abs(num(ob.data)))} ${num(ob.data) >= 0 ? 'مدين' : 'دائن'}</span></div>
          <div class="card stat"><span class="k">حركة الفترة (مدين / دائن)</span><span class="v" dir="ltr" style="font-size:20px">${fmtNum(td)} / ${fmtNum(tc)}</span></div>
          <div class="card stat"><span class="k">رصيد آخر المدة</span><span class="v" dir="ltr" style="font-size:20px">${fmtNum(Math.abs(run))} ${run >= 0 ? 'مدين' : 'دائن'}</span></div></div>
        <div class="card table-wrap">${table}</div>`;
      last = { a, r, table, mv: mv.data, ob: num(ob.data) };
    } catch (e) { out.innerHTML = `<div class="notice">${esc(arError(e))}</div>`; }
  };
  v.querySelector('#f-run').onclick = run;
  wireOutput(v, () => last && { title: `كشف حساب: ${last.a.code} — ${last.a.name}`, html: last.table, opts: { subtitle: subtitleRange(last.r) } },
    () => { if (!last) return; let b = last.ob; return { name: `كشف حساب ${last.a.code} - ${last.a.name}.csv`,
      rows: [['التاريخ', 'السند', 'الحساب', 'البيان', 'المرجع', 'مدين', 'دائن', 'الرصيد'], [last.r.from, 'رصيد أول المدة', '', '', '', '', '', b.toFixed(3)]]
        .concat(last.mv.map(m => { b += num(m.debit) - num(m.credit); return [m.entry_date, `${ENTRY_TYPES[m.entry_type].label} ${m.entry_no}`, `${m.account_code} ${m.account_name}`, m.line_description || m.description || '', m.reference || '', num(m.debit).toFixed(3), num(m.credit).toFixed(3), b.toFixed(3)]; })) }; });
  if (pre) run();
}

// ---------------------------------------------------------------------
//  اليومية العامة
// ---------------------------------------------------------------------
async function viewJournalReport(v) {
  if (!guard(v)) return;
  v.innerHTML = `<div class="page-head"><h2>📚 اليومية العامة</h2></div>
    ${rangeBar(`<div class="field"><label>نوع السند</label><select id="f-type"><option value="">الكل</option>${Object.entries(ENTRY_TYPES).map(([k, t]) => `<option value="${k}">${t.label}</option>`).join('')}</select></div>`)}
    <div id="out"></div>`;
  let last = null;
  const run = async () => {
    const r = getRange(v), type = v.querySelector('#f-type').value || null, out = v.querySelector('#out');
    out.innerHTML = '<div class="empty">جاري التحميل…</div>';
    const { data, error } = await sb.rpc('rep_journal', { p_company: S.company.id, p_fy: S.fy.id, p_from: r.from, p_to: r.to, p_type: type });
    if (error) return void (out.innerHTML = `<div class="notice">${esc(arError(error))}</div>`);
    const groups = []; data.forEach(x => { const g = groups.at(-1); if (g && g.id === x.entry_id) g.lines.push(x); else groups.push({ id: x.entry_id, h: x, lines: [x] }); });
    let td = 0, tc = 0;
    const body = groups.map(g => { const d = g.lines.reduce((s, l) => s + num(l.debit), 0); td += d; tc += g.lines.reduce((s, l) => s + num(l.credit), 0);
      return `<tr class="grp"><td>${fmtDate(g.h.entry_date)}</td><td>${ENTRY_TYPES[g.h.entry_type].label} ${g.h.entry_no}${g.h.status === 'reversed' ? ' (معكوس)' : ''}</td><td colspan="4">${esc(g.h.description || '')} ${g.h.party_name ? '— ' + esc(g.h.party_name) : ''} ${g.h.reference ? '— مرجع: ' + esc(g.h.reference) : ''}</td></tr>
        ${g.lines.map(l => `<tr><td></td><td dir="ltr" style="text-align:right">${esc(l.account_code)}</td><td>${esc(l.account_name)}</td><td>${esc(l.line_description || '')}</td><td class="n">${money(num(l.debit))}</td><td class="n">${money(num(l.credit))}</td></tr>`).join('')}`; }).join('');
    const table = `<table class="t pt rep"><thead><tr><th>التاريخ</th><th>السند / الحساب</th><th>اسم الحساب</th><th>البيان</th><th>مدين</th><th>دائن</th></tr></thead>
      <tbody>${body || '<tr><td colspan="6" class="empty">ما في قيود مرحّلة بهالفترة</td></tr>'}</tbody>
      <tfoot><tr class="tot"><td colspan="4">المجموع (${groups.length} قيد)</td><td class="n">${fmtNum(td)}</td><td class="n">${fmtNum(tc)}</td></tr></tfoot></table>`;
    out.innerHTML = `<div class="card table-wrap" style="margin-top:12px">${table}</div>`;
    last = { r, table, data };
  };
  v.querySelector('#f-run').onclick = run;
  wireOutput(v, () => last && { title: 'اليومية العامة', html: last.table, opts: { subtitle: subtitleRange(last.r) } },
    () => last && { name: `اليومية العامة - ${S.company.name}.csv`, rows: [['التاريخ', 'نوع السند', 'رقم السند', 'البيان', 'رقم الحساب', 'اسم الحساب', 'بيان السطر', 'مدين', 'دائن']]
      .concat(last.data.map(x => [x.entry_date, ENTRY_TYPES[x.entry_type].label, x.entry_no, x.description || '', x.account_code, x.account_name, x.line_description || '', num(x.debit).toFixed(3), num(x.credit).toFixed(3)])) });
  run();
}

// ---------------------------------------------------------------------
//  قائمة الدخل والميزانية (من ميزان المراجعة)
// ---------------------------------------------------------------------
function statementRows(kids, T, roots, sign, maxLvl, valueOf) {
  const rows = [];
  const walk = (list) => list.forEach(a => {
    const val = sign * valueOf(T[a.id]);
    if (Math.abs(val) < 0.0005 && !(kids[a.id] || []).some(c => Math.abs(valueOf(T[c.id])) >= 0.0005)) return;
    rows.push(`<tr class="${a.is_group ? 'grp' : ''}"><td style="padding-inline-start:${(a.level - 1) * 18 + 12}px">${esc(a.code)} — ${esc(a.name)}</td><td class="n">${a.is_group && a.level < maxLvl ? '' : fmtNum(val)}</td><td class="n">${a.is_group && a.level < maxLvl ? fmtNum(val) : ''}</td></tr>`);
    if (a.is_group && a.level < maxLvl) walk(kids[a.id] || []);
  });
  walk(roots);
  return rows.join('');
}

async function viewIncome(v) {
  if (!guard(v)) return;
  v.innerHTML = `<div class="page-head"><h2>📈 قائمة الدخل</h2></div>
    ${rangeBar(`<div class="field"><label>التفصيل لغاية المستوى</label><select id="f-lvl"><option value="2">2</option><option value="3" selected>3</option><option value="4">4</option><option value="9">الكل</option></select></div>`)}<div id="out"></div>`;
  let last = null;
  const run = async () => {
    const r = getRange(v), lvl = +v.querySelector('#f-lvl').value, out = v.querySelector('#out');
    out.innerHTML = '<div class="empty">جاري التحميل…</div>';
    try {
      const { kids, T } = await trialData(r.from, r.to);
      const period = (t) => t.pd - t.pc;    // حركة الفترة بس (الإيرادات والمصاريف)
      const rev = (kids.root || []).filter(a => a.category === 'revenue'), exp = (kids.root || []).filter(a => a.category === 'expenses');
      const tRev = -rev.reduce((s, a) => s + period(T[a.id]), 0), tExp = exp.reduce((s, a) => s + period(T[a.id]), 0), net = tRev - tExp;
      const table = `<table class="t pt rep statement"><tbody>
        <tr class="sec"><td colspan="3">الإيرادات</td></tr>${statementRows(kids, T, rev, -1, lvl, period)}
        <tr class="tot"><td>مجموع الإيرادات</td><td></td><td class="n">${fmtNum(tRev)}</td></tr>
        <tr class="sec"><td colspan="3">المصاريف</td></tr>${statementRows(kids, T, exp, 1, lvl, period)}
        <tr class="tot"><td>مجموع المصاريف</td><td></td><td class="n">${fmtNum(tExp)}</td></tr>
        <tr class="net ${net >= 0 ? 'pos' : 'neg'}"><td>${net >= 0 ? 'صافي الربح' : 'صافي الخسارة'}</td><td></td><td class="n">${fmtNum(Math.abs(net))}</td></tr></tbody></table>`;
      out.innerHTML = `<div class="grid cols-3" style="margin:12px 0">
        <div class="card stat"><span class="k">الإيرادات</span><span class="v" dir="ltr">${fmtNum(tRev)}</span></div>
        <div class="card stat"><span class="k">المصاريف</span><span class="v" dir="ltr">${fmtNum(tExp)}</span></div>
        <div class="card stat"><span class="k">${net >= 0 ? 'صافي الربح' : 'صافي الخسارة'}</span><span class="v" dir="ltr" style="color:${net >= 0 ? 'var(--ok)' : 'var(--bad)'}">${fmtNum(Math.abs(net))}</span></div></div>
        <div class="card table-wrap">${table}</div>`;
      last = { r, table, tRev, tExp, net };
    } catch (e) { out.innerHTML = `<div class="notice">${esc(arError(e))}</div>`; }
  };
  v.querySelector('#f-run').onclick = run;
  wireOutput(v, () => last && { title: 'قائمة الدخل', html: last.table, opts: { subtitle: subtitleRange(last.r) } },
    () => last && { name: `قائمة الدخل - ${S.company.name}.csv`, rows: [['البند', 'المبلغ'], ['مجموع الإيرادات', last.tRev.toFixed(3)], ['مجموع المصاريف', last.tExp.toFixed(3)], ['صافي الربح (الخسارة)', last.net.toFixed(3)]] });
  run();
}

async function viewBalanceSheet(v) {
  if (!guard(v)) return;
  v.innerHTML = `<div class="page-head"><h2>🏦 الميزانية العمومية (قائمة المركز المالي)</h2></div>
    ${rangeBar(`<div class="field"><label>التفصيل لغاية المستوى</label><select id="f-lvl"><option value="2">2</option><option value="3" selected>3</option><option value="4">4</option><option value="9">الكل</option></select></div>`)}<div id="out"></div>`;
  v.querySelector('#f-from').closest('.field').style.display = 'none';
  let last = null;
  const run = async () => {
    const r = { from: S.fy.start_date, to: getRange(v).to }, lvl = +v.querySelector('#f-lvl').value, out = v.querySelector('#out');
    out.innerHTML = '<div class="empty">جاري التحميل…</div>';
    try {
      const { kids, T } = await trialData(r.from, r.to);
      const close = (t) => t.close;
      const roots = kids.root || [];
      const by = (c) => roots.filter(a => a.category === c);
      const sumOf = (list) => list.reduce((s, a) => s + close(T[a.id]), 0);
      const tA = sumOf(by('assets')), tL = -sumOf(by('liabilities')), tE = -sumOf(by('equity'));
      const net = -(sumOf(by('revenue')) + sumOf(by('expenses')));   // ربح السنة لغاية التاريخ
      const tLE = tL + tE + net, ok = Math.abs(tA - tLE) < 0.001;
      const table = `<table class="t pt rep statement"><tbody>
        <tr class="sec"><td colspan="3">الموجودات</td></tr>${statementRows(kids, T, by('assets'), 1, lvl, close)}
        <tr class="tot"><td>مجموع الموجودات</td><td></td><td class="n">${fmtNum(tA)}</td></tr>
        <tr class="sec"><td colspan="3">المطلوبات</td></tr>${statementRows(kids, T, by('liabilities'), -1, lvl, close)}
        <tr class="tot"><td>مجموع المطلوبات</td><td></td><td class="n">${fmtNum(tL)}</td></tr>
        <tr class="sec"><td colspan="3">حقوق الملكية</td></tr>${statementRows(kids, T, by('equity'), -1, lvl, close)}
        <tr><td style="padding-inline-start:30px">${net >= 0 ? 'صافي ربح الفترة' : 'صافي خسارة الفترة'} (من قائمة الدخل)</td><td class="n">${fmtNum(net)}</td><td></td></tr>
        <tr class="tot"><td>مجموع حقوق الملكية</td><td></td><td class="n">${fmtNum(tE + net)}</td></tr>
        <tr class="net ${ok ? 'pos' : 'neg'}"><td>مجموع المطلوبات وحقوق الملكية</td><td></td><td class="n">${fmtNum(tLE)}</td></tr></tbody></table>`;
      out.innerHTML = `<div class="notice ${ok ? 'info' : ''}" style="margin-top:12px">${ok ? '✓ الميزانية متوازنة' : `⚠️ الميزانية مش متوازنة، الفرق ${fmtNum(tA - tLE)}`} — كما في ${fmtDate(r.to)}</div>
        <div class="card table-wrap">${table}</div>`;
      last = { r, table, tA, tL, tE, net };
    } catch (e) { out.innerHTML = `<div class="notice">${esc(arError(e))}</div>`; }
  };
  v.querySelector('#f-run').onclick = run;
  wireOutput(v, () => last && { title: 'الميزانية العمومية', html: last.table, opts: { subtitle: `كما في ${fmtDate(last.r.to)} — ${fyLabel()}` } },
    () => last && { name: `الميزانية العمومية - ${S.company.name}.csv`, rows: [['البند', 'المبلغ'], ['مجموع الموجودات', last.tA.toFixed(3)], ['مجموع المطلوبات', last.tL.toFixed(3)], ['حقوق الملكية', last.tE.toFixed(3)], ['صافي ربح الفترة', last.net.toFixed(3)]] });
  run();
}

export const REPORT_ROUTES = {
  'rep-trial': viewTrial, 'rep-ledger': viewLedger, 'rep-journal': viewJournalReport,
  'rep-income': viewIncome, 'rep-balance': viewBalanceSheet,
};
