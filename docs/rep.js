// =====================================================================
//  السمو ERP — تطبيق المندوب (للجوال): العملاء، الزيارات، دفعات العملاء
//  route: rep  (?t=customers|visits|payments|team)
// =====================================================================
import { S, sb, esc, fmtNum, fmtDate, fmtDateTime, num, today, toast, arError, modal, can } from './core.js';
import { loadParties } from './parties.js';
import { loadAccounts, leafAccounts, accLabel } from './finance.js';
import { loadLookups } from './lookups.js';
import { openAttachments } from './attach.js';
import { printDoc, amountToWords } from './print.js';

const q = (k) => new URLSearchParams(location.hash.split('?')[1] || '').get(k);
const phone962 = (p) => { let ph = String(p || '').replace(/\D/g, ''); if (ph.startsWith('00')) ph = ph.slice(2); else if (ph.startsWith('0')) ph = '962' + ph.slice(1); else if (ph.length === 9 && ph.startsWith('7')) ph = '962' + ph; return ph; };
const geo = () => new Promise(res => {
  if (!navigator.geolocation) return res(null);
  navigator.geolocation.getCurrentPosition(p => res({ lat: +p.coords.latitude.toFixed(6), lng: +p.coords.longitude.toFixed(6) }), () => res(null), { enableHighAccuracy: true, timeout: 8000, maximumAge: 60000 });
});
const mapLink = (lat, lng) => lat != null ? `https://maps.google.com/?q=${lat},${lng}` : '';
const dur = (a, b) => { const s = Math.max(0, Math.round(((b ? new Date(b) : new Date()) - new Date(a)) / 1000)); return `${String(Math.floor(s / 3600)).padStart(2, '0')}:${String(Math.floor(s / 60) % 60).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`; };
let timer = null;

async function viewRep(v, ctx) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  if (!can('rep_visits', 'view')) return void (v.innerHTML = '<div class="notice">ما عندك صلاحية تطبيق المندوب</div>');
  clearInterval(timer);
  const tab = q('t') || 'home';
  const [parties, openV] = await Promise.all([loadParties(), sb.from('sales_visits').select('*').eq('company_id', S.company.id).eq('user_id', S.session?.user?.id).eq('status', 'open').maybeSingle()]);
  const cust = parties.filter(p => p.party_type === 'customer' && p.is_active), pBy = Object.fromEntries(parties.map(p => [p.id, p]));
  const ov = openV.data;
  const sup = can('rep_visits', 'edit');
  const head = `<style>
    .rep{max-width:720px;margin:0 auto}.rep .vis{background:var(--brand);color:#fff;border-radius:16px;padding:14px;text-align:center;margin-bottom:12px}
    .rep .vis b{font-size:18px;display:block}.rep .vis .tm{font-size:30px;font-weight:800;letter-spacing:2px;margin:6px 0;font-variant-numeric:tabular-nums}
    .rep .tiles{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}.rep .tile{background:var(--card,#fff);border:1px solid var(--line,#e5e7eb);border-radius:16px;padding:16px 8px;text-align:center;cursor:pointer;text-decoration:none;color:inherit}
    .rep .tile i{font-style:normal;font-size:30px;display:block;margin-bottom:6px}.rep .cc{background:var(--card,#fff);border:1px solid var(--line,#e5e7eb);border-radius:14px;padding:10px 12px;margin-bottom:8px}
    .rep .cc .acts{display:flex;gap:6px;flex-wrap:wrap;margin-top:8px}.rep .cc .acts .btn{flex:1;min-width:70px}.rep .ctop{display:flex;gap:8px;align-items:center}
    .rep .search{width:100%;font-size:16px;padding:10px 14px;border-radius:12px;margin-bottom:10px}.rep .back{margin-bottom:10px}
    @media(max-width:520px){.rep .tiles{grid-template-columns:repeat(2,1fr)}}</style>`;
  const visCard = ov ? `<div class="vis"><div>🟢 زيارة جارية</div><b>${esc(pBy[ov.party_id]?.name || '')}</b><div class="tm" id="tm">${dur(ov.started_at)}</div>
      <div style="display:flex;gap:8px;justify-content:center;flex-wrap:wrap"><button class="btn" id="v-pay">💵 دفعة</button><button class="btn" id="v-photo">📷 صور</button><button class="btn danger" id="v-end">⏹ إنهاء الزيارة</button></div></div>` : '';
  let body = '';
  if (tab === 'home') {
    body = `<div class="tiles">
      <a class="tile" href="#/rep?t=customers"><i>👥</i>العملاء</a>
      <a class="tile" href="#/rep?t=visits"><i>📍</i>زياراتي</a>
      <a class="tile" href="#/rep?t=payments"><i>💵</i>دفعات العملاء</a>
      ${can('sales_orders', 'view') ? '<a class="tile" href="#/orders?t=sales_order"><i>📝</i>طلبات المبيعات</a>' : ''}
      ${can('reports', 'view') || can('customers', 'view') ? '<a class="tile" href="#/party-ledger?type=customer"><i>📄</i>كشف حساب</a>' : ''}
      ${sup ? '<a class="tile" href="#/rep?t=team"><i>🧭</i>فريقي (المشرف)</a>' : ''}</div>`;
  } else if (tab === 'customers') {
    body = `<a class="btn sm back" href="#/rep">→ رجوع</a><input class="search" id="s" placeholder="🔎 ابحث بالاسم أو الرمز أو الهاتف…"><div id="cl"></div>`;
  } else if (tab === 'visits' || tab === 'team') {
    if (tab === 'team' && !sup) return void (v.innerHTML = '<div class="notice">هالشاشة للمشرف</div>');
    const isD = (x) => /^\d{4}-\d{2}-\d{2}$/.test(x || '');
    const from = isD(q('from')) ? q('from') : today().slice(0, 8) + '01', to = isD(q('to')) ? q('to') : today();
    let qy = sb.from('sales_visits').select('*').eq('company_id', S.company.id).gte('started_at', from + 'T00:00:00+03:00').lte('started_at', to + 'T23:59:59+03:00').order('started_at', { ascending: false }).limit(500);
    if (tab === 'visits') qy = qy.eq('user_id', S.session?.user?.id);
    const [vs, rep] = await Promise.all([qy, tab === 'team' ? sb.rpc('visits_report', { p_company: S.company.id, p_from: from, p_to: to }) : { data: null }]);
    const uids = [...new Set((vs.data || []).map(x => x.user_id).concat((rep.data || []).map(x => x.user_id)))];
    const names = uids.length ? Object.fromEntries(((await sb.rpc('user_names', { p_ids: uids })).data || []).map(u => [u.id, u.name || u.full_name || u.username])) : {};
    body = `<a class="btn sm back" href="#/rep">→ رجوع</a>
      <div class="card" style="display:flex;gap:8px;flex-wrap:wrap;align-items:end;padding:10px"><div class="field"><label>من</label><input type="date" id="fr" value="${from}"></div><div class="field"><label>إلى</label><input type="date" id="tt" value="${to}"></div><button class="btn primary" id="go">عرض</button></div>
      ${tab === 'team' ? `<h3>ملخص المندوبين</h3><div class="card table-wrap"><table class="t"><thead><tr><th>المستخدم</th><th>زيارات</th><th>مفتوحة</th><th>الدقائق</th><th>عملاء</th><th>تكسي</th><th>مواقف</th><th>المحصّل</th></tr></thead><tbody>
        ${(rep.data || []).map(r => `<tr><td>${esc(names[r.user_id] || '')}</td><td class="n">${r.visits}</td><td class="n">${r.open_visits ? `<span class="badge ok">${r.open_visits}</span>` : 0}</td><td class="n">${num(r.minutes)}</td><td class="n">${r.customers}</td><td class="n">${fmtNum(r.taxi)}</td><td class="n">${fmtNum(r.parking)}</td><td class="n"><b>${fmtNum(r.payments)}</b></td></tr>`).join('') || '<tr><td colspan="8" class="empty">ما في</td></tr>'}</tbody></table></div><h3>الزيارات</h3>` : ''}
      ${(vs.data || []).map(x => `<div class="cc"><div class="ctop"><b style="flex:1">${esc(pBy[x.party_id]?.name || '')}</b>${x.status === 'open' ? '<span class="badge ok">جارية</span>' : x.status === 'cancelled' ? '<span class="badge bad">ملغاة</span>' : '<span class="badge">منتهية</span>'}</div>
        <div class="muted" style="font-size:13px">${tab === 'team' ? esc(names[x.user_id] || '') + ' · ' : ''}${fmtDateTime(x.started_at)} · المدة ${dur(x.started_at, x.ended_at)}${num(x.taxi_fee) || num(x.parking_fee) ? ` · مواصلات ${fmtNum(num(x.taxi_fee) + num(x.parking_fee))}` : ''}</div>
        ${x.purpose || x.notes || x.outcome ? `<div style="font-size:13px">${esc([x.purpose, x.outcome, x.notes].filter(Boolean).join(' — '))}</div>` : ''}
        <div class="acts">${x.start_lat != null ? `<a class="btn sm" target="_blank" rel="noopener" href="${mapLink(x.start_lat, x.start_lng)}">📍 موقع البداية</a>` : ''}${x.end_lat != null ? `<a class="btn sm" target="_blank" rel="noopener" href="${mapLink(x.end_lat, x.end_lng)}">📍 موقع النهاية</a>` : ''}
          <button class="btn sm" data-ph="${x.id}">📷 الصور</button>${sup && x.status === 'open' ? `<button class="btn sm danger" data-vx="${x.id}">إلغاء</button>` : ''}</div></div>`).join('') || '<div class="empty">ما في زيارات بهالفترة</div>'}`;
  } else if (tab === 'payments') {
    const [ents, chq] = await Promise.all([
      sb.from('journal_entries').select('id,entry_date,total,status,party_name,description,doc_code,entry_no,created_at,journal_lines(debit)').eq('company_id', S.company.id).eq('entry_type', 'receipt').eq('created_by', S.session?.user?.id).order('created_at', { ascending: false }).limit(50),
      sb.from('cheques').select('id,cheque_no,amount,due_date,status,created_at,party_id,visit_id').eq('company_id', S.company.id).eq('created_by', S.session?.user?.id).order('created_at', { ascending: false }).limit(50)]);
    const entAmt = (e) => e.status === 'posted' ? num(e.total) : (e.journal_lines || []).reduce((a, l) => a + num(l.debit), 0);
    const chqHTML = (chq.data || []).map(c => `<div class="cc"><div class="ctop"><b style="flex:1">🧾 شيك ${esc(c.cheque_no)} — ${esc(pBy[c.party_id]?.name || '')}</b><b>${fmtNum(c.amount)}</b></div><div class="muted" style="font-size:13px">استحقاق ${fmtDate(c.due_date)}</div></div>`).join('');
    body = `<a class="btn sm back" href="#/rep">→ رجوع</a> <button class="btn primary" id="newpay" style="margin-bottom:10px">➕ دفعة جديدة</button>
      ${chqHTML}${(ents.data || []).map(e => `<div class="cc"><div class="ctop"><b style="flex:1">${esc(e.party_name || '')}</b><b>${fmtNum(entAmt(e))}</b></div><div class="muted" style="font-size:13px">${fmtDate(e.entry_date)} · ${esc(e.doc_code || e.entry_no || '')} · ${e.status === 'posted' ? 'مثبت' : 'قيد الانتظار'}</div></div>`).join('') || '<div class="empty">ما في دفعات مسجّلة منك</div>'}`;
  }
  v.innerHTML = head + `<div class="rep"><div class="page-head"><h2>📱 تطبيق المندوب</h2></div>${visCard}${body}</div>`;
  if (ov) { timer = setInterval(() => { const t = document.getElementById('tm'); if (!t) return clearInterval(timer); t.textContent = dur(ov.started_at); }, 1000); }
  const startVisit = async (p) => {
    if (ov) return toast('عندك زيارة مفتوحة، أنهيها أول', 'err');
    const g = await geo();
    const { error } = await sb.rpc('visit_start', { p_company: S.company.id, p_party: p.id, p_lat: g?.lat ?? null, p_lng: g?.lng ?? null, p_purpose: null });
    if (error) return toast(arError(error), 'err');
    toast(g ? 'بلّشت الزيارة' : 'بلّشت الزيارة (بدون موقع)', 'ok'); ctx.rerender();
  };
  v.querySelector('#v-end')?.addEventListener('click', () => {
    const m = modal({ title: `⏹ إنهاء زيارة: ${pBy[ov.party_id]?.name || ''}`, size: 'sm', body: `<form id="f">
      <div class="field"><label>نتيجة الزيارة</label><select name="outcome"><option>تمت بنجاح</option><option>طلب جديد</option><option>تحصيل</option><option>العميل مش موجود</option><option>متابعة لاحقاً</option></select></div>
      <div class="field"><label>ملاحظات</label><textarea name="notes" style="min-height:60px"></textarea></div>
      <div class="grid cols-2"><div class="field"><label>أجرة تكسي</label><input name="taxi" inputmode="decimal" dir="ltr" value="0"></div><div class="field"><label>مواقف</label><input name="parking" inputmode="decimal" dir="ltr" value="0"></div></div></form>`,
      foot: '<button class="btn primary" data-ok>⏹ إنهاء</button><button class="btn" data-close>رجوع</button>' });
    m.el.querySelector('[data-ok]').onclick = async () => {
      const f = Object.fromEntries(new FormData(m.el.querySelector('#f'))); const g = await geo();
      const { error } = await sb.rpc('visit_end', { p_id: ov.id, p_lat: g?.lat ?? null, p_lng: g?.lng ?? null, p_notes: f.notes, p_outcome: f.outcome, p_taxi: num(f.taxi), p_parking: num(f.parking) });
      if (error) return toast(arError(error), 'err'); toast('انتهت الزيارة', 'ok'); m.close(); ctx.rerender();
    };
  });
  v.querySelector('#v-photo')?.addEventListener('click', () => openAttachments('visit', ov.id, 'صور الزيارة'));
  v.querySelector('#v-pay')?.addEventListener('click', () => payForm(ctx, pBy[ov.party_id], ov, cust));
  v.querySelector('#newpay')?.addEventListener('click', () => payForm(ctx, ov ? pBy[ov.party_id] : null, ov, cust));
  v.querySelectorAll('[data-ph]').forEach(b => b.onclick = () => openAttachments('visit', b.dataset.ph, 'صور الزيارة'));
  v.querySelectorAll('[data-vx]').forEach(b => b.onclick = async () => { const { error } = await sb.rpc('visit_cancel', { p_id: b.dataset.vx }); if (error) return toast(arError(error), 'err'); ctx.rerender(); });
  v.querySelector('#go')?.addEventListener('click', () => { location.hash = `#/rep?t=${tab}&from=${v.querySelector('#fr').value}&to=${v.querySelector('#tt').value}`; });
  const cl = v.querySelector('#cl');
  if (cl) {
    const draw = (t = '') => {
      t = t.trim().toLowerCase();
      cl.innerHTML = cust.filter(p => !t || [p.name, p.code, p.mobile, p.phone].some(x => String(x || '').toLowerCase().includes(t))).slice(0, 80).map(p => `<div class="cc">
        <div class="ctop"><b style="flex:1">${esc(p.name)}</b><span class="muted">${esc(p.code)}</span></div><div class="muted" style="font-size:13px">${esc([p.city, p.address].filter(Boolean).join(' - '))}</div>
        <div class="acts"><button class="btn sm primary" data-st="${p.id}">▶ زيارة</button><button class="btn sm" data-pay="${p.id}">💵 دفعة</button>
          ${p.mobile || p.phone ? `<a class="btn sm" href="tel:${esc(p.mobile || p.phone)}">📞</a><a class="btn sm" target="_blank" rel="noopener" href="https://wa.me/${phone962(p.mobile || p.phone)}">💬</a>` : ''}
          <a class="btn sm" href="#/party-ledger?type=customer&id=${p.id}">📄 كشف</a></div></div>`).join('') || '<div class="empty">ما في نتائج</div>';
    };
    draw(); v.querySelector('#s').oninput = (e) => draw(e.target.value);
    cl.addEventListener('click', (e) => {
      const s = e.target.closest('[data-st]'); if (s) return startVisit(pBy[s.dataset.st]);
      const pp = e.target.closest('[data-pay]'); if (pp) return payForm(ctx, pBy[pp.dataset.pay], ov && ov.party_id === pp.dataset.pay ? ov : null, cust);
    });
  }
}

// نموذج دفعة: نقد / تحويل / شيكات
async function payForm(ctx, party, visit, cust) {
  const [accs, lk] = await Promise.all([loadAccounts(), loadLookups()]);
  const cashAccs = leafAccounts(accs).filter(a => ['cash', 'bank'].includes(a.account_type));
  const pms = lk.filter(r => r.kind === 'payment_method' && r.is_active && r.account_id && r.use_sales !== false && cashAccs.some(a => a.id === r.account_id));
  const banks = lk.filter(r => r.kind === 'bank' && r.is_active);
  let kind = 'cash', chqs = [{ cheque_no: '', amount: '', due_date: '', bank_name: '' }];
  const m = modal({ title: '💵 دفعة عميل', body: `<form id="f">
      <div class="field"><label>العميل *</label><select name="party_id" ${visit ? 'disabled' : ''}><option value="">— اختار —</option>${cust.map(p => `<option value="${p.id}" ${p.id === party?.id ? 'selected' : ''}>${esc(p.code)} — ${esc(p.name)}</option>`).join('')}</select></div>
      <div class="tabs" id="kt"><div class="tab active" data-k="cash">💵 نقد</div><div class="tab" data-k="transfer">🏦 تحويل</div>${can('cheques', 'add') ? '<div class="tab" data-k="cheques">🧾 شيكات</div>' : ''}</div>
      <div id="kb"></div>
      <div class="grid cols-2"><div class="field"><label>التاريخ</label><input type="date" name="pay_date" value="${today()}"></div><div class="field"><label>المرجع</label><input name="reference"></div></div>
      <div class="field"><label>الوصف</label><input name="notes"></div></form>${visit ? '<p class="muted" style="font-size:13px">الدفعة رح تنربط بالزيارة الجارية.</p>' : ''}`,
    foot: '<button class="btn primary" data-save>💾 حفظ الدفعة</button><button class="btn" data-close>إلغاء</button>' });
  const kb = m.el.querySelector('#kb');
  const accOpts = () => `${pms.map(r => `<option value="${r.account_id}">💳 ${esc(r.name)}</option>`).join('')}${cashAccs.map(a => `<option value="${a.id}">${esc(accLabel(a))}</option>`).join('')}`;
  const drawK = () => {
    if (kind !== 'cheques') {
      kb.innerHTML = `<div class="grid cols-2"><div class="field"><label>المبلغ *</label><input name="amount" inputmode="decimal" dir="ltr" style="font-size:20px"></div>
        <div class="field"><label>${kind === 'cash' ? 'الصندوق' : 'البنك'} *</label><select name="account_id">${accOpts()}</select></div></div>`;
      return;
    }
    kb.innerHTML = `<div id="chl">${chqs.map((c, i) => `<div class="card" style="padding:8px;margin-bottom:6px"><div class="grid cols-2">
        <div class="field"><label>رقم الشيك *</label><input data-c="cheque_no" data-i="${i}" value="${esc(c.cheque_no)}" dir="ltr"></div><div class="field"><label>المبلغ *</label><input data-c="amount" data-i="${i}" value="${esc(c.amount)}" inputmode="decimal" dir="ltr"></div>
        <div class="field"><label>تاريخ الاستحقاق *</label><input type="date" data-c="due_date" data-i="${i}" value="${esc(c.due_date)}"></div><div class="field"><label>البنك المسحوب عليه</label><input data-c="bank_name" data-i="${i}" value="${esc(c.bank_name)}" list="rep-banks"></div>
        <div class="field" style="grid-column:span 2"><label>اسم الساحب</label><input data-c="drawer_name" data-i="${i}" value="${esc(c.drawer_name || '')}"></div></div>
        ${chqs.length > 1 ? `<button type="button" class="btn sm danger" data-rm="${i}">حذف الشيك</button>` : ''}</div>`).join('')}</div>
      <datalist id="rep-banks">${banks.map(b => `<option value="${esc(b.name)}">`).join('')}</datalist>
      <button type="button" class="btn sm" id="addc">➕ شيك</button> <b id="ctot" style="margin-inline-start:10px"></b>`;
    const tot = () => { m.el.querySelector('#ctot').textContent = 'المجموع: ' + fmtNum(chqs.reduce((s, c) => s + num(c.amount), 0)); };
    tot();
    kb.querySelector('#addc').onclick = () => { chqs.push({ cheque_no: '', amount: '', due_date: '', bank_name: chqs[chqs.length - 1]?.bank_name || '' }); drawK(); };
    kb.oninput = (e) => { const c = e.target.dataset.c; if (c) { chqs[+e.target.dataset.i][c] = e.target.value; tot(); } };
    kb.onclick = (e) => { const r = e.target.closest('[data-rm]'); if (r) { chqs.splice(+r.dataset.rm, 1); drawK(); } };
  };
  drawK();
  m.el.querySelector('#kt').onclick = (e) => { const t = e.target.closest('[data-k]'); if (!t) return; kind = t.dataset.k; m.el.querySelectorAll('#kt .tab').forEach(x => x.classList.toggle('active', x === t)); drawK(); };
  m.el.querySelector('[data-save]').onclick = async (ev) => {
    const f = Object.fromEntries(new FormData(m.el.querySelector('#f')));
    const pid = visit ? visit.party_id : f.party_id; if (!pid) return toast('اختار العميل', 'err');
    const p = { company_id: S.company.id, party_id: pid, kind, pay_date: f.pay_date, reference: f.reference, notes: f.notes, visit_id: visit?.id || null };
    if (kind === 'cheques') {
      if (chqs.some(c => !c.cheque_no || !num(c.amount) || !c.due_date)) return toast('عبّي رقم الشيك والمبلغ والاستحقاق لكل شيك', 'err');
      p.cheques = chqs.map(c => ({ ...c, amount: num(c.amount) }));
    } else { p.amount = num(f.amount); p.account_id = f.account_id; if (p.amount <= 0) return toast('اكتب المبلغ', 'err'); }
    ev.target.disabled = true;
    const { data, error } = await sb.rpc('mobile_payment', { p });
    ev.target.disabled = false;
    if (error) return toast(arError(error), 'err');
    const pt = cust.find(x => x.id === pid);
    const msg = `${S.company.name}\nتم استلام دفعة من ${data.party}\nالمبلغ: ${fmtNum(data.total)} دينار${kind === 'cheques' ? ` (${chqs.length} شيك)` : ''}\nالتاريخ: ${fmtDate(f.pay_date)}\nشكراً لكم.`;
    const ok = modal({ title: '✅ تم حفظ الدفعة بنجاح', size: 'sm', body: `<p style="font-size:18px;text-align:center"><b>${fmtNum(data.total)}</b> دينار من <b>${esc(data.party)}</b></p>
      ${data.posted ? '' : '<p class="muted">الدفعة محفوظة «قيد الانتظار» لحد ما المحاسب يثبّتها.</p>'}
      <div style="display:flex;gap:8px;flex-wrap:wrap;justify-content:center"><button class="btn" data-prn>🖨️ طباعة</button>
        <a class="btn" target="_blank" rel="noopener" href="https://wa.me/${phone962(data.mobile)}?text=${encodeURIComponent(msg)}">💬 واتساب</a>
        <a class="btn" href="sms:${esc(data.mobile || '')}?body=${encodeURIComponent(msg)}">✉️ رسالة نصية</a></div>`,
      foot: '<button class="btn primary" data-close>تم</button>' });
    ok.el.querySelector('[data-prn]').onclick = () => printDoc('إيصال استلام دفعة', `<p><b>استلمنا من:</b> ${esc(data.party)} &nbsp; <b>التاريخ:</b> ${fmtDate(f.pay_date)}${f.reference ? ` &nbsp; <b>المرجع:</b> ${esc(f.reference)}` : ''}</p>
      ${kind === 'cheques' ? `<table class="t"><thead><tr><th>رقم الشيك</th><th>البنك</th><th>الاستحقاق</th><th>المبلغ</th></tr></thead><tbody>${chqs.map(c => `<tr><td>${esc(c.cheque_no)}</td><td>${esc(c.bank_name || '')}</td><td>${fmtDate(c.due_date)}</td><td class="n">${fmtNum(c.amount)}</td></tr>`).join('')}</tbody></table>` : `<p><b>طريقة الدفع:</b> ${kind === 'cash' ? 'نقداً' : 'تحويل بنكي'}</p>`}
      <p><b>المبلغ:</b> ${fmtNum(data.total)} دينار — ${esc(amountToWords(data.total))}</p>${f.notes ? `<p>${esc(f.notes)}</p>` : ''}`, { kind: 'receipt' });
    ok.el.querySelector('[data-close]').addEventListener('click', () => ctx.rerender());
  };
}

export const REP_ROUTES = { 'rep': viewRep };
