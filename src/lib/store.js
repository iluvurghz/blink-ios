import { useSyncExternalStore } from 'react';

function createStore(initial) {
  let state = initial;
  const subs = new Set();
  return {
    get: () => state,
    set(patch) {
      const next = typeof patch === 'function' ? patch(state) : patch;
      state = { ...state, ...next };
      subs.forEach((f) => f());
    },
    subscribe(f) {
      subs.add(f);
      return () => subs.delete(f);
    },
  };
}

export const store = createStore({
  loaded: false,
  view: { name: 'home', params: {} },
  back: [],
  settings: { ytKey: '', country: 'ru', intro: false, crossfade: 3, game: false },
  likes: [],
  // «Вспышка»: tracks marked «не то» and how often each artist got it.
  waveBan: { ids: [], artists: {} },
  aiBan: { artists: [] }, // artists marked «Это нейротрек» (see aiFilter.js)
  playlists: [],
  recent: [],
  ytCache: {},
  lens: {}, // real lengths (seconds) learned while playing, for tracks whose source gave none
  dead: {}, // tracks that failed to play: id → time, hidden from search for 30 days
  via: {}, // how each track last played: 'mp3' (parser) or 'yt', for the source badge
  lyricShift: {},
  svc: null, // live service health (status page), not persisted
  flow: false, // true once an endless auto-flow has extended the queue
  devices: null, // this account's active devices (sessions), live
  volume: 80,
  muted: false,
  queue: [],
  index: -1,
  shuffle: false,
  repeat: 'off',
  track: null,
  status: 'idle',
  videoMode: 'audio',
  hasClip: false,
  stage: false,
  stageTab: 'lyrics',
  sheet: null,
  toast: null,
  menu: null,
  query: '',
  palette: null,
  plus: null, // Blink+ paid-until date (ISO) while the subscription is active
  supporter: null, // date (ISO) the account first supported Blink × Spherical («Хранитель» badge)
  saved: [], // tracks kept on the device for listening offline (offline.js)
  // Admin-controlled source flags (loaded from /api/mp3/config at startup).
  youtubeEnabled: true,
  parserEnabled: false,
  apiblinkEnabled: true,
  yandexAsPrimary: false,
  yandexSearchOnly: false,
});

// Playback clock lives apart so the progress bar doesn't re-render the whole tree.
export const clock = createStore({ time: 0, duration: 0, at: 0, playing: false });

export function useStore(sel) {
  return useSyncExternalStore(store.subscribe, () => sel(store.get()));
}
export function useClock(sel) {
  return useSyncExternalStore(clock.subscribe, () => sel(clock.get()));
}

// Smooth time for lyrics: last reported time plus the wall clock since then.
export function nowTime() {
  const c = clock.get();
  if (!c.playing) return c.time;
  return c.time + (performance.now() - c.at) / 1000;
}

// YouTube API data (found video ids) is kept at most 30 days, then looked up again (YouTube API policy).
export const YT_TTL = 30 * 24 * 60 * 60 * 1000;
export const ytFresh = (v) => !!v && Date.now() - (v.at || 0) < YT_TTL;
function pruneYtCache() {
  const cache = store.get().ytCache || {};
  const kept = Object.fromEntries(Object.entries(cache).filter(([, v]) => ytFresh(v)));
  if (Object.keys(kept).length !== Object.keys(cache).length) store.set({ ytCache: kept });
}

const PERSIST = ['settings', 'likes', 'waveBan', 'aiBan', 'playlists', 'recent', 'ytCache', 'dead', 'via', 'lens', 'lyricShift', 'volume', 'muted', 'queue', 'index', 'shuffle', 'repeat', 'plus', 'saved'];

const MEDIA_BASE = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '');

export async function loadState() {
  const [data, builtinKey, apiParserUrl] = await Promise.all([
    window.blink.load().then((d) => d || {}),
    window.blink.builtinKey ? window.blink.builtinKey() : '',
    window.blink.apiParserUrl ? window.blink.apiParserUrl() : '',
  ]);
  const patch = { loaded: true, builtinKey, apiParserUrl };
  for (const k of PERSIST) if (data[k] !== undefined) patch[k] = data[k];
  // One region for charts and search (Russia): the region picker was removed.
  patch.settings = { ...store.get().settings, ...(data.settings || {}), country: 'ru' };
  if (patch.queue && patch.index >= 0) patch.track = patch.queue[patch.index] || null;

  // Sanitize artwork URLs stored with localhost/127.0.0.1 (old bug — replace with proper proxy URL).
  // Also clear expired /api/apiblink/artwork/:id URLs — these use temporary stream IDs (4h TTL)
  // and will return 404. Clearing them forces a fresh lookup on next display.
  const fixArtwork = (t) => {
    if (!t || !t.artwork) return t;
    const a = t.artwork;
    // Fix localhost leak
    if (/^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?\//.test(a)) {
      return { ...t, artwork: MEDIA_BASE + a.replace(/^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?/, '') };
    }
    // Clear temporary /api/apiblink/artwork/:id URLs — they expire in ~4h and cause 404s.
    // These will be re-fetched on next playback and re-imported correctly with artworkDirect.
    if (/\/api\/apiblink\/artwork\//.test(a)) {
      return { ...t, artwork: '' };
    }
    return t;
  };
  if (patch.likes) patch.likes = patch.likes.map(fixArtwork);
  if (patch.recent) patch.recent = patch.recent.map(fixArtwork);
  if (patch.queue) patch.queue = patch.queue.map(fixArtwork);
  if (patch.playlists) patch.playlists = patch.playlists.map((p) => ({ ...p, tracks: (p.tracks || []).map(fixArtwork) }));

  store.set(patch);

  // Load admin-controlled source flags (non-critical, ignore errors).
  fetch(`${MEDIA_BASE}/api/mp3/config`, { cache: 'no-store' })
    .then((r) => r.ok ? r.json() : null)
    .then((cfg) => {
      if (!cfg) return;
      store.set({
        youtubeEnabled: cfg.youtubeEnabled !== false,
        parserEnabled: cfg.parserEnabled === true,
        apiblinkEnabled: cfg.apiblinkEnabled !== false,
        yandexAsPrimary: cfg.yandexAsPrimary === true,
        yandexSearchOnly: cfg.yandexSearchOnly === true,
      });
    })
    .catch(() => {});

  // Background artwork enrichment: for tracks that lost their artwork (expired APIBlink IDs),
  // fetch stable Yandex artwork (avatars.yandex.net) and patch the store.
  setTimeout(() => enrichMissingArtwork(), 3000);

  // Save only when a persisted field actually changed (by reference), and not on every tick:
  // status/toast/view changes fire store.set many times a second, and stringifying the whole
  // library + caches each time froze the UI (the main cause of the lag).
  let prev = {};
  for (const k of PERSIST) prev[k] = store.get()[k];
  let saveTimer = 0;
  const flush = () => {
    saveTimer = 0;
    const s = store.get();
    const out = {};
    for (const k of PERSIST) out[k] = s[k];
    try {
      window.blink.save(out);
    } catch {
      /* storage blocked */
    }
  };
  store.subscribe(() => {
    const s = store.get();
    let dirty = false;
    for (const k of PERSIST) {
      if (s[k] !== prev[k]) {
        prev[k] = s[k];
        dirty = true;
      }
    }
    if (dirty && !saveTimer) saveTimer = setTimeout(flush, 1200);
  });
  const flushNow = () => {
    if (!saveTimer) return;
    clearTimeout(saveTimer);
    flush();
  };
  window.addEventListener('pagehide', flushNow);
  document.addEventListener('visibilitychange', () => document.visibilityState === 'hidden' && flushNow());
  window.addEventListener('beforeunload', flushNow);
}

// The user's own key wins; otherwise the key built into the app (filled in by the main process).
export function ytKey(s = store.get()) {
  return s.settings.ytKey || s.builtinKey;
}
// ---------- navigation ----------

export function go(name, params = {}) {
  const s = store.get();
  if (s.view.name === name && JSON.stringify(s.view.params) === JSON.stringify(params)) return;
  store.set({ view: { name, params }, back: [...s.back.slice(-40), s.view], stage: false });
}
export function goBack() {
  const s = store.get();
  if (s.stage) return store.set({ stage: false });
  if (!s.back.length) return;
  store.set({ view: s.back[s.back.length - 1], back: s.back.slice(0, -1) });
}

let toastTimer;
export function toast(text, tone = 'info') {
  clearTimeout(toastTimer);
  store.set({ toast: { text, tone, id: Date.now() } });
  toastTimer = setTimeout(() => store.set({ toast: null }), 2600);
}

// ---------- account gate ----------
// Listening and saving music need a Blink account.
export function requireAccount(reason) {
  const s = store.get();
  if (s.user) return true;
  store.set({ sheet: 'account', authReason: reason, menu: null });
  return false;
}

// ---------- library ----------

export function isLiked(id) {
  return store.get().likes.some((t) => t.id === id);
}
export function toggleLike(track) {
  if (!track || !requireAccount('save')) return;
  const s = store.get();
  const has = s.likes.some((t) => t.id === track.id);
  store.set({ likes: has ? s.likes.filter((t) => t.id !== track.id) : [track, ...s.likes] });
  if (track.lic) import('./catalog.js').then((c) => c.syncLike(track.lic, !has)).catch(() => {});
  toast(has ? 'Убрано из любимого' : 'Добавлено в любимое');
}
export function createPlaylist(name, tracks = []) {
  if (!requireAccount('save')) return null;
  const p = { id: 'p' + Date.now().toString(36), name: name.trim() || 'Новый плейлист', tracks, created: Date.now() };
  store.set({ playlists: [p, ...store.get().playlists] });
  return p;
}
export function addToPlaylist(pid, track) {
  if (!requireAccount('save')) return;
  const s = store.get();
  let dup = false;
  store.set({
    playlists: s.playlists.map((p) => {
      if (p.id !== pid) return p;
      if (p.tracks.some((t) => t.id === track.id)) {
        dup = true;
        return p;
      }
      return { ...p, tracks: [...p.tracks, track] };
    }),
  });
  const p = s.playlists.find((x) => x.id === pid);
  toast(dup ? 'Трек уже в этом плейлисте' : `Добавлено в «${p ? p.name : ''}»`);
}
export function removeFromPlaylist(pid, id) {
  store.set({ playlists: store.get().playlists.map((p) => (p.id === pid ? { ...p, tracks: p.tracks.filter((t) => t.id !== id) } : p)) });
}
export function renamePlaylist(pid, name) {
  store.set({ playlists: store.get().playlists.map((p) => (p.id === pid ? { ...p, name } : p)) });
}
export function deletePlaylist(pid) {
  store.set({ playlists: store.get().playlists.filter((p) => p.id !== pid) });
}
export function pushRecent(track) {
  const s = store.get();
  store.set({ recent: [track, ...s.recent.filter((t) => t.id !== track.id)].slice(0, 60) });
}

const DEAD_TTL = 30 * 24 * 60 * 60 * 1000;
export function markDead(id) {
  if (!id) return;
  const now = Date.now();
  const dead = Object.fromEntries(Object.entries(store.get().dead || {}).filter(([, at]) => now - at < DEAD_TTL));
  store.set({ dead: { ...dead, [id]: now } });
}
// Drops tracks that recently failed to play (none of the enabled sources had them).
export function playable(tracks) {
  const dead = store.get().dead || {};
  const now = Date.now();
  return tracks.filter((t) => !(dead[t.id] && now - dead[t.id] < DEAD_TTL));
}

// Fetch stable Yandex artwork for a single track by artist+title.
// Returns a stable avatars.yandex.net URL, or '' on failure.
async function fetchYandexArtwork(artist, title) {
  try {
    const q = encodeURIComponent(`${artist} ${title}`);
    const r = await fetch(`${MEDIA_BASE}/api/yandex/search?q=${q}&type=track&limit=5`, {
      signal: AbortSignal.timeout(8000),
    });
    if (!r.ok) return '';
    const data = await r.json();
    const results = (data.results || []);
    const norm = (s) => (s || '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
    const hit = results.find((x) =>
      x.kind === 'song' &&
      norm(x.trackName || '').includes(norm(title)) &&
      norm(x.artistName || '').includes(norm((artist || '').split(/,|&/)[0]))
    ) || results.find((x) => x.kind === 'song');
    return (hit && (hit.artworkUrl600 || hit.artworkUrl100)) || '';
  } catch {
    return '';
  }
}

// Background job: enrich tracks that have no artwork with stable Yandex URLs.
// Runs once at startup, processes up to 200 tracks, 2 at a time.
export async function enrichMissingArtwork() {
  const s = store.get();
  const missing = [];
  const seen = new Set();
  const collect = (tracks) => {
    for (const t of (tracks || [])) {
      if (t && t.id && !seen.has(t.id) && !t.artwork && t.artist && t.title) {
        seen.add(t.id);
        missing.push({ id: t.id, artist: t.artist, title: t.title });
        if (missing.length >= 200) return;
      }
    }
  };
  collect(s.likes);
  for (const p of (s.playlists || [])) collect(p.tracks || []);
  if (!missing.length) return;

  let i = 0;
  const artworkMap = new Map();
  while (i < missing.length) {
    const batch = missing.slice(i, i + 2);
    i += 2;
    await Promise.all(batch.map(async ({ id, artist, title }) => {
      const url = await fetchYandexArtwork(artist, title);
      if (url) artworkMap.set(id, url);
    }));
    if (i < missing.length) await new Promise((r) => setTimeout(r, 400));
  }
  if (!artworkMap.size) return;

  const patchTrack = (t) => (t && artworkMap.has(t.id) ? { ...t, artwork: artworkMap.get(t.id) } : t);
  const cur = store.get();
  const patch = {};
  if (cur.likes.some((t) => artworkMap.has(t.id))) patch.likes = cur.likes.map(patchTrack);
  if ((cur.playlists || []).some((p) => (p.tracks || []).some((t) => artworkMap.has(t.id)))) {
    patch.playlists = cur.playlists.map((p) => ({ ...p, tracks: (p.tracks || []).map(patchTrack) }));
  }
  if ((cur.queue || []).some((t) => artworkMap.has(t.id))) patch.queue = cur.queue.map(patchTrack);
  if (Object.keys(patch).length) store.set(patch);
}
