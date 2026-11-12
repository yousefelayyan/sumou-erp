// Service worker: تخزين ملفات الواجهة لفتح أسرع. البيانات دائماً من الإنترنت.
const CACHE = 'sumou-erp-v4.9.0';
const ASSETS = ['./', './index.html', './styles.css', './app.js', './config.js', './core.js', './finance.js', './reports.js', './print.js', './parties.js', './invoices.js', './obligations.js', './cheques.js', './inventory.js', './printset.js', './numbering.js', './posting.js', './audit.js', './centers.js', './departments.js', './perms.js', './lookups.js', './daybook.js', './extras.js', './payroll.js', './tools.js', './attach.js', './manifest.webmanifest', './icons/icon.svg', './icons/icon-192.png'];
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS))); self.skipWaiting(); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))); self.clients.claim(); });
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== location.origin) return; // Supabase والخطوط ما بتتخزن
  e.respondWith(fetch(e.request).then(r => { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); return r; })
    .catch(() => caches.match(e.request)));
});
