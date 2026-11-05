// Game mode restarts Blink: the main process starts the light window (no GPU, see GameApp.jsx)
// or the full one. Whatever was playing picks up where it stopped.
import { store, nowTime } from './store.js';
import { playTrack } from './player.js';
import { handOffDevice } from './cloud.js';

const KEY = 'blink.resume';

export function switchGame(game) {
  const s = store.get();
  try {
    if (s.status === 'playing' && s.track) localStorage.setItem(KEY, JSON.stringify({ id: s.track.id, t: nowTime(), at: Date.now() }));
  } catch {
    /* storage off: just don't resume */
  }
  handOffDevice();
  store.set({ settings: { ...s.settings, game }, gameSwitch: game });
  // Let the transition play; an older app without relaunch just reloads the page.
  setTimeout(() => (window.blink.relaunch ? window.blink.relaunch() : location.reload()), 1100);
}

export function resumeAfterSwitch() {
  let r = null;
  try {
    r = JSON.parse(localStorage.getItem(KEY));
    localStorage.removeItem(KEY);
  } catch {
    return;
  }
  const s = store.get();
  if (r && s.track && r.id === s.track.id && Date.now() - r.at < 30000) playTrack(s.track, s.queue, s.index, r.t);
}
