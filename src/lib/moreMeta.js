// More catalogs for search, beyond Apple's: many Russian and independent releases are missing
// there. Results become ordinary Blink tracks (source: 'chart', played through the YouTube
// lookup by title and artist). The sources are not named in the interface.
//   desktop: the Russian catalog first, then the international ones
//   site:    the international one through JSONP (it sends no CORS headers), and Spotify's
//            through our server (its key stays there) on both
const bridge = window.blink;
const MEDIA = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '');

const img = (uri, size = 600) => (uri ? 'https://' + uri.replace('%%', `${size}x${size}`) : '');

async function get(url) {
  const r = await bridge.json(url, { tries: 1, timeout: 8000 });
  if (!r.ok) throw new Error('HTTP ' + r.status);
  return r.data;
}

export function jsonp(url) {
  return new Promise((resolve, reject) => {
    const cb = '__blinkJp' + Math.random().toString(36).slice(2);
    const tag = document.createElement('script');
    const done = (fn, v) => {
      delete window[cb];
      tag.remove();
      clearTimeout(timer);
      fn(v);
    };
    const timer = setTimeout(() => done(reject, new Error('timeout')), 8000);
    window[cb] = (d) => done(resolve, d);
    tag.onerror = () => done(reject, new Error('jsonp'));
    tag.src = `${url}${url.includes('?') ? '&' : '?'}output=jsonp&callback=${cb}`;
    document.head.appendChild(tag);
  });
}

async function ru(q) {
  const d = await get(`https://api.music.yandex.net/search?text=${encodeURIComponent(q)}&type=track&page=0&nocorrect=false`);
  const list = (d && d.result && d.result.tracks && d.result.tracks.results) || [];
  return list
    .filter((t) => t && t.title && t.artists && t.artists.length)
    .map((t) => {
      const al = (t.albums && t.albums[0]) || {};
      return {
        id: 'cr' + t.id,
        source: 'chart',
        title: t.version ? `${t.title} (${t.version})` : t.title,
        artist: t.artists.map((a) => a.name).join(', '),
        artistId: null,
        artistPhoto: t.artists[0].cover ? img(t.artists[0].cover.uri, 1000) : '',
        album: al.title || '',
        albumId: null,
        artwork: img(t.coverUri),
        duration: t.durationMs ? Math.round(t.durationMs / 1000) : 0,
        explicit: t.contentWarning === 'explicit',
        year: al.year ? String(al.year) : '',
        genre: al.genre || '',
      };
    });
}

async function intl(q) {
  // Go through our server proxy — Deezer sends no CORS headers, and it's faster from Sweden.
  const url = `${MEDIA}/api/deezer/search?q=${encodeURIComponent(q)}&limit=25`;
  const r = await fetch(url, { signal: AbortSignal.timeout(8000) });
  if (!r.ok) throw new Error('deezer ' + r.status);
  const d = await r.json();
  return ((d && d.data) || [])
    .filter((t) => t && t.title && t.artist)
    .map((t) => ({
      id: 'cd' + t.id,
      source: 'chart',
      title: t.title,
      artist: t.artist.name,
      artistId: null,
      artistPhoto: t.artist.picture_xl || '',
      album: (t.album && t.album.title) || '',
      albumId: null,
      artwork: (t.album && (t.album.cover_xl || t.album.cover_big)) || '',
      duration: t.duration || 0,
      explicit: !!t.explicit_lyrics,
      year: '',
      genre: '',
    }));
}

async function sp(q) {
  const r = await fetch(`${MEDIA}/api/spotify/search?q=${encodeURIComponent(q)}`, { signal: AbortSignal.timeout(8000) });
  if (!r.ok) return [];
  const d = await r.json();
  return (d.tracks || []).map((t) => ({ ...t, source: 'chart', artistId: null, artistPhoto: '', albumId: null, genre: '' }));
}

export const trackKey = (t) => `${t.artist.split(/,|&| feat/i)[0]} ${t.title.replace(/\s*\((feat|with|prod)\.?[^)]*\)/gi, '')}`.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');

// Tracks from the other catalogs that `have` (Apple's results) doesn't already list.
// Only results that share words with the query: the Russian catalog sometimes leads with
// something unrelated by the same artist.
const words = (s) => s.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter((w) => w.length > 1);
function relevant(q, t) {
  const want = words(q);
  if (!want.length) return true;
  const have = new Set(words(`${t.title} ${t.artist}`));
  const hit = want.filter((w) => have.has(w)).length;
  return hit / want.length >= 0.5;
}

export async function searchMore(q, have = []) {
  const [r, i, s] = await Promise.all([bridge.isWeb ? [] : ru(q).catch(() => []), intl(q).catch(() => []), sp(q).catch(() => [])]);
  const lists = [i, s, r].map((l) => l.filter((t) => relevant(q, t)));
  const seen = new Set(have.map(trackKey));
  const out = [];
  for (const t of lists.flat()) {
    const k = trackKey(t);
    if (!k || seen.has(k)) continue;
    seen.add(k);
    out.push(t);
  }
  return out.slice(0, 30);
}
