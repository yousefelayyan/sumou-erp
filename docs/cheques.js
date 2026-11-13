// =====================================================================
//  السمو ERP — محفظة الشيكات (واردة وصادرة)
// =====================================================================
import { S, sb, esc, fmtDate, fmtNum, num, today, toast, arError, modal, confirmBox, formData, can, log } from './core.js';
import { loadAccounts, leafAccounts, accLabel, downloadCSV } from './finance.js';
import { loadLookups, lookupDatalistSync } from './lookups.js';
import { loadParties, partyDatalist, resolveParty, partyLabel } from './parties.js';
import { printDoc, amountToWords } from './print.js';
import { openAttachments } from './attach.js';

const ST = {
  portfolio: ['بالمحفظة', 'warn'], deposited: ['مودع بالبنك (برسم التحصيل)', 'info'], collected: ['محصّل', 'ok'], returned: ['راجع', 'bad'],
  issued: ['صادر (بانتظار الصرف)', 'warn'], paid: ['مصروف', 'ok'], cancelled: ['ملغى', 'bad'],
};
const daysTo = (d) => Math.round((new Date(d) - new Date(today())) / 86400000);

async function viewCheques(v, ctx) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const dir = new URLSearchParams(location.hash.split('?')[1] || '').get('dir') === 'out' ? 'out' : 'in';
  const [{ data, error }, parties, accs] = await Promise.all([
    sb.from('cheques').select('*').eq('company_id', S.company.id).eq('direction', dir).order('due_date').limit(5000), loadParties(), loadAccounts(), loadLookups()]);
  if (error) throw error;
  const pName = Object.fromEntries(parties.map(p => [p.id, p.name]));
  const open = data.filter(c => c.status === (dir === 'in' ? 'portfolio' : 'issued'));
  const sumOpen = open.reduce((s, c) => s + num(c.amount), 0);
  const due7 = open.filter(c => daysTo(c.due_date) <= 7).reduce((s, c) => s + num(c.amount), 0);
  v.innerHTML = `<div class="page-head"><h2>💳 محفظة الشيكات</h2><div class="spacer"></div>
      ${can('cheques', 'add') ? `<button class="btn primary" id="add">➕ ${dir === 'in' ? 'شيك وارد' : 'شيك صادر'}</button>` : ''}</div>
    <div class="tabs"><a class="tab ${dir === 'in' ? 'active' : ''}" href="#/cheques?dir=in" style="text-decoration:none">📥 شيكات واردة (من العملاء)</a>
      <a class="tab ${dir === 'out' ? 'active' : ''}" href="#/cheques?dir=out" style="text-decoration:none">📤 شيكات صادرة (للموردين)</a></div>
    <div class="grid cols-3" style="margin-bottom:14px">
      <div class="card stat"><span class="k">${dir === 'in' ? 'بالمحفظة' : 'صادرة بانتظار الصرف'}</span><span class="v" dir="ltr">${fmtNum(sumOpen)}</span><span class="muted">${open.length} شيك</span></div>
      <div class="card stat"><span class="k">مستحقة خلال 7 أيام (أو فاتت)</span><span class="v" dir="ltr" style="color:var(--warn)">${fmtNum(due7)}</span></div>
      <div class="card stat"><span class="k">راجعة</span><span class="v" dir="ltr" style="color:var(--bad)">${fmtNum(data.filter(c => c.status === 'returned').reduce((s, c) => s + num(c.amount), 0))}</span></div></div>
    <div class="card no-print filters">
      <div class="field"><label>الحالة</label><select id="f-s"><option value="open">${dir === 'in' ? 'بالمحفظة' : 'صادرة'}</option><option value="">الكل</option>
        ${Object.entries(ST).filter(([k]) => dir === 'in' ? ['portfolio', 'deposited', 'collected', 'returned'].includes(k) : ['issued', 'paid', 'cancelled'].includes(k)).map(([k, [l]]) => `<option value="${k}">${l}</option>`).join('')}</select></div>
      <div class="field"><label>الاستحقاق من</label><input type="date" id="f-from"></div><div class="field"><label>إلى</label><input type="date" id="f-to"></div>
      <div class="field"><label>بحث</label><input id="f-q" placeholder="رقم الشيك، الاسم، البنك…"></div>
      <div class="field" style="justify-content:flex-end;flex-direction:row;gap:6px"><button class="btn" id="prn">🖨️ طباعة</button><button class="btn" id="csv">⬇️ Excel</button></div></div>
    <div class="card table-wrap" style="margin-top:12px"><table class="t"><thead><tr><th>الاستحقاق</th><th>رقم الشيك</th><th>البنك</th><th>${dir === 'in' ? 'من' : 'إلى'}</th><th style="text-align:left">المبلغ</th><th>الحالة</th><th></th></tr></thead><tbody id="rows"></tbody>
      <tfoot><tr><td colspan="4" style="text-align:left"><b>المجموع</b></td><td dir="ltr" style="text-align:left"><b id="tot"></b></td><td colspan="2"></td></tr></tfoot></table></div>`;
  let shown = [];
  const draw = () => {
    const fs = v.querySelector('#f-s').value, ff = v.querySelector('#f-from').value, ft = v.querySelector('#f-to').value, q = v.querySelector('#f-q').value.trim().toLowerCase();
    shown = data.filter(c => (fs === '' || (fs === 'open' ? c.status === (dir === 'in' ? 'portfolio' : 'issued') : c.status === fs))
      && (!ff || c.due_date >= ff) && (!ft || c.due_date <= ft)
      && (!q || [c.cheque_no, c.bank_name, c.drawer_name, pName[c.party_id]].some(x => (x || '').toLowerCase().includes(q))));
    v.querySelector('#rows').innerHTML = shown.map(c => { const d = daysTo(c.due_date), isOpen = ['portfolio', 'issued'].includes(c.status);
      return `<tr><td><b>${fmtDate(c.due_date)}</b>${isOpen ? `<div style="font-size:12px;color:${d < 0 ? 'var(--bad)' : d <= 7 ? 'var(--warn)' : 'var(--muted)'}">${d < 0 ? `فات ${-d} يوم` : d === 0 ? 'اليوم' : `باقي ${d} يوم`}</div>` : ''}</td>
        <td dir="ltr" style="text-align:right">${esc(c.cheque_no)}</td><td>${esc([c.bank_name, c.branch].filter(Boolean).join(' - '))}</td>
        <td>${esc(pName[c.party_id] || c.drawer_name || '')}</td><td dir="ltr" style="text-align:left"><b>${fmtNum(c.amount)}</b></td>
        <td><span class="badge ${ST[c.status][1]}">${ST[c.status][0]}</span></td>
        <td class="actions">${can('cheques', 'post') ? (dir === 'in'
          ? (c.status === 'portfolio' ? `<button class="btn sm" data-act="deposit" data-id="${c.id}">🏦 إيداع</button> <button class="btn sm primary" data-act="collect" data-id="${c.id}">✓ تحصيل</button> <button class="btn sm danger" data-act="return" data-id="${c.id}">راجع</button>`
             : c.status === 'deposited' ? `<button class="btn sm primary" data-act="collect" data-id="${c.id}">✓ تحصيل</button> <button class="btn sm danger" data-act="return" data-id="${c.id}">راجع</button> <button class="btn sm" data-act="undeposit" data-id="${c.id}" title="رجّعه للمحفظة">↩︎</button>`
             : c.status === 'collected' ? `<button class="btn sm danger" data-act="return" data-id="${c.id}">راجع</button>` : '')
          : (c.status === 'issued' ? `<button class="btn sm primary" data-act="pay" data-id="${c.id}">✓ انصرف</button> <button class="btn sm danger" data-act="cancel" data-id="${c.id}">إلغاء</button>` : '')) : ''}
          <button class="btn sm" data-hist="${c.id}">السجل</button></td></tr>`; }).join('') || '<tr><td colspan="7" class="empty">ما في شيكات</td></tr>';
    v.querySelector('#tot').textContent = fmtNum(shown.reduce((s, c) => s + num(c.amount), 0));
  };
  draw(); ['#f-s', '#f-from', '#f-to', '#f-q'].forEach(s => v.querySelector(s).addEventListener('input', draw));
  const banks = leafAccounts(accs).filter(a => ['bank', 'cash'].includes(a.account_type)).concat(leafAccounts(accs).filter(a => !['bank', 'cash'].includes(a.account_type)));
  const depSel = () => `<select name="bank" required><option value="">— اختار —</option>${leafAccounts(accs).filter(a => a.category === 'assets' && a.account_type !== 'cash').map(a => `<option value="${a.id}">${esc(accLabel(a))}</option>`).join('')}</select>`;
  const bankSel = (sel) => `<select name="bank">${banks.map(a => `<option value="${a.id}" ${a.id === sel ? 'selected' : ''}>${esc(accLabel(a))}</option>`).join('')}</select>`;

  v.querySelector('#add')?.addEventListener('click', () => {
    const myParties = parties.filter(p => p.party_type === (dir === 'in' ? 'customer' : 'supplier') && p.is_active);
    const m = modal({ title: dir === 'in' ? 'تسجيل شيك وارد' : 'تسجيل شيك صادر', body: `<form id="c-form"><div class="grid cols-2">
      <div class="field"><label>رقم الشيك *</label><input name="cheque_no" dir="ltr"></div>
      <div class="field"><label>المبلغ *</label><input name="amount" inputmode="decimal" dir="ltr"></div>
      <div class="field"><label>البنك</label><input name="bank_name" list="lk-bank">${lookupDatalistSync('lk-bank', ['bank'])}</div><div class="field"><label>الفرع</label><input name="branch" list="lk-branch">${lookupDatalistSync('lk-branch', ['bank_branch'])}</div>
      <div class="field"><label>تاريخ ${dir === 'in' ? 'الاستلام' : 'الإصدار'} *</label><input type="date" name="issue_date" value="${today()}"></div>
      <div class="field"><label>تاريخ الاستحقاق *</label><input type="date" name="due_date" value="${today()}"></div>
      <div class="field" style="grid-column:span 2"><label>${dir === 'in' ? 'العميل' : 'المورد'}</label><input list="party-list" id="c-party" placeholder="اختار من القائمة…">${partyDatalist(myParties)}</div>
      <div class="field"><label>أو حساب مقابل (إذا مش عميل/مورد)</label><select name="account_id"><option value="">—</option>${leafAccounts(accs).map(a => `<option value="${a.id}">${esc(accLabel(a))}</option>`).join('')}</select></div>
      <div class="field"><label>اسم ${dir === 'in' ? 'الساحب' : 'المستفيد'}</label><input name="drawer_name"></div>
      ${dir === 'in' ? '<div class="field"><label>اسم المجيّر (إذا الشيك مجيّر)</label><input name="endorser_name"></div>' : ''}</div>
      <div class="field"><label>ملاحظات</label><input name="notes"></div></form>
      <p class="muted" style="font-size:13px">${dir === 'in' ? 'بينعمل قيد: من حـ/ شيكات برسم التحصيل إلى حـ/ العميل.' : 'بينعمل قيد: من حـ/ المورد إلى حـ/ شيكات آجلة الدفع.'}</p>`,
      foot: `<button class="btn primary" data-save>💾 تسجيل</button><button class="btn" data-close>إلغاء</button>` });
    m.el.querySelector('[data-save]').onclick = async (e) => {
      const d = formData(m.el.querySelector('#c-form')); const pi = m.el.querySelector('#c-party').value; const p = resolveParty(myParties, pi);
      if (!d.cheque_no || !num(d.amount) || !d.due_date || !d.issue_date) return toast('رقم الشيك والمبلغ والتواريخ مطلوبة', 'err');
      if (pi && !p) return toast('العميل/المورد مش موجود بالقائمة', 'err');
      if (!p && !d.account_id) return toast('اختار العميل/المورد أو الحساب المقابل', 'err');
      e.target.disabled = true;
      const endorser = d.endorser_name || null; delete d.endorser_name;
      const { data: cid, error } = await sb.rpc('register_cheque', { p: { ...d, amount: num(d.amount), company_id: S.company.id, direction: dir, party_id: p?.id || null, drawer_name: d.drawer_name || p?.name || null } });
      if (error) { e.target.disabled = false; return toast(arError(error), 'err'); }
      if (endorser && cid) await sb.from('cheques').update({ endorser_name: endorser }).eq('id', cid);
      toast('تم تسجيل الشيك وترحيل قيده', 'ok'); m.close(); ctx.rerender();
    };
  });

  v.querySelector('#rows').onclick = async (e) => {
    const b = e.target.closest('[data-act]'), h = e.target.closest('[data-hist]');
    if (h) {
      const { data: ev } = await sb.from('cheque_events').select('*').eq('cheque_id', h.dataset.hist).order('created_at');
      const eids = (ev || []).map(x => x.entry_id).filter(Boolean);
      const [{ data: jl }, { data: je }, accs2] = eids.length ? await Promise.all([sb.from('journal_lines').select('entry_id,line_no,account_id,debit,credit,description').in('entry_id', eids).order('line_no'),
        sb.from('journal_entries').select('id,doc_code,entry_no,status').in('id', eids), loadAccounts()]) : [{ data: [] }, { data: [] }, []];
      const accBy = Object.fromEntries((accs2 || []).map(a => [a.id, a])), jeBy = Object.fromEntries((je || []).map(x => [x.id, x]));
      const c0 = data.find(x => x.id === h.dataset.hist);
      const opsHTML = `<div class="grid cols-2" style="margin-bottom:8px;font-size:13px"><div>الساحب: <b>${esc(c0.drawer_name || '')}</b></div><div>المجيّر: <b>${esc(c0.endorser_name || '—')}</b></div>
        <div>البنك: <b>${esc([c0.bank_name, c0.branch].filter(Boolean).join(' - '))}</b></div><div>سبب الإرجاع: <b>${esc(c0.return_reason || '—')}</b></div></div>
        <h4 style="margin:6px 0">💼 العمليات المالية</h4>${(ev || []).map(x => `<div class="card" style="padding:8px;margin-bottom:6px"><b>${esc(x.action)}</b> · ${fmtDate(x.event_date)}${x.entry_id && jeBy[x.entry_id] ? ` · قيد ${esc(jeBy[x.entry_id].doc_code || String(jeBy[x.entry_id].entry_no))}` : ''} <span class="muted">${esc(x.note || '')}</span>
          ${(jl || []).filter(l => l.entry_id === x.entry_id).length ? `<table class="t" style="margin-top:4px"><thead><tr><th>الحساب</th><th>مدين</th><th>دائن</th><th>البيان</th></tr></thead><tbody>${(jl || []).filter(l => l.entry_id === x.entry_id).map(l => `<tr><td>${esc(accBy[l.account_id] ? accBy[l.account_id].code + ' — ' + accBy[l.account_id].name : '')}</td><td class="n">${num(l.debit) ? fmtNum(l.debit) : ''}</td><td class="n">${num(l.credit) ? fmtNum(l.credit) : ''}</td><td class="muted" style="font-size:12px">${esc(l.description || '')}</td></tr>`).join('')}</tbody></table>` : ''}</div>`).join('')}`;
      const hm = modal({ title: `سجل الشيك رقم ${c0.cheque_no}`, body: `${opsHTML || '<div class="empty">ما في حركات</div>'}`,
        foot: `<button class="btn" data-att>📎 مرفقات</button>${can('cheques', 'print') ? '<button class="btn" data-pr>🖨️ طباعة إشعار</button>' : ''}<button class="btn" data-close>إغلاق</button>` }).el; hm.querySelector('[data-att]').onclick = () => openAttachments('cheque', h.dataset.hist, 'شيك'); hm.querySelector('[data-pr]')?.addEventListener('click', () => {
          const c = data.find(x => x.id === h.dataset.hist);
          printDoc(`${dir === 'in' ? 'إشعار استلام شيك' : 'إشعار تسليم شيك'} رقم ${c.cheque_no}`, `<table class="meta">
            <tr><td><b>${dir === 'in' ? 'استلمنا من' : 'سلّمنا إلى'}:</b> ${esc(pName[c.party_id] || c.drawer_name || '')}</td><td><b>تاريخ الاستلام:</b> ${fmtDate(c.issue_date || c.created_at)}</td></tr>
            <tr><td><b>رقم الشيك:</b> ${esc(c.cheque_no)}</td><td><b>تاريخ الاستحقاق:</b> ${fmtDate(c.due_date)}</td></tr>
            <tr><td><b>البنك:</b> ${esc(c.bank_name || '')}</td><td><b>الحالة:</b> ${esc(ST[c.status]?.[0] || c.status)}</td></tr>
            ${c.notes ? `<tr><td colspan="2"><b>ملاحظات:</b> ${esc(c.notes)}</td></tr>` : ''}</table>
            <div class="amount-box">مبلغ وقدره: <b>${fmtNum(c.amount)}</b> دينار<br><span>${amountToWords(c.amount)}</span></div>`, { kind: 'cheque' });
        });
    }
    if (!b) return;
    const c = data.find(x => x.id === b.dataset.id), act = b.dataset.act;
    const T = { collect: 'تحصيل الشيك', return: 'شيك راجع', pay: 'صرف الشيك من البنك', cancel: 'إلغاء الشيك الصادر', deposit: 'إيداع الشيك بالبنك', undeposit: 'سحب الشيك من الإيداع' }[act];
    const needBank = act === 'collect' || act === 'pay' || act === 'deposit' || (act === 'return' && c.status === 'collected');
    const m = modal({ title: `${T} رقم ${c.cheque_no}`, size: 'sm', body: `<form id="a-form">
      <div class="field"><label>التاريخ</label><input type="date" name="date" value="${today()}"></div>
      ${needBank ? `<div class="field"><label>${act === 'deposit' ? 'حساب «شيكات برسم التحصيل» عند البنك' : 'البنك'}</label>${act === 'deposit' ? depSel() : bankSel(c.bank_account_id)}</div>` : ''}
      ${act === 'deposit' ? '<p class="muted" style="font-size:12px">القيد: من حـ/ شيكات برسم التحصيل (البنك) إلى حـ/ صندوق الشيكات. ولما يتحصّل: من حـ/ البنك إلى حـ/ شيكات برسم التحصيل.</p>' : ''}
      ${act === 'return' ? '<div class="field"><label>سبب الإرجاع</label><input name="reason" list="ret-reasons" placeholder="مثلاً: عدم كفاية الرصيد"><datalist id="ret-reasons"><option>عدم كفاية الرصيد</option><option>اختلاف التوقيع</option><option>الحساب مغلق</option><option>إيقاف صرف</option><option>خطأ بالتاريخ أو المبلغ</option></datalist></div>' : ''}
      <div class="field"><label>ملاحظة</label><input name="note"></div></form>
      <p class="muted" style="font-size:13px">${act === 'return' ? 'الشيك الراجع بيرجّع المبلغ على حساب العميل.' : act === 'cancel' ? 'الإلغاء بيرجّع المبلغ لحساب المورد.' : 'بينعمل قيد مرحّل تلقائياً.'}</p>`,
      foot: `<button class="btn primary" data-go>تأكيد</button><button class="btn" data-close>إلغاء</button>` });
    m.el.querySelector('[data-go]').onclick = async (ev) => {
      const d = formData(m.el.querySelector('#a-form')); ev.target.disabled = true;
      const { error } = await sb.rpc('cheque_action', { p_id: c.id, p_action: act, p_date: d.date, p_bank: d.bank || null, p_note: d.note });
      if (error) { ev.target.disabled = false; return toast(arError(error), 'err'); }
      if (act === 'return' && d.reason) await sb.from('cheques').update({ return_reason: d.reason }).eq('id', c.id);
      toast('تم ✓', 'ok'); m.close(); ctx.rerender();
    };
  };
  v.querySelector('#csv').onclick = () => downloadCSV(`الشيكات ${dir === 'in' ? 'الواردة' : 'الصادرة'}.csv`, [['الاستحقاق', 'رقم الشيك', 'البنك', 'الفرع', 'الاسم', 'المبلغ', 'الحالة']]
    .concat(shown.map(c => [c.due_date, c.cheque_no, c.bank_name, c.branch, pName[c.party_id] || c.drawer_name, num(c.amount).toFixed(3), ST[c.status][0]])));
  v.querySelector('#prn').onclick = () => printDoc(`كشف الشيكات ${dir === 'in' ? 'الواردة' : 'الصادرة'}`, `<table class="pt"><thead><tr><th>الاستحقاق</th><th>رقم الشيك</th><th>البنك</th><th>الاسم</th><th>المبلغ</th><th>الحالة</th></tr></thead><tbody>
    ${shown.map(c => `<tr><td>${fmtDate(c.due_date)}</td><td>${esc(c.cheque_no)}</td><td>${esc(c.bank_name || '')}</td><td>${esc(pName[c.party_id] || c.drawer_name || '')}</td><td class="n">${fmtNum(c.amount)}</td><td>${ST[c.status][0]}</td></tr>`).join('')}</tbody>
    <tfoot><tr class="tot"><td colspan="4">المجموع</td><td class="n">${fmtNum(shown.reduce((s, c) => s + num(c.amount), 0))}</td><td></td></tr></tfoot></table>`, { subtitle: `بتاريخ ${fmtDate(today())}` });
}

// ---------------------------------------------------------------------
//  لوحة الشيكات (واردة/صادرة): بطاقات، رسم شهري، تقويم الاستحقاق، فلاتر
// ---------------------------------------------------------------------
const AR_M = ['كانون الثاني', 'شباط', 'آذار', 'نيسان', 'أيار', 'حزيران', 'تموز', 'آب', 'أيلول', 'تشرين الأول', 'تشرين الثاني', 'كانون الأول'];
const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const CDS = {};
async function viewChequesDash(v, ctx) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const qs = new URLSearchParams(location.hash.split('?')[1] || '');
  const dir = qs.get('dir') === 'out' ? 'out' : 'in', openSt = dir === 'in' ? 'portfolio' : 'issued', doneSt = dir === 'in' ? 'collected' : 'paid';
  let [{ data, error }, parties] = await Promise.all([sb.from('cheques').select('*').eq('company_id', S.company.id).eq('direction', dir).order('due_date').limit(10000), loadParties()]);
  if (error) throw error;
  data = data.filter(c => c.status !== 'cancelled');
  const pName = Object.fromEntries(parties.map(p => [p.id, p.name]));
  const st = CDS[dir] || (CDS[dir] = { party: '', from: '', to: '', flt: { open: true, done: false, returned: false }, mode: 'month', cur: today().slice(0, 7) + '-01', day: today() });
  const cls = (c) => c.status === openSt ? (c.due_date < today() ? 'late' : c.due_date === today() ? 'today' : daysTo(c.due_date) <= 7 ? 'soon' : 'open') : c.status === doneSt ? 'done' : 'ret';
  const CL = { late: ['متأخر', '#dc2626'], today: ['مستحق اليوم', '#d97706'], soon: ['قريباً', '#7c3aed'], open: ['بالمحفظة', '#2563eb'], done: [dir === 'in' ? 'محصّل' : 'مصروف', '#059669'], ret: ['مرجع', '#64748b'] };
  const rows = () => data.filter(c => (!st.party || c.party_id === st.party) && (!st.from || c.due_date >= st.from) && (!st.to || c.due_date <= st.to)
    && ((st.flt.open && c.status === openSt) || (st.flt.done && c.status === doneSt) || (st.flt.returned && c.status === 'returned')));
  const draw = () => {
    const R = rows(), open = R.filter(c => c.status === openSt), sum = (a) => a.reduce((s, c) => s + num(c.amount), 0);
    const late = open.filter(c => c.due_date < today()), wk = open.filter(c => c.due_date >= today() && daysTo(c.due_date) <= 7);
    // الرسم الشهري: آخر 6 شهور وأول 6 جاية
    const base = new Date(today()); const months = Array.from({ length: 12 }, (_, i) => { const d = new Date(base.getFullYear(), base.getMonth() - 5 + i, 1); return iso(d).slice(0, 7); });
    const byM = Object.fromEntries(months.map(m => [m, { late: 0, open: 0, done: 0, ret: 0 }]));
    R.forEach(c => { const m = c.due_date.slice(0, 7); if (!byM[m]) return; const k = cls(c); byM[m][k === 'today' || k === 'soon' ? 'open' : k] += num(c.amount); });
    const mx = Math.max(1, ...months.map(m => Object.values(byM[m]).reduce((a, b) => a + b, 0)));
    // التقويم
    const cur = new Date(st.cur), y = cur.getFullYear(), mo = cur.getMonth();
    let days;
    if (st.mode === 'month') { const first = new Date(y, mo, 1), pad = first.getDay(), n = new Date(y, mo + 1, 0).getDate(); days = [...Array(pad).fill(null), ...Array.from({ length: n }, (_, i) => iso(new Date(y, mo, i + 1)))]; }
    else { const d0 = new Date(st.day); d0.setDate(d0.getDate() - d0.getDay()); days = Array.from({ length: 7 }, (_, i) => iso(new Date(d0.getFullYear(), d0.getMonth(), d0.getDate() + i))); }
    const byDay = {}; R.forEach(c => (byDay[c.due_date] ||= []).push(c));
    const dayList = byDay[st.day] || [];
    v.querySelector('#body').innerHTML = `
      <div class="ckpi">
        <div><span>قيمة المستحق</span><b>${fmtNum(sum(open))}</b><small>بالفترة والفلاتر</small></div>
        <div><span>عدد الشيكات المستحقة</span><b>${open.length}</b><small>غير محصّلة بعد</small></div>
        <div class="bad"><span>متأخر</span><b>${late.length}</b><small>${fmtNum(sum(late))}</small></div>
        <div class="warn"><span>مستحق خلال 7 أيام</span><b>${wk.length}</b><small>${fmtNum(sum(wk))}</small></div></div>
      <div class="grid cols-2" style="gap:14px;align-items:start">
        <div class="card"><h3 style="margin-top:0">📊 النظرة الشهرية <small class="muted">(القيمة حسب شهر الاستحقاق)</small></h3>
          <div class="cbars">${months.map(m => { const b = byM[m], t = Object.values(b).reduce((a, x) => a + x, 0);
            return `<div class="cb" title="${m}: ${fmtNum(t)}"><div class="v">${t ? fmtNum(t) : ''}</div><div class="stack" style="height:${Math.round(t / mx * 150)}px">${['ret', 'done', 'open', 'late'].map(k => b[k] ? `<i style="flex:${b[k]};background:${CL[k][1]}"></i>` : '').join('')}</div><div class="m">${AR_M[+m.slice(5) - 1]}</div></div>`; }).join('')}</div>
          <div class="cleg">${['late', 'open', 'done', 'ret'].map(k => `<span><i style="background:${CL[k][1]}"></i>${CL[k][0]}</span>`).join('')}</div></div>
        <div class="card"><div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap"><h3 style="margin:0">📅 تقويم تاريخ الاستحقاق</h3><div class="spacer"></div>
            <button class="btn sm ${st.mode === 'month' ? 'primary' : ''}" data-mode="month">شهر</button><button class="btn sm ${st.mode === 'week' ? 'primary' : ''}" data-mode="week">أسبوع</button>
            <button class="btn sm" data-nav="-1">→</button><b>${st.mode === 'month' ? `${AR_M[mo]} ${y}` : fmtDate(days[0]) + ' - ' + fmtDate(days[6])}</b><button class="btn sm" data-nav="1">←</button></div>
          <div class="ccal">${['الأحد', 'الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت'].map(d => `<div class="h">${d}</div>`).join('')}
            ${days.map(d => d ? `<div class="d ${d === st.day ? 'sel' : ''} ${d === today() ? 'tdy' : ''}" data-day="${d}"><span>${+d.slice(8)}</span><div>${[...new Set((byDay[d] || []).map(cls))].map(k => `<i style="background:${CL[k][1]}"></i>`).join('')}</div></div>` : '<div></div>').join('')}</div>
          <h4 style="margin:10px 0 4px">مستحق في ${fmtDate(st.day)} ${dayList.length ? `<span class="badge brand">${dayList.length}</span>` : ''}</h4>
          ${dayList.map(c => `<div class="cday"><div><b>${fmtNum(c.amount)}</b> <span class="badge" style="background:${CL[cls(c)][1]};color:#fff">${CL[cls(c)][0]}</span></div>
            <div>${esc(pName[c.party_id] || c.drawer_name || '')}</div><div class="muted" style="font-size:12px">رقم الشيك: ${esc(c.cheque_no)} · ${esc(c.bank_name || '')} · تاريخ الإصدار ${fmtDate(c.issue_date)}</div></div>`).join('') || '<div class="empty">ما في شيكات بهاليوم</div>'}</div></div>`;
    v.querySelectorAll('[data-mode]').forEach(b => b.onclick = () => { st.mode = b.dataset.mode; draw(); });
    v.querySelectorAll('[data-nav]').forEach(b => b.onclick = () => { const k = +b.dataset.nav;
      if (st.mode === 'month') { const d = new Date(st.cur); st.cur = iso(new Date(d.getFullYear(), d.getMonth() + k, 1)); }
      else { const d = new Date(st.day); d.setDate(d.getDate() + 7 * k); st.day = iso(d); st.cur = st.day.slice(0, 7) + '-01'; } draw(); });
    v.querySelectorAll('[data-day]').forEach(b => b.onclick = () => { st.day = b.dataset.day; draw(); });
  };
  const custs = parties.filter(p => p.party_type === (dir === 'in' ? 'customer' : 'supplier'));
  v.innerHTML = `<style>
    .ckpi{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:12px}.ckpi>div{background:var(--card,#fff);border:1px solid var(--line,#e5e7eb);border-radius:12px;padding:12px}
    .ckpi span{display:block;color:var(--ink2);font-size:13px}.ckpi b{display:block;font-size:24px;margin:4px 0}.ckpi small{color:var(--ink2)}.ckpi .bad b{color:#dc2626}.ckpi .warn b{color:#d97706}
    .cbars{display:flex;align-items:flex-end;gap:6px;height:200px;padding-top:10px}.cb{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:flex-end;min-width:0}
    .cb .stack{width:70%;display:flex;flex-direction:column-reverse;border-radius:4px 4px 0 0;overflow:hidden;min-height:2px;background:var(--tint)}.cb .stack i{display:block}
    .cb .v{font-size:10px;color:var(--ink2);writing-mode:vertical-rl;transform:rotate(180deg);max-height:60px;overflow:hidden}.cb .m{font-size:10px;margin-top:4px;text-align:center;line-height:1.2;height:26px}
    .cleg{display:flex;gap:12px;flex-wrap:wrap;font-size:12px;margin-top:6px}.cleg i{display:inline-block;width:10px;height:10px;border-radius:50%;margin-inline-end:4px}
    .ccal{display:grid;grid-template-columns:repeat(7,1fr);gap:4px;margin-top:8px}.ccal .h{font-size:11px;color:var(--ink2);text-align:center}
    .ccal .d{border:1px solid var(--line,#e5e7eb);border-radius:8px;padding:4px;min-height:44px;cursor:pointer;text-align:center}.ccal .d.sel{background:var(--brand);color:#fff}.ccal .d.tdy{outline:2px solid var(--brand)}
    .ccal .d div{display:flex;gap:2px;justify-content:center;margin-top:2px}.ccal .d i{width:7px;height:7px;border-radius:50%;display:block}
    .cday{border:1px solid var(--line,#e5e7eb);border-inline-start:4px solid var(--brand);border-radius:10px;padding:8px;margin-bottom:6px}
    @media(max-width:800px){.ckpi{grid-template-columns:1fr 1fr}}</style>
    <div class="page-head"><h2>📈 لوحة ${dir === 'in' ? 'شيكات العملاء الواردة' : 'الشيكات الصادرة'}</h2><div class="spacer"></div>
      <a class="btn sm" href="#/cheques-dash?dir=${dir === 'in' ? 'out' : 'in'}">${dir === 'in' ? '📤 الصادرة' : '📥 الواردة'}</a> <a class="btn sm" href="#/cheques?dir=${dir}">💳 محفظة الشيكات</a></div>
    <div class="card no-print filters" style="display:flex;gap:10px;flex-wrap:wrap;align-items:end">
      <div class="field"><label>${dir === 'in' ? 'العميل' : 'المورد'}</label><select id="f-p"><option value="">— الكل —</option>${custs.map(p => `<option value="${p.id}" ${p.id === st.party ? 'selected' : ''}>${esc(partyLabel(p))}</option>`).join('')}</select></div>
      <div class="field"><label>الاستحقاق من</label><input type="date" id="f-from" value="${st.from}"></div><div class="field"><label>إلى</label><input type="date" id="f-to" value="${st.to}"></div>
      <label class="check"><input type="checkbox" data-f="open" ${st.flt.open ? 'checked' : ''}> بالمحفظة</label>
      <label class="check"><input type="checkbox" data-f="done" ${st.flt.done ? 'checked' : ''}> ${dir === 'in' ? 'محصّل' : 'مصروف'}</label>
      <label class="check"><input type="checkbox" data-f="returned" ${st.flt.returned ? 'checked' : ''}> مرجع</label>
      <button class="btn" id="f-reset">مسح الفلاتر</button></div>
    <div id="body"></div>`;
  v.querySelector('#f-p').onchange = (e) => { st.party = e.target.value; draw(); };
  v.querySelector('#f-from').onchange = (e) => { st.from = e.target.value; draw(); };
  v.querySelector('#f-to').onchange = (e) => { st.to = e.target.value; draw(); };
  v.querySelectorAll('[data-f]').forEach(c => c.onchange = () => { st.flt[c.dataset.f] = c.checked; draw(); });
  v.querySelector('#f-reset').onclick = () => { CDS[dir] = null; viewChequesDash(v, ctx); };
  draw();
}

export const CHEQUE_ROUTES = { 'cheques': viewCheques, 'cheques-dash': viewChequesDash };
