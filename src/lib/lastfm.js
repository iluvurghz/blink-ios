// Last.fm: who sounds alike, and how many people listen.
const bridge = window.blink;
const KEY = import.meta.env.VITE_LASTFM_KEY;
const API = 'https://ws.audioscrobbler.com/2.0/';
// In the browser, Last.fm sends no CORS headers — go through our server proxy.
const MEDIA = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '');

async function call(params) {
  if (!KEY) return null;
  const q = new URLSearchParams({ ...params, api_key: KEY, format: 'json', autocorrect: '1' });
  // Desktop app: direct fetch through Electron (no CORS). Browser: server proxy.
  const url = bridge.isWeb ? `${MEDIA}/api/lastfm?${q}` : `${API}?${q}`;
  const r = await bridge.json(url);
  if (!r.ok || !r.data || r.data.error) return null;
  return r.data;
}

const cache = new Map();
function cached(key, fn) {
  if (!cache.has(key)) cache.set(key, fn().catch(() => null));
  return cache.get(key);
}

const mainName = (s) => s.split(/\s*(?:,|&|\sfeat\.?\s|\sft\.?\s|\sx\s)\s*/i)[0].trim();
const cleanTitle = (s) => s.replace(/\s*[([](feat|with|prod)[^)\]]*[)\]]/gi, '').trim();

export function listeners(artistName) {
  return cached('l:' + artistName, async () => {
    const want = mainName(artistName);
    const d = await call({ method: 'artist.getinfo', artist: want });
    // Autocorrect can swap a small artist for a famous namesake (kahoma → Kaoma): show nothing then.
    const n = (s) => (s || '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
    if (!d || !d.artist || n(d.artist.name) !== n(want)) return null;
    return d.artist.stats ? Number(d.artist.stats.listeners) : null;
  });
}

export function similarTracks(track, limit = 12) {
  return cached(`st:${track.artist}:${track.title}`, async () => {
    const d = await call({ method: 'track.getsimilar', artist: mainName(track.artist), track: cleanTitle(track.title), limit: String(limit) });
    const list = (d && d.similartracks && d.similartracks.track) || [];
    return list.map((t) => ({ artist: t.artist.name, title: t.name }));
  });
}

export function similarArtists(name, limit = 15) {
  return cached('sa:' + name, async () => {
    const d = await call({ method: 'artist.getsimilar', artist: mainName(name), limit: String(limit) });
    const list = (d && d.similarartists && d.similarartists.artist) || [];
    const own = mainName(name).toLowerCase();
    // Collabs of the same artist aren't "similar artists"; weak matches drift into other genres.
    return list
      .map((a) => ({ name: a.name, match: Number(a.match) || 0 }))
      .filter((a) => a.match >= 0.35 && !a.name.toLowerCase().includes(own));
  });
}

export const hasLastfm = !!KEY;
