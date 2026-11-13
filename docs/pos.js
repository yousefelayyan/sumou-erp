// =====================================================================
//  السمو ERP — نقطة البيع (الكاشير)
//  شاشة لمس: فئات + أصناف بالصور + بحث/باركود، سلة، دفع نقدي/بطاقة مع الباقي.
//  الحفظ = RPC pos_checkout (فاتورة بيع نقدية مرحّلة للمحاسبة والمخزون)،
//  وبعدها وصل على طابعة الرول (80 أو 58 ملم). فتح درج الكاش من إعداد الطابعة.
// =====================================================================
import { S, sb, esc, toast, arError, can, modal, formData, fmtNum, fmtDateTime, num, localStorageGet, localStorageSet, fmtQty, fmtPrice } from './core.js';
import { loadAccounts, leafAccounts, accLabel } from './finance.js';
import { loadWarehouses } from './inventory.js';
import { posMethods, loadLookups } from './lookups.js';
import { loadParties } from './parties.js';

const localDate = () => new Date().toLocaleDateString('en-CA');   // تاريخ الجهاز (مش UTC)
const r3 = (x) => Math.round((Number(x) || 0) * 1000) / 1000;
const POS_DEF = { warehouse_id: '', cash_account_id: '', card_account_id: '', prices_include_tax: true, header: '', footer: 'شكراً لزيارتكم', paper: '80', auto_print: true, copies: 1 };
let cfgCache = null;

async function loadPosCfg(force = false) {
  if (!force && cfgCache?.cid === S.company.id) return cfgCache.v;
  const { data } = await sb.from('company_settings').select('pos').eq('company_id', S.company.id).maybeSingle();
  // كاشير الفرع: إعدادات دائرة المستخدم الافتراضية بتغطي على إعداد الشركة
  const dep = S.memberships.find(x => x.company_id === S.company.id)?.department_id;
  const dp = dep ? ((await sb.from('departments').select('pos,name,address,phone,sales_tax_no').eq('id', dep).maybeSingle()).data || null) : null;
  cfgCache = { cid: S.company.id, v: { ...POS_DEF, ...(data?.pos || {}), ...(dp?.pos || {}), branch: dp ? { name: dp.name, address: dp.address, phone: dp.phone, sales_tax_no: dp.sales_tax_no } : null } };
  return cfgCache.v;
}

// السعر الظاهر للكاشير = سعر الصنف (شامل الضريبة إذا الإعداد شامل)
const shownPrice = (it) => num(it.sale_price);
function totals(cart, cfg, invDisc = 0) {
  let sub = 0, tax = 0, disc = 0, left = invDisc;
  const G = cart.reduce((a, l) => a + r3(l.qty * l.price - (l.discount || 0)), 0);
  for (const [k, l] of cart.entries()) {
    let g = r3(l.qty * l.price - (l.discount || 0)); const rate = num(l.item.tax_rate);
    // خصم الفاتورة بيتوزّع على السطور (نفس طريقة قاعدة البيانات)
    if (invDisc > 0 && G > 0) { let sh = k === cart.length - 1 ? left : Math.min(left, r3(invDisc * g / G)); sh = Math.min(sh, g); left = r3(left - sh); g = r3(g - sh); disc += sh; }
    if (cfg.prices_include_tax) { const s = r3(g / (1 + rate / 100)); sub += s; tax += r3(g - s); }
    else { sub += g; tax += r3(g * rate / 100); }
    disc += l.discount || 0;
  }
  return { sub: r3(sub), tax: r3(tax), disc: r3(disc), total: r3(sub + tax) };
}

async function viewPos(v, ctx) {
  if (!can('pos', 'view')) return void (v.innerHTML = '<div class="notice">ما عندك صلاحية على نقطة البيع.</div>');
  const cfg = await loadPosCfg();
  const [methods, accs] = await Promise.all([posMethods(), loadAccounts()]);
  const accType = (id) => accs.find(a => a.id === id)?.account_type;
  // وسائل الدفع من «إعداد ← وسائل الدفع» (مأشّر عليها نقطة البيع)، وإذا ما في: نقدي/بطاقة من إعدادات نقطة البيع
  const PAY = methods.length
    ? methods.map(x => ({ id: x.id, label: x.pos_label || x.name, sub: x.name2 || '', cash: accType(x.account_id) === 'cash' }))
    : [{ id: '', method: 'cash', label: '💵 نقدي', cash: true }, { id: '', method: 'card', label: '💳 بطاقة', cash: false }];
  const [{ data: items, error }, { data: cats }] = await Promise.all([
    sb.from('items').select('id,code,name,barcode,sale_price,tax_rate,unit,image,category_id,item_type').eq('company_id', S.company.id).eq('is_active', true).order('name').limit(3000),
    sb.from('item_categories').select('id,code,name').eq('company_id', S.company.id).order('code'),
  ]);
  if (error) return void (v.innerHTML = `<div class="notice">${esc(arError(error))}</div>`);
  const catList = (cats || []).filter(c => items.some(i => i.category_id === c.id));
  const cartKey = 'sumou.pos.cart.' + S.company.id;
  const parties = (await loadParties()).filter(x => x.party_type === 'customer' && x.is_active);
  let cart = [], cust = null, invDisc = 0;
  try {
    const sv = JSON.parse(localStorageGet(cartKey) || '[]') || [];
    const rows = Array.isArray(sv) ? sv : (sv.lines || []);
    cart = rows.map(l => ({ ...l, item: items.find(i => i.id === l.id) })).filter(l => l.item);
    if (!Array.isArray(sv)) { cust = parties.find(x => x.id === sv.cust) || null; invDisc = num(sv.disc); }
  } catch { cart = []; }
  const lastKey = 'sumou.pos.last.' + S.company.id;
  // مندوب المبيعات: بيضل محفوظ على هالجهاز
  const reps = (await loadLookups()).filter(x => x.kind === 'sales_rep' && x.is_active);
  const repKey = 'sumou.pos.rep.' + S.company.id;
  let rep = reps.find(x => x.id === localStorageGet(repKey)) || null;
  const canDisc = can('pos', 'edit') || can('sales_invoices', 'edit');
  let cat = '', q = '', sel = cart.length - 1;
  const canEditPrice = can('sales_invoices', 'edit');
  if (!canEditPrice) cart.forEach(l => { l.price = num(l.item.sale_price); l.discount = 0; });   // السعر الحالي للصنف
  const saveCart = () => localStorageSet(cartKey, cart.length || cust || invDisc
    ? JSON.stringify({ lines: cart.map(l => ({ id: l.item.id, qty: l.qty, price: l.price, discount: l.discount || 0 })), cust: cust?.id || null, disc: invDisc })
    : null);
  const td = localDate(); const yearOk = S.fy && !S.fy.is_closed && td >= S.fy.start_date && td <= S.fy.end_date;

  v.innerHTML = `
  <div class="pos">
    <section class="pos-left">
      <div class="pos-top">
        <input id="pos-q" class="pos-search" placeholder="🔍 بحث أو امسح الباركود…" autocomplete="off" inputmode="search">
        ${can('companies', 'edit') ? '<button class="pos-icon" id="pos-cfg" title="إعدادات نقطة البيع">⚙️</button>' : ''}
      </div>
      <div class="pos-cats" id="pos-cats"></div>
      <div class="pos-grid" id="pos-grid"></div>
    </section>
    <aside class="pos-cart">
      <div class="pos-cart-head"><b>🧾 الفاتورة</b><span class="muted" id="pos-count"></span><button class="pos-link" id="pos-clear">🆕 جديد</button></div>
      <button class="pos-cust" id="pos-cust"></button>
      <div class="pos-lines" id="pos-lines"></div>
      <div class="pos-keys" id="pos-keys">
        ${[['7'], ['8'], ['9'], ['+', '＋', 'op'], ['4'], ['5'], ['6'], ['-', '－', 'op'], ['1'], ['2'], ['3'], ['del', '🗑', 'op danger'], ['.'], ['0'], ['⌫'], ...(canDisc ? [['disc', '٪ خصم', 'op']] : [])].map(([k, t, c]) => `<button data-k="${k}" class="${c || ''}">${t || k}</button>`).join('')}
      </div>
      <div class="pos-sum" id="pos-sum"></div>
      <button class="pos-pay" id="pos-pay">💵 دفع</button>
    </aside>
  </div>
  <div class="pos-info" id="pos-info"></div>
  ${yearOk ? '' : `<div class="notice" style="margin-top:10px">السنة المالية المختارة ما فيها تاريخ اليوم أو مغلقة. اختار السنة الحالية من «تبديل السنة».</div>`}`;

  const $ = (s) => v.querySelector(s);
  let typed = '';   // كمية مكتوبة من لوحة الأرقام للسطر المختار
  const drawCats = () => {
    $('#pos-cats').innerHTML = `<button class="${!cat ? 'on' : ''}" data-c="">الكل</button>` + catList.map(c => `<button class="${cat === c.id ? 'on' : ''}" data-c="${c.id}">${esc(c.name)}</button>`).join('')
      + (items.some(i => !i.category_id) && catList.length ? `<button class="${cat === '-' ? 'on' : ''}" data-c="-">بدون فئة</button>` : '');
  };
  const drawGrid = () => {
    const qq = q.toLowerCase();
    const list = items.filter(i => (!cat || (cat === '-' ? !i.category_id : i.category_id === cat)) && (!qq || [i.name, i.code, i.barcode].some(x => (x || '').toLowerCase().includes(qq)))).slice(0, 400);
    $('#pos-grid').innerHTML = list.map(i => `<button class="pos-item" data-i="${i.id}">
        <span class="pi-img">${i.image ? `<img src="${esc(i.image)}" alt="" loading="lazy">` : `<span class="pi-ph">${esc((i.name || '?').trim().charAt(0))}</span>`}</span>
        <span class="pi-name">${esc(i.name)}</span><span class="pi-price">${fmtNum(shownPrice(i, cfg))}</span></button>`).join('')
      || '<div class="empty">ما في أصناف</div>';
  };
  const drawCart = () => {
    const t = totals(cart, cfg, invDisc);
    $('#pos-lines').innerHTML = cart.map((l, k) => `<div class="pos-line ${k === sel ? 'sel' : ''}" data-l="${k}">
        <div class="pl-name">${esc(l.item.name)}<small>${fmtPrice(l.price)} × ${fmtQty(l.qty, l.qty % 1 ? 3 : 0)}${l.discount ? ` − خصم ${fmtNum(l.discount)}` : ''}</small></div>
        <div class="pl-qty"><button data-m="${k}">－</button><b>${fmtQty(l.qty, l.qty % 1 ? 3 : 0)}</b><button data-p="${k}">＋</button></div>
        <div class="pl-tot">${fmtNum(r3(l.qty * l.price - (l.discount || 0)))}</div></div>`).join('')
      || '<div class="pos-empty">اضغط على صنف عشان ينضاف للفاتورة</div>';
    $('#pos-count').textContent = cart.length ? `${cart.length} صنف` : '';
    $('#pos-cust').innerHTML = cust ? `👤 <b>${esc(cust.name)}</b>${cust.mobile || cust.phone ? ` <span dir="ltr">${esc(cust.mobile || cust.phone)}</span>` : ''} <span class="x">✕</span>` : '👤 زبون نقدي <small>(اضغط لاختيار زبون)</small>';
    const last = (() => { try { return JSON.parse(localStorageGet(lastKey) || 'null'); } catch { return null; } })();
    $('#pos-info').innerHTML = `<span>👨‍💼 ${esc(S.profile?.full_name || S.profile?.username || '')} / ${esc(S.company.name)}</span>
      ${reps.length ? `<button class="btn sm" id="pos-rep">🧑‍💼 المندوب: <b>${esc(rep?.name || 'بدون')}</b></button>` : ''}
      ${last ? `<span>🧾 آخر فاتورة: <b>${esc(last.sale.doc_code || last.sale.no)}</b> — ${fmtNum(last.sale.total)}</span><button class="btn sm" id="pos-reprint">🖨️ إعادة طباعة آخر وصل</button>` : ''}`;
    $('#pos-sum').innerHTML = `${t.disc ? `<div><span>الخصم</span><b>${fmtNum(t.disc)}</b></div>` : ''}<div><span>قبل الضريبة</span><b>${fmtNum(t.sub)}</b></div><div><span>الضريبة</span><b>${fmtNum(t.tax)}</b></div>
      <div class="big"><span>المجموع</span><b>${fmtNum(t.total)}</b></div>`;
    $('#pos-pay').disabled = !cart.length || !yearOk;
    v.querySelector('.pos-line.sel')?.scrollIntoView({ block: 'nearest' });
    saveCart();
  };
  const addItem = (it, qty = 1) => {
    const k = cart.findIndex(l => l.item.id === it.id && !l.discount && l.price === shownPrice(it, cfg));
    if (k >= 0) { cart[k].qty = r3(cart[k].qty + qty); sel = k; }
    else { cart.push({ item: it, qty, price: shownPrice(it, cfg), discount: 0 }); sel = cart.length - 1; }
    typed = ''; drawCart();
  };
  drawCats(); drawGrid(); drawCart();

  $('#pos-cats').onclick = (e) => { const b = e.target.closest('[data-c]'); if (!b) return; cat = b.dataset.c; drawCats(); drawGrid(); };
  $('#pos-grid').onclick = (e) => { const b = e.target.closest('[data-i]'); if (b) addItem(items.find(i => i.id === b.dataset.i)); };
  const qi = $('#pos-q');
  qi.oninput = () => { q = qi.value.trim(); drawGrid(); };
  qi.onkeydown = (e) => {   // الباركود: الماسح بيكتب الرقم وبيضغط إدخال
    if (e.key !== 'Enter') return;
    const t = qi.value.trim(); if (!t) return;
    const it = items.find(i => i.barcode && i.barcode === t) || items.find(i => i.code === t);
    if (it) { addItem(it); qi.value = ''; q = ''; drawGrid(); } else toast('ما في صنف بهالباركود', 'err');
  };
  $('#pos-lines').onclick = (e) => {
    const m = e.target.closest('[data-m]'), p = e.target.closest('[data-p]'), l = e.target.closest('[data-l]');
    if (m) { const k = +m.dataset.m; cart[k].qty = r3(cart[k].qty - 1); if (cart[k].qty <= 0) { cart.splice(k, 1); sel = Math.min(sel, cart.length - 1); } typed = ''; return drawCart(); }
    if (p) { const k = +p.dataset.p; cart[k].qty = r3(cart[k].qty + 1); sel = k; typed = ''; return drawCart(); }
    if (l) { sel = +l.dataset.l; typed = ''; drawCart(); if (canEditPrice && e.detail === 2) editLine(sel); }
  };
  const editLine = (k) => {
    const l = cart[k]; if (!l) return;
    const m = modal({ title: l.item.name, size: 'sm', body: `<form id="el" class="grid cols-3">
      <div class="field"><label>الكمية</label><input name="qty" inputmode="decimal" dir="ltr" value="${l.qty}"></div>
      <div class="field"><label>السعر</label><input name="price" inputmode="decimal" dir="ltr" value="${l.price}"></div>
      <div class="field"><label>خصم (مبلغ)</label><input name="discount" inputmode="decimal" dir="ltr" value="${l.discount || 0}"></div></form>`,
      foot: '<button class="btn primary" data-ok>تمام</button><button class="btn" data-close>إلغاء</button>' });
    m.el.querySelector('[data-ok]').onclick = () => { const d = formData(m.el.querySelector('#el'));
      if (num(d.qty) <= 0) return toast('الكمية لازم أكبر من صفر', 'err');
      if (num(d.discount) > num(d.qty) * num(d.price)) return toast('الخصم أكبر من قيمة السطر', 'err');
      Object.assign(l, { qty: num(d.qty), price: num(d.price), discount: num(d.discount) }); m.close(); drawCart(); };
  };
  $('#pos-keys').onclick = (e) => {
    const k = e.target.closest('[data-k]')?.dataset.k; if (!k) return;
    if (k === 'disc') return discDialog();
    if (!cart[sel]) return;
    const l = cart[sel];
    if (k === '+') { l.qty = r3(l.qty + 1); typed = ''; }
    else if (k === '-') { l.qty = r3(l.qty - 1); typed = ''; if (l.qty <= 0) { cart.splice(sel, 1); sel = cart.length - 1; } }
    else if (k === 'del') { cart.splice(sel, 1); sel = cart.length - 1; typed = ''; }
    else if (k === 'disc') return discDialog();
    else {
      typed = k === '⌫' ? typed.slice(0, -1) : (typed + k).replace(/^0+(?=\d)/, '');
      if (k === '.' && typed.split('.').length > 2) typed = typed.slice(0, -1);
      const n = num(typed); if (n > 0) l.qty = n;
    }
    drawCart();
  };
  $('#pos-clear').onclick = () => { cart = []; sel = -1; cust = null; invDisc = 0; drawCart(); };
  $('#pos-cust').onclick = (e) => { if (e.target.closest('.x')) { cust = null; return drawCart(); } custDialog(); };
  $('#pos-info').onclick = (e) => {
    if (e.target.closest('#pos-rep')) return repDialog();
    if (!e.target.closest('#pos-reprint')) return;
    try { const last = JSON.parse(localStorageGet(lastKey)); printReceipt({ ...last, cfg }); } catch { toast('ما في وصل محفوظ', 'err'); } };
  function custDialog() {
    const m = modal({ title: '👤 اختيار الزبون', body: `<input class="pos-search" id="cq" placeholder="ابحث بالاسم أو الرقم أو الهاتف" autocomplete="off">
      <div id="cl" style="display:grid;gap:6px;max-height:55vh;overflow:auto;margin-top:10px"></div>`, foot: '<button class="btn" data-cash>زبون نقدي</button><button class="btn" data-close>إلغاء</button>' });
    const draw = () => { const q2 = m.el.querySelector('#cq').value.trim().toLowerCase();
      m.el.querySelector('#cl').innerHTML = parties.filter(x => !q2 || [x.name, x.code, x.mobile, x.phone].some(y => (y || '').toLowerCase().includes(q2))).slice(0, 80)
        .map(x => `<button class="btn" data-pid="${x.id}" style="justify-content:space-between;text-align:start;min-height:46px"><span><b>${esc(x.name)}</b> <span class="muted">${esc(x.code)}</span></span><span dir="ltr" class="muted">${esc(x.mobile || x.phone || '')}</span></button>`).join('')
        || '<div class="empty">ما في زبائن بهالاسم</div>'; };
    draw(); m.el.querySelector('#cq').oninput = draw; m.el.querySelector('#cq').focus();
    m.el.querySelector('#cl').onclick = (e) => { const b = e.target.closest('[data-pid]'); if (!b) return; cust = parties.find(x => x.id === b.dataset.pid); m.close(); drawCart(); };
    m.el.querySelector('[data-cash]').onclick = () => { cust = null; m.close(); drawCart(); };
  }
  function repDialog() {
    const m = modal({ title: '🧑‍💼 مندوب المبيعات', body: `<div class="pos-repgrid">${reps.map(x => `<button data-rid="${x.id}" class="${x.id === rep?.id ? 'on' : ''}">${esc(x.name)}</button>`).join('')}</div>`,
      foot: '<button class="btn" data-none>بدون مندوب</button><button class="btn" data-close>إلغاء</button>' });
    m.el.querySelector('.pos-repgrid').onclick = (e) => { const b = e.target.closest('[data-rid]'); if (!b) return; rep = reps.find(x => x.id === b.dataset.rid); localStorageSet(repKey, rep.id); m.close(); drawCart(); };
    m.el.querySelector('[data-none]').onclick = () => { rep = null; localStorageSet(repKey, null); m.close(); drawCart(); };
  }
  function discDialog() {
    if (!cart.length) return toast('السلة فاضية', 'err');
    const G = cart.reduce((a, l) => a + r3(l.qty * l.price - (l.discount || 0)), 0);
    const m = modal({ title: '٪ خصم على الفاتورة', size: 'sm', body: `<div class="grid cols-2">
      <div class="field"><label>مبلغ</label><input id="da" inputmode="decimal" dir="ltr" value="${invDisc || ''}"></div>
      <div class="field"><label>أو نسبة %</label><input id="dp" inputmode="decimal" dir="ltr"></div></div>
      <p class="muted" style="margin:0">مجموع الفاتورة قبل الخصم: ${fmtNum(G)}</p>`, foot: '<button class="btn primary" data-ok>تمام</button><button class="btn" data-zero>بدون خصم</button><button class="btn" data-close>إلغاء</button>' });
    m.el.querySelector('#dp').oninput = (e) => { m.el.querySelector('#da').value = r3(G * num(e.target.value) / 100) || ''; };
    m.el.querySelector('[data-ok]').onclick = () => { const a = num(m.el.querySelector('#da').value);
      if (a < 0 || a > G) return toast('الخصم أكبر من مجموع الفاتورة', 'err'); invDisc = a; m.close(); drawCart(); };
    m.el.querySelector('[data-zero]').onclick = () => { invDisc = 0; m.close(); drawCart(); };
  }
  $('#pos-cfg')?.addEventListener('click', () => posSettings(ctx));
  $('#pos-pay').onclick = () => payDialog();

  function payDialog() {
    const t = totals(cart, cfg, invDisc);
    const PAYS = cust && cfg.allow_credit !== false ? [...PAY, { id: '', method: 'credit', label: '📒 آجل', sub: 'على حساب الزبون', cash: false }] : PAY;
    let paid = ''; let pm = PAYS[0];
    const quick = [...new Set([Math.ceil(t.total), Math.ceil(t.total / 5) * 5, Math.ceil(t.total / 10) * 10, Math.ceil(t.total / 20) * 20, 50].filter(x => x >= t.total))].slice(0, 4);
    const m = modal({ title: '💵 الدفع', body: `
      <div class="pos-paybox">
        <div class="pp-total"><span>المطلوب</span><b>${fmtNum(t.total)}</b></div>
        <div class="pp-methods">${PAYS.map((x, k) => `<button class="${k ? '' : 'on'}" data-meth="${k}">${esc(x.label)}${x.sub ? `<small>${esc(x.sub)}</small>` : ''}</button>`).join('')}</div>
        ${methods.length ? '' : '<div class="muted" style="font-size:12px">لتعريف كبسات الدفع (كاش، فيزا، كليك…): «إعداد ← وسائل الدفع» وأشّر «نقطة البيع».</div>'}
        <div class="pp-in"><span>المدفوع</span><b id="pp-paid">${fmtNum(t.total)}</b></div>
        <div class="pp-quick">${[t.total, ...quick].map(x => `<button data-q="${x}">${fmtNum(x, x % 1 ? 3 : 0)}</button>`).join('')}</div>
        <div class="pp-keys">${['7','8','9','4','5','6','1','2','3','.','0','⌫'].map(k => `<button data-k="${k}">${k}</button>`).join('')}</div>
        <div class="pp-change"><span>الباقي للزبون</span><b id="pp-ch">0.000</b></div>
        ${cust ? `<div class="muted">👤 الزبون: <b>${esc(cust.name)}</b></div>` : '<input id="pp-name" class="pos-search" placeholder="اسم الزبون (اختياري)" style="margin-top:8px">'}
      </div>`, foot: '<button class="btn primary pos-save" data-save>✅ حفظ وطباعة</button><button class="btn" data-close>رجوع</button>' });
    const upd = () => { const p = paid === '' ? t.total : num(paid);
      m.el.querySelector('#pp-paid').textContent = fmtNum(p);
      const ch = r3(p - t.total); const el = m.el.querySelector('#pp-ch'); el.textContent = fmtNum(Math.max(ch, 0)); el.parentElement.classList.toggle('bad', ch < 0); };
    m.el.querySelector('.pos-paybox').onclick = (e) => {
      const b = e.target.closest('button'); if (!b) return;
      if (b.dataset.meth) { pm = PAYS[+b.dataset.meth]; m.el.querySelectorAll('[data-meth]').forEach(x => x.classList.toggle('on', x === b)); if (!pm.cash) paid = ''; }
      else if (b.dataset.q) paid = String(b.dataset.q);
      else if (b.dataset.k) { const k = b.dataset.k; paid = k === '⌫' ? paid.slice(0, -1) : paid + k; if (paid.split('.').length > 2) paid = paid.slice(0, -1); }
      upd();
    };
    upd();
    const saveBtn = m.el.querySelector('[data-save]');
    saveBtn.onclick = async () => {
      const p = paid === '' ? t.total : num(paid);
      if (pm.cash && p + 0.0005 < t.total) return toast('المدفوع أقل من المطلوب', 'err');
      saveBtn.disabled = true; saveBtn.textContent = '⏳ جاري الحفظ…';
      const lines = cart.map(l => ({ item_id: l.item.id, qty: l.qty, price: l.price, discount: l.discount || 0 }));
      const r = await sb.rpc('pos_checkout', { p: { company_id: S.company.id, fiscal_year_id: S.fy.id, ...(pm.id ? { method_id: pm.id } : { method: pm.method }), paid: pm.cash ? p : t.total, party_id: cust?.id || null, sales_rep_id: rep?.id || null, party_name: m.el.querySelector('#pp-name')?.value.trim() || '', discount: invDisc, lines } });
      if (r.error) { saveBtn.disabled = false; saveBtn.textContent = '✅ حفظ وطباعة'; return toast(arError(r.error), 'err'); }
      const sale = r.data; const change = r3(num(sale.paid) - num(sale.total)); const name = m.el.querySelector('#pp-name')?.value.trim() || cust?.name || '';
      const rec = { sale, paid: num(sale.paid), change, method: sale.method || pm.label, name };
      localStorageSet(lastKey, JSON.stringify(rec));
      cart = []; sel = -1; cust = null; invDisc = 0; drawCart(); m.close();
      if (Math.abs(num(sale.total) - t.total) > 0.0005) toast(`⚠️ انتبه: المجموع المحفوظ ${fmtNum(sale.total)} (تغيّر سعر صنف). الباقي الصحيح ${fmtNum(Math.max(change, 0))}`, 'err');
      else toast(`انحفظت الفاتورة ${sale.doc_code || sale.no}${change > 0 ? ' — الباقي ' + fmtNum(change) : ''}`, 'ok');
      if (cfg.auto_print) printReceipt({ ...rec, cfg });
    };
  }
}

// ---------------------------------------------------------------------
//  وصل الرول
// ---------------------------------------------------------------------
function receiptHTML({ sale, paid, change, method, cfg, name }) {
  const lines = sale.lines || [];
  const c = S.company, w = cfg.paper === '58' ? 58 : 80;
  const who = S.profile?.full_name || S.profile?.username || '';
  return `<!doctype html><html dir="rtl" lang="ar"><head><meta charset="utf-8"><title>وصل ${esc(sale.doc_code || sale.no)}</title>
  <style>@page{size:${w}mm auto;margin:0}*{box-sizing:border-box}body{margin:0;padding:3mm 3mm 6mm;width:${w}mm;font:12px/1.45 Tahoma,Arial,sans-serif;color:#000}
  .c{text-align:center}.b{font-weight:700}h1{font-size:15px;margin:2px 0}img{max-width:60%;max-height:22mm}
  table{width:100%;border-collapse:collapse;margin:4px 0}td{padding:2px 0;vertical-align:top}td.n{text-align:left;white-space:nowrap}
  .hr{border-top:1px dashed #000;margin:4px 0}.tot td{font-size:14px;font-weight:700}small{color:#333}</style></head><body>
  <div class="c">${c.logo_url ? `<img src="${esc(c.logo_url)}"><br>` : ''}<h1>${esc(c.name)}</h1>
  ${cfg.header ? `<div>${esc(cfg.header).replace(/\n/g, '<br>')}</div>` : ''}${cfg.branch?.name ? `<div>${esc(cfg.branch.name)}${cfg.branch.phone ? ' — ' + esc(cfg.branch.phone) : ''}</div>` : ''}${(cfg.branch?.sales_tax_no || c.sales_tax_no) ? `<div>رقم ضريبة المبيعات: ${esc(cfg.branch?.sales_tax_no || c.sales_tax_no)}</div>` : ''}</div>
  <div class="hr"></div>
  <div>فاتورة رقم: <b>${esc(sale.doc_code || sale.no)}</b></div><div>${fmtDateTime(sale.created_at || new Date())}</div>
  <div>الكاشير: ${esc(who)}${name ? ` · الزبون: ${esc(name)}` : ''}</div>
  <div class="hr"></div>
  <table>${lines.map(l => `<tr><td>${esc(l.name)}<br><small>${fmtQty(l.qty, l.qty % 1 ? 3 : 0)} × ${fmtPrice(l.price)}${num(l.discount) ? ` − ${fmtNum(l.discount)}` : ''}</small></td>
    <td class="n">${fmtNum(l.total)}</td></tr>`).join('')}</table>
  <div class="hr"></div>
  <table><tr><td>قبل الضريبة</td><td class="n">${fmtNum(sale.subtotal)}</td></tr><tr><td>ضريبة المبيعات</td><td class="n">${fmtNum(sale.tax)}</td></tr>
  <tr class="tot"><td>المجموع</td><td class="n">${fmtNum(sale.total)}</td></tr>
  <tr><td>المدفوع (${esc(method || '')})</td><td class="n">${fmtNum(paid)}</td></tr>
  ${change > 0 ? `<tr class="b"><td>الباقي</td><td class="n">${fmtNum(change)}</td></tr>` : ''}</table>
  <div class="hr"></div><div class="c">${esc(cfg.footer || '').replace(/\n/g, '<br>')}</div>
  </body></html>`;
}
export function printReceipt(o) {
  const html = receiptHTML(o);
  const ios = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  if (ios) {   // على الآيباد: نافذة فيها زر رجوع
    const w = window.open('', '_blank'); if (!w) return toast('اسمح بالنوافذ المنبثقة عشان يطبع الوصل', 'err');
    w.document.write(html.replace('<body>', `<body><div style="position:sticky;top:0;display:flex;gap:8px;padding:8px;background:#f3eefa" class="np"><button onclick="window.close();setTimeout(function(){history.back()},300)" style="flex:1;padding:12px;font-size:16px">→ رجوع للكاشير</button><button onclick="print()" style="flex:1;padding:12px;font-size:16px">🖨️ طباعة</button></div><style>@media print{.np{display:none!important}}</style>`)
      .replace('</body>', '<script>setTimeout(function(){print()},300)<\/script></body>'));
    w.document.close(); return;
  }
  // الكمبيوتر: طباعة من إطار مخفي بدون ما تفتح نافذة
  const f = document.createElement('iframe'); f.style.cssText = 'position:fixed;width:0;height:0;border:0;left:-9999px';
  document.body.appendChild(f);
  f.contentDocument.open(); f.contentDocument.write(html); f.contentDocument.close();
  setTimeout(() => {
    const n = Math.max(1, Math.min(3, parseInt(o.cfg.copies, 10) || 1));
    for (let i = 0; i < n; i++) f.contentWindow.print();
    setTimeout(() => f.remove(), 2000);
  }, 250);
}

// ---------------------------------------------------------------------
//  إعدادات نقطة البيع
// ---------------------------------------------------------------------
async function posSettings(ctx) {
  await loadPosCfg(true);   // (الكاش) — بس الشاشة بتعدّل إعداد الشركة العام، مش إعداد الفرع
  const cfg = { ...POS_DEF, ...(((await sb.from('company_settings').select('pos').eq('company_id', S.company.id).maybeSingle()).data?.pos) || {}) };
  const [accs, whs] = await Promise.all([loadAccounts(), loadWarehouses()]);
  const cash = leafAccounts(accs).filter(a => ['cash', 'bank'].includes(a.account_type));
  const accOpts = (sel) => `<option value="">— الافتراضي من حسابات الربط —</option>` + cash.map(a => `<option value="${a.id}" ${a.id === sel ? 'selected' : ''}>${esc(accLabel(a))}</option>`).join('');
  const m = modal({ title: '⚙️ إعدادات نقطة البيع', body: `<form id="pc" class="grid cols-2">
    <div class="field"><label>المستودع اللي بيطلع منه البيع</label><select name="warehouse_id"><option value="">— الافتراضي —</option>${(whs || []).filter(w => w.is_active !== false).map(w => `<option value="${w.id}" ${w.id === cfg.warehouse_id ? 'selected' : ''}>${esc(w.name)}</option>`).join('')}</select></div>
    <div class="field"><label>صندوق الكاش</label><select name="cash_account_id">${accOpts(cfg.cash_account_id)}</select></div>
    <div class="field"><label>حساب البطاقات (البنك)</label><select name="card_account_id">${accOpts(cfg.card_account_id)}</select></div>
    <div class="field"><label>عرض الورق</label><select name="paper"><option value="80" ${cfg.paper !== '58' ? 'selected' : ''}>رول 80 ملم</option><option value="58" ${cfg.paper === '58' ? 'selected' : ''}>رول 58 ملم</option></select></div>
    <div class="field"><label>رأس الوصل (عنوان، هاتف…)</label><textarea name="header" rows="2">${esc(cfg.header)}</textarea></div>
    <div class="field"><label>ذيل الوصل</label><textarea name="footer" rows="2">${esc(cfg.footer)}</textarea></div>
    <div class="field"><label>عدد النسخ</label><select name="copies">${[1, 2].map(n => `<option ${+cfg.copies === n ? 'selected' : ''}>${n}</option>`).join('')}</select></div>
    <div class="field"><label class="check"><input type="checkbox" name="prices_include_tax" ${cfg.prices_include_tax ? 'checked' : ''}> أسعار الأصناف شاملة الضريبة</label>
      <label class="check"><input type="checkbox" name="auto_print" ${cfg.auto_print ? 'checked' : ''}> اطبع الوصل لحاله بعد الحفظ</label>
      <label class="check"><input type="checkbox" name="allow_credit" ${cfg.allow_credit !== false ? 'checked' : ''}> البيع الآجل على حساب الزبون</label></div>
    </form>
    <div class="notice info" style="font-size:13px;line-height:1.8"><b>فتح درج الكاش:</b> الدرج بيكون موصول بطابعة الرول. من إعدادات الطابعة بالويندوز (خصائص الطابعة ← إعدادات الجهاز أو «Cash Drawer») فعّل «فتح الدرج قبل/بعد الطباعة»، فبيفتح مع كل وصل.<br>
    <b>طباعة بدون نافذة:</b> اعمل اختصار لكروم على جهاز الكاشير وضيف آخره <span dir="ltr">--kiosk-printing</span>، فبيطبع الوصل دغري على الطابعة الافتراضية.</div>`,
    foot: '<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>' });
  m.el.querySelector('[data-save]').onclick = async () => {
    const d = formData(m.el.querySelector('#pc'));
    const pos = { warehouse_id: d.warehouse_id || '', cash_account_id: d.cash_account_id || '', card_account_id: d.card_account_id || '', paper: d.paper,
      header: d.header || '', footer: d.footer || '', copies: +d.copies || 1, prices_include_tax: !!d.prices_include_tax, auto_print: !!d.auto_print, allow_credit: !!d.allow_credit };
    await sb.rpc('ensure_company_settings', { p_company: S.company.id }).then(() => {}, () => {});
    const { error } = await sb.from('company_settings').update({ pos }).eq('company_id', S.company.id);
    if (error) return toast(arError(error), 'err');
    cfgCache = null; toast('انحفظت الإعدادات', 'ok'); m.close(); ctx.rerender();
  };
}

export const POS_ROUTES = { pos: viewPos };
