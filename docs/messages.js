// =====================================================================
//  السمو ERP — الرسائل (route messages?t=campaign|log|templates)
//  واتساب/رسالة نصية من الجهاز (wa.me / sms:) + نصوص جاهزة (company_settings.msg_templates) + سجل (message_log)
// =====================================================================
import { S, sb, esc, fmtNum, fmtDate, fmtDateTime, num, today, toast, arError, modal, confirmBox, can } from './core.js';
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

// بوابة الرسائل القصيرة (المرحلة 73)
export async function smsGateway() {
  const { data } = await sb.rpc('sms_config_get', { p_company: S.company.id });
  return data || {};
}
export async function sendSmsGateway(opts) {
  const { data, error } = await sb.rpc('sms_send', { p_company: S.company.id, p_phone: opts.phone, p_body: String(opts.body || '').slice(0, 1000),
    p_party: opts.party_id || null, p_kind: opts.kind || 'other', p_ref: opts.ref_id || null, p_campaign: opts.campaign || null });
  if (error) throw error;
  return data;
}

async function campaignTab(v, head) {
  const [parties, lk, tpl, gw] = await Promise.all([loadParties(), loadLookups(), msgTemplates(), smsGateway()]);
  const useGw = gw.enabled && gw.has_url;
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
        ${useGw && can('marketing', 'add') ? `<button class="btn sm primary" id="m-all">📤 إرسال للكل بالبوابة (${withPh.length})${gw.test_mode ? ' — وضع التجربة' : ''}</button>` : ''}
        <button class="btn sm" id="m-csv">⬇️ تنزيل الأرقام والنصوص</button></div>
      <div id="m-prog" class="muted" style="margin-top:6px"></div>
      <p class="muted" style="font-size:12px">كبسة «واتساب» بتفتح المحادثة جاهزة؛ ابعت من الواتساب وارجع للي بعده. السطر بيتعلّم ✓ وبينسجّل بالسجل.</p>
      <div class="table-wrap"><table class="t"><thead><tr><th>الاسم</th><th>الجوال</th><th>الرصيد</th><th></th></tr></thead><tbody>
      ${withPh.map((x, i) => `<tr data-i="${i}"><td>${esc(x.p.name)}</td><td dir="ltr">${esc(x.ph)}</td><td class="n">${fmtNum(x.b)}</td>
        <td class="actions"><button class="btn sm" data-wa="${i}">💬 واتساب</button><button class="btn sm" data-sms="${i}">✉️ رسالة</button><span data-ok="${i}"></span></td></tr>`).join('') || '<tr><td colspan="4" class="empty">ما في حدا ضمن الفلتر</td></tr>'}</tbody></table></div></div>`;
    const msgOf = (x) => fillTpl(body, { name: x.p.name, balance: Math.abs(x.b) });
    $('#m-out').onclick = (e) => {
      const w = e.target.closest('[data-wa]'), s = e.target.closest('[data-sms]'); const i = +(w?.dataset.wa ?? s?.dataset.sms); if (!(w || s)) return;
      const x = withPh[i], text = msgOf(x);
      const done = (mark = ' ✓') => { v.querySelector(`[data-ok="${i}"]`).textContent = mark; v.querySelector(`tr[data-i="${i}"]`).style.opacity = .55; };
      if (s && useGw) { sendSmsGateway({ party_id: x.p.id, phone: x.ph, kind, body: text, campaign: camp }).then(() => done(' 📤')).catch(er => toast(arError(er), 'err')); return; }
      if (w) window.open(waLink(x.ph, text), '_blank', 'noopener'); else location.href = smsLink(x.ph, text);
      logMessage({ party_id: x.p.id, phone: x.ph, channel: w ? 'whatsapp' : 'sms', kind, body: text, campaign: camp });
      done();
    };
    $('#m-all')?.addEventListener('click', async (e) => {
      if (!(await confirmBox(`إرسال ${withPh.length} رسالة عن طريق البوابة${gw.test_mode ? ' (وضع التجربة: كلها بتروح لرقم التجربة)' : ''}؟`))) return;
      e.target.disabled = true; let ok = 0, bad = 0, lastErr = '';
      for (const [i, x] of withPh.entries()) {
        $('#m-prog').textContent = `جاري الإرسال ${i + 1} من ${withPh.length}…`;
        try { await sendSmsGateway({ party_id: x.p.id, phone: x.ph, kind, body: msgOf(x), campaign: camp }); ok++; v.querySelector(`[data-ok="${i}"]`).textContent = ' 📤'; v.querySelector(`tr[data-i="${i}"]`).style.opacity = .55; }
        catch (er) { bad++; lastErr = arError(er); if (/حد الرسائل|مش مفعّلة|pg_net/.test(lastErr)) break; }
      }
      $('#m-prog').textContent = `انبعتت ${ok}${bad ? ` · ما زبط ${bad}: ${lastErr}` : ''} — الحالة النهائية بسجل الرسائل.`;
    });
    $('#m-csv')?.addEventListener('click', () => {
      const rows = [['phone', 'name', 'message']].concat(withPh.map(x => [phone962(x.ph), x.p.name, msgOf(x)]));
      const csv = '﻿' + rows.map(r => r.map(c => `"${String(c).replace(/"/g, '""')}"`).join(',')).join('\r\n');
      const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' })); a.download = 'رسائل.csv'; a.click();
    });
  };
}

async function logTab(v, head) {
  await sb.rpc('sms_refresh', { p_company: S.company.id });
  const [{ data: rows = [] }, parties] = await Promise.all([sb.from('message_log').select('*').eq('company_id', S.company.id).order('sent_at', { ascending: false }).limit(500), loadParties()]);
  const pn = Object.fromEntries(parties.map(p => [p.id, p.name]));
  const K = { invoice: 'فاتورة', statement: 'كشف/رصيد', payment: 'دفعة', reminder: 'تذكير', campaign: 'حملة', other: 'أخرى' };
  v.innerHTML = `${head}<div class="card table-wrap"><table class="t rep"><thead><tr><th>الوقت</th><th>الطرف</th><th>الجوال</th><th>القناة</th><th>الحالة</th><th>النوع</th><th>الحملة</th><th>النص</th></tr></thead><tbody>
    ${(rows || []).map(r => `<tr><td>${fmtDateTime(r.sent_at)}</td><td>${esc(pn[r.party_id] || '')}</td><td dir="ltr">${esc(r.phone || '')}</td><td>${r.channel === 'sms' ? '✉️ رسالة' : '💬 واتساب'}</td>
      <td>${ST[r.status] ? `<span class="badge ${ST[r.status][1]}" ${r.error ? `title="${esc(r.error)}"` : ''}>${ST[r.status][0]}</span>` : '<span class="muted">من الجهاز</span>'}</td>
      <td>${K[r.kind] || r.kind}</td><td>${esc(r.campaign || '')}</td><td class="muted" style="font-size:12px;max-width:380px;white-space:pre-wrap">${esc(r.body)}</td></tr>`).join('') || '<tr><td colspan="8" class="empty">ما في رسائل لسا</td></tr>'}</tbody></table></div>`;
}
const ST = { queued: ['بالطريق', 'warn'], sent: ['انبعتت', 'ok'], failed: ['ما زبطت', 'bad'], test: ['تجربة', 'brand'] };

async function gatewayTab(v, head) {
  const gw = await smsGateway(), ed = can('companies', 'edit');
  const dis = ed ? '' : 'disabled';
  v.innerHTML = `${head}<div class="card" style="max-width:860px">
    <h3 style="margin-top:0">📡 بوابة الرسائل القصيرة (SMS)</h3>
    <p class="muted" style="margin-top:0">شركة الرسائل (مثلاً بالأردن) بتعطيك رابط إرسال فيه اسم الحساب وكلمة السر. الصقه هون وحط مكان الرقم <code>{phone}</code> ومكان النص <code>{msg}</code> (أو <code>{msg_hex}</code> إذا البوابة بدها النص العربي يونيكود)، ومكان اسم المرسل <code>{sender}</code>.
      الرابط بينحفظ بقاعدة البيانات وما بيرجع يطلع على أي شاشة، والإرسال بيصير من السيرفر مش من الجهاز.</p>
    ${gw.trial ? '<div class="notice">بوابة الرسائل مش متاحة بالنسخة التجريبية.</div>' : ''}
    <p class="muted" style="font-size:12.5px;margin-top:0">لازم الرابط يبدأ بـ https:// وعلى دومين شركة الرسائل (مش رقم IP). الموظف اللي ما إله صلاحية التسويق بيقدر يبعت بس فاتورة أو كشف أو دفعة لرقم العميل نفسه.</p>
    ${gw.pg_net === false ? '<div class="notice">إضافة pg_net مش مفعّلة بقاعدة البيانات، فالإرسال ما رح يشتغل لحد ما تتفعّل.</div>' : ''}
    <form id="gw"><div class="grid cols-2">
      <div class="field" style="grid-column:span 2"><label>رابط الإرسال ${gw.has_url ? `<span class="badge ok">محفوظ — ${esc(gw.host || '')}</span>` : '<span class="badge warn">مش محفوظ</span>'}</label>
        <input type="password" name="url_template" dir="ltr" autocomplete="off" placeholder="${gw.has_url ? 'فاضي = بيضل الرابط المحفوظ' : 'https://…/send?user=…&pass=…&to={phone}&text={msg}&from={sender}'}" ${dis}></div>
      <div class="field"><label>اسم المرسل (Sender ID)</label><input name="sender" dir="ltr" value="${esc(gw.sender || '')}" ${dis}></div>
      <div class="field"><label>حد الرسائل باليوم</label><input name="daily_limit" type="number" min="1" max="20000" value="${gw.daily_limit || 500}" ${dis}><small class="muted">انبعت اليوم: ${gw.sent_today || 0}</small></div>
      <div class="field"><label><input type="checkbox" name="enabled" ${gw.enabled ? 'checked' : ''} ${dis}> تفعيل الإرسال بالبوابة</label></div>
      <div class="field"><label><input type="checkbox" name="test_mode" ${gw.test_mode !== false ? 'checked' : ''} ${dis}> وضع التجربة: كل الرسائل بتروح لرقم التجربة بس</label></div>
      <div class="field"><label><input type="checkbox" name="allow_intl" ${gw.allow_intl ? 'checked' : ''} ${dis}> السماح بأرقام برّا الأردن</label></div>
      <div class="field"><label>رقم التجربة</label><input name="test_phone" dir="ltr" value="${esc(gw.test_phone || '')}" placeholder="07…" ${dis}></div>
    </div></form>
    ${ed ? `<div style="display:flex;gap:8px;flex-wrap:wrap"><button class="btn primary" id="gw-save">💾 حفظ</button><button class="btn" id="gw-test">📤 رسالة تجربة</button>${gw.has_url ? '<button class="btn danger" id="gw-clear">مسح الرابط</button>' : ''}</div>` : '<p class="muted">التعديل لمين إله صلاحية تعديل الشركات.</p>'}
    <p class="muted" style="font-size:12.5px">ابدأ بوضع التجربة وتأكد إنه رسالة التجربة وصلت لجوالك، وبعدها شيل علامة التجربة. حالة كل رسالة (انبعتت / ما زبطت) بتبيّن بسجل الرسائل.</p></div>`;
  const f = v.querySelector('#gw');
  const payload = () => ({ enabled: f.enabled.checked, test_mode: f.test_mode.checked, test_phone: f.test_phone.value.trim(), sender: f.sender.value.trim(),
    daily_limit: Math.max(1, Math.min(20000, parseInt(f.daily_limit.value) || 500)), allow_intl: f.allow_intl.checked, url_template: f.url_template.value.trim() || null });
  v.querySelector('#gw-save')?.addEventListener('click', async () => {
    const { error } = await sb.rpc('sms_config_save', { p_company: S.company.id, p: payload() });
    if (error) return toast(arError(error), 'err');
    toast('انحفظ إعداد البوابة', 'ok'); gatewayTab(v, head);
  });
  v.querySelector('#gw-test')?.addEventListener('click', async () => {
    const ph = f.test_phone.value.trim(); if (!ph) return toast('اكتب رقم التجربة واحفظ أول', 'err');
    try { await sendSmsGateway({ phone: ph, body: `رسالة تجربة من ${S.company.name}`, kind: 'other' }); toast('انبعتت رسالة التجربة — شوف جوالك وسجل الرسائل', 'ok'); }
    catch (e) { toast(arError(e), 'err'); }
  });
  v.querySelector('#gw-clear')?.addEventListener('click', async () => {
    if (!(await confirmBox('مسح رابط البوابة ووقف الإرسال؟'))) return;
    const { error } = await sb.rpc('sms_config_save', { p_company: S.company.id, p: { ...payload(), url_template: null, clear_url: true } });
    if (error) return toast(arError(error), 'err'); gatewayTab(v, head);
  });
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
    <div class="tabs" style="margin-bottom:10px">${[['campaign', '📢 حملة / تذكير'], ['log', '📜 سجل الرسائل'], ['templates', '📝 النصوص الجاهزة'], ['gateway', '📡 بوابة الرسائل']].map(([k, l]) => `<a class="tab ${t === k ? 'active' : ''}" href="#/messages?t=${k}">${l}</a>`).join('')}</div>`;
  if (t === 'log') return logTab(v, head);
  if (t === 'templates') return templatesTab(v, head);
  if (t === 'gateway') return gatewayTab(v, head);
  return campaignTab(v, head);
}

export const MESSAGE_ROUTES = { messages: viewMessages };
