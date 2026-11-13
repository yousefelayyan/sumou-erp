// =====================================================================
//  السمو ERP — حالات المتابعة المخصصة (route doc-statuses?k=…) + attachFollow() بمحررات المستندات
//  + followMap()/followBadge() للقوائم. التغيير من set_doc_follow بس.
// =====================================================================
import { S, sb, esc, fmtDateTime, toast, arError, modal, formData, can } from './core.js';

export const FOLLOW_KINDS = { sale: 'فواتير المبيعات', sale_return: 'مردودات المبيعات', purchase: 'فواتير المشتريات', purchase_return: 'مردودات المشتريات',
  sales_order: 'طلبات المبيعات', purchase_order: 'طلبات التزويد', receipt: 'سندات القبض', payment: 'سندات الصرف', journal: 'سندات القيد', stock: 'سندات المخزون' };

export async function loadStatuses(force = false) {
  if (!S.company) return [];
  if (!force && S._dst?.cid === S.company.id) return S._dst.rows;
  const { data } = await sb.from('doc_statuses').select('*').eq('company_id', S.company.id).order('kind').order('sort').order('code');
  S._dst = { cid: S.company.id, rows: data || [] };
  return S._dst.rows;
}
export const followBadge = (st) => st ? `<span class="badge" style="background:${esc(st.color)}22;color:${esc(st.color)};border:1px solid ${esc(st.color)}55">${st.is_final ? '✔ ' : ''}${esc(st.name)}</span>` : '';

// للقوائم: {doc_id: status row}
export async function followMap(ids) {
  if (!ids?.length) return {};
  const sts = await loadStatuses(); if (!sts.length) return {};
  const byId = Object.fromEntries(sts.map(s => [s.id, s])), out = {};
  for (let i = 0; i < ids.length; i += 300) {
    const { data } = await sb.from('doc_follow').select('doc_id,status_id,note').in('doc_id', ids.slice(i, i + 300));
    (data || []).forEach(r => { if (byId[r.status_id]) out[r.doc_id] = { ...byId[r.status_id], note: r.note }; });
  }
  return out;
}

// شريط «حالة المتابعة» أعلى نافذة المستند
export async function attachFollow(root, table, row, kind, screen) {
  if (!row?.id || !FOLLOW_KINDS[kind]) return;
  const body = root.querySelector('.modal-body'); if (!body) return;
  const sts = (await loadStatuses()).filter(s => s.kind === kind);
  if (!sts.length) return;
  const { data: cur } = await sb.from('doc_follow').select('status_id,note,updated_at').eq('doc_id', row.id).maybeSingle();
  const canSet = can(screen, 'edit') || can(screen, 'post');
  const box = document.createElement('div');
  box.className = 'no-print';
  box.style.cssText = 'display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:0 0 10px;padding:6px 10px;border:1px dashed var(--line, #ddd);border-radius:10px';
  const draw = (c) => {
    const st = sts.find(s => s.id === c?.status_id);
    box.innerHTML = `<b style="font-size:13px">📌 المتابعة:</b> ${followBadge(st) || '<span class="muted" style="font-size:13px">بدون حالة</span>'}
      ${c?.note ? `<span class="muted" style="font-size:12px">— ${esc(c.note)}</span>` : ''}<span style="flex:1"></span>
      ${canSet ? `<select data-fst class="cell" style="max-width:200px"><option value="">— بدون حالة —</option>${sts.filter(s => s.is_active || s.id === c?.status_id).map(s => `<option value="${s.id}" ${s.id === c?.status_id ? 'selected' : ''}>${esc(s.name)}</option>`).join('')}</select>` : ''}
      <button type="button" class="btn sm" data-fhist>🕓</button><div data-fh hidden style="flex-basis:100%"></div>`;
    box.querySelector('[data-fst]')?.addEventListener('change', async (e) => {
      const note = prompt('ملاحظة على الحالة (اختياري):', '') ?? '';
      const { error } = await sb.rpc('set_doc_follow', { p_table: table, p_id: row.id, p_status: e.target.value || null, p_note: note });
      if (error) { toast(arError(error), 'err'); draw(c); return; }
      toast('انحفظت الحالة', 'ok'); draw({ status_id: e.target.value || null, note });
    });
    box.querySelector('[data-fhist]').onclick = async () => {
      const h = box.querySelector('[data-fh]'); if (!h.hidden) { h.hidden = true; return; }
      h.hidden = false;
      const { data } = await sb.from('doc_follow_log').select('*').eq('doc_id', row.id).order('set_at', { ascending: false }).limit(50);
      const { data: nm } = await sb.rpc('user_names', { p_ids: [...new Set((data || []).map(x => x.set_by).filter(Boolean))] });
      const names = Object.fromEntries((nm || []).map(x => [x.id, x.name]));
      h.innerHTML = `<table class="t"><tbody>${(data || []).map(x => `<tr><td dir="ltr" style="text-align:right;font-size:12px">${fmtDateTime(x.set_at)}</td><td>${esc(x.status_name || '')}</td><td>${esc(names[x.set_by] || '')}</td><td class="muted" style="font-size:12px">${esc(x.note || '')}</td></tr>`).join('') || '<tr><td class="empty">ما في تغييرات</td></tr>'}</tbody></table>`;
    };
  };
  draw(cur);
  const audit = body.querySelector('.audit-bar');
  if (audit) audit.after(box); else body.prepend(box);
}

async function viewStatuses(v, ctx) {
  if (!S.company) return void (v.innerHTML = '<div class="notice info">اختار شركة من فوق أول.</div>');
  const k = new URLSearchParams(location.hash.split('?')[1] || '').get('k') || 'sale';
  const all = await loadStatuses(true), rows = all.filter(s => s.kind === k), ed = can('doc_types', 'edit');
  v.innerHTML = `<div class="page-head"><h2>📌 حالات المتابعة</h2><div class="spacer"></div>${ed ? '<button class="btn primary" id="add">➕ حالة</button>' : ''}</div>
    <p class="muted" style="margin-top:-6px">حالات بتسمّيها إنت لتتبّع المستند بعد ما ينعمل (مثلاً: بانتظار التوقيع، انبعتت للعميل، تم التسليم). بتبيّن بشريط فوق المستند وبالقوائم، وبتتغيّر حتى للمرحّل.</p>
    <div class="tabs" style="margin-bottom:10px;flex-wrap:wrap">${Object.entries(FOLLOW_KINDS).map(([kk, l]) => `<a class="tab ${kk === k ? 'active' : ''}" href="#/doc-statuses?k=${kk}">${l} (${all.filter(s => s.kind === kk).length})</a>`).join('')}</div>
    <div class="card table-wrap"><table class="t"><thead><tr><th>الترتيب</th><th>الرمز</th><th>الحالة</th><th>نهائية</th><th>فعّالة</th></tr></thead><tbody>
      ${rows.map(s => `<tr data-s="${s.id}" ${ed ? 'style="cursor:pointer"' : ''}><td class="n">${s.sort}</td><td>${esc(s.code)}</td><td>${followBadge(s)}</td><td>${s.is_final ? '✓' : ''}</td><td>${s.is_active ? '✓' : '—'}</td></tr>`).join('')
        || `<tr><td colspan="5" class="empty">ما في حالات لـ${FOLLOW_KINDS[k]}</td></tr>`}</tbody></table></div>`;
  const form = (s) => {
    s = s || { code: String(rows.length + 1).padStart(2, '0'), name: '', color: '#2563eb', sort: rows.length + 1, is_final: false, is_active: true };
    const m = modal({ title: s.id ? 'تعديل حالة' : `حالة جديدة — ${FOLLOW_KINDS[k]}`, body: `<form id="sf"><div class="grid cols-2">
      <div class="field"><label>الرمز</label><input name="code" value="${esc(s.code)}"></div><div class="field"><label>اسم الحالة</label><input name="name" value="${esc(s.name)}"></div>
      <div class="field"><label>اللون</label><input type="color" name="color" value="${esc(s.color)}"></div><div class="field"><label>الترتيب</label><input type="number" name="sort" value="${s.sort}"></div>
      <label class="check"><input type="checkbox" name="is_final" ${s.is_final ? 'checked' : ''}> حالة نهائية (المستند خلص)</label><label class="check"><input type="checkbox" name="is_active" ${s.is_active ? 'checked' : ''}> فعّالة</label></div></form>`,
      foot: `<button class="btn primary" data-save>💾 حفظ</button>${s.id ? '<button class="btn danger" data-del>حذف</button>' : ''}<button class="btn" data-close>إلغاء</button>` });
    m.el.querySelector('[data-save]').onclick = async () => {
      const d = formData(m.el.querySelector('#sf')); if (!d.code || !d.name) return toast('الرمز والاسم مطلوبين', 'err');
      const row = { code: d.code, name: d.name, color: d.color, sort: +d.sort || 0, is_final: !!d.is_final, is_active: !!d.is_active };
      const q = s.id ? sb.from('doc_statuses').update(row).eq('id', s.id) : sb.from('doc_statuses').insert({ ...row, kind: k, company_id: S.company.id });
      const { error } = await q; if (error) return toast(arError(error), 'err');
      toast('انحفظ', 'ok'); m.close(); ctx.rerender();
    };
    m.el.querySelector('[data-del]')?.addEventListener('click', async () => {
      const { error } = await sb.from('doc_statuses').delete().eq('id', s.id); if (error) return toast(arError(error), 'err');
      toast('انحذفت (المستندات اللي عليها صارت بدون حالة)', 'ok'); m.close(); ctx.rerender();
    });
  };
  v.querySelector('#add')?.addEventListener('click', () => form(null));
  if (ed) v.querySelectorAll('[data-s]').forEach(tr => tr.onclick = () => form(rows.find(x => x.id === tr.dataset.s)));
}

export const FOLLOW_ROUTES = { 'doc-statuses': viewStatuses };
