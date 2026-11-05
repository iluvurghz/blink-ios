// "I'm here" heartbeat for the online counter in Blink's admin: every 45 seconds while the page
// is visible or music is playing. Sends a random id of this device (no account, nothing else
// about the person), whether it's the app or the site, and what's playing.
import { store } from './store.js';
import { MEDIA } from './catalog.js';
import { isDesktop } from './cloud.js';

function deviceId() {
  try {
    let id = localStorage.getItem('blink.device');
    if (!id) {
      id = Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(36).padStart(2, '0')).join('').slice(0, 24);
      localStorage.setItem('blink.device', id);
    }
    return id;
  } catch {
    return null;
  }
}

function beat() {
  const s = store.get();
  const playing = s.status === 'playing' && !!s.track;
  if (document.visibilityState !== 'visible' && !playing) return;
  const device = deviceId();
  if (!device) return;
  const t = s.track;
  fetch(`${MEDIA}/api/presence`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ device, platform: isDesktop ? 'app' : 'web', playing, track: t ? { id: String(t.id), title: t.title, artist: t.artist, source: t.source === 'blink' || t.source === 'jamendo' ? t.source : 'youtube' } : null }),
    keepalive: true,
  }).catch(() => {});
}

export function startPresence() {
  beat();
  setInterval(beat, 45000);
  let last = store.get().status;
  store.subscribe(() => {
    const st = store.get().status;
    if (st !== last && (st === 'playing' || last === 'playing')) beat();
    last = st;
  });
  document.addEventListener('visibilitychange', () => document.visibilityState === 'visible' && beat());
}
