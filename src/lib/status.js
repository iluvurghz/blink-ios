// Live health of the services Blink leans on — for the status page and the indicator in Settings.
// Every check is best-effort and times out fast; a red dot here only colours the page, it never
// touches playback. States: 'up' (works), 'slow' (works, but sluggish), 'down' (not answering),
// 'off' (not set up / switched off — grey, not a problem).
import { store, ytKey } from './store.js';
import { MEDIA } from './catalog.js';

const bridge = typeof window !== 'undefined' ? window.blink : null;
const SB = import.meta.env.VITE_SUPABASE_URL;
const ANON = import.meta.env.VITE_SUPABASE_ANON_KEY;

const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());

// GET JSON: through the desktop bridge (no CORS, substitutes the built-in key) or directly.
async function jget(url, budget = 7000) {
  if (bridge) {
    const r = await bridge.json(url, { tries: 1, timeout: budget });
    if (!r.ok) throw Object.assign(new Error('HTTP ' + r.status), { status: r.status, data: r.data });
    return r.data;
  }
  const r = await fetch(url, { cache: 'no-store', signal: AbortSignal.timeout(budget) });
  const data = await r.json().catch(() => null);
  if (!r.ok) throw Object.assign(new Error('HTTP ' + r.status), { status: r.status, data });
  return data;
}

// Supabase and our own server send CORS to everyone, so a plain fetch reaches them on desktop too,
// and here any answer at all (even 401) means the service is up — only silence is 'down'.
async function reachable(url, headers, budget = 7000) {
  const r = await fetch(url, { headers, cache: 'no-store', signal: AbortSignal.timeout(budget) });
  return r.status;
}

async function timed(run, { slow = 2500 } = {}) {
  const t0 = now();
  try {
    const r = await run();
    const ms = Math.round(now() - t0);
    const state = r.state || (ms > slow ? 'slow' : 'up');
    return { ...r, state, ms };
  } catch (e) {
    const ms = Math.round(now() - t0);
    const timeout = e.name === 'TimeoutError' || /timeout|aborted/i.test(e.message || '');
    return { state: 'down', note: timeout ? 'не ответил вовремя' : 'не отвечает', ms };
  }
}

const quota = (e) => {
  const errs = e.data && e.data.error && e.data.error.errors;
  const reason = (errs && errs[0] && errs[0].reason) || (e.data && e.data.error && e.data.error.status);
  return /quota|rateLimit|dailyLimit/i.test(reason || '') ? reason : null;
};

const CHECKS = [
  {
    key: 'yt',
    label: 'YouTube',
    desc: 'Поиск и проигрывание треков',
    icon: 'youtube',
    core: true,
    run: () =>
      timed(async () => {
        const key = ytKey(store.get());
        if (key) {
          try {
            await jget(`https://www.googleapis.com/youtube/v3/videos?part=id&id=dQw4w9WgXcQ&key=${encodeURIComponent(key)}`);
            return { state: 'up', note: 'YouTube отвечает' };
          } catch (e) {
            if (quota(e)) return { state: 'slow', note: 'дневной лимит YouTube почти исчерпан' };
            throw e;
          }
        }
        // No local key: the shared lookup on our Supabase function. A preflight that answers means it's deployed.
        const code = await reachable(`${SB}/functions/v1/resolve`, undefined, 7000).catch(() => 0);
        if (!code) throw new Error('no answer');
        return { state: 'up', note: 'общий поиск видео работает' };
      }),
  },
  {
    key: 'server',
    label: 'Сервер Blink',
    desc: 'Каталог, обложки, загрузки',
    icon: 'library',
    core: true,
    run: () =>
      timed(async () => {
        const d = await jget(`${MEDIA}/api/health`);
        if (d && d.ok) return { state: 'up', note: 'сервер на связи' };
        throw new Error('bad health');
      }),
  },
  {
    key: 'meta',
    label: 'Поиск и метаданные',
    desc: 'Apple, Deezer и Spotify для поиска и обложек',
    icon: 'search',
    run: () =>
      timed(async () => {
        // The app searches Apple + Deezer + Spotify together, so one source being restricted
        // (e.g. Spotify's 403) doesn't break search — only a server that won't answer at all does.
        try {
          const d = await jget(`${MEDIA}/api/spotify/search?q=test`);
          if (d && Array.isArray(d.tracks) && d.tracks.length) return { state: 'up', note: 'источники отвечают' };
          if (d && d.error === 'spotify_off') return { state: 'up', note: 'Apple и Deezer отвечают, Spotify не подключён' };
          return { state: 'up', note: 'источники отвечают' };
        } catch (e) {
          // The server answered with an error (Spotify restricted) — search still works via Apple и Deezer.
          if (e.status) return { state: 'up', note: 'работает (Spotify сейчас недоступен)' };
          throw e;
        }
      }),
  },
  {
    key: 'lyrics',
    label: 'Тексты песен',
    desc: 'Открытая база LRCLIB',
    icon: 'lyrics',
    run: () =>
      timed(async () => {
        if (!bridge) {
          // LRCLIB blocks cross-site reads, so on the website this one is checked only in the app.
          return { state: 'off', note: 'проверяется только в приложении' };
        }
        const d = await jget((import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '') + '/api/lrclib/search?q=test');
        if (Array.isArray(d)) return { state: 'up', note: 'база отвечает' };
        throw new Error('bad');
      }),
  },
  {
    key: 'accounts',
    label: 'Аккаунт и синхронизация',
    desc: 'Вход, «Любимое» и плейлисты на всех устройствах',
    icon: 'user',
    core: true,
    run: () =>
      timed(async () => {
        const code = await reachable(`${SB}/auth/v1/health`, { apikey: ANON });
        if (code && code < 500) return { state: 'up', note: 'сервис аккаунтов отвечает' };
        throw new Error('HTTP ' + code);
      }),
  },
  {
    key: 'charts',
    label: 'Чарты',
    desc: 'Топ России и подборки по дням',
    icon: 'eq',
    run: () =>
      timed(async () => {
        const d = await jget(`${MEDIA}/api/charts/daily`);
        if (d && Array.isArray(d.items) && d.items.length) return { state: 'up', note: 'чарты обновляются' };
        return { state: 'slow', note: 'источник чартов временно пуст' };
      }),
  },
  {
    key: 'relay',
    label: 'YouTube через сервер',
    desc: 'Обход замедления YouTube в некоторых сетях',
    icon: 'wifi',
    run: () =>
      timed(async () => {
        const d = await jget(`${MEDIA}/api/yt-relay`);
        if (d && d.on) return { state: 'up', note: 'ретранслятор включён' };
        return { state: 'off', note: 'выключен на сервере' };
      }),
  },
  {
    key: 'api',
    label: 'API (запасной источник)',
    desc: 'Включается, когда на YouTube трека нет',
    icon: 'api',
    run: () =>
      timed(async () => {
        // The parser gateway answers 401 without a login (gateway up) or 503 when the parser is down.
        const code = await reachable(`${MEDIA}/api/mp3/search?q=test`).catch(() => 0);
        if (!code) throw new Error('no answer');
        if (code === 503) return { state: 'down', note: 'парсер сейчас не запущен' };
        return { state: 'up', note: 'на связи' };
      }),
  },
];

export const SERVICES = CHECKS.map(({ key, label, desc, icon }) => ({ key, label, desc, icon }));

// Worst state decides the overall light: a core service down is red, anything else amiss is amber.
export function overallOf(rows) {
  const by = Object.fromEntries(rows.map((r) => [r.key, r]));
  const core = CHECKS.filter((c) => c.core).map((c) => by[c.key]).filter(Boolean);
  if (core.some((r) => r.state === 'down')) return 'down';
  if (rows.some((r) => r.state === 'down') || rows.some((r) => r.state === 'slow')) return 'slow';
  if (rows.length && rows.every((r) => r.state === 'up' || r.state === 'off')) return 'up';
  return 'slow';
}

let running = null;
export async function runStatus() {
  if (running) return running;
  running = (async () => {
    const rows = await Promise.all(
      CHECKS.map(async (c) => ({ key: c.key, label: c.label, desc: c.desc, icon: c.icon, core: !!c.core, ...(await c.run()) }))
    );
    const overall = overallOf(rows);
    store.set({ svc: { rows, overall, at: Date.now() } });
    return { rows, overall };
  })();
  try {
    return await running;
  } finally {
    running = null;
  }
}
