// =====================================================================
//  السمو PDF — قارئ ومحرّر PDF عربي (بيشتغل بالمتصفح وبدون إنترنت)
//  العرض: pdf.js — الحفظ: pdf-lib — التخزين: IndexedDB على الجهاز
// =====================================================================
import * as pdfjsLib from './lib/pdf.min.mjs';
pdfjsLib.GlobalWorkerOptions.workerSrc = './lib/pdf.worker.min.mjs';
const PDFJS_OPTS = { cMapUrl: './lib/cmaps/', cMapPacked: true, standardFontDataUrl: './lib/standard_fonts/' };

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const uid = () => Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const DPR = () => Math.min(window.devicePixelRatio || 1, 3);
const A4 = [595.28, 841.89];

function toast(t, ms = 2400) { const el = $('#toast'); el.textContent = t; el.style.display = 'block'; clearTimeout(toast.t); toast.t = setTimeout(() => el.style.display = 'none', ms); }
function busy(on, txt = 'لحظة…') { let b = $('.busy'); if (on) { if (!b) { b = document.createElement('div'); b.className = 'busy'; document.body.appendChild(b); } b.textContent = txt; } else b?.remove(); }

// ---------------------------------------------------------------------
//  التخزين على الجهاز (IndexedDB)
// ---------------------------------------------------------------------
const DB = {
  db: null,
  async open() {
    if (this.db) return this.db;
    this.db = await new Promise((res, rej) => {
      const r = indexedDB.open('sumou-pdf', 1);
      r.onupgradeneeded = () => { const d = r.result; d.createObjectStore('docs'); d.createObjectStore('meta'); };
      r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error);
    });
    return this.db;
  },
  async tx(store, mode, fn) { const d = await this.open(); return new Promise((res, rej) => { const t = d.transaction(store, mode); const s = t.objectStore(store); const out = fn(s); t.oncomplete = () => res(out?.result ?? out); t.onerror = () => rej(t.error); }); },
  get(store, k) { return this.tx(store, 'readonly', s => s.get(k)); },
  put(store, k, v) { return this.tx(store, 'readwrite', s => s.put(v, k)); },
  del(store, k) { return this.tx(store, 'readwrite', s => s.delete(k)); },
  async all(store) { const d = await this.open(); return new Promise((res, rej) => { const out = []; const r = d.transaction(store).objectStore(store).openCursor(); r.onsuccess = () => { const c = r.result; if (c) { out.push(c.value); c.continue(); } else res(out); }; r.onerror = () => rej(r.error); }); },
};

// ---------------------------------------------------------------------
//  الحالة
// ---------------------------------------------------------------------
const S = {
  doc: null,            // { id, name, fp, sources:[{bytes, pdf}], pages:[...] }
  scale: 1, fit: 'width', zoom: 1,
  tool: 'hand', shape: 'rect', color: localStorage.getItem('pdf.color') || '#d0021b', width: +(localStorage.getItem('pdf.width') || 2),
  penOnly: localStorage.getItem('pdf.penOnly') === '1', cur: 0,
  undo: [], redo: [], sel: null, present: false,
};
// صفحة: { id, src (رقم المصدر أو null للفاضية), idx, rot (تدوير إضافي), blank: 'plain'|'grid'|'lines'|null, bw, bh (المقاس بدون التدوير الإضافي), annots: [] }
const dispSize = (p) => (p.rot % 180 ? [p.bh, p.bw] : [p.bw, p.bh]);

// ---------------------------------------------------------------------
//  فتح الملفات
// ---------------------------------------------------------------------
async function loadPdf(bytes) { return pdfjsLib.getDocument({ data: bytes.slice(), ...PDFJS_OPTS }).promise; }

async function pagesFromPdf(pdf, srcIdx) {
  const out = [];
  for (let i = 1; i <= pdf.numPages; i++) {
    const pg = await pdf.getPage(i); const vp = pg.getViewport({ scale: 1 });
    out.push({ id: uid(), src: srcIdx, idx: i - 1, rot: 0, blank: null, bw: vp.width, bh: vp.height, annots: [] });
  }
  return out;
}

async function openBytes(bytes, name) {
  busy(true, 'جاري فتح الملف…');
  try {
    const pdf = await loadPdf(bytes);
    const fp = pdf.fingerprints?.[0] || null;
    const metas = await DB.all('meta');
    const prev = fp && metas.find(m => m.fp === fp);
    if (prev) {
      busy(false);
      const ok = await ask(`عندك تعديلات محفوظة على «${prev.name}» من ${new Date(prev.updated).toLocaleString('ar-JO')}. بدك تكمّل عليها؟`, 'كمّل على تعديلاتي', 'افتحه من جديد');
      if (ok) return openSaved(prev.id);
      busy(true, 'جاري فتح الملف…');
    }
    const doc = { id: uid(), name: name.replace(/\.pdf$/i, ''), fp, sources: [{ bytes, pdf }], pages: await pagesFromPdf(pdf, 0) };
    await showDoc(doc); persist(true);
  } catch (e) {
    console.error(e);
    toast(/password/i.test(e?.name + e?.message) ? 'الملف محمي بكلمة سر — هالنسخة ما بتفتح ملفات محمية لسا' : 'ما قدرت أفتح الملف — يمكن يكون تالف');
  } finally { busy(false); }
}

async function openSaved(id) {
  busy(true, 'جاري الفتح…');
  try {
    const d = await DB.get('docs', id); if (!d) return toast('الملف مش موجود');
    const sources = []; for (const b of d.sources) sources.push({ bytes: b, pdf: await loadPdf(b) });
    await showDoc({ id: d.id, name: d.name, fp: d.fp, sources, pages: d.pages });
  } catch (e) { console.error(e); toast('ما قدرت أفتح الملف'); } finally { busy(false); }
}

function newNotebook() {
  const d = new Date();
  const doc = { id: uid(), name: `دفتر ${d.toLocaleDateString('ar-JO')}`, fp: null, sources: [],
    pages: [{ id: uid(), src: null, idx: 0, rot: 0, blank: 'grid', bw: A4[0], bh: A4[1], annots: [] }] };
  showDoc(doc).then(() => { persist(true); setTool('pen'); });
}

// ---------------------------------------------------------------------
//  الحفظ التلقائي
// ---------------------------------------------------------------------
let saveT = null;
function persist(now = false) {
  if (!S.doc) return;
  clearTimeout(saveT);
  const run = async () => {
    const d = S.doc; if (!d) return;
    const pages = d.pages.map(p => ({ ...p }));
    try {
      await DB.put('docs', d.id, { id: d.id, name: d.name, fp: d.fp, sources: d.sources.map(s => s.bytes), pages });
      await DB.put('meta', d.id, { id: d.id, name: d.name, fp: d.fp, updated: Date.now(), pages: pages.length, size: d.sources.reduce((a, s) => a + s.bytes.byteLength, 0) });
    } catch (e) { console.warn('save', e); toast('ما قدرت أحفظ التعديلات على الجهاز (المساحة ممتلئة؟)'); }
  };
  if (now) run(); else saveT = setTimeout(run, 700);
}

// ---------------------------------------------------------------------
//  التراجع والإعادة
// ---------------------------------------------------------------------
const snap = () => JSON.stringify(S.doc.pages);
function pushUndo() { S.undo.push(snap()); if (S.undo.length > 80) S.undo.shift(); S.redo = []; updUndo(); }
function applySnap(json) { S.doc.pages = JSON.parse(json); S.sel = null; layout(); renderThumbs(); persist(); }
function undo() { if (!S.undo.length) return; S.redo.push(snap()); applySnap(S.undo.pop()); updUndo(); }
function redo() { if (!S.redo.length) return; S.undo.push(snap()); applySnap(S.redo.pop()); updUndo(); }
function updUndo() { $('#b-undo').disabled = !S.undo.length; $('#b-redo').disabled = !S.redo.length; $('#b-undo').style.opacity = S.undo.length ? 1 : .35; $('#b-redo').style.opacity = S.redo.length ? 1 : .35; }

// ---------------------------------------------------------------------
//  عرض المستند
// ---------------------------------------------------------------------
const pagesEl = () => $('#pages');
let io = null;

async function showDoc(doc) {
  S.doc = doc; S.undo = []; S.redo = []; S.sel = null; S.cur = 0; S.fit = 'width'; S.zoom = 1; textCache.clear(); searchHits = [];
  $('#home').hidden = true; $('#viewer').hidden = false;
  $('#doc-name').textContent = doc.name; document.title = doc.name + ' — السمو PDF';
  history.replaceState(null, '', '#' + doc.id);
  if (innerWidth > 900) $('#side').hidden = false;
  updUndo(); layout(); renderThumbs(); setTool(S.tool);
}

function computeScale() {
  const el = pagesEl(); const avail = Math.max(200, el.clientWidth - 24);
  const maxW = Math.max(...S.doc.pages.map(p => dispSize(p)[0]));
  let base;
  if (S.present) {
    const p = S.doc.pages[S.cur], [w, h] = dispSize(p);
    base = Math.min((innerWidth - 10) / w, (innerHeight - 10) / h);
    return base;
  }
  if (S.fit === 'page') { const p = S.doc.pages[S.cur] || S.doc.pages[0]; const [w, h] = dispSize(p); base = Math.min(avail / w, (el.clientHeight - 30) / h); }
  else base = avail / maxW;
  return base * S.zoom;
}

function layout() {
  if (!S.doc) return;
  const el = pagesEl();
  S.scale = computeScale();
  io?.disconnect();
  io = new IntersectionObserver((ents) => ents.forEach(e => { if (e.isIntersecting) renderPage(+e.target.dataset.i); }), { root: el, rootMargin: '600px 0px' });
  const keep = new Map($$('.page', el).map(d => [d.dataset.pid, d]));
  const frag = document.createDocumentFragment();
  S.doc.pages.forEach((p, i) => {
    const [w, h] = dispSize(p);
    let d = keep.get(p.id);
    if (!d) {
      d = document.createElement('div'); d.className = 'page'; d.dataset.pid = p.id;
      d.innerHTML = `<canvas class="pdf"></canvas><div class="textLayer"></div><canvas class="ann"></canvas><div class="num"></div>`;
      attachPointer(d);
    }
    keep.delete(p.id);
    d.dataset.i = i; d.style.width = Math.round(w * S.scale) + 'px'; d.style.height = Math.round(h * S.scale) + 'px';
    d.querySelector('.num').textContent = `${i + 1}`;
    if (d._key !== keyOf(p)) d._rendered = null;
    d.classList.toggle('show', S.present && i === S.cur);
    frag.appendChild(d); io.observe(d);
  });
  keep.forEach(d => d.remove());
  el.appendChild(frag);
  $('#pg-n').textContent = S.doc.pages.length; $('#side-n').textContent = S.doc.pages.length + ' صفحة';
  $('#b-zoom').textContent = Math.round(S.scale * 100 / (96 / 72)) + '%';
  updCur(); applyToolClass();
  if (S.present) renderPage(S.cur);
}
const keyOf = (p) => `${p.src}|${p.idx}|${p.rot}|${p.blank}`;

async function renderPage(i) {
  const p = S.doc.pages[i]; if (!p) return;
  const d = $(`.page[data-pid="${p.id}"]`); if (!d) return;
  const want = `${S.scale.toFixed(4)}|${keyOf(p)}|${DPR()}`;
  if (d._rendered === want) { drawAnn(d, p); return; }
  d._rendered = want; d._key = keyOf(p);
  const [w, h] = dispSize(p); const cssW = w * S.scale, cssH = h * S.scale;
  let r = DPR(); const maxPx = 16e6; if (cssW * cssH * r * r > maxPx) r = Math.sqrt(maxPx / (cssW * cssH));
  const cv = d.querySelector('canvas.pdf'), tl = d.querySelector('.textLayer');
  if (p.src == null) { // صفحة فاضية
    cv.width = Math.round(cssW * r); cv.height = Math.round(cssH * r);
    const ctx = cv.getContext('2d'); ctx.setTransform(r, 0, 0, r, 0, 0); drawBlank(ctx, p.blank, cssW, cssH, S.scale); tl.innerHTML = '';
  } else {
    const src = S.doc.sources[p.src]; const pg = await src.pdf.getPage(p.idx + 1);
    if (d._rendered !== want) return;
    const vp = pg.getViewport({ scale: S.scale, rotation: (pg.rotate + p.rot) % 360 });
    const tmp = document.createElement('canvas'); tmp.width = Math.round(vp.width * r); tmp.height = Math.round(vp.height * r);
    d._task?.cancel?.();
    const task = pg.render({ canvasContext: tmp.getContext('2d'), viewport: vp, transform: r !== 1 ? [r, 0, 0, r, 0, 0] : null });
    d._task = task;
    try { await task.promise; } catch (e) { if (e?.name !== 'RenderingCancelledException') console.warn(e); return; }
    if (d._rendered !== want) return;
    cv.width = tmp.width; cv.height = tmp.height; cv.getContext('2d').drawImage(tmp, 0, 0);
    // طبقة النص (للنسخ والبحث)
    tl.innerHTML = ''; tl.style.setProperty('--scale-factor', vp.scale);
    try {
      const tc = await pg.getTextContent();
      if (d._rendered !== want) return;
      await new pdfjsLib.TextLayer({ textContentSource: tc, container: tl, viewport: vp }).render();
      markHits(i, d);
    } catch (e) { console.warn('text', e); }
  }
  drawAnn(d, p);
}

function drawBlank(ctx, kind, W, H, sc) {
  ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, W, H);
  if (kind === 'grid' || kind === 'lines') {
    const step = (kind === 'grid' ? 18 : 24) * sc; ctx.strokeStyle = kind === 'grid' ? '#dfe7f2' : '#cfdcec'; ctx.lineWidth = Math.max(.5, .6 * sc);
    ctx.beginPath();
    for (let y = step * (kind === 'lines' ? 3 : 1); y < H; y += step) { ctx.moveTo(0, y); ctx.lineTo(W, y); }
    if (kind === 'grid') for (let x = step; x < W; x += step) { ctx.moveTo(x, 0); ctx.lineTo(x, H); }
    ctx.stroke();
    if (kind === 'lines') { ctx.strokeStyle = '#f0b4b4'; ctx.beginPath(); ctx.moveTo(W - 50 * sc, 0); ctx.lineTo(W - 50 * sc, H); ctx.stroke(); }
  }
}

// ---------------------------------------------------------------------
//  رسم الإضافات (نفس الدالة للشاشة وللحفظ)
// ---------------------------------------------------------------------
const imgCache = new Map();
function getImg(src) { let im = imgCache.get(src); if (!im) { im = new Image(); im.src = src; imgCache.set(src, im); im.onload = () => { $$('.page').forEach(d => { const p = S.doc?.pages[+d.dataset.i]; if (p) drawAnn(d, p); }); }; } return im; }

function wrapLines(ctx, text, maxW) {
  const out = [];
  for (const para of String(text).split('\n')) {
    const words = para.split(/(\s+)/); let line = '';
    for (const w of words) { const t = line + w; if (ctx.measureText(t).width > maxW && line.trim()) { out.push(line.trimEnd()); line = w.trimStart(); } else line = t; }
    out.push(line);
  }
  return out;
}

function drawAnnots(ctx, annots, W, H, skipId = null) {
  for (const a of annots) {
    if (a.id === skipId) continue;
    ctx.save();
    const lw = (a.w || 0.003) * W;
    if (a.t === 'pen' || a.t === 'hl') {
      ctx.strokeStyle = a.c; ctx.lineCap = a.t === 'hl' ? 'butt' : 'round'; ctx.lineJoin = 'round';
      if (a.t === 'hl') { ctx.globalAlpha = .35; ctx.globalCompositeOperation = 'multiply'; }
      const pts = a.p;
      if (pts.length === 1) { ctx.fillStyle = a.c; ctx.beginPath(); ctx.arc(pts[0][0] * W, pts[0][1] * H, lw / 2, 0, 7); ctx.fill(); }
      else if (a.t === 'pen' && pts.some(q => q[2] != null && q[2] !== .5)) { // عرض متغيّر حسب ضغط القلم
        for (let k = 1; k < pts.length; k++) { const q0 = pts[k - 1], q1 = pts[k];
          ctx.lineWidth = lw * (0.35 + 1.3 * ((q0[2] ?? .5) + (q1[2] ?? .5)) / 2); ctx.beginPath(); ctx.moveTo(q0[0] * W, q0[1] * H); ctx.lineTo(q1[0] * W, q1[1] * H); ctx.stroke(); }
      } else {
        ctx.lineWidth = lw; ctx.beginPath(); ctx.moveTo(pts[0][0] * W, pts[0][1] * H);
        for (let k = 1; k < pts.length - 1; k++) { const mx = (pts[k][0] + pts[k + 1][0]) / 2, my = (pts[k][1] + pts[k + 1][1]) / 2; ctx.quadraticCurveTo(pts[k][0] * W, pts[k][1] * H, mx * W, my * H); }
        const l = pts[pts.length - 1]; ctx.lineTo(l[0] * W, l[1] * H); ctx.stroke();
      }
    } else if (a.t === 'shape') {
      ctx.strokeStyle = a.c; ctx.lineWidth = lw; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
      const x1 = a.x1 * W, y1 = a.y1 * H, x2 = a.x2 * W, y2 = a.y2 * H;
      ctx.beginPath();
      if (a.k === 'rect') ctx.rect(Math.min(x1, x2), Math.min(y1, y2), Math.abs(x2 - x1), Math.abs(y2 - y1));
      else if (a.k === 'ellipse') ctx.ellipse((x1 + x2) / 2, (y1 + y2) / 2, Math.abs(x2 - x1) / 2 || .5, Math.abs(y2 - y1) / 2 || .5, 0, 0, 7);
      else { ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); }
      ctx.stroke();
      if (a.k === 'arrow') { const ang = Math.atan2(y2 - y1, x2 - x1), L = Math.max(10, lw * 4.5);
        ctx.beginPath(); ctx.moveTo(x2, y2); ctx.lineTo(x2 - L * Math.cos(ang - .45), y2 - L * Math.sin(ang - .45)); ctx.moveTo(x2, y2); ctx.lineTo(x2 - L * Math.cos(ang + .45), y2 - L * Math.sin(ang + .45)); ctx.stroke(); }
    } else if (a.t === 'text') {
      const fs = a.s * W; ctx.font = `${a.b ? '700 ' : ''}${fs}px Tajawal, sans-serif`; ctx.fillStyle = a.c; ctx.textBaseline = 'top';
      ctx.direction = 'rtl'; ctx.textAlign = 'right';
      const lines = wrapLines(ctx, a.text, a.bw * W); const x = (a.x + a.bw) * W; let y = a.y * H + fs * .12;
      if (a.bg) { ctx.save(); ctx.fillStyle = a.bg; ctx.globalAlpha = .85; ctx.fillRect(a.x * W - 2, a.y * H - 2, a.bw * W + 4, lines.length * fs * 1.35 + 4); ctx.restore(); }
      for (const ln of lines) { ctx.fillText(ln, x, y); y += fs * 1.35; }
    } else if (a.t === 'img') {
      const im = getImg(a.src); if (im.complete && im.naturalWidth) ctx.drawImage(im, a.x * W, a.y * H, a.bw * W, a.bh * H);
    }
    ctx.restore();
  }
}

function annBox(a, W = 1, H = 1) {
  if (a.t === 'pen' || a.t === 'hl') { const xs = a.p.map(q => q[0]), ys = a.p.map(q => q[1]); const m = (a.w || .003) * (a.t === 'hl' ? .5 : 1);
    return { x: Math.min(...xs) - m, y: Math.min(...ys) - m * W / H, w: Math.max(...xs) - Math.min(...xs) + 2 * m, h: Math.max(...ys) - Math.min(...ys) + 2 * m * W / H }; }
  if (a.t === 'shape') return { x: Math.min(a.x1, a.x2), y: Math.min(a.y1, a.y2), w: Math.abs(a.x2 - a.x1), h: Math.abs(a.y2 - a.y1) };
  if (a.t === 'text') { const lines = Math.max(1, String(a.text).split('\n').length + Math.floor(String(a.text).length / Math.max(8, a.bw / (a.s * .5)))); return { x: a.x, y: a.y, w: a.bw, h: a.th || (lines * a.s * 1.35 * W / H) }; }
  return { x: a.x, y: a.y, w: a.bw, h: a.bh };
}

function drawAnn(d, p, live = null) {
  const cv = d.querySelector('canvas.ann'); const cssW = parseFloat(d.style.width), cssH = parseFloat(d.style.height); const r = DPR();
  const W = Math.round(cssW * r), H = Math.round(cssH * r);
  if (cv.width !== W || cv.height !== H) { cv.width = W; cv.height = H; }
  const ctx = cv.getContext('2d'); ctx.clearRect(0, 0, W, H);
  drawAnnots(ctx, p.annots, W, H, S.editing?.id);
  if (live) drawAnnots(ctx, [live], W, H);
  updSelBox(d, p);
}

// ---------------------------------------------------------------------
//  الأدوات والرسم
// ---------------------------------------------------------------------
const DRAW_TOOLS = ['pen', 'hl', 'eraser', 'shape', 'text', 'sign', 'select'];
function setTool(t) {
  S.tool = t; S.sel = null;
  $$('.tool').forEach(b => b.classList.toggle('on', b.dataset.tool === t));
  const sb = $('#subbar');
  if (t === 'shape') {
    sb.hidden = false; sb.innerHTML = [['rect', '▭ مربع'], ['ellipse', '◯ دائرة'], ['line', '╱ خط'], ['arrow', '↗ سهم']].map(([k, l]) => `<button class="chip ${S.shape === k ? 'on' : ''}" data-shape="${k}">${l}</button>`).join('');
    sb.onclick = (e) => { const b = e.target.closest('[data-shape]'); if (b) { S.shape = b.dataset.shape; setTool('shape'); } };
  } else if (!searchOpen) sb.hidden = true;
  applyToolClass(); $$('.page').forEach(d => { const p = S.doc?.pages[+d.dataset.i]; if (p) updSelBox(d, p); });
}
function applyToolClass() {
  const draw = DRAW_TOOLS.includes(S.tool);
  $$('.page').forEach(d => { d.classList.toggle('drawing', draw); d.classList.toggle('pen-only', draw && S.penOnly);
    const ann = d.querySelector('canvas.ann'); ann.style.pointerEvents = draw ? 'auto' : 'none';
    ann.style.cursor = S.tool === 'select' ? 'default' : S.tool === 'text' ? 'text' : draw ? 'crosshair' : ''; });
}
const relW = () => ({ 1: .0016, 2: .003, 4: .0055, 7: .0095 }[S.width] || .003);
const textSize = () => ({ 1: .018, 2: .024, 4: .032, 7: .045 }[S.width] || .024);

function attachPointer(d) {
  const ann = d.querySelector('canvas.ann');
  let cur = null, pid = null, dragSel = null;
  const pos = (e) => { const r = ann.getBoundingClientRect(); return [clamp((e.clientX - r.left) / r.width, 0, 1), clamp((e.clientY - r.top) / r.height, 0, 1)]; };
  const page = () => S.doc.pages[+d.dataset.i];
  // آيباد: قلم أبل بيرسم، والإصبع بيحرّك الصفحة
  const stylusGuard = (e) => { if (DRAW_TOOLS.includes(S.tool) && [...e.touches].some(t => t.touchType === 'stylus')) e.preventDefault(); };
  ann.addEventListener('touchstart', stylusGuard, { passive: false }); ann.addEventListener('touchmove', stylusGuard, { passive: false });

  ann.addEventListener('pointerdown', (e) => {
    if (!DRAW_TOOLS.includes(S.tool) || pid !== null) return;
    if (e.pointerType === 'pen' && !S.penOnly) { S.penOnly = true; localStorage.setItem('pdf.penOnly', '1'); applyToolClass(); toast('✍️ انكشف القلم: الإصبع صار للتحريك، والقلم للكتابة (بتغيّرها من ⋯)'); }
    if (S.penOnly && e.pointerType === 'touch') return;
    if (e.button && e.button !== 0) return;
    const p = page(); const [x, y] = pos(e); const pr = e.pointerType === 'pen' ? (e.pressure || .5) : .5;
    S.cur = +d.dataset.i; updCur();
    if (S.tool === 'select') {
      const W = ann.width, H = ann.height;
      const hit = [...p.annots].reverse().find(a => { const b = annBox(a, W, H); const pad = .012; return x >= b.x - pad && x <= b.x + b.w + pad && y >= b.y - pad && y <= b.y + b.h + pad; });
      S.sel = hit ? { page: p.id, id: hit.id } : null; drawAnn(d, p);
      if (hit) { pushUndo(); dragSel = { a: hit, x, y, orig: JSON.parse(JSON.stringify(hit)) }; pid = e.pointerId; ann.setPointerCapture(pid); }
      return;
    }
    if (S.tool === 'text') { e.preventDefault(); startText(d, p, x, y); return; }
    if (S.tool === 'sign') { e.preventDefault(); placeSignature(d, p, x, y); return; }
    e.preventDefault(); pid = e.pointerId; ann.setPointerCapture(pid);
    if (S.tool === 'eraser') { pushUndo(); cur = { eraser: true, any: false }; cur.any = eraseAt(d, p, x, y); return; }
    if (S.tool === 'shape') { cur = { id: uid(), t: 'shape', k: S.shape, c: S.color, w: relW(), x1: x, y1: y, x2: x, y2: y }; return; }
    cur = { id: uid(), t: S.tool, c: S.color, w: S.tool === 'hl' ? relW() * 5 : relW(), p: [[x, y, pr]] };
  });
  ann.addEventListener('pointermove', (e) => {
    if (e.pointerId !== pid) return;
    const p = page(); const [x, y] = pos(e);
    if (dragSel) { moveAnn(dragSel.a, dragSel.orig, x - dragSel.x, y - dragSel.y); drawAnn(d, p); return; }
    if (!cur) return;
    if (cur.eraser) { if (eraseAt(d, p, x, y)) cur.any = true; return; }
    if (cur.t === 'shape') { cur.x2 = x; cur.y2 = y; if (e.shiftKey && cur.k !== 'line' && cur.k !== 'arrow') { const W = ann.width, H = ann.height; const s = Math.max(Math.abs(x - cur.x1) * W, Math.abs(y - cur.y1) * H); cur.x2 = cur.x1 + Math.sign(x - cur.x1) * s / W; cur.y2 = cur.y1 + Math.sign(y - cur.y1) * s / H; } }
    else {
      const evs = e.getCoalescedEvents?.() || [e];
      for (const ev of evs) { const q = pos(ev); const l = cur.p[cur.p.length - 1]; if (Math.hypot(q[0] - l[0], q[1] - l[1]) > .0008) cur.p.push([+q[0].toFixed(5), +q[1].toFixed(5), ev.pointerType === 'pen' ? +(ev.pressure || .5).toFixed(2) : .5]); }
      if (cur.t === 'hl') { cur.p = [cur.p[0], cur.p[cur.p.length - 1]]; cur.p[1][1] = cur.p[0][1]; } // التظليل خط مستقيم أفقي
    }
    drawAnn(d, p, cur);
  });
  const end = (e) => {
    if (e.pointerId !== pid) return; pid = null;
    const p = page();
    if (dragSel) { if (JSON.stringify(dragSel.a) === JSON.stringify(dragSel.orig)) S.undo.pop(), updUndo(); else { persist(); renderThumb(+d.dataset.i); } dragSel = null; drawAnn(d, p); return; }
    if (!cur) return;
    if (cur.eraser) { if (!cur.any) { S.undo.pop(); updUndo(); } else { persist(); renderThumb(+d.dataset.i); } cur = null; return; }
    const tiny = cur.t === 'shape' ? Math.hypot(cur.x2 - cur.x1, cur.y2 - cur.y1) < .004 : false;
    if (!tiny) { pushUndo(); p.annots.push(cur); persist(); renderThumb(+d.dataset.i); }
    cur = null; drawAnn(d, p);
  };
  ann.addEventListener('pointerup', end); ann.addEventListener('pointercancel', end);
  ann.addEventListener('dblclick', (e) => {
    if (S.tool !== 'select') return; const p = page(); const a = p.annots.find(x => x.id === S.sel?.id);
    if (a?.t === 'text') editText(d, p, a);
  });
}

function moveAnn(a, o, dx, dy) {
  if (a.p) a.p = o.p.map(q => [q[0] + dx, q[1] + dy, q[2]]);
  else if (a.t === 'shape') { a.x1 = o.x1 + dx; a.x2 = o.x2 + dx; a.y1 = o.y1 + dy; a.y2 = o.y2 + dy; }
  else { a.x = o.x + dx; a.y = o.y + dy; }
}
function scaleAnn(a, o, box, f) {   // تكبير من الزاوية العليا
  const sx = (v) => box.x + (v - box.x) * f, sy = (v) => box.y + (v - box.y) * f;
  if (a.p) { a.p = o.p.map(q => [sx(q[0]), sy(q[1]), q[2]]); a.w = o.w * f; }
  else if (a.t === 'shape') { a.x1 = sx(o.x1); a.x2 = sx(o.x2); a.y1 = sy(o.y1); a.y2 = sy(o.y2); }
  else if (a.t === 'text') { a.s = o.s * f; a.bw = o.bw * f; a.x = sx(o.x + o.bw) - a.bw; a.y = sy(o.y); a.th = o.th ? o.th * f : o.th; }
  else { a.bw = o.bw * f; a.bh = o.bh * f; a.x = sx(o.x + o.bw) - a.bw; a.y = sy(o.y); }
}

function eraseAt(d, p, x, y) {
  const W = parseFloat(d.style.width), H = parseFloat(d.style.height), R = 12 / W;
  const before = p.annots.length;
  p.annots = p.annots.filter(a => {
    if (a.p) return !a.p.some((q, k) => { const n = a.p[k + 1] || q; return distSeg(x, y * H / W, q[0], q[1] * H / W, n[0], n[1] * H / W) < R + (a.w || 0) / 2; });
    if (a.t === 'shape') {
      if (a.k === 'line' || a.k === 'arrow') return distSeg(x, y * H / W, a.x1, a.y1 * H / W, a.x2, a.y2 * H / W) > R + a.w;
      const b = annBox(a); return !(x > b.x - R && x < b.x + b.w + R && y > b.y - R && y < b.y + b.h + R) || (x > b.x + R && x < b.x + b.w - R && y > b.y + R && y < b.y + b.h - R && a.k === 'rect');
    }
    const b = annBox(a, W, H); return !(x >= b.x && x <= b.x + b.w && y >= b.y && y <= b.y + b.h);
  });
  if (p.annots.length !== before) { drawAnn(d, p); return true; }
  return false;
}
function distSeg(px, py, x1, y1, x2, y2) { const dx = x2 - x1, dy = y2 - y1, L = dx * dx + dy * dy; let t = L ? ((px - x1) * dx + (py - y1) * dy) / L : 0; t = clamp(t, 0, 1); return Math.hypot(px - (x1 + t * dx), py - (y1 + t * dy)); }

// مربع التحديد + أدواته
function updSelBox(d, p) {
  d.querySelectorAll('.sel-box,.sel-tools').forEach(x => x.remove());
  if (!S.sel || S.sel.page !== p.id || S.tool !== 'select') return;
  const a = p.annots.find(x => x.id === S.sel.id); if (!a) return;
  const W = parseFloat(d.style.width), H = parseFloat(d.style.height); const b = annBox(a, W, H);
  const box = document.createElement('div'); box.className = 'sel-box';
  Object.assign(box.style, { left: b.x * W - 4 + 'px', top: b.y * H - 4 + 'px', width: b.w * W + 8 + 'px', height: b.h * H + 8 + 'px' });
  box.innerHTML = '<div class="h" title="تكبير/تصغير"></div>'; d.appendChild(box);
  const tools = document.createElement('div'); tools.className = 'sel-tools';
  Object.assign(tools.style, { left: Math.max(0, b.x * W) + 'px', top: Math.max(0, b.y * H - 46) + 'px' });
  tools.innerHTML = `${a.t === 'text' ? '<button data-a="edit">✏️ تعديل</button>' : ''}<button data-a="color" title="لون">🎨</button><button data-a="dup" title="نسخ">⧉</button><button data-a="front" title="للأمام">⬆</button><button data-a="del" title="حذف">🗑️</button>`;
  d.appendChild(tools);
  tools.onpointerdown = (e) => e.stopPropagation();
  tools.onclick = (e) => {
    const k = e.target.closest('[data-a]')?.dataset.a; if (!k) return;
    pushUndo();
    if (k === 'del') { p.annots = p.annots.filter(x => x !== a); S.sel = null; }
    if (k === 'dup') { const c = JSON.parse(JSON.stringify(a)); c.id = uid(); moveAnn(c, JSON.parse(JSON.stringify(c)), .02, .02); p.annots.push(c); S.sel = { page: p.id, id: c.id }; }
    if (k === 'front') { p.annots = p.annots.filter(x => x !== a).concat(a); }
    if (k === 'color') { if (a.t !== 'img') a.c = S.color; else S.undo.pop(); }
    if (k === 'edit') { S.undo.pop(); updUndo(); return editText(d, p, a); }
    updUndo(); persist(); drawAnn(d, p); renderThumb(+d.dataset.i);
  };
  // تكبير من المقبض
  const h = box.querySelector('.h');
  h.onpointerdown = (e) => {
    e.stopPropagation(); e.preventDefault(); h.setPointerCapture(e.pointerId); pushUndo();
    const o = JSON.parse(JSON.stringify(a)), ob = annBox(o, W, H), r0 = d.getBoundingClientRect();
    const right = ob.x + ob.w;  // الزاوية اليسرى تحت: بنكبّر لليسار وتحت
    h.onpointermove = (ev) => {
      const x = (ev.clientX - r0.left) / W, y = (ev.clientY - r0.top) / H;
      const f = clamp(Math.max((right - x) / ob.w, (y - ob.y) / ob.h), .15, 8);
      scaleAnn(a, o, { x: right, y: ob.y }, f); drawAnn(d, p);
    };
    h.onpointerup = () => { h.onpointermove = null; persist(); renderThumb(+d.dataset.i); };
  };
}

// النص
function startText(d, p, x, y) {
  const a = { id: uid(), t: 'text', c: S.color, s: textSize(), b: false, x: clamp(x - .3, 0, .7), y, bw: .3, text: '' };
  // صندوق النص بيبدأ من مكان الضغط ويمتد لليسار (عربي)
  a.x = clamp(x - a.bw, 0, 1 - a.bw);
  editText(d, p, a, true);
}
function editText(d, p, a, isNew = false) {
  if (S.editing) return;
  S.editing = a; drawAnn(d, p);
  const W = parseFloat(d.style.width), H = parseFloat(d.style.height);
  const el = document.createElement('div'); el.className = 'tbox'; el.contentEditable = 'true';
  Object.assign(el.style, { left: a.x * W + 'px', top: a.y * H + 'px', width: a.bw * W + 'px', fontSize: a.s * W + 'px', color: a.c, fontWeight: a.b ? 700 : 400 });
  el.textContent = a.text; d.appendChild(el);
  setTimeout(() => { el.focus(); const r = document.createRange(); r.selectNodeContents(el); r.collapse(false); const s = getSelection(); s.removeAllRanges(); s.addRange(r); }, 30);
  el.addEventListener('pointerdown', (e) => e.stopPropagation());
  el.addEventListener('keydown', (e) => { if (e.key === 'Escape') el.blur(); e.stopPropagation(); });
  el.addEventListener('blur', () => {
    const txt = el.innerText.replace(/\n$/, '');
    el.remove(); S.editing = null;
    if (txt.trim()) {
      pushUndo();
      // لو النص قصير، ضيّق الصندوق
      const c = document.createElement('canvas').getContext('2d'); c.font = `${a.b ? '700 ' : ''}${a.s * 1000}px Tajawal`;
      const longest = Math.max(...txt.split('\n').map(l => c.measureText(l).width)) / 1000;
      if (isNew && longest + .01 < a.bw) { const nw = longest + .01; a.x = a.x + a.bw - nw; a.bw = nw; }
      a.text = txt; a.th = el.offsetHeight / H;
      if (isNew) p.annots.push(a);
      persist(); renderThumb(+d.dataset.i);
    } else if (!isNew) { pushUndo(); p.annots = p.annots.filter(x => x !== a); persist(); }
    drawAnn(d, p);
  }, { once: true });
}

// التوقيع
const sigs = () => { try { return JSON.parse(localStorage.getItem('pdf.sigs') || '[]'); } catch { return []; } };
function placeSignature(d, p, x, y) {
  const list = sigs();
  if (!list.length) return signatureDialog(() => placeSignature(d, p, x, y));
  const s = list[S.sigIdx || 0] || list[0];
  const im = new Image(); im.onload = () => {
    const bw = .26, bh = bw * (im.height / im.width) * (parseFloat(d.style.width) / parseFloat(d.style.height));
    pushUndo(); const a = { id: uid(), t: 'img', src: s, x: clamp(x - bw / 2, 0, 1 - bw), y: clamp(y - bh / 2, 0, 1 - bh), bw, bh };
    p.annots.push(a); S.sel = { page: p.id, id: a.id }; setTool('select'); S.sel = { page: p.id, id: a.id }; drawAnn(d, p); persist(); renderThumb(+d.dataset.i);
  }; im.src = s;
}
function signatureDialog(after) {
  const m = modal(`<h3>✍️ التوقيع</h3>
    <div class="sigs" id="sg-list"></div>
    <p class="muted" style="margin:0 0 6px">ارسم توقيعك هون (بالقلم أو الإصبع أو الماوس):</p>
    <canvas id="sig-pad"></canvas>
    <div class="acts"><button class="btn pri" data-save>💾 حفظ التوقيع</button><button class="btn" data-clear>مسح</button><button class="btn" data-close>إغلاق</button></div>`);
  const list = () => { const l = sigs(); m.querySelector('#sg-list').innerHTML = l.map((s, i) => `<div class="sg" data-i="${i}" style="${i === (S.sigIdx || 0) ? 'border-color:var(--brand)' : ''}"><img src="${s}"><button class="x" data-rm="${i}">✕</button></div>`).join('') || '<span class="muted">ما في توقيعات محفوظة</span>'; };
  list();
  m.querySelector('#sg-list').onclick = (e) => {
    const rm = e.target.closest('[data-rm]'); if (rm) { const l = sigs(); l.splice(+rm.dataset.rm, 1); localStorage.setItem('pdf.sigs', JSON.stringify(l)); S.sigIdx = 0; return list(); }
    const sg = e.target.closest('[data-i]'); if (sg) { S.sigIdx = +sg.dataset.i; close(); after?.(); }
  };
  const cv = m.querySelector('#sig-pad'); const r = DPR(); cv.width = cv.clientWidth * r; cv.height = cv.clientHeight * r;
  const ctx = cv.getContext('2d'); ctx.scale(r, r); ctx.lineCap = 'round'; ctx.lineJoin = 'round'; ctx.strokeStyle = '#0b2a6b';
  let drawing = false, last = null, any = false;
  cv.onpointerdown = (e) => { drawing = true; cv.setPointerCapture(e.pointerId); const b = cv.getBoundingClientRect(); last = [e.clientX - b.left, e.clientY - b.top]; };
  cv.onpointermove = (e) => { if (!drawing) return; const b = cv.getBoundingClientRect(); const q = [e.clientX - b.left, e.clientY - b.top];
    ctx.lineWidth = e.pointerType === 'pen' ? 1 + 3 * (e.pressure || .5) : 2.6; ctx.beginPath(); ctx.moveTo(...last); ctx.lineTo(...q); ctx.stroke(); last = q; any = true; };
  cv.onpointerup = () => drawing = false;
  m.querySelector('[data-clear]').onclick = () => { ctx.clearRect(0, 0, cv.width, cv.height); any = false; };
  const close = () => m.closest('.ov').remove();
  m.querySelector('[data-save]').onclick = () => {
    if (!any) return toast('ارسم التوقيع أول');
    // قص الفراغ حوالين التوقيع
    const id = ctx.getImageData(0, 0, cv.width, cv.height).data; let x0 = cv.width, y0 = cv.height, x1 = 0, y1 = 0;
    for (let y = 0; y < cv.height; y++) for (let x = 0; x < cv.width; x++) if (id[(y * cv.width + x) * 4 + 3] > 10) { x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y); }
    const pad = 6, w = x1 - x0 + 2 * pad, h = y1 - y0 + 2 * pad; const out = document.createElement('canvas'); out.width = w; out.height = h;
    out.getContext('2d').drawImage(cv, x0 - pad, y0 - pad, w, h, 0, 0, w, h);
    const l = sigs(); l.unshift(out.toDataURL('image/png')); localStorage.setItem('pdf.sigs', JSON.stringify(l.slice(0, 6))); S.sigIdx = 0;
    toast('انحفظ التوقيع — اضغط على الصفحة مكان ما بدك تحطه'); close(); after?.();
  };
}

// صورة
function insertImage(file) {
  const fr = new FileReader(); fr.onload = () => {
    const im = new Image(); im.onload = () => {
      // تصغير الصورة الكبيرة
      const mx = 1600, sc = Math.min(1, mx / Math.max(im.width, im.height)); const c = document.createElement('canvas'); c.width = im.width * sc; c.height = im.height * sc;
      c.getContext('2d').drawImage(im, 0, 0, c.width, c.height);
      const src = c.toDataURL(file.type === 'image/png' ? 'image/png' : 'image/jpeg', .88);
      const p = S.doc.pages[S.cur], d = $(`.page[data-pid="${p.id}"]`); const [w, h] = dispSize(p);
      const bw = .5, bh = bw * (c.height / c.width) * (w / h);
      pushUndo(); const a = { id: uid(), t: 'img', src, x: .25, y: clamp(.3, 0, 1 - bh), bw, bh }; p.annots.push(a);
      setTool('select'); S.sel = { page: p.id, id: a.id }; drawAnn(d, p); persist(); renderThumb(S.cur);
    }; im.src = fr.result;
  }; fr.readAsDataURL(file);
}

// ---------------------------------------------------------------------
//  الصفحات المصغّرة وعمليات الصفحات
// ---------------------------------------------------------------------
let thIO = null;
function renderThumbs() {
  const box = $('#thumbs'); thIO?.disconnect();
  thIO = new IntersectionObserver(ents => ents.forEach(e => { if (e.isIntersecting) renderThumb(+e.target.dataset.i); }), { root: $('#side'), rootMargin: '300px 0px' });
  box.innerHTML = S.doc.pages.map((p, i) => { const [w, h] = dispSize(p); return `<div class="th ${i === S.cur ? 'cur' : ''}" data-i="${i}" draggable="true">
    <canvas width="1" height="1" style="aspect-ratio:${w}/${h}"></canvas><div class="n">${i + 1}</div>
    <div class="acts"><button data-a="up" title="لفوق">▲</button><button data-a="down" title="لتحت">▼</button><button data-a="rot" title="تدوير">⟳</button><button data-a="del" title="حذف">🗑</button></div></div>`; }).join('');
  $$('.th', box).forEach(t => thIO.observe(t));
}
async function renderThumb(i) {
  const p = S.doc?.pages[i]; const t = $(`.th[data-i="${i}"]`); if (!p || !t) return;
  const cv = t.querySelector('canvas'); const [w, h] = dispSize(p); const sc = 126 / w; const W = Math.round(126 * 1.5), H = Math.round(h * sc * 1.5);
  const off = document.createElement('canvas'); off.width = W; off.height = H; const ctx = off.getContext('2d');
  if (p.src == null) drawBlank(ctx, p.blank, W, H, sc * 1.5);
  else { try { const pg = await S.doc.sources[p.src].pdf.getPage(p.idx + 1); const vp = pg.getViewport({ scale: sc * 1.5, rotation: (pg.rotate + p.rot) % 360 }); await pg.render({ canvasContext: ctx, viewport: vp }).promise; } catch { return; } }
  drawAnnots(ctx, p.annots, W, H);
  cv.width = W; cv.height = H; cv.getContext('2d').drawImage(off, 0, 0);
}

function rotatePage(i, deg = 90) {
  const p = S.doc.pages[i]; p.rot = (p.rot + deg + 360) % 360;
  const tr = deg === 90 ? (x, y) => [1 - y, x] : deg === -90 || deg === 270 ? (x, y) => [y, 1 - x] : (x, y) => [1 - x, 1 - y];
  for (const a of p.annots) {
    if (a.p) a.p = a.p.map(q => [...tr(q[0], q[1]), q[2]]);
    else if (a.t === 'shape') { [a.x1, a.y1] = tr(a.x1, a.y1); [a.x2, a.y2] = tr(a.x2, a.y2); }
    else { const [w0, h0] = dispSize({ ...p, rot: (p.rot - deg + 360) % 360 }); const cx = a.x + a.bw / 2, cy = a.y + (a.bh || a.th || .03) / 2; const [nx, ny] = tr(cx, cy);
      const ratio = w0 / h0; if (a.t === 'img') { const bw = a.bh * (1 / ratio) * 0 + a.bw * ratio; a.bh = a.bh / ratio; a.bw = bw; } else { a.bw = Math.min(.95, a.bw * ratio); a.s = a.s * ratio; }
      a.x = clamp(nx - a.bw / 2, 0, 1); a.y = clamp(ny - (a.bh || a.th || .03) / 2, 0, 1); }
  }
}
function pageOp(op, i) {
  pushUndo(); const P = S.doc.pages;
  if (op === 'del') { if (P.length === 1) { S.undo.pop(); updUndo(); return toast('ما بتقدر تحذف آخر صفحة'); } P.splice(i, 1); S.cur = Math.min(S.cur, P.length - 1); }
  if (op === 'rot') rotatePage(i, 90);
  if (op === 'up' && i > 0) [P[i - 1], P[i]] = [P[i], P[i - 1]];
  if (op === 'down' && i < P.length - 1) [P[i + 1], P[i]] = [P[i], P[i + 1]];
  layout(); renderThumbs(); persist();
}
function addBlank(kind, after = S.cur) {
  pushUndo(); const ref = S.doc.pages[after]; const [w, h] = ref ? dispSize(ref) : A4;
  const bw = Math.min(w, h) === w ? w : w, bh = h; // نفس مقاس الصفحة الحالية واتجاهها
  S.doc.pages.splice(after + 1, 0, { id: uid(), src: null, idx: 0, rot: 0, blank: kind, bw, bh, annots: [] });
  layout(); renderThumbs(); persist(); goTo(after + 1);
}
async function mergeFiles(files) {
  busy(true, 'جاري الدمج…');
  try {
    pushUndo();
    for (const f of files) { const bytes = new Uint8Array(await f.arrayBuffer()); const pdf = await loadPdf(bytes); const si = S.doc.sources.push({ bytes, pdf }) - 1; S.doc.pages.push(...await pagesFromPdf(pdf, si)); }
    layout(); renderThumbs(); persist(); toast(`انضاف ${files.length} ملف بآخر المستند`);
  } catch (e) { console.error(e); toast('ما قدرت أدمج الملف'); } finally { busy(false); }
}

// ---------------------------------------------------------------------
//  الحفظ كملف PDF (pdf-lib) — الإضافات بتنحط كطبقة صورة شفافة فوق الصفحة
// ---------------------------------------------------------------------
let PDFLibP = null;
const getPDFLib = () => PDFLibP || (PDFLibP = new Promise((res, rej) => { if (window.PDFLib) return res(window.PDFLib); const s = document.createElement('script'); s.src = './lib/pdf-lib.min.js'; s.onload = () => res(window.PDFLib); s.onerror = rej; document.head.appendChild(s); }));

async function annotsPng(p, ptsW, ptsH, k = 2.6) {
  const W = Math.round(ptsW * k), H = Math.round(ptsH * k); const c = document.createElement('canvas'); c.width = W; c.height = H;
  const ctx = c.getContext('2d'); if (p.src == null) drawBlank(ctx, p.blank, W, H, k);
  drawAnnots(ctx, p.annots, W, H);
  return new Promise(res => c.toBlob(async b => res(new Uint8Array(await b.arrayBuffer())), 'image/png'));
}

async function exportPdf(indices = null) {
  const { PDFDocument, degrees } = await getPDFLib();
  await document.fonts.load('16px Tajawal').catch(() => {});
  await Promise.all([...new Set(S.doc.pages.flatMap(p => p.annots.filter(a => a.t === 'img').map(a => a.src)))].map(s => new Promise(r => { const im = getImg(s); if (im.complete) r(); else { im.onload = r; im.onerror = r; } })));
  const out = await PDFDocument.create();
  const libs = []; // مصادر pdf-lib (أو null إذا مشفّر — بنحوّله صور)
  for (const s of S.doc.sources) { try { const d = await PDFDocument.load(s.bytes, { ignoreEncryption: true }); libs.push(d.isEncrypted ? null : d); } catch { libs.push(null); } }
  const list = (indices || S.doc.pages.map((_, i) => i)).map(i => S.doc.pages[i]);
  for (const [n, p] of list.entries()) {
    busy(true, `جاري تجهيز الملف… ${n + 1}/${list.length}`);
    let page;
    if (p.src == null) { page = out.addPage([p.bw, p.bh]); if (p.rot) page.setRotation(degrees(p.rot)); }
    else if (libs[p.src]) { const [cp] = await out.copyPages(libs[p.src], [p.idx]); page = out.addPage(cp); page.setRotation(degrees(((cp.getRotation().angle || 0) + p.rot) % 360)); }
    else { // ملف مشفّر: نرسم الصفحة كصورة
      const pg = await S.doc.sources[p.src].pdf.getPage(p.idx + 1); const vp = pg.getViewport({ scale: 2.5, rotation: (pg.rotate + p.rot) % 360 });
      const c = document.createElement('canvas'); c.width = vp.width; c.height = vp.height; await pg.render({ canvasContext: c.getContext('2d'), viewport: vp }).promise;
      const [w, h] = dispSize(p); page = out.addPage([w, h]); const jpg = await out.embedJpg(await new Promise(r => c.toBlob(async b => r(new Uint8Array(await b.arrayBuffer())), 'image/jpeg', .92)));
      page.drawImage(jpg, { x: 0, y: 0, width: w, height: h });
    }
    if (!p.annots.length && p.src != null) continue;
    if (!p.annots.length && p.src == null && p.blank === 'plain') continue;
    const R = (page.getRotation().angle % 360 + 360) % 360; const cb = page.getCropBox(); const cx = cb.x, cy = cb.y, W = cb.width, H = cb.height;
    const [dw, dh] = R % 180 ? [H, W] : [W, H];
    const png = await out.embedPng(await annotsPng(p, dw, dh));
    // نحط الطبقة بحيث تطلع مستقيمة بعد تدوير الصفحة
    const opt = R === 0 ? { x: cx, y: cy, width: dw, height: dh } : R === 90 ? { x: cx + W, y: cy, width: dw, height: dh, rotate: degrees(90) }
      : R === 180 ? { x: cx + W, y: cy + H, width: dw, height: dh, rotate: degrees(180) } : { x: cx, y: cy + H, width: dw, height: dh, rotate: degrees(270) };
    page.drawImage(png, opt);
  }
  out.setTitle(S.doc.name); out.setProducer('السمو PDF'); out.setCreator('السمو PDF');
  const bytes = await out.save(); busy(false);
  return bytes;
}

async function saveAs(name = S.doc.name, indices = null) {
  try {
    const bytes = await exportPdf(indices);
    const blob = new Blob([bytes], { type: 'application/pdf' }); const fname = (name || 'ملف').replace(/[\\/:*?"<>|]+/g, ' ').trim() + '.pdf';
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = fname; document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 30000); toast(`✓ انحفظ «${fname}» بالتنزيلات`);
  } catch (e) { console.error(e); busy(false); toast('صار خطأ بالحفظ'); }
}
async function shareFile() {
  try {
    const bytes = await exportPdf(); const file = new File([bytes], S.doc.name + '.pdf', { type: 'application/pdf' });
    if (navigator.canShare?.({ files: [file] })) await navigator.share({ files: [file], title: S.doc.name });
    else { toast('المشاركة مش مدعومة هون — رح أنزّله بدالها'); saveAs(); }
  } catch (e) { busy(false); if (e?.name !== 'AbortError') toast('ما زبطت المشاركة'); }
}
async function printDoc() {
  try {
    const bytes = await exportPdf(); const url = URL.createObjectURL(new Blob([bytes], { type: 'application/pdf' }));
    if (/iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)) { window.open(url, '_blank'); toast('اضغط زر المشاركة بالصفحة اللي فتحت واختار «طباعة»', 4000); return; }
    const f = document.createElement('iframe'); f.style.cssText = 'position:fixed;width:0;height:0;border:0;visibility:hidden'; f.src = url; document.body.appendChild(f);
    f.onload = () => { try { f.contentWindow.focus(); f.contentWindow.print(); } catch { window.open(url, '_blank'); } setTimeout(() => f.remove(), 60000); };
  } catch (e) { console.error(e); busy(false); toast('ما زبطت الطباعة'); }
}

// ---------------------------------------------------------------------
//  البحث
// ---------------------------------------------------------------------
const textCache = new Map(); let searchHits = [], searchIdx = -1, searchQ = '', searchOpen = false;
const norm = (s) => String(s).toLowerCase().replace(/[ً-ٰٟـ]/g, '').replace(/[أإآٱ]/g, 'ا').replace(/ى/g, 'ي').replace(/ة/g, 'ه');
async function pageText(p) {
  if (p.src == null) return '';
  const k = `${p.src}:${p.idx}`; if (textCache.has(k)) return textCache.get(k);
  const pg = await S.doc.sources[p.src].pdf.getPage(p.idx + 1); const tc = await pg.getTextContent(); const t = norm(tc.items.map(x => x.str).join(' '));
  textCache.set(k, t); return t;
}
function openSearch() {
  searchOpen = true; const sb = $('#subbar'); sb.hidden = false;
  sb.innerHTML = `<input type="search" id="q" placeholder="ابحث بالملف…" value="${esc(searchQ)}"><span id="q-res" class="muted"></span>
    <button class="chip" id="q-prev">▲ السابق</button><button class="chip" id="q-next">▼ التالي</button><button class="chip" id="q-x">✕</button>`;
  const q = $('#q'); q.focus(); q.select();
  q.onkeydown = (e) => { if (e.key === 'Enter') { e.preventDefault(); if (norm(q.value) !== searchQ) runSearch(q.value); else stepSearch(e.shiftKey ? -1 : 1); } if (e.key === 'Escape') closeSearch(); e.stopPropagation(); };
  $('#q-next').onclick = () => norm(q.value) !== searchQ ? runSearch(q.value) : stepSearch(1); $('#q-prev').onclick = () => stepSearch(-1); $('#q-x').onclick = closeSearch;
}
function closeSearch() { searchOpen = false; searchQ = ''; searchHits = []; $('#subbar').hidden = true; $$('.textLayer .hit').forEach(s => s.classList.remove('hit', 'cur')); setTool(S.tool); }
async function runSearch(v) {
  searchQ = norm(v.trim()); searchHits = []; searchIdx = -1; $$('.textLayer .hit').forEach(s => s.classList.remove('hit', 'cur'));
  if (!searchQ) return;
  $('#q-res').textContent = 'جاري البحث…';
  for (const [i, p] of S.doc.pages.entries()) { const t = await pageText(p); let k = t.indexOf(searchQ), n = 0; while (k >= 0) { n++; k = t.indexOf(searchQ, k + 1); } if (n) searchHits.push({ i, n }); }
  const tot = searchHits.reduce((a, h) => a + h.n, 0);
  $('#q-res').textContent = tot ? `${tot} نتيجة بـ ${searchHits.length} صفحة` : 'ما في نتائج';
  $$('.page').forEach(d => markHits(+d.dataset.i, d));
  if (searchHits.length) stepSearch(1);
}
function stepSearch(dir) { if (!searchHits.length) return; searchIdx = (searchIdx + dir + searchHits.length) % searchHits.length; goTo(searchHits[searchIdx].i); $('#q-res').textContent = `صفحة ${searchHits[searchIdx].i + 1} — (${searchIdx + 1}/${searchHits.length} صفحات)`; }
function markHits(i, d) {
  if (!searchQ) return; const spans = $$('.textLayer span', d);
  spans.forEach(s => s.classList.toggle('hit', norm(s.textContent).includes(searchQ)));
  // لو الكلمة مقسومة على أكثر من span
  if (!spans.some(s => s.classList.contains('hit')) && searchHits.some(h => h.i === i)) spans.forEach(s => { const t = norm(s.textContent); if (t.length > 1 && searchQ.includes(t)) s.classList.add('hit'); });
}

// ---------------------------------------------------------------------
//  التنقل والتكبير
// ---------------------------------------------------------------------
function goTo(i, smooth = true) {
  i = clamp(i, 0, S.doc.pages.length - 1); S.cur = i;
  if (S.present) { layout(); return; }
  const d = $(`.page[data-i="${i}"]`); d?.scrollIntoView({ behavior: smooth ? 'smooth' : 'auto', block: 'start' }); updCur();
}
function updCur() {
  if (!S.doc) return; $('#pg-in').value = S.cur + 1;
  $$('.th').forEach(t => t.classList.toggle('cur', +t.dataset.i === S.cur));
  $('#pr-n') && ($('#pr-n').textContent = `${S.cur + 1} / ${S.doc.pages.length}`);
}
function trackScroll() {
  if (S.present) return; const el = pagesEl(); const mid = el.scrollTop + el.clientHeight * .35;
  let best = 0; for (const d of $$('.page', el)) { if (d.offsetTop <= mid) best = +d.dataset.i; else break; }
  if (best !== S.cur) { S.cur = best; updCur(); const t = $(`.th[data-i="${best}"]`); if (t && !$('#side').hidden) t.scrollIntoView({ block: 'nearest' }); }
}
function setZoom(z, keepPage = true) {
  const el = pagesEl(); const d = $(`.page[data-i="${S.cur}"]`); const off = d ? (el.scrollTop - d.offsetTop) / d.offsetHeight : 0;
  S.zoom = clamp(z, .25, 6); layout();
  if (keepPage) { const d2 = $(`.page[data-i="${S.cur}"]`); if (d2) el.scrollTop = d2.offsetTop + off * d2.offsetHeight; }
}

// وضع العرض بشاشة كاملة
function present(on) {
  S.present = on; document.body.classList.toggle('present', on); $('#present-nav').hidden = !on;
  if (on) { document.documentElement.requestFullscreen?.().catch(() => {}); $('#present-nav').innerHTML = `<button class="ib" id="pr-prev" title="السابقة">›</button><span id="pr-n"></span><button class="ib" id="pr-next" title="التالية">‹</button>
      <span id="present-tools"><button class="ib" data-pt="hand" title="تحريك">✋</button><button class="ib" data-pt="pen" title="قلم">✏️</button><button class="ib" data-pt="hl" title="تظليل">🖍️</button><button class="ib" data-pt="eraser" title="ممحاة">🧽</button><button class="ib" data-pt="blank" title="صفحة فاضية للشرح">➕</button></span><button class="ib" id="pr-exit" title="خروج">✕</button>`;
    $('#pr-prev').onclick = () => goTo(S.cur - 1); $('#pr-next').onclick = () => goTo(S.cur + 1); $('#pr-exit').onclick = () => present(false);
    $('#present-tools').onclick = (e) => { const b = e.target.closest('[data-pt]'); if (!b) return; if (b.dataset.pt === 'blank') { addBlank('plain'); return; } setTool(b.dataset.pt); $$('[data-pt]').forEach(x => x.classList.toggle('on', x.dataset.pt === S.tool)); };
    $$('[data-pt]').forEach(x => x.classList.toggle('on', x.dataset.pt === S.tool));
  } else if (document.fullscreenElement) document.exitFullscreen?.();
  layout(); updCur(); if (!on) goTo(S.cur, false);
}

// ---------------------------------------------------------------------
//  نوافذ صغيرة
// ---------------------------------------------------------------------
function modal(html) {
  const ov = document.createElement('div'); ov.className = 'ov'; ov.innerHTML = `<div class="mdl">${html}</div>`;
  ov.addEventListener('click', (e) => { if (e.target === ov || e.target.closest('[data-close]')) ov.remove(); });
  $('#modal-root').appendChild(ov); return ov.querySelector('.mdl');
}
function ask(text, yes = 'نعم', no = 'لا') {
  return new Promise(res => { const m = modal(`<p style="font-size:16px;margin:0">${esc(text)}</p><div class="acts"><button class="btn pri" data-y>${esc(yes)}</button><button class="btn" data-n>${esc(no)}</button></div>`);
    m.querySelector('[data-y]').onclick = () => { m.closest('.ov').remove(); res(true); }; m.querySelector('[data-n]').onclick = () => { m.closest('.ov').remove(); res(false); };
    m.closest('.ov').addEventListener('click', (e) => { if (e.target.classList.contains('ov')) res(false); }); });
}
function prompt2(title, value = '', label = '') {
  return new Promise(res => { const m = modal(`<h3>${esc(title)}</h3><div class="f">${label ? `<label>${esc(label)}</label>` : ''}<input type="text" id="p-in" value="${esc(value)}"></div><div class="acts"><button class="btn pri" data-y>تمام</button><button class="btn" data-close>إلغاء</button></div>`);
    const i = m.querySelector('#p-in'); setTimeout(() => { i.focus(); i.select(); }, 30);
    const ok = () => { m.closest('.ov').remove(); res(i.value); }; m.querySelector('[data-y]').onclick = ok; i.onkeydown = (e) => { e.stopPropagation(); if (e.key === 'Enter') ok(); };
    m.closest('.ov').addEventListener('click', (e) => { if (e.target.classList.contains('ov') || e.target.closest('[data-close]')) res(null); }); });
}
function parseRange(s, n) { const out = new Set(); for (const part of String(s).replace(/[٠-٩]/g, d => '٠١٢٣٤٥٦٧٨٩'.indexOf(d)).split(/[,،\s]+/)) { if (!part) continue; const m = part.match(/^(\d+)(?:-(\d+))?$/); if (!m) return null; let a = +m[1], b = +(m[2] || m[1]); if (a > b) [a, b] = [b, a]; for (let i = a; i <= b; i++) if (i >= 1 && i <= n) out.add(i - 1); } return [...out].sort((a, b) => a - b); }

function openMenu(btn) {
  const m = $('#menu'); const r = btn.getBoundingClientRect();
  m.innerHTML = `
    <button data-m="blank-plain">📄 إضافة صفحة بيضاء</button><button data-m="blank-grid">🔲 إضافة صفحة مربعات</button><button data-m="blank-lines">📝 إضافة صفحة أسطر</button>
    <button data-m="merge">➕ دمج ملف PDF ثاني</button><button data-m="extract">✂️ استخراج صفحات لملف جديد</button>
    <hr><button data-m="rot">⟳ تدوير الصفحة الحالية</button><button data-m="rotall">⟳ تدوير كل الصفحات</button><button data-m="del">🗑️ حذف الصفحة الحالية</button><button data-m="clear">🧹 مسح الكتابة عن الصفحة الحالية</button>
    <hr><button data-m="print">🖨️ طباعة</button><button data-m="share">📤 مشاركة / إرسال</button><button data-m="saveas">💾 حفظ باسم جديد…</button><button data-m="rename">✏️ تغيير اسم الملف</button>
    <hr><button data-m="pen">${S.penOnly ? '✅' : '⬜'} الكتابة بالقلم بس (الإصبع للتحريك)</button><button data-m="dark">${document.body.classList.contains('dark') ? '✅' : '⬜'} وضع القراءة الليلي</button><button data-m="fit">${S.fit === 'page' ? '↔️ ملء العرض' : '🗎 الصفحة كاملة'}</button>
    <hr><button data-m="sig">✍️ إدارة التوقيعات</button><button data-m="help">❓ طريقة الاستخدام</button>`;
  m.hidden = false; const w = 250; m.style.top = Math.min(r.bottom + 6, innerHeight - 100) + 'px'; m.style.left = clamp(r.left, 6, innerWidth - w - 6) + 'px';
  m.onclick = async (e) => {
    const k = e.target.closest('[data-m]')?.dataset.m; if (!k) return; m.hidden = true;
    if (k.startsWith('blank-')) addBlank(k.slice(6));
    if (k === 'merge') $('#merge-file').click();
    if (k === 'extract') { const v = await prompt2('استخراج صفحات', `1-${S.doc.pages.length}`, 'أرقام الصفحات (مثلاً: 1-3، 5، 8)'); if (v == null) return; const ix = parseRange(v, S.doc.pages.length); if (!ix?.length) return toast('أرقام الصفحات مش مفهومة'); saveAs(`${S.doc.name} - صفحات ${v}`, ix); }
    if (k === 'rot') pageOp('rot', S.cur);
    if (k === 'rotall') { pushUndo(); S.doc.pages.forEach((_, i) => rotatePage(i, 90)); layout(); renderThumbs(); persist(); }
    if (k === 'del') pageOp('del', S.cur);
    if (k === 'clear') { const p = S.doc.pages[S.cur]; if (!p.annots.length) return; if (!(await ask('تمسح كل الكتابة والإضافات عن هالصفحة؟', 'امسح', 'لا'))) return; pushUndo(); p.annots = []; layout(); renderThumb(S.cur); persist(); }
    if (k === 'print') printDoc();
    if (k === 'share') shareFile();
    if (k === 'saveas') { const v = await prompt2('حفظ باسم جديد', S.doc.name, 'اسم الملف'); if (v) saveAs(v); }
    if (k === 'rename') { const v = await prompt2('اسم الملف', S.doc.name); if (v?.trim()) { S.doc.name = v.trim(); $('#doc-name').textContent = S.doc.name; persist(); } }
    if (k === 'pen') { S.penOnly = !S.penOnly; localStorage.setItem('pdf.penOnly', S.penOnly ? '1' : '0'); applyToolClass(); toast(S.penOnly ? 'القلم بيكتب، والإصبع بيحرّك' : 'الإصبع والقلم بيكتبوا'); }
    if (k === 'dark') document.body.classList.toggle('dark');
    if (k === 'fit') { S.fit = S.fit === 'page' ? 'width' : 'page'; S.zoom = 1; layout(); goTo(S.cur, false); }
    if (k === 'sig') signatureDialog();
    if (k === 'help') help();
  };
}
function help() {
  modal(`<h3>❓ طريقة الاستخدام</h3><div style="line-height:1.9;font-size:14.5px">
  <b>✋ تحريك:</b> بتقلّب الصفحات وبتحدد النص وبتنسخه.<br><b>✏️ قلم / 🖍️ تظليل:</b> اختار اللون والسماكة من فوق. قلم الآيباد والقلم الضوئي بيحسّوا بالضغط.<br>
  <b>🧽 ممحاة:</b> مرّرها على أي خط أو شكل.<br><b>⬭ أشكال:</b> مربع، دائرة، خط، سهم (مع Shift بيطلع مربع/دائرة مضبوطة).<br>
  <b>T نص:</b> اضغط مكان ما بدك واكتب، واضغط برا لما تخلص.<br><b>✍️ توقيع:</b> أول مرة بترسم توقيعك وبينحفظ، وبعدين بتضغط مكانه وبينحط.<br>
  <b>⬚ تحديد:</b> اضغط على أي إضافة لتحرّكها أو تكبّرها (من المقبض) أو تحذفها أو تغيّر لونها. ضغطتين على النص بتعدّله.<br>
  <b>📽️ عرض:</b> شاشة كاملة للشرح، بالأسهم بتقلّب، وفيه قلم وصفحة فاضية.<br><b>💾 حفظ:</b> بينزّل ملف PDF جديد فيه كل تعديلاتك.<br>
  <b>اختصارات:</b> Ctrl+Z تراجع، Ctrl+Y إعادة، Ctrl+F بحث، Ctrl+S حفظ، P قلم، H تظليل، E ممحاة، T نص، V تحديد، Space تحريك، Delete حذف المحدد.<br>
  <span class="muted">كل تعديلاتك بتنحفظ لحالها على جهازك، فبتسكّر وبترجع تكمّل من وين ما وقفت.</span></div><div class="acts"><button class="btn pri" data-close>تمام</button></div>`);
}

// ---------------------------------------------------------------------
//  الشاشة الأولى
// ---------------------------------------------------------------------
async function showHome() {
  if (S.doc) persist(true);
  S.doc = null; if (S.present) present(false);
  $('#viewer').hidden = true; $('#home').hidden = false; document.title = 'السمو PDF'; history.replaceState(null, '', location.pathname);
  pagesEl().innerHTML = '';
  const list = (await DB.all('meta').catch(() => [])).sort((a, b) => b.updated - a.updated);
  const kb = (n) => n > 1048576 ? (n / 1048576).toFixed(1) + ' ميغا' : Math.round(n / 1024) + ' كيلو';
  $('#recent').innerHTML = list.length ? list.map(m => `<div class="rf" data-id="${m.id}"><span style="font-size:26px">📕</span><div class="nm"><b>${esc(m.name)}</b><small>${m.pages} صفحة · ${kb(m.size || 0)} · ${new Date(m.updated).toLocaleString('ar-JO', { dateStyle: 'medium', timeStyle: 'short' })}</small></div><button class="x" data-rm="${m.id}" title="حذف من الجهاز">🗑</button></div>`).join('')
    : '<p class="muted">ما في ملفات لسا</p>';
}

// ---------------------------------------------------------------------
//  ربط الأزرار
// ---------------------------------------------------------------------
function bind() {
  $('#open-file').onchange = (e) => { const f = e.target.files[0]; e.target.value = ''; if (f) f.arrayBuffer().then(b => openBytes(new Uint8Array(b), f.name)); };
  const drop = $('#drop');
  ['dragenter', 'dragover'].forEach(ev => document.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.add('over'); }));
  ['dragleave', 'drop'].forEach(ev => document.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.remove('over'); }));
  document.addEventListener('drop', (e) => { const fs = [...(e.dataTransfer?.files || [])].filter(f => /pdf$/i.test(f.type) || /\.pdf$/i.test(f.name)); if (!fs.length) return;
    if (S.doc && !$('#viewer').hidden) mergeFiles(fs); else fs[0].arrayBuffer().then(b => openBytes(new Uint8Array(b), fs[0].name)); });
  $('#new-blank').onclick = newNotebook;
  $('#recent').onclick = async (e) => {
    const rm = e.target.closest('[data-rm]'); if (rm) { e.stopPropagation(); if (await ask('تحذف الملف وتعديلاته من هالجهاز؟ (الملف الأصلي عندك ما بيتأثر)', 'احذف', 'لا')) { await DB.del('docs', rm.dataset.rm); await DB.del('meta', rm.dataset.rm); showHome(); } return; }
    const r = e.target.closest('[data-id]'); if (r) openSaved(r.dataset.id);
  };
  $('#b-home').onclick = showHome;
  $('#b-side').onclick = () => { $('#side').hidden = !$('#side').hidden; };
  $('#tools').addEventListener('click', (e) => { const b = e.target.closest('.tool'); if (b) setTool(b.dataset.tool); });
  $('#b-image').onclick = () => $('#img-file').click();
  $('#img-file').onchange = (e) => { const f = e.target.files[0]; e.target.value = ''; if (f) insertImage(f); };
  $('#merge-file').onchange = (e) => { const fs = [...e.target.files]; e.target.value = ''; if (fs.length) mergeFiles(fs); };
  $('#color').value = S.color; $('#color').oninput = (e) => { S.color = e.target.value; localStorage.setItem('pdf.color', S.color); };
  $('#width').value = String(S.width); $('#width').onchange = (e) => { S.width = +e.target.value; localStorage.setItem('pdf.width', S.width); };
  $('#b-undo').onclick = undo; $('#b-redo').onclick = redo;
  $('#b-zin').onclick = () => setZoom(S.zoom * 1.2); $('#b-zout').onclick = () => setZoom(S.zoom / 1.2);
  $('#b-zoom').onclick = () => { S.fit = 'width'; setZoom(1); };
  $('#pg-in').onchange = (e) => goTo(+e.target.value - 1); $('#pg-in').onkeydown = (e) => e.stopPropagation();
  $('#b-search').onclick = () => searchOpen ? closeSearch() : openSearch();
  $('#b-present').onclick = () => present(true);
  $('#b-more').onclick = (e) => { e.stopPropagation(); $('#menu').hidden ? openMenu(e.currentTarget) : ($('#menu').hidden = true); };
  document.addEventListener('click', (e) => { if (!e.target.closest('#menu')) $('#menu').hidden = true; });
  $('#b-save').onclick = () => saveAs();
  pagesEl().addEventListener('scroll', () => { requestAnimationFrame(trackScroll); }, { passive: true });
  // الصفحات المصغّرة
  const th = $('#thumbs'); let dragI = null;
  th.onclick = (e) => { const t = e.target.closest('.th'); if (!t) return; const a = e.target.closest('[data-a]'); if (a) return pageOp(a.dataset.a, +t.dataset.i); goTo(+t.dataset.i); if (innerWidth < 760) $('#side').hidden = true; };
  th.ondragstart = (e) => { dragI = +e.target.closest('.th').dataset.i; e.dataTransfer.effectAllowed = 'move'; };
  th.ondragover = (e) => { e.preventDefault(); $$('.th', th).forEach(x => x.classList.remove('drag-over')); e.target.closest('.th')?.classList.add('drag-over'); };
  th.ondrop = (e) => { e.preventDefault(); e.stopPropagation(); const t = e.target.closest('.th'); $$('.th', th).forEach(x => x.classList.remove('drag-over')); if (!t || dragI == null) return;
    const to = +t.dataset.i; if (to === dragI) return; pushUndo(); const [pg] = S.doc.pages.splice(dragI, 1); S.doc.pages.splice(to > dragI ? to - 1 : to, 0, pg); dragI = null; layout(); renderThumbs(); persist(); };
  // تكبير باللمس (إصبعين) والماوس (Ctrl + عجلة)
  let pinch = null;
  pagesEl().addEventListener('touchstart', (e) => { if (e.touches.length === 2) { const [a, b] = e.touches; pinch = { d: Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY), z: S.zoom }; } }, { passive: true });
  pagesEl().addEventListener('touchmove', (e) => { if (pinch && e.touches.length === 2) { e.preventDefault(); const [a, b] = e.touches; const r = Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY) / pinch.d; $$('.page').forEach(p => p.style.transform = `scale(${r})`); pinch.r = r; } }, { passive: false });
  pagesEl().addEventListener('touchend', () => { if (pinch) { $$('.page').forEach(p => p.style.transform = ''); if (pinch.r) setZoom(pinch.z * pinch.r); pinch = null; } });
  pagesEl().addEventListener('wheel', (e) => { if (e.ctrlKey || e.metaKey) { e.preventDefault(); setZoom(S.zoom * (e.deltaY < 0 ? 1.1 : 1 / 1.1)); } }, { passive: false });
  // أي تغيير بعرض منطقة الصفحات (فتح الجنب، تدوير الجهاز…) بيعيد الترتيب
  let lastW = 0; new ResizeObserver(() => { const w = pagesEl().clientWidth; if (Math.abs(w - lastW) < 2) return; lastW = w; clearTimeout(bind.rt); bind.rt = setTimeout(() => S.doc && setZoom(S.zoom), 120); }).observe(pagesEl());
  document.addEventListener('fullscreenchange', () => { if (!document.fullscreenElement && S.present) present(false); });
  // لوحة المفاتيح
  document.addEventListener('keydown', (e) => {
    if (!S.doc || $('#viewer').hidden || e.target.closest('input,textarea,[contenteditable="true"]') || $('.ov')) return;
    const k = e.key.toLowerCase(), c = e.ctrlKey || e.metaKey;
    if (c && k === 'z') { e.preventDefault(); e.shiftKey ? redo() : undo(); }
    else if (c && k === 'y') { e.preventDefault(); redo(); }
    else if (c && k === 'f') { e.preventDefault(); openSearch(); }
    else if (c && k === 's') { e.preventDefault(); saveAs(); }
    else if (c && k === 'p') { e.preventDefault(); printDoc(); }
    else if (c && (k === '=' || k === '+')) { e.preventDefault(); setZoom(S.zoom * 1.2); }
    else if (c && k === '-') { e.preventDefault(); setZoom(S.zoom / 1.2); }
    else if (c) return;
    else if ((k === 'delete' || k === 'backspace') && S.sel) { const p = S.doc.pages.find(x => x.id === S.sel.page); pushUndo(); p.annots = p.annots.filter(a => a.id !== S.sel.id); S.sel = null; layout(); persist(); }
    else if (S.present && ['arrowleft', 'pagedown', ' ', 'arrowdown', 'enter'].includes(k)) { e.preventDefault(); goTo(S.cur + 1); }
    else if (S.present && ['arrowright', 'pageup', 'arrowup', 'backspace'].includes(k)) { e.preventDefault(); goTo(S.cur - 1); }
    else if (k === 'escape') { if (S.present) present(false); else if (searchOpen) closeSearch(); else { S.sel = null; layout(); } }
    else if (k === 'p') setTool('pen'); else if (k === 'h') setTool('hl'); else if (k === 'e') setTool('eraser'); else if (k === 't') setTool('text'); else if (k === 'v') setTool('select');
    else if (k === ' ') { e.preventDefault(); setTool('hand'); }
    else if (k === 'pagedown') { e.preventDefault(); goTo(S.cur + 1); } else if (k === 'pageup') { e.preventDefault(); goTo(S.cur - 1); }
  });
  addEventListener('beforeunload', () => { if (S.doc) persist(true); });
  document.addEventListener('visibilitychange', () => { if (document.hidden && S.doc) persist(true); });
}

// ---------------------------------------------------------------------
//  البداية
// ---------------------------------------------------------------------
bind();
if ('serviceWorker' in navigator) navigator.serviceWorker.register('./sw.js').catch(() => {});
// فتح ملف من «فتح باستخدام» (لما البرنامج متنزّل على الكمبيوتر)
if ('launchQueue' in window) launchQueue.setConsumer(async (p) => { const h = p.files?.[0]; if (h) { const f = await h.getFile(); openBytes(new Uint8Array(await f.arrayBuffer()), f.name); } });
const hashId = location.hash.slice(1);
if (hashId) DB.get('meta', hashId).then(m => m ? openSaved(hashId) : showHome()).catch(showHome); else showHome();
window.__pdfapp = { S, exportPdf, openBytes };   // للفحص
