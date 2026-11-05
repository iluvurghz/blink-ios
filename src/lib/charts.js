// Russian charts for the home page. The sources are never named in the interface.
//   topRu()            the main chart of Russia (desktop app only: the source refuses browsers
//                      and the Blink server's region); null when it can't be had
//   periodChart(kind)  'daily' | 'weekly' | 'monthly' top 100 of new Russian releases
// Both return Blink track objects (source: 'chart'), played through the usual YouTube lookup.

const bridge = window.blink;
const MEDIA = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '');
const TOP = 'https://api.music.yandex.net/landing3/chart/russia';
const PERIOD = 'https://band.link/chart';

async function get(url, opts) {
  const r = await bridge.json(url, { tries: 2, timeout: 10000, ...opts });
  if (!r.ok) throw Object.assign(new Error(r.error || 'HTTP ' + r.status), { status: r.status });
  return r.data;
}

const img = (uri, size = 600) => (uri ? 'https://' + uri.replace('%%', `${size}x${size}`) : '');

export async function topRu() {
  // Blink's server (in Russia) can read it for browsers; the app reads it itself and uses the
  // server when that fails.
  const viaServer = async () => {
    const r = await fetch(`${MEDIA}/api/charts/top`, { signal: AbortSignal.timeout(7000) });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    return (await r.json()).items || [];
  };
  let list;
  if (bridge.isWeb) list = await viaServer().catch(() => null);
  else {
    list = await get(TOP)
      .then((d) => d && d.result && d.result.chart && d.result.chart.tracks)
      .catch(() => null);
    if (!Array.isArray(list) || !list.length) list = await viaServer().catch(() => null);
  }
  if (!Array.isArray(list) || !list.length) return null;
  return list
    .map(({ track: t, chart }) => {
      if (!t || !t.title || !t.artists || !t.artists.length) return null;
      const al = (t.albums && t.albums[0]) || {};
      return {
        id: 'cr' + t.id,
        source: 'chart',
        title: t.version ? `${t.title} (${t.version})` : t.title,
        artist: t.artists.map((a) => a.name).join(', '),
        artistId: null,
        artistPhoto: t.artists[0].cover ? img(t.artists[0].cover.uri, 1000) : '',
        album: al.title || '',
        albumId: null,
        artwork: img(t.coverUri),
        duration: t.durationMs ? Math.round(t.durationMs / 1000) : 0,
        explicit: t.contentWarning === 'explicit',
        year: al.year ? String(al.year) : '',
        genre: al.genre || '',
        move: chart ? chart.progress : null,
      };
    })
    .filter(Boolean);
}

// The period charts come inside the page's Next.js payload (self.__next_f chunks) as
// ChartPageComponent props { type, period, items[] }.
export function parsePeriodPage(html) {
  let s = html;
  if (s.includes('self.__next_f.push')) {
    let t = '';
    const re = /self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)/g;
    let m;
    while ((m = re.exec(html))) {
      try {
        t += JSON.parse('"' + m[1] + '"');
      } catch {
        /* a broken chunk: skip it */
      }
    }
    s = t;
  }
  const at = s.indexOf('"items":[');
  if (at < 0) return [];
  let i = at + 8;
  let depth = 0;
  let inStr = false;
  for (; i < s.length; i++) {
    const c = s[i];
    if (inStr) {
      if (c === '\\') i++;
      else if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') inStr = true;
    else if (c === '[') depth++;
    else if (c === ']' && --depth === 0) break;
  }
  try {
    return JSON.parse(s.slice(at + 8, i + 1));
  } catch {
    return [];
  }
}

const today = () => {
  // The charts are published for Moscow days.
  const d = new Date(Date.now() + 3 * 3600 * 1000);
  return d.toISOString().slice(0, 10);
};
const dayBefore = (iso, n) => new Date(Date.parse(iso) - n * 86400000).toISOString().slice(0, 10);

export async function periodChart(kind = 'daily') {
  let items = [];
  // Blink's server keeps the parsed chart warm (refreshed in the background), so it answers at
  // once; the page itself is only read from here when the server has nothing.
  const viaServer = async () => {
    const r = await fetch(`${MEDIA}/api/charts/${kind}`, { signal: AbortSignal.timeout(7000) });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const list = (await r.json()).items || [];
    if (!list.length) throw new Error('empty');
    return list;
  };
  if (bridge.isWeb) {
    items = (await viaServer().catch(() => viaServer())) || [];
  } else {
    items = await viaServer().catch(() => []);
    // Today's chart may not be out yet: fall back a day or two.
    for (let back = 0; back < 3 && !items.length; back++) {
      const html = await get(`${PERIOD}/${kind}/${dayBefore(today(), back)}`).catch(() => '');
      if (typeof html === 'string') items = parsePeriodPage(html);
    }
  }
  return items
    .filter((x) => x && x.trackNameStr && (x.artistNameStr || (x.artistNames && x.artistNames.length)))
    .map((x) => ({
      id: 'cp' + x.id,
      source: 'chart',
      title: x.trackNameStr,
      artist: x.artistNameStr || x.artistNames.join(', '),
      artistId: null,
      album: '',
      albumId: null,
      artwork: x.coverUrl || '',
      duration: 0,
      explicit: false,
      year: '',
      genre: '',
      move: x.rankDiffStr || '',
    }));
}
