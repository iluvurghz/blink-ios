// Artist photos for «Вспышка»: a big picture of who is playing instead of the cover.
// Looked up by name (first artist only) and kept for the session; null when there is none.
import { splitArtists } from './api.js';
const SELF = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '');

const cache = new Map();

export function artistPhoto(track) {
  if (!track) return Promise.resolve(null);
  if (track.artistPhoto) return Promise.resolve(track.artistPhoto);
  const name = splitArtists(track.artist || '')[0];
  if (!name) return Promise.resolve(null);
  const key = name.toLowerCase();
  if (!cache.has(key))
    cache.set(
      key,
      // The site can't read this API directly (no CORS): JSONP there, the bridge in the app.
      window.blink.json(`${SELF}/api/deezer/artist?q=${encodeURIComponent(name)}`, { tries: 1, timeout: 6000 })
        .then((r) => {
          const list = (r.ok && r.data && r.data.data) || [];
          const hit = list.find((a) => a.name && a.name.toLowerCase() === key) || null;
          // Deezer's placeholder for artists without a photo has an empty hash in the path.
          const url = hit && hit.picture_xl;
          return url && !/\/artist\/\/|\/images\/artist\/\//.test(url) ? url : null;
        })
        .catch(() => null)
    );
  return cache.get(key);
}
