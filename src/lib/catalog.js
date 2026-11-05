// Blink's own licensed catalog: artist uploads and partner releases, streamed from blinkmusic.cc.
import { cloud } from './cloud.js';
import { store } from './store.js';

export const MEDIA = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '');

async function token() {
  if (!cloud) return null;
  const { data } = await cloud.auth.getSession();
  return data.session ? data.session.access_token : null;
}

async function api(path, opts = {}) {
  const t = await token();
  const res = await fetch(MEDIA + path, {
    ...opts,
    headers: { ...(opts.body && !(opts.body instanceof FormData) ? { 'Content-Type': 'application/json' } : {}), ...(t ? { Authorization: `Bearer ${t}` } : {}), ...(opts.headers || {}) },
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw Object.assign(new Error(data.error || 'Ошибка сервера'), { status: res.status });
  return data;
}

// A licensed track in the same shape the player uses for catalog tracks.
export function fromRow(r) {
  return {
    id: 'b:' + r.id,
    lic: r.id,
    source: 'blink',
    title: r.title,
    artist: r.artist_name,
    artistId: null,
    artistRef: r.artist_id || null, // Blink artist profile
    album: r.release_title || '',
    albumId: null,
    artwork: r.cover_path ? `${MEDIA}/covers/${r.id}.jpg` : '',
    duration: r.duration || 0,
    explicit: !!r.explicit,
    year: r.year ? String(r.year) : '',
    genre: r.genre || '',
    lrc: r.lrc || null,
    lyrics: r.lyrics || null,
    offline: !!r.offline_allowed,
  };
}

const FIELDS = 'id, artist_id, title, artist_name, release_title, duration, explicit, year, genre, lrc, lyrics, cover_path, offline_allowed, status';

export async function searchLicensed(q) {
  if (!cloud || !q.trim()) return [];
  const like = `%${q.trim().replace(/[%_,()]/g, ' ')}%`;
  const { data } = await cloud.from('lic_tracks').select(FIELDS).eq('status', 'live').or(`title.ilike.${like},artist_name.ilike.${like},release_title.ilike.${like}`).limit(20);
  return (data || []).map(fromRow);
}

export async function latestLicensed(limit = 12) {
  if (!cloud) return [];
  const { data } = await cloud.from('lic_tracks').select(FIELDS).eq('status', 'live').order('created_at', { ascending: false }).limit(limit);
  return (data || []).map(fromRow);
}

// Jamendo (Creative Commons): searched through Blink's server, streamed straight from Jamendo.
// Empty when the server has no Jamendo key yet.
export function fromJamendo(t) {
  return { id: 'j:' + t.id, source: 'jamendo', title: t.title, artist: t.artist, artistId: null, album: t.album, albumId: null, artwork: t.artwork, duration: t.duration, stream: t.stream, link: t.link };
}
export async function searchJamendo(q) {
  const r = await fetch(`${MEDIA}/api/jamendo/search?q=${encodeURIComponent(q)}`);
  const d = await r.json();
  return d.enabled ? d.tracks.map(fromJamendo) : [];
}

// Playlist cover through Blink's server (600×600 WebP in storage); returns its URL.
export async function uploadPlaylistCover(file) {
  if (!file) throw new Error('Выберите картинку');
  if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type)) throw new Error('Подойдёт JPEG, PNG или WebP');
  if (file.size > 8 * 1024 * 1024) throw new Error('Картинка больше 8 МБ');
  const fd = new FormData();
  fd.append('cover', file);
  const d = await api('/api/playlist/cover', { method: 'POST', body: fd });
  return d.url;
}

// Nickname, kept by Blink's server so signing in with Google doesn't overwrite it.
export async function saveName(name) {
  const d = await api('/api/profile/name', { method: 'POST', body: JSON.stringify({ name }) });
  return d.name;
}

// New avatar through Blink's server (re-encoded to 256×256 WebP there); returns its URL.
export async function uploadAvatar(file) {
  if (!file) throw new Error('Выберите картинку');
  if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type)) throw new Error('Подойдёт JPEG, PNG или WebP');
  if (file.size > 5 * 1024 * 1024) throw new Error('Картинка больше 5 МБ');
  const fd = new FormData();
  fd.append('avatar', file);
  const d = await api('/api/profile/avatar', { method: 'POST', body: fd });
  return d.url;
}

export const playUrl = (licId) => api(`/api/play/${licId}`).then((d) => d.url);
export const reportStream = (licId, seconds) => api('/api/streams', { method: 'POST', body: JSON.stringify({ trackId: licId, seconds }) }).catch(() => null);

// ---------- artist cabinet ----------

export const artistMe = () => api('/api/artist/me');
export const acceptOffer = (name) => api('/api/artist/accept', { method: 'POST', body: JSON.stringify({ name, accept: true }) });
export const myTracks = () => api('/api/tracks/mine').then((d) => d.tracks);
export const takedown = (licId) => api(`/api/tracks/${licId}`, { method: 'DELETE' });

// ---------- public artist profile ----------

const ARTIST = 'id, user_id, name, handle, bio, avatar_url, verified';

// Profile by id or link name, with live tracks. Label releases are matched by name only for verified artists.
export async function artistProfile(key) {
  if (!cloud) throw new Error('Нет соединения');
  const byId = /^[0-9a-f-]{36}$/.test(key);
  const { data: a, error } = await cloud.from('artists').select(ARTIST).eq(byId ? 'id' : 'handle', key).maybeSingle();
  if (error) throw error;
  if (!a) return null;
  const today = new Date().toISOString().slice(0, 10);
  const live = () => cloud.from('lic_tracks').select(FIELDS).eq('status', 'live').lte('release_date', today).order('release_date', { ascending: false }).limit(200);
  const [own, label, stats] = await Promise.all([
    live().eq('artist_id', a.id),
    a.verified ? live().eq('source', 'partner').ilike('artist_name', a.name.replace(/[\\%_]/g, (c) => '\\' + c)) : { data: [] },
    cloud.rpc('artist_stats', { aid: a.id }),
  ]);
  const st = (stats.data && stats.data[0]) || { followers: 0, likes: 0 };
  return { ...a, tracks: [...(own.data || []), ...(label.data || [])].map(fromRow), followers: Number(st.followers), likes: Number(st.likes) };
}

export async function isFollowing(artistId) {
  const user = store.get().user;
  if (!cloud || !user) return false;
  const { data } = await cloud.from('follows').select('artist_id').eq('user_id', user.id).eq('artist_id', artistId).maybeSingle();
  return !!data;
}

export async function setFollow(artistId, on) {
  const user = store.get().user;
  const q = on ? cloud.from('follows').insert({ user_id: user.id, artist_id: artistId }) : cloud.from('follows').delete().eq('user_id', user.id).eq('artist_id', artistId);
  const { error } = await q;
  if (error && error.code !== '23505') throw error;
}

// Mirrors a like on a Blink track into track_likes, so the artist sees the count.
export async function syncLike(licId, on) {
  const user = store.get().user;
  if (!cloud || !user) return;
  if (on) await cloud.from('track_likes').upsert({ user_id: user.id, track_id: licId }, { ignoreDuplicates: true });
  else await cloud.from('track_likes').delete().eq('user_id', user.id).eq('track_id', licId);
}

// ---------- announcements ----------

// One artist's posts (artistId) or the listener's feed from followed artists (no artistId), with attached tracks.
export async function listPosts(artistId = null) {
  if (!cloud) return [];
  const { data, error } = await cloud.rpc('post_list', { aid: artistId });
  if (error) throw error;
  const ids = [...new Set(data.map((p) => p.track_id).filter(Boolean))];
  const { data: rows } = ids.length ? await cloud.from('lic_tracks').select(FIELDS).in('id', ids) : { data: [] };
  const byId = new Map((rows || []).map((r) => [r.id, fromRow(r)]));
  return data.map((p) => ({ ...p, likes: Number(p.likes), track: p.track_id ? byId.get(p.track_id) || null : null }));
}

export async function createPost(artistId, body, trackId) {
  const { error } = await cloud.from('posts').insert({ artist_id: artistId, body, track_id: trackId || null });
  if (error) throw new Error(/too_often/.test(error.message) ? 'Анонс можно публиковать раз в 10 минут' : 'Не получилось опубликовать');
}

export async function deletePost(id) {
  const { error } = await cloud.from('posts').delete().eq('id', id);
  if (error) throw new Error('Не получилось удалить');
}

export async function setPostLike(postId, on) {
  const user = store.get().user;
  const { error } = on ? await cloud.from('post_likes').insert({ user_id: user.id, post_id: postId }) : await cloud.from('post_likes').delete().eq('user_id', user.id).eq('post_id', postId);
  if (error && error.code !== '23505') throw error;
}

// ---------- comments and reports ----------

export async function listComments({ postId = null, trackId = null }) {
  if (!cloud) return [];
  const { data, error } = await cloud.rpc('comment_list', { pid: postId, tid: trackId });
  if (error) throw error;
  return data;
}

export async function addComment({ postId = null, trackId = null }, body) {
  const user = store.get().user;
  const { error } = await cloud.from('comments').insert({ user_id: user.id, post_id: postId, track_id: trackId, body });
  if (error) throw new Error(/too_often/.test(error.message) ? 'Слишком много комментариев, попробуйте через час' : 'Не получилось отправить');
}

export async function deleteComment(id) {
  const { error } = await cloud.from('comments').delete().eq('id', id);
  if (error) throw new Error('Не получилось удалить');
}

export async function report(kind, targetId) {
  const user = store.get().user;
  const { error } = await cloud.from('reports').insert({ reporter_id: user.id, kind, target_id: targetId });
  if (error && error.code !== '23505') throw new Error('Не получилось отправить жалобу');
}

export async function saveArtistProfile(artistId, { bio }) {
  const { error } = await cloud.from('artists').update({ bio: bio || null }).eq('id', artistId);
  if (error) throw new Error('Не получилось сохранить');
}

// Upload with progress (fetch has no upload progress, XHR does).
export async function uploadTrack(form, onProgress) {
  const t = await token();
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('POST', MEDIA + '/api/tracks');
    if (t) xhr.setRequestHeader('Authorization', `Bearer ${t}`);
    xhr.upload.onprogress = (e) => e.lengthComputable && onProgress && onProgress(e.loaded / e.total);
    xhr.onload = () => {
      let data = {};
      try {
        data = JSON.parse(xhr.responseText);
      } catch {
        /* not json */
      }
      xhr.status < 300 ? resolve(data.track) : reject(new Error(data.error || 'Не получилось загрузить'));
    };
    xhr.onerror = () => reject(new Error('Нет соединения с сервером'));
    xhr.send(form);
  });
}

// Word-timed lyrics (TTML) for Blink's own tracks, when the release has them.
export async function fetchTtml(licId) {
  try {
    const t = await token();
    const res = await fetch(`${MEDIA}/api/tracks/${licId}/ttml`, { headers: t ? { Authorization: `Bearer ${t}` } : {} });
    if (!res.ok) return null;
    return await res.text();
  } catch {
    return null;
  }
}
