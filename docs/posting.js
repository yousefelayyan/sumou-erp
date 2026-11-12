// =====================================================================
//  السمو ERP — الترحيل: كبسات «ترحيل للمحاسبة» و«ترحيل للمخزون» بكل سند،
//  وشاشة «الأدوات ← الترحيل» (الإعدادات + ترحيل وإلغاء ترحيل دفعة واحدة)
// =====================================================================
import { S, sb, esc, toast, arError, can, log, fmtDate, fmtNum, num } from './core.js';
import { docNo } from './numbering.js';

// أنواع السندات: gl = بيترحّل للمحاسبة، stock = بيترحّل للمخزون (إذا النوع بيسمح)
export const POST_KINDS = [
  { key: 'journal',         label: 'سندات القيد',        group: 'المالية',   fam: 'entry',   screen: 'journal_entries',  gl: true,  stock: false },
  { key: 'receipt',         label: 'سندات القبض',        group: 'المالية',   fam: 'entry',   screen: 'receipt_vouchers', gl: true,  stock: false },
  { key: 'payment',         label: 'سندات الصرف',        group: 'المالية',   fam: 'entry',   screen: 'payment_vouchers', gl: true,  stock: false },
  { key: 'sale',            label: 'فواتير المبيعات',    group: 'المبيعات',  fam: 'invoice', screen: 'sales_invoices',   gl: true,  stock: true },
  { key: 'sale_return',     label: 'مردودات المبيعات',   group: 'المبيعات',  fam: 'invoice', screen: 'sales_invoices',   gl: true,  stock: true },
  { key: 'purchase',        label: 'فواتير المشتريات',   group: 'المشتريات', fam: 'invoice', screen: 'purchase_invoices', gl: true, stock: true },
  { key: 'purchase_return', label: 'مردودات المشتريات',  group: 'المشتريات', fam: 'invoice', screen: 'purchase_invoices', gl: true, stock: true },
  { key: 'stock_in',        label: 'سندات الإدخال',      group: 'المخزون',   fam: 'stock',   screen: 'inventory',        gl: true,  stock: true },
  { key: 'stock_out',       label: 'سندات الإخراج',      group: 'المخزون',   fam: 'stock',   screen: 'inventory',        gl: true,  stock: true },
  { key: 'stock_transfer',  label: 'سندات التحويل',      group: 'المخزون',   fam: 'stock',   screen: 'inventory',        gl: false, stock: true },
  { key: 'stock_count',     label: 'الجرد والتسوية',     group: 'المخزون',   fam: 'stock',   screen: 'inventory',        gl: true,  stock: true },
];
const KIND = Object.fromEntries(POST_KINDS.map(k => [k.key, k]));

let cache = null, cacheCo = null;
export async function loadPosting(force = false) {
  if (!S.company) return { posting: {}, perpetual: false };
  if (!force && cache && cacheCo === S.company.id) return cache;
  const { data } = await sb.from('company_settings').select('posting,perpetual_inventory').eq('company_id', S.company.id).maybeSingle();
  cache = { posting: data?.posting || {}, perpetual: !!data?.perpetual_inventory }; cacheCo = S.company.id; return cache;
}
// هل النوع بيترحّل للمحاسبة/للمخزون؟ (سندات المخزون بتترحّل للمحاسبة بس مع الجرد المستمر)
export function postFlag(kind, what) {
  const K = KIND[kind]; if (!K || !K[what]) return false;
  if (what === 'gl' && K.fam === 'stock' && !cache?.perpetual) return false;
  const v = cache?.posting?.[kind]?.[what];
  return typeof v === 'boolean' ? v : true;
}

// شريط الترحيل أعلى السند. items: [{ key:'gl'|'stock', posted, canPost, canUnpost, note }]
export function postBarHTML(items) {
  const shown = items.filter(Boolean);
  if (!shown.length) return '';
  const L = { gl: ['📘', 'المحاسبة'], stock: ['📦', 'المخزون'] };
  return `<div class="post-bar">${shown.map(it => `<div class="post-item ${it.posted ? 'done' : ''}">
      <span class="pi-ico">${L[it.key][0]}</span><span>${L[it.key][1]}: <b>${it.posted ? 'مرحّل ✓' : 'مش مرحّل'}</b></span>
      ${!it.posted && it.canPost ? `<button type="button" class="btn sm primary" data-postdo="${it.key}">ترحيل ${it.key === 'gl' ? 'للمحاسبة' : 'للمخزون'}</button>` : ''}
      ${it.posted && it.canUnpost ? `<button type="button" class="btn sm" data-unpostdo="${it.key}">↩️ إلغاء الترحيل</button>` : ''}
      ${it.note ? `<span class="muted" style="font-size:12px">${esc(it.note)}</span>` : ''}</div>`).join('')}</div>`;
}

// تنفيذ الترحيل/الإلغاء لسند واحد
export async function doPost(fam, id, what, undo = false) {
  let r;
  if (fam === 'entry') r = undo ? await sb.rpc('unpost_entry', { p_id: id }) : await sb.rpc('post_entry', { p_id: id });
  else if (fam === 'invoice') r = undo ? await sb.rpc('unpost_invoice', { p_id: id, p_what: what })
    : what === 'gl' ? await sb.rpc('post_invoice', { p_id: id }) : await sb.rpc('post_invoice_stock', { p_id: id });
  else r = undo ? await sb.rpc('unpost_stock_doc', { p_id: id, p_what: what })
    : what === 'gl' ? await sb.rpc('post_stock_doc_gl', { p_id: id }) : await sb.rpc('post_stock_doc', { p_id: id });
  if (r.error) throw r.error;
}

// ربط كبسات الشريط. after() بتنعمل بعد النجاح (مثلاً إعادة فتح السند)
export function wirePostBar(root, fam, id, after) {
  root.querySelectorAll('[data-postdo],[data-unpostdo]').forEach(b => b.addEventListener('click', async () => {
    const undo = !!b.dataset.unpostdo, what = b.dataset.postdo || b.dataset.unpostdo;
    if (undo && !confirm(`متأكد بدك تلغي ترحيل ${what === 'gl' ? 'المحاسبة' : 'المخزون'}؟ السند بيرجع مسودة وبينمسح ${what === 'gl' ? 'قيده' : 'أثره على المخزون'}.${what === 'stock' ? '\nانتبه: إذا في حركات أحدث على نفس الأصناف، متوسط الكلفة إلها ما بيتغيّر لحاله.' : ''}`)) return;
    b.disabled = true;
    try { await doPost(fam, id, what, undo); toast(undo ? 'انلغى الترحيل' : `انرحّل ${what === 'gl' ? 'للمحاسبة' : 'للمخزون'}`, 'ok'); after?.(); }
    catch (e) { toast(arError(e), 'err'); b.disabled = false; }
  }));
}

// ---------------------------------------------------------------------
//  شاشة الأدوات ← الترحيل
// ---------------------------------------------------------------------
async function viewPosting(v) {
  if (!S.company || !S.fy) return void (v.innerHTML = `<div class="notice info">اختار شركة وسنة مالية من فوق أول.</div>`);
  const P = await loadPosting(true);
  const posting = JSON.parse(JSON.stringify(P.posting || {}));
  const canSet = can('companies', 'edit');
  const groups = [...new Set(POST_KINDS.map(k => k.group))];
  v.innerHTML = `<div class="page-head"><h2>📮 الترحيل</h2><div class="spacer"></div></div>
    <div class="tabs"><div class="tab active" data-tab="run">ترحيل وإلغاء ترحيل</div><div class="tab" data-tab="set">إعدادات الترحيل</div></div>
    <div class="tab-panel active" data-tab="run">
      <div class="grid" style="grid-template-columns:240px 1fr;gap:16px;align-items:start">
        <div class="card" style="padding:8px" id="pk">${groups.map(g => `<div class="kgrp open" data-grp="${esc(g)}">
          <div class="kgrp-title" style="cursor:default"><label class="check" style="margin:0"><input type="checkbox" data-g="${esc(g)}"> <b>${g}</b></label>
            <button type="button" class="btn sm" data-toggle="${esc(g)}" style="margin-inline-start:auto;padding:0 8px">›</button></div>
          <div class="kgrp-items">${POST_KINDS.filter(k => k.group === g).map(k => `<label class="check" style="margin:4px 14px"><input type="checkbox" data-kind="${k.key}"> ${k.label}</label>`).join('')}</div></div>`).join('')}</div>
        <div>
          <div class="card">
            <div class="grid cols-3">
              <div class="field"><label>الفترة</label><select id="per"><option value="fy">السنة المالية الحالية</option><option value="custom">فترة محددة</option></select></div>
              <div class="field"><label>من</label><input type="date" id="from" value="${S.fy.start_date}" disabled></div>
              <div class="field"><label>إلى</label><input type="date" id="to" value="${S.fy.end_date}" disabled></div>
            </div>
            <hr><b style="font-size:14px">الترحيل</b>
            <label class="check"><input type="radio" name="what" value="gl" checked> للمالية (المحاسبة)</label>
            <label class="check"><input type="radio" name="what" value="stock"> للمخزون</label>
            <label class="check" style="margin-top:6px"><input type="checkbox" id="only" checked> فقط الحركات غير المرحّلة</label>
            <button class="btn" id="load" type="button" style="margin-top:10px">📋 قائمة السندات</button>
          </div>
          <div class="card table-wrap"><table class="t"><thead><tr><th style="width:36px"><input type="checkbox" id="all"></th><th>النوع</th><th>الرقم</th><th>التاريخ</th><th>البيان</th><th style="text-align:left">المبلغ</th><th>الحالة</th></tr></thead>
            <tbody id="rows"><tr><td colspan="7" class="empty">علّم أنواع السندات وكبّس «قائمة السندات»</td></tr></tbody></table></div>
          <div style="display:flex;gap:10px;align-items:center;margin-top:10px;flex-wrap:wrap">
            <button class="btn primary" id="go-post" type="button">✅ ترحيل</button>
            <button class="btn danger" id="go-unpost" type="button">↩️ إلغاء الترحيل</button>
            <button class="btn" id="stop" type="button" disabled>⏹️ إيقاف</button>
            <span class="muted" id="msg"></span></div>
        </div>
      </div>
    </div>
    <div class="tab-panel" data-tab="set">
      <p class="muted">لكل نوع سند: هل بيترحّل للمحاسبة (بيعمل قيد)؟ وهل بيترحّل للمخزون (بيحرّك الكميات)؟ الحفظ بأي سند بيخزّن بس، والترحيل بالكبسات اللي فوق السند أو من هون دفعة وحدة.
        ${P.perpetual ? '' : '<br>سندات المخزون بتترحّل للمحاسبة بس لما يكون «الجرد المستمر» مفعّل من «حسابات الربط».'}</p>
      <div class="card table-wrap"><table class="t"><thead><tr><th>نوع السند</th><th style="text-align:center">📘 ترحيل للمحاسبة</th><th style="text-align:center">📦 ترحيل للمخزون</th></tr></thead><tbody>
      ${groups.map(g => `<tr><td colspan="3" class="muted" style="font-weight:700">${g}</td></tr>` + POST_KINDS.filter(k => k.group === g).map(k => `<tr><td>${k.label}</td>
        ${['gl', 'stock'].map(w => `<td style="text-align:center">${k[w] ? `<input type="checkbox" data-k="${k.key}" data-w="${w}" ${(typeof posting[k.key]?.[w] === 'boolean' ? posting[k.key][w] : true) ? 'checked' : ''} ${canSet ? '' : 'disabled'}>` : '<span class="muted">—</span>'}</td>`).join('')}</tr>`).join('')).join('')}
      </tbody></table></div>
      ${canSet ? '<button class="btn primary" id="save-set" style="margin-top:12px">💾 حفظ الإعدادات</button>' : ''}
    </div>`;
  const $ = (q) => v.querySelector(q);
  v.querySelector('.tabs').addEventListener('click', (e) => {
    const t = e.target.closest('.tab'); if (!t) return;
    v.querySelectorAll('.tab').forEach(x => x.classList.toggle('active', x === t));
    v.querySelectorAll('.tab-panel').forEach(x => x.classList.toggle('active', x.dataset.tab === t.dataset.tab));
  });
  $('#save-set')?.addEventListener('click', async () => {
    v.querySelectorAll('[data-tab=set] input[type=checkbox]').forEach(c => { (posting[c.dataset.k] ||= {})[c.dataset.w] = c.checked; });
    await sb.rpc('ensure_company_settings', { p_company: S.company.id });
    const { error } = await sb.from('company_settings').update({ posting }).eq('company_id', S.company.id);
    if (error) return toast(arError(error), 'err');
    cache = null; await log('تعديل', 'posting', S.company.id); toast('انحفظت إعدادات الترحيل', 'ok');
  });
  // أنواع السندات: علامة المجموعة بتعلّم كل اللي تحتها، والسهم بيطوي المجموعة
  $('#pk').addEventListener('click', (e) => { const t = e.target.closest('[data-toggle]'); if (t) t.closest('.kgrp').classList.toggle('open'); });
  $('#pk').addEventListener('change', (e) => {
    const g = e.target.dataset.g;
    if (g) v.querySelectorAll(`.kgrp[data-grp="${CSS.escape(g)}"] [data-kind]`).forEach(c => c.checked = e.target.checked);
    else { const box = e.target.closest('.kgrp'); const all = [...box.querySelectorAll('[data-kind]')]; box.querySelector('[data-g]').checked = all.every(c => c.checked); }
  });
  $('#per').onchange = () => { const c = $('#per').value === 'custom'; $('#from').disabled = $('#to').disabled = !c; if (!c) { $('#from').value = S.fy.start_date; $('#to').value = S.fy.end_date; } };

  let list = [], stop = false;
  const what = () => v.querySelector('[name=what]:checked').value;
  const isPosted = (K, r, w) => K.fam === 'entry' ? r.status !== 'draft' : K.fam === 'invoice' ? (w === 'gl' ? r.status === 'posted' : !!r.stock_posted)
    : (w === 'gl' ? !!r.entry_id : r.status === 'posted');
  $('#load').onclick = async () => {
    const kinds = [...v.querySelectorAll('[data-kind]:checked')].map(c => KIND[c.dataset.kind]);
    if (!kinds.length) return toast('علّم نوع سند واحد على الأقل', 'err');
    const w = what(), only = $('#only').checked, from = $('#from').value, to = $('#to').value;
    list = []; const skipped = [];
    for (const K of kinds) {
      if (!K[w] || (w === 'gl' && K.fam === 'stock' && !P.perpetual)) { skipped.push(K.label); continue; }
      let q;
      if (K.fam === 'entry') {
        q = sb.from('journal_entries').select('id,entry_no,doc_code,entry_date,description,total,status,reversal_of,reversed_by').eq('company_id', S.company.id).eq('fiscal_year_id', S.fy.id)
          .eq('entry_type', K.key).gte('entry_date', from).lte('entry_date', to).order('entry_date');
        if (only) q = q.eq('status', 'draft');
      } else if (K.fam === 'invoice') {
        q = sb.from('invoices').select('id,inv_no,doc_code,inv_date,party_name,reference,total,status,stock_posted').eq('company_id', S.company.id).eq('fiscal_year_id', S.fy.id)
          .eq('inv_type', K.key).gte('inv_date', from).lte('inv_date', to).neq('status', 'cancelled').order('inv_date');
        if (only) q = w === 'gl' ? q.eq('status', 'draft') : q.eq('stock_posted', false);
      } else {
        q = sb.from('stock_docs').select('id,doc_no,doc_code,doc_date,notes,status,entry_id').eq('company_id', S.company.id)
          .eq('doc_type', K.key.replace('stock_', '')).gte('doc_date', from).lte('doc_date', to).order('doc_date');
        if (only) q = w === 'gl' ? q.eq('status', 'posted').is('entry_id', null) : q.eq('status', 'draft');
      }
      const { data, error } = await q.limit(3000);
      if (error) return toast(arError(error), 'err');
      list.push(...(data || []).map(r => ({ ...r, K, posted: isPosted(K, r, w) })));
    }
    // بالتاريخ، وبنفس اليوم الداخل للمخزون قبل الطالع (عشان متوسط الكلفة ينحسب صح)
    const inFirst = (r) => ['purchase', 'sale_return', 'stock_in'].includes(r.K.key) ? 0 : r.K.key === 'stock_count' ? 1 : 2;
    list.sort((a, b) => String(a.entry_date || a.inv_date || a.doc_date).localeCompare(String(b.entry_date || b.inv_date || b.doc_date)) || inFirst(a) - inFirst(b));
    $('#rows').innerHTML = list.map((r, i) => `<tr><td><input type="checkbox" data-i="${i}" checked></td><td>${r.K.label}</td><td><b dir="ltr">${esc(docNo(r))}</b></td>
      <td>${fmtDate(r.entry_date || r.inv_date || r.doc_date)}</td><td>${esc(r.description || r.party_name || r.reference || r.notes || '')}</td>
      <td dir="ltr" style="text-align:left">${r.total != null ? fmtNum(num(r.total)) : ''}</td>
      <td>${r.posted ? '<span class="badge ok">مرحّل</span>' : '<span class="badge">مش مرحّل</span>'}</td></tr>`).join('') || '<tr><td colspan="7" class="empty">ما في سندات</td></tr>';
    $('#all').checked = !!list.length;
    $('#msg').textContent = `${list.length} سند` + (skipped.length ? ` — ما بيترحّل ${w === 'gl' ? 'للمالية' : 'للمخزون'}: ${skipped.join('، ')}` : '');
  };
  $('#all').onchange = () => $('#rows').querySelectorAll('[data-i]').forEach(c => c.checked = $('#all').checked);
  const run = async (undo) => {
    const w = what();
    const sel = [...$('#rows').querySelectorAll('[data-i]:checked')].map(c => list[+c.dataset.i]).filter(r => undo ? r.posted : !r.posted);
    if (undo) sel.reverse();   // الإلغاء من الأحدث للأقدم
    if (!sel.length) return toast(undo ? 'ما في سندات مرحّلة محددة' : 'ما في سندات غير مرحّلة محددة', 'err');
    if (undo && !confirm(`إلغاء ترحيل ${sel.length} سند ${w === 'gl' ? 'من المحاسبة' : 'من المخزون'}؟ رح يرجعوا مسودات.`)) return;
    stop = false; $('#stop').disabled = false; $('#go-post').disabled = $('#go-unpost').disabled = true;
    let ok = 0; const bad = [];
    for (const [n, r] of sel.entries()) {
      if (stop) break;
      $('#msg').textContent = `جاري… ${n + 1} من ${sel.length}`;
      try { await doPost(r.K.fam, r.id, w, undo); ok++; }
      catch (e) { bad.push(`${r.K.label} ${docNo(r)}: ${arError(e)}`); }
    }
    $('#stop').disabled = true; $('#go-post').disabled = $('#go-unpost').disabled = false;
    await $('#load').onclick();
    $('#msg').innerHTML = `${stop ? 'انوقف. ' : ''}تم: <b>${ok}</b>${bad.length ? ` — ما زبط: <b>${bad.length}</b>` : ''}`;
    if (bad.length) toast(bad.slice(0, 3).join(' | '), 'err'); else if (ok) toast(undo ? 'انلغى الترحيل' : 'انرحّلت السندات', 'ok');
  };
  $('#go-post').onclick = () => run(false);
  $('#go-unpost').onclick = () => run(true);
  $('#stop').onclick = () => { stop = true; $('#stop').disabled = true; };
}

export const POSTING_ROUTES = { posting: viewPosting };
