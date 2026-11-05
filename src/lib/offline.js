// Saved tracks: Blink+ keeps the audio of chosen tracks on the device to play without internet.
// The files live on disk in the app (window.blink.offline) and in IndexedDB on the site; the list is store.saved.
// Downloads go one at a time through a queue; store.dl shows its progress and can be paused.
import { store, toast, go } from './store.js';
import { playUrl } from './catalog.js';
import { findMp3 } from './apiparser.js';

const DB = 'blink-offline';
let dbp = null;
const db = () =>
  (dbp ||= new Promise((ok, fail) => {
    const r = indexedDB.open(DB, 1);
    r.onupgradeneeded = () => r.result.createObjectStore('audio');
    r.onsuccess = () => ok(r.result);
    r.onerror = () => fail(r.error);
  }));
const tx = async (mode, fn) => {
  const d = await db();
  return new Promise((ok, fail) => {
    const req = fn(d.transaction('audio', mode).objectStore('audio'));
    req.onsuccess = () => ok(req.result);
    req.onerror = () => fail(req.error);
  });
};

// In the app, files go to its own folder: online it shows the site and offline its bundled copy,
// and each has separate page storage. Files an older version left in IndexedDB move there once.
const disk = window.blink && window.blink.offline;
let moved = null;
const ready = () =>
  (moved ||= !disk
    ? Promise.resolve()
    : (async () => {
        const d = await db();
        const keys = await new Promise((ok) => {
          const req = d.transaction('audio').objectStore('audio').getAllKeys();
          req.onsuccess = () => ok(req.result || []);
          req.onerror = () => ok([]);
        });
        for (const id of keys) {
          const blob = await tx('readonly', (o) => o.get(id)).catch(() => null);
          if (blob && (await disk.put(id, new Uint8Array(await blob.arrayBuffer())))) await tx('readwrite', (o) => o.delete(id));
        }
      })().catch(() => {}));
const files = {
  put: async (id, blob) => (disk ? disk.put(id, new Uint8Array(await blob.arrayBuffer())) : tx('readwrite', (o) => o.put(blob, id))),
  get: async (id) => {
    if (!disk) return tx('readonly', (o) => o.get(id));
    const data = await disk.get(id);
    return data && new Blob([data], { type: 'audio/mpeg' });
  },
  del: (id) => (disk ? disk.del(id) : tx('readwrite', (o) => o.delete(id))),
  clear: () => (disk ? disk.clear() : tx('readwrite', (o) => o.clear())),
};

const hasPlus = () => !!store.get().plus && Date.parse(store.get().plus) > Date.now();
export const isSaved = (id, s = store.get()) => (s.saved || []).some((t) => t.id === id);

async function sourceUrl(track) {
  if (track.source === 'blink') return playUrl(track.lic);
  if (track.source === 'jamendo') return track.stream;
  if (track.source === 'parser' && track._parserUrl) return track._parserUrl;
  const r = await findMp3(track.title, track.artist);
  return r && r.url;
}

// ---------- queue ----------
// store.dl = { ids, cur, pct, done, ok, total, paused } while something is queued, else null.
let queue = [];
let part = null; // the track being downloaded: { id, url, chunks, got, size, ctl }
let running = false;

const publish = (patch = {}) => {
  const d = { done: 0, ok: 0, paused: false, ...store.get().dl, ...patch };
  const ids = queue.map((t) => t.id);
  store.set({ dl: { ...d, ids, cur: ids[0] || null, pct: part && part.size ? part.got / part.size : 0, total: d.done + ids.length } });
};

async function download(track) {
  if (!part || part.id !== track.id) part = { id: track.id, url: null, chunks: [], got: 0, size: 0 };
  part.ctl = new AbortController();
  if (!part.url) part.url = await sourceUrl(track);
  if (!part.url) throw new Error('нет файла');
  // After a pause, ask only for the rest of the file; a source without Range sends it whole again.
  const res = await fetch(part.url, { signal: part.ctl.signal, headers: part.got ? { Range: `bytes=${part.got}-` } : {} });
  if (!res.ok) throw new Error(res.status);
  if (part.got && res.status !== 206) (part.chunks = []), (part.got = 0);
  const len = +res.headers.get('content-length') || 0;
  part.size = part.got + len;
  const reader = res.body.getReader();
  let shown = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    part.chunks.push(value);
    part.got += value.length;
    if (part.got - shown > 64 * 1024) (shown = part.got), publish();
  }
  const blob = new Blob(part.chunks, { type: res.headers.get('content-type') || 'audio/mpeg' });
  if (blob.size < 50000) throw new Error('слишком маленький файл');
  await ready();
  await files.put(track.id, blob);
  store.set({ saved: [track, ...(store.get().saved || []).filter((t) => t.id !== track.id)] });
}

async function pump() {
  if (running) return;
  running = true;
  if (navigator.storage && navigator.storage.persist) navigator.storage.persist().catch(() => {});
  while (queue.length && !store.get().dl.paused) {
    const track = queue[0];
    publish();
    let ok = false;
    try {
      await download(track);
      ok = true;
    } catch (e) {
      if (e.name === 'AbortError') {
        if (!store.get().dl || store.get().dl.paused) break; // paused: the track stays first in line
        continue; // this track was taken out of the queue
      }
    }
    if (!store.get().dl) break;
    part = null;
    queue.shift();
    const d = store.get().dl;
    publish({ done: d.done + 1, ok: d.ok + (ok ? 1 : 0) });
  }
  running = false;
  const d = store.get().dl;
  if (d && !queue.length) {
    toast(d.ok === d.total ? `Готово: ${d.ok} тр. играют без интернета` : `Сохранено ${d.ok} из ${d.total}, остальные не нашлись`, d.ok ? undefined : 'error');
    store.set({ dl: null });
  }
}

// Queues tracks for saving (one or a whole list).
export function saveTracks(tracks) {
  if (!hasPlus()) {
    toast('Сохранение треков доступно с Blink+');
    return go('settings', { tab: 'plus' });
  }
  const queued = new Set(queue.map((t) => t.id));
  const add = tracks.filter((t) => t && t.source !== 'local' && !(t.source === 'blink' && t.offline === false) && !isSaved(t.id) && !queued.has(t.id));
  if (!add.length) {
    const t = tracks.length === 1 && tracks[0];
    if (t && t.source === 'blink' && t.offline === false) return toast('Артист не разрешил сохранять этот трек');
    if (t && t.source === 'local') return toast('Этот трек и так на устройстве');
    return toast(queued.size ? 'Уже в очереди' : 'Все треки уже сохранены');
  }
  if (!navigator.onLine) return toast('Нужен интернет, чтобы сохранить треки', 'error');
  queue.push(...add);
  if (!store.get().dl) store.set({ dl: { done: 0, ok: 0, paused: false } });
  publish();
  pump();
}
export const saveTrack = (track) => saveTracks([track]);

export function pauseDownloads() {
  if (!store.get().dl) return;
  publish({ paused: true });
  if (part && part.ctl) part.ctl.abort();
}
export function resumeDownloads() {
  if (!store.get().dl) return;
  publish({ paused: false });
  pump();
}
export function cancelDownloads() {
  queue = [];
  if (part && part.ctl) part.ctl.abort();
  part = null;
  store.set({ dl: null });
}
// Takes one track out of the queue (the current one stops).
export function unqueue(id) {
  if (queue[0] && queue[0].id === id && part && part.ctl) part.ctl.abort();
  queue = queue.filter((t) => t.id !== id);
  if (!queue.length) return cancelDownloads();
  if (part && part.id === id) part = null;
  publish();
  if (!store.get().dl.paused) pump();
}

export async function removeSaved(id) {
  await ready();
  await files.del(id).catch(() => {});
  store.set({ saved: (store.get().saved || []).filter((t) => t.id !== id) });
  toast('Убрано из сохранённых');
}

// A playable URL for a saved track, or null. Saved files play only while Blink+ is active.
// The last few URLs stay alive: a crossfade still plays the previous one.
const live = [];
export async function savedUrl(id) {
  if (!isSaved(id) || !hasPlus()) return null;
  await ready();
  const blob = await files.get(id).catch(() => null);
  if (!blob) return null;
  const url = URL.createObjectURL(blob);
  live.push(url);
  if (live.length > 3) URL.revokeObjectURL(live.shift());
  return url;
}

// Settings → Хранилище: how much the saved files take, and wiping them all.
export async function savedBytes() {
  await ready();
  if (disk) return disk.size();
  const d = await db();
  return new Promise((ok) => {
    let sum = 0;
    const req = d.transaction('audio').objectStore('audio').openCursor();
    req.onsuccess = () => {
      const c = req.result;
      if (!c) return ok(sum);
      sum += c.value.size || 0;
      c.continue();
    };
    req.onerror = () => ok(sum);
  });
}
export async function clearSaved() {
  cancelDownloads();
  await ready();
  await files.clear().catch(() => {});
  store.set({ saved: [] });
}
