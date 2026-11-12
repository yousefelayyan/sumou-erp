// =====================================================================
//  السمو قصاصة — تصوير الشاشة وقصّها والكتابة عليها (بالمتصفح، بدون إنترنت)
// =====================================================================
const $ = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];
const uid = () => Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
function toast(t, ms = 2200) { const el = $('#toast'); el.textContent = t; el.style.display = 'block'; clearTimeout(toast.t); toast.t = setTimeout(() => el.style.display = 'none', ms); }
const show = (id) => ['home', 'crop', 'editor'].forEach(s => $('#' + s).hidden = s !== id);
const stamp = () => { const d = new Date(), p = (n) => String(n).padStart(2, '0'); return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}-${p(d.getMinutes())}-${p(d.getSeconds())}`; };
const canCapture = !!navigator.mediaDevices?.getDisplayMedia;

// ---------------------------------------------------------------------
//  التخزين على الجهاز
// ---------------------------------------------------------------------
const DB = {
  db: null,
  async open() { if (this.db) return this.db; this.db = await new Promise((res, rej) => { const r = indexedDB.open('sumou-snip', 1); r.onupgradeneeded = () => r.result.createObjectStore('shots'); r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); }); return this.db; },
  async run(mode, fn) { const d = await this.open(); return new Promise((res, rej) => { const t = d.transaction('shots', mode); const r = fn(t.objectStore('shots')); t.oncomplete = () => res(r?.result); t.onerror = () => rej(t.error); }); },
  put(k, v) { return this.run('readwrite', s => s.put(v, k)); }, get(k) { return this.run('readonly', s => s.get(k)); }, del(k) { return this.run('readwrite', s => s.delete(k)); },
  async all() { const d = await this.open(); return new Promise((res) => { const out = []; const r = d.transaction('shots').objectStore('shots').openCursor(); r.onsuccess = () => { const c = r.result; if (c) { out.push(c.value); c.continue(); } else res(out); }; r.onerror = () => res(out); }); },
  async clear() { return this.run('readwrite', s => s.clear()); },
};

// ---------------------------------------------------------------------
//  التصوير
// ---------------------------------------------------------------------
async function capture({ delay = 0, full = false } = {}) {
  if (!canCapture) return toast('تصوير الشاشة مش متاح على هالجهاز');
  let stream;
  try {
    stream = await navigator.mediaDevices.getDisplayMedia({ video: { cursor: 'never', frameRate: 30 }, audio: false, selfBrowserSurface: 'include', surfaceSwitching: 'exclude', monitorTypeSurfaces: 'include' });
  } catch (e) { if (e?.name !== 'NotAllowedError') toast('ما زبط التصوير'); return; }
  const track = stream.getVideoTracks()[0];
  const surface = track.getSettings?.().displaySurface;
  // لما يختار الشاشة كاملة: فرصة يبدّل للنافذة اللي بدو إياها
  const wait = delay || (surface === 'monitor' ? 3 : 0);
  try {
    const video = document.createElement('video'); video.muted = true; video.playsInline = true; video.srcObject = stream; await video.play();
    if (wait) await countdown(wait);
    await new Promise(r => setTimeout(r, 250));   // نخلي الإطار يستقر
    const c = document.createElement('canvas'); c.width = video.videoWidth; c.height = video.videoHeight;
    c.getContext('2d').drawImage(video, 0, 0);
    track.stop(); stream.getTracks().forEach(t => t.stop());
    if (!c.width) return toast('ما وصلت صورة من الشاشة');
    if (full) openEditor(c, [], null, true); else startCrop(c);
  } catch (e) { console.error(e); stream?.getTracks().forEach(t => t.stop()); toast('ما زبط التصوير'); }
}
function countdown(n) {
  return new Promise(res => { const el = $('#countdown'); el.hidden = false; const t0 = document.title;
    const tick = () => { el.textContent = n; document.title = `⏱️ ${n} — السمو قصاصة`; if (n-- <= 0) { el.hidden = true; document.title = t0; return setTimeout(res, 150); } setTimeout(tick, 1000); }; tick(); });
}
async function fromFile(file) {
  if (!file || !/^image\//.test(file.type)) return toast('هاد الملف مش صورة');
  const img = await createImageBitmap(file).catch(() => null); if (!img) return toast('ما قدرت أقرأ الصورة');
  const c = document.createElement('canvas'); c.width = img.width; c.height = img.height; c.getContext('2d').drawImage(img, 0, 0);
  openEditor(c, [], null, false);
}

// ---------------------------------------------------------------------
//  تحديد الجزء (بعد التصوير)
// ---------------------------------------------------------------------
let cropState = null;
function startCrop(src) {
  show('crop'); const box = $('#crop'), cv = $('#crop-cv'), sel = $('#crop-sel');
  box.classList.remove('has-sel'); sel.hidden = true; $('#crop-hint').hidden = false;
  const sc = Math.min(innerWidth / src.width, innerHeight / src.height);
  const w = src.width * sc, h = src.height * sc, ox = (innerWidth - w) / 2, oy = (innerHeight - h) / 2;
  cv.width = src.width; cv.height = src.height; cv.getContext('2d').drawImage(src, 0, 0);
  Object.assign(cv.style, { width: w + 'px', height: h + 'px', left: ox + 'px', top: oy + 'px' });
  cropState = { src, sc, ox, oy, w, h, start: null };
  box.onpointerdown = (e) => { box.setPointerCapture(e.pointerId); cropState.start = [e.clientX, e.clientY]; cropState.end = null; $('#crop-hint').hidden = true; };
  box.onpointermove = (e) => { if (!cropState.start) return; cropState.end = [e.clientX, e.clientY]; drawSel(); };
  box.onpointerup = () => { const r = selRect(); cropState.start = null; if (!r || r.w < 4 || r.h < 4) { box.classList.remove('has-sel'); sel.hidden = true; $('#crop-hint').hidden = false; return; } finishCrop(r); };
}
function selRect() {
  const s = cropState; if (!s.start || !s.end) return null;
  const x1 = clamp(Math.min(s.start[0], s.end[0]), s.ox, s.ox + s.w), x2 = clamp(Math.max(s.start[0], s.end[0]), s.ox, s.ox + s.w);
  const y1 = clamp(Math.min(s.start[1], s.end[1]), s.oy, s.oy + s.h), y2 = clamp(Math.max(s.start[1], s.end[1]), s.oy, s.oy + s.h);
  return { x: x1, y: y1, w: x2 - x1, h: y2 - y1 };
}
function drawSel() {
  const r = selRect(); if (!r) return; const sel = $('#crop-sel'); sel.hidden = false; $('#crop').classList.add('has-sel');
  Object.assign(sel.style, { left: r.x + 'px', top: r.y + 'px', width: r.w + 'px', height: r.h + 'px' });
  $('#crop-size').textContent = `${Math.round(r.w / cropState.sc)} × ${Math.round(r.h / cropState.sc)}`;
}
function finishCrop(r) {
  const s = cropState; let out = s.src;
  if (r) { const x = Math.round((r.x - s.ox) / s.sc), y = Math.round((r.y - s.oy) / s.sc), w = Math.round(r.w / s.sc), h = Math.round(r.h / s.sc);
    out = document.createElement('canvas'); out.width = w; out.height = h; out.getContext('2d').drawImage(s.src, x, y, w, h, 0, 0, w, h); }
  cropState = null; openEditor(out, [], null, true);
}

// ---------------------------------------------------------------------
//  المحرر
// ---------------------------------------------------------------------
const E = { base: null, annots: [], id: null, tool: localStorage.getItem('snip.tool') || 'arrow', color: localStorage.getItem('snip.color') || '#e11d48',
  width: +(localStorage.getItem('snip.width') || 4), undo: [], redo: [], sel: null, editing: null, num: 1, view: 1 };
const cv = () => $('#cv');

function openEditor(base, annots = [], id = null, autoCopy = false) {
  E.base = base; E.annots = annots; E.id = id || uid(); E.undo = []; E.redo = []; E.sel = null; E.num = 1 + annots.filter(a => a.t === 'num').length;
  show('editor'); fit(); setTool(E.tool); render(); updUndo();
  if (autoCopy) copyImage(true); persist();
}
function fit() {
  const st = $('#stage'); const aw = st.clientWidth - 40, ah = st.clientHeight - 40; const r = devicePixelRatio || 1;
  // الصورة بحجمها الطبيعي على الشاشة (بكسل الشاشة) أو أصغر لتنسع
  E.view = Math.min(aw / E.base.width, ah / E.base.height, 1 / r); if (!(E.view > 0)) E.view = 1;
  const c = cv(); c.width = E.base.width; c.height = E.base.height; c.style.width = E.base.width * E.view + 'px'; c.style.height = E.base.height * E.view + 'px';
  $('#status').textContent = `${E.base.width} × ${E.base.height} بكسل · ${Math.round(E.view * 100)}%`;
}
const W = () => E.base.width;
const lw = () => E.width * Math.max(1, W() / 1400);
const fontPx = () => ({ 2: 18, 4: 26, 7: 38, 12: 56 }[E.width] || 26) * Math.max(1, W() / 1400);

function render(live = null) {
  const c = cv(), ctx = c.getContext('2d'); ctx.clearRect(0, 0, c.width, c.height); ctx.drawImage(E.base, 0, 0);
  for (const a of E.annots) if (a.id !== E.editing) drawAnnot(ctx, a);
  if (live) drawAnnot(ctx, live);
  if (E.sel) { const a = E.annots.find(x => x.id === E.sel); if (a) { const b = box(a); ctx.save(); ctx.setLineDash([8, 6]); ctx.strokeStyle = '#06b6d4'; ctx.lineWidth = 2 / E.view; ctx.strokeRect(b.x - 6, b.y - 6, b.w + 12, b.h + 12); ctx.restore(); } }
  if (live?.t === 'crop') { ctx.save(); ctx.fillStyle = 'rgba(0,0,0,.45)'; const r = norm(live); ctx.beginPath(); ctx.rect(0, 0, c.width, c.height); ctx.rect(r.x, r.y, r.w, r.h); ctx.fill('evenodd'); ctx.strokeStyle = '#22d3ee'; ctx.lineWidth = 2 / E.view; ctx.strokeRect(r.x, r.y, r.w, r.h); ctx.restore(); }
}
const norm = (a) => ({ x: Math.min(a.x1, a.x2), y: Math.min(a.y1, a.y2), w: Math.abs(a.x2 - a.x1), h: Math.abs(a.y2 - a.y1) });

function drawAnnot(ctx, a) {
  ctx.save(); ctx.strokeStyle = a.c; ctx.fillStyle = a.c; ctx.lineWidth = a.w; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
  if (a.t === 'pen' || a.t === 'hl') {
    if (a.t === 'hl') { ctx.globalAlpha = .38; ctx.globalCompositeOperation = 'multiply'; ctx.lineCap = 'square'; }
    const p = a.p; ctx.beginPath(); ctx.moveTo(p[0][0], p[0][1]);
    for (let k = 1; k < p.length - 1; k++) ctx.quadraticCurveTo(p[k][0], p[k][1], (p[k][0] + p[k + 1][0]) / 2, (p[k][1] + p[k + 1][1]) / 2);
    const l = p[p.length - 1]; ctx.lineTo(l[0], l[1]); ctx.stroke();
  } else if (a.t === 'rect') { const r = norm(a); ctx.beginPath(); ctx.roundRect ? ctx.roundRect(r.x, r.y, r.w, r.h, Math.min(8, a.w * 1.5)) : ctx.rect(r.x, r.y, r.w, r.h); ctx.stroke(); }
  else if (a.t === 'ellipse') { const r = norm(a); ctx.beginPath(); ctx.ellipse(r.x + r.w / 2, r.y + r.h / 2, r.w / 2 || 1, r.h / 2 || 1, 0, 0, 7); ctx.stroke(); }
  else if (a.t === 'line' || a.t === 'arrow') {
    ctx.beginPath(); ctx.moveTo(a.x1, a.y1);
    if (a.t === 'arrow') { // سهم بنهاية معبّاة
      const ang = Math.atan2(a.y2 - a.y1, a.x2 - a.x1), L = Math.max(14, a.w * 4.2), bx = a.x2 - L * .8 * Math.cos(ang), by = a.y2 - L * .8 * Math.sin(ang);
      ctx.lineTo(bx, by); ctx.stroke(); ctx.beginPath(); ctx.moveTo(a.x2, a.y2); ctx.lineTo(a.x2 - L * Math.cos(ang - .42), a.y2 - L * Math.sin(ang - .42)); ctx.lineTo(a.x2 - L * Math.cos(ang + .42), a.y2 - L * Math.sin(ang + .42)); ctx.closePath(); ctx.fill();
    } else { ctx.lineTo(a.x2, a.y2); ctx.stroke(); }
  } else if (a.t === 'text') {
    ctx.font = `700 ${a.s}px Tajawal, sans-serif`; ctx.textBaseline = 'top'; ctx.direction = 'rtl'; ctx.textAlign = 'right';
    const lines = String(a.text).split('\n'); const wmax = Math.max(...lines.map(l => ctx.measureText(l).width));
    if (a.bg) { ctx.save(); ctx.fillStyle = a.bg; ctx.globalAlpha = .9; ctx.fillRect(a.x - wmax - a.s * .3, a.y - a.s * .15, wmax + a.s * .6, lines.length * a.s * 1.3 + a.s * .25); ctx.restore(); ctx.fillStyle = a.c; }
    else { ctx.lineWidth = Math.max(2, a.s / 7); ctx.strokeStyle = '#fff'; lines.forEach((l, i) => ctx.strokeText(l, a.x, a.y + i * a.s * 1.3)); }
    lines.forEach((l, i) => ctx.fillText(l, a.x, a.y + i * a.s * 1.3));
  } else if (a.t === 'num') {
    const r = a.r; ctx.beginPath(); ctx.arc(a.x, a.y, r, 0, 7); ctx.fill(); ctx.lineWidth = Math.max(2, r / 7); ctx.strokeStyle = '#fff'; ctx.stroke();
    ctx.fillStyle = '#fff'; ctx.font = `800 ${r * 1.15}px Tajawal, sans-serif`; ctx.textAlign = 'center'; ctx.textBaseline = 'middle'; ctx.fillText(String(a.n), a.x, a.y + r * .06);
  } else if (a.t === 'blur') {
    const r = norm(a); if (r.w > 1 && r.h > 1) { const px = Math.max(6, Math.round(Math.min(r.w, r.h) / 10), Math.round(W() / 140));
      const tw = Math.max(1, Math.round(r.w / px)), th = Math.max(1, Math.round(r.h / px)); const t = document.createElement('canvas'); t.width = tw; t.height = th;
      t.getContext('2d').drawImage(E.base, r.x, r.y, r.w, r.h, 0, 0, tw, th); ctx.imageSmoothingEnabled = false; ctx.drawImage(t, 0, 0, tw, th, r.x, r.y, r.w, r.h); }
  }
  ctx.restore();
}
function box(a) {
  if (a.p) { const xs = a.p.map(q => q[0]), ys = a.p.map(q => q[1]), m = a.w / 2; return { x: Math.min(...xs) - m, y: Math.min(...ys) - m, w: Math.max(...xs) - Math.min(...xs) + a.w, h: Math.max(...ys) - Math.min(...ys) + a.w }; }
  if (a.t === 'text') { const c = cv().getContext('2d'); c.font = `700 ${a.s}px Tajawal, sans-serif`; const lines = String(a.text).split('\n'); const w = Math.max(...lines.map(l => c.measureText(l).width)); return { x: a.x - w, y: a.y, w, h: lines.length * a.s * 1.3 }; }
  if (a.t === 'num') return { x: a.x - a.r, y: a.y - a.r, w: a.r * 2, h: a.r * 2 };
  return norm(a);
}
function moveBy(a, o, dx, dy) {
  if (o.p) a.p = o.p.map(q => [q[0] + dx, q[1] + dy]);
  else if ('x1' in o) { a.x1 = o.x1 + dx; a.x2 = o.x2 + dx; a.y1 = o.y1 + dy; a.y2 = o.y2 + dy; }
  else { a.x = o.x + dx; a.y = o.y + dy; }
}

// التراجع
const snapshot = () => ({ base: E.base, annots: JSON.stringify(E.annots), num: E.num });
function pushUndo() { E.undo.push(snapshot()); if (E.undo.length > 60) E.undo.shift(); E.redo = []; updUndo(); }
function restore(s) { const resized = s.base !== E.base; E.base = s.base; E.annots = JSON.parse(s.annots); E.num = s.num; E.sel = null; if (resized) fit(); render(); persist(); }
function undo() { if (!E.undo.length) return; E.redo.push(snapshot()); restore(E.undo.pop()); updUndo(); }
function redo() { if (!E.redo.length) return; E.undo.push(snapshot()); restore(E.redo.pop()); updUndo(); }
function updUndo() { $('#b-undo').style.opacity = E.undo.length ? 1 : .35; $('#b-redo').style.opacity = E.redo.length ? 1 : .35; }

function setTool(t) {
  E.tool = t; localStorage.setItem('snip.tool', t); E.sel = null;
  $$('.tool').forEach(b => b.classList.toggle('on', b.dataset.tool === t));
  cv().style.cursor = t === 'move' ? 'default' : t === 'text' ? 'text' : 'crosshair'; if (E.base) render();
}

// الرسم بالماوس/اللمس/القلم
function bindCanvas() {
  const c = cv(); let cur = null, pid = null, drag = null;
  const pos = (e) => { const r = c.getBoundingClientRect(); return [clamp((e.clientX - r.left) / r.width * c.width, 0, c.width), clamp((e.clientY - r.top) / r.height * c.height, 0, c.height)]; };
  c.addEventListener('pointerdown', (e) => {
    if (pid !== null || (e.button && e.button !== 0)) return;
    const [x, y] = pos(e);
    if (E.tool === 'move') {
      const hit = [...E.annots].reverse().find(a => { const b = box(a), p = 10 / E.view; return x >= b.x - p && x <= b.x + b.w + p && y >= b.y - p && y <= b.y + b.h + p; });
      E.sel = hit?.id || null; render();
      if (hit) { pid = e.pointerId; c.setPointerCapture(pid); pushUndo(); drag = { a: hit, o: JSON.parse(JSON.stringify(hit)), x, y, moved: false }; }
      return;
    }
    if (E.tool === 'text') { e.preventDefault(); return startText(x, y); }
    if (E.tool === 'num') { pushUndo(); E.annots.push({ id: uid(), t: 'num', c: E.color, x, y, r: Math.max(16, fontPx() * .75), n: E.num++ }); render(); persist(); return; }
    e.preventDefault(); pid = e.pointerId; c.setPointerCapture(pid);
    if (E.tool === 'pen' || E.tool === 'hl') cur = { id: uid(), t: E.tool, c: E.tool === 'hl' && E.color === '#e11d48' ? '#facc15' : E.color, w: E.tool === 'hl' ? lw() * 5 : lw(), p: [[x, y]] };
    else cur = { id: uid(), t: E.tool, c: E.color, w: lw(), x1: x, y1: y, x2: x, y2: y };
  });
  c.addEventListener('pointermove', (e) => {
    if (e.pointerId !== pid) return; const [x, y] = pos(e);
    if (drag) { moveBy(drag.a, drag.o, x - drag.x, y - drag.y); drag.moved = true; render(); return; }
    if (!cur) return;
    if (cur.p) { for (const ev of e.getCoalescedEvents?.() || [e]) { const q = pos(ev), l = cur.p[cur.p.length - 1]; if (Math.hypot(q[0] - l[0], q[1] - l[1]) > 1.5) cur.p.push([Math.round(q[0] * 10) / 10, Math.round(q[1] * 10) / 10]); }
      if (cur.t === 'hl' && e.shiftKey) cur.p = [cur.p[0], [x, cur.p[0][1]]]; }
    else { cur.x2 = x; cur.y2 = y; if (e.shiftKey && (cur.t === 'rect' || cur.t === 'ellipse')) { const s = Math.max(Math.abs(x - cur.x1), Math.abs(y - cur.y1)); cur.x2 = cur.x1 + Math.sign(x - cur.x1) * s; cur.y2 = cur.y1 + Math.sign(y - cur.y1) * s; } }
    render(cur);
  });
  const end = (e) => {
    if (e.pointerId !== pid) return; pid = null;
    if (drag) { if (!drag.moved) { E.undo.pop(); updUndo(); } else persist(); drag = null; render(); return; }
    if (!cur) return; const a = cur; cur = null;
    const small = a.p ? false : Math.hypot(a.x2 - a.x1, a.y2 - a.y1) < 4;
    if (a.t === 'crop') { if (!small) applyCrop(norm(a)); else render(); return; }
    if (!small) { pushUndo(); E.annots.push(a); persist(); }
    render();
  };
  c.addEventListener('pointerup', end); c.addEventListener('pointercancel', end);
  c.addEventListener('dblclick', (e) => { if (E.tool !== 'move' || !E.sel) return; const a = E.annots.find(x => x.id === E.sel); if (a?.t === 'text') editText(a); });
}
function applyCrop(r) {
  r = { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.w), h: Math.round(r.h) }; if (r.w < 4 || r.h < 4) return render();
  pushUndo();
  // نطبع الإضافات المغبّشة على الأصل قبل القص عشان ما تضيع؟ لا — بنحرّكها مع الإحداثيات
  const nb = document.createElement('canvas'); nb.width = r.w; nb.height = r.h; nb.getContext('2d').drawImage(E.base, r.x, r.y, r.w, r.h, 0, 0, r.w, r.h);
  E.annots.forEach(a => moveBy(a, JSON.parse(JSON.stringify(a)), -r.x, -r.y));
  E.base = nb; fit(); setTool('move'); persist(); toast('انقصّت الصورة');
}

// النص
function startText(x, y) { const bg = localStorage.getItem('snip.textbg') === '1'; editText({ id: uid(), t: 'text', c: bg ? '#ffffff' : E.color, bg: bg ? E.color : null, s: fontPx(), x, y: y - fontPx() * .6, text: '' }, true); }
function editText(a, isNew = false) {
  if (E.editing) return; E.editing = a.id; render();
  const el = document.createElement('div'); el.className = 'tbox'; el.contentEditable = 'true'; el.dir = 'rtl';
  const v = E.view; Object.assign(el.style, { fontSize: a.s * v + 'px', color: a.c, right: (E.base.width - a.x) * v + 'px', top: a.y * v + 'px' });
  el.textContent = a.text; $('#wrap').appendChild(el);
  setTimeout(() => { el.focus(); const r = document.createRange(); r.selectNodeContents(el); r.collapse(false); const s = getSelection(); s.removeAllRanges(); s.addRange(r); }, 20);
  el.addEventListener('keydown', (e) => { e.stopPropagation(); if (e.key === 'Escape' || (e.key === 'Enter' && (e.ctrlKey || e.metaKey))) el.blur(); });
  el.addEventListener('pointerdown', (e) => e.stopPropagation());
  el.addEventListener('blur', () => {
    const t = el.innerText.replace(/\n$/, ''); el.remove(); E.editing = null;
    if (t.trim()) { pushUndo(); a.text = t; if (isNew) E.annots.push(a); persist(); }
    else if (!isNew) { pushUndo(); E.annots = E.annots.filter(x => x !== a); persist(); }
    render();
  }, { once: true });
}

// ---------------------------------------------------------------------
//  النسخ والحفظ
// ---------------------------------------------------------------------
function finalCanvas() { const sel = E.sel; E.sel = null; render(); const c = cv(); E.sel = sel; return c; }
const toBlob = (c, type = 'image/png', q = .92) => new Promise(r => c.toBlob(r, type, q));
async function copyImage(silent = false) {
  try {
    const blob = await toBlob(finalCanvas()); render();
    await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })]);
    toast(silent ? '✓ انسخت الصورة — الصقها وين ما بدك (كنترول + V)' : '✓ انسخت الصورة');
  } catch (e) { if (!silent) toast('المتصفح ما سمح بالنسخ — استعمل «حفظ»'); }
}
async function saveImage(type = 'image/png') {
  const c = finalCanvas(); let out = c;
  if (type === 'image/jpeg') { out = document.createElement('canvas'); out.width = c.width; out.height = c.height; const x = out.getContext('2d'); x.fillStyle = '#fff'; x.fillRect(0, 0, c.width, c.height); x.drawImage(c, 0, 0); }
  const blob = await toBlob(out, type); render();
  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = `قصاصة ${stamp()}.${type === 'image/png' ? 'png' : 'jpg'}`; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 20000); toast('✓ انحفظت بالتنزيلات');
}
async function shareImage() {
  try { const blob = await toBlob(finalCanvas()); render(); const f = new File([blob], `قصاصة ${stamp()}.png`, { type: 'image/png' });
    if (navigator.canShare?.({ files: [f] })) await navigator.share({ files: [f], title: 'قصاصة' }); else { toast('المشاركة مش مدعومة هون — حفظتها بدالها'); saveImage(); }
  } catch (e) { if (e?.name !== 'AbortError') toast('ما زبطت المشاركة'); }
}

// حفظ تلقائي بالسجل (الأصل + الإضافات عشان ترجع تعدّل)
let pT = null;
function persist() {
  clearTimeout(pT); pT = setTimeout(async () => {
    if (!E.base) return;
    try {
      const base = await toBlob(E.base); const sel = E.sel; E.sel = null; render();
      const t = document.createElement('canvas'); const s = Math.min(1, 320 / Math.max(E.base.width, E.base.height)); t.width = Math.max(1, E.base.width * s); t.height = Math.max(1, E.base.height * s);
      t.getContext('2d').drawImage(cv(), 0, 0, t.width, t.height); E.sel = sel; render();
      const old = await DB.get(E.id);
      await DB.put(E.id, { id: E.id, created: old?.created || Date.now(), updated: Date.now(), base, annots: E.annots, w: E.base.width, h: E.base.height, thumb: t.toDataURL('image/jpeg', .75) });
      // نخلي آخر 60 قصاصة
      const all = (await DB.all()).sort((a, b) => b.updated - a.updated); for (const x of all.slice(60)) await DB.del(x.id);
    } catch (e) { console.warn(e); }
  }, 600);
}

// ---------------------------------------------------------------------
//  الشاشة الأولى
// ---------------------------------------------------------------------
async function home() {
  show('home'); E.base = null;
  $('#cap-box').hidden = !canCapture; $('#no-cap').hidden = canCapture;
  const all = (await DB.all().catch(() => [])).sort((a, b) => b.updated - a.updated);
  $('#clear-all').hidden = !all.length;
  $('#gallery').innerHTML = all.length ? all.map(s => `<div class="shot" data-id="${s.id}"><img src="${s.thumb}" alt=""><small>${new Date(s.updated).toLocaleString('ar-JO', { dateStyle: 'short', timeStyle: 'short' })} · ${s.w}×${s.h}</small><button class="x" data-rm="${s.id}" title="حذف">✕</button></div>`).join('')
    : '<p class="muted">ما في قصاصات لسا</p>';
}
async function reopen(id) {
  const s = await DB.get(id); if (!s) return;
  const img = await createImageBitmap(s.base); const c = document.createElement('canvas'); c.width = img.width; c.height = img.height; c.getContext('2d').drawImage(img, 0, 0);
  openEditor(c, s.annots || [], id, false);
}

function openMenu(btn) {
  const m = $('#menu'), r = btn.getBoundingClientRect();
  m.innerHTML = `<button data-m="jpg">🖼️ حفظ بصيغة JPG (حجم أصغر)</button><button data-m="share">📤 مشاركة / إرسال</button>
    <hr><button data-m="bg">🏷️ النص بخلفية ملوّنة: ${localStorage.getItem('snip.textbg') === '1' ? 'شغّال' : 'مسكّر'}</button><button data-m="resetnum">① رجّع الترقيم من ١</button>
    <button data-m="clear">🧹 مسح كل الإضافات</button><hr><button data-m="help">❓ طريقة الاستخدام</button>`;
  m.hidden = false; m.style.top = r.bottom + 6 + 'px'; m.style.left = clamp(r.left, 6, innerWidth - 250) + 'px';
  m.onclick = (e) => { const k = e.target.closest('[data-m]')?.dataset.m; if (!k) return; m.hidden = true;
    if (k === 'jpg') saveImage('image/jpeg'); if (k === 'share') shareImage();
    if (k === 'bg') { const on = localStorage.getItem('snip.textbg') === '1'; localStorage.setItem('snip.textbg', on ? '0' : '1'); toast(on ? 'النص بدون خلفية' : 'النص الجديد بخلفية ملوّنة'); }
    if (k === 'resetnum') { E.num = 1; toast('الترقيم الجاي من ١'); }
    if (k === 'clear' && E.annots.length) { pushUndo(); E.annots = []; render(); persist(); }
    if (k === 'help') toast('اختار أداة من فوق وارسم. «⬚» بتحرّك أو بتحذف (Delete). كنترول+C نسخ، كنترول+S حفظ، كنترول+Z تراجع.', 6000);
  };
}

// ---------------------------------------------------------------------
//  ربط الأزرار
// ---------------------------------------------------------------------
$('#b-cap').onclick = () => capture();
$('#b-full').onclick = () => capture({ full: true });
$$('[data-delay]').forEach(b => b.onclick = () => capture({ delay: +b.dataset.delay }));
$('#open-img').onchange = (e) => { const f = e.target.files[0]; e.target.value = ''; fromFile(f); };
$('#b-paste').onclick = async () => {
  try { const items = await navigator.clipboard.read(); for (const it of items) { const t = it.types.find(x => x.startsWith('image/')); if (t) return fromFile(new File([await it.getType(t)], 'paste', { type: t })); } toast('ما في صورة منسوخة'); }
  catch { toast('اضغط مع بعض كنترول وحرف V هون عشان تلصق'); }
};
document.addEventListener('paste', (e) => { if (e.target.closest?.('.tbox')) return; const f = [...(e.clipboardData?.files || [])].find(x => /^image\//.test(x.type)); if (f) { e.preventDefault(); fromFile(f); } });
['dragover', 'drop'].forEach(ev => document.addEventListener(ev, (e) => { e.preventDefault(); if (ev === 'drop') fromFile([...(e.dataTransfer?.files || [])][0]); }));
$('#gallery').onclick = async (e) => {
  const rm = e.target.closest('[data-rm]'); if (rm) { e.stopPropagation(); await DB.del(rm.dataset.rm); return home(); }
  const s = e.target.closest('[data-id]'); if (s) reopen(s.dataset.id);
};
$('#clear-all').onclick = async () => { if (confirm('تمسح كل القصاصات من هالجهاز؟')) { await DB.clear(); home(); } };
$('#b-home').onclick = home; $('#b-new').onclick = () => canCapture ? capture() : $('#open-img').click();
$('#tools').addEventListener('click', (e) => { const b = e.target.closest('.tool'); if (b) setTool(b.dataset.tool); });
$('#color').value = E.color; $('#color').oninput = (e) => { E.color = e.target.value; localStorage.setItem('snip.color', E.color);
  if (E.sel) { const a = E.annots.find(x => x.id === E.sel); if (a && a.t !== 'blur') { pushUndo(); a.c = E.color; render(); persist(); } } };
$('#width').value = String(E.width); $('#width').onchange = (e) => { E.width = +e.target.value; localStorage.setItem('snip.width', E.width); };
$('#b-undo').onclick = undo; $('#b-redo').onclick = redo;
$('#b-copy').onclick = () => copyImage(); $('#b-save').onclick = () => saveImage();
$('#b-more').onclick = (e) => { e.stopPropagation(); $('#menu').hidden ? openMenu(e.currentTarget) : ($('#menu').hidden = true); };
document.addEventListener('click', (e) => { if (!e.target.closest('#menu')) $('#menu').hidden = true; });
addEventListener('resize', () => { if (!$('#editor').hidden && E.base) { fit(); render(); } });
document.addEventListener('keydown', (e) => {
  if (!$('#crop').hidden) { if (e.key === 'Escape') home(); if (e.key === 'Enter') finishCrop(null); return; }
  if (e.target.closest?.('input,select,.tbox')) return;
  const k = e.key.toLowerCase(), c = e.ctrlKey || e.metaKey;
  if ($('#editor').hidden) { if (c && k === 'n') { e.preventDefault(); capture(); } return; }
  if (c && k === 'c') { e.preventDefault(); copyImage(); }
  else if (c && k === 's') { e.preventDefault(); saveImage(); }
  else if (c && k === 'z') { e.preventDefault(); e.shiftKey ? redo() : undo(); }
  else if (c && k === 'y') { e.preventDefault(); redo(); }
  else if (c && k === 'n') { e.preventDefault(); capture(); }
  else if (c) return;
  else if ((k === 'delete' || k === 'backspace') && E.sel) { pushUndo(); E.annots = E.annots.filter(a => a.id !== E.sel); E.sel = null; render(); persist(); }
  else if (k === 'escape') { E.sel = null; render(); }
  else { const map = { v: 'move', p: 'pen', h: 'hl', a: 'arrow', r: 'rect', o: 'ellipse', l: 'line', t: 'text', n: 'num', b: 'blur', c: 'crop' }; if (map[k]) setTool(map[k]); }
});
if ('serviceWorker' in navigator) navigator.serviceWorker.register('./sw.js').catch(() => {});
if ('launchQueue' in window) launchQueue.setConsumer(async (p) => { const h = p.files?.[0]; if (h) fromFile(await h.getFile()); });
bindCanvas(); home();
window.__snip = { startCrop, E };
