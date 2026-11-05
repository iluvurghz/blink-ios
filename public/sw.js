// Retired 2026-11-01: the shell cache made the iPhone home-screen app open on a white screen.
// This version only cleans up: drops every Blink cache, unregisters itself and reloads open pages
// from the network. The app no longer registers a service worker (src/main.jsx).
self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (e) => {
  e.waitUntil(
    (async () => {
      for (const k of await caches.keys()) if (k.startsWith('blink-shell-')) await caches.delete(k);
      await self.registration.unregister();
      for (const c of await self.clients.matchAll({ type: 'window' })) c.navigate(c.url).catch(() => {});
    })(),
  );
});
