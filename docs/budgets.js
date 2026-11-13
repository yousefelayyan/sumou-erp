// =====================================================================
//  السمو ERP — الموازنات التقديرية (route budgets | budgets?id=… | budgets?id=…&t=report)
//  قائمة موازنات السنة، محرر 12 شهر لكل حساب (توزيع بالتساوي، تعبئة من فعلي السنة السابقة ± %)،
//  اعتماد/فك اعتماد، وتقرير الموازنة مقابل الفعلي (budget_vs_actual) لفترة من شهور السنة.
// =====================================================================
import { S, sb, esc, fmtNum, num, toast, arError, modal, confirmBox, formData, can, log } from './core.js';
import { loadAccounts, leafAccounts, accLabel } from './finance.js';
import { deptField, deptValue, loadDepartments } from './departments.js';
import { printDoc } from './print.js';

const qp = () => new URLSearchParams(location.hash.split('?')[1] || '');
const MON = ['كانون الثاني', 'شباط', 'آذار', 'نيسان', 'أيار', 'حزيران', 'تموز', 'آب', 'أيلول', 'تشرين الأول', 'تشرين الثاني', 'كانون الأول'];
const months = (fy) => { const d = new Date((fy?.start_date || '2026-01-01') + 'T00:00:00'); return Array.from({ length: 12 }, (_, i) => { const x = new Date(d.getFullYear(), d.getMonth() + i, 1); return `${MON[x.getMonth()]} ${String(x.getFullYear()).slice(2)}`; }); };
const CAT = { revenue: 'الإيرادات', expenses: 'المصاريف', assets: 'الأصول', liabilities: 'الالتزامات', equity: 'حقوق الملكية' };
const r3 = (x) => Math.round(x * 1000) / 1000;

async function viewBudgets(v, ctx) {
  if (!S.company || !S.fy) return void (v.innerHTML = '<div class="notice info">اختار شركة وسنة مالية أول.</div>');
  const id = qp().get('id');
  if (id) return qp().get('t') === 'report' ? budgetReport(v, id) : budgetEditor(v, id);
  const [{ data: rows, error }, { data: ccs }, deps] = await Promise.all([
    sb.from('budgets').select('*').eq('company_id', S.company.id).eq('fiscal_year_id', S.fy.id).order('code'),
    sb.from('cost_centers').select('id,code,name').eq('company_id', S.company.id).order('code'), loadDepartments()]);
  if (error) return void (v.innerHTML = `<div class="notice">${esc(arError(error))}</div>`);
  const ids = (rows || []).map(b => b.id);
  const { data: lines } = ids.length ? await sb.from('budget_lines').select('budget_id,account_id,amounts').in('budget_id', ids) : { data: [] };
  const accs = await loadAccounts(); const accById = Object.fromEntries(accs.map(a => [a.id, a]));
  const tot = (bid, cat) => (lines || []).filter(l => l.budget_id === bid && accById[l.account_id]?.category === cat).reduce((s, l) => s + l.amounts.reduce((a, x) => a + num(x), 0), 0);
  const depName = Object.fromEntries(deps.map(d => [d.id, d.name])), ccName = Object.fromEntries((ccs || []).map(c => [c.id, c.name]));
  v.innerHTML = `<div class="page-head"><h2>📐 الموازنات التقديرية</h2><span class="muted">${esc(S.fy.name || '')}</span><div class="spacer"></div>
      ${can('budgets', 'add') ? '<button class="btn primary" id="add">➕ موازنة جديدة</button>' : ''}</div>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرمز</th><th>الموازنة</th><th>الدائرة / مركز الكلفة</th><th style="text-align:left">الإيرادات</th><th style="text-align:left">المصاريف</th><th style="text-align:left">صافي الربح المتوقع</th><th>الحالة</th><th></th></tr></thead><tbody>
    ${(rows || []).map(b => { const rv = tot(b.id, 'revenue'), ex = tot(b.id, 'expenses');
      return `<tr><td>${esc(b.code)}</td><td><b>${esc(b.name)}</b></td><td>${esc([depName[b.department_id], ccName[b.cost_center_id]].filter(Boolean).join(' / ') || 'كل الشركة')}</td>
        <td class="n">${fmtNum(rv)}</td><td class="n">${fmtNum(ex)}</td><td class="n" style="color:${rv - ex < 0 ? 'var(--bad)' : 'var(--ok)'}"><b>${fmtNum(rv - ex)}</b></td>
        <td>${b.status === 'approved' ? '<span class="badge ok">معتمدة</span>' : '<span class="badge warn">مسودة</span>'}</td>
        <td class="actions"><a class="btn sm" href="#/budgets?id=${b.id}">✏️ ${b.status === 'approved' ? 'عرض' : 'تعديل'}</a> <a class="btn sm" href="#/budgets?id=${b.id}&t=report">📊 مقابل الفعلي</a></td></tr>`; }).join('')
      || '<tr><td colspan="8" class="empty">ما في موازنات لهالسنة. اعمل وحدة وعبّيها من فعلي السنة السابقة بكبسة.</td></tr>'}</tbody></table></div>`;
  v.querySelector('#add')?.addEventListener('click', async () => {
    const dept = await deptField(null, '', false);
    const m = modal({ title: 'موازنة جديدة', body: `<form id="bf"><div class="grid cols-2">
      <div class="field"><label>الرمز</label><input name="code" value="${String((rows || []).length + 1).padStart(2, '0')}"></div>
      <div class="field"><label>الاسم</label><input name="name" value="${(rows || []).length ? '' : 'الموازنة العامة'}"></div>
      ${dept}${(ccs || []).length ? `<div class="field"><label>مركز الكلفة (اختياري)</label><select name="cost_center_id"><option value="">— كل المراكز —</option>${ccs.map(c => `<option value="${c.id}">${esc(c.code)} — ${esc(c.name)}</option>`).join('')}</select></div>` : ''}
      <div class="field" style="grid-column:span 2"><label>ملاحظات</label><input name="notes"></div></div>
      <p class="muted" style="font-size:12px">الدائرة ومركز الكلفة اختياريين: إذا اخترتهم، الفعلي بالمقارنة بيكون لهالدائرة (وفروعها) أو هالمركز بس.</p></form>`,
      foot: '<button class="btn primary" data-save>💾 حفظ وفتح</button><button class="btn" data-close>إلغاء</button>' });
    m.el.querySelector('[data-save]').onclick = async () => {
      const f = m.el.querySelector('#bf'), d = formData(f);
      if (!d.code?.trim() || !d.name?.trim()) return toast('الرمز والاسم مطلوبين', 'err');
      const { data, error: e } = await sb.from('budgets').insert({ company_id: S.company.id, fiscal_year_id: S.fy.id, code: d.code.trim(), name: d.name.trim(), notes: d.notes || null,
        cost_center_id: d.cost_center_id || null, ...deptValue(f) }).select('id').single();
      if (e) return toast(arError(e), 'err');
      await log('إضافة', 'budgets', data.id, { name: d.name }); m.close(); location.hash = `#/budgets?id=${data.id}`;
    };
  });
}

async function budgetEditor(v, id) {
  const [{ data: b, error }, { data: lines }, accs] = await Promise.all([sb.from('budgets').select('*').eq('id', id).single(),
    sb.from('budget_lines').select('*').eq('budget_id', id), loadAccounts()]);
  if (error) return void (v.innerHTML = `<div class="notice">${esc(arError(error))}</div>`);
  const fy = (S.fiscalYearsAll || []).find(y => y.id === b.fiscal_year_id) || S.fy, mn = months(fy);
  const accById = Object.fromEntries(accs.map(a => [a.id, a])), leaf = leafAccounts(accs);
  const ro = b.status === 'approved' || !can('budgets', 'edit');
  const ord = { revenue: 1, expenses: 2, assets: 3, liabilities: 4, equity: 5 };
  let rows = (lines || []).map(l => ({ account_id: l.account_id, a: l.amounts.map(num) }))
    .sort((x, y) => (ord[accById[x.account_id]?.category] || 9) - (ord[accById[y.account_id]?.category] || 9) || String(accById[x.account_id]?.code).localeCompare(String(accById[y.account_id]?.code)));
  let dirty = false;
  v.innerHTML = `<div class="page-head"><a class="btn sm" href="#/budgets">→ الموازنات</a><h2>📐 ${esc(b.code)} — ${esc(b.name)}</h2>
      ${b.status === 'approved' ? '<span class="badge ok">معتمدة</span>' : '<span class="badge warn">مسودة</span>'}<div class="spacer"></div>
      <a class="btn" href="#/budgets?id=${id}&t=report">📊 مقابل الفعلي</a>
      ${can('budgets', 'post') ? `<button class="btn" id="st">${b.status === 'approved' ? '🔓 فك الاعتماد' : '✅ اعتماد'}</button>` : ''}
      ${!ro ? '<button class="btn primary" id="save">💾 حفظ</button>' : ''}
      ${b.status === 'draft' && can('budgets', 'delete') ? '<button class="btn danger" id="del">حذف</button>' : ''}</div>
    ${ro && b.status === 'approved' ? '<div class="notice info">الموازنة معتمدة ومقفولة. لتعديلها فك الاعتماد أول.</div>' : ''}
    ${!ro ? `<div class="card" style="display:flex;gap:8px;flex-wrap:wrap;align-items:end;margin-bottom:10px">
      <div class="field" style="margin:0;flex:1;min-width:260px"><label>إضافة حساب</label><input id="add-acc" list="bacc" placeholder="اكتب رمز أو اسم الحساب"><datalist id="bacc">${leaf.map(a => `<option value="${esc(accLabel(a))}"></option>`).join('')}</datalist></div>
      <button class="btn" id="add-cat" data-c="revenue">➕ كل حسابات الإيرادات</button><button class="btn" id="add-cat2" data-c="expenses">➕ كل حسابات المصاريف</button>
      <span style="border-inline-start:1px solid var(--line,#ddd);height:32px"></span>
      <div class="field" style="margin:0;width:110px"><label>نسبة ±%</label><input id="fill-pct" type="number" value="0" step="1"></div>
      <button class="btn" id="fill">📥 تعبئة من فعلي السنة السابقة</button></div>` : ''}
    <div class="card table-wrap" style="overflow-x:auto"><table class="t bud-grid"><thead><tr><th style="min-width:220px">الحساب</th>${mn.map(m => `<th>${m}</th>`).join('')}<th>المجموع</th>${!ro ? '<th></th>' : ''}</tr></thead><tbody id="bg"></tbody><tfoot id="bt"></tfoot></table></div>
    <p class="muted" style="font-size:12px">اكتب المبلغ السنوي بخانة «المجموع» وبيتوزّع بالتساوي على الشهور. الإيرادات والمصاريف بيتجمّعوا تحت لحالهم.</p>`;
  const tb = v.querySelector('#bg'), tf = v.querySelector('#bt');
  const sumCat = (c) => { const t = Array(12).fill(0); rows.filter(r => accById[r.account_id]?.category === c).forEach(r => r.a.forEach((x, i) => t[i] += num(x))); return t; };
  const draw = () => {
    let cat = '';
    tb.innerHTML = rows.map((r, i) => { const a = accById[r.account_id], head = a?.category !== cat ? (cat = a?.category, `<tr class="grp"><td colspan="${ro ? 14 : 15}"><b>${CAT[cat] || ''}</b></td></tr>`) : '';
      return `${head}<tr><td>${esc(accLabel(a))}</td>${r.a.map((x, k) => `<td><input class="cell n" data-i="${i}" data-m="${k}" value="${x || ''}" inputmode="decimal" ${ro ? 'disabled' : ''}></td>`).join('')}
        <td><input class="cell n tot" data-i="${i}" data-t="1" value="${r3(r.a.reduce((s, x) => s + num(x), 0)) || ''}" inputmode="decimal" ${ro ? 'disabled' : ''} title="المجموع السنوي — غيّره ليتوزّع بالتساوي"></td>
        ${!ro ? `<td><button class="x" type="button" data-rm="${i}">×</button></td>` : ''}</tr>`; }).join('') || `<tr><td colspan="15" class="empty">ضيف حسابات أو عبّي من السنة السابقة</td></tr>`;
    const rv = sumCat('revenue'), ex = sumCat('expenses'), line = (l, t, c = '') => `<tr><th style="${c}">${l}</th>${t.map(x => `<th class="n" style="${c}">${fmtNum(x)}</th>`).join('')}<th class="n" style="${c}">${fmtNum(t.reduce((s, x) => s + x, 0))}</th>${!ro ? '<th></th>' : ''}</tr>`;
    tf.innerHTML = line('مجموع الإيرادات', rv) + line('مجموع المصاريف', ex) + line('صافي الربح المتوقع', rv.map((x, k) => x - ex[k]), 'color:var(--brand)');
  };
  draw();
  tb.addEventListener('change', (e) => { const t = e.target, r = rows[+t.dataset.i]; if (!r) return; dirty = true;
    if (t.dataset.t) { const total = num(t.value), each = Math.floor(total / 12 * 1000) / 1000; r.a = Array(12).fill(each); r.a[11] = r3(total - each * 11); }
    else r.a[+t.dataset.m] = num(t.value);
    draw(); });
  tb.addEventListener('click', (e) => { const b2 = e.target.closest('[data-rm]'); if (!b2) return; rows.splice(+b2.dataset.rm, 1); dirty = true; draw(); });
  const addAcc = (a) => { if (!a || rows.some(r => r.account_id === a.id)) return false; rows.push({ account_id: a.id, a: Array(12).fill(0) }); dirty = true; return true; };
  const resort = () => rows.sort((x, y) => (ord[accById[x.account_id]?.category] || 9) - (ord[accById[y.account_id]?.category] || 9) || String(accById[x.account_id]?.code).localeCompare(String(accById[y.account_id]?.code)));
  v.querySelector('#add-acc')?.addEventListener('change', (e) => { const c = e.target.value.split('—')[0].trim(); const a = leaf.find(x => x.code === c) || leaf.find(x => x.name === e.target.value.trim());
    if (!a) return toast('الحساب مش موجود أو مش فرعي', 'err'); if (!addAcc(a)) toast('الحساب موجود بالموازنة', 'err'); e.target.value = ''; resort(); draw(); });
  v.querySelectorAll('[data-c]').forEach(bt => bt.addEventListener('click', () => { let n = 0; leaf.filter(a => a.category === bt.dataset.c).forEach(a => { if (addAcc(a)) n++; }); resort(); draw(); toast(`انضاف ${n} حساب`, 'ok'); }));
  const save = async (quiet) => {
    const { error: se } = await sb.rpc('budget_save_lines', { p_budget: id, p_lines: rows.map(r => ({ account_id: r.account_id, amounts: r.a.map(x => r3(num(x))) })) });
    if (se) { toast(arError(se), 'err'); return false; }
    dirty = false; if (!quiet) { await log('تعديل', 'budgets', id, { name: b.name }); toast('تم الحفظ', 'ok'); } return true;
  };
  v.querySelector('#save')?.addEventListener('click', () => save());
  v.querySelector('#fill')?.addEventListener('click', async () => {
    if (dirty && !(await save(true))) return;
    const pct = num(v.querySelector('#fill-pct').value);
    const replace = rows.length ? await confirmBox(`في ${rows.length} حساب بالموازنة. بدك تمسحهم وتعبّي من جديد؟ (لا = بتنضاف الحسابات الناقصة بس)`) : true;
    const { data, error: e } = await sb.rpc('budget_fill', { p_budget: id, p_pct: pct, p_replace: replace });
    if (e) return toast(arError(e), 'err');
    toast(`تعبّى ${data} حساب من فعلي السنة السابقة${pct ? ` (${pct > 0 ? '+' : ''}${pct}%)` : ''}`, 'ok'); budgetEditor(v, id);
  });
  v.querySelector('#st')?.addEventListener('click', async () => {
    if (dirty && !(await save(true))) return;
    const { error: e } = await sb.rpc('budget_set_status', { p_id: id, p_status: b.status === 'approved' ? 'draft' : 'approved' });
    if (e) return toast(arError(e), 'err'); toast(b.status === 'approved' ? 'انفك الاعتماد' : 'اعتمدت الموازنة', 'ok'); budgetEditor(v, id);
  });
  v.querySelector('#del')?.addEventListener('click', async () => {
    if (!(await confirmBox(`حذف الموازنة «${b.name}»؟`))) return;
    const { error: e } = await sb.from('budgets').delete().eq('id', id); if (e) return toast(arError(e), 'err');
    await log('حذف', 'budgets', id, { name: b.name }); location.hash = '#/budgets';
  });
}

async function budgetReport(v, id) {
  const [{ data: b, error }, { data: rows, error: e2 }, accs] = await Promise.all([sb.from('budgets').select('*').eq('id', id).single(),
    sb.rpc('budget_vs_actual', { p_budget: id }), loadAccounts()]);
  if (error || e2) return void (v.innerHTML = `<div class="notice">${esc(arError(error || e2))}</div>`);
  const fy = (S.fiscalYearsAll || []).find(y => y.id === b.fiscal_year_id) || S.fy, mn = months(fy);
  const accById = Object.fromEntries(accs.map(a => [a.id, a]));
  const cur = (() => { const s = new Date(fy.start_date + 'T00:00:00'), t = new Date(); const k = (t.getFullYear() - s.getFullYear()) * 12 + t.getMonth() - s.getMonth() + 1; return Math.min(12, Math.max(1, k)); })();
  v.innerHTML = `<div class="page-head"><a class="btn sm" href="#/budgets">→ الموازنات</a><h2>📊 ${esc(b.name)}: الموازنة مقابل الفعلي</h2><div class="spacer"></div>
      <a class="btn" href="#/budgets?id=${id}">✏️ الموازنة</a><button class="btn" id="pr">🖨️ طباعة</button></div>
    <div class="card" style="display:flex;gap:8px;flex-wrap:wrap;align-items:end;margin-bottom:10px">
      <div class="field" style="margin:0"><label>من شهر</label><select id="m1">${mn.map((m, i) => `<option value="${i + 1}">${m}</option>`).join('')}</select></div>
      <div class="field" style="margin:0"><label>لشهر</label><select id="m2">${mn.map((m, i) => `<option value="${i + 1}" ${i + 1 === cur ? 'selected' : ''}>${m}</option>`).join('')}</select></div>
      <div class="field" style="margin:0"><label>العرض</label><select id="lv"><option value="d">تفصيلي (كل حساب)</option><option value="p">حسب الحساب الرئيسي</option></select></div>
      <label class="check" style="margin:0 0 8px"><input type="checkbox" id="ub" checked> حسابات بدون موازنة إلها فعلي</label></div>
    <div id="cards" style="display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:10px;margin-bottom:10px"></div>
    <div class="card table-wrap" id="tbl"></div>
    <div class="card table-wrap" style="margin-top:10px" id="mon"></div>`;
  const parentOf = (a) => accById[a?.parent_id] || a;
  const draw = () => {
    const m1 = +v.querySelector('#m1').value, m2 = Math.max(m1, +v.querySelector('#m2').value), lv = v.querySelector('#lv').value, ub = v.querySelector('#ub').checked;
    const agg = {};
    (rows || []).filter(r => r.mon >= m1 && r.mon <= m2).forEach(r => { const a = accById[r.account_id]; if (!a) return; const k = lv === 'p' ? parentOf(a).id : a.id;
      const o = agg[k] ||= { acc: lv === 'p' ? parentOf(a) : a, cat: a.category, b: 0, x: 0 }; o.b += num(r.budget); o.x += num(r.actual); });
    let list = Object.values(agg).filter(o => ub || Math.abs(o.b) > 0.0005);
    const cats = ['revenue', 'expenses', 'assets', 'liabilities', 'equity'].filter(c => list.some(o => o.cat === c));
    const sum = (c, k) => list.filter(o => o.cat === c).reduce((s, o) => s + o[k], 0);
    const rb = sum('revenue', 'b'), rx = sum('revenue', 'x'), eb = sum('expenses', 'b'), ex = sum('expenses', 'x');
    const card = (l, a, b2, good) => { const p = b2 ? a / b2 * 100 : null; return `<div class="card" style="padding:12px"><div class="muted" style="font-size:12px">${l}</div>
      <div style="font-size:20px;font-weight:800">${fmtNum(a)}</div><div class="muted" style="font-size:12px">من ${fmtNum(b2)}${p != null ? ` · <b style="color:${good(a, b2) ? 'var(--ok)' : 'var(--bad)'}">${Math.round(p)}%</b>` : ''}</div></div>`; };
    v.querySelector('#cards').innerHTML = card('الإيرادات الفعلية', rx, rb, (a, b2) => a >= b2) + card('المصاريف الفعلية', ex, eb, (a, b2) => a <= b2) + card('صافي الربح الفعلي', rx - ex, rb - eb, (a, b2) => a >= b2);
    const row = (o) => { const d = o.x - o.b, p = o.b ? o.x / o.b * 100 : null, good = o.cat === 'revenue' ? d >= 0 : d <= 0;
      return `<tr><td>${esc(accLabel(o.acc))}</td><td class="n">${fmtNum(o.b)}</td><td class="n">${fmtNum(o.x)}</td><td class="n" style="color:${Math.abs(d) < 0.0005 ? '' : good ? 'var(--ok)' : 'var(--bad)'}">${fmtNum(d)}</td>
        <td>${p == null ? '<span class="muted">بدون موازنة</span>' : `<div class="bud-bar"><span style="width:${Math.min(100, Math.max(0, p))}%;background:${good ? 'var(--ok)' : 'var(--bad)'}"></span><b>${Math.round(p)}%</b></div>`}</td></tr>`; };
    const head = '<thead><tr><th>الحساب</th><th style="text-align:left">الموازنة</th><th style="text-align:left">الفعلي</th><th style="text-align:left">الفرق</th><th style="min-width:160px">نسبة التحقيق</th></tr></thead>';
    v.querySelector('#tbl').innerHTML = `<h4 style="margin:0 0 8px">${mn[m1 - 1]}${m2 > m1 ? ' — ' + mn[m2 - 1] : ''}</h4><table class="t">${head}<tbody>
      ${cats.map(c => { const l = list.filter(o => o.cat === c).sort((a, b2) => String(a.acc.code).localeCompare(String(b2.acc.code)));
        return `<tr class="grp"><td colspan="5"><b>${CAT[c]}</b></td></tr>${l.map(row).join('')}<tr><th>مجموع ${CAT[c]}</th><th class="n">${fmtNum(sum(c, 'b'))}</th><th class="n">${fmtNum(sum(c, 'x'))}</th><th class="n">${fmtNum(sum(c, 'x') - sum(c, 'b'))}</th><th></th></tr>`; }).join('')
        || '<tr><td colspan="5" class="empty">ما في أرقام بهالفترة</td></tr>'}</tbody>
      ${cats.includes('revenue') || cats.includes('expenses') ? `<tfoot><tr><th>صافي الربح</th><th class="n">${fmtNum(rb - eb)}</th><th class="n">${fmtNum(rx - ex)}</th><th class="n">${fmtNum((rx - ex) - (rb - eb))}</th><th></th></tr></tfoot>` : ''}</table>`;
    const per = (c, k, i) => (rows || []).filter(r => r.mon === i && accById[r.account_id]?.category === c && (ub || Math.abs(num(r.budget)) > 0.0005 || (rows || []).some(x => x.account_id === r.account_id && Math.abs(num(x.budget)) > 0.0005))).reduce((s, r) => s + num(r[k]), 0);
    v.querySelector('#mon').innerHTML = `<h4 style="margin:0 0 8px">شهر بشهر</h4><table class="t"><thead><tr><th></th>${mn.map(m => `<th>${m}</th>`).join('')}</tr></thead><tbody>
      ${[['موازنة الإيرادات', 'revenue', 'budget'], ['الإيرادات الفعلية', 'revenue', 'actual'], ['موازنة المصاريف', 'expenses', 'budget'], ['المصاريف الفعلية', 'expenses', 'actual']]
        .map(([l, c, k]) => `<tr><td>${l}</td>${mn.map((_, i) => `<td class="n">${fmtNum(per(c, k, i + 1))}</td>`).join('')}</tr>`).join('')}
      <tr><th>صافي الربح (موازنة)</th>${mn.map((_, i) => `<th class="n">${fmtNum(per('revenue', 'budget', i + 1) - per('expenses', 'budget', i + 1))}</th>`).join('')}</tr>
      <tr><th>صافي الربح (فعلي)</th>${mn.map((_, i) => `<th class="n">${fmtNum(per('revenue', 'actual', i + 1) - per('expenses', 'actual', i + 1))}</th>`).join('')}</tr></tbody></table>`;
  };
  draw();
  ['#m1', '#m2', '#lv', '#ub'].forEach(s => v.querySelector(s).addEventListener('change', draw));
  v.querySelector('#pr').addEventListener('click', () => printDoc(`${b.name}: الموازنة مقابل الفعلي`, v.querySelector('#tbl').innerHTML.replace(/class="t"/g, 'class="pt"') + v.querySelector('#mon').innerHTML.replace(/class="t"/g, 'class="pt"'), { landscape: true }));
}

export const BUDGET_ROUTES = { budgets: viewBudgets };
