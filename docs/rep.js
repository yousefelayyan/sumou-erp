// =====================================================================
//  السمو ERP — تطبيق المندوب (للجوال): العملاء، الزيارات، دفعات العملاء
//  route: rep  (?t=customers|visits|payments|team)
// =====================================================================
import { S, sb, esc, fmtNum, fmtDate, fmtDateTime, num, today, toast, arError, modal, can, qm } from './core.js';
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

// ---- طابور بدون إنترنت: العمليات بتنحفظ على الجهاز وبتنبعت لما يرجع النت (offline_sync، كل عملية إلها رقم ما بيتكرر)
const QK = () => `sumou.repq.${S.company?.id}.${S.session?.user?.id}`;
const qGet = () => { try { return JSON.parse(localStorage.getItem(QK()) || '[]'); } catch (e) { return []; } };
const qSet = (a) => { try { localStorage.setItem(QK(), JSON.stringify(a)); } catch (e) { } };
const newRef = () => (crypto.randomUUID ? crypto.randomUUID() : Date.now().toString(36) + Math.random().toString(36).slice(2)).replace(/-/g, '').slice(0, 32);
const netErr = (e) => !navigator.onLine || /fetch|network|load failed|timeout/i.test(String(e?.message || e || ''));
function qPush(op, p, label) { const a = qGet(); a.push({ ref: newRef(), op, p, label, at: new Date().toISOString() }); qSet(a); }
let flushing = false;
export async function flushRepQueue(silent) {
  if (flushing || !S.company || !navigator.onLine) return 0;
  const a = qGet(); if (!a.length) return 0;
  flushing = true; let done = 0; const keep = [];
  for (const it of a) {
    const { data, error } = await sb.rpc('offline_sync', { p_company: S.company.id, p_ref: it.ref, p_op: it.op, p: it.p });
    if (!error) { done++; continue; }
    if (netErr(error)) { keep.push(it); continue; }
    keep.push({ ...it, err: arError(error) });
  }
  qSet(keep); flushing = false;
  if (!silent && done) toast(`تمت مزامنة ${done} عملية`, 'ok');
  return done;
}
if (typeof window !== 'undefined' && !window.__repQ) { window.__repQ = 1; window.addEventListener('online', () => flushRepQueue().then(n => { if (n && location.hash.startsWith('#/rep')) window.dispatchEvent(new HashChangeEvent('hashchange')); })); }
const km = (m) => m == null ? '' : m >= 1000 ? (m / 1000).toFixed(1) + ' كم' : m + ' م';
const geoBadge = (x) => x.geo_ok === false ? `<span class="badge bad" title="بعيد عن موقع العميل">⚠️ بعيد ${km(x.distance_m)}</span>` : x.geo_ok ? `<span class="badge ok" title="عند العميل">📍 ${km(x.distance_m)}</span>` : '';

async function viewRep(v, ctx) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  if (!can('rep_visits', 'view')) return void (v.innerHTML = '<div class="notice">ما عندك صلاحية تطبيق المندوب</div>');
  clearInterval(timer);
  const tab = q('t') || 'home';
  if (navigator.onLine && qGet().length) await flushRepQueue();
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
  const pend = qGet();
  const qBar = pend.length ? `<div class="notice ${pend.some(x => x.err) ? '' : 'info'}" style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">📴 ${pend.length} عملية محفوظة على الجهاز بانتظار الإنترنت
      <button class="btn sm" id="q-sync">🔄 مزامنة الآن</button><button class="btn sm" id="q-show">عرض</button></div>` : (navigator.onLine ? '' : '<div class="notice info">📴 ما في إنترنت — الدفعات وإنهاء الزيارة رح ينحفظوا على الجهاز وينبعتوا لحالهم.</div>');
  const visCard = ov ? `<div class="vis"><div>🟢 زيارة جارية</div><b>${esc(pBy[ov.party_id]?.name || '')}</b><div class="tm" id="tm">${dur(ov.started_at)}</div>
      <div style="display:flex;gap:8px;justify-content:center;flex-wrap:wrap"><button class="btn" id="v-pay">💵 دفعة</button><button class="btn" id="v-photo">📷 صور</button><button class="btn danger" id="v-end">⏹ إنهاء الزيارة</button></div></div>` : '';
  let body = '';
  if (tab === 'home') {
    body = `<div class="tiles">
      <a class="tile" href="#/rep?t=mine"><i>📊</i>زبائني</a>
      <a class="tile" href="#/rep?t=customers"><i>👥</i>العملاء</a>
      <a class="tile" href="#/rep?t=visits"><i>📍</i>زياراتي</a>
      <a class="tile" href="#/rep?t=payments"><i>💵</i>دفعات العملاء</a>
      <a class="tile" href="#/rep?t=map"><i>🗺️</i>خريطة العملاء</a>
      <a class="tile" href="#/rep?t=km"><i>🚗</i>المسافات والمواصلات</a>
      ${can('sales_orders', 'view') ? '<a class="tile" href="#/orders?t=sales_order"><i>📝</i>طلبات المبيعات</a>' : ''}
      ${can('reports', 'view') || can('customers', 'view') ? '<a class="tile" href="#/party-ledger?type=customer"><i>📄</i>كشف حساب</a>' : ''}
      ${sup ? '<a class="tile" href="#/rep?t=team"><i>🧭</i>فريقي (المشرف)</a>' : ''}</div>`;
  } else if (tab === 'mine') {
    // «زبائني»: حركات وأرقام وحالة زبائن المندوب، مع فلتر يوم المسار
    const DAYS = ['الأحد', 'الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت'];
    const isD = (x) => /^\d{4}-\d{2}-\d{2}$/.test(x || '');
    const from = isD(q('from')) ? q('from') : today().slice(0, 8) + '01', to = isD(q('to')) ? q('to') : today();
    const day = /^[0-6]$/.test(q('day') || '') ? +q('day') : null, rep = /^[0-9a-f-]{36}$/.test(q('rep') || '') ? q('rep') : null, all = q('all') === '1';
    const r = await sb.rpc('rep_customers_dash', { p_company: S.company.id, p_from: from, p_to: to, p_rep: rep, p_day: day, p_all: all });
    if (r.error) return void (v.innerHTML = head + `<div class="rep"><div class="notice">${esc(arError(r.error))}</div></div>`);
    const D = r.data || {};
    const link = (o) => { const p = new URLSearchParams({ t: 'mine', from, to, ...(day != null ? { day } : {}), ...(rep ? { rep } : {}), ...(all ? { all: 1 } : {}), ...o }); [...p.keys()].forEach(k => { if (p.get(k) === '') p.delete(k); }); return '#/rep?' + p.toString(); };
    const st = (n) => D.customers ? Math.round(n / D.customers * 100) : 0;
    const box = (ico, n, l, col) => `<div class="tile" style="cursor:default"><i>${ico}</i><b style="font-size:20px;${col ? 'color:' + col : ''}">${n}</b><div class="muted" style="font-size:12px">${l}</div></div>`;
    const sec = (id, title, inner, open) => `<details class="cc" ${open ? 'open' : ''}><summary style="font-weight:700;cursor:pointer">${title}</summary><div style="margin-top:10px">${inner}</div></details>`;
    const list = (rows, col) => `<table class="t"><thead><tr><th>#</th><th>الزبون</th><th>فواتير المبيعات</th></tr></thead><tbody>${(rows || []).map((x, i) => `<tr><td>${i + 1}</td><td>${esc(x.name)}${x.last_date ? `<div class="muted" style="font-size:11px">آخر فاتورة ${fmtDate(x.last_date)}</div>` : ''}</td><td class="n" style="color:${col}">${fmtNum(x.amount)}</td></tr>`).join('') || '<tr><td colspan="3" class="empty">ما في</td></tr>'}</tbody></table>`;
    body = `<a class="btn sm back" href="#/rep">→ رجوع</a>
      ${!D.has_rep && !D.supervisor ? '<div class="notice">ما في مندوب مربوط بحسابك. خلّي المدير يربطك من «إعداد ← مندوبي المبيعات».</div>' : ''}
      <div class="card" style="display:flex;gap:8px;flex-wrap:wrap;align-items:end;padding:10px">
        <div class="field"><label>من</label><input type="date" id="fr" value="${from}"></div><div class="field"><label>إلى</label><input type="date" id="to" value="${to}"></div>
        ${D.supervisor ? `<div class="field"><label>المندوب</label><select id="rp"><option value="">مندوبي أنا</option><option value="all" ${all ? 'selected' : ''}>كل المندوبين</option>${(D.reps || []).map(x => `<option value="${x.id}" ${x.id === rep ? 'selected' : ''}>${esc(x.name)}</option>`).join('')}</select></div>` : ''}
        <button class="btn primary" id="go">عرض</button></div>
      <div class="tabs" style="margin:6px 0 10px;overflow:auto"><a class="tab ${day == null ? 'active' : ''}" href="${link({ day: '' })}">الجميع</a>${DAYS.map((d, i) => `<a class="tab ${day === i ? 'active' : ''}" href="${link({ day: i })}">${d}</a>`).join('')}</div>
      ${sec('m', '📦 الحركات', `<div class="tiles">${box('💵', fmtNum(D.payments), `دفعات الزبائن (${D.payments_n || 0})`)}${box('🧾', fmtNum(D.invoices), `فواتير المبيعات (${D.invoices_n || 0})`)}${box('📝', fmtNum(D.orders), `طلبات المبيعات (${D.orders_n || 0})`)}</div>`, true)}
      ${sec('c', '👥 زبائني', `<div class="tiles">${box('👥', D.customers || 0, 'الزبائن')}${box('🛒', D.buyers || 0, 'اشتروا')}${box('🆕', D.first_time || 0, 'اشتروا لأول مرة')}
        ${box('💵', D.payers || 0, 'دفعوا')}${box('🧾', fmtNum(D.avg_invoice), 'متوسط الفاتورة')}${box('📈', (D.invoices ? Math.round(num(D.payments) / num(D.invoices) * 100) : 0) + '٪', 'نسبة التحصيل')}</div>`)}
      ${sec('s', '📶 حالة الزبائن <span class="muted" style="font-weight:400;font-size:12px">حسب آخر فاتورة: نشط لحد 30 يوم، متراجع لحد 60، متوقف بعدها</span>', `<table class="t"><tbody>
        <tr><td>🟢 نشط</td><td class="n">${D.active || 0}</td><td class="n">${st(D.active)}٪</td></tr><tr><td>🟡 متراجع</td><td class="n">${D.slipping || 0}</td><td class="n">${st(D.slipping)}٪</td></tr>
        <tr><td>🔴 متوقف</td><td class="n">${D.stopped || 0}</td><td class="n">${st(D.stopped)}٪</td></tr><tr><td>⚪ لم يشترِ</td><td class="n">${D.never || 0}</td><td class="n">${st(D.never)}٪</td></tr></tbody></table>`)}
      ${sec('t', '🏆 أكثر الزبائن شراء', list(D.top, 'var(--ok)'))}
      ${sec('b', '📉 أقل الزبائن شراء', list(D.bottom, 'var(--bad)'))}`;
  } else if (tab === 'map') {
    body = `<a class="btn sm back" href="#/rep">→ رجوع</a> <button class="btn sm" id="mp-me">📍 موقعي</button> <span class="muted" style="font-size:13px">${cust.filter(p => p.geo_lat != null).length} من ${cust.length} عميل إلهم موقع</span>
      <div id="map" style="height:62vh;border-radius:14px;margin-top:8px;border:1px solid var(--line,#e5e7eb)"></div>
      ${cust.some(p => p.geo_lat == null) ? `<details class="cc" style="margin-top:8px"><summary style="cursor:pointer;font-weight:700">عملاء بدون موقع (${cust.filter(p => p.geo_lat == null).length})</summary><div class="muted" style="font-size:12px;margin:6px 0">بتقدر تحفظ الموقع من بطاقة العميل، أو أول زيارة بتحفظه إذا الإعداد مفعّل.</div>${cust.filter(p => p.geo_lat == null).slice(0, 200).map(p => `<div>${esc(p.code)} — ${esc(p.name)}</div>`).join('')}</details>` : ''}`;
  } else if (tab === 'km') {
    const isD = (x) => /^\d{4}-\d{2}-\d{2}$/.test(x || '');
    const from = isD(q('from')) ? q('from') : today().slice(0, 8) + '01', to = isD(q('to')) ? q('to') : today();
    const r = await sb.rpc('rep_km_report', { p_company: S.company.id, p_from: from, p_to: to });
    const rows = r.data || [];
    const uids = [...new Set(rows.map(x => x.user_id))];
    const names = uids.length ? Object.fromEntries(((await sb.rpc('user_names', { p_ids: uids })).data || []).map(u => [u.id, u.name || u.full_name || u.username])) : {};
    const per = {}; rows.forEach(x => { const o = per[x.user_id] ||= { visits: 0, km: 0, allowance: 0, taxi: 0, parking: 0, far: 0, days: 0 }; o.days++; o.visits += +x.visits; o.km += num(x.km); o.allowance += num(x.allowance); o.taxi += num(x.taxi); o.parking += num(x.parking); o.far += +x.far_visits; });
    body = `<a class="btn sm back" href="#/rep">→ رجوع</a> ${sup ? '<button class="btn sm" id="geo-set">⚙️ التحقق من الموقع وبدل الكيلو</button>' : ''}
      <div class="card" style="display:flex;gap:8px;flex-wrap:wrap;align-items:end;padding:10px"><div class="field"><label>من</label><input type="date" id="fr" value="${from}"></div><div class="field"><label>إلى</label><input type="date" id="tt" value="${to}"></div><button class="btn primary" id="go">عرض</button></div>
      ${r.error ? `<div class="notice">${esc(arError(r.error))}</div>` : ''}
      <p class="muted" style="font-size:13px">المسافة = مجموع المسافة بخط مستقيم بين مواقع بداية الزيارات بنفس اليوم بالترتيب. البدل = الكيلومترات × سعر الكيلو بالإعداد.</p>
      <h3>الملخص</h3><div class="card table-wrap"><table class="t"><thead><tr><th>المستخدم</th><th>أيام</th><th>زيارات</th><th>كم</th><th>بدل الكيلو</th><th>تكسي</th><th>مواقف</th><th>المجموع</th><th>زيارات بعيدة</th></tr></thead><tbody>
      ${Object.entries(per).map(([u, o]) => `<tr><td>${esc(names[u] || '')}</td><td class="n">${o.days}</td><td class="n">${o.visits}</td><td class="n">${o.km.toFixed(2)}</td><td class="n">${fmtNum(o.allowance)}</td><td class="n">${fmtNum(o.taxi)}</td><td class="n">${fmtNum(o.parking)}</td><td class="n"><b>${fmtNum(o.allowance + o.taxi + o.parking)}</b></td><td class="n">${o.far ? `<span class="badge bad">${o.far}</span>` : 0}</td></tr>`).join('') || '<tr><td colspan="9" class="empty">ما في</td></tr>'}</tbody></table></div>
      <h3>حسب اليوم</h3><div class="card table-wrap"><table class="t"><thead><tr><th>اليوم</th><th>المستخدم</th><th>زيارات</th><th>بموقع</th><th>كم</th><th>البدل</th><th>تكسي + مواقف</th></tr></thead><tbody>
      ${rows.map(x => `<tr><td>${fmtDate(x.day)}</td><td>${esc(names[x.user_id] || '')}</td><td class="n">${x.visits}</td><td class="n">${x.located}</td><td class="n">${num(x.km).toFixed(2)}</td><td class="n">${fmtNum(x.allowance)}</td><td class="n">${fmtNum(num(x.taxi) + num(x.parking))}</td></tr>`).join('') || '<tr><td colspan="7" class="empty">ما في</td></tr>'}</tbody></table></div>`;
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
      ${(vs.data || []).map(x => `<div class="cc"><div class="ctop"><b style="flex:1">${esc(pBy[x.party_id]?.name || '')}</b>${geoBadge(x)} ${x.status === 'open' ? '<span class="badge ok">جارية</span>' : x.status === 'cancelled' ? '<span class="badge bad">ملغاة</span>' : '<span class="badge">منتهية</span>'}</div>
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
  v.innerHTML = head + `<div class="rep"><div class="page-head"><h2>📱 تطبيق المندوب</h2></div>${qBar}${visCard}${body}</div>`;
  v.querySelector('#q-sync')?.addEventListener('click', async () => { if (!navigator.onLine) return toast('لسا ما في إنترنت', 'err'); await flushRepQueue(); ctx.rerender(); });
  v.querySelector('#q-show')?.addEventListener('click', () => {
    const m = modal({ title: '📴 عمليات بانتظار الإرسال', body: `<table class="t"><thead><tr><th>الوقت</th><th>العملية</th><th>الحالة</th><th></th></tr></thead><tbody>${qGet().map((x, i) => `<tr><td>${fmtDateTime(x.at)}</td><td>${esc(x.label || x.op)}</td><td>${x.err ? `<span style="color:var(--bad)">${esc(x.err)}</span>` : 'بالانتظار'}</td><td>${x.err ? `<button class="btn sm danger" data-qd="${i}">حذف</button>` : ''}</td></tr>`).join('')}</tbody></table>`, foot: '<button class="btn" data-close>إغلاق</button>' });
    m.el.querySelectorAll('[data-qd]').forEach(b => b.onclick = () => { if (!confirm('تحذف العملية من الجهاز؟ ما رح تنبعت.')) return; const a = qGet(); a.splice(+b.dataset.qd, 1); qSet(a); m.close(); ctx.rerender(); });
  });
  if (tab === 'map') drawMap(v, cust);
  v.querySelector('#geo-set')?.addEventListener('click', () => geoSettings(ctx));
  if (ov) { timer = setInterval(() => { const t = document.getElementById('tm'); if (!t) return clearInterval(timer); t.textContent = dur(ov.started_at); }, 1000); }
  const startVisit = async (p) => {
    if (ov) return toast('عندك زيارة مفتوحة، أنهيها أول', 'err');
    if (!navigator.onLine) return toast('بداية الزيارة بدها إنترنت (عشان التحقق من الموقع). الدفعة بتنحفظ على الجهاز.', 'err');
    const g = await geo();
    const { error } = await sb.rpc('visit_start', { p_company: S.company.id, p_party: p.id, p_lat: g?.lat ?? null, p_lng: g?.lng ?? null, p_purpose: null });
    if (error) return toast(arError(error), 'err');
    const d = g && p.geo_lat != null ? geoDist(g.lat, g.lng, p.geo_lat, p.geo_lng) : null;
    toast(!g ? 'بلّشت الزيارة (بدون موقع)' : d != null && d > (p.geo_radius || 300) ? `بلّشت الزيارة — ⚠️ إنت بعيد ${km(d)} عن موقع العميل` : 'بلّشت الزيارة', d != null && d > (p.geo_radius || 300) ? 'err' : 'ok'); ctx.rerender();
  };
  v.querySelector('#v-end')?.addEventListener('click', () => {
    const m = modal({ title: `⏹ إنهاء زيارة: ${pBy[ov.party_id]?.name || ''}`, size: 'sm', body: `<form id="f">
      <div class="field"><label>نتيجة الزيارة</label><select name="outcome"><option>تمت بنجاح</option><option>طلب جديد</option><option>تحصيل</option><option>العميل مش موجود</option><option>متابعة لاحقاً</option></select></div>
      <div class="field"><label>ملاحظات</label><textarea name="notes" style="min-height:60px"></textarea></div>
      <div class="grid cols-2"><div class="field"><label>أجرة تكسي</label><input name="taxi" inputmode="decimal" dir="ltr" value="0"></div><div class="field"><label>مواقف</label><input name="parking" inputmode="decimal" dir="ltr" value="0"></div></div></form>`,
      foot: '<button class="btn primary" data-ok>⏹ إنهاء</button><button class="btn" data-close>رجوع</button>' });
    m.el.querySelector('[data-ok]').onclick = async () => {
      const f = Object.fromEntries(new FormData(m.el.querySelector('#f'))); const g = await geo();
      const P = { visit_id: ov.id, lat: g?.lat ?? null, lng: g?.lng ?? null, notes: f.notes, outcome: f.outcome, taxi: num(f.taxi), parking: num(f.parking), ended_at: new Date().toISOString() };
      const { error } = navigator.onLine ? await sb.rpc('offline_sync', { p_company: S.company.id, p_ref: newRef(), p_op: 'visit_end', p: P }) : { error: { message: 'offline' } };
      if (error && !netErr(error)) return toast(arError(error), 'err');
      if (error) { qPush('visit_end', P, 'إنهاء زيارة: ' + (pBy[ov.party_id]?.name || '')); toast('📴 انحفظ إنهاء الزيارة على الجهاز، وبينبعت لما يرجع النت', 'ok'); m.close(); return ctx.rerender(); }
      toast('انتهت الزيارة', 'ok'); m.close(); ctx.rerender();
    };
  });
  v.querySelector('#v-photo')?.addEventListener('click', () => openAttachments('visit', ov.id, 'صور الزيارة'));
  v.querySelector('#v-pay')?.addEventListener('click', () => payForm(ctx, pBy[ov.party_id], ov, cust));
  v.querySelector('#newpay')?.addEventListener('click', () => payForm(ctx, ov ? pBy[ov.party_id] : null, ov, cust));
  v.querySelectorAll('[data-ph]').forEach(b => b.onclick = () => openAttachments('visit', b.dataset.ph, 'صور الزيارة'));
  v.querySelectorAll('[data-vx]').forEach(b => b.onclick = async () => { const { error } = await sb.rpc('visit_cancel', { p_id: b.dataset.vx }); if (error) return toast(arError(error), 'err'); ctx.rerender(); });
  v.querySelector('#go')?.addEventListener('click', () => {
    if (tab === 'mine') {
      const rp = v.querySelector('#rp')?.value || '', p = new URLSearchParams({ t: 'mine', from: v.querySelector('#fr').value, to: v.querySelector('#to').value });
      if (q('day')) p.set('day', q('day')); if (rp === 'all') p.set('all', '1'); else if (rp) p.set('rep', rp);
      return void (location.hash = '#/rep?' + p.toString());
    }
    location.hash = `#/rep?t=${tab}&from=${v.querySelector('#fr').value}&to=${v.querySelector('#tt').value}`;
  });
  const cl = v.querySelector('#cl');
  if (cl) {
    const draw = (t = '') => {
      t = t.trim().toLowerCase();
      cl.innerHTML = cust.filter(p => !t || qm([p.name, p.code, p.mobile, p.phone], t)).slice(0, 80).map(p => `<div class="cc">
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
      <div class="field" id="inv-f"><label>تسديد فاتورة (اختياري)</label><select name="invoice_id"><option value="">—</option></select></div>
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
  // فواتير العميل المفتوحة (للتسديد)
  const loadInv = async (pid) => {
    const sel = m.el.querySelector('[name=invoice_id]'); sel.innerHTML = '<option value="">—</option>';
    if (!pid) return;
    const { data, error } = await sb.rpc('party_open_invoices', { p_company: S.company.id, p_party: pid });
    if (error) { m.el.querySelector('#inv-f').style.display = 'none'; return; }
    sel.innerHTML += (data || []).filter(x => num(x.remaining) > 0).map(x => `<option value="${x.invoice_id}" data-rem="${x.remaining}">${esc(x.doc_code || String(x.inv_no))} — ${fmtDate(x.inv_date)} — متبقي ${fmtNum(x.remaining)}</option>`).join('');
  };
  loadInv(visit ? visit.party_id : party?.id);
  m.el.querySelector('[name=party_id]')?.addEventListener('change', (e) => loadInv(e.target.value));
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
    const { data, error } = navigator.onLine ? await sb.rpc('offline_sync', { p_company: S.company.id, p_ref: newRef(), p_op: 'payment', p }) : { error: { message: 'offline' } };
    ev.target.disabled = false;
    if (error && netErr(error)) {
      const pt0 = cust.find(x => x.id === pid);
      qPush('payment', p, `دفعة ${kind === 'cheques' ? 'شيكات' : kind === 'cash' ? 'نقد' : 'تحويل'} — ${pt0?.name || ''} — ${fmtNum(kind === 'cheques' ? p.cheques.reduce((a, c) => a + c.amount, 0) : p.amount)}`);
      toast('📴 ما في إنترنت: الدفعة انحفظت على الجهاز وبتنبعت لحالها لما يرجع النت', 'ok'); m.close(); return ctx.rerender();
    }
    if (error) return toast(arError(error), 'err');
    if (f.invoice_id && data.posted && data.entry_id && kind !== 'cheques') {
      const rem = num(m.el.querySelector(`[name=invoice_id] option[value="${f.invoice_id}"]`)?.dataset.rem);
      const r = await sb.rpc('allocate_payment', { p_entry: data.entry_id, p_party: pid, p_items: [{ invoice_id: f.invoice_id, amount: Math.min(num(data.total), rem || num(data.total)) }] });
      if (r.error) toast('الدفعة انحفظت، بس ما انربطت بالفاتورة: ' + arError(r.error), 'err');
    }
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

// المسافة بالمتر (نفس حساب قاعدة البيانات)
function geoDist(a, b, c, d) { const R = 6371000, r = (x) => x * Math.PI / 180; const h = Math.sin(r(c - a) / 2) ** 2 + Math.cos(r(a)) * Math.cos(r(c)) * Math.sin(r(d - b) / 2) ** 2; return Math.round(2 * R * Math.asin(Math.min(1, Math.sqrt(h)))); }

// خريطة العملاء (Leaflet + خرائط OpenStreetMap)
let leafletP = null;
function loadLeaflet() {
  if (window.L) return Promise.resolve(window.L);
  return leafletP ||= new Promise((res, rej) => {
    const css = document.createElement('link'); css.rel = 'stylesheet'; css.href = './lib/leaflet/leaflet.css'; document.head.appendChild(css);
    const js = document.createElement('script'); js.src = './lib/leaflet/leaflet.js'; js.onload = () => res(window.L); js.onerror = () => { leafletP = null; rej(new Error('map')); }; document.head.appendChild(js);
  });
}
async function drawMap(v, cust) {
  const el = v.querySelector('#map'); if (!el) return;
  let L; try { L = await loadLeaflet(); } catch (e) { el.innerHTML = '<div class="notice" style="margin:10px">ما قدرت أحمّل الخريطة (بدها إنترنت).</div>'; return; }
  const pts = cust.filter(p => p.geo_lat != null);
  const map = L.map(el).setView(pts.length ? [+pts[0].geo_lat, +pts[0].geo_lng] : [31.95, 35.91], 12);
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(map);
  const b = [];
  pts.forEach(p => { const ll = [+p.geo_lat, +p.geo_lng]; b.push(ll);
    L.marker(ll).addTo(map).bindPopup(`<b>${esc(p.name)}</b><br>${esc(p.code)}${p.mobile ? '<br>' + esc(p.mobile) : ''}<br><a target="_blank" rel="noopener" href="https://www.google.com/maps/dir/?api=1&destination=${ll[0]},${ll[1]}">🧭 الاتجاهات</a>`); });
  if (b.length > 1) map.fitBounds(b, { padding: [30, 30] });
  v.querySelector('#mp-me')?.addEventListener('click', async () => { const g = await geo(); if (!g) return toast('ما قدرت آخذ موقعك', 'err');
    L.circleMarker([g.lat, g.lng], { radius: 9, color: '#2563eb', fillOpacity: .8 }).addTo(map).bindPopup('موقعي').openPopup(); map.setView([g.lat, g.lng], 14); });
}

// إعداد التحقق من الموقع وبدل الكيلو (للمشرف)
async function geoSettings(ctx) {
  const { data } = await sb.from('company_settings').select('rep_geo').eq('company_id', S.company.id).maybeSingle();
  const g = data?.rep_geo || {};
  const m = modal({ title: '⚙️ التحقق من موقع الزيارة وبدل الكيلو', size: 'sm', body: `<form id="f">
    <div class="field"><label>التحقق لما يبلّش المندوب الزيارة</label><select name="mode">
      <option value="none" ${!g.mode || g.mode === 'none' ? 'selected' : ''}>بدون تحقق</option><option value="warn" ${g.mode === 'warn' ? 'selected' : ''}>تنبيه وعلامة «بعيد» بس</option><option value="block" ${g.mode === 'block' ? 'selected' : ''}>منع الزيارة إذا بعيد أو بدون موقع</option></select>
      <span class="hint">المشرف دايماً بيقدر يبلّش، وزيارته بتنعلّم إذا بعيدة.</span></div>
    <div class="field"><label>نصف القطر المسموح (متر)</label><input name="radius" value="${g.radius || 300}" inputmode="numeric" dir="ltr"><span class="hint">العميل اللي إله نصف قطر ببطاقته بياخذ تبعه.</span></div>
    <label class="check"><input type="checkbox" name="learn" ${g.learn ? 'checked' : ''}> أول زيارة لعميل بدون موقع بتحفظ موقعه</label>
    <div class="field"><label>بدل المواصلات لكل كيلو (دينار)</label><input name="km_rate" value="${g.km_rate || 0}" inputmode="decimal" dir="ltr"></div></form>`,
    foot: '<button class="btn primary" data-ok>💾 حفظ</button><button class="btn" data-close>إلغاء</button>' });
  m.el.querySelector('[data-ok]').onclick = async () => {
    const f = Object.fromEntries(new FormData(m.el.querySelector('#f')));
    const { error } = await sb.rpc('rep_geo_save', { p_company: S.company.id, p: { mode: f.mode, radius: parseInt(f.radius) || 300, learn: !!f.learn, km_rate: num(f.km_rate) } });
    if (error) return toast(arError(error), 'err'); toast('تم الحفظ', 'ok'); m.close(); ctx.rerender();
  };
}
