// Yandex Music playlists for «Перенос музыки», read in the desktop app over the listener's own
// connection: Yandex answers 451 to our server (it blocks by country), but not to listeners in
// Russia. The web version can't do this (no CORS), so it asks the server (server/yandexRoute.js).
//
// Links: music.yandex.ru/users/<login>/playlists/<kind> (kind 3 is «Мне нравится»),
// /playlists/<uuid>, /users/<login>/tracks, /album/<id>, /album/<id>/track/<id>.

const bridge = window.blink;
const API = 'https://api.music.yandex.net';
const MAX = 2000;

export const canReadYandex = !!(bridge && !bridge.isWeb);

async function ym(path) {
  const r = await bridge.json(API + path, { tries: 2 });
  if (r && r.ok && r.data && r.data.result) return r.data.result;
  const status = (r && r.status) || 0;
  throw Object.assign(new Error('yandex_' + status), { status: [401, 403, 404].includes(status) ? 404 : status });
}

const cover = (uri) => (uri ? 'https://' + String(uri).replace('%%', '400x400') : '');
const item = (t) => ({ artist: (t.artists || []).map((a) => a.name).filter(Boolean).join(', '), title: t.title });

async function tracksById(ids) {
  const out = [];
  for (let i = 0; i < ids.length; i += 200) out.push(...((await ym(`/tracks?track-ids=${encodeURIComponent(ids.slice(i, i + 200).join(','))}`)) || []));
  return out;
}

// Playlist tracks come either with full details or as bare ids (big playlists, likes).
async function resolve(shorts) {
  shorts = (shorts || []).slice(0, MAX);
  const full = shorts.filter((s) => s.track).map((s) => s.track);
  const bare = shorts.filter((s) => !s.track && s.id).map((s) => (s.albumId ? `${s.id}:${s.albumId}` : String(s.id)));
  if (bare.length) full.push(...(await tracksById(bare)));
  return full.filter((t) => t && t.title).map(item);
}

function parseLink(url) {
  const s = String(url || '');
  let m = /\/users\/([^/?#\s]+)\/playlists\/(\d+)/.exec(s);
  if (m) return { kind: 'playlist', user: decodeURIComponent(m[1]), id: m[2] };
  m = /\/users\/([^/?#\s]+)\/tracks/.exec(s);
  if (m) return { kind: 'likes', user: decodeURIComponent(m[1]) };
  m = /\/playlists\/([A-Za-z0-9.-]{8,64})/.exec(s);
  if (m) return { kind: 'uuid', id: m[1] };
  m = /\/album\/(\d+)\/track\/(\d+)/.exec(s);
  if (m) return { kind: 'track', id: `${m[2]}:${m[1]}` };
  m = /\/album\/(\d+)/.exec(s);
  if (m) return { kind: 'album', id: m[1] };
  return null;
}

// → { name, cover, items: [{ artist, title }] }; throws with status 404 for closed/missing ones.
export async function readYandex(url) {
  const link = parseLink(url);
  if (!link) throw Object.assign(new Error('bad_link'), { status: 400 });
  if (link.kind === 'album') {
    const al = await ym(`/albums/${link.id}/with-tracks`);
    return { name: al.title, cover: cover(al.coverUri), items: (al.volumes || []).flat().filter((t) => t && t.title).map(item) };
  }
  if (link.kind === 'track') {
    const [t] = await tracksById([link.id]);
    if (!t) throw Object.assign(new Error('not_found'), { status: 404 });
    return { name: t.title, cover: cover(t.coverUri), items: [item(t)] };
  }
  if (link.kind === 'likes') {
    const lib = await ym(`/users/${encodeURIComponent(link.user)}/likes/tracks`);
    return { name: 'Мне нравится', cover: '', items: await resolve(lib && lib.library && lib.library.tracks) };
  }
  const pl = link.kind === 'uuid' ? await ym(`/playlist/${link.id}`) : await ym(`/users/${encodeURIComponent(link.user)}/playlists/${link.id}`);
  const name = link.kind === 'playlist' && link.id === '3' ? 'Мне нравится' : pl.title;
  return { name, cover: cover((pl.cover && pl.cover.uri) || pl.ogImage), items: await resolve(pl.tracks) };
}
