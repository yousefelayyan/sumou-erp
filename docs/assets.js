// =====================================================================
//  السمو ERP — حركات الأصول الثابتة: استبعاد/إتلاف، بيع مباشر، نقل بين الدوائر
//  الكتابة كلها من دوال قاعدة البيانات (asset_mov_*)، والقيد بينعمل لحاله مع الترحيل.
// =====================================================================
import { S, sb, esc, fmtDate, fmtNum, num, today, toast, arError, modal, confirmBox, formData, can, fmtPrice } from './core.js';
import { loadParties, partyLabel } from './parties.js';
import { loadDepartments, deptName } from './departments.js';
import { printDoc, amountToWords } from './print.js';

export const MOV_KINDS = {
  dispose:  { l: 'استبعاد / إتلاف', i: '🗑️', d: 'شطب الأصل: المجمع مدين، الأصل دائن بكلفته، والقيمة الدفترية خسارة.' },
  sale:     { l: 'بيع مباشر', i: '💰', d: 'بيع الأصل لزبون: الزبون مدين بالسعر والضريبة، والفرق عن القيمة الدفترية ربح أو خسارة.' },
  transfer: { l: 'نقل بين الدوائر', i: '🔀', d: 'تغيير دائرة الأصل بس، بدون قيد.' },
};
const ST = { draft: ['مسودة', 'warn'], posted: ['مرحّلة', 'ok'], cancelled: ['ملغاة', 'bad'] };
const q = (k) => new URLSearchParams(location.hash.split('?')[1] || '').get(k);

async function viewAssetMoves(v, ctx) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const kind = q('k') || '';
  const [mv, assets, parties, depts] = await Promise.all([
    sb.from('asset_movements').select('*').eq('company_id', S.company.id).order('mov_no', { ascending: false }),
    sb.from('fixed_assets').select('id,code,name,cost,status,department_id').eq('company_id', S.company.id).order('code'),
    loadParties(), loadDepartments()]);
  if (mv.error) throw mv.error;
  const rows = (mv.data || []).filter(r => !kind || r.kind === kind);
  const pby = Object.fromEntries(parties.map(p => [p.id, p]));
  v.innerHTML = `<div class="page-head"><h2>🔁 حركات الأصول الثابتة</h2><span class="badge brand">${rows.length}</span><div class="spacer"></div>
      <a class="btn sm" href="#/assets">🏢 الأصول</a>
      ${can('fixed_assets', 'add') ? Object.entries(MOV_KINDS).map(([k, x]) => `<button class="btn primary" data-new="${k}">${x.i} ${x.l}</button>`).join(' ') : ''}</div>
    <div class="tabs" style="margin-bottom:10px">${[['', 'الكل'], ...Object.entries(MOV_KINDS).map(([k, x]) => [k, x.l])].map(([k, l]) => `<a style="text-decoration:none" class="tab ${k === kind ? 'active' : ''}" href="#/asset-moves${k ? '?k=' + k : ''}">${l}</a>`).join('')}</div>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرقم</th><th>النوع</th><th>التاريخ</th><th>البيان</th><th>الكلفة</th><th>المجمع</th><th>سعر البيع</th><th>الحالة</th></tr></thead><tbody>
    ${rows.map(r => `<tr class="click" data-open="${r.id}"><td><b>${r.mov_no}</b></td><td>${MOV_KINDS[r.kind].i} ${MOV_KINDS[r.kind].l}</td><td>${fmtDate(r.mov_date)}</td>
      <td>${r.kind === 'sale' ? esc(partyLabel(pby[r.party_id])) : r.kind === 'transfer' ? `${esc(deptName(r.from_department_id) || '—')} ← ${esc(deptName(r.to_department_id))}` : esc(r.notes || '')}</td>
      <td class="n">${r.status === 'posted' || r.status === 'cancelled' ? fmtNum(r.total_cost) : ''}</td><td class="n">${r.total_accum ? fmtNum(r.total_accum) : ''}</td>
      <td class="n">${r.kind === 'sale' ? fmtPrice(r.total_price) : ''}</td><td><span class="badge ${ST[r.status][1]}">${ST[r.status][0]}</span></td></tr>`).join('')
      || '<tr><td colspan="8" class="empty">ما في حركات</td></tr>'}</tbody></table></div>`;
  v.querySelectorAll('[data-new]').forEach(b => b.onclick = () => openMove(ctx, { kind: b.dataset.new }, assets.data || [], parties, depts));
  v.querySelector('tbody').onclick = (e) => { const r = e.target.closest('[data-open]'); if (r) openMove(ctx, mv.data.find(x => x.id === r.dataset.open), assets.data || [], parties, depts); };
  if (q('new') && MOV_KINDS[q('new')] && can('fixed_assets', 'add')) openMove(ctx, { kind: q('new'), _asset: q('asset') }, assets.data || [], parties, depts);
}

async function openMove(ctx, m, assets, parties, depts) {
  const isNew = !m.id, k = m.kind, K = MOV_KINDS[k];
  let lines = [];
  if (!isNew) lines = (await sb.from('asset_movement_lines').select('*').eq('movement_id', m.id).order('line_no')).data || [];
  else if (m._asset) { lines = [{ asset_id: m._asset, sale_price: '' }]; if (k === 'transfer') m.from_department_id = assets.find(a => a.id === m._asset)?.department_id || null; }
  const editable = (isNew ? can('fixed_assets', 'add') : can('fixed_assets', 'edit')) && (isNew || m.status === 'draft');
  const ro = editable ? '' : 'disabled';
  const aby = Object.fromEntries(assets.map(a => [a.id, a]));
  const accum = {};
  await Promise.all([...new Set([...assets.filter(a => a.status === 'active').map(a => a.id), ...lines.map(l => l.asset_id)])].map(async id => { accum[id] = num((await sb.rpc('asset_accum', { p_asset: id })).data); }));
  const customers = parties.filter(p => p.party_type === 'customer' && (p.is_active || p.id === m.party_id));
  const subs = depts.filter(d => d.kind === 'sub' && (d.is_active || d.id === m.to_department_id || d.id === m.from_department_id));
  const dsel = (name, val, req) => `<select name="${name}" ${ro}><option value="">${req ? '— اختار —' : '— أي دائرة —'}</option>${subs.map(d => `<option value="${d.id}" ${d.id === val ? 'selected' : ''}>${esc(d.code)} — ${esc(d.name)}</option>`).join('')}</select>`;
  const head = `<div class="grid cols-3">
      <div class="field"><label>التاريخ *</label><input type="date" name="mov_date" value="${esc(m.mov_date || today())}" ${ro}></div>
      ${k === 'sale' ? `<div class="field" style="grid-column:span 2"><label>الزبون *</label><select name="party_id" ${ro}><option value="">— اختار —</option>${customers.map(p => `<option value="${p.id}" ${p.id === m.party_id ? 'selected' : ''}>${esc(partyLabel(p))}</option>`).join('')}</select></div>
        <div class="field"><label>نسبة الضريبة %</label><input name="tax_rate" value="${m.tax_rate ?? 16}" inputmode="decimal" dir="ltr" ${ro}></div>` : ''}
      ${k === 'transfer' ? `<div class="field"><label>من دائرة</label>${dsel('from_department_id', m.from_department_id)}</div><div class="field"><label>إلى دائرة *</label>${dsel('to_department_id', m.to_department_id, true)}</div>` : ''}
      <div class="field"><label>المرجع</label><input name="reference" value="${esc(m.reference || '')}" ${ro}></div>
      <div class="field" style="grid-column:span 3"><label>البيان / السبب</label><input name="notes" value="${esc(m.notes || '')}" ${ro}></div></div>`;
  const body = `<p class="muted" style="margin-top:0">${K.d}</p><form id="f">${head}</form>
    <div class="table-wrap"><table class="t" id="ln"><thead><tr><th>الأصل</th><th>الدائرة</th><th>الكلفة</th><th>المجمع</th><th>القيمة الدفترية</th>${k === 'sale' ? '<th>سعر البيع</th><th>الضريبة</th><th>ربح/خسارة</th>' : ''}${editable ? '<th></th>' : ''}</tr></thead><tbody></tbody>
    <tfoot></tfoot></table></div>
    ${editable ? `<div style="display:flex;gap:8px;align-items:center;margin-top:8px"><select id="pick"><option value="">➕ أضف أصل…</option></select></div>` : ''}
    ${m.status === 'posted' && m.entry_id ? `<p class="muted" style="font-size:13px">انعمل قيد بالحركة. بتلاقيه باليومية العامة.</p>` : ''}`;
  const md = modal({ title: `${K.i} ${K.l}${isNew ? ' — جديدة' : ` رقم ${m.mov_no} (${ST[m.status][0]})`}`, size: 'lg', body,
    foot: `${editable ? '<button class="btn primary" data-save>💾 حفظ</button>' : ''}
      ${!isNew && m.status === 'draft' && can('fixed_assets', 'post') ? '<button class="btn primary" data-post>✅ ترحيل</button>' : ''}
      ${!isNew ? '<button class="btn" data-prn>🖨️ طباعة</button>' : ''}
      ${!isNew && m.status !== 'cancelled' && can('fixed_assets', m.status === 'posted' ? 'post' : 'edit') ? '<button class="btn danger" data-cx>إلغاء الحركة</button>' : ''}
      ${!isNew && m.status === 'draft' && can('fixed_assets', 'delete') ? '<button class="btn danger" data-del style="margin-inline-start:auto">حذف</button>' : ''}
      <button class="btn" data-close>إغلاق</button>` });
  const el = md.el, tb = el.querySelector('#ln tbody'), tf = el.querySelector('#ln tfoot');
  const rate = () => num(el.querySelector('[name=tax_rate]')?.value);
  const lineVals = (l) => {
    const a = aby[l.asset_id] || {}, cost = l.cost != null ? num(l.cost) : num(a.cost), acc = l.accum != null ? num(l.accum) : num(accum[l.asset_id]);
    const book = cost - acc, price = num(l.sale_price), tax = l.tax_amount != null && !editable ? num(l.tax_amount) : Math.round(price * rate() * 10) / 1000;
    return { a, cost, acc, book, price, tax, gl: price - book };
  };
  const draw = () => {
    let T = { cost: 0, acc: 0, book: 0, price: 0, tax: 0, gl: 0 };
    tb.innerHTML = lines.map((l, i) => {
      const x = lineVals(l); Object.keys(T).forEach(kk => T[kk] += x[kk]);
      return `<tr><td><b>${esc(x.a.code || '')}</b> ${esc(x.a.name || '')}</td><td>${esc(deptName(l.prev_department_id ?? x.a.department_id) || '—')}</td>
        <td class="n">${fmtNum(x.cost)}</td><td class="n">${fmtNum(x.acc)}</td><td class="n">${fmtNum(x.book)}</td>
        ${k === 'sale' ? `<td>${editable ? `<input data-pr="${i}" value="${esc(l.sale_price ?? '')}" inputmode="decimal" dir="ltr" style="width:110px">` : `<span class="n">${fmtPrice(x.price)}</span>`}</td><td class="n">${fmtNum(x.tax)}</td>
          <td class="n" style="color:${x.gl < 0 ? 'var(--bad,#c0392b)' : 'inherit'}">${fmtNum(x.gl)}</td>` : ''}
        ${editable ? `<td><button class="btn sm danger" data-rm="${i}">✕</button></td>` : ''}</tr>`;
    }).join('') || `<tr><td colspan="9" class="empty">أضف أصل واحد على الأقل</td></tr>`;
    tf.innerHTML = lines.length ? `<tr class="tot"><td colspan="2">المجموع</td><td class="n">${fmtNum(T.cost)}</td><td class="n">${fmtNum(T.acc)}</td><td class="n">${fmtNum(T.book)}</td>
      ${k === 'sale' ? `<td class="n">${fmtPrice(T.price)}</td><td class="n">${fmtNum(T.tax)}</td><td class="n">${fmtNum(T.gl)}</td>` : ''}${editable ? '<td></td>' : ''}</tr>` : '';
    const pick = el.querySelector('#pick');
    if (pick) {
      const from = el.querySelector('[name=from_department_id]')?.value;
      const avail = assets.filter(a => a.status === 'active' && !lines.some(l => l.asset_id === a.id) && (!from || a.department_id === from));
      pick.innerHTML = `<option value="">➕ أضف أصل… (${avail.length})</option>` + avail.map(a => `<option value="${a.id}">${esc(a.code)} — ${esc(a.name)} · دفترية ${fmtNum(num(a.cost) - num(accum[a.id]))}</option>`).join('');
    }
  };
  draw();
  el.querySelector('#pick')?.addEventListener('change', (e) => { if (e.target.value) { lines.push({ asset_id: e.target.value, sale_price: '' }); draw(); } });
  el.querySelector('[name=from_department_id]')?.addEventListener('change', draw);
  el.querySelector('[name=tax_rate]')?.addEventListener('input', draw);
  tb.addEventListener('click', (e) => { const b = e.target.closest('[data-rm]'); if (b) { lines.splice(+b.dataset.rm, 1); draw(); } });
  tb.addEventListener('change', (e) => { const i = e.target.dataset.pr; if (i != null) { lines[+i].sale_price = e.target.value; draw(); } });
  const done = (msg) => { toast(msg, 'ok'); md.close(true); ctx.rerender(); };

  el.querySelector('[data-save]')?.addEventListener('click', async () => {
    const f = formData(el.querySelector('#f'));
    if (!lines.length) return toast('أضف أصل واحد على الأقل', 'err');
    const p = { ...f, id: m.id || null, company_id: S.company.id, kind: k, lines: lines.map(l => ({ asset_id: l.asset_id, sale_price: num(l.sale_price) })) };
    const { data, error } = await sb.rpc('asset_mov_save', { p });
    if (error) return toast(arError(error), 'err');
    if (can('fixed_assets', 'post') && await confirmBox('انحفظت الحركة. بدك ترحّلها هلّق؟')) {
      const x = await sb.rpc('asset_mov_post', { p_id: data }); if (x.error) { toast(arError(x.error), 'err'); md.close(true); return ctx.rerender(); }
      return done('انرحّلت الحركة');
    }
    done('تم الحفظ');
  });
  el.querySelector('[data-post]')?.addEventListener('click', async () => {
    if (!(await confirmBox(k === 'transfer' ? 'ترحيل النقل؟ دائرة الأصول رح تتغيّر.' : 'ترحيل الحركة؟ رح ينعمل القيد والأصول بتصير «مستبعدة».'))) return;
    const x = await sb.rpc('asset_mov_post', { p_id: m.id }); if (x.error) return toast(arError(x.error), 'err'); done('انرحّلت الحركة');
  });
  el.querySelector('[data-cx]')?.addEventListener('click', async () => {
    let d = null;
    if (m.status === 'posted' && m.entry_id) { d = prompt('تاريخ القيد العكسي (YYYY-MM-DD):', today()); if (!d) return; }
    else if (!(await confirmBox(m.status === 'posted' ? 'إلغاء النقل؟ الأصول بترجع لدائرتها.' : 'إلغاء المسودة؟'))) return;
    const x = await sb.rpc('asset_mov_cancel', { p_id: m.id, p_date: d }); if (x.error) return toast(arError(x.error), 'err'); done('انلغت الحركة');
  });
  el.querySelector('[data-del]')?.addEventListener('click', async () => {
    if (!(await confirmBox('حذف المسودة؟'))) return;
    const x = await sb.rpc('asset_mov_delete', { p_id: m.id }); if (x.error) return toast(arError(x.error), 'err'); done('انحذفت');
  });
  el.querySelector('[data-prn]')?.addEventListener('click', () => {
    let tot = 0;
    const rowsH = lines.map((l, i) => { const x = lineVals(l); tot += x.price + x.tax; return `<tr><td>${i + 1}</td><td>${esc(x.a.code || '')}</td><td>${esc(x.a.name || '')}</td><td class="n">${fmtNum(x.cost)}</td><td class="n">${fmtNum(x.acc)}</td><td class="n">${fmtNum(x.book)}</td>${k === 'sale' ? `<td class="n">${fmtPrice(x.price)}</td><td class="n">${fmtNum(x.tax)}</td>` : ''}</tr>`; }).join('');
    const info = [`<b>رقم الحركة:</b> ${m.mov_no}`, `<b>التاريخ:</b> ${fmtDate(m.mov_date)}`,
      k === 'sale' ? `<b>الزبون:</b> ${esc(partyLabel(parties.find(p => p.id === m.party_id)))}` : '',
      k === 'transfer' ? `<b>من:</b> ${esc(deptName(m.from_department_id) || '—')} &nbsp; <b>إلى:</b> ${esc(deptName(m.to_department_id))}` : '',
      m.reference ? `<b>المرجع:</b> ${esc(m.reference)}` : '', m.notes ? `<b>البيان:</b> ${esc(m.notes)}` : ''].filter(Boolean).join(' &nbsp;·&nbsp; ');
    printDoc(`${K.l} — أصول ثابتة`, `<p>${info}</p><table class="t"><thead><tr><th>#</th><th>الرقم</th><th>الأصل</th><th>الكلفة</th><th>المجمع</th><th>الدفترية</th>${k === 'sale' ? '<th>السعر</th><th>الضريبة</th>' : ''}</tr></thead><tbody>${rowsH}</tbody></table>
      ${k === 'sale' ? `<p><b>المجموع شامل الضريبة:</b> ${fmtNum(tot)} — ${esc(amountToWords(tot))}</p>` : ''}
      <div style="display:flex;justify-content:space-around;margin-top:50px"><div>أعدّه: ............</div><div>اعتمده: ............</div>${k === 'transfer' ? '<div>استلمه: ............</div>' : ''}</div>`,
      { subtitle: ST[m.status][0] });
  });
}

// ---------------------------------------------------------------------
//  عهد الأصول الثابتة
// ---------------------------------------------------------------------
export const CUST_KINDS = {
  handover: { l: 'تسليم عهدة', i: '📥', from: false, to: true, ack: 'أقرّ أنا الموقّع أدناه باستلام الأصول المذكورة أعلاه بالحالة والملحقات المبيّنة، وأتعهّد بالمحافظة عليها واستعمالها لأغراض العمل فقط، وإرجاعها عند الطلب أو عند ترك العمل.' },
  transfer: { l: 'نقل عهدة', i: '🔀', from: true, to: true, ack: 'تم نقل عهدة الأصول المذكورة أعلاه من المسلِّم إلى المستلِم بالحالة والملحقات المبيّنة، ويقرّ المستلِم باستلامها وبمسؤوليته عنها من تاريخه.' },
  return:   { l: 'إرجاع عهدة', i: '📤', from: true, to: false, ack: 'تم إرجاع الأصول المذكورة أعلاه من صاحب العهدة بالحالة والملحقات المبيّنة، وتبرأ ذمّته منها من تاريخه.' },
};
export const CUST_ST = { pending: ['في الانتظار', 'warn'], confirmed: ['مثبت', 'brand'], done: ['انتهاء العمل', 'ok'], closed: ['مغلق', ''], cancelled: ['ملغى', 'bad'] };
const tabLink = (base, k, cur, l) => `<a style="text-decoration:none" class="tab ${k === cur ? 'active' : ''}" href="#/${base}${k ? '?t=' + k : ''}">${l}</a>`;

async function viewCustody(v, ctx) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const tab = q('t') || 'docs';
  const [docs, custs, assets, emps] = await Promise.all([
    sb.from('custody_docs').select('*').eq('company_id', S.company.id).order('doc_no', { ascending: false }),
    sb.from('asset_custodians').select('*').eq('company_id', S.company.id).order('code'),
    sb.from('fixed_assets').select('id,code,name,category,status,custodian_id,custody_since,location').eq('company_id', S.company.id).order('code'),
    sb.from('employees').select('id,code,name').eq('company_id', S.company.id).order('code')]);
  if (docs.error) throw docs.error;
  const C = custs.data || [], A = assets.data || [], cby = Object.fromEntries(C.map(c => [c.id, c]));
  const cn = (id) => cby[id] ? `${cby[id].code} — ${cby[id].name}` : '—';
  let body = '';
  if (tab === 'docs') {
    body = `<div class="card table-wrap"><table class="t"><thead><tr><th>الرقم</th><th>النوع</th><th>التاريخ</th><th>المسلِّم</th><th>المستلِم</th><th>الموقع</th><th>الحالة</th></tr></thead><tbody>
      ${(docs.data || []).map(d => `<tr class="click" data-open="${d.id}"><td><b>${d.doc_no}</b></td><td>${CUST_KINDS[d.kind].i} ${CUST_KINDS[d.kind].l}</td><td>${fmtDate(d.doc_date)}</td>
        <td>${esc(d.from_custodian_id ? cn(d.from_custodian_id) : '—')}</td><td>${esc(d.to_custodian_id ? cn(d.to_custodian_id) : '—')}</td><td>${esc(d.location || '')}</td>
        <td><span class="badge ${CUST_ST[d.status][1]}">${CUST_ST[d.status][0]}</span></td></tr>`).join('') || '<tr><td colspan="7" class="empty">ما في مستندات</td></tr>'}</tbody></table></div>`;
  } else if (tab === 'holders') {
    body = `<div class="card table-wrap"><table class="t"><thead><tr><th>الرمز</th><th>الاسم</th><th>الموظف</th><th>الهاتف</th><th>عدد الأصول بعهدته</th><th>الحالة</th></tr></thead><tbody>
      ${C.map(c => `<tr class="click" data-cust="${c.id}"><td>${esc(c.code)}</td><td><b>${esc(c.name)}</b></td><td>${esc((emps.data || []).find(e => e.id === c.employee_id)?.name || '')}</td><td dir="ltr">${esc(c.phone || '')}</td>
        <td class="n">${A.filter(a => a.custodian_id === c.id).length}</td><td>${c.is_active ? '<span class="badge ok">فعّال</span>' : '<span class="badge bad">موقوف</span>'}</td></tr>`).join('') || '<tr><td colspan="6" class="empty">ما في أصحاب عهد</td></tr>'}</tbody></table></div>`;
  } else {
    const groups = [...C.map(c => [c.id, cn(c.id)]), [null, 'بدون عهدة']].map(([id, name]) => [name, A.filter(a => a.status === 'active' && (a.custodian_id || null) === id)]).filter(g => g[1].length);
    body = `<div class="card table-wrap"><table class="t pt rep" id="cur"><thead><tr><th>الأصل</th><th>التصنيف</th><th>الموقع</th><th>بعهدته من</th></tr></thead><tbody>
      ${groups.map(([name, rows]) => `<tr class="tot"><td colspan="4">👤 ${esc(name)} (${rows.length})</td></tr>` + rows.map(a => `<tr class="click" data-hist="${a.id}"><td><b>${esc(a.code)}</b> ${esc(a.name)}</td><td>${esc(a.category || '')}</td><td>${esc(a.location || '')}</td><td>${fmtDate(a.custody_since)}</td></tr>`).join('')).join('') || '<tr><td colspan="4" class="empty">ما في أصول</td></tr>'}</tbody></table></div>`;
  }
  v.innerHTML = `<div class="page-head"><h2>🧾 عهد الأصول الثابتة</h2><div class="spacer"></div><a class="btn sm" href="#/assets">🏢 الأصول</a>
      ${tab === 'current' ? '<button class="btn" id="prn">🖨️ طباعة</button>' : ''}
      ${tab === 'holders' && can('asset_custody', 'add') ? '<button class="btn primary" id="addc">➕ صاحب عهدة</button>' : ''}
      ${tab === 'docs' && can('asset_custody', 'add') ? Object.entries(CUST_KINDS).map(([k, x]) => `<button class="btn primary" data-new="${k}">${x.i} ${x.l}</button>`).join(' ') : ''}</div>
    <p class="muted">العهدة سجل مسؤولية وموقع بس، بدون قيد. الأصل بينتقل لصاحب العهدة الجديد لما المستند يصير «انتهاء العمل».</p>
    <div class="tabs" style="margin-bottom:10px">${tabLink('asset-custody', '', tab === 'docs' ? '' : tab, 'المستندات')}${tabLink('asset-custody', 'current', tab, 'العهد الحالية')}${tabLink('asset-custody', 'holders', tab, 'أصحاب العهد')}</div>${body}`;
  v.querySelectorAll('[data-new]').forEach(b => b.onclick = () => openCustody(ctx, { kind: b.dataset.new }, C, A));
  v.querySelector('#prn')?.addEventListener('click', () => printDoc('العهد الحالية للأصول الثابتة', v.querySelector('#cur').outerHTML, { subtitle: `كما في ${fmtDate(today())}` }));
  v.querySelector('#addc')?.addEventListener('click', () => openCustodian(ctx, null, C, emps.data || []));
  v.querySelector('tbody')?.addEventListener('click', (e) => {
    const o = e.target.closest('[data-open]'); if (o) return openCustody(ctx, docs.data.find(x => x.id === o.dataset.open), C, A);
    const c = e.target.closest('[data-cust]'); if (c) return openCustodian(ctx, C.find(x => x.id === c.dataset.cust), C, emps.data || []);
    const h = e.target.closest('[data-hist]'); if (h) return custodyHistory(A.find(x => x.id === h.dataset.hist));
  });
  if (q('new') && CUST_KINDS[q('new')] && can('asset_custody', 'add')) openCustody(ctx, { kind: q('new'), _asset: q('asset') }, C, A);
}

function openCustodian(ctx, c, all, emps) {
  const isNew = !c; c = c || { code: String(Math.max(0, ...all.map(x => parseInt(String(x.code).replace(/\D/g, ''), 10) || 0)) + 1).padStart(3, '0'), is_active: true };
  const ed = isNew ? can('asset_custody', 'add') : can('asset_custody', 'edit'), ro = ed ? '' : 'disabled';
  const m = modal({ title: isNew ? 'صاحب عهدة جديد' : `صاحب العهدة: ${c.name}`, size: 'sm', body: `<form id="f">
    <div class="field"><label>الرمز *</label><input name="code" value="${esc(c.code)}" ${ro}></div>
    <div class="field"><label>الاسم *</label><input name="name" value="${esc(c.name || '')}" ${ro}></div>
    <div class="field"><label>الموظف (اختياري)</label><select name="employee_id" ${ro}><option value="">—</option>${emps.map(e => `<option value="${e.id}" ${e.id === c.employee_id ? 'selected' : ''}>${esc(e.code)} — ${esc(e.name)}</option>`).join('')}</select></div>
    <div class="field"><label>الهاتف</label><input name="phone" value="${esc(c.phone || '')}" dir="ltr" ${ro}></div>
    <div class="field"><label>ملاحظات</label><input name="notes" value="${esc(c.notes || '')}" ${ro}></div>
    <label class="check"><input type="checkbox" name="is_active" ${c.is_active ? 'checked' : ''} ${ro}> فعّال</label></form>`,
    foot: `${ed ? '<button class="btn primary" data-save>💾 حفظ</button>' : ''}${!isNew && can('asset_custody', 'delete') ? '<button class="btn danger" data-del style="margin-inline-start:auto">حذف</button>' : ''}<button class="btn" data-close>إغلاق</button>` });
  m.el.querySelector('[name=employee_id]')?.addEventListener('change', (e) => { const n = m.el.querySelector('[name=name]'); if (!n.value && e.target.value) n.value = emps.find(x => x.id === e.target.value)?.name || ''; });
  m.el.querySelector('[data-save]')?.addEventListener('click', async () => {
    const d = formData(m.el.querySelector('#f')); d.is_active = !!m.el.querySelector('[name=is_active]').checked; d.employee_id = d.employee_id || null;
    if (!d.code || !d.name) return toast('الرمز والاسم مطلوبين', 'err');
    const r = isNew ? await sb.from('asset_custodians').insert({ ...d, company_id: S.company.id }) : await sb.from('asset_custodians').update(d).eq('id', c.id);
    if (r.error) return toast(arError(r.error), 'err'); toast('تم الحفظ', 'ok'); m.close(); ctx.rerender();
  });
  m.el.querySelector('[data-del]')?.addEventListener('click', async () => {
    if (!(await confirmBox('حذف صاحب العهدة؟'))) return;
    const r = await sb.from('asset_custodians').delete().eq('id', c.id); if (r.error) return toast('ما بينحذف: عليه مستندات عهدة. أوقفه بدل الحذف', 'err'); ctx.rerender();
  });
}

export async function custodyHistory(a) {
  if (!a) return;
  const { data, error } = await sb.rpc('custody_history', { p_asset: a.id });
  if (error) return toast(arError(error), 'err');
  modal({ title: `سجل العهدة: ${a.code} ${a.name}`, size: 'lg', body: `<div class="table-wrap"><table class="t"><thead><tr><th>المستند</th><th>الحركة</th><th>من تاريخ</th><th>لتاريخ</th><th>المسلِّم</th><th>المستلِم</th><th>الموقع</th><th>الحالة والملحقات</th></tr></thead><tbody>
    ${(data || []).map(h => `<tr><td>${h.doc_no}</td><td>${CUST_KINDS[h.kind].i} ${CUST_KINDS[h.kind].l}</td><td>${fmtDate(h.doc_date)}</td><td>${h.ended ? fmtDate(h.ended) : '<b>لهلّق</b>'}</td>
      <td>${esc(h.from_name || '—')}</td><td>${esc(h.to_name || '—')}</td><td>${esc(h.location || '')}</td><td>${esc([h.condition, h.accessories].filter(Boolean).join(' · '))}</td></tr>`).join('') || '<tr><td colspan="8" class="empty">ما في حركات عهدة على هالأصل</td></tr>'}</tbody></table></div>`,
    foot: '<button class="btn" data-close>إغلاق</button>' });
}

async function openCustody(ctx, d, custs, assets) {
  const isNew = !d.id, k = d.kind, K = CUST_KINDS[k], st = d.status || 'pending';
  let lines = isNew ? (d._asset ? [{ asset_id: d._asset }] : []) : ((await sb.from('custody_doc_lines').select('*').eq('doc_id', d.id).order('line_no')).data || []);
  if (isNew && d._asset && K.from) d.from_custodian_id = assets.find(a => a.id === d._asset)?.custodian_id || null;
  const editable = st === 'pending' && (isNew ? can('asset_custody', 'add') : can('asset_custody', 'edit')), ro = editable ? '' : 'disabled';
  const aby = Object.fromEntries(assets.map(a => [a.id, a]));
  const csel = (name, val, onlyActive) => `<select name="${name}" ${ro}><option value="">— اختار —</option>${custs.filter(c => !onlyActive || c.is_active || c.id === val).map(c => `<option value="${c.id}" ${c.id === val ? 'selected' : ''}>${esc(c.code)} — ${esc(c.name)}</option>`).join('')}</select>`;
  const md = modal({ title: `${K.i} ${K.l}${isNew ? ' — جديد' : ` رقم ${d.doc_no} (${CUST_ST[st][0]})`}`, size: 'lg', body: `<form id="f"><div class="grid cols-3">
      <div class="field"><label>التاريخ *</label><input type="date" name="doc_date" value="${esc(d.doc_date || today())}" ${ro}></div>
      ${K.from ? `<div class="field"><label>صاحب العهدة المسلِّم *</label>${csel('from_custodian_id', d.from_custodian_id)}</div>` : ''}
      ${K.to ? `<div class="field"><label>صاحب العهدة المستلِم *</label>${csel('to_custodian_id', d.to_custodian_id, true)}</div>` : ''}
      <div class="field"><label>${k === 'return' ? 'مكان الإرجاع' : 'الموقع الجديد'}</label><input name="location" value="${esc(d.location || '')}" ${ro}></div>
      <div class="field"><label>المرجع</label><input name="reference" value="${esc(d.reference || '')}" ${ro}></div>
      <div class="field" style="grid-column:span 3"><label>الوصف</label><input name="notes" value="${esc(d.notes || '')}" ${ro}></div></div></form>
    <div class="table-wrap"><table class="t" id="ln"><thead><tr><th>الأصل</th><th>بعهدة</th><th>الحالة عند ${k === 'return' ? 'الإرجاع' : 'التسليم'}</th><th>الملحقات</th><th>ملاحظات</th>${editable ? '<th></th>' : ''}</tr></thead><tbody></tbody></table></div>
    ${editable ? '<select id="pick" style="margin-top:8px"></select>' : ''}
    ${st !== 'cancelled' && !isNew ? `<div style="display:flex;gap:6px;flex-wrap:wrap;margin-top:12px;align-items:center"><b>الحالة:</b>
      ${['pending', 'confirmed', 'done', 'closed'].map(x => `<button class="btn sm ${x === st ? 'primary' : ''}" data-st="${x}" ${x === st || st === 'closed' || (x === 'closed' && st !== 'done') ? 'disabled' : ''}>${CUST_ST[x][0]}</button>`).join(' ← ')}
      ${st === 'pending' || st === 'confirmed' ? '<button class="btn sm danger" data-st="cancelled">إلغاء</button>' : ''}</div>` : ''}`,
    foot: `${editable ? '<button class="btn primary" data-save>💾 حفظ</button>' : ''}${!isNew ? '<button class="btn" data-prn>🖨️ إقرار استلام</button>' : ''}
      ${!isNew && (st === 'pending' || st === 'cancelled') && can('asset_custody', 'delete') ? '<button class="btn danger" data-del style="margin-inline-start:auto">حذف</button>' : ''}<button class="btn" data-close>إغلاق</button>` });
  const el = md.el, tb = el.querySelector('#ln tbody');
  const fromVal = () => el.querySelector('[name=from_custodian_id]')?.value || null;
  const draw = () => {
    tb.innerHTML = lines.map((l, i) => { const a = aby[l.asset_id] || {}; const holder = l.prev_custodian_id !== undefined && st === 'done' || st === 'closed' ? l.prev_custodian_id : a.custodian_id;
      return `<tr><td><b>${esc(a.code || '')}</b> ${esc(a.name || '')}</td><td>${esc(custs.find(c => c.id === holder)?.name || '—')}</td>
        ${['condition', 'accessories', 'notes'].map(f => `<td>${editable ? `<input data-f="${f}" data-i="${i}" value="${esc(l[f] || '')}" placeholder="${f === 'condition' ? 'جديد، ممتاز، فيه خدش…' : f === 'accessories' ? 'شاحن، حقيبة…' : ''}">` : esc(l[f] || '')}</td>`).join('')}
        ${editable ? `<td><button class="btn sm danger" data-rm="${i}">✕</button></td>` : ''}</tr>`; }).join('') || '<tr><td colspan="6" class="empty">أضف الأصول</td></tr>';
    const pick = el.querySelector('#pick'); if (!pick) return;
    const fc = fromVal();
    const avail = assets.filter(a => a.status === 'active' && !lines.some(l => l.asset_id === a.id) && (k === 'handover' ? !a.custodian_id : (fc && a.custodian_id === fc)));
    pick.innerHTML = `<option value="">➕ أضف أصل… (${avail.length})</option>` + avail.map(a => `<option value="${a.id}">${esc(a.code)} — ${esc(a.name)}${a.location ? ' · ' + esc(a.location) : ''}</option>`).join('');
  };
  draw();
  el.querySelector('#pick')?.addEventListener('change', (e) => { if (e.target.value) { lines.push({ asset_id: e.target.value }); draw(); } });
  el.querySelector('[name=from_custodian_id]')?.addEventListener('change', () => { lines = lines.filter(l => aby[l.asset_id]?.custodian_id === fromVal()); draw(); });
  tb.addEventListener('click', (e) => { const b = e.target.closest('[data-rm]'); if (b) { lines.splice(+b.dataset.rm, 1); draw(); } });
  tb.addEventListener('input', (e) => { const i = e.target.dataset.i; if (i != null) lines[+i][e.target.dataset.f] = e.target.value; });
  const done = (msg) => { toast(msg, 'ok'); md.close(); ctx.rerender(); };
  el.querySelector('[data-save]')?.addEventListener('click', async () => {
    if (!lines.length) return toast('أضف أصل واحد على الأقل', 'err');
    const f = formData(el.querySelector('#f'));
    const { error } = await sb.rpc('custody_save', { p: { ...f, id: d.id || null, company_id: S.company.id, kind: k, lines: lines.map(l => ({ asset_id: l.asset_id, condition: l.condition || '', accessories: l.accessories || '', notes: l.notes || '' })) } });
    if (error) return toast(arError(error), 'err'); done('تم الحفظ');
  });
  el.querySelectorAll('[data-st]').forEach(b => b.onclick = async () => {
    const to = b.dataset.st;
    const msg = to === 'done' ? 'تطبيق المستند على الأصول؟ صاحب العهدة والموقع رح يتغيّروا.' : to === 'cancelled' ? 'إلغاء المستند؟' : st === 'done' ? 'الرجوع عن المستند؟ الأصول بترجع لصاحب عهدتها وموقعها قبله.' : to === 'closed' ? 'إغلاق المستند (أرشيف)؟ ما بيتغيّر بعدها.' : null;
    if (msg && !(await confirmBox(msg))) return;
    const { error } = await sb.rpc('custody_set_status', { p_id: d.id, p_status: to }); if (error) return toast(arError(error), 'err'); done('تغيّرت الحالة');
  });
  el.querySelector('[data-del]')?.addEventListener('click', async () => {
    if (!(await confirmBox('حذف المستند؟'))) return;
    const { error } = await sb.rpc('custody_delete', { p_id: d.id }); if (error) return toast(arError(error), 'err'); done('انحذف');
  });
  el.querySelector('[data-prn]')?.addEventListener('click', () => {
    const fromN = custs.find(c => c.id === d.from_custodian_id)?.name, toN = custs.find(c => c.id === d.to_custodian_id)?.name;
    const info = [`<b>رقم المستند:</b> ${d.doc_no}`, `<b>التاريخ:</b> ${fmtDate(d.doc_date)}`, fromN ? `<b>المسلِّم:</b> ${esc(fromN)}` : '', toN ? `<b>المستلِم:</b> ${esc(toN)}` : '',
      d.location ? `<b>الموقع:</b> ${esc(d.location)}` : '', d.reference ? `<b>المرجع:</b> ${esc(d.reference)}` : ''].filter(Boolean).join(' &nbsp;·&nbsp; ');
    const rows = lines.map((l, i) => { const a = aby[l.asset_id] || {}; return `<tr><td>${i + 1}</td><td>${esc(a.code || '')}</td><td>${esc(a.name || '')}</td><td>${esc(l.condition || '')}</td><td>${esc(l.accessories || '')}</td><td>${esc(l.notes || '')}</td></tr>`; }).join('');
    const sign = (t, n) => `<div style="text-align:center;min-width:180px"><div>${t}</div><div style="margin-top:6px">${esc(n || '')}</div><div style="margin-top:36px">التوقيع: ................</div></div>`;
    printDoc(`إقرار ${K.l}`, `<p>${info}</p>${d.notes ? `<p>${esc(d.notes)}</p>` : ''}<table class="t"><thead><tr><th>#</th><th>الرقم</th><th>الأصل</th><th>الحالة</th><th>الملحقات</th><th>ملاحظات</th></tr></thead><tbody>${rows}</tbody></table>
      <p style="margin-top:18px;line-height:1.9">${K.ack}</p>
      <div style="display:flex;justify-content:space-around;margin-top:30px;flex-wrap:wrap;gap:20px">${K.from ? sign('المسلِّم', fromN) : ''}${K.to ? sign('المستلِم', toN) : ''}${sign('المسؤول المباشر', '')}</div>`, { subtitle: CUST_ST[st][0] });
  });
}

export const ASSET_ROUTES = { 'asset-moves': viewAssetMoves, 'asset-custody': viewCustody };
