// =====================================================================
//  السمو ERP — محرر الصلاحيات على شكل شجرة (مثل ستاليون)
//  يمين: مجموعات الشاشات (بتنفتح وبتتسكّر)، يسار: صلاحيات الشاشة المختارة.
// =====================================================================
import { SCREENS, ACTIONS, esc, moduleOn, screenModule } from './core.js';

const HELP = {
  view: 'عرض الشاشة والسجلات اللي فيها',
  add: 'إضافة سجل أو سند جديد',
  edit: 'تعديل بيانات سجل (المسودات بس للسندات)',
  delete: 'حذف سجل (المسودات بس للسندات)',
  print: 'طباعة السجل والتقارير وتصديرها',
  post: 'ترحيل السندات وعمل قيد عكسي',
  unpost: 'إلغاء الترحيل وفتح الفترات المقفولة',
};

// perms: صيغة المجموعة {screen:{view:true}} أو صيغة المستخدم {screen:true | {view:true}}
export function permEditor(root, perms = {}, { compact = false } = {}) {
  const st = {};   // screen -> Set(actions)
  for (const s of SCREENS) {
    const p = perms[s.key];
    st[s.key] = new Set(p === true ? ACTIONS.map(a => a.key) : Object.keys(p || {}).filter(k => p[k]));
  }
  const groups = [...new Set(SCREENS.map(s => s.group))];
  let sel = SCREENS[0].key, open = new Set([SCREENS[0].group]), q = '';
  const n = (k) => st[k].size;
  const gCount = (g) => SCREENS.filter(s => s.group === g).reduce((a, s) => a + (n(s.key) ? 1 : 0), 0);
  const badge = (k) => { const c = n(k); return c === 0 ? '' : `<span class="pt-b ${c === ACTIONS.length ? 'full' : ''}">${c === ACTIONS.length ? 'الكل' : c}</span>`; };
  function draw() {
    const scr = SCREENS.find(s => s.key === sel);
    const vis = (s) => moduleOn(screenModule(s.key)) && (!q || s.label.includes(q) || s.group.includes(q));
    root.innerHTML = `<div class="ptree ${compact ? 'compact' : ''}">
      <div class="pt-tree">
        <div class="pt-tools"><input class="pt-q" placeholder="🔎 بحث عن شاشة…" value="${esc(q)}">
          <button type="button" class="btn sm" data-pall="1" title="كل الصلاحيات على كل الشاشات">✔ الكل</button><button type="button" class="btn sm" data-pall="0" title="شيل كل الصلاحيات">✖ لا شي</button></div>
        ${groups.map(g => { const items = SCREENS.filter(s => s.group === g && vis(s)); if (!items.length) return '';
          const isOpen = open.has(g) || !!q;
          return `<div class="pt-g ${isOpen ? 'open' : ''}"><button type="button" class="pt-gt" data-g="${esc(g)}"><span class="chev">›</span>${esc(g)}
              <span class="muted" style="font-size:11px;margin-inline-start:auto">${gCount(g)}/${SCREENS.filter(s => s.group === g).length}</span></button>
            ${isOpen ? `<div class="pt-items">${items.map(s => `<div class="pt-i ${s.key === sel ? 'on' : ''}" data-s="${s.key}">${esc(s.label)}${badge(s.key)}</div>`).join('')}</div>` : ''}</div>`; }).join('')}
      </div>
      <div class="pt-panel">
        <div class="pt-head"><b>${esc(scr.group)} ← ${esc(scr.label)}</b><div class="spacer" style="flex:1"></div>
          <button type="button" class="btn sm" data-sall="1">تحديد الكل</button><button type="button" class="btn sm" data-sall="0">إلغاء الكل</button></div>
        ${ACTIONS.map(a => `<label class="pt-a"><input type="checkbox" data-a="${a.key}" ${st[sel].has(a.key) ? 'checked' : ''}>
          <span><b>${esc(a.label)}</b><small class="muted">${esc(HELP[a.key] || '')}</small></span></label>`).join('')}
        <p class="muted" style="font-size:12px;margin:8px 0 0">أي صلاحية غير «عرض» بتشغّل «عرض» معها لحالها.</p>
      </div></div>`;
    const qi = root.querySelector('.pt-q');
    qi.oninput = () => { q = qi.value.trim(); const pos = qi.selectionStart; draw(); const x = root.querySelector('.pt-q'); x.focus(); x.setSelectionRange(pos, pos); };
    root.querySelectorAll('[data-g]').forEach(b => b.onclick = () => { const g = b.dataset.g; open.has(g) ? open.delete(g) : (open = new Set([g])); draw(); });
    root.querySelectorAll('[data-s]').forEach(b => b.onclick = () => { sel = b.dataset.s; draw(); });
    root.querySelectorAll('[data-a]').forEach(c => c.onchange = () => {
      const s = st[sel];
      if (c.checked) { s.add(c.dataset.a); if (c.dataset.a !== 'view') s.add('view'); }
      else { s.delete(c.dataset.a); if (c.dataset.a === 'view') s.clear(); }
      draw();
    });
    root.querySelectorAll('[data-sall]').forEach(b => b.onclick = () => { st[sel] = new Set(b.dataset.sall === '1' ? ACTIONS.map(a => a.key) : []); draw(); });
    root.querySelectorAll('[data-pall]').forEach(b => b.onclick = () => { for (const s of SCREENS) st[s.key] = new Set(b.dataset.pall === '1' ? ACTIONS.map(a => a.key) : []); draw(); });
  }
  draw();
  return {
    group: () => Object.fromEntries(SCREENS.filter(s => n(s.key)).map(s => [s.key, Object.fromEntries([...st[s.key]].map(a => [a, true]))])),
    user: () => Object.fromEntries(SCREENS.filter(s => n(s.key)).map(s => [s.key, n(s.key) === ACTIONS.length ? true : Object.fromEntries([...st[s.key]].map(a => [a, true]))])),
    set: (p) => { for (const s of SCREENS) { const x = p?.[s.key]; st[s.key] = new Set(x === true ? ACTIONS.map(a => a.key) : Object.keys(x || {}).filter(k => x[k])); } draw(); },
  };
}
