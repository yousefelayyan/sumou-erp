// =====================================================================
//  السمو ERP — وثائق العملاء والموردين (route party-docs?t=report|docs|types&party=…)
//  أنواع الوثائق (إلزامية، تصرّف عند النقص/الانتهاء)، وثائق كل طرف مع مرفقات، وتقرير المنتهية والقريبة.
// =====================================================================
import { S, sb, esc, fmtDate, toast, arError, modal, confirmBox, formData, can, today } from './core.js';
import { loadParties, partyLabel, partyDatalist, resolveParty } from './parties.js';
import { openAttachments } from './attach.js';
import { printDoc } from './print.js';

const qp = () => new URLSearchParams(location.hash.split('?')[1] || '');
const MODE = { none: 'تنبيه بالتقرير بس', warn: 'تنبيه بالفاتورة', block: 'منع ترحيل الفاتورة' };
const APPLY = { customer: 'العملاء', supplier: 'الموردين', both: 'الكل' };
const PROB = { missing: ['ناقصة', 'bad'], expired: ['منتهية', 'bad'], expiring: ['قرّبت تنتهي', 'warn'] };
const daysLeft = (d) => d ? Math.round((new Date(d) - new Date(today())) / 864e5) : null;

async function viewPartyDocs(v, ctx) {
  if (!S.company) return void (v.innerHTML = '<div class="notice info">اختار شركة من فوق أول.</div>');
  const t = qp().get('t') || 'report';
  const edT = can('customers', 'edit') || can('suppliers', 'edit');
  const { data: types = [] } = await sb.from('party_doc_types').select('*').eq('company_id', S.company.id).order('code');
  const head = `<div class="page-head"><h2>📄 وثائق العملاء والموردين</h2></div>
    <div class="tabs" style="margin-bottom:10px">${[['report', '⏰ المنتهية والقريبة'], ['docs', '🗂️ وثائق طرف'], ['types', '⚙️ أنواع الوثائق']]
      .map(([k, l]) => `<a class="tab ${t === k ? 'active' : ''}" href="#/party-docs?t=${k}">${l}</a>`).join('')}</div>`;

  if (t === 'types') {
    v.innerHTML = `${head}<div class="page-head"><div class="spacer"></div>${edT ? '<button class="btn primary" id="add">➕ نوع وثيقة</button>' : ''}</div>
      <div class="card table-wrap"><table class="t"><thead><tr><th>الرمز</th><th>الوثيقة</th><th>لمين</th><th>إلزامية</th><th>إذا ناقصة أو منتهية</th><th>التنبيه قبل</th><th>فعّال</th></tr></thead><tbody>
      ${(types || []).map(x => `<tr data-t="${x.id}" ${edT ? 'style="cursor:pointer"' : ''}><td>${esc(x.code)}</td><td>${esc(x.name)}</td><td>${APPLY[x.applies_to]}</td><td>${x.required ? '✓' : ''}</td>
        <td>${x.on_missing === 'block' ? '<span class="badge bad">' + MODE.block + '</span>' : MODE[x.on_missing]}</td><td class="n">${x.warn_days} يوم</td><td>${x.is_active ? '✓' : '—'}</td></tr>`).join('')
        || '<tr><td colspan="7" class="empty">ما في أنواع. مثلاً: سجل تجاري، رخصة مهن، شهادة تسجيل ضريبي، هوية المفوّض بالتوقيع.</td></tr>'}</tbody></table></div>`;
    const form = (x) => {
      x = x || { code: String((types || []).length + 1).padStart(2, '0'), name: '', applies_to: 'customer', required: false, on_missing: 'warn', warn_days: 30, is_active: true };
      const m = modal({ title: x.id ? 'تعديل نوع وثيقة' : 'نوع وثيقة جديد', body: `<form id="tf"><div class="grid cols-2">
        <div class="field"><label>الرمز</label><input name="code" value="${esc(x.code)}"></div><div class="field"><label>اسم الوثيقة</label><input name="name" value="${esc(x.name)}"></div>
        <div class="field"><label>لمين</label><select name="applies_to">${Object.entries(APPLY).map(([k, l]) => `<option value="${k}" ${k === x.applies_to ? 'selected' : ''}>${l}</option>`).join('')}</select></div>
        <div class="field"><label>إذا ناقصة أو منتهية</label><select name="on_missing">${Object.entries(MODE).map(([k, l]) => `<option value="${k}" ${k === x.on_missing ? 'selected' : ''}>${l}</option>`).join('')}</select></div>
        <div class="field"><label>نبّهني قبل الانتهاء بـ (يوم)</label><input type="number" name="warn_days" min="0" max="365" value="${x.warn_days}"></div><div></div>
        <label class="check"><input type="checkbox" name="required" ${x.required ? 'checked' : ''}> إلزامية (الطرف بدونها بينحسب ناقص)</label><label class="check"><input type="checkbox" name="is_active" ${x.is_active ? 'checked' : ''}> فعّال</label></div></form>`,
        foot: '<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>' });
      m.el.querySelector('[data-save]').onclick = async () => {
        const d = formData(m.el.querySelector('#tf')); if (!d.code || !d.name) return toast('الرمز والاسم مطلوبين', 'err');
        const row = { code: d.code, name: d.name, applies_to: d.applies_to, on_missing: d.on_missing, warn_days: +d.warn_days || 0, required: !!d.required, is_active: !!d.is_active };
        const q = x.id ? sb.from('party_doc_types').update(row).eq('id', x.id) : sb.from('party_doc_types').insert({ ...row, company_id: S.company.id });
        const { error } = await q; if (error) return toast(arError(error), 'err'); toast('انحفظ', 'ok'); m.close(); ctx.rerender();
      };
    };
    v.querySelector('#add')?.addEventListener('click', () => form(null));
    if (edT) v.querySelectorAll('[data-t]').forEach(tr => tr.onclick = () => form(types.find(x => x.id === tr.dataset.t)));
    return;
  }

  if (t === 'docs') {
    const parties = (await loadParties()).filter(p => p.party_type !== 'expense');
    const pid = qp().get('party'), p = parties.find(x => x.id === pid);
    v.innerHTML = `${head}<div class="card" style="display:flex;gap:10px;align-items:end;flex-wrap:wrap;margin-bottom:10px">
      <div class="field" style="flex:1;min-width:260px"><label>العميل / المورد</label><input list="pd-parties" id="pp" value="${esc(partyLabel(p))}" placeholder="رقم أو اسم…">${partyDatalist(parties, 'pd-parties')}</div>
      ${p && can(p.party_type === 'supplier' ? 'suppliers' : 'customers', 'edit') && (types || []).some(x => x.is_active) ? '<button class="btn primary" id="add">➕ وثيقة</button>' : ''}</div><div id="pd-body"></div>`;
    v.querySelector('#pp').onchange = (e) => { const x = resolveParty(parties, e.target.value); if (x) location.hash = `#/party-docs?t=docs&party=${x.id}`; };
    if (!p) return void (v.querySelector('#pd-body').innerHTML = '<div class="notice info">اختار عميل أو مورد.</div>');
    const ed = can(p.party_type === 'supplier' ? 'suppliers' : 'customers', 'edit');
    const [{ data: docs = [] }, { data: issues = [] }] = await Promise.all([
      sb.from('party_documents').select('*').eq('party_id', p.id).order('expiry_date', { ascending: false }),
      sb.rpc('party_doc_issues', { p_company: S.company.id, p_party: p.id, p_date: null })]);
    const tBy = Object.fromEntries((types || []).map(x => [x.id, x]));
    v.querySelector('#pd-body').innerHTML = `${(issues || []).length ? `<div class="notice" style="margin-bottom:10px">${(issues || []).map(i => `<b>${esc(i.type_name)}</b>: ${PROB[i.problem][0]}${i.expiry_date ? ' (' + fmtDate(i.expiry_date) + ')' : ''}`).join(' · ')}</div>` : ''}
      <div class="card table-wrap"><table class="t"><thead><tr><th>الوثيقة</th><th>الرقم</th><th>الإصدار</th><th>الانتهاء</th><th>المتبقي</th><th>ملاحظات</th><th></th></tr></thead><tbody>
      ${(docs || []).map(d => { const dl = daysLeft(d.expiry_date); return `<tr><td>${esc(tBy[d.type_id]?.name || '')}</td><td dir="ltr">${esc(d.doc_no || '')}</td><td>${fmtDate(d.issue_date)}</td><td>${fmtDate(d.expiry_date)}</td>
        <td>${dl == null ? '—' : dl < 0 ? `<span class="badge bad">منتهية من ${-dl} يوم</span>` : dl <= (tBy[d.type_id]?.warn_days ?? 30) ? `<span class="badge warn">${dl} يوم</span>` : `<span class="badge ok">${dl} يوم</span>`}</td>
        <td>${esc(d.notes || '')}</td><td class="actions"><button class="btn sm" data-att="${d.id}">📎</button>${ed ? ` <button class="btn sm" data-ed="${d.id}">تعديل</button> <button class="btn sm danger" data-del="${d.id}">حذف</button>` : ''}</td></tr>`; }).join('')
        || '<tr><td colspan="7" class="empty">ما في وثائق لهالطرف</td></tr>'}</tbody></table></div>`;
    const form = (d) => {
      d = d || { type_id: (types || []).find(x => x.is_active)?.id, doc_no: '', issue_date: '', expiry_date: '', notes: '' };
      const m = modal({ title: d.id ? 'تعديل وثيقة' : `وثيقة جديدة — ${p.name}`, body: `<form id="df"><div class="grid cols-2">
        <div class="field"><label>نوع الوثيقة</label><select name="type_id">${(types || []).filter(x => x.is_active || x.id === d.type_id).map(x => `<option value="${x.id}" ${x.id === d.type_id ? 'selected' : ''}>${esc(x.name)}</option>`).join('')}</select></div>
        <div class="field"><label>رقم الوثيقة</label><input name="doc_no" value="${esc(d.doc_no || '')}" dir="auto"></div>
        <div class="field"><label>تاريخ الإصدار</label><input type="date" name="issue_date" value="${d.issue_date || ''}"></div>
        <div class="field"><label>تاريخ الانتهاء</label><input type="date" name="expiry_date" value="${d.expiry_date || ''}"></div>
        <div class="field" style="grid-column:span 2"><label>ملاحظات</label><input name="notes" value="${esc(d.notes || '')}"></div></div></form>
        <p class="muted" style="font-size:12px">بعد الحفظ بتقدر ترفق صورة الوثيقة من زر 📎.</p>`,
        foot: '<button class="btn primary" data-save>💾 حفظ</button><button class="btn" data-close>إلغاء</button>' });
      m.el.querySelector('[data-save]').onclick = async () => {
        const f = formData(m.el.querySelector('#df'));
        const row = { type_id: f.type_id, doc_no: f.doc_no || null, issue_date: f.issue_date || null, expiry_date: f.expiry_date || null, notes: f.notes || null };
        const q = d.id ? sb.from('party_documents').update(row).eq('id', d.id) : sb.from('party_documents').insert({ ...row, company_id: S.company.id, party_id: p.id });
        const { error } = await q; if (error) return toast(arError(error), 'err'); toast('انحفظت', 'ok'); m.close(); ctx.rerender();
      };
    };
    v.querySelector('#add')?.addEventListener('click', () => form(null));
    v.querySelectorAll('[data-ed]').forEach(b => b.onclick = () => form(docs.find(x => x.id === b.dataset.ed)));
    v.querySelectorAll('[data-att]').forEach(b => b.onclick = () => { const d = docs.find(x => x.id === b.dataset.att); openAttachments('party_doc', d.id, `${tBy[d.type_id]?.name || 'وثيقة'} — ${p.name}`); });
    v.querySelectorAll('[data-del]').forEach(b => b.onclick = async () => {
      if (!(await confirmBox('حذف الوثيقة؟'))) return;
      const { error } = await sb.from('party_documents').delete().eq('id', b.dataset.del); if (error) return toast(arError(error), 'err'); toast('انحذفت', 'ok'); ctx.rerender();
    });
    return;
  }

  const days = +(qp().get('days') || 30);
  const { data: rows = [], error } = await sb.rpc('party_docs_report', { p_company: S.company.id, p_days: days });
  if (error) return void (v.innerHTML = `${head}<div class="notice">${esc(arError(error))}</div>`);
  const f = qp().get('f') || '';
  const list = (rows || []).filter(r => !f || r.problem === f);
  v.innerHTML = `${head}<div class="card" style="display:flex;gap:10px;align-items:end;flex-wrap:wrap;margin-bottom:10px">
      <div class="field"><label>اللي بتنتهي خلال (يوم)</label><input type="number" id="days" min="0" max="365" value="${days}"></div>
      <div class="field"><label>الحالة</label><select id="f"><option value="">الكل</option>${Object.entries(PROB).map(([k, [l]]) => `<option value="${k}" ${k === f ? 'selected' : ''}>${l}</option>`).join('')}</select></div>
      <button class="btn primary" id="go">عرض</button><div class="spacer"></div>
      <span class="badge bad">منتهية ${(rows || []).filter(r => r.problem === 'expired').length}</span><span class="badge bad">ناقصة ${(rows || []).filter(r => r.problem === 'missing').length}</span>
      <span class="badge warn">قرّبت ${(rows || []).filter(r => r.problem === 'expiring').length}</span><button class="btn" id="pr">🖨️ طباعة</button></div>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الرمز</th><th>الطرف</th><th>الوثيقة</th><th>الرقم</th><th>الانتهاء</th><th>الحالة</th><th>التصرّف</th><th></th></tr></thead><tbody>
    ${list.map(r => { const dl = daysLeft(r.expiry_date); return `<tr><td>${esc(r.party_code)}</td><td>${esc(r.party_name)} <span class="muted" style="font-size:11px">${r.party_type === 'supplier' ? 'مورد' : 'عميل'}</span></td><td>${esc(r.type_name)}</td><td dir="ltr">${esc(r.doc_no || '')}</td>
      <td>${fmtDate(r.expiry_date)}${dl != null ? ` <span class="muted" style="font-size:11px">(${dl < 0 ? 'من ' + -dl : 'بعد ' + dl} يوم)</span>` : ''}</td><td><span class="badge ${PROB[r.problem][1]}">${PROB[r.problem][0]}</span></td>
      <td style="font-size:12px">${MODE[r.on_missing]}</td><td><a class="btn sm" href="#/party-docs?t=docs&party=${r.party_id}">فتح</a></td></tr>`; }).join('')
      || '<tr><td colspan="8" class="empty">كل الوثائق تمام 👍</td></tr>'}</tbody></table></div>`;
  v.querySelector('#go').onclick = () => { location.hash = `#/party-docs?t=report&days=${v.querySelector('#days').value}&f=${v.querySelector('#f').value}`; };
  v.querySelector('#pr').onclick = () => printDoc('وثائق العملاء والموردين المنتهية والقريبة', v.querySelector('table').outerHTML.replace('class="t"', 'class="pt"'));
}

export const PARTYDOC_ROUTES = { 'party-docs': viewPartyDocs };
