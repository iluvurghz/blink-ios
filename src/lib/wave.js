// "Вспышка": an endless stream from what the listener likes and plays, plus artists
// that sound alike (Last.fm), kept inside the listener's own genres.
import { store } from './store.js';
import { artist as fetchArtist, charts, findArtistId, splitArtists, lookupTracks, toTrack } from './api.js';
import { similarArtists, hasLastfm } from './lastfm.js';
import { playableIds } from './cloud.js';
import { periodChart } from './charts.js';
import { isAi } from './aiFilter.js';

function shuffle(a) {
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}
const pick = (a, n) => shuffle([...a]).slice(0, n);

// Individual artists ("VILLIAN & Aarne" counts for both), weighted by likes (x3) and plays (x1).
export function tasteArtists() {
  const s = store.get();
  const score = new Map();
  const add = (t, w) => {
    const names = splitArtists(t.artist);
    names.forEach((name) => {
      const key = name.toLowerCase();
      const cur = score.get(key) || { name, id: names.length === 1 ? t.artistId : null, w: 0 };
      cur.w += w / names.length;
      score.set(key, cur);
    });
  };
  const skipped = new Set((s.waveBan || {}).skips || []);
  s.likes.forEach((t) => add(t, 3));
  s.recent.forEach((t) => !skipped.has(t.id) && add(t, 1));
  return [...score.values()].sort((a, b) => b.w - a.w);
}

function pickWeighted(list, n) {
  const pool = [...list];
  const out = [];
  while (pool.length && out.length < n) {
    const total = pool.reduce((a, x) => a + x.w, 0);
    let r = Math.random() * total;
    const i = pool.findIndex((x) => (r -= x.w) <= 0);
    out.push(pool.splice(Math.max(0, i), 1)[0]);
  }
  return out;
}

// Artists' songs are kept on the device for two days, so the next «Вспышка» doesn't wait on the
// same lookups again (the slow part of building a batch).
const SONGS_KEY = 'blink-artist-songs';
const SONGS_TTL = 2 * 24 * 3600 * 1000;
let disk = null;
function songsDisk() {
  if (!disk) {
    try {
      disk = JSON.parse(localStorage.getItem(SONGS_KEY)) || {};
    } catch {
      disk = {};
    }
  }
  return disk;
}
let saveTimer = 0;
function keepSongs(key, list) {
  const d = songsDisk();
  delete d[key];
  d[key] = { at: Date.now(), list };
  const keys = Object.keys(d);
  for (const old of keys.slice(0, Math.max(0, keys.length - 60))) delete d[old];
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    try {
      localStorage.setItem(SONGS_KEY, JSON.stringify(d));
    } catch {
      /* storage full: the memory copy still works */
    }
  }, 1500);
}

const YM_PROXY = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '') + '/api/yandex';

const artistCache = new Map();
async function songsOf(name, id, country) {
  const key = (id || name).toLowerCase();
  if (!artistCache.has(key)) {
    const hit = songsDisk()[key];
    if (hit && Date.now() - hit.at < SONGS_TTL) artistCache.set(key, Promise.resolve(hit.list));
    else
      artistCache.set(
        key,
        (async () => {
          const s = store.get();
          const useYandex = s.yandexAsPrimary || s.yandexSearchOnly;

          if (useYandex) {
            // Yandex path: search artist by name first to get Yandex artist ID, then fetch tracks
            const realId = id || (await findArtistId(name, country).catch(() => null));
            if (realId) {
              try {
                const r = await fetch(`${YM_PROXY}/artist/${realId}/tracks?limit=25&metaOnly=true`, {
                  signal: AbortSignal.timeout(20000),
                });
                if (r.ok) {
                  const data = await r.json();
                  const list = (data.results || [])
                    .filter((x) => x.kind === 'song')
                    .map(toTrack)
                    .slice(0, 25);
                  if (list.length) { keepSongs(key, list); return list; }
                }
              } catch { /* fall through to iTunes */ }
            }
            // Yandex search fallback: search by artist name
            try {
              const r = await fetch(`${YM_PROXY}/search?q=${encodeURIComponent(name)}&type=track&limit=25`, {
                signal: AbortSignal.timeout(15000),
              });
              if (r.ok) {
                const data = await r.json();
                const norm = (s) => (s || '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
                const list = (data.results || [])
                  .filter((x) => x.kind === 'song')
                  .filter((x) => norm(x.artistName || '').includes(norm(name)))
                  .map(toTrack)
                  .slice(0, 20);
                if (list.length) { keepSongs(key, list); return list; }
              }
            } catch { /* fall through to iTunes */ }
          }

          // iTunes path (default or Yandex fallback)
          const realId = id || (await findArtistId(name, country).catch(() => null));
          if (!realId) return [];
          const a = await fetchArtist(realId, country).catch(() => null);
          const list = a ? a.tracks.slice(0, 20) : [];
          if (list.length) keepSongs(key, list);
          return list;
        })()
      );
  }
  return artistCache.get(key);
}

// The first track of a new «Вспышка», without waiting for the network: what is left of the last
// batch, or something the listener likes or played, not heard in the last few tracks.
const NEXT_KEY = 'blink-wave-next';
export function quickStart() {
  const s = store.get();
  const wb = s.waveBan || { ids: [] };
  const ban = new Set([...wb.ids, ...(wb.skips || [])]);
  const recent = new Set(s.recent.slice(0, 8).map((t) => t.id));
  const ok = (t) => t && t.id && !ban.has(t.id) && !recent.has(t.id) && !isAi(t);
  let saved = [];
  try {
    saved = JSON.parse(localStorage.getItem(NEXT_KEY)) || [];
  } catch {
    /* none */
  }
  const heard = new Set(s.recent.slice(0, 60).map((t) => t.id));
  const left = saved.filter((t) => ok(t) && !heard.has(t.id));
  if (left.length >= 2) return left.slice(0, 4);
  // Liked tracks only when nothing else was played: the stream should not open with the favourites.
  const liked = new Set(s.likes.map((t) => t.id));
  const played = s.recent.filter((t) => ok(t) && !liked.has(t.id));
  return played.length >= 2 ? pick(played, 3) : pick([...s.likes, ...s.recent].filter(ok), 3);
}

// Tracks in the spirit of one track: artists Last.fm calls similar to its artist.
export async function similarTo(track, size = 10) {
  if (!hasLastfm || !track) return [];
  const name = splitArtists(track.artist || '')[0];
  if (!name) return [];
  const country = store.get().settings.country;
  const sim = await similarArtists(name).catch(() => []);
  const names = pickWeighted(sim.filter((x) => x && x.name).map((x) => ({ name: x.name, w: x.match || 0.5 })), 5);
  const lists = await Promise.all(names.map((n) => songsOf(n.name, null, country).then((list) => pick(list.filter((t) => !isAi(t)), 2))));
  return shuffle(lists.flat()).slice(0, size);
}

// The listener's genres, from Apple's data for the tracks they like.
let genreCache = { key: '', set: null };
async function tasteGenres(country) {
  const s = store.get();
  const sample = [...s.likes, ...s.recent].slice(0, 60);
  const key = sample.map((t) => t.id).join(',');
  if (genreCache.key === key) return genreCache.set;
  const known = sample.filter((t) => t.genre);
  const missing = sample.filter((t) => !t.genre).map((t) => t.id);
  const looked = missing.length ? await lookupTracks(missing.slice(0, 150), country).catch(() => []) : [];
  const count = new Map();
  [...known, ...looked].forEach((t) => t.genre && count.set(t.genre, (count.get(t.genre) || 0) + 1));
  const total = [...count.values()].reduce((a, b) => a + b, 0);
  // Genres that make up at least 10% of what you like.
  const set = new Set([...count.entries()].filter(([, c]) => c / total >= 0.1).map(([g]) => g));
  genreCache = { key, set: set.size ? set : null };
  return genreCache.set;
}

export async function waveBatch(size = 16) {
  const s = store.get();
  const country = s.settings.country;
  const avoid = new Set([...s.recent.slice(0, 60).map((t) => t.id), ...s.queue.map((t) => t.id)]);
  const artists = tasteArtists();
  if (!artists.length) {
    // Nothing to go on yet: start from what's popular.
    const c = await charts(country).catch(() => ({ tracks: [] }));
    return pick(c.tracks, size);
  }
  const genres = await tasteGenres(country);
  const fits = (t) => !genres || !t.genre || genres.has(t.genre);

  const own = Promise.all(pickWeighted(artists, 6).map((a) => songsOf(a.name, a.id, country).then((list) => pick(list, 2))));
  let similar = Promise.resolve([]);
  if (hasLastfm) {
    similar = Promise.all(pickWeighted(artists.slice(0, 12), 4).map((a) => similarArtists(a.name)))
      .then((lists) => {
        const merged = new Map();
        lists.flat().forEach((x) => x && merged.set(x.name.toLowerCase(), { name: x.name, w: Math.max(x.match, (merged.get(x.name.toLowerCase()) || {}).w || 0) }));
        return pickWeighted([...merged.values()], 8);
      })
      .then((names) => Promise.all(names.map((n) => songsOf(n.name, null, country).then((list) => pick(list.filter(fits), 2)))));
  }
  const mode = s.settings.waveMode || 'mix';
  const fresh = mode === 'fresh' ? periodChart('weekly').then((l) => pick(l.slice(0, 40), 6)).catch(() => []) : Promise.resolve([]);
  const [ownSongs, similarSongs, hot] = await Promise.all([own, similar, fresh]);
  const year = new Date().getFullYear();
  const liked = new Set(artists.slice(0, 30).map((a) => a.name.toLowerCase()));
  const parts =
    mode === 'known'
      ? [...pick(s.likes, 2), ...ownSongs.flat()]
      : mode === 'discover'
        ? similarSongs.flat().filter((t) => t && !splitArtists(t.artist).some((n) => liked.has(n.toLowerCase())))
        : mode === 'fresh'
          ? [...ownSongs.flat(), ...similarSongs.flat()].filter((t) => t && Number(t.year) >= year - 1).concat(hot)
          : [...ownSongs.flat(), ...similarSongs.flat()];
  // A narrow mode that found too little is topped up from the usual mix.
  let pool = parts.length >= 4 ? parts : [...parts, ...ownSongs.flat(), ...similarSongs.flat(), ...pick(s.likes, 3)];
  const seen = new Set();
  pool = pool.filter((t) => t && !avoid.has(t.id) && !isAi(t) && !seen.has(t.id) && seen.add(t.id));

  // «Не то»: never that track again; an artist marked twice leaves the stream.
  // A track skipped in its first seconds stays out too; an artist skipped like that 3 times leaves.
  const ban = s.waveBan || { ids: [], artists: {} };
  const bannedIds = new Set([...ban.ids, ...(ban.skips || [])]);
  const skippedArtists = ban.skipArtists || {};
  pool = pool.filter(
    (t) =>
      !bannedIds.has(t.id) &&
      !splitArtists(t.artist).some((n) => (ban.artists[n.toLowerCase()] || 0) >= 2 || (skippedArtists[n.toLowerCase()] || 0) >= 3)
  );

  // Liked tracks are already in «Любимое»: here they turn up rarely, one per batch at most
  // (two in «Знакомое»), and only now and then.
  const likedIds = new Set(s.likes.map((t) => t.id));
  let likedLeft = mode === 'known' ? 2 : Math.random() < 0.35 ? 1 : 0;
  const fewLiked = shuffle(pool).filter((t) => !likedIds.has(t.id) || likedLeft-- > 0);
  // Someone who has only likes so far still gets a stream.
  if (fewLiked.length >= 4) pool = fewLiked;

  // Limit tracks per artist to max 2 to avoid one artist dominating the stream
  const artistCount = new Map();
  pool = pool.filter((t) => {
    const key = (t.artist || '').toLowerCase();
    const count = artistCount.get(key) || 0;
    if (count >= 2) return false;
    artistCount.set(key, count + 1);
    return true;
  });

  const out = shuffle(pool).slice(0, size);
  // The tail of this batch starts the next «Вспышка» instantly.
  try {
    localStorage.setItem(NEXT_KEY, JSON.stringify(out.slice(Math.floor(out.length / 2))));
  } catch {
    /* storage full */
  }
  return out;
}

// A track skipped by hand in its first seconds: kept out of the stream, and an artist skipped
// like that three times leaves it (a softer «Не то»).
export function noteSkip(track) {
  if (!track || !track.id) return;
  const ban = store.get().waveBan || { ids: [], artists: {} };
  const skipArtists = { ...(ban.skipArtists || {}) };
  splitArtists(track.artist).forEach((n) => (skipArtists[n.toLowerCase()] = (skipArtists[n.toLowerCase()] || 0) + 1));
  const skips = [...(ban.skips || []).filter((id) => id !== track.id), track.id].slice(-500);
  store.set({ waveBan: { ...ban, skips, skipArtists } });
}

// «Не то» on the playing track: remember it, drop it and its artist's other songs from the
// queue ahead when the artist got it twice, then go on.
export function notThis(track) {
  const s = store.get();
  const ban = s.waveBan || { ids: [], artists: {} };
  const artists = { ...ban.artists };
  splitArtists(track.artist).forEach((n) => (artists[n.toLowerCase()] = (artists[n.toLowerCase()] || 0) + 1));
  const waveBan = { ...ban, ids: [...ban.ids.filter((id) => id !== track.id), track.id].slice(-500), artists };
  const gone = (t) => t.id === track.id || splitArtists(t.artist).some((n) => (artists[n.toLowerCase()] || 0) >= 2);
  const queue = s.queue.filter((t, i) => i <= s.index || !gone(t));
  store.set({ waveBan, queue });
}

export const WAVE_MODES = [
  ['mix', 'Микс'],
  ['known', 'Знакомое'],
  ['discover', 'Открытия'],
  ['fresh', 'Новое'],
];
