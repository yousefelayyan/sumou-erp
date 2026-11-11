// =====================================================================
//  السمو ERP — المرفقات (صور ومستندات مع السندات والفواتير)
// =====================================================================
import { S, sb, esc, fmtDateTime, toast, arError, modal, confirmBox } from './core.js';

const MAX = 10 * 1024 * 1024;   // 10 ميغا للملف
const size = (n) => n > 1048576 ? (n / 1048576).toFixed(1) + ' ميغا' : Math.max(1, Math.round(n / 1024)) + ' كيلو';

export async function openAttachments(entity, entityId, title = '') {
  if (!S.company) return;
  const m = modal({ title: '📎 المرفقات' + (title ? ': ' + title : ''), body: `<div id="att-list" class="muted">جاري التحميل…</div>
    <label class="btn primary" style="margin-top:12px;display:inline-flex">➕ إرفاق ملف أو صورة<input type="file" id="att-file" multiple accept="image/*,application/pdf,.doc,.docx,.xls,.xlsx" hidden></label>
    <p class="muted" style="font-size:12px;margin:8px 0 0">من الجوال بتقدر تصوّر الفاتورة أو الشيك مباشرة. الحد الأقصى 10 ميغا للملف.</p>`,
    foot: '<button class="btn" data-close>إغلاق</button>' });
  const list = m.el.querySelector('#att-list');
  const load = async () => {
    const { data, error } = await sb.from('attachments').select('*').eq('entity', entity).eq('entity_id', entityId).order('created_at');
    if (error) return void (list.innerHTML = `<div class="notice">${esc(arError(error))}</div>`);
    list.innerHTML = data.length ? `<table class="t">${data.map(a => `<tr>
        <td>${/^image\//.test(a.mime || '') ? '🖼️' : a.mime === 'application/pdf' ? '📄' : '📁'} <b>${esc(a.file_name)}</b><div class="muted" style="font-size:12px">${size(a.size || 0)} · ${fmtDateTime(a.created_at)}</div></td>
        <td class="actions"><button class="btn sm" data-open="${a.id}">فتح</button> <button class="btn sm danger" data-rm="${a.id}">حذف</button></td></tr>`).join('')}</table>`
      : '<div class="empty">ما في مرفقات</div>';
    list.onclick = async (e) => {
      const o = e.target.closest('[data-open]'), r = e.target.closest('[data-rm]');
      const a = data.find(x => x.id === (o || r)?.dataset.open || x.id === (o || r)?.dataset.rm); if (!a) return;
      if (o) {
        const w = window.open('', '_blank');
        const { data: u, error: er } = await sb.storage.from('attachments').createSignedUrl(a.path, 600);
        if (er) { w?.close(); return toast(arError(er), 'err'); }
        if (w) w.location = u.signedUrl; else location.href = u.signedUrl;
      } else {
        if (!(await confirmBox(`حذف المرفق «${a.file_name}»؟`))) return;
        // السجل أول (بيرفض إذا مش إلك)، وبعدين الملف
        const { data: del, error: er } = await sb.from('attachments').delete().eq('id', a.id).select();
        if (er) return toast(arError(er), 'err');
        if (!del?.length) return toast('بس اللي رفع الملف أو المدير بيقدر يحذفه', 'err');
        await sb.storage.from('attachments').remove([a.path]);
        toast('انحذف', 'ok'); load();
      }
    };
  };
  m.el.querySelector('#att-file').onchange = async (e) => {
    const files = [...e.target.files]; e.target.value = '';
    for (const f of files) {
      if (f.size > MAX) { toast(`«${f.name}» أكبر من 10 ميغا`, 'err'); continue; }
      const ext = (f.name.split('.').pop() || 'bin').toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 6) || 'bin';
      const path = `${S.company.id}/${entity}/${entityId}/${Date.now()}_${Math.random().toString(36).slice(2, 8)}.${ext}`;
      toast(`جاري رفع «${f.name}»…`, '');
      const up = await sb.storage.from('attachments').upload(path, f, { contentType: f.type || undefined, upsert: false });
      if (up.error) { toast(arError(up.error), 'err'); continue; }
      const ins = await sb.from('attachments').insert({ company_id: S.company.id, entity, entity_id: entityId, path, file_name: f.name, mime: f.type, size: f.size });
      if (ins.error) { await sb.storage.from('attachments').remove([path]); toast(arError(ins.error), 'err'); continue; }
    }
    toast('تم الإرفاق', 'ok'); load();
  };
  load();
}
