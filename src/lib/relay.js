// YouTube through Blink's server, for listeners whose network slows YouTube down (desktop app only).
// The server hands out the relay's address; the app routes only YouTube hosts through it and goes
// direct when the relay doesn't answer. Always on in the app; the admin panel can switch it off for
// everyone (the server then answers { on: false }).
import { store } from './store.js';
import { MEDIA } from './catalog.js';

export const hasRelay = () => !!(window.blink && window.blink.ytRelay);
export const relayOn = () => true;

let applied = null;
export async function syncRelay() {
  if (!hasRelay()) return;
  const want = relayOn(store.get().settings);
  if (applied === want) return;
  applied = want;
  if (!want) return window.blink.ytRelay(null);
  try {
    const r = await fetch(`${MEDIA}/api/yt-relay`, { cache: 'no-store' });
    const cfg = r.ok ? await r.json() : null;
    // An older server without the relay answers 404: keep whatever the app already uses.
    if (cfg) await window.blink.ytRelay(cfg.on ? cfg : null);
  } catch {
    applied = null;
  }
}
