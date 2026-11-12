// السمو قصاصة — تشغيل بدون إنترنت
const CACHE = 'sumou-snip-v1';
const CORE = ['./', './index.html', './app.css', './app.js', './manifest.webmanifest', './icon-192.png'];
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(CORE)).then(() => self.skipWaiting())); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k.startsWith('sumou-snip-') && k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url); if (e.request.method !== 'GET') return;
  const isLib = u.pathname.includes('/lib/');
  if (isLib) { // المكتبات ما بتتغيّر: من الكاش أول
    e.respondWith(caches.match(e.request).then(r => r || fetch(e.request).then(res => { const cp = res.clone(); caches.open(CACHE).then(c => c.put(e.request, cp)); return res; })));
    return;
  }
  // باقي الملفات: من الشبكة أول عشان التحديثات، والكاش إذا ما في إنترنت
  e.respondWith(fetch(e.request).then(res => { if (res.ok && (u.origin === location.origin || u.host.includes('fonts.g'))) { const cp = res.clone(); caches.open(CACHE).then(c => c.put(e.request, cp)); } return res; })
    .catch(() => caches.match(e.request).then(r => r || caches.match('./index.html'))));
});
