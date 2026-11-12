// Друзья и «слушает сейчас»: friends by invite link, who is listening now, and what this listener
// shows to friends. The server keeps it all; see server/friendsRoute.js.
import { store, toast } from './store.js';
import { MEDIA } from './catalog.js';
import { cloud } from './cloud.js';

const SITE = 'https://blinkmusic.cc/';
export const friendLink = (code) => `${SITE}?friend=${code}`;

async function call(path, body) {
  const { data } = cloud ? await cloud.auth.getSession() : { data: {} };
  const t = data && data.session ? data.session.access_token : null;
  const res = await fetch(MEDIA + path, {
    method: body ? 'POST' : 'GET',
    headers: { ...(body ? { 'Content-Type': 'application/json' } : {}), ...(t ? { Authorization: `Bearer ${t}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(10000),
  });
  const d = await res.json().catch(() => ({}));
  return { status: res.status, data: d };
}

const signedIn = () => !!store.get().user;

export async function loadFriends() {
  if (!signedIn()) return;
  try {
    const { status, data } = await call('/api/friends');
    if (status === 200) store.set({ friends: data.friends || [], friendsHidden: !!data.hidden });
  } catch {}
}

// The link to send to a friend (the server keeps one live code per person).
export async function makeInvite() {
  try {
    const { status, data } = await call('/api/friends/link', {});
    if (status === 200) return friendLink(data.code);
    toast((data && data.error) || 'Не получилось создать ссылку', 'error');
  } catch {
    toast('Нет связи с сервером', 'error');
  }
  return null;
}

export async function acceptInvite(code) {
  try {
    const { status, data } = await call('/api/friends/accept', { code });
    if (status === 200) {
      toast(`Теперь вы друзья с ${data.friend.name}`);
      loadFriends();
      return true;
    }
    toast((data && data.error) || 'Не получилось добавить', 'error');
  } catch {
    toast('Нет связи с сервером', 'error');
  }
  return false;
}

export async function removeFriend(id) {
  try {
    await call('/api/friends/remove', { id });
    store.set({ friends: (store.get().friends || []).filter((f) => f.id !== id) });
  } catch {
    toast('Не получилось удалить', 'error');
  }
}

export async function setHidden(hidden) {
  store.set({ friendsHidden: hidden });
  try {
    const { status } = await call('/api/friends/hidden', { hidden });
    if (status !== 200) throw new Error('bad');
  } catch {
    store.set({ friendsHidden: !hidden });
    toast('Не получилось сохранить', 'error');
  }
}

// Tell the server what this listener is playing, so friends see it. Sent when the track or the
// room changes and every 45 s while playing; an empty report when playback stops.
let lastKey = '';
async function push(force) {
  const s = store.get();
  if (!s.user || s.friendsHidden) return;
  const t = s.status === 'playing' && s.track ? s.track : null;
  const room = s.together ? s.together.code : '';
  const key = t ? `${t.id}|${room}` : '';
  if (!force && key === lastKey) return;
  lastKey = key;
  try {
    await call('/api/friends/activity', { track: t ? { id: t.id, title: t.title, artist: t.artist, artwork: t.artwork } : null, room });
  } catch {}
}

export function startFriends() {
  store.subscribe(() => push(false));
  setInterval(() => {
    const s = store.get();
    if (s.status === 'playing' && s.track) push(true);
  }, 45000);
}
