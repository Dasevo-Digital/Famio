// Famio's Web Push: shows the family server's notices while the web app
// is closed. It only handles push messages. There is no fetch handler and
// no cache, so the web app itself still comes fresh from the server each
// time (see flutter_bootstrap.js).

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) =>
  event.waitUntil(self.clients.claim()));

self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (_) {
    // Not from Famio's server: show the plain hint.
  }
  event.waitUntil((async () => {
    // Browsers expect a visible notification for every push (Safari ends
    // the subscription otherwise). With Famio in front it stays silent:
    // the family sees the news in the app anyway.
    const windows = await self.clients.matchAll({
      type: 'window',
      includeUncontrolled: true,
    });
    const inFront = windows.some((w) => w.focused);
    await self.registration.showNotification(data.title || 'Famio', {
      body: data.body || '',
      icon: 'icons/Icon-192.png',
      badge: 'icons/Icon-192.png',
      silent: Boolean(data.quiet) || (inFront && !data.urgent),
      requireInteraction: Boolean(data.urgent),
      vibrate: data.urgent ? [500, 200, 500, 200, 500] : undefined,
    });
  })());
});

// A tap opens Famio (an open window comes to the front).
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({
      type: 'window',
      includeUncontrolled: true,
    });
    for (const w of windows) {
      if (w.url.startsWith(self.registration.scope) && 'focus' in w) {
        return w.focus();
      }
    }
    return self.clients.openWindow(self.registration.scope);
  })());
});
