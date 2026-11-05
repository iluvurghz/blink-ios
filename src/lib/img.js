// Covers and avatars from hosts that are slow or cut off in Russia come through Blink's server,
// which keeps a copy (server/chartsRoute.js, /api/img).
const MEDIA = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '');
const VIA = /^https:\/\/(lh\d\.googleusercontent\.com|([a-z0-9-]+\.)?mzstatic\.com|([a-z0-9-]+\.)?dzcdn\.net|avatars\.yandex\.net)\//i;

export function proxied(url) {
  return url && VIA.test(url) ? `${MEDIA}/api/img?u=${encodeURIComponent(url)}` : url;
}
