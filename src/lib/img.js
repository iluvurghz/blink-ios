// Covers and avatars from hosts that are slow or cut off in Russia come through Blink's server,
// which keeps a copy (server/chartsRoute.js, /api/img).
const MEDIA = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '');
const VIA = /^https:\/\/(lh\d\.googleusercontent\.com|([a-z0-9-]+\.)?mzstatic\.com|([a-z0-9-]+\.)?dzcdn\.net|([a-z0-9-]+\.)?sndcdn\.com|avatars\.yandex\.net)\//i;
const SC = /^https:\/\/([a-z0-9-]+\.)?sndcdn\.com\//i;

// SoundCloud serves one picture in a fixed set of sizes, named by a suffix: -large (100px, what the
// API returns), -t300x300, -t500x500 (the biggest "normal" one), -original (the raw upload, can be
// many megabytes). Anything small gets lifted to a size that stays sharp on a phone.
export function scaleSc(url, size = 500) {
  if (!url || !SC.test(url)) return url;
  const want = size <= 150 ? 't300x300' : 't500x500';
  return url.replace(/-(?:large|badge|small|tiny|mini|crop|original|t\d+x\d+)\.(jpe?g|png|webp)(?=$|[?#])/i, `-${want}.$1`);
}

export function proxied(url) {
  return url && VIA.test(url) ? `${MEDIA}/api/img?u=${encodeURIComponent(url)}` : url;
}

// For a plain <img>: the server copy first, and if that is not there (an older server, a hiccup)
// the original address once. Spread it on the element: <img src={proxied(u)} {...coverFallback(u)} />.
export function coverFallback(original) {
  return {
    referrerPolicy: 'no-referrer',
    onError: (e) => {
      const el = e.currentTarget;
      if (!original || el.dataset.direct) return;
      el.dataset.direct = '1';
      el.src = original;
    },
  };
}
