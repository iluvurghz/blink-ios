// The phone app (Capacitor): the same window.blink the desktop app gets from Electron, built on native plugins.
// The site itself ships inside the app (it opens without internet); this file is what makes it an app:
// requests without CORS, state and saved tracks in the app's own files, sign-in through the system
// browser and the blink:// link, media controls in the notification, the back button.
// On the site and in Electron it does nothing (webBridge.js or preload.cjs take over).
import { Capacitor, CapacitorHttp, registerPlugin } from '@capacitor/core';
import { App } from '@capacitor/app';
import { Browser } from '@capacitor/browser';
import { Filesystem, Directory, Encoding } from '@capacitor/filesystem';
import { Preferences } from '@capacitor/preferences';
import { Haptics, ImpactStyle } from '@capacitor/haptics';
import { SplashScreen } from '@capacitor/splash-screen';

const native = Capacitor.isNativePlatform();
const platform = Capacitor.getPlatform();
// Same as the desktop app: some sources answer differently to an unknown client.
const UA = 'Blink/1.0 (desktop music player)';
const DATA = Directory.Data;
const noop = () => {};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// Android only: the notification with the track and its buttons, and the service that keeps playback alive.
const Media = registerPlugin('BlinkMedia');

// ---------- network ----------
function header(headers, name) {
  if (!headers) return '';
  const key = Object.keys(headers).find((k) => k.toLowerCase() === name);
  return key ? String(headers[key]) : '';
}

async function request(url, { tries = 3, timeout = 12000, as = 'text' } = {}) {
  let lastErr;
  for (let i = 0; i < tries; i++) {
    try {
      const r = await CapacitorHttp.get({
        url,
        headers: { 'User-Agent': UA },
        connectTimeout: timeout,
        readTimeout: timeout,
        responseType: as === 'blob' ? 'blob' : 'text',
      });
      if (r.status === 404) return { ok: false, status: 404 };
      if (r.status >= 500 || r.status === 429) throw new Error('HTTP ' + r.status);
      return { ok: r.status >= 200 && r.status < 300, status: r.status, data: r.data, headers: r.headers };
    } catch (e) {
      lastErr = e;
      if (i < tries - 1) await sleep(400 * (i + 1));
    }
  }
  return { ok: false, status: 0, error: String((lastErr && lastErr.message) || lastErr) };
}

async function json(url, opts) {
  const r = await request(url, { tries: (opts && opts.tries) || 3, timeout: (opts && opts.timeout) || 12000 });
  if (r.error || r.status === 404) return { ok: r.ok, status: r.status, ...(r.error ? { error: r.error } : {}) };
  let data = r.data;
  if (typeof data === 'string') {
    try {
      data = JSON.parse(data);
    } catch {
      /* not json */
    }
  }
  return { ok: r.ok, status: r.status, data };
}

async function image(url) {
  if (!url) return null;
  if (/^data:/.test(url)) return url;
  const r = await request(url, { tries: 2, as: 'blob' });
  if (!r.ok || !r.data) return null;
  if (typeof r.data !== 'string') return null;
  const type = header(r.headers, 'content-type').split(';')[0] || 'image/jpeg';
  return `data:${type};base64,${r.data}`;
}

// ---------- app state (one JSON file, like the desktop app's) ----------
const STATE = 'blink-data.json';
const STATE_TMP = 'blink-data.tmp.json';
let pending = null;
let saveTimer = 0;
let writing = Promise.resolve();

async function readText(path) {
  const r = await Filesystem.readFile({ path, directory: DATA, encoding: Encoding.UTF8 });
  return typeof r.data === 'string' ? r.data : await r.data.text();
}

async function load() {
  for (const path of [STATE, STATE_TMP]) {
    try {
      const d = JSON.parse(await readText(path));
      if (d && typeof d === 'object') return d;
    } catch {
      /* missing or cut short: try the next one */
    }
  }
  // First start after the web version kept it in page storage.
  try {
    return JSON.parse(localStorage.getItem('blink-data') || '{}');
  } catch {
    return {};
  }
}

function flush() {
  clearTimeout(saveTimer);
  if (!pending) return writing;
  const text = JSON.stringify(pending);
  pending = null;
  writing = writing
    .then(async () => {
      await Filesystem.writeFile({ path: STATE_TMP, directory: DATA, data: text, encoding: Encoding.UTF8 });
      await Filesystem.writeFile({ path: STATE, directory: DATA, data: text, encoding: Encoding.UTF8 });
    })
    .catch((e) => console.warn('save failed', e));
  return writing;
}

function save(data) {
  pending = data;
  clearTimeout(saveTimer);
  saveTimer = setTimeout(flush, 400);
}

// ---------- sign-in session (the app keeps it, not the page) ----------
const auth = {
  get: async (k) => (await Preferences.get({ key: 'auth:' + k })).value,
  set: (k, v) => Preferences.set({ key: 'auth:' + k, value: String(v) }),
  remove: (k) => Preferences.remove({ key: 'auth:' + k }),
  legacy: async () => null,
};

// ---------- saved tracks on disk ----------
const DIR = 'offline';
const hex = (id) => Array.from(new TextEncoder().encode(String(id)), (b) => b.toString(16).padStart(2, '0')).join('');
const fileOf = (id) => `${DIR}/${hex(id)}`;
const partOf = (id) => `${DIR}/${hex(id)}.part`;

function toBase64(bytes) {
  let s = '';
  const step = 0x8000;
  for (let i = 0; i < bytes.length; i += step) s += String.fromCharCode.apply(null, bytes.subarray(i, i + step));
  return btoa(s);
}
function fromBase64(b64) {
  const s = atob(b64);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}
const exists = (path) => Filesystem.stat({ path, directory: DATA }).then((s) => s, () => null);
const remove = (path) => Filesystem.deleteFile({ path, directory: DATA }).catch(noop);

const progressCbs = new Set();
const aborted = new Set();
let progressHooked = false;
// downloadFile reports progress by address; the address of each running download leads back to its track.
const running = new Map(); // url -> id
function hookProgress() {
  if (progressHooked) return;
  progressHooked = true;
  Filesystem.addListener('progress', (p) => {
    const id = running.get(p.url);
    if (id == null) return;
    progressCbs.forEach((cb) => cb({ id, got: p.bytes || 0, total: p.contentLength || 0 }));
  }).catch(noop);
}

const offline = {
  async put(id, data) {
    await Filesystem.writeFile({ path: fileOf(id), directory: DATA, data: toBase64(data), recursive: true });
    return true;
  },
  async get(id) {
    try {
      const r = await Filesystem.readFile({ path: fileOf(id), directory: DATA });
      return typeof r.data === 'string' ? fromBase64(r.data) : new Uint8Array(await r.data.arrayBuffer());
    } catch {
      return null;
    }
  },
  del: (id) => remove(fileOf(id)),
  async clear() {
    await Filesystem.rmdir({ path: DIR, directory: DATA, recursive: true }).catch(noop);
  },
  async size() {
    try {
      const { files } = await Filesystem.readdir({ path: DIR, directory: DATA });
      return files.reduce((sum, f) => sum + (f.size || 0), 0);
    } catch {
      return 0;
    }
  },
  async download(id, url) {
    hookProgress();
    aborted.delete(id);
    running.set(url, id);
    try {
      await Filesystem.downloadFile({ url, path: partOf(id), directory: DATA, recursive: true, progress: true, headers: { 'User-Agent': UA } });
      if (aborted.has(id)) {
        await remove(partOf(id));
        return { ok: false, aborted: true };
      }
      const st = await exists(partOf(id));
      if (!st || st.size < 50000) {
        await remove(partOf(id));
        return { ok: false, error: 'слишком маленький файл' };
      }
      await remove(fileOf(id));
      await Filesystem.rename({ from: partOf(id), to: fileOf(id), directory: DATA, toDirectory: DATA });
      return { ok: true, size: st.size };
    } catch (e) {
      await remove(partOf(id));
      if (aborted.has(id)) return { ok: false, aborted: true };
      return { ok: false, error: String((e && e.message) || e) };
    } finally {
      running.delete(url);
      aborted.delete(id);
    }
  },
  // A started download can't be cut off midway: its result is thrown away when it ends.
  abort: async (id) => void aborted.add(id),
  discard: async (id) => {
    aborted.add(id);
    await remove(partOf(id));
  },
  async url(id) {
    if (!(await exists(fileOf(id)))) return null;
    const { uri } = await Filesystem.getUri({ path: fileOf(id), directory: DATA });
    return Capacitor.convertFileSrc(uri);
  },
  onProgress(cb) {
    progressCbs.add(cb);
    return () => progressCbs.delete(cb);
  },
};

// ---------- links: the browser for http(s), blink:// back into the app ----------
const deepCbs = [];
const early = []; // links that came before the page listened: { url, at }
// blink://view/<section>[?q=…] opens a section of the app (search, charts, me, settings, account…): for widgets,
// shortcuts and the CI screenshot tour. Other blink:// links go to the page's own handlers, as on the PC.
function openView(url) {
  const m = /^blink:\/\/view\/([a-z-]+)/i.exec(url);
  if (!m) return false;
  const store = window.__blink && window.__blink.store;
  if (!store || !store.get().loaded) {
    setTimeout(() => openView(url), 400);
    return true;
  }
  const name = m[1].toLowerCase();
  let q = '';
  try {
    q = new URL(url).searchParams.get('q') || '';
  } catch {
    /* no query */
  }
  if (name === 'account') store.set({ sheet: 'account', menu: null });
  else store.set({ view: { name, params: {} }, back: [...(store.get().back || []), store.get().view], sheet: null, menu: null, stage: false, ...(q ? { query: q } : {}) });
  return true;
}

function deliver(url) {
  if (!/^blink:/i.test(url)) return;
  if (openView(url)) return;
  Browser.close().catch(noop); // the sign-in page has done its job
  if (!deepCbs.length) return void early.push({ url, at: Date.now() });
  deepCbs.forEach((cb) => cb(url));
}
function onDeepLink(cb) {
  deepCbs.push(cb);
  // Each listener looks for its own kind of link, so every one of them gets the early ones too.
  early.filter((e) => Date.now() - e.at < 20000).forEach((e) => setTimeout(() => cb(e.url), 0));
}

function open(url) {
  if (!url) return;
  if (/^https?:/i.test(url)) return void Browser.open({ url, presentationStyle: 'popover', toolbarColor: '#0d0c10' }).catch(() => window.open(url, '_blank'));
  window.location.href = url; // tg:, mailto: and the like: the system hands them to their app
}

// ---------- media controls (Android notification; iPhone uses the page's own media session) ----------
const mediaCbs = [];
const sessionHandlers = {};
let lastSent = null;
let lastSentAt = 0;
function playback(state) {
  if (platform !== 'android' || !state) return;
  const s = {
    id: state.id == null ? '' : String(state.id),
    playing: !!state.playing,
    title: state.title || '',
    artist: state.artist || '',
    album: state.album || '',
    art: state.art || state.artwork || '',
    time: Number(state.time) || 0,
    duration: Number(state.duration) || 0,
  };
  const same = lastSent && lastSent.id === s.id && lastSent.playing === s.playing && lastSent.title === s.title && lastSent.art === s.art && Math.abs(lastSent.duration - s.duration) < 1;
  // The position moves on its own in the notification; resend it only now and then or after a jump.
  const jumped = lastSent && Math.abs(s.time - (lastSent.time + (s.playing ? (Date.now() - lastSentAt) / 1000 : 0))) > 2;
  if (same && !jumped && Date.now() - lastSentAt < 15000) return;
  lastSent = s;
  lastSentAt = Date.now();
  Media.update(s).catch(noop);
}
function onMedia(cb) {
  mediaCbs.push(cb);
}
function mediaCommand({ cmd, time }) {
  const h = sessionHandlers;
  if (cmd === 'seek') return h.seekto && h.seekto({ action: 'seekto', seekTime: Number(time) || 0 });
  if (cmd === 'play' && h.play) return h.play({ action: 'play' });
  if (cmd === 'pause' && h.pause) return h.pause({ action: 'pause' });
  if (cmd === 'next' && h.nexttrack) return h.nexttrack({ action: 'nexttrack' });
  if (cmd === 'prev' && h.previoustrack) return h.previoustrack({ action: 'previoustrack' });
  const c = cmd === 'play' || cmd === 'pause' ? 'toggle' : cmd;
  mediaCbs.forEach((cb) => cb(c));
}
// The player sets its lock-screen handlers on navigator.mediaSession: keep a copy for the notification's buttons.
function captureSession() {
  const ms = navigator.mediaSession;
  if (!ms || !ms.setActionHandler) return;
  const orig = ms.setActionHandler.bind(ms);
  ms.setActionHandler = (action, handler) => {
    sessionHandlers[action] = handler || null;
    try {
      orig(action, handler);
    } catch {
      /* this WebView doesn't know the action */
    }
  };
}

// ---------- back button (Android) ----------
// Closes what is on top, one layer per press, the way the site's own «back» does; at home it leaves the
// app running in the background (music keeps playing), like the home button.
function back() {
  // A question («Удалить?») answers «no» to Escape.
  if (document.querySelector('.confirm-scrim')) return void window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
  const store = window.__blink && window.__blink.store;
  const s = store && store.get();
  if (s) {
    if (s.menu) return store.set({ menu: null });
    if (s.sheet) return store.set({ sheet: null, authReason: null });
    if (s.stage) return store.set({ stage: false });
    if (s.back && s.back.length) return store.set({ view: s.back[s.back.length - 1], back: s.back.slice(0, -1) });
  }
  App.minimizeApp().catch(noop);
}

// ---------- vibration: the site's light taps through the phone's own haptics ----------
function hookVibrate() {
  navigator.vibrate = (pattern) => {
    const ms = Array.isArray(pattern) ? pattern[0] : pattern;
    if (!ms) return true;
    Haptics.impact({ style: ms > 12 ? ImpactStyle.Medium : ImpactStyle.Light }).catch(noop);
    return true;
  };
}

export function installCapBridge() {
  captureSession();
  hookVibrate();
  let version = '';
  App.getInfo().then((i) => (version = i.version), noop);
  window.blink = {
    mobile: true,
    platform,
    json,
    image,
    load,
    save,
    builtinKey: async () => '',
    apiParserUrl: async () => '',
    game: false,
    relaunch: () => location.reload(),
    setGame: noop,
    offline,
    auth,
    minimize: () => App.minimizeApp().catch(noop),
    maximize: noop,
    close: () => App.minimizeApp().catch(noop),
    isMaximized: async () => false,
    onWinState: noop,
    open,
    playback,
    thumbIcons: noop,
    onMedia,
    onDeepLink,
    version: async () => version || (await App.getInfo()).version,
  };

  App.addListener('appUrlOpen', (e) => deliver(e.url)).catch(noop);
  App.getLaunchUrl()
    .then((r) => r && r.url && deliver(r.url))
    .catch(noop);
  App.addListener('backButton', back).catch(noop);
  // Going to the background: write the state now, the app may not get another chance.
  App.addListener('pause', () => flush()).catch(noop);
  if (platform === 'android') Media.addListener('media', mediaCommand).catch(noop);
  // The intro is drawn by the page itself: hide the native launch screen as soon as the page is up.
  const hide = () => SplashScreen.hide({ fadeOutDuration: 180 }).catch(noop);
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => setTimeout(hide, 60));
  else setTimeout(hide, 60);
  document.documentElement.classList.add('app-' + platform);
}

// Runs on import, before any module that reads window.blink (and before webBridge.js).
if (native && !window.blink) installCapBridge();
