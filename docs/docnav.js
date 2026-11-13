// =====================================================================
//  السمو ERP — شريط التنقّل الموحّد بكل مستند:
//  جديد · الأول · السابق · التالي · الأخير · تعديل · حذف · تجميد/فك التجميد
//  الشاشة (القائمة) بتسجّل ترتيب المستندات بـ setNavList، والمحرر بينادي attachDocNav.
// =====================================================================
import { sb, toast, arError, hasUnsavedModal, confirmBox } from './core.js';

const LISTS = {};
export const setNavList = (key, rows) => { LISTS[key] = rows || []; };

/**
 * m: نتيجة modal()، row: المستند الحالي (أو null للجديد)
 * opts: { key, open(row), onNew(), table, canFreeze, editable }
 */
export function attachDocNav(m, row, { key, open, onNew, table, canFreeze = false, editable = true }) {
  const list = LISTS[key] || [];
  const i = row ? list.findIndex(x => x.id === row.id) : -1;
  const fr = !!row?.is_frozen;
  const hasDel = !!m.el.querySelector('.modal-foot [data-del]');
  const bar = document.createElement('div');
  bar.className = 'docnav no-print';
  bar.innerHTML = `
    ${onNew ? '<button type="button" class="btn sm" data-n="new" title="جديد">➕ جديد</button>' : ''}
    <span class="dn-sep"></span>
    <button type="button" class="btn sm" data-n="first" title="الأول" ${list.length && i !== 0 ? '' : 'disabled'}>⏮</button>
    <button type="button" class="btn sm" data-n="prev" title="السابق" ${i > 0 ? '' : 'disabled'}>▶ السابق</button>
    <span class="dn-pos">${i >= 0 ? `${i + 1} / ${list.length}` : row ? '' : 'جديد'}</span>
    <button type="button" class="btn sm" data-n="next" title="التالي" ${i >= 0 && i < list.length - 1 ? '' : 'disabled'}>التالي ◀</button>
    <button type="button" class="btn sm" data-n="last" title="الأخير" ${list.length && i !== list.length - 1 ? '' : 'disabled'}>⏭</button>
    <span class="dn-sep"></span>
    ${row ? `<button type="button" class="btn sm" data-n="edit" title="تعديل">✏️ تعديل</button>
      <button type="button" class="btn sm danger" data-n="del" title="حذف" ${hasDel && !fr ? '' : 'disabled'}>🗑️ حذف</button>
      ${table && canFreeze ? `<button type="button" class="btn sm ${fr ? 'primary' : ''}" data-n="freeze">${fr ? '🔓 فك التجميد' : '🧊 تجميد'}</button>` : ''}
      ${fr ? '<span class="badge" style="background:#0ea5e9;color:#fff">🧊 مجمّد</span>' : ''}` : ''}`;
  const body = m.el.querySelector('.modal-body');
  body?.prepend(bar);
  if (fr) m.el.querySelectorAll('.modal-foot [data-save], .modal-foot [data-post], .modal-foot [data-del]').forEach(b => { b.disabled = true; b.title = 'المستند مجمّد'; });
  const go = (target) => {
    if (hasUnsavedModal()) return toast('في تعديلات مش محفوظة: احفظ أو سكّر النافذة أول', 'err');
    m.close(); target();
  };
  // التنقّل بيقرأ المستند من جديد (عشان الحالة بعد الترحيل/إلغاء الترحيل/التجميد تكون محدّثة)
  const fresh = async (r) => {
    if (!r || !table) return r;
    const { data } = await sb.from(table).select('*').eq('id', r.id).maybeSingle();
    if (data) { const k = list.findIndex(x => x.id === r.id); if (k >= 0) list[k] = { ...list[k], ...data }; }
    return data ? { ...r, ...data } : r;
  };
  const goTo = (r) => go(async () => open(await fresh(r)));
  bar.addEventListener('click', async (e) => {
    const b = e.target.closest('[data-n]'); if (!b || b.disabled) return;
    const n = b.dataset.n;
    if (n === 'new') return go(onNew);
    if (n === 'first') return goTo(list[0]);
    if (n === 'last') return goTo(list[list.length - 1]);
    if (n === 'prev') return goTo(list[i - 1]);
    if (n === 'next') return goTo(list[i + 1]);
    if (n === 'del') return m.el.querySelector('.modal-foot [data-del]')?.click();
    if (n === 'edit') {
      if (fr) return toast('المستند مجمّد، فك التجميد أول', 'err');
      if (!editable) return toast('المستند مرحّل أو ما عندك صلاحية تعديل. للتعديل ألغِ الترحيل أو اعمل قيد عكسي', 'err');
      const f = m.el.querySelector('.modal-body input:not([disabled]):not([type=hidden]), .modal-body select:not([disabled]), .modal-body textarea:not([disabled])');
      f?.focus(); f?.scrollIntoView({ block: 'center' }); return;
    }
    if (n === 'freeze') {
      if (hasUnsavedModal()) return toast('احفظ التعديلات أول', 'err');
      const ok = await confirmBox(fr ? 'فك تجميد المستند؟ بيرجع ينعدّل ويترحّل.' : 'تجميد المستند؟ ما رح ينعدّل ولا ينحذف ولا يترحّل لحد ما ينفك تجميده.');
      if (!ok) return open(row);
      const { error } = await sb.rpc('set_doc_frozen', { p_table: table, p_id: row.id, p_frozen: !fr });
      if (error) { toast(arError(error), 'err'); return open(row); }
      toast(fr ? 'انفك التجميد' : 'انجمّد المستند', 'ok');
      const { data } = await sb.from(table).select('*').eq('id', row.id).single();
      const k = list.findIndex(x => x.id === row.id); if (k >= 0 && data) list[k] = data;
      open(data || row);
    }
  });
}
