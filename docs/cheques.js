// =====================================================================
//  السمو ERP — محفظة الشيكات (واردة وصادرة)
// =====================================================================
import { S, sb, esc, fmtDate, fmtNum, num, today, toast, arError, modal, confirmBox, formData, can, log } from './core.js';
import { loadAccounts, leafAccounts, accLabel, downloadCSV } from './finance.js';
import { loadParties, partyDatalist, resolveParty, partyLabel } from './parties.js';
import { printDoc } from './print.js';

const ST = {
  portfolio: ['بالمحفظة', 'warn'], collected: ['محصّل', 'ok'], returned: ['راجع', 'bad'],
  issued: ['صادر (بانتظار الصرف)', 'warn'], paid: ['مصروف', 'ok'], cancelled: ['ملغى', 'bad'],
};
const daysTo = (d) => Math.round((new Date(d) - new Date(today())) / 86400000);

async function viewCheques(v, ctx) {
  if (!S.company) return void (v.innerHTML = `<div class="notice info">اختار شركة من فوق أول.</div>`);
  const dir = new URLSearchParams(location.hash.split('?')[1] || '').get('dir') === 'out' ? 'out' : 'in';
  const [{ data, error }, parties, accs] = await Promise.all([
    sb.from('cheques').select('*').eq('company_id', S.company.id).eq('direction', dir).order('due_date').limit(5000), loadParties(), loadAccounts()]);
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
        ${Object.entries(ST).filter(([k]) => dir === 'in' ? ['portfolio', 'collected', 'returned'].includes(k) : ['issued', 'paid', 'cancelled'].includes(k)).map(([k, [l]]) => `<option value="${k}">${l}</option>`).join('')}</select></div>
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
          ? (c.status === 'portfolio' ? `<button class="btn sm primary" data-act="collect" data-id="${c.id}">✓ تحصيل</button> <button class="btn sm danger" data-act="return" data-id="${c.id}">راجع</button>`
             : c.status === 'collected' ? `<button class="btn sm danger" data-act="return" data-id="${c.id}">راجع</button>` : '')
          : (c.status === 'issued' ? `<button class="btn sm primary" data-act="pay" data-id="${c.id}">✓ انصرف</button> <button class="btn sm danger" data-act="cancel" data-id="${c.id}">إلغاء</button>` : '')) : ''}
          <button class="btn sm" data-hist="${c.id}">السجل</button></td></tr>`; }).join('') || '<tr><td colspan="7" class="empty">ما في شيكات</td></tr>';
    v.querySelector('#tot').textContent = fmtNum(shown.reduce((s, c) => s + num(c.amount), 0));
  };
  draw(); ['#f-s', '#f-from', '#f-to', '#f-q'].forEach(s => v.querySelector(s).addEventListener('input', draw));
  const banks = leafAccounts(accs).filter(a => ['bank', 'cash'].includes(a.account_type)).concat(leafAccounts(accs).filter(a => !['bank', 'cash'].includes(a.account_type)));
  const bankSel = (sel) => `<select name="bank">${banks.map(a => `<option value="${a.id}" ${a.id === sel ? 'selected' : ''}>${esc(accLabel(a))}</option>`).join('')}</select>`;

  v.querySelector('#add')?.addEventListener('click', () => {
    const myParties = parties.filter(p => p.party_type === (dir === 'in' ? 'customer' : 'supplier') && p.is_active);
    const m = modal({ title: dir === 'in' ? 'تسجيل شيك وارد' : 'تسجيل شيك صادر', body: `<form id="c-form"><div class="grid cols-2">
      <div class="field"><label>رقم الشيك *</label><input name="cheque_no" dir="ltr"></div>
      <div class="field"><label>المبلغ *</label><input name="amount" inputmode="decimal" dir="ltr"></div>
      <div class="field"><label>البنك</label><input name="bank_name"></div><div class="field"><label>الفرع</label><input name="branch"></div>
      <div class="field"><label>تاريخ ${dir === 'in' ? 'الاستلام' : 'الإصدار'} *</label><input type="date" name="issue_date" value="${today()}"></div>
      <div class="field"><label>تاريخ الاستحقاق *</label><input type="date" name="due_date" value="${today()}"></div>
      <div class="field" style="grid-column:span 2"><label>${dir === 'in' ? 'العميل' : 'المورد'}</label><input list="party-list" id="c-party" placeholder="اختار من القائمة…">${partyDatalist(myParties)}</div>
      <div class="field"><label>أو حساب مقابل (إذا مش عميل/مورد)</label><select name="account_id"><option value="">—</option>${leafAccounts(accs).map(a => `<option value="${a.id}">${esc(accLabel(a))}</option>`).join('')}</select></div>
      <div class="field"><label>اسم ${dir === 'in' ? 'الساحب' : 'المستفيد'}</label><input name="drawer_name"></div></div>
      <div class="field"><label>ملاحظات</label><input name="notes"></div></form>
      <p class="muted" style="font-size:13px">${dir === 'in' ? 'بينعمل قيد: من حـ/ شيكات برسم التحصيل إلى حـ/ العميل.' : 'بينعمل قيد: من حـ/ المورد إلى حـ/ شيكات آجلة الدفع.'}</p>`,
      foot: `<button class="btn primary" data-save>💾 تسجيل</button><button class="btn" data-close>إلغاء</button>` });
    m.el.querySelector('[data-save]').onclick = async (e) => {
      const d = formData(m.el.querySelector('#c-form')); const pi = m.el.querySelector('#c-party').value; const p = resolveParty(myParties, pi);
      if (!d.cheque_no || !num(d.amount) || !d.due_date || !d.issue_date) return toast('رقم الشيك والمبلغ والتواريخ مطلوبة', 'err');
      if (pi && !p) return toast('العميل/المورد مش موجود بالقائمة', 'err');
      if (!p && !d.account_id) return toast('اختار العميل/المورد أو الحساب المقابل', 'err');
      e.target.disabled = true;
      const { error } = await sb.rpc('register_cheque', { p: { ...d, amount: num(d.amount), company_id: S.company.id, direction: dir, party_id: p?.id || null, drawer_name: d.drawer_name || p?.name || null } });
      if (error) { e.target.disabled = false; return toast(arError(error), 'err'); }
      toast('تم تسجيل الشيك وترحيل قيده', 'ok'); m.close(); ctx.rerender();
    };
  });

  v.querySelector('#rows').onclick = async (e) => {
    const b = e.target.closest('[data-act]'), h = e.target.closest('[data-hist]');
    if (h) {
      const { data: ev } = await sb.from('cheque_events').select('*').eq('cheque_id', h.dataset.hist).order('created_at');
      return void modal({ title: 'سجل الشيك', size: 'sm', body: `<table class="t">${(ev || []).map(x => `<tr><td>${fmtDate(x.event_date)}</td><td>${esc(x.action)}</td><td class="muted">${esc(x.note || '')}</td></tr>`).join('') || '<tr><td class="empty">ما في حركات</td></tr>'}</table>`,
        foot: '<button class="btn" data-close>إغلاق</button>' });
    }
    if (!b) return;
    const c = data.find(x => x.id === b.dataset.id), act = b.dataset.act;
    const T = { collect: 'تحصيل الشيك', return: 'شيك راجع', pay: 'صرف الشيك من البنك', cancel: 'إلغاء الشيك الصادر' }[act];
    const needBank = act === 'collect' || act === 'pay' || (act === 'return' && c.status === 'collected');
    const m = modal({ title: `${T} رقم ${c.cheque_no}`, size: 'sm', body: `<form id="a-form">
      <div class="field"><label>التاريخ</label><input type="date" name="date" value="${today()}"></div>
      ${needBank ? `<div class="field"><label>البنك</label>${bankSel(c.bank_account_id)}</div>` : ''}
      <div class="field"><label>ملاحظة</label><input name="note"></div></form>
      <p class="muted" style="font-size:13px">${act === 'return' ? 'الشيك الراجع بيرجّع المبلغ على حساب العميل.' : act === 'cancel' ? 'الإلغاء بيرجّع المبلغ لحساب المورد.' : 'بينعمل قيد مرحّل تلقائياً.'}</p>`,
      foot: `<button class="btn primary" data-go>تأكيد</button><button class="btn" data-close>إلغاء</button>` });
    m.el.querySelector('[data-go]').onclick = async (ev) => {
      const d = formData(m.el.querySelector('#a-form')); ev.target.disabled = true;
      const { error } = await sb.rpc('cheque_action', { p_id: c.id, p_action: act, p_date: d.date, p_bank: d.bank || null, p_note: d.note });
      if (error) { ev.target.disabled = false; return toast(arError(error), 'err'); }
      toast('تم ✓', 'ok'); m.close(); ctx.rerender();
    };
  };
  v.querySelector('#csv').onclick = () => downloadCSV(`الشيكات ${dir === 'in' ? 'الواردة' : 'الصادرة'}.csv`, [['الاستحقاق', 'رقم الشيك', 'البنك', 'الفرع', 'الاسم', 'المبلغ', 'الحالة']]
    .concat(shown.map(c => [c.due_date, c.cheque_no, c.bank_name, c.branch, pName[c.party_id] || c.drawer_name, num(c.amount).toFixed(3), ST[c.status][0]])));
  v.querySelector('#prn').onclick = () => printDoc(`كشف الشيكات ${dir === 'in' ? 'الواردة' : 'الصادرة'}`, `<table class="pt"><thead><tr><th>الاستحقاق</th><th>رقم الشيك</th><th>البنك</th><th>الاسم</th><th>المبلغ</th><th>الحالة</th></tr></thead><tbody>
    ${shown.map(c => `<tr><td>${fmtDate(c.due_date)}</td><td>${esc(c.cheque_no)}</td><td>${esc(c.bank_name || '')}</td><td>${esc(pName[c.party_id] || c.drawer_name || '')}</td><td class="n">${fmtNum(c.amount)}</td><td>${ST[c.status][0]}</td></tr>`).join('')}</tbody>
    <tfoot><tr class="tot"><td colspan="4">المجموع</td><td class="n">${fmtNum(shown.reduce((s, c) => s + num(c.amount), 0))}</td><td></td></tr></tfoot></table>`, { subtitle: `بتاريخ ${fmtDate(today())}` });
}

export const CHEQUE_ROUTES = { 'cheques': viewCheques };
