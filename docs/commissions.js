// =====================================================================
//  السمو ERP — عمولات المندوبين (route commissions?t=report|targets|plans)
//  report: rep_commissions لكل مندوب وشهر. targets: أهداف شهرية (rep_targets). plans: خطط العمولة بالشرائح (commission_plans) وربطها بالمندوبين.
// =====================================================================
import { S, sb, esc, fmtNum, num, today, toast, arError, modal, confirmBox, can } from './core.js';
import { loadLookups } from './lookups.js';
import { downloadCSV } from './finance.js';
import { printDoc } from './print.js';

const MONTHS = ['كانون الثاني', 'شباط', 'آذار', 'نيسان', 'أيار', 'حزيران', 'تموز', 'آب', 'أيلول', 'تشرين الأول', 'تشرين الثاني', 'كانون الأول'];
const mName = (d) => { const [y, m] = String(d).split('-'); return `${MONTHS[+m - 1]} ${y}`; };
const BASIS = { sales: 'صافي المبيعات (قبل الضريبة)', collections: 'التحصيل (الدفعات الموزّعة على فواتيره)' };
const reps = (lk) => lk.filter(r => r.kind === 'sales_rep');

async function viewCommissions(v) {
  if (!S.company || !S.fy) return void (v.innerHTML = '<div class="notice info">اختار شركة وسنة مالية أول.</div>');
  const t = new URLSearchParams(location.hash.split('?')[1] || '').get('t') || 'report';
  const head = `<div class="page-head"><h2>💼 عمولات المندوبين</h2></div>
    <div class="tabs" style="margin-bottom:10px">${[['report', '📊 العمولات'], ['targets', '🎯 الأهداف الشهرية'], ['plans', '📐 خطط العمولة']].map(([k, l]) => `<a class="tab ${t === k ? 'active' : ''}" href="#/commissions?t=${k}">${l}</a>`).join('')}</div>`;
  const lk = await loadLookups(true);
  if (t === 'targets') return targetsTab(v, head, lk);
  if (t === 'plans') return plansTab(v, head, lk);
  return reportTab(v, head, lk);
}

async function reportTab(v, head, lk) {
  const R = Object.fromEntries(reps(lk).map(r => [r.id, r]));
  const from0 = S.fy.start_date, to0 = today() >= S.fy.start_date && today() <= S.fy.end_date ? today() : S.fy.end_date;
  v.innerHTML = `${head}<div class="card no-print filters">
      <div class="field"><label>من</label><input type="date" id="c-from" value="${from0}"></div><div class="field"><label>إلى</label><input type="date" id="c-to" value="${to0}"></div>
      <div class="field"><label>المندوب</label><select id="c-rep"><option value="">الكل</option>${reps(lk).map(r => `<option value="${r.id}">${esc(r.name)}</option>`).join('')}</select></div>
      <div class="field"><label>العرض</label><select id="c-mode"><option value="month">كل شهر</option><option value="sum">مجموع الفترة لكل مندوب</option></select></div>
      <div class="field" style="justify-content:flex-end"><button class="btn primary" id="c-run">عرض</button></div>
      <div class="field" style="justify-content:flex-end;flex-direction:row;gap:6px">${can('reports', 'print') || can('rep_commissions', 'print') ? '<button class="btn" id="c-print">🖨️ طباعة</button>' : ''}<button class="btn" id="c-csv">⬇️ Excel</button></div></div>
    <div id="c-out"></div>`;
  let last = null;
  const run = async () => {
    const from = v.querySelector('#c-from').value, to = v.querySelector('#c-to').value, rep = v.querySelector('#c-rep').value, mode = v.querySelector('#c-mode').value;
    const { data, error } = await sb.rpc('rep_commissions', { p_company: S.company.id, p_from: from, p_to: to });
    if (error) return void (v.querySelector('#c-out').innerHTML = `<div class="notice">${esc(arError(error))}</div>`);
    let rows = (data || []).filter(r => !rep || r.rep_id === rep);
    if (mode === 'sum') {
      const by = {}; rows.forEach(r => { const g = (by[r.rep_id] ||= { rep_id: r.rep_id, basis: r.basis, target: 0, net_sales: 0, collections: 0, base: 0, commission: 0, bonus: 0, total: 0, months: 0, hasT: false });
        ['net_sales', 'collections', 'base', 'commission', 'bonus', 'total'].forEach(k => g[k] += num(r[k])); if (r.target != null) { g.target += num(r.target); g.hasT = true; } g.months++; });
      rows = Object.values(by).map(g => ({ ...g, target: g.hasT ? g.target : null, achieved_pct: g.hasT && g.target > 0 ? g.base * 100 / g.target : null, rate: g.base ? g.commission * 100 / g.base : 0 }));
    }
    const T = rows.reduce((a, r) => { ['net_sales', 'collections', 'commission', 'bonus', 'total'].forEach(k => a[k] = (a[k] || 0) + num(r[k])); return a; }, {});
    const pct = (x) => x == null ? '<span class="muted">بدون هدف</span>' : `<span class="badge ${x >= 100 ? 'ok' : x >= 80 ? 'warn' : 'bad'}">${(Math.round(x * 10) / 10)}%</span>`;
    const table = `<table class="t pt rep"><thead><tr>${mode === 'month' ? '<th>الشهر</th>' : ''}<th>المندوب</th><th>الأساس</th><th>الهدف</th><th>صافي المبيعات</th><th>التحصيل</th><th>نسبة التحقيق</th><th>نسبة العمولة</th><th>العمولة</th><th>المكافأة</th><th>المستحق</th></tr></thead><tbody>
      ${rows.map(r => `<tr>${mode === 'month' ? `<td>${mName(r.month)}</td>` : ''}<td><b>${esc(R[r.rep_id]?.name || '')}</b></td><td style="font-size:12px">${r.basis === 'collections' ? 'التحصيل' : 'المبيعات'}</td>
        <td class="n">${r.target != null ? fmtNum(r.target) : '—'}</td><td class="n">${fmtNum(r.net_sales)}</td><td class="n">${fmtNum(r.collections)}</td><td>${pct(r.achieved_pct)}</td>
        <td class="n">${Math.round(num(r.rate) * 100) / 100}%</td><td class="n">${fmtNum(r.commission)}</td><td class="n">${num(r.bonus) ? fmtNum(r.bonus) : ''}</td><td class="n"><b>${fmtNum(r.total)}</b></td></tr>`).join('')
        || `<tr><td colspan="11" class="empty">ما في مبيعات أو أهداف للمندوبين بالفترة</td></tr>`}</tbody>
      ${rows.length ? `<tfoot><tr class="tot"><td colspan="${mode === 'month' ? 4 : 3}">المجموع</td><td class="n">${fmtNum(T.net_sales)}</td><td class="n">${fmtNum(T.collections)}</td><td colspan="2"></td><td class="n">${fmtNum(T.commission)}</td><td class="n">${fmtNum(T.bonus)}</td><td class="n">${fmtNum(T.total)}</td></tr></tfoot>` : ''}</table>`;
    v.querySelector('#c-out').innerHTML = `<div class="card table-wrap" style="margin-top:12px">${table}</div>
      <p class="muted" style="font-size:13px">صافي المبيعات = فواتير البيع المرحّلة ناقص المرتجعات (قبل الضريبة) حسب مندوب الفاتورة. التحصيل = الدفعات الموزّعة على فواتير المندوب بشهر الدفعة. النسبة من شرائح خطة المندوب حسب تحقيق الهدف، والمندوب بدون خطة بياخذ نسبته الثابتة من «إعداد ← مندوبي المبيعات».</p>`;
    last = { table, sub: `من ${from} لـ ${to}`, csv: [[...(mode === 'month' ? ['الشهر'] : []), 'المندوب', 'الهدف', 'صافي المبيعات', 'التحصيل', 'نسبة التحقيق', 'نسبة العمولة', 'العمولة', 'المكافأة', 'المستحق']]
      .concat(rows.map(r => [...(mode === 'month' ? [r.month] : []), R[r.rep_id]?.name || '', r.target ?? '', num(r.net_sales).toFixed(3), num(r.collections).toFixed(3), r.achieved_pct ?? '', num(r.rate), num(r.commission).toFixed(3), num(r.bonus).toFixed(3), num(r.total).toFixed(3)])) };
  };
  v.querySelector('#c-run').onclick = run;
  v.querySelector('#c-print')?.addEventListener('click', () => last && printDoc('عمولات المندوبين', last.table, { subtitle: last.sub, landscape: true }));
  v.querySelector('#c-csv').onclick = () => last && downloadCSV('عمولات المندوبين.csv', last.csv);
  run();
}

async function targetsTab(v, head, lk) {
  const year = +(new URLSearchParams(location.hash.split('?')[1] || '').get('y') || S.fy.start_date.slice(0, 4));
  const list = reps(lk).filter(r => r.is_active), ed = can('rep_commissions', 'edit');
  const { data: tg, error } = await sb.from('rep_targets').select('*').eq('company_id', S.company.id).gte('month', `${year}-01-01`).lte('month', `${year}-12-01`);
  if (error) return void (v.innerHTML = `${head}<div class="notice">${esc(arError(error))}</div>`);
  const val = {}; (tg || []).forEach(t => val[`${t.rep_id}|${+t.month.slice(5, 7)}`] = num(t.target));
  v.innerHTML = `${head}<div class="card"><div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:8px">
      <a class="btn sm" href="#/commissions?t=targets&y=${year - 1}">→ ${year - 1}</a><b style="font-size:17px">أهداف ${year}</b><a class="btn sm" href="#/commissions?t=targets&y=${year + 1}">${year + 1} ←</a>
      <div class="spacer"></div>${ed ? '<button class="btn primary" id="t-save">💾 حفظ الأهداف</button>' : ''}</div>
    <p class="muted" style="margin-top:0;font-size:13px">الهدف بالدينار لكل شهر (بنفس أساس خطة المندوب: مبيعات أو تحصيل). اكتب رقم بأول خانة واضغط «⇐ كل الأشهر» لتعبئة السنة. الفاضي = بدون هدف.</p>
    <div class="table-wrap"><table class="t"><thead><tr><th>المندوب</th>${MONTHS.map(m => `<th style="font-size:11.5px">${m}</th>`).join('')}<th>المجموع</th></tr></thead><tbody>
    ${list.map(r => `<tr data-rep="${r.id}"><td><b>${esc(r.name)}</b>${ed ? ` <button type="button" class="btn sm" data-fillrow title="انسخ أول شهر لكل الأشهر">⇐ كل الأشهر</button>` : ''}</td>
      ${MONTHS.map((_, i) => `<td><input class="cell n" data-m="${i + 1}" value="${val[`${r.id}|${i + 1}`] ?? ''}" inputmode="decimal" style="width:80px" ${ed ? '' : 'disabled'}></td>`).join('')}<td class="n" data-sum></td></tr>`).join('')
      || '<tr><td colspan="14" class="empty">ما في مندوبين — ضيفهم من «إعداد ← مندوبي المبيعات»</td></tr>'}</tbody></table></div></div>`;
  const sums = () => v.querySelectorAll('tr[data-rep]').forEach(tr => tr.querySelector('[data-sum]').textContent = fmtNum([...tr.querySelectorAll('[data-m]')].reduce((s, i) => s + num(i.value), 0)));
  sums(); v.addEventListener('input', sums);
  v.querySelectorAll('[data-fillrow]').forEach(b => b.onclick = () => { const tr = b.closest('tr'), ins = [...tr.querySelectorAll('[data-m]')]; ins.forEach(i => i.value = ins[0].value); sums(); });
  v.querySelector('#t-save')?.addEventListener('click', async (e) => {
    const up = [], del = [];
    v.querySelectorAll('tr[data-rep]').forEach(tr => tr.querySelectorAll('[data-m]').forEach(i => {
      const m = `${year}-${String(i.dataset.m).padStart(2, '0')}-01`, key = `${tr.dataset.rep}|${+i.dataset.m}`;
      if (i.value.trim() === '') { if (key in val) del.push({ rep: tr.dataset.rep, m }); }
      else up.push({ company_id: S.company.id, rep_id: tr.dataset.rep, month: m, target: num(i.value) });
    }));
    if (up.some(x => x.target < 0)) return toast('الهدف ما بيكون سالب', 'err');
    e.target.disabled = true;
    if (up.length) { const r = await sb.from('rep_targets').upsert(up, { onConflict: 'rep_id,month' }); if (r.error) { e.target.disabled = false; return toast(arError(r.error), 'err'); } }
    for (const d of del) await sb.from('rep_targets').delete().eq('rep_id', d.rep).eq('month', d.m);
    e.target.disabled = false; toast('انحفظت الأهداف', 'ok'); targetsTab(v, head, lk);
  });
}

async function plansTab(v, head, lk) {
  const { data: plans, error } = await sb.from('commission_plans').select('*').eq('company_id', S.company.id).order('code');
  if (error) return void (v.innerHTML = `${head}<div class="notice">${esc(arError(error))}</div>`);
  const ed = can('rep_commissions', 'edit'), edRep = can('lookups', 'edit');
  const tiersTxt = (p) => (p.tiers || []).slice().sort((a, b) => a.min_pct - b.min_pct).map(t => `من ${t.min_pct}% ← ${t.rate}%`).join(' · ');
  v.innerHTML = `${head}<div class="card"><div style="display:flex;align-items:center;margin-bottom:6px"><h3 style="margin:0">📐 الخطط</h3><div class="spacer"></div>${ed ? '<button class="btn primary sm" data-new>➕ خطة جديدة</button>' : ''}</div>
    <div class="table-wrap"><table class="t"><thead><tr><th>الرمز</th><th>الخطة</th><th>الأساس</th><th>الشرائح (نسبة التحقيق ← العمولة)</th><th>بدون هدف</th><th>المكافأة</th><th>الحالة</th></tr></thead><tbody>
    ${(plans || []).map(p => `<tr class="click" data-open="${p.id}"><td>${esc(p.code)}</td><td><b>${esc(p.name)}</b></td><td style="font-size:12.5px">${BASIS[p.basis]}</td><td style="font-size:12.5px">${esc(tiersTxt(p)) || '—'}</td>
      <td class="n">${num(p.no_target_rate)}%</td><td style="font-size:12.5px">${p.bonus_at_pct ? `${fmtNum(p.bonus_amount)} عند ${num(p.bonus_at_pct)}%` : '—'}</td><td>${p.is_active ? '<span class="badge ok">فعّالة</span>' : '<span class="badge">موقوفة</span>'}</td></tr>`).join('')
      || '<tr><td colspan="7" class="empty">ما في خطط — المندوب بياخذ نسبته الثابتة</td></tr>'}</tbody></table></div></div>
    <div class="card"><h3 style="margin-top:0">🧑‍💼 خطة كل مندوب</h3>
    <div class="table-wrap"><table class="t"><thead><tr><th>المندوب</th><th>النسبة الثابتة (بدون خطة)</th><th>الخطة</th></tr></thead><tbody>
    ${reps(lk).filter(r => r.is_active).map(r => `<tr><td><b>${esc(r.name)}</b></td><td class="n">${num(r.rate)}%</td><td><select data-rep="${r.id}" ${edRep ? '' : 'disabled'}><option value="">— نسبة ثابتة —</option>${(plans || []).filter(p => p.is_active || p.id === r.commission_plan_id).map(p => `<option value="${p.id}" ${p.id === r.commission_plan_id ? 'selected' : ''}>${esc(p.code)} — ${esc(p.name)}</option>`).join('')}</select></td></tr>`).join('')
      || '<tr><td colspan="3" class="empty">ما في مندوبين</td></tr>'}</tbody></table></div>
    ${edRep ? '' : '<p class="muted" style="font-size:12.5px">تغيير خطة المندوب بدها صلاحية تعديل قوائم الإعداد.</p>'}</div>`;
  v.querySelectorAll('select[data-rep]').forEach(s => s.onchange = async () => {
    const { error: e2 } = await sb.from('lookups').update({ commission_plan_id: s.value || null }).eq('id', s.dataset.rep);
    if (e2) return toast(arError(e2), 'err'); S._lk = null; toast('انحفظت خطة المندوب', 'ok');
  });
  const open = (p) => {
    const p0 = p || { code: String((plans || []).length + 1).padStart(2, '0'), name: '', basis: 'sales', tiers: [{ min_pct: 0, rate: 0 }, { min_pct: 80, rate: 2 }, { min_pct: 100, rate: 3 }], no_target_rate: 1, bonus_at_pct: null, bonus_amount: 0, is_active: true };
    const dis = ed ? '' : 'disabled';
    const tierRow = (t = {}) => `<tr><td><input class="cell n" data-k="min" value="${t.min_pct ?? ''}" inputmode="decimal" ${dis}></td><td><input class="cell n" data-k="rate" value="${t.rate ?? ''}" inputmode="decimal" ${dis}></td><td>${ed ? '<button type="button" class="x" data-rm>×</button>' : ''}</td></tr>`;
    const m = modal({ title: p ? `خطة ${p.code}` : 'خطة عمولة جديدة', body: `<form id="pf"><div class="grid cols-3">
        <div class="field"><label>الرمز</label><input name="code" value="${esc(p0.code)}" ${dis}></div>
        <div class="field" style="grid-column:span 2"><label>اسم الخطة *</label><input name="name" value="${esc(p0.name)}" ${dis}></div>
        <div class="field" style="grid-column:span 3"><label>العمولة على</label><select name="basis" ${dis}>${Object.entries(BASIS).map(([k, l]) => `<option value="${k}" ${k === p0.basis ? 'selected' : ''}>${l}</option>`).join('')}</select></div></div>
      <h4 style="margin:8px 0 4px">الشرائح</h4><p class="muted" style="margin:0 0 6px;font-size:12.5px">إذا المندوب حقق «من %» من هدفه أو أكثر، بياخذ «العمولة %» على كل الأساس. البرنامج بياخذ أعلى شريحة وصلها.</p>
      <table class="t" style="max-width:420px"><thead><tr><th>من % تحقيق الهدف</th><th>العمولة %</th><th></th></tr></thead><tbody id="tiers">${(p0.tiers || []).slice().sort((a, b) => a.min_pct - b.min_pct).map(tierRow).join('')}</tbody></table>
      ${ed ? '<button type="button" class="btn sm" data-addt style="margin-top:4px">➕ شريحة</button>' : ''}
      <div class="grid cols-3" style="margin-top:10px">
        <div class="field"><label>العمولة % إذا ما في هدف للشهر</label><input name="no_target_rate" value="${num(p0.no_target_rate)}" inputmode="decimal" ${dis}></div>
        <div class="field"><label>مكافأة ثابتة (دينار)</label><input name="bonus_amount" value="${num(p0.bonus_amount) || ''}" inputmode="decimal" ${dis}></div>
        <div class="field"><label>عند تحقيق % أو أكثر</label><input name="bonus_at_pct" value="${p0.bonus_at_pct ?? ''}" inputmode="decimal" placeholder="مثلاً 100" ${dis}></div></div>
      <label class="check"><input type="checkbox" name="is_active" ${p0.is_active ? 'checked' : ''} ${dis}> فعّالة</label></form>`,
      foot: `${ed ? '<button class="btn primary" data-save>💾 حفظ</button>' : ''}${p && ed ? '<button class="btn danger" data-del style="margin-inline-start:auto">حذف</button>' : ''}<button class="btn" data-close>إغلاق</button>` });
    const f = m.el.querySelector('#pf'), tb = m.el.querySelector('#tiers');
    m.el.querySelector('[data-addt]')?.addEventListener('click', () => tb.insertAdjacentHTML('beforeend', tierRow()));
    tb.addEventListener('click', (e) => { if (e.target.closest('[data-rm]')) e.target.closest('tr').remove(); });
    m.el.querySelector('[data-save]')?.addEventListener('click', async () => {
      const tiers = [...tb.querySelectorAll('tr')].map(tr => ({ min_pct: num(tr.querySelector('[data-k=min]').value), rate: num(tr.querySelector('[data-k=rate]').value), _e: tr.querySelector('[data-k=min]').value.trim() === '' && tr.querySelector('[data-k=rate]').value.trim() === '' }))
        .filter(t => !t._e).map(({ min_pct, rate }) => ({ min_pct, rate })).sort((a, b) => a.min_pct - b.min_pct);
      if (tiers.some(t => t.min_pct < 0 || t.rate < 0 || t.rate > 100)) return toast('الشرائح: النسب بين 0 و100', 'err');
      const bAt = f.bonus_at_pct.value.trim() === '' ? null : num(f.bonus_at_pct.value);
      if (num(f.bonus_amount.value) > 0 && !bAt) return toast('حدد نسبة التحقيق اللي بتعطي المكافأة', 'err');
      const rec = { code: f.code.value.trim(), name: f.name.value.trim(), basis: f.basis.value, tiers, no_target_rate: num(f.no_target_rate.value), bonus_at_pct: bAt, bonus_amount: num(f.bonus_amount.value), is_active: f.is_active.checked };
      if (!rec.code || !rec.name) return toast('الرمز والاسم مطلوبين', 'err');
      const res = p ? await sb.from('commission_plans').update(rec).eq('id', p.id) : await sb.from('commission_plans').insert({ ...rec, company_id: S.company.id });
      if (res.error) return toast(arError(res.error), 'err');
      toast('انحفظت الخطة', 'ok'); m.close(); plansTab(v, head, lk);
    });
    m.el.querySelector('[data-del]')?.addEventListener('click', async () => {
      if (!(await confirmBox(`حذف الخطة «${p.name}»؟ المندوبين عليها بيرجعوا للنسبة الثابتة.`))) return;
      const { error: e3 } = await sb.from('commission_plans').delete().eq('id', p.id); if (e3) return toast(arError(e3), 'err'); m.close(); S._lk = null; viewCommissions(v);
    });
  };
  v.querySelector('[data-new]')?.addEventListener('click', () => open(null));
  v.querySelector('tbody').addEventListener('click', (e) => { const tr = e.target.closest('[data-open]'); if (tr) open(plans.find(x => x.id === tr.dataset.open)); });
}

export const COMMISSION_ROUTES = { commissions: viewCommissions };
