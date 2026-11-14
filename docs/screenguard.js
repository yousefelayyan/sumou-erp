// 📸 مراقبة تصوير الشاشة (المرحلة 96) — «أفضل محاولة» من المتصفح:
// زر برنت سكرين، اختصار أداة القص (ويندوز + شفت + إس، أو كوماند + شفت + 3/4/5 بالماك)، طباعة الشاشة من المتصفح،
// ونسخ نص كبير. كل محاولة بتنبعت لـ screen_event وبتنسجّل بسجل التتبع، والسيرفر بيقرر التحذير والإيقاف.
// التصوير بالجوال أو بكاميرا ثانية ما بينكشف من المتصفح.
import { S, sb, toast, modal, esc } from './core.js';

let wired = false, metaAt = 0, appPrintAt = 0, lastSent = 0, warnedAt = 0;

const screenName = () => (location.hash.replace(/^#\/?/, '').split('?')[0]) || 'home';

async function report(kind) {
  if (!S.session) return;
  const now = Date.now(); if (now - lastSent < 2500) return; lastSent = now;
  const { data, error } = await sb.rpc('screen_event', { p_company: S.company?.id || null, p_kind: kind, p_screen: screenName() });
  if (error || !data) return;
  if (data.blocked) {
    modal({ title: '⛔ تم إيقاف حسابك', body: `<p>تكررت محاولات تصوير الشاشة اليوم (${esc(String(data.count))} مرة)، فتوقّف حسابك تلقائياً.</p><p>تواصل مع مدير النظام لإعادة التفعيل.</p>`,
      foot: '<button class="btn primary" data-close>تمام</button>' });
    setTimeout(async () => { try { await sb.auth.signOut({ scope: 'local' }); } catch (e) { } location.reload(); }, 6000);
    return;
  }
  if (data.warn) {
    if (now - warnedAt > 15000) {
      warnedAt = now;
      modal({ title: '⚠️ تنبيه: تصوير الشاشة', body: `<p>تم تسجيل محاولة تصوير للشاشة باسمك (${esc(String(data.count))} مرة اليوم).</p>
        <p>بعد ${esc(String(data.block_at))} محاولة باليوم بيتوقّف الحساب تلقائياً. المحاولات بتوصل للمدير وبتنسجّل بسجل التتبع.</p>`,
        foot: '<button class="btn primary" data-close>فهمت</button>' });
    }
  }
}

export function initScreenGuard() {
  if (wired) return; wired = true;
  // طباعة من أزرار البرنامج (🖨️) مش محاولة تصوير
  document.addEventListener('click', (e) => {
    const b = e.target.closest?.('button, a'); if (!b) return;
    if (/🖨|طباعة/.test(b.textContent || '') || /^(prn|print)$/.test(b.id || '')) appPrintAt = Date.now();
  }, true);
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Meta' || e.key === 'OS') metaAt = Date.now();
    if (e.key === 'PrintScreen') report('printscreen');
    else if ((e.metaKey || e.key === 'Meta') && e.shiftKey && /^[sS345س]$/.test(e.key)) report('snip');
    else if ((e.ctrlKey || e.metaKey) && !e.shiftKey && (e.key === 'p' || e.key === 'P' || e.key === 'ح')) { if (Date.now() - appPrintAt > 3000) report('print'); }
  }, true);
  // بالويندوز زر برنت سكرين غالباً بيوصل بس بالـ keyup
  document.addEventListener('keyup', (e) => { if (e.key === 'PrintScreen') report('printscreen'); }, true);
  // زر الويندوز وبعده فوراً بتطلع النافذة من التركيز = ممكن أداة القص (بينسجّل بس، ما بينحسب للإيقاف عشان قائمة ابدأ)
  window.addEventListener('blur', () => { if (Date.now() - metaAt < 1200) report('other'); });
  window.addEventListener('beforeprint', () => { if (Date.now() - appPrintAt > 3000) report('print'); });
  document.addEventListener('copy', () => {
    const t = String(window.getSelection?.() || '');
    const inInput = /^(INPUT|TEXTAREA)$/.test(document.activeElement?.tagName || '');
    if (!inInput && t.length > 600) report('copy');
  }, true);
}

// إعداد الحدود (لمدير المشترك)
export async function screenGuardDialog() {
  const { data } = await sb.rpc('screen_guard');
  const g = data || { enabled: true, warn: 10, block: 25 };
  const m = modal({ title: '📸 مراقبة تصوير الشاشة', size: 'sm', body: `<form id="sg">
    <label class="check"><input type="checkbox" name="enabled" ${g.enabled ? 'checked' : ''}> تشغيل المراقبة</label>
    <div class="grid cols-2"><div class="field"><label>تحذير المستخدم بعد (مرة باليوم)</label><input name="warn" value="${esc(String(g.warn))}" inputmode="numeric" dir="ltr"></div>
    <div class="field"><label>إيقاف الحساب بعد (مرة باليوم)</label><input name="block" value="${esc(String(g.block))}" inputmode="numeric" dir="ltr"></div></div>
    <p class="muted" style="font-size:12px">اللي بينحسب للتحذير والإيقاف: زر برنت سكرين، اختصار أداة القص، والطباعة. النسخ الكبير وخروج النافذة بعد زر الويندوز بينسجّلوا بس. التصوير بالجوال أو بكاميرا ما بينكشف، فالعلامة المائية باسم المستخدم والتاريخ بتضل على الشاشة. المدير ما بيتوقّف.</p></form>
    <div id="sg-list"></div>`,
    foot: '<button class="btn primary" data-ok>💾 حفظ</button><button class="btn" data-close>إغلاق</button>' });
  const { data: al } = await sb.rpc('screen_alerts', { p_days: 7 });
  m.el.querySelector('#sg-list').innerHTML = (al || []).length ? `<h4 style="margin:10px 0 6px">آخر 7 أيام</h4><table class="t"><thead><tr><th>المستخدم</th><th>اليوم</th><th>7 أيام</th><th>آخر شاشة</th><th></th></tr></thead><tbody>
    ${al.map(r => `<tr><td>${esc(r.name || '')}</td><td class="n">${r.today}</td><td class="n">${r.total}</td><td>${esc(r.last_screen || '')}</td><td>${r.blocked ? '<span class="badge bad">موقوف</span>' : ''}</td></tr>`).join('')}</tbody></table>` : '<p class="muted">ما في محاولات آخر 7 أيام.</p>';
  m.el.querySelector('[data-ok]').onclick = async () => {
    const f = Object.fromEntries(new FormData(m.el.querySelector('#sg')));
    const { error } = await sb.rpc('set_screen_guard', { p: { enabled: !!f.enabled, warn: parseInt(f.warn) || 10, block: parseInt(f.block) || 25 } });
    if (error) return toast(error.message, 'err'); toast('تم الحفظ', 'ok'); m.close();
  };
}

// شريط تنبيه للمدير على الرئيسية: محاولات اليوم
export async function screenAlertsBanner(el) {
  if (!el || !S.profile?.is_admin) return;
  const { data } = await sb.rpc('screen_alerts', { p_days: 1 });
  const rows = (data || []).filter(r => r.today > 0); if (!rows.length) return;
  el.innerHTML = `<div class="notice" style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">📸 محاولات تصوير شاشة اليوم:
    ${rows.map(r => `<b>${esc(r.name || '')}</b> (${r.today})${r.blocked ? ' ⛔' : ''}`).join('، ')}
    <button class="btn sm" id="sg-open">التفاصيل والإعداد</button></div>`;
  el.querySelector('#sg-open').onclick = () => screenGuardDialog();
}
