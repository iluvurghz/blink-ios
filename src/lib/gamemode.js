// Game mode swaps the window in the same process (no restart): the main process opens the light window (no GPU, see GameApp.jsx)
// or the full one. Whatever was playing picks up where it stopped.
import { store, nowTime, saveNow } from './store.js';
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
  // An older app restarts and reads the setting from disk: it has to get there before that, the usual save waits 1.2 s.
  saveNow();
  // Let the transition play; an older app without relaunch just reloads the page.
  setTimeout(() => {
    const b = window.blink;
    if (b.setGame) b.setGame(game);
    else if (b.relaunch) b.relaunch();
    else location.reload();
  }, 1100);
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
