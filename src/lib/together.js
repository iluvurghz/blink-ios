// «Слушать вместе»: a room on Blink's server that up to 8 listeners join by link. Whatever anyone
// in the room does by hand (picks a track, pauses, seeks) plays the same way for everyone, and
// the room has a small chat.
// The server keeps the room's state; each app waits for changes (long poll) and follows them.
import { store, clock, nowTime, toast, requireAccount } from './store.js';
import { MEDIA } from './catalog.js';
import { cloud } from './cloud.js';
import { playTrack, toggle, seek, userActions } from './player.js';

const SITE = 'https://blinkmusic.cc/';
export const togetherLink = (code) => `${SITE}?together=${code}`;

let room = null; // last room state from the server
let offset = 0; // server clock minus ours, ms
let applying = false; // true while we follow the room, so that isn't sent back as our own action
let lastId = null;

async function call(path, body) {
  const { data } = cloud ? await cloud.auth.getSession() : { data: {} };
  const t = data && data.session ? data.session.access_token : null;
  const res = await fetch(MEDIA + path, {
    method: body ? 'POST' : 'GET',
    headers: { ...(body ? { 'Content-Type': 'application/json' } : {}), ...(t ? { Authorization: `Bearer ${t}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const d = await res.json().catch(() => ({}));
  return { status: res.status, data: d };
}

const playingNow = (s) => s.status === 'playing' || s.status === 'buffering' || s.status === 'loading';
const target = (r) => r.pos + (r.playing ? (Date.now() + offset - r.at) / 1000 : 0);
const slim = (q) => q.slice(0, 100);

function follow(r) {
  if (!r.track) return;
  const s = store.get();
  const t = target(r);
  applying = true;
  try {
    if (!s.track || s.track.id !== r.track.id) {
      lastId = r.track.id;
      if (r.playing) return playTrack(r.track, r.queue, r.index, t);
      // Paused room: show the track, start it from the room's moment on play.
      store.set({ queue: r.queue, index: r.index, track: r.track, pendingResume: true, resumeAt: t, status: 'paused' });
      clock.set({ time: t, duration: r.track.duration || 0, at: performance.now(), playing: false });
      return;
    }
    if (s.status === 'loading') return;
    if (r.playing !== playingNow(s)) {
      store.set({ resumeAt: t });
      toggle();
      if (s.pendingResume || s.status === 'idle' || s.status === 'error') return;
    }
    if (Math.abs(nowTime() - t) > 2.5) seek(t);
  } finally {
    applying = false;
  }
}

function update(r) {
  if (!room || r.code !== room.code || r.rev < room.rev) return;
  // New messages from others show as a toast while the room window is closed.
  const seen = new Set(((store.get().together || {}).chat || []).map((c) => c.id));
  const me = store.get().user && store.get().user.id;
  if (store.get().sheet !== 'together' && room.rev) for (const c of r.chat || []) if (!seen.has(c.id) && c.by !== me) toast(`${c.name}: ${c.text}`);
  room = r;
  offset = r.now - Date.now();
  store.set({ together: { code: r.code, members: r.members || [], chat: r.chat || [] } });
  follow(r);
}

async function send(patch) {
  if (!room || applying) return;
  const s = store.get();
  const body = { base: room.v, playing: playingNow(s), pos: nowTime(), ...patch };
  try {
    const { status, data } = await call(`/api/together/${room.code}`, body);
    if (status === 200 || status === 409) update(data);
    else if (status === 404 || status === 403) end(data.error);
  } catch {}
}

async function loop(code) {
  while (room && room.code === code) {
    try {
      const { status, data } = await call(`/api/together/${code}?r=${room.rev}`);
      if (status === 200) update(data);
      else if (status === 404 || status === 403 || status === 401) return end(data.error);
      else await new Promise((f) => setTimeout(f, 3000));
    } catch {
      await new Promise((f) => setTimeout(f, 3000));
    }
  }
}

function end(message) {
  room = null;
  store.set({ together: null });
  if (message) toast(message, 'error');
}

function enter(code) {
  room = { code, v: 0, rev: 0 };
  lastId = store.get().track && store.get().track.id;
  store.set({ together: { code, members: [], chat: [] } });
  loop(code);
}

// Make a room; what plays here now becomes the room's track.
export async function createRoom() {
  if (!requireAccount('play')) return null;
  const { status, data } = await call('/api/together', {}).catch(() => ({}));
  if (status !== 200) {
    toast((data && data.error) || 'Не получилось создать комнату', 'error');
    return null;
  }
  room = { code: data.code, v: 0, rev: 0 };
  update(data);
  const s = store.get();
  if (s.track) await send({ track: s.track, queue: slim(s.queue), index: s.index });
  loop(data.code);
  return data.code;
}

export function joinRoom(code) {
  if (!requireAccount('play')) return;
  if (room && room.code === code) return;
  if (room) leaveRoom();
  enter(code);
}

export async function sendChat(text) {
  if (!room) return false;
  const { status, data } = await call(`/api/together/${room.code}/chat`, { text }).catch(() => ({}));
  if (status === 200) {
    update(data);
    return true;
  }
  toast((data && data.error) || 'Сообщение не отправилось', 'error');
  return false;
}

export function leaveRoom() {
  if (!room) return;
  call(`/api/together/${room.code}/leave`, {}).catch(() => {});
  end();
}

// What the listener does by hand goes to the room.
userActions.add((a) => {
  if (!room || applying) return;
  if ('seek' in a) send({ pos: a.seek });
  else send({ playing: a.playing, pos: nowTime() });
});
store.subscribe(() => {
  const s = store.get();
  const id = s.track && s.track.id;
  if (id === lastId) return;
  lastId = id;
  if (room && !applying && s.track) send({ track: s.track, queue: slim(s.queue), index: s.index, playing: true, pos: 0 });
});
// A slow connection or a long buffer can leave this player behind; catch up now and then.
setInterval(() => {
  const s = store.get();
  if (room && room.track && s.status === 'playing' && s.track && s.track.id === room.track.id && room.playing) {
    if (Math.abs(nowTime() - target(room)) > 3) {
      applying = true;
      seek(target(room));
      applying = false;
    }
  }
}, 5000);
