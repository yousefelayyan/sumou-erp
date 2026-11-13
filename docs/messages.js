// =====================================================================
//  السمو ERP — الرسائل (route messages?t=campaign|log|templates)
//  واتساب/رسالة نصية من الجهاز (wa.me / sms:) + نصوص جاهزة (company_settings.msg_templates) + سجل (message_log)
// =====================================================================
import { S, sb, esc, fmtNum, fmtDate, fmtDateTime, num, today, toast, arError, modal, can } from './core.js';
import { loadParties } from './parties.js';
import { loadLookups } from './lookups.js';

export const phone962 = (p) => { let ph = String(p || '').replace(/\D/g, ''); if (ph.startsWith('00')) ph = ph.slice(2); else if (ph.startsWith('0')) ph = '962' + ph.slice(1); else if (ph.length === 9 && ph.startsWith('7')) ph = '962' + ph; return ph; };
export const waLink = (phone, text) => `https://wa.me/${phone962(phone)}?text=${encodeURIComponent(text)}`;
export const smsLink = (phone, text) => `sms:${String(phone || '').replace(/[^\d+]/g, '')}?body=${encodeURIComponent(text)}`;

export const DEFAULT_TPL = {
  invoice: 'مرحباً [الاسم]،\nفاتورة رقم [رقم الفاتورة] بتاريخ [التاريخ]\nالمبلغ: [المبلغ] دينار\nرصيدكم الحالي: [الرصيد] دينار\nشكراً لتعاملكم مع [الشركة]',
  statement: 'مرحباً [الاسم]،\nرصيد حسابكم لدى [الشركة] بتاريخ [التاريخ]: [الرصيد] دينار.',
  payment: 'مرحباً [الاسم]،\nتم استلام دفعة بمبلغ [المبلغ] دينار بتاريخ [التاريخ]. شكراً لكم.\n[الشركة]',
  reminder: 'مرحباً [الاسم]،\nنذكّركم برصيد مستحق بقيمة [الرصيد] دينار. نرجو التكرم بالسداد.\n[الشركة]',
  campaign: 'مرحباً [الاسم]،\n[الشركة] بتقدّملكم عرض خاص…',
};
const VARS = ['[الاسم]', '[الشركة]', '[التاريخ]', '[المبلغ]', '[الرصيد]', '[رقم الفاتورة]'];
export async function msgTemplates() {
  if (S._msgtpl?.cid === S.company?.id) return S._msgtpl.t;
  const { data } = await sb.from('company_settings').select('msg_templates').eq('company_id', S.company.id).maybeSingle();
  const t = { ...DEFAULT_TPL, ...(data?.msg_templates || {}) };
  S._msgtpl = { cid: S.company.id, t }; return t;
}
export const fillTpl = (tpl, v) => String(tpl || '').replace(/\[الاسم\]/g, v.name ?? '').replace(/\[الشركة\]/g, S.company?.name ?? '')
  .replace(/\[التاريخ\]/g, v.date ? fmtDate(v.date) : fmtDate(today())).replace(/\[المبلغ\]/g, v.amount != null ? fmtNum(v.amount) : '')
  .replace(/\[الرصيد\]/g, v.balance != null ? fmtNum(v.balance) : '').replace(/\[رقم الفاتورة\]/g, v.no ?? '');
export async function logMessage({ party_id = null, phone, channel = 'whatsapp', kind = 'other', ref_id = null, body, campaign = null }) {
  const { error } = await sb.from('message_log').insert({ company_id: S.company.id, party_id, phone, channel, kind, ref_id, body: String(body).slice(0, 2000), campaign });
  if (error) console.warn(error.message);
}
// زر جاهز: بيفتح واتساب وبيسجّل
export function sendWhatsApp(opts) {
  if (!opts.phone) return toast('ما في رقم جوال لهالطرف', 'err');
  window.open(waLink(opts.phone, opts.body), '_blank', 'noopener');
  logMessage({ ...opts, channel: 'whatsapp' });
}

async function campaignTab(v, head) {
  const [parties, lk, tpl] = await Promise.all([loadParties(), loadLookups(), msgTemplates()]);
  const cats = (await sb.from('party_categories').select('id,name,party_type').eq('company_id', S.company.id)).data || [];
  const { data: bals } = S.fy ? await sb.from('party_balances').select('party_id,debit,credit').eq('company_id', S.company.id).eq('fiscal_year_id', S.fy.id) : { data: [] };
  const bal = Object.fromEntries((bals || []).map(b => [b.party_id, num(b.debit) - num(b.credit)]));
  const reps = lk.filter(r => r.kind === 'sales_rep'), routes = lk.filter(r => r.kind === 'route');
  v.innerHTML = `${head}<div class="card">
    <div class="grid cols-4">
      <div class="field"><label>النوع</label><select id="m-type"><option value="customer">العملاء</option><option value="supplier">الموردين</option></select></div>
      <div class="field"><label>الفئة</label><select id="m-cat"><option value="">الكل</option>${cats.map(c => `<option value="${c.id}" data-t="${c.party_type}">${esc(c.name)}</option>`).join('')}</select></div>
      <div class="field"><label>المندوب</label><select id="m-rep"><option value="">الكل</option>${reps.map(r => `<option value="${r.id}">${esc(r.name)}</option>`).join('')}</select></div>
      <div class="field"><label>المسار</label><select id="m-route"><option value="">الكل</option>${routes.map(r => `<option value="${r.id}">${esc(r.name)}</option>`).join('')}</select></div>
      <div class="field"><label>المدينة</label><input id="m-city" placeholder="الكل"></div>
      <div class="field"><label>الرصيد</label><select id="m-bal"><option value="">الكل</option><option value="due">عليه رصيد (مدين)</option><option value="credit">إله رصيد (دائن)</option><option value="zero">رصيده صفر</option></select></div>
      <div class="field"><label>أقل رصيد</label><input id="m-min" dir="ltr" placeholder="0"></div>
      <div class="field"><label>اسم الحملة</label><input id="m-camp" placeholder="مثلاً: عرض نهاية السنة"></div></div>
    <div class="field"><label>نص الرسالة <span class="muted" style="font-size:12px">— كلمات بتتعبّى: ${VARS.join(' ')}</span></label>
      <div style="display:flex;gap:6px;margin-bottom:4px">${['campaign', 'reminder', 'statement'].map(k => `<button type="button" class="btn sm" data-tpl="${k}">${{ campaign: 'عرض', reminder: 'تذكير بالرصيد', statement: 'رصيد الحساب' }[k]}</button>`).join('')}</div>
      <textarea id="m-body" rows="4">${esc(tpl.campaign)}</textarea></div>
    <button class="btn primary" id="m-go">🔍 جهّز القائمة</button></div><div id="m-out"></div>`;
  const $ = (s) => v.querySelector(s);
  v.querySelectorAll('[data-tpl]').forEach(b => b.onclick = () => { $('#m-body').value = tpl[b.dataset.tpl]; if (b.dataset.tpl !== 'campaign') $('#m-bal').value = 'due'; });
  $('#m-go').onclick = () => {
    const type = $('#m-type').value, cat = $('#m-cat').value, rep = $('#m-rep').value, route = $('#m-route').value, city = $('#m-city').value.trim(), bm = $('#m-bal').value, mn = num($('#m-min').value);
    const side = type === 'supplier' ? -1 : 1;
    const list = parties.filter(p => p.party_type === type && p.is_active && (!cat || p.category_id === cat) && (!rep || p.sales_rep_id === rep) && (!route || p.route_id === route)
      && (!city || (p.city || '').includes(city))).map(p => ({ p, b: (bal[p.id] || 0) * side, ph: p.mobile || p.phone }))
      .filter(x => (!bm || (bm === 'due' ? x.b > 0.0005 : bm === 'credit' ? x.b < -0.0005 : Math.abs(x.b) < 0.0005)) && (!mn || Math.abs(x.b) >= mn));
    const withPh = list.filter(x => x.ph), body = $('#m-body').value, camp = $('#m-camp').value.trim() || null;
    const kind = /\[الرصيد\]/.test(body) && $('#m-bal').value === 'due' ? 'reminder' : 'campaign';
    $('#m-out').innerHTML = `<div class="card" style="margin-top:10px"><div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">
        <b>${withPh.length} مستلم</b><span class="muted">(${list.length - withPh.length} بدون رقم ما انضافوا)</span><div class="spacer"></div>
        <button class="btn sm" id="m-csv">⬇️ تنزيل الأرقام والنصوص (لبوابة الرسائل)</button></div>
      <p class="muted" style="font-size:12px">كبسة «واتساب» بتفتح المحادثة جاهزة؛ ابعت من الواتساب وارجع للي بعده. السطر بيتعلّم ✓ وبينسجّل بالسجل.</p>
      <div class="table-wrap"><table class="t"><thead><tr><th>الاسم</th><th>الجوال</th><th>الرصيد</th><th></th></tr></thead><tbody>
      ${withPh.map((x, i) => `<tr data-i="${i}"><td>${esc(x.p.name)}</td><td dir="ltr">${esc(x.ph)}</td><td class="n">${fmtNum(x.b)}</td>
        <td class="actions"><button class="btn sm" data-wa="${i}">💬 واتساب</button><button class="btn sm" data-sms="${i}">✉️ رسالة</button><span data-ok="${i}"></span></td></tr>`).join('') || '<tr><td colspan="4" class="empty">ما في حدا ضمن الفلتر</td></tr>'}</tbody></table></div></div>`;
    const msgOf = (x) => fillTpl(body, { name: x.p.name, balance: Math.abs(x.b) });
    $('#m-out').onclick = (e) => {
      const w = e.target.closest('[data-wa]'), s = e.target.closest('[data-sms]'); const i = +(w?.dataset.wa ?? s?.dataset.sms); if (!(w || s)) return;
      const x = withPh[i], text = msgOf(x);
      if (w) window.open(waLink(x.ph, text), '_blank', 'noopener'); else location.href = smsLink(x.ph, text);
      logMessage({ party_id: x.p.id, phone: x.ph, channel: w ? 'whatsapp' : 'sms', kind, body: text, campaign: camp });
      v.querySelector(`[data-ok="${i}"]`).textContent = ' ✓'; v.querySelector(`tr[data-i="${i}"]`).style.opacity = .55;
    };
    $('#m-csv')?.addEventListener('click', () => {
      const rows = [['phone', 'name', 'message']].concat(withPh.map(x => [phone962(x.ph), x.p.name, msgOf(x)]));
      const csv = '﻿' + rows.map(r => r.map(c => `"${String(c).replace(/"/g, '""')}"`).join(',')).join('\r\n');
      const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' })); a.download = 'رسائل.csv'; a.click();
    });
  };
}

async function logTab(v, head) {
  const [{ data: rows = [] }, parties] = await Promise.all([sb.from('message_log').select('*').eq('company_id', S.company.id).order('sent_at', { ascending: false }).limit(500), loadParties()]);
  const pn = Object.fromEntries(parties.map(p => [p.id, p.name]));
  const K = { invoice: 'فاتورة', statement: 'كشف/رصيد', payment: 'دفعة', reminder: 'تذكير', campaign: 'حملة', other: 'أخرى' };
  v.innerHTML = `${head}<div class="card table-wrap"><table class="t rep"><thead><tr><th>الوقت</th><th>الطرف</th><th>الجوال</th><th>القناة</th><th>النوع</th><th>الحملة</th><th>النص</th></tr></thead><tbody>
    ${(rows || []).map(r => `<tr><td>${fmtDateTime(r.sent_at)}</td><td>${esc(pn[r.party_id] || '')}</td><td dir="ltr">${esc(r.phone || '')}</td><td>${r.channel === 'sms' ? '✉️ رسالة' : '💬 واتساب'}</td>
      <td>${K[r.kind] || r.kind}</td><td>${esc(r.campaign || '')}</td><td class="muted" style="font-size:12px;max-width:380px;white-space:pre-wrap">${esc(r.body)}</td></tr>`).join('') || '<tr><td colspan="7" class="empty">ما في رسائل لسا</td></tr>'}</tbody></table></div>`;
}

async function templatesTab(v, head) {
  const tpl = await msgTemplates(); const ed = can('companies', 'edit');
  const L = { invoice: '🧾 الفاتورة', statement: '📄 كشف الحساب / الرصيد', payment: '💵 استلام دفعة', reminder: '⏰ تذكير بالرصيد المستحق', campaign: '📢 حملة / عرض' };
  v.innerHTML = `${head}<div class="card"><p class="muted" style="margin-top:0">الكلمات اللي بين قوسين بتتعبّى لحالها: ${VARS.join(' ')}</p>
    ${Object.keys(L).map(k => `<div class="field"><label>${L[k]}</label><textarea data-k="${k}" rows="4" ${ed ? '' : 'disabled'}>${esc(tpl[k])}</textarea></div>`).join('')}
    ${ed ? '<button class="btn primary" id="t-save">💾 حفظ النصوص</button> <button class="btn" id="t-def">↺ النصوص الافتراضية</button>' : ''}</div>`;
  v.querySelector('#t-def')?.addEventListener('click', () => v.querySelectorAll('[data-k]').forEach(t => t.value = DEFAULT_TPL[t.dataset.k]));
  v.querySelector('#t-save')?.addEventListener('click', async () => {
    const t = {}; v.querySelectorAll('[data-k]').forEach(x => t[x.dataset.k] = x.value.slice(0, 1500));
    const { error } = await sb.from('company_settings').update({ msg_templates: t }).eq('company_id', S.company.id);
    if (error) return toast(arError(error), 'err');
    S._msgtpl = null; toast('انحفظت النصوص', 'ok');
  });
}

async function viewMessages(v) {
  if (!S.company) return void (v.innerHTML = '<div class="notice info">اختار شركة من فوق أول.</div>');
  if (!can('marketing', 'view')) return void (v.innerHTML = '<div class="notice">ما عندك صلاحية على التسويق</div>');
  const t = new URLSearchParams(location.hash.split('?')[1] || '').get('t') || 'campaign';
  const head = `<div class="page-head"><h2>💬 الرسائل والواتساب</h2></div>
    <div class="tabs" style="margin-bottom:10px">${[['campaign', '📢 حملة / تذكير'], ['log', '📜 سجل الرسائل'], ['templates', '📝 النصوص الجاهزة']].map(([k, l]) => `<a class="tab ${t === k ? 'active' : ''}" href="#/messages?t=${k}">${l}</a>`).join('')}</div>`;
  if (t === 'log') return logTab(v, head);
  if (t === 'templates') return templatesTab(v, head);
  return campaignTab(v, head);
}

export const MESSAGE_ROUTES = { messages: viewMessages };
