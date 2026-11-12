// Accounts, library sync and the shared video finder (Supabase).
import { createClient } from '@supabase/supabase-js';
import { store, toast } from './store.js';
import { sbFetch, sbUrl, probeRoute } from './sbroute.js';
import { telegramToken } from './tgsignin.js';
import { googleRedirectOn, googleRedirectUrl, googleReturn } from './gsignin.js';

const URL = import.meta.env.VITE_SUPABASE_URL;
const ANON = import.meta.env.VITE_SUPABASE_ANON_KEY;
const SITE = 'https://blinkmusic.cc/';

export const isDesktop = !!(window.blink && !window.blink.isWeb); // any app: the PC one or the phone one
// The phone app (Capacitor) signs in and keeps the session like the PC app, but has no window of its own to manage.
export const isPhoneApp = !!(window.blink && window.blink.mobile);
export const isPc = isDesktop && !isPhoneApp;

// In the app the session is kept by the app itself (survives updates, the offline copy and
// address changes). A session left in this page's storage by an older version moves over.
const appAuth = isDesktop && window.blink.auth;
const quiet = (f) => {
  try {
    return f();
  } catch {
    return null;
  }
};
const appStorage = appAuth && {
  async getItem(k) {
    const v = await appAuth.get(k);
    if (v != null) return v;
    const old = quiet(() => localStorage.getItem(k));
    if (old != null) {
      await appAuth.set(k, old);
      quiet(() => localStorage.removeItem(k));
      return old;
    }
    if (!k.endsWith('-auth-token')) return null;
    const found = await appAuth.legacy().catch(() => null);
    return found && found[0] === k ? found[1] : null;
  },
  setItem: (k, v) => appAuth.set(k, v),
  async removeItem(k) {
    await appAuth.remove(k);
    quiet(() => localStorage.removeItem(k));
  },
};

export const cloud =
  URL && ANON
    ? createClient(URL, ANON, {
        auth: { flowType: 'pkce', persistSession: true, detectSessionInUrl: !isDesktop, ...(appStorage ? { storage: appStorage } : {}) },
        global: { fetch: sbFetch },
      })
    : null;
if (cloud) probeRoute();

// ---------- videos ----------

export async function resolveRemote(track) {
  if (!cloud) throw Object.assign(new Error('no cloud'), { reason: 'offline' });
  const { data, error } = await cloud.functions.invoke('resolve', {
    body: { track: { id: track.id, title: track.title, artist: track.artist, duration: track.duration, country: store.get().settings.country } },
  });
  if (error) {
    let reason = 'youtube';
    try {
      const body = await error.context.json();
      reason = body.error || reason;
    } catch {
      if (!navigator.onLine) reason = 'offline';
    }
    throw Object.assign(new Error(reason), { reason });
  }
  return { audio: data.audio || [], clip: data.clip || null };
}

// ---------- accounts ----------

const SYNCED = ['likes', 'playlists', 'recent', 'nowPlaying'];
// Each open copy of Blink (app window or browser tab) is its own "device". A game-mode restart
// (lib/gamemode.js) keeps it, or the new window would take its own track for another device's
// and cut the queue down to that one track.
const HANDOFF = 'blink.device';
function handedDevice() {
  try {
    const h = JSON.parse(localStorage.getItem(HANDOFF));
    localStorage.removeItem(HANDOFF);
    return h && Date.now() - h.at < 30000 ? h.id : null;
  } catch {
    return null;
  }
}
const DEVICE = handedDevice() || Math.random().toString(36).slice(2);
export function handOffDevice() {
  try {
    localStorage.setItem(HANDOFF, JSON.stringify({ id: DEVICE, at: Date.now() }));
  } catch {
    /* storage off: the restart just counts as a new device */
  }
}
export const DEVICE_NAME = isDesktop ? 'в приложении' : 'на сайте';

// ---------- devices / sessions ----------
// A stable id per install (survives restarts), so Settings can list where the account is signed in.
// The app's store only keeps "sb-…" keys, so the id lives under one too.
const APP_DEV_KEY = 'sb-blink-device-id';
let _devId = null;
async function deviceId() {
  if (_devId) return _devId;
  const make = () => (crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2) + Date.now().toString(36));
  try {
    if (appAuth) {
      _devId = (await appAuth.get(APP_DEV_KEY)) || null;
      if (!_devId) { _devId = make(); await appAuth.set(APP_DEV_KEY, _devId); }
    } else {
      _devId = localStorage.getItem('blink.deviceId');
      if (!_devId) { _devId = make(); localStorage.setItem('blink.deviceId', _devId); }
    }
  } catch { _devId = DEVICE; }
  return _devId;
}

function deviceInfo() {
  const ua = (typeof navigator !== 'undefined' && navigator.userAgent) || '';
  const mobile = /Android|iPhone|iPad|iPod|Mobile/i.test(ua);
  const os = /Windows/.test(ua) ? 'Windows' : /Mac OS X|Macintosh/.test(ua) ? 'macOS' : /Android/.test(ua) ? 'Android' : /iPhone|iPad|iPod/.test(ua) ? 'iOS' : /Linux/.test(ua) ? 'Linux' : '';
  const platform = isDesktop ? 'app' : mobile ? 'mobile' : 'web';
  const kind = isDesktop ? 'Приложение' : mobile ? 'Телефон' : 'Браузер';
  const name = kind + (os ? ' · ' + os : '');
  return { platform, name };
}

let devRegistered = false;
let devTimer = null;

// Register this device and refresh its «last seen». If our row was removed elsewhere
// («Выйти на этом устройстве»), sign out here instead of recreating it.
async function devHeartbeat() {
  if (!cloud) return;
  const { data } = await cloud.auth.getUser().catch(() => ({ data: {} }));
  const user = data && data.user;
  if (!user) return;
  const id = await deviceId();
  try {
    if (devRegistered) {
      const { data: row, error } = await cloud.from('user_devices').select('device_id').eq('user_id', user.id).eq('device_id', id).maybeSingle();
      if (!error && !row) {
        devRegistered = false;
        await signOut();
        toast('Сессия на этом устройстве была завершена');
        return;
      }
    }
    const info = deviceInfo();
    const { error } = await cloud.from('user_devices').upsert(
      { user_id: user.id, device_id: id, name: info.name, platform: info.platform, last_seen: new Date().toISOString() },
      { onConflict: 'user_id,device_id' }
    );
    if (!error) {
      devRegistered = true;
      await dropOldAppCopies(user.id, id, info);
    }
  } catch {
    /* table may not exist yet (before the Supabase update) — ignore */
  }
}

// Older app versions lost their id on every launch, leaving a pile of rows for one PC.
// Once per install, drop this app's same-named rows that have been silent for 15 minutes (heartbeat is 90 s).
async function dropOldAppCopies(userId, id, info) {
  const DONE = 'sb-blink-devices-cleaned';
  if (!appAuth || (await appAuth.get(DONE))) return;
  const { error } = await cloud
    .from('user_devices')
    .delete()
    .eq('user_id', userId)
    .eq('platform', info.platform)
    .eq('name', info.name)
    .neq('device_id', id)
    .lt('last_seen', new Date(Date.now() - 15 * 60e3).toISOString());
  if (!error) await appAuth.set(DONE, '1');
}

function startDevices() {
  clearInterval(devTimer);
  devHeartbeat();
  devTimer = setInterval(devHeartbeat, 90000);
}
function stopDevices() {
  clearInterval(devTimer);
  devTimer = null;
  devRegistered = false;
}

export async function listDevices() {
  if (!cloud) return [];
  const { data } = await cloud.auth.getUser().catch(() => ({ data: {} }));
  const user = data && data.user;
  if (!user) return [];
  const id = await deviceId();
  try {
    const { data: rows, error } = await cloud.from('user_devices').select('device_id,name,platform,last_seen').eq('user_id', user.id).order('last_seen', { ascending: false });
    if (error) throw error;
    return (rows || []).map((d) => ({ ...d, current: d.device_id === id }));
  } catch {
    // Before the table exists, at least show this device.
    const info = deviceInfo();
    return [{ device_id: id, name: info.name, platform: info.platform, last_seen: new Date().toISOString(), current: true }];
  }
}

export async function revokeDevice(deviceIdToDrop) {
  if (!cloud) return;
  const { data } = await cloud.auth.getUser().catch(() => ({ data: {} }));
  const user = data && data.user;
  if (!user) return;
  await cloud.from('user_devices').delete().eq('user_id', user.id).eq('device_id', deviceIdToDrop);
}

function mergeById(a = [], b = []) {
  const seen = new Set();
  const out = [];
  for (const x of [...a, ...b]) {
    if (!x || seen.has(x.id)) continue;
    seen.add(x.id);
    out.push(x);
  }
  return out;
}

function mergePlaylists(local = [], remote = []) {
  const map = new Map(remote.map((p) => [p.id, p]));
  for (const p of local) {
    const r = map.get(p.id);
    map.set(p.id, r ? { ...r, ...p, tracks: mergeById(p.tracks, r.tracks) } : p);
  }
  return [...map.values()].sort((x, y) => (y.created || 0) - (x.created || 0));
}

let pushTimer = null;
let lastPushed = '';
let unsub = null;

function snapshot() {
  const s = store.get();
  const data = {};
  for (const k of SYNCED) data[k] = s[k];
  return data;
}

// Another device's copy wins: it already merged everything before saving.
function applyRemote(remote, merge) {
  const s = store.get();
  const patch = merge
    ? {
        likes: mergeById(s.likes, remote.likes),
        playlists: mergePlaylists(s.playlists, remote.playlists),
        recent: mergeById(s.recent, remote.recent).slice(0, 60),
      }
    : { likes: remote.likes || [], playlists: remote.playlists || [], recent: remote.recent || [] };
  store.set(patch);
  if (!merge) lastPushed = JSON.stringify({ ...snapshot() });
  if (remote.nowPlaying) applyRemoteNow({ ...remote.nowPlaying, device: remote.device });
}

// What's playing elsewhere: pick it up here, or step aside if it just started there.
function applyRemoteNow(np) {
  if (!np || !np.track || np.device === DEVICE) return;
  const s = store.get();
  const fresh = Date.now() - np.at < 15000;
  if (s.status === 'playing' || s.status === 'buffering') {
    if (np.playing && fresh && s.onRemotePlay) s.onRemotePlay(np);
    return;
  }
  const time = np.playing ? np.time + (Date.now() - np.at) / 1000 : np.time;
  if (!s.track || s.track.id !== np.track.id || Math.abs((s.resumeAt || 0) - time) > 5) {
    store.set({ track: np.track, queue: [np.track], index: 0, resumeAt: Math.max(0, time), pendingResume: true, remoteFrom: np.deviceName });
  }
}

async function pull(user) {
  const { data, error } = await cloud.from('library').select('data').eq('user_id', user.id).maybeSingle();
  if (error) return;
  applyRemote((data && data.data) || {}, true);
  await push(user);
}

async function push(user) {
  const data = snapshot();
  const str = JSON.stringify(data);
  if (str === lastPushed) return;
  lastPushed = str;
  await cloud.from('library').upsert({ user_id: user.id, data: { ...data, device: DEVICE }, updated_at: new Date().toISOString() });
}

let channel = null;
function live(user) {
  if (channel) cloud.removeChannel(channel);
  channel = cloud
    .channel('library-' + user.id)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'library', filter: `user_id=eq.${user.id}` }, (payload) => {
      const d = payload.new && payload.new.data;
      if (d && d.device !== DEVICE) applyRemote(d, false);
    })
    .subscribe();
}

function watch(user) {
  if (unsub) unsub();
  let prev = SYNCED.map((k) => store.get()[k]);
  unsub = store.subscribe(() => {
    const now = SYNCED.map((k) => store.get()[k]);
    if (now.every((v, i) => v === prev[i])) return;
    prev = now;
    clearTimeout(pushTimer);
    pushTimer = setTimeout(() => push(user).catch(() => {}), 1500);
  });
}

function setUser(user) {
  store.set({
    user: user
      ? {
          id: user.id,
          email: user.email,
          // What the listener set in Blink (app_metadata, written by Blink's server) wins over the
          // name and picture Google re-sends on every sign-in.
          name:
            (user.app_metadata && user.app_metadata.blink_name) ||
            (user.user_metadata && (user.user_metadata.full_name || user.user_metadata.name)) ||
            (user.email || '').split('@')[0],
          avatar: (user.app_metadata && user.app_metadata.blink_avatar) || (user.user_metadata && user.user_metadata.avatar_url),
        }
      : null,
  });
}

export function initCloud() {
  if (!cloud) return;
  let current = null;
  cloud.auth.onAuthStateChange((_event, session) => {
    const user = session ? session.user : null;
    setUser(user);
    if (user && (!current || current.id !== user.id)) {
      current = user;
      pull(user).catch(() => {});
      watch(user);
      live(user);
      startDevices();
    } else if (!user) {
      current = null;
      stopDevices();
      if (unsub) unsub();
      unsub = null;
      lastPushed = '';
      if (channel) cloud.removeChannel(channel);
      channel = null;
    }
  });
  if (isDesktop && window.blink.onDeepLink) window.blink.onDeepLink(finishSignIn);
  // Back from Google's account page on the site (?gsignin=web#id_token=...): finish the sign-in and clean the address.
  if (!isDesktop && new URLSearchParams(location.search).get('gsignin') === 'web') {
    const back = googleReturn();
    history.replaceState(null, '', location.pathname);
    if (back) {
      signInGoogleToken(back.token, back.nonce).then(
        () => toast('Вы вошли'),
        () => toast('Не получилось войти через Google', 'error')
      );
    }
  }
}

// The address Google/Supabase sent the listener back to (from the app's sign-in window or the
// blink:// link of the browser flow): finishes the sign-in with its code or ID token.
async function finishSignIn(url) {
  let q;
  try {
    q = new window.URL(url).searchParams;
  } catch {
    return false;
  }
  const code = q.get('code');
  const token = q.get('id_token');
  const tg = q.get('tg_hash');
  if (tg) {
    const { error } = await cloud.auth.verifyOtp({ token_hash: tg, type: 'magiclink' });
    if (error) {
      toast('Не получилось войти через Telegram', 'error');
      return false;
    }
    store.set({ sheet: null });
    toast('Вы вошли');
    return true;
  }
  if (!code && !token) {
    if (q.get('error') || q.get('error_description')) toast('Вход отменён или не получился', 'error');
    return false;
  }
  const { error } = token
    ? await cloud.auth.signInWithIdToken({ provider: 'google', token, nonce: q.get('nonce') || undefined })
    : await cloud.auth.exchangeCodeForSession(code);
  if (error) {
    toast('Не получилось войти через Google', 'error');
    return false;
  }
  store.set({ sheet: null });
  toast('Вы вошли');
  return true;
}

export async function signUp(email, password, name) {
  const { data, error } = await cloud.auth.signUp({ email, password, options: { data: { full_name: name }, emailRedirectTo: SITE } });
  if (error) throw error;
  return data;
}

export async function signIn(email, password) {
  const { error } = await cloud.auth.signInWithPassword({ email, password });
  if (error) throw error;
}

// Is the running app at least this version? (the Electron app and the native one both answer window.blink.version())
async function appAtLeast(min) {
  try {
    const v = String(await window.blink.version()).split('.').map((n) => parseInt(n, 10) || 0);
    const m = min.split('.').map((n) => parseInt(n, 10));
    for (let i = 0; i < 3; i++) {
      if ((v[i] || 0) !== m[i]) return (v[i] || 0) > m[i];
    }
    return true;
  } catch {
    return false;
  }
}

export async function signInGoogle() {
  // The app signs in in the SYSTEM browser: Google refuses to sign in inside embedded windows ("this browser or app may not be
  // secure"). blinkmusic.cc/?gsignin=desktop opens there, goes to Google, and the ID token comes back as blink://auth?id_token=...
  // (the browser asks to open Blink), which the app handles through onDeepLink (finishSignIn).
  if (isDesktop && window.blink.open) {
    window.blink.open(SITE + '?gsignin=desktop');
    toast('Продолжите вход в браузере. Когда выберете аккаунт, он вернёт вас в Blink');
    return;
  }
  // Straight to Google's own account page (our domain on its screen, one window): the site goes there in the same tab, an app's
  // sign-in window opens the same way through the handoff page. See lib/gsignin.js for what Google Cloud needs for it.
  if (googleRedirectOn()) {
    if (isDesktop && window.blink.authWindow) {
      const landed = await window.blink.authWindow(SITE + '?gsignin=desktop');
      if (landed) await finishSignIn(landed);
      return;
    }
    if (isDesktop) return void window.blink.open(SITE + '?gsignin=desktop');
    location.assign(await googleRedirectUrl('web'));
    return;
  }
  if (isDesktop) {
    // Apps from 1.9.8 sign in on blinkmusic.cc/?gsignin=desktop inside their own window: Google's button there shows OUR domain
    // (not "<project>.supabase.co"), and the ID token comes back as blink://auth?id_token=... Older apps cannot show Google's
    // pop-up, they keep the Supabase OAuth way below.
    if (window.blink.authWindow && (await appAtLeast('1.9.8'))) {
      const landed = await window.blink.authWindow(SITE + '?gsignin=desktop');
      if (landed) await finishSignIn(landed);
      return;
    }
    // Sign-in happens in Blink's own window (main.cjs auth:window), which hands the address with
    // the code back. An older app without it uses the real browser and the blink:// link.
    const { data, error } = await cloud.auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo: SITE + '?desktop=1', skipBrowserRedirect: true },
    });
    if (error) throw error;
    if (window.blink.authWindow) {
      const landed = await window.blink.authWindow(sbUrl(data.url));
      if (landed) await finishSignIn(landed);
      return;
    }
    window.blink.open(sbUrl(data.url));
    return;
  }
  const { data, error } = await cloud.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: SITE, skipBrowserRedirect: true } });
  if (error) throw error;
  location.assign(sbUrl(data.url));
}

// Google's ID token from the button on blinkmusic.cc (lib/gsignin.js).
export async function signInGoogleToken(token, nonce) {
  const { error } = await cloud.auth.signInWithIdToken({ provider: 'google', token, nonce });
  if (error) throw error;
}

// Telegram: the widget's signed user (lib/tgsignin.js) → session. The desktop app opens the real browser instead.
export async function signInTelegramUser(user) {
  const hash = await telegramToken(user);
  const { error } = await cloud.auth.verifyOtp({ token_hash: hash, type: 'magiclink' });
  if (error) throw error;
}

export function signInTelegramDesktop() {
  window.blink.open(SITE + '?tgsignin=desktop');
}

export async function signOut() {
  try {
    const { data } = await cloud.auth.getUser();
    const id = await deviceId();
    if (data && data.user) await cloud.from('user_devices').delete().eq('user_id', data.user.id).eq('device_id', id);
  } catch {}
  stopDevices();
  await cloud.auth.signOut();
  toast('Вы вышли из аккаунта');
}

// ---------- numbers ----------

export function recordPlay(track) {
  const u = store.get().user;
  if (!cloud || !u || !track) return;
  cloud
    .from('plays')
    .insert({ user_id: u.id, track_id: String(track.id), title: (track.title || '').slice(0, 200), artist: (track.artist || '').slice(0, 200) })
    .then(() => {}, () => {});
}

export async function fetchStats() {
  if (!cloud) return null;
  const { data, error } = await cloud.rpc('blink_stats');
  return error ? null : data;
}

// Which of these tracks already have a known video (playable without a new YouTube search).
export async function playableIds(ids) {
  if (!cloud || !ids.length) return new Set();
  const since = new Date(Date.now() - 30 * 864e5).toISOString(); // older entries are purged (YouTube API policy)
  const { data } = await cloud.from('video_cache').select('track_id').in('track_id', ids.slice(0, 300).map(String)).gte('created_at', since);
  return new Set((data || []).map((r) => r.track_id));
}

// ---------- profile & images ----------

// Shrinks a picked image to a square JPEG before upload (avatars and covers never need more).
export function squareJpeg(file, size = 512) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => {
      const c = document.createElement('canvas');
      c.width = c.height = size;
      const s = Math.min(img.width, img.height);
      c.getContext('2d').drawImage(img, (img.width - s) / 2, (img.height - s) / 2, s, s, 0, 0, size, size);
      c.toBlob((b) => (b ? resolve(b) : reject(new Error('image'))), 'image/jpeg', 0.86);
      URL.revokeObjectURL(img.src);
    };
    img.onerror = () => reject(new Error('Не получилось открыть картинку'));
    img.src = URL.createObjectURL(file);
  });
}

export async function uploadImage(file, kind, size) {
  const u = store.get().user;
  if (!cloud || !u) throw new Error('Войдите в аккаунт');
  const blob = await squareJpeg(file, size);
  const path = `${u.id}/${kind}-${Date.now().toString(36)}.jpg`;
  const { error } = await cloud.storage.from('media').upload(path, blob, { contentType: 'image/jpeg', upsert: true });
  if (error) throw new Error('Не получилось загрузить картинку');
  return cloud.storage.from('media').getPublicUrl(path).data.publicUrl;
}

// The server changed the profile (avatar): fetch the fresh user.
export async function reloadUser() {
  const { data } = await cloud.auth.refreshSession();
  if (data && data.user) setUser(data.user);
  // app_metadata is server-managed; refresh the session so the updated Blink name/avatar
  // replaces the stale OAuth claims in both the auth client and the visible store.
  const { data: fresh } = await cloud.auth.getUser();
  if (fresh && fresh.user) setUser(fresh.user);
}


// ---------- sharing playlists ----------

const code = () => Math.random().toString(36).slice(2, 8) + Math.random().toString(36).slice(2, 6);

export async function sharePlaylist(p) {
  const u = store.get().user;
  if (!cloud || !u) throw new Error('Войдите в аккаунт');
  const data = { name: p.name, cover: p.cover || null, tracks: p.tracks.slice(0, 500) };
  const { data: existing } = await cloud.from('shared_playlists').select('code').eq('owner_id', u.id).eq('playlist_id', p.id).maybeSingle();
  const c = existing ? existing.code : code();
  const row = { code: c, owner_id: u.id, owner_name: u.name, playlist_id: p.id, data, updated_at: new Date().toISOString() };
  const { error } = existing ? await cloud.from('shared_playlists').update(row).eq('code', c) : await cloud.from('shared_playlists').insert(row);
  if (error) throw new Error('Не получилось поделиться');
  return shareLink(c);
}

// blinkmusic.cc/p/<code>: opens with a preview card (server/shareRoute.js); the old ?playlist=<code> keeps working.
export const shareLink = (c) => `${SITE}p/${c}`;

// A track link with a preview card (server/shareRoute.js). Title, artist and cover ride along for
// sources the server can't look up by id.
// Apple (numeric) and Blink catalog (b:<uuid>) tracks are looked up by id on the server, so their
// link is just blinkmusic.cc/t/<id>. Other sources still carry the title and artist (the server has
// nothing to look them up by), but no longer the long cover URL. Old long links keep working.
export function trackLink(t) {
  const id = String(t.id);
  if (/^\d{1,15}$/.test(id) || /^b:[0-9a-f-]{36}$/.test(id)) return `${SITE}t/${encodeURIComponent(id)}`;
  const q = new URLSearchParams({ n: t.title || '', a: t.artist || '' });
  return `${SITE}t/${encodeURIComponent(id)}?${q}`;
}

// The short, tidy link for a track: blinkmusic.cc/t/Xk3p9aQ. The server keeps the title, artist and cover
// behind the code (same track → same code). Numeric Apple ids are short already; if the server can't be
// reached the long form above still works.
const shortLinks = new Map();
export async function shortTrackLink(t) {
  const id = String(t.id);
  if (/^\d{1,15}$/.test(id)) return trackLink(t);
  if (shortLinks.has(id)) return shortLinks.get(id);
  try {
    const base = (import.meta.env.VITE_MEDIA_URL || SITE).replace(/\/$/, '');
    const r = await fetch(`${base}/api/share/track`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id, title: t.title || '', artist: t.artist || '', artwork: t.artwork || '' }),
      signal: AbortSignal.timeout(3500),
    });
    const j = r.ok ? await r.json() : null;
    if (j && /^[A-Za-z0-9]{7}$/.test(j.code || '')) {
      const url = `${SITE}t/${j.code}`;
      shortLinks.set(id, url);
      return url;
    }
  } catch {
    /* offline or an older server: the long link */
  }
  return trackLink(t);
}

// The owner's share of this playlist, if it is shared: { code } or null.
export async function sharedState(p) {
  const u = store.get().user;
  if (!cloud || !u || !p) return null;
  const { data } = await cloud.from('shared_playlists').select('code').eq('owner_id', u.id).eq('playlist_id', p.id).maybeSingle();
  return data || null;
}

// Stops sharing: the link stops working for everyone (copies people already added stay theirs).
export async function unsharePlaylist(p) {
  const u = store.get().user;
  if (!cloud || !u) throw new Error('Войдите в аккаунт');
  const { error } = await cloud.from('shared_playlists').delete().eq('owner_id', u.id).eq('playlist_id', p.id);
  if (error) throw new Error('Не получилось закрыть доступ');
}

// ---------- editorial playlists (made in the admin panel) ----------

export async function fetchEditorial() {
  if (!cloud) return [];
  const { data } = await cloud
    .from('editorial_playlists')
    .select('id, title, description, kind, cover_url, art:tracks->0->>artwork')
    .eq('published', true)
    .order('position')
    .order('created_at', { ascending: false })
    .limit(24);
  return data || [];
}

export async function fetchEditorialOne(id) {
  if (!cloud) return null;
  const { data } = await cloud.from('editorial_playlists').select('id, title, description, kind, cover_url, tracks').eq('id', id).eq('published', true).maybeSingle();
  return data;
}

export async function fetchShared(c) {
  if (!cloud) return null;
  const { data } = await cloud.from('shared_playlists').select('code, owner_name, data').eq('code', c).maybeSingle();
  return data;
}
