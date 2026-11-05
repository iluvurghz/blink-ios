// All network goes through the main process (no CORS, retries, timeouts).
import { sbUrl } from './sbroute.js';
const bridge = window.blink;
const SELF = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '');

async function json(url, opts) {
  const r = await bridge.json(url, opts);
  if (!r.ok) {
    const err = new Error(r.error || 'HTTP ' + r.status);
    err.status = r.status;
    err.data = r.data;
    throw err;
  }
  return r.data;
}

export function art(url, size = 600) {
  if (!url) return '';
  // iTunes: ...100x100bb.jpg → ...600x600bb.jpg
  if (/\/\d+x\d+bb\.jpg$/.test(url)) return url.replace(/\/\d+x\d+bb\.jpg$/, `/${size}x${size}bb.jpg`);
  // Yandex: .../100x100 or .../1000x1000 → .../600x600
  if (/\/\d+x\d+$/.test(url)) return url.replace(/\/\d+x\d+$/, `/${size}x${size}`);
  return url;
}

function cleanAlbum(name = '') {
  return name.replace(/\s*-\s*(Single|EP)$/i, '');
}

export function toTrack(r) {
  // artworkUrl600 (from Yandex) is already high-res; artworkUrl100 (iTunes) is scaled up via art().
  // For Yandex URLs (avatars.yandex.net), scale to 1000x1000 instead of 100x100.
  let artwork = '';
  if (r.artworkUrl600) {
    artwork = r.artworkUrl600.replace(/\/\d+x\d+$/, '/1000x1000');
  } else if (r.artworkUrl100) {
    artwork = art(r.artworkUrl100, 600);
  }
  return {
    id: String(r.trackId),
    title: r.trackName,
    artist: r.artistName,
    artistId: r.artistId ? String(r.artistId) : null,
    album: cleanAlbum(r.collectionName),
    albumId: r.collectionId ? String(r.collectionId) : null,
    artwork,
    duration: r.trackTimeMillis ? Math.round(r.trackTimeMillis / 1000) : 0,
    explicit: r.trackExplicitness === 'explicit',
    year: r.releaseDate ? r.releaseDate.slice(0, 4) : '',
    genre: r.primaryGenreName || '',
  };
}

export function toAlbum(r) {
  return {
    id: String(r.collectionId),
    title: cleanAlbum(r.collectionName),
    artist: r.artistName,
    artistId: r.artistId ? String(r.artistId) : null,
    artwork: art(r.artworkUrl100, 600),
    year: r.releaseDate ? r.releaseDate.slice(0, 4) : '',
    count: r.trackCount || 0,
    type: /- Single$/i.test(r.collectionName) ? 'Сингл' : /- EP$/i.test(r.collectionName) ? 'EP' : 'Альбом',
  };
}

// All iTunes requests go through our server (Sweden) so they work from Russia too.
// Falls back to direct Apple if the proxy is unavailable, then to Yandex Music.
const IT_PROXY = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '') + '/api/itunes';
const IT_DIRECT = 'https://itunes.apple.com';
const YM_PROXY = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '') + '/api/yandex';

function itSearch(params) {
  return json(`${IT_PROXY}/search?${params}`).catch(() => json(`${IT_DIRECT}/search?${params}`));
}
function itLookup(params) {
  return json(`${IT_PROXY}/lookup?${params}`).catch(() => json(`${IT_DIRECT}/lookup?${params}`));
}

// Yandex Music helpers — used when iTunes is unavailable
async function ymSearchTracks(term, limit = 30) {
  try {
    const d = await json(`${YM_PROXY}/search?q=${encodeURIComponent(term)}&type=track&limit=${limit}`);
    return (d.results || []).filter(r => r.kind === 'song').map(toTrack);
  } catch { return []; }
}

async function ymArtistTracks(artistId, limit = 40) {
  try {
    const d = await json(`${YM_PROXY}/artist/${artistId}/tracks?limit=${limit}`);
    return (d.results || []).filter(r => r.kind === 'song').map(toTrack);
  } catch { return []; }
}

async function ymArtistAlbums(artistId, limit = 60) {
  try {
    const d = await json(`${YM_PROXY}/artist/${artistId}/albums?limit=${limit}`);
    return (d.results || []).filter(r => r.wrapperType === 'collection').map(toAlbum);
  } catch { return []; }
}

export async function search(term, country) {
  const q = encodeURIComponent(term);
  try {
    const [songs, albums, artists] = await Promise.all([
      itSearch(`term=${q}&country=${country}&media=music&entity=song&limit=50`).catch(() => ({ results: [] })),
      itSearch(`term=${q}&country=${country}&media=music&entity=album&limit=16`).catch(() => ({ results: [] })),
      itSearch(`term=${q}&country=${country}&media=music&entity=musicArtist&limit=8`).catch(() => ({ results: [] })),
    ]);
    const tracks = songs.results.filter((r) => r.kind === 'song').map(toTrack);
    // Query is an artist's name: Apple's song search often misses their tracks, so add them.
    const norm = (s) => (s || '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
    const named = artists.results.find((a) => norm(a.artistName) === norm(term));
    if (named) {
      const own = await itLookup(`id=${named.artistId}&entity=song&limit=30&country=${country}`).catch(() => ({ results: [] }));
      const have = new Set(tracks.map((t) => t.id));
      for (const t of own.results.filter((r) => r.kind === 'song').map(toTrack)) if (!have.has(t.id)) tracks.push(t);
    }
    // Always top up with Yandex tracks — fills gaps, especially for Russian/indie artists
    const yandexTracks = await ymSearchTracks(term, 20);
    const allTrackKeys = new Set(tracks.map((t) => (t.title + '|' + t.artist).toLowerCase().replace(/[^\p{L}\p{N}|]+/gu, '')));
    for (const t of yandexTracks) {
      const k = (t.title + '|' + t.artist).toLowerCase().replace(/[^\p{L}\p{N}|]+/gu, '');
      if (!allTrackKeys.has(k)) { allTrackKeys.add(k); tracks.push(t); }
    }

    // Build artist list: iTunes artists + Yandex artists (Yandex fills in what Apple misses).
    const norm2 = (s) => (s || '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
    const artistList = artists.results
      .filter((a, i, all) => all.findIndex((b) => norm2(b.artistName) === norm2(a.artistName)) === i)
      .map((a) => {
        const id = String(a.artistId);
        const t = tracks.find((x) => x.artistId === id);
        return { id, name: a.artistName, genre: a.primaryGenreName, artwork: t ? t.artwork : '' };
      });

    // Fetch Yandex artists and add any not already in iTunes list
    try {
      const ymArtistsRes = await fetch(`${YM_PROXY}/search?q=${encodeURIComponent(term)}&type=artist&limit=5`);
      if (ymArtistsRes.ok) {
        const ymArtistsData = await ymArtistsRes.json();
        for (const a of (ymArtistsData.results || [])) {
          const name = a.artistName || '';
          if (!name) continue;
          // Skip if already in iTunes list (same name)
          if (artistList.some((x) => norm2(x.name) === norm2(name))) continue;
          // Use ym: prefix so Artist page knows to use Yandex data
          const t = yandexTracks.find((x) => norm2(x.artist).includes(norm2(name)));
          artistList.push({
            id: `ym:${a.artistId}`,
            name,
            genre: a.primaryGenreName || '',
            artwork: t ? t.artwork : (a.artworkUrl600 || a.artworkUrl100 || ''),
          });
        }
      }
    } catch { /* ignore */ }

    // Deezer: the artist named in the query (linked in the admin or found by exact name) with
    // their full discography — small artists Apple lists partly or not at all.
    const dz = await deezerMatch(term, !!named && tracks.length >= 10);
    if (dz) {
      const have = new Set(tracks.map((t) => norm(t.title) + '|' + norm(splitArtists(t.artist)[0])));
      for (const t of dz.tracks) {
        const k = norm(t.title) + '|' + norm(splitArtists(t.artist)[0]);
        if (!have.has(k)) (have.add(k), tracks.push(t));
      }
      const same = artistList.findIndex((x) => norm2(x.name) === norm2(dz.name));
      if (same === -1) artistList.unshift({ id: dz.id, name: dz.name, genre: '', artwork: dz.picture });
      else if (!artistList[same].artwork) artistList[same].artwork = dz.picture;
    }

    return { tracks, albums: albums.results.filter((r) => r.collectionType).map(toAlbum), artists: artistList };
  } catch {
    // Full iTunes failure — fall back to Yandex entirely
    const tracks = await ymSearchTracks(term, 30);
    return { tracks, albums: [], artists: [] };
  }
}

// A 30-second preview for a track (Apple's own public snippet), used as the soundtrack for a
// story video. Works for any track — it searches the iTunes catalogue by name, independent of
// how the track plays in Blink. Returns a preview URL or '' when none is found.
export async function previewFor(track, country = 'US') {
  const term = `${track.artist || ''} ${track.title || ''}`.trim();
  if (!term) return '';
  try {
    const r = await itSearch(`term=${encodeURIComponent(term)}&country=${country}&media=music&entity=song&limit=10`);
    const list = (r.results || []).filter((x) => x.kind === 'song' && x.previewUrl);
    if (!list.length) return '';
    const norm = (s) => (s || '').toLowerCase().replace(/[^0-9a-zа-яё]+/gi, '');
    const wantT = norm(track.title);
    const wantA = norm(track.artist);
    const best =
      list.find((x) => norm(x.trackName) === wantT && norm(x.artistName).includes(wantA)) ||
      list.find((x) => (norm(x.trackName).includes(wantT) || wantT.includes(norm(x.trackName))) && norm(x.artistName).includes(wantA)) ||
      list.find((x) => norm(x.trackName).includes(wantT) || wantT.includes(norm(x.trackName))) ||
      list[0];
    return (best && best.previewUrl) || '';
  } catch {
    return '';
  }
}

export async function lookupTracks(ids, country) {
  if (!ids.length) return [];
  // Apple's lookup only accepts numeric IDs — filter out chart/Deezer/Yandex IDs.
  const numeric = ids.filter((id) => /^\d+$/.test(String(id)));
  if (!numeric.length) return [];
  const d = await itLookup(`id=${numeric.join(',')}&country=${country}`);
  const byId = new Map(d.results.filter((r) => r.kind === 'song').map((r) => [String(r.trackId), toTrack(r)]));
  return numeric.map((id) => byId.get(String(id))).filter(Boolean);
}

// Deezer metadata through Blink's server (deezerArtistRoute.js); ids are prefixed 'dz'.
const DZ = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '') + '/api/deezer';
const dzTrack = (t) => ({ ...t, source: 'chart', artistId: null });
async function deezerMatch(q, linkedOnly = false) {
  try {
    const d = await json(`${DZ}/match?q=${encodeURIComponent(q)}${linkedOnly ? '&linked=1' : ''}`);
    return d && d.id ? { ...d, tracks: d.tracks.map(dzTrack) } : null;
  } catch {
    return null;
  }
}

export async function album(id, country) {
  if (String(id).startsWith('dz')) {
    const d = await json(`${DZ}/album/${String(id).slice(2)}`);
    return { ...d, copyright: '', genre: '', tracks: d.tracks.map(dzTrack) };
  }
  const d = await itLookup(`id=${id}&entity=song&country=${country}`);
  const head = d.results.find((r) => r.wrapperType === 'collection');
  if (!head) throw new Error('not found');
  return {
    ...toAlbum(head),
    copyright: head.copyright || '',
    genre: head.primaryGenreName || '',
    tracks: d.results.filter((r) => r.kind === 'song').map((r) => ({ ...toTrack(r), no: r.trackNumber, disc: r.discNumber })),
  };
}

export async function artist(id, country) {
  // Deezer artist (from search, when Apple has no profile with that name)
  if (String(id).startsWith('dz')) {
    const d = await json(`${DZ}/artist/${String(id).slice(2)}`);
    return { id: String(id), name: d.name, genre: '', artwork: d.picture || (d.albums[0] && d.albums[0].artwork) || '', albums: d.albums, tracks: d.tracks.map(dzTrack) };
  }
  // Yandex artist: id starts with 'ym:' — use Yandex data directly
  if (String(id).startsWith('ym:')) {
    const ymId = String(id).slice(3);
    try {
      const [tracksRes, albumsRes] = await Promise.all([
        fetch(`${YM_PROXY}/artist/${ymId}/tracks?limit=40&metaOnly=true`).then(r => r.ok ? r.json() : { results: [] }).catch(() => ({ results: [] })),
        fetch(`${YM_PROXY}/artist/${ymId}/albums?limit=60`).then(r => r.ok ? r.json() : { results: [] }).catch(() => ({ results: [] })),
      ]);
      const tracks = (tracksRes.results || []).filter(r => r.kind === 'song').map(toTrack);
      const albums = (albumsRes.results || []).filter(r => r.wrapperType === 'collection').map(toAlbum).sort((x, y) => (y.year || '').localeCompare(x.year || ''));
      const name = tracks[0] ? tracks[0].artist.split(/,|&/)[0].trim() : '';
      const artwork = albums[0] ? albums[0].artwork : tracks[0] ? tracks[0].artwork : '';
      return {
        id: String(id),
        name,
        genre: '',
        artwork,
        albums,
        tracks,
      };
    } catch {
      return { id: String(id), name: '', genre: '', artwork: '', albums: [], tracks: [] };
    }
  }

  // iTunes artist (numeric id)
  try {
    const [a, s] = await Promise.all([
      itLookup(`id=${id}&entity=album&limit=60&country=${country}`),
      itLookup(`id=${id}&entity=song&limit=40&country=${country}`),
    ]);
    const head = a.results.find((r) => r.wrapperType === 'artist') || s.results.find((r) => r.wrapperType === 'artist');
    const albums = a.results.filter((r) => r.wrapperType === 'collection').map(toAlbum).sort((x, y) => (y.year || '').localeCompare(x.year || ''));
    // Only the artist's own tracks and their collaborations, not songs that merely share an id.
    const own = (x) => (x || '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
    const credited = (r) => !head || splitArtists(r.artistName).some((n) => own(n) === own(head.artistName));
    const tracks = s.results
      .filter((r) => r.kind === 'song')
      .filter((r) => String(r.artistId) === String(id) || credited(r))
      .map(toTrack);
    // Apple files collaborations («witheredead & kahoma») and namesake profiles under other artist
    // ids: pull in every song and release where this exact name is credited.
    if (head) {
      const q = encodeURIComponent(head.artistName);
      const [ms, ma] = await Promise.all([
        itSearch(`term=${q}&country=${country}&media=music&entity=song&attribute=artistTerm&limit=100`).catch(() => ({ results: [] })),
        itSearch(`term=${q}&country=${country}&media=music&entity=album&attribute=artistTerm&limit=50`).catch(() => ({ results: [] })),
      ]);
      const haveT = new Set(tracks.map((t) => t.id));
      for (const r of ms.results) if (r.kind === 'song' && credited(r) && !haveT.has(String(r.trackId))) (haveT.add(String(r.trackId)), tracks.push(toTrack(r)));
      const haveA = new Set(albums.map((x) => x.id));
      for (const r of ma.results) if (r.collectionType && credited(r) && !haveA.has(String(r.collectionId))) (haveA.add(String(r.collectionId)), albums.push(toAlbum(r)));
      albums.sort((x, y) => (y.year || '').localeCompare(x.year || ''));
    }
    // Same name on Deezer (linked in the admin or exact match): its discography is the reference.
    // Apple adds only collaborations Deezer doesn't list; Apple-only solo tracks (often deleted
    // releases or a namesake's) are dropped.
    const dz = head ? await deezerMatch(head.artistName, tracks.length >= 10) : null;
    if (dz) {
      const key = (t) => own(t.title);
      const have = new Set(dz.tracks.map(key));
      const collabs = tracks.filter((t) => own(t.artist) !== own(head.artistName) && !have.has(key(t)));
      const haveA = new Set(dz.albums.map((x) => own(x.title)));
      const extraA = albums.filter((x) => own(x.artist) !== own(head.artistName) && !haveA.has(own(x.title)));
      return {
        id: String(id),
        name: head.artistName,
        genre: head.primaryGenreName || '',
        artwork: dz.picture || (dz.albums[0] && dz.albums[0].artwork) || '',
        albums: [...dz.albums, ...extraA].sort((x, y) => (y.year || '').localeCompare(x.year || '')),
        tracks: [...dz.tracks, ...collabs],
      };
    }
    // Top up with Yandex if iTunes returned nothing
    const allTracks = tracks.length >= 3 ? tracks : [...tracks, ...(await ymArtistTracks(id, 40))];
    const allAlbums = albums.length >= 1 ? albums : await ymArtistAlbums(id, 60);
    return {
      id: String(id),
      name: head ? head.artistName : allTracks[0] ? allTracks[0].artist : '',
      genre: head ? head.primaryGenreName : '',
      artwork: allAlbums[0] ? allAlbums[0].artwork : allTracks[0] ? allTracks[0].artwork : '',
      albums: allAlbums,
      tracks: allTracks,
    };
  } catch {
    // Full iTunes failure — use Yandex
    const [tracks, albums] = await Promise.all([ymArtistTracks(id, 40), ymArtistAlbums(id, 60)]);
    return {
      id: String(id),
      name: tracks[0] ? tracks[0].artist : '',
      genre: '',
      artwork: albums[0] ? albums[0].artwork : tracks[0] ? tracks[0].artwork : '',
      albums,
      tracks,
    };
  }
}

const RSS = ['https://rss.marketingtools.apple.com', 'https://rss.applemarketingtools.com'];

async function feed(country, kind, limit) {
  let last;
  // Same source for the app and the website: Blink's server relays Apple's feed.
  const base = import.meta.env.VITE_SUPABASE_URL;
  if (base) {
    try {
      const d = await json(sbUrl(`${base}/functions/v1/charts`) + `?country=${country}&kind=${kind}&limit=${limit}`, { tries: 2, timeout: 8000 });
      if (d && d.feed && d.feed.results) return d.feed.results;
    } catch (e) {
      last = e;
    }
  }
  // Apple's newer feed has no CORS headers, so the browser version goes straight to the older one.
  for (const host of bridge.isWeb ? [] : RSS) {
    try {
      const d = await json(`${host}/api/v2/${country}/music/most-played/${limit}/${kind}.json`, { tries: 1, timeout: 6000 });
      if (d && d.feed && d.feed.results) return d.feed.results;
    } catch (e) {
      last = e;
    }
  }
  // Older iTunes feed as a fallback, mapped to the same shape.
  const d = await json(`${IT_DIRECT}/${country}/rss/top${kind}/limit=${limit}/json`);
  const entries = (d && d.feed && d.feed.entry) || [];
  if (!entries.length) throw last || new Error('feed');
  return entries.map((e) => ({
    id: e.id.attributes['im:id'],
    name: e['im:name'].label,
    artistName: e['im:artist'].label,
    artistId: e['im:artist'].attributes ? (e['im:artist'].attributes.href.match(/\/(\d+)\?/) || [])[1] : null,
    artworkUrl100: e['im:image'][e['im:image'].length - 1].label,
    releaseDate: e['im:releaseDate'] ? e['im:releaseDate'].label : '',
  }));
}

export async function charts(country) {
  const [songs, albums] = await Promise.all([
    feed(country, 'songs', 50).catch(() => []),
    feed(country, 'albums', 100).catch(() => []),
  ]);
  const tracks = await lookupTracks(
    songs.map((s) => s.id),
    country
  ).catch(() => []);
  return {
    tracks,
    // "Albums of the week": what's played most among recent releases, not old catalog hits.
    albums: albums
      .filter((r) => r.releaseDate && Date.now() - Date.parse(r.releaseDate) < 1000 * 60 * 60 * 24 * 120)
      .slice(0, 24)
      .map((r) => ({
        id: String(r.id),
        title: cleanAlbum(r.name),
        artist: r.artistName,
        artistId: r.artistId ? String(r.artistId) : null,
        artwork: art(r.artworkUrl100, 600),
        year: r.releaseDate ? r.releaseDate.slice(0, 4) : '',
        type: 'Альбом',
        fresh: Date.now() - Date.parse(r.releaseDate) < 1000 * 60 * 60 * 24 * 21,
      })),
  };
}

// ---------- Lyrics (LRCLIB) ----------

export function parseLrc(text) {
  const lines = [];
  for (const raw of text.split(/\r?\n/)) {
    const tags = [...raw.matchAll(/\[(\d+):(\d+(?:\.\d+)?)\]/g)];
    if (!tags.length) continue;
    let body = raw.replace(/\[(\d+):(\d+(?:\.\d+)?)\]/g, '').trim();
    // Enhanced LRC word timings: <mm:ss.xx>word
    let words = null;
    if (/<\d+:\d+(\.\d+)?>/.test(body)) {
      words = [];
      const re = /<(\d+):(\d+(?:\.\d+)?)>([^<]*)/g;
      let m;
      while ((m = re.exec(body))) {
        if (m[3]) words.push({ t: +m[1] * 60 + +m[2], w: m[3] });
      }
      body = words.map((w) => w.w).join('').trim();
    }
    for (const t of tags) lines.push({ t: +t[1] * 60 + +t[2], text: body, words });
  }
  lines.sort((a, b) => a.t - b.t);
  return lines;
}

function norm(s = '') {
  return s
    .toLowerCase()
    .replace(/\(.*?\)|\[.*?\]/g, '')
    .replace(/feat\..*$/, '')
    .replace(/[^\p{L}\p{N} ]/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

export async function lyrics(track) {
  // Blink's own tracks bring their lyrics with them (uploaded by the artist).
  if (track.source === 'blink') {
    if (track.lrc) return { synced: parseLrc(track.lrc) };
    if (track.lyrics) return { plain: track.lyrics.split(/\r?\n/) };
    return null;
  }
  const LR = SELF + '/api/lrclib';
  const pick = (d) => {
    if (!d) return null;
    if (d.instrumental) return { instrumental: true };
    if (d.syncedLyrics) return { synced: parseLrc(d.syncedLyrics) };
    if (d.plainLyrics) return { plain: d.plainLyrics.split(/\r?\n/) };
    return null;
  };
  const title = track.title.replace(/\s*\((feat|with|prod)\.?[^)]*\)/i, '').trim();
  const mainArtist = track.artist.split(/,|&| feat/i)[0].trim();
  const p = new URLSearchParams({ track_name: title, artist_name: mainArtist });
  if (track.album) p.set('album_name', track.album);
  if (track.duration) p.set('duration', String(track.duration));
  // One quick try each: LRCLIB goes down now and then, and a long retry only keeps the pane empty.
  const quick = { tries: 1, timeout: 7000 };
  let down = false;
  let plain = null;
  try {
    const got = pick(await json(`${LR}/get?${p}`, quick));
    if (got && (got.synced || got.instrumental)) return got;
    plain = got;
  } catch (e) {
    down = e.status !== 404;
  }
  if (!down) {
    try {
      const list = await json(`${LR}/search?${new URLSearchParams({ track_name: title, artist_name: track.artist })}`, quick);
      if (Array.isArray(list) && list.length) {
        const nt = norm(title);
        const scored = list
          .map((d) => {
            let s = 0;
            if (norm(d.trackName) === nt) s += 5;
            if (d.syncedLyrics) s += 4;
            if (track.duration && d.duration) s -= Math.min(6, Math.abs(d.duration - track.duration) / 2);
            return { d, s };
          })
          .sort((a, b) => b.s - a.s);
        const best = pick(scored[0].d);
        if (best) return best;
      }
    } catch (e) {
      down = e.status !== 404;
    }
  }
  if (plain) return plain;
  // Plain text from a second source when LRCLIB has nothing or is down.
  try {
    const d = await json(`${SELF}/api/lyricsovh?${new URLSearchParams({ artist: mainArtist, title })}`, quick);
    const text = d && typeof d.lyrics === 'string' && d.lyrics.replace(/^Paroles de la chanson.*\r?\n/, '').trim();
    if (text) return { plain: text.split(/\r?\n/) };
  } catch {
    /* nothing there either */
  }
  // "No lyrics" is remembered; "the service is down" is not, so the listener can try again.
  if (down) throw Object.assign(new Error('lyrics unavailable'), { unavailable: true });
  return null;
}

// ---------- YouTube (official Data API, user's own key) ----------

const YT = 'https://www.googleapis.com/youtube/v3';

function isoDur(s) {
  const m = /PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/.exec(s || '');
  return m ? (+m[1] || 0) * 3600 + (+m[2] || 0) * 60 + (+m[3] || 0) : 0;
}

export async function checkKey(key) {
  try {
    await json(`${YT}/videos?part=id&id=dQw4w9WgXcQ&key=${encodeURIComponent(key)}`);
    return { ok: true };
  } catch (e) {
    const reason = e.data && e.data.error && e.data.error.errors && e.data.error.errors[0] && e.data.error.errors[0].reason;
    return { ok: false, reason: reason || e.message };
  }
}

const BAD = ['live', 'cover', 'karaoke', 'nightcore', 'slowed', 'sped up', 'speed up', '8d', 'instrumental', 'reverb', 'remix', 'lyrics', 'lyric', 'текст', 'караоке', 'кавер', 'reaction', 'реакция', 'minus', 'минус', 'tutorial', 'piano'];

export async function resolveVideos(track, key) {
  const q = `${track.artist.split(/,|&/)[0].trim()} ${track.title.replace(/\s*\((feat|with)\.?[^)]*\)/i, '')}`;
  let found;
  try {
    found = await json(
      `${YT}/search?part=snippet&type=video&maxResults=12&videoEmbeddable=true&q=${encodeURIComponent(q)}&key=${encodeURIComponent(key)}`
    );
  } catch (e) {
    const reason = e.data && e.data.error && e.data.error.errors && e.data.error.errors[0] && e.data.error.errors[0].reason;
    const err = new Error(reason || 'youtube');
    err.reason = reason || (e.status === 0 ? 'offline' : 'youtube');
    throw err;
  }
  const ids = found.items.map((i) => i.id.videoId).filter(Boolean);
  if (!ids.length) return { audio: [], clip: null };
  const det = await json(`${YT}/videos?part=contentDetails,status,snippet&id=${ids.join(',')}&key=${encodeURIComponent(key)}`).catch(() => ({ items: [] }));
  const info = new Map(det.items.map((v) => [v.id, v]));

  const nt = norm(track.title);
  const na = norm(track.artist.split(/,|&/)[0]);
  const wantsBad = BAD.filter((w) => norm(track.title).includes(w));

  const rows = found.items
    .map((it) => {
      const v = info.get(it.id.videoId);
      if (v && v.status && v.status.embeddable === false) return null;
      const title = it.snippet.title.replace(/&amp;/g, '&').replace(/&#39;/g, "'").replace(/&quot;/g, '"');
      const channel = it.snippet.channelTitle || '';
      const nTitle = norm(title);
      const dur = v ? isoDur(v.contentDetails.duration) : 0;
      let base = 0;
      // How much of the song's title is in the video's title (0..1).
      let tHit = 0;
      if (nt && nTitle.includes(nt)) (base += 30), (tHit = 1);
      else {
        const toks = nt.split(' ').filter((x) => x.length > 1);
        const hit = toks.filter((x) => nTitle.includes(x)).length;
        tHit = toks.length ? hit / toks.length : 0;
        base += tHit * 20;
      }
      const aHit = !!(na && (nTitle.includes(na) || norm(channel).includes(na)));
      if (aHit) base += 15;
      const padded = ` ${nTitle} `;
      for (const w of BAD) if (!wantsBad.includes(w) && padded.includes(` ${w} `)) base -= 35;
      const diff = track.duration && dur ? Math.abs(dur - track.duration) : 20;
      // Reject if duration is way off — it's a different song or a different version.
      if (track.duration && dur && diff > Math.max(30, track.duration * 0.25)) return null;
      // Stricter: require decent title match, or artist + exact duration.
      const exactLen = !!(track.duration && dur && diff <= 5);
      if (tHit < 0.6 && !(aHit && exactLen)) return null;
      const topic = / - Topic$/.test(channel);
      const isClip = /official\s*(music\s*)?video|music video|official mv|\bmv\b|клип|videoclip/i.test(title) || /vevo/i.test(channel);
      // "- Topic" channels are YouTube Music's official audio — almost always the correct track.
      const audio = base + (topic ? 60 : 0) + (/official audio|audio/i.test(title) ? 15 : 0) - Math.min(40, diff * 1.5) - (isClip ? 15 : 0);
      const clip = base + (isClip ? 40 : -30) + (topic ? -50 : 0) - Math.min(20, Math.max(0, diff - 30) * 0.3);
      return { id: it.id.videoId, title, channel, dur, audio, clip };
    })
    .filter(Boolean);

  const audio = [...rows].sort((a, b) => b.audio - a.audio).filter((r) => r.audio > 0).map((r) => r.id);
  const clipRow = [...rows].sort((a, b) => b.clip - a.clip)[0];
  const clip = clipRow && clipRow.clip > 20 ? clipRow.id : null;
  if (!audio.length && rows.length) audio.push([...rows].sort((a, b) => b.audio - a.audio)[0].id);
  return { audio: audio.slice(0, 4), clip };
}

// "Miyagi & Andy Panda" is one combined artist in Apple's catalog; each name gets its own page.
export function splitArtists(name = '') {
  return name
    .split(/\s*(?:,|&|\sx\s|\sи\s|×|\sfeat\.?\s|\sft\.?\s)\s*/i)
    .map((x) => x.trim())
    .filter(Boolean);
}

const artistIds = new Map();
export async function findArtistId(name, country) {
  const key = name.toLowerCase();
  if (artistIds.has(key)) return artistIds.get(key);
  let id = null;
  try {
    const d = await itSearch(`term=${encodeURIComponent(name)}&entity=musicArtist&limit=5&country=${country}`);
    const list = d.results || [];
    const n = (x) => x.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
    const hit = list.find((a) => n(a.artistName) === n(name));
    if (hit) id = String(hit.artistId);
  } catch { /* iTunes failed */ }

  // Fallback: search Yandex for the artist ID
  if (!id) {
    try {
      const d = await json(`${YM_PROXY}/search?q=${encodeURIComponent(name)}&type=artist&limit=5`);
      const list = d.results || [];
      const n = (x) => (x || '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
      const hit = list.find((a) => n(a.artistName) === n(name));
      if (hit) id = String(hit.artistId);
    } catch { /* ignore */ }
  }

  artistIds.set(key, id);
  return id;
}
