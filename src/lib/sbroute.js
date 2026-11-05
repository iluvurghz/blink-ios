// Supabase sits behind Cloudflare, which Russian carriers often slow down or cut off without a VPN.
// Our server in Sweden mirrors the same API at blinkmusic.cc/sb (nginx). Direct stays the default
// (Supabase limits sign-ins per IP, and through the mirror everyone shares ours); the mirror takes
// over when direct doesn't answer, and the choice is remembered for the next start.
const DIRECT = (import.meta.env.VITE_SUPABASE_URL || '').replace(/\/$/, '');
const MIRROR = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '') + '/sb';
const ANON = import.meta.env.VITE_SUPABASE_ANON_KEY;
const KEY = 'blink.sbRoute';

const quiet = (f) => {
  try {
    return f();
  } catch {
    return null;
  }
};
let route = quiet(() => localStorage.getItem(KEY)) === 'mirror' ? 'mirror' : 'direct';
const use = (r) => {
  route = r;
  quiet(() => localStorage.setItem(KEY, r));
};

export const sbRoute = () => route;
export const sbUrl = (u) => (route === 'mirror' && DIRECT && u.startsWith(DIRECT) ? MIRROR + u.slice(DIRECT.length) : u);

// fetch for the Supabase client: rewrites to the current route; a network failure on the direct
// route switches to the mirror and retries once.
export async function sbFetch(input, init) {
  const url = typeof input === 'string' ? input : input.url;
  const go = () => fetch(typeof input === 'string' ? sbUrl(url) : new Request(sbUrl(url), input), init);
  if (route === 'mirror' || !DIRECT || !url.startsWith(DIRECT)) return go();
  try {
    return await go();
  } catch (e) {
    if (init && init.signal && init.signal.aborted) throw e;
    use('mirror');
    return go();
  }
}

// Once per start: if direct answers within 2.5 s keep it, otherwise take whichever answers first.
async function ping(base, ms) {
  const r = await fetch(base + '/auth/v1/health', { headers: { apikey: ANON }, cache: 'no-store', signal: AbortSignal.timeout(ms) });
  if (!r.ok) throw new Error('HTTP ' + r.status);
  return base;
}
export function probeRoute() {
  if (!DIRECT || !ANON) return;
  const direct = ping(DIRECT, 8000);
  const mirror = ping(MIRROR, 8000);
  const quick = Promise.race([direct, new Promise((_, no) => setTimeout(() => no(new Error('slow')), 2500))]);
  quick
    .then(() => use('direct'))
    .catch(() => Promise.any([direct, mirror]).then((b) => use(b === DIRECT ? 'direct' : 'mirror')))
    .catch(() => {});
}
