// "Вспышка": an endless stream from what the listener likes and plays, plus artists
// that sound alike (Last.fm), kept inside the listener's own genres.
import { store } from './store.js';
import { artist as fetchArtist, charts, findArtistId, splitArtists, lookupTracks, toTrack } from './api.js';
import { similarArtists, hasLastfm } from './lastfm.js';
import { playableIds } from './cloud.js';
import { periodChart, topRu } from './charts.js';
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

// What the stream has already shown this listener (id -> [time, artist]). A track shown in the last
// day and a half never comes back; older ones come back less likely the more recent they are, and
// an artist who has just been heard a lot gets a small penalty. Kept on the device.
const SEEN_KEY = 'blink-wave-seen';
const SPARE_KEY = 'blink-wave-spare';
const NEXT_KEY = 'blink-wave-next';
let seenMem = null;
function seenMap() {
  if (!seenMem) {
    try {
      seenMem = JSON.parse(localStorage.getItem(SEEN_KEY)) || {};
    } catch {
      seenMem = {};
    }
  }
  return seenMem;
}
function markSeen(list) {
  const m = seenMap();
  const now = Date.now();
  list.forEach((t) => t && t.id && (m[t.id] = [now, (splitArtists(t.artist || '')[0] || '').toLowerCase()]));
  const keys = Object.keys(m);
  if (keys.length > 900) keys.sort((x, y) => m[x][0] - m[y][0]).slice(0, keys.length - 700).forEach((k) => delete m[k]);
  try {
    localStorage.setItem(SEEN_KEY, JSON.stringify(m));
  } catch {
    /* storage full: the memory copy still works */
  }
}
const DAY = 86400000;
function seenPenalty(t, now = Date.now()) {
  const e = seenMap()[t.id];
  if (!e) return 0;
  const age = now - e[0];
  return age < 1.5 * DAY ? Infinity : 2.5 * Math.exp(-age / (5 * DAY));
}
function artistFatigue() {
  const m = seenMap();
  const now = Date.now();
  const c = new Map();
  Object.values(m).forEach(([at, a]) => a && now - at < 3 * DAY && c.set(a, (c.get(a) || 0) + 1));
  return c;
}

// ---------- Taste profile ----------
// The stream is built from the listener's CORE (artists with several likes, repeat plays, full
// listens), not from every single like: one stray like is periphery and gets a small share of the
// seeds. Skips, «Не моё» and old plays pull weights down; everything fades with time.
const LISTEN_KEY = 'blink-wave-listen';
const GENRES_KEY = 'blink-wave-genres';
const NEG_KEY = 'blink-wave-neg';
const NEG_DAYS = 30;
const GENRE_MIN_SHARE = 0.06;
const CORE_SHARE = 0.85; // of the seeds
const MEDIA = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '');
const GENRES_URL = MEDIA + '/api/wave/genres';
const SIMILAR_URL = MEDIA + '/api/wave/similar-ids';

function loadObj(key) {
  try {
    const v = JSON.parse(localStorage.getItem(key));
    return v && typeof v === 'object' && !Array.isArray(v) ? v : {};
  } catch {
    return {};
  }
}
function saveObj(key, o) {
  try {
    localStorage.setItem(key, JSON.stringify(o));
  } catch {
    /* storage full: the memory copy still works */
  }
}
const lc = (x) => String(x || '').toLowerCase();
const isYm = (id) => /^cr\d+$/.test(String(id));

// Plays that were heard to the end (>70%), per artist, fading with a half-life of 45 days.
const LISTEN_HALF = 45 * 86400000;
function listenScores(now = Date.now()) {
  const raw = loadObj(LISTEN_KEY);
  const out = {};
  for (const [k, v] of Object.entries(raw)) {
    if (!Array.isArray(v)) continue;
    const sc = v[0] * Math.pow(0.5, (now - v[1]) / LISTEN_HALF);
    if (sc > 0.05) out[k] = sc;
  }
  return out;
}
// Call when a track was listened to (fraction 0..1 of its length): 70% or more counts as a
// positive signal for its artists; repeats stack up.
export function noteListen(track, fraction) {
  if (!track || !track.artist || !(fraction >= 0.7)) return;
  const now = Date.now();
  const cur = listenScores(now);
  splitArtists(track.artist).forEach((n) => (cur[lc(n)] = (cur[lc(n)] || 0) + 1));
  const keys = Object.keys(cur);
  if (keys.length > 400) keys.sort((x, y) => cur[x] - cur[y]).slice(0, keys.length - 300).forEach((k) => delete cur[k]);
  const raw = {};
  for (const k of Object.keys(cur)) raw[k] = [cur[k], now];
  saveObj(LISTEN_KEY, raw);
}

// Genres in Yandex's own format ('rap', 'local-indie'), resolved once per track through the server.
let genreMemo = null;
const genreMem = () => genreMemo || (genreMemo = loadObj(GENRES_KEY));
function setGenre(id, g) {
  const m = genreMem();
  delete m[id];
  m[id] = g || '-';
  const keys = Object.keys(m);
  if (keys.length > 2500) keys.slice(0, keys.length - 2000).forEach((k) => delete m[k]);
}
const saveGenres = () => saveObj(GENRES_KEY, genreMem());
function genreFor(t) {
  const g = genreMem()[t.id];
  if (g) return g === '-' ? '' : g;
  return isYm(t.id) && t.genre ? t.genre : ''; // other sources use other genre names: not comparable
}
const genreUntried = (t) => !genreMem()[t.id] && !(isYm(t.id) && t.genre);

// «Не моё» memory: ids of tracks that sound like a disliked one, and disliked genres. Fades in 30 days.
function loadNeg(now = Date.now()) {
  const raw = loadObj(NEG_KEY);
  const lim = NEG_DAYS * 86400000;
  const ids = {};
  for (const [id, at] of Object.entries(raw.ids || {})) if (now - at < lim) ids[id] = at;
  const genres = {};
  for (const [g, v] of Object.entries(raw.genres || {})) if (Array.isArray(v) && now - v[1] < lim) genres[g] = v;
  return { ids, genres };
}
function saveNeg(neg) {
  const keys = Object.keys(neg.ids);
  if (keys.length > 600) keys.sort((x, y) => neg.ids[x] - neg.ids[y]).slice(0, keys.length - 600).forEach((k) => delete neg.ids[k]);
  saveObj(NEG_KEY, neg);
}
const genrePenalty = (neg, g, now = Date.now()) => {
  const v = g && neg.genres[g];
  return v ? v[0] * Math.max(0, 1 - (now - v[1]) / (NEG_DAYS * 86400000)) : 0;
};
function bumpGenre(neg, g, now) {
  neg.genres[g] = [genrePenalty(neg, g, now) + 1, now];
}

function buildProfile() {
  const s = store.get();
  const now = Date.now();
  const ban = s.waveBan || {};
  const skipA = ban.skipArtists || {};
  const banA = ban.artists || {};
  const skippedIds = new Set(ban.skips || []);
  const listen = listenScores(now);
  const neg = loadNeg(now);
  const A = new Map();
  const get = (name) => {
    const k = lc(name);
    let a = A.get(k);
    if (!a) A.set(k, (a = { key: k, name, likes: 0, plays: 0, w: 0, rep: 0, liked: [], tracks: [] }));
    return a;
  };
  s.likes.forEach((t, i) => {
    if (!t || !t.title || !t.artist) return;
    const r = 1 / (1 + i / 150); // newest likes first
    splitArtists(t.artist).forEach((n) => {
      const a = get(n);
      a.likes++;
      a.w += r;
      a.liked.push(t);
      a.tracks.push(t);
    });
  });
  s.recent.forEach((t, i) => {
    if (!t || !t.title || !t.artist || skippedIds.has(t.id)) return;
    splitArtists(t.artist).forEach((n) => {
      const a = get(n);
      a.plays++;
      a.w += 0.6 / (1 + i / 20);
      a.tracks.push(t);
    });
  });
  for (const a of A.values()) {
    a.rep = listen[a.key] || 0;
    a.w += Math.min(4, a.rep) * 0.8;
    a.w -= 1.5 * Math.min(4, skipA[a.key] || 0) + 3 * (banA[a.key] || 0);
    if ((banA[a.key] || 0) >= 2) a.w = 0;
    a.w = Math.max(0, a.w);
  }
  const all = [...A.values()].filter((a) => a.w > 0.05 && a.tracks.length);
  let core = all.filter((a) => (a.likes >= 2 || a.plays >= 2 || a.rep >= 1.5) && a.w >= 0.3);
  if (!core.length) core = all; // too little history to tell core from periphery
  const coreSet = new Set(core.map((a) => a.key));
  const periph = all.filter((a) => !coreSet.has(a.key));
  core.sort((x, y) => y.w - x.w);

  // Genres: each artist spreads its weight over the genres of its known tracks.
  const gw = new Map();
  let totalW = 0;
  let knownW = 0;
  let knownN = 0;
  for (const a of all) {
    totalW += a.w;
    const c = new Map();
    a.tracks.forEach((t) => {
      const g = genreFor(t);
      if (g) c.set(g, (c.get(g) || 0) + 1);
    });
    const n = [...c.values()].reduce((x, y) => x + y, 0);
    if (!n) continue;
    knownW += a.w;
    knownN++;
    c.forEach((v, g) => gw.set(g, (gw.get(g) || 0) + (a.w * v) / n));
  }
  // Disliked genres lose weight (about the weight of two average artists per «Не моё»).
  const avgW = knownN ? knownW / knownN : 0;
  for (const g of [...gw.keys()]) gw.set(g, Math.max(0, gw.get(g) - 2 * avgW * genrePenalty(neg, g, now)));
  const gTotal = [...gw.values()].reduce((x, y) => x + y, 0);
  const share = new Map();
  const top = new Set();
  if (gTotal > 0)
    gw.forEach((v, g) => {
      share.set(g, v / gTotal);
      if (v / gTotal >= GENRE_MIN_SHARE) top.add(g);
    });
  // Without enough known genres the filter stays off rather than guessing from a sliver.
  const active = totalW > 0 && knownW / totalW >= 0.35 && knownN >= 4 && top.size > 0;

  // Tracks whose genre is still unknown, core artists first: asked from the server in the background.
  const unresolved = [];
  for (const a of [...core, ...periph]) {
    if (unresolved.length >= 16) break;
    if (a.tracks.some((t) => genreFor(t))) continue;
    const t = a.tracks.find(genreUntried);
    if (t) unresolved.push({ id: t.id, token: isYm(t.id) ? t.id : `${splitArtists(t.artist)[0] || t.artist} ${t.title}`.replace(/\|/g, ' ') });
  }
  const aff = (t) => Math.min(1, Math.max(0, ...splitArtists(t.artist).map((n) => ((A.get(lc(n)) || {}).w || 0) / 4)));
  return { artists: A, core, periph, share, top, active, unresolved, aff, neg };
}

async function resolveGenres(list) {
  const todo = list.slice(0, 16);
  if (!todo.length) return;
  try {
    const r = await fetch(`${GENRES_URL}?items=${encodeURIComponent(todo.map((x) => x.token).join('|'))}`, { signal: AbortSignal.timeout(6000) });
    if (!r.ok) return;
    const g = (await r.json()).genres || {};
    let any = false;
    todo.forEach((x) => {
      if (g[x.token] !== undefined) {
        setGenre(x.id, g[x.token]);
        any = true;
      }
    });
    if (any) saveGenres();
  } catch {
    /* offline or an older server: the profile just stays as it is */
  }
}

function readJson(key) {
  try {
    return JSON.parse(localStorage.getItem(key)) || [];
  } catch {
    return [];
  }
}

// The first tracks of a new «Вспышка», without waiting for the network: tracks kept from the last
// batch (picked for this listener, never shown yet), then whatever is left of an older batch.
export function quickStart() {
  const s = store.get();
  const wb = s.waveBan || { ids: [] };
  const ban = new Set([...wb.ids, ...(wb.skips || [])]);
  const recent = new Set(s.recent.slice(0, 30).map((t) => t.id));
  const liked = new Set(s.likes.map((t) => t.id));
  const now = Date.now();
  const negIds = loadNeg(now).ids;
  const ok = (t) => t && t.id && !ban.has(t.id) && !negIds[t.id] && !recent.has(t.id) && !liked.has(t.id) && !isAi(t) && seenPenalty(t, now) !== Infinity;
  const spare = readJson(SPARE_KEY).filter(ok);
  let first = [];
  if (spare.length >= 3) first = pick(spare, 4);
  else {
    const left = readJson(NEXT_KEY).filter(ok);
    if (left.length >= 2) first = pick(left, 3);
  }
  if (first.length) {
    const used = new Set(first.map((t) => t.id));
    try {
      localStorage.setItem(SPARE_KEY, JSON.stringify(spare.filter((t) => !used.has(t.id))));
      localStorage.setItem(NEXT_KEY, '[]');
    } catch {
      /* storage full */
    }
    markSeen(first);
    return first;
  }
  // Nothing kept yet (first run): a played track that is not a favourite, as before.
  const played = s.recent.filter((t) => ok(t));
  return played.length >= 2 ? pick(played, 3) : pick([...s.likes, ...s.recent].filter((t) => t && t.id && !ban.has(t.id) && !isAi(t)), 3);
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

async function legacyBatch(size = 16) {
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
  const bannedIds = new Set([...ban.ids, ...(ban.skips || []), ...Object.keys(loadNeg().ids)]);
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

// ---------- «Вспышка» v2: Яндекс вместо Last.fm ----------
// Сервер (Москва) по нескольким любимым трекам отдаёт похожие по звучанию (собственная похожесть
// Яндекса), популярное у артиста и у похожих артистов. К этому добавляются главный чарт и
// недельный/месячный чарты новинок. Сиды берутся в основном из ядра вкуса (см. buildProfile),
// кандидат проходит, если его жанр в топ-жанрах слушателя или он всплыл у двух сидов ядра; остальное
// — только слот «исследование» (~10% батча, выключается settings.waveExplore === false).
// Каждый трек получает оценку, выбор идёт взвешенно, корзинами (похожее / популярное / чарты).
const POOL_URL = MEDIA + '/api/wave/pool';
const poolCache = new Map();

async function yandexPool(seedTracks) {
  const seeds = seedTracks.map((t) => `${splitArtists(t.artist)[0] || t.artist} ${t.title}`.replace(/\|/g, ' ').trim()).filter(Boolean);
  if (!seeds.length) return { tracks: [], seedGenre: [] };
  const key = seeds.join('|');
  const hit = poolCache.get(key);
  if (hit && Date.now() - hit.at < 20 * 60 * 1000) return hit.res;
  const r = await fetch(`${POOL_URL}?seeds=${encodeURIComponent(key)}&n=${seeds.length}`, { signal: AbortSignal.timeout(15000) });
  if (!r.ok) throw new Error('HTTP ' + r.status);
  const j = await r.json();
  const res = { tracks: j.tracks || [], seedGenre: j.seedGenre || [] };
  poolCache.set(key, { at: Date.now(), res });
  if (poolCache.size > 20) poolCache.delete(poolCache.keys().next().value);
  return res;
}

// What the server says about the seeds' own genres feeds the profile.
function learnSeedGenres(seedTracks, res) {
  if (!res || !res.seedGenre || res.seedGenre.length !== seedTracks.length) return;
  seedTracks.forEach((t, i) => {
    const g = res.seedGenre[i];
    if (g && g.genre && genreUntried(t)) setGenre(t.id, g.genre);
  });
}

// Seeds: ~85% from the core (weighted, flattened so the long tail of the core gets its turn),
// the rest from the periphery; one track per artist.
function pickSeeds(profile, n = 6) {
  const trackOf = (a) => pick(a.liked.length ? a.liked : a.tracks, 1)[0];
  const nCore = Math.min(profile.core.length, profile.periph.length ? Math.max(1, Math.round(n * CORE_SHARE)) : n);
  const nPer = Math.min(profile.periph.length, n - nCore);
  const used = new Set();
  const grab = (list, k, wf) => {
    const out = [];
    for (const x of pickWeighted(list.map((a) => ({ a, w: wf(a) })), list.length)) {
      if (out.length >= k) break;
      const t = trackOf(x.a);
      if (!t || used.has(t.id)) continue;
      used.add(t.id);
      out.push(t);
    }
    return out;
  };
  return {
    core: grab(profile.core, nCore, (a) => Math.pow(a.w, 0.8)),
    periph: grab(profile.periph, nPer, (a) => 1 + Math.sqrt(a.w)),
  };
}

// Weighted pick without replacement; temp > 1 flattens the weights (more variety).
function sample(scored, n, temp = 1.2) {
  const pool = scored.map((x) => ({ ...x, w: Math.exp(Math.max(-6, Math.min(8, x.score)) / temp) }));
  const out = [];
  while (pool.length && out.length < n) {
    const total = pool.reduce((a, x) => a + x.w, 0);
    let r = Math.random() * total;
    let i = pool.findIndex((x) => (r -= x.w) <= 0);
    if (i < 0) i = pool.length - 1;
    out.push(pool.splice(i, 1)[0]);
  }
  return out;
}

export async function waveBatch(size = 16) {
  try {
    const out = await yandexBatch(size);
    if (out.length >= Math.min(6, size)) return out;
  } catch {
    /* Yandex is down: the older mix below */
  }
  return legacyBatch(size);
}

async function yandexBatch(size) {
  const s = store.get();
  const mode = s.settings.waveMode || 'mix';
  const exploreOn = s.settings.waveExplore !== false;
  let prof = buildProfile();
  const seeds = pickSeeds(prof, 6);
  const [coreRes, perRes, top, weekly, monthly] = await Promise.all([
    seeds.core.length ? yandexPool(seeds.core).catch(() => null) : null,
    seeds.periph.length ? yandexPool(seeds.periph).catch(() => null) : null,
    topRu().catch(() => null),
    periodChart('weekly').catch(() => []),
    Math.random() < 0.5 ? periodChart('monthly').catch(() => []) : Promise.resolve([]),
    resolveGenres(prof.unresolved), // slowly fills in the genres of the likes
  ]);
  if (!(coreRes && coreRes.tracks.length) && !(perRes && perRes.tracks.length) && !(top && top.length) && !weekly.length) return [];
  learnSeedGenres(seeds.core, coreRes);
  learnSeedGenres(seeds.periph, perRes);
  saveGenres();
  prof = buildProfile(); // with the genres just learned

  // Pool of similar/popular tracks; "hits" counts only the core seeds.
  const pool = new Map();
  const addPool = (res, isCore) =>
    ((res && res.tracks) || []).forEach((t) => {
      const cur = pool.get(t.id);
      if (cur) cur.hits += isCore ? t.hits || 1 : 0;
      else pool.set(t.id, { t, hits: isCore ? t.hits || 1 : 0 });
    });
  addPool(coreRes, true);
  addPool(perRes, false);
  const haveTaste = pool.size > 0;

  const now = Date.now();
  const year = new Date().getFullYear();
  const likedIds = new Set(s.likes.map((t) => t.id));
  const likedArtists = new Set(tasteArtists().slice(0, 40).map((a) => a.name.toLowerCase()));
  const freshW = mode === 'fresh' ? 2 : 1;
  const fatigue = artistFatigue();
  const cand = new Map();
  const add = (t, base, bucket, hits = 0) => {
    if (!t || !t.id) return;
    const cur = cand.get(t.id);
    if (cur) {
      cur.score += base * 0.5;
      cur.hits = Math.max(cur.hits, hits);
    } else cand.set(t.id, { t, score: base, bucket, hits });
  };
  pool.forEach(({ t, hits }) => {
    const b = t.src === 'similar' ? 1.2 + 0.6 * Math.min(3, hits || 1) : t.src === 'popular' ? 1.4 : 0.9;
    add(t, b, t.src === 'similar' ? 'similar' : 'pop', hits);
  });
  const chartScore = (i, n) => 1.6 - (i / Math.max(1, n)) * 1.2; // the higher in the chart, the better
  (top || []).forEach((t, i) => add(t, chartScore(i, top.length), 'chart'));
  weekly.slice(0, 60).forEach((t, i) => add(t, 1.4 - (i / 60) * 1.0 + 0.5 * freshW, 'chart')); // new Russian releases
  monthly.slice(0, 60).forEach((t, i) => add(t, 1.0 - (i / 60) * 0.8 + 0.3 * freshW, 'chart'));

  const queued = new Set(s.queue.map((t) => t.id));
  const recent = new Set(s.recent.slice(0, 30).map((t) => t.id));
  const ban = s.waveBan || { ids: [], artists: {} };
  const bannedIds = new Set([...(ban.ids || []), ...(ban.skips || [])]);
  const skippedArtists = ban.skipArtists || {};

  // Tiers: A passes the taste filter, U has no genre to judge by, E is a known off-profile genre
  // (only for the «exploration» slot).
  const tiers = { A: [], U: [], E: [] };
  for (const { t, score, bucket, hits } of cand.values()) {
    if (queued.has(t.id) || recent.has(t.id) || bannedIds.has(t.id) || prof.neg.ids[t.id] || isAi(t)) continue;
    const names = splitArtists(t.artist).map((n) => n.toLowerCase());
    if (names.some((n) => (ban.artists[n] || 0) >= 2 || (skippedArtists[n] || 0) >= 3)) continue;
    if (mode === 'discover' && names.some((n) => likedArtists.has(n))) continue;
    const seenP = seenPenalty(t, now);
    if (seenP === Infinity) continue;
    const g = t.genre || '';
    const gPen = genrePenalty(prof.neg, g, now);
    if (gPen >= 3) continue;
    let tier = 'A';
    if (prof.active && !((g && prof.top.has(g)) || hits >= 2)) tier = g ? 'E' : 'U';

    let sc = score - seenP;
    if (g && prof.top.has(g)) sc += 0.2 + 0.5 * Math.min(1, (prof.share.get(g) || 0) / 0.3);
    sc -= 0.6 * gPen;
    // Freshness: releases of the last months get a push.
    const rel = t.released ? Date.parse(t.released) : NaN;
    if (!Number.isNaN(rel) && now - rel < 90 * DAY) sc += 1.0 * freshW;
    else if (Number(t.year) >= year) sc += 0.6 * freshW;
    else if (Number(t.year) === year - 1) sc += 0.2 * freshW;
    // Artists the listener plays a lot are welcome, but not the same ones over and over.
    if (mode !== 'discover') sc += 0.9 * prof.aff(t);
    sc -= 0.5 * Math.min(3, Math.max(0, ...names.map((n) => fatigue.get(n) || 0)));
    sc -= 1.2 * Math.max(0, ...names.map((n) => ban.artists[n] || 0)); // «Не моё» once: much rarer
    if (likedIds.has(t.id)) sc -= 3; // already in «Любимое»
    if (mode === 'known' && names.some((n) => likedArtists.has(n))) sc += 1;
    tiers[tier].push({ t, score: sc, bucket });
  }

  // Quotas by bucket, so a batch is never only the chart, nor only one kind of match.
  const q = haveTaste ? { similar: 0.45, pop: 0.25, chart: 0.3 } : { chart: 1 };
  const nExplore = prof.active && exploreOn ? Math.max(1, Math.round(size * 0.1)) : 0;
  const mainSize = size - nExplore;
  const taken = new Set();
  const count = new Map();
  const out = [];
  const take = (arr, n) => {
    for (const x of arr) {
      if (out.length >= size || n <= 0) break;
      if (taken.has(x.t.id)) continue;
      const k = (x.t.artist || '').toLowerCase();
      if ((count.get(k) || 0) >= 2) continue; // one artist at most twice in a batch
      count.set(k, (count.get(k) || 0) + 1);
      taken.add(x.t.id);
      out.push(x.t);
      n--;
    }
  };
  const rest = (list) => list.filter((x) => !taken.has(x.t.id));
  for (const [bucket, share] of Object.entries(q)) {
    const list = tiers.A.filter((x) => x.bucket === bucket);
    take(sample(list, Math.ceil(mainSize * share) * 3), Math.round(mainSize * share));
  }
  take(sample(rest(tiers.A), mainSize * 3), mainSize - out.length);
  take(sample(rest(tiers.U), mainSize * 3), mainSize - out.length); // genre unknown: better than nothing
  if (nExplore) take(sample(rest(tiers.E), nExplore * 3), nExplore);
  if (out.length < size) {
    take(sample(rest(tiers.A), size * 3), size - out.length);
    take(sample(rest(tiers.U), size * 3), size - out.length);
    if (exploreOn) take(sample(rest(tiers.E), size * 3), size - out.length);
  }

  // The rest of the good candidates wait on the device: the next «Вспышка» opens with them at once.
  try {
    const spare = sample(rest([...tiers.A, ...tiers.U]), 24).map((x) => x.t);
    localStorage.setItem(SPARE_KEY, JSON.stringify(spare));
  } catch {
    /* storage full */
  }
  markSeen(out);
  return shuffle(out);
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

// «Не моё» on the playing track: the track and its artist's other songs leave the stream (an
// artist marked twice goes for good), its genre loses weight, and tracks that sound like it are
// remembered for 30 days (asked from the server). Then the caller moves on.
export function dislike(track) {
  if (!track || !track.id) return;
  const s = store.get();
  const ban = s.waveBan || { ids: [], artists: {} };
  const artists = { ...ban.artists };
  splitArtists(track.artist).forEach((n) => (artists[n.toLowerCase()] = (artists[n.toLowerCase()] || 0) + 1));
  const waveBan = { ...ban, ids: [...ban.ids.filter((id) => id !== track.id), track.id].slice(-500), artists };
  const gone = (t) => t.id === track.id || splitArtists(t.artist).some((n) => (artists[n.toLowerCase()] || 0) >= 2);
  const queue = s.queue.filter((t, i) => i <= s.index || !gone(t));
  store.set({ waveBan, queue });

  const now = Date.now();
  const neg = loadNeg(now);
  neg.ids[track.id] = now;
  const g = genreFor(track);
  if (g) bumpGenre(neg, g, now);
  saveNeg(neg);
  const seed = isYm(track.id) ? track.id : `${splitArtists(track.artist)[0] || track.artist} ${track.title}`.replace(/\|/g, ' ');
  fetch(`${SIMILAR_URL}?seed=${encodeURIComponent(seed)}`, { signal: AbortSignal.timeout(10000) })
    .then((r) => (r.ok ? r.json() : null))
    .then((d) => {
      if (!d) return;
      const n = loadNeg();
      const at = Date.now();
      (d.ids || []).forEach((id) => !n.ids[id] && (n.ids[id] = at));
      if (!g && d.genre) {
        bumpGenre(n, d.genre, at);
        setGenre(track.id, d.genre);
        saveGenres();
      }
      saveNeg(n);
    })
    .catch(() => {
      /* offline: the track and artist are already out */
    });
}
export const notThis = dislike;

export const WAVE_MODES = [
  ['mix', 'Микс'],
  ['known', 'Знакомое'],
  ['discover', 'Открытия'],
  ['fresh', 'Новое'],
];
