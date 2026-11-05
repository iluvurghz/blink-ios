// The site, the home-screen app and the desktop app can stay open for days on an old version
// (an iPhone resumes the page from memory instead of loading it again). Each time Blink comes back
// to the foreground, and every 20 minutes, look at which bundle index.html points to now: if it
// changed, reload as soon as nothing is playing.
import { clock, toast } from './store.js';

const BUNDLE = /assets\/index-[\w-]+\.js/;
const running = (() => {
  const s = document.querySelector('script[type="module"][src*="assets/index-"]');
  const m = s && s.getAttribute('src').match(BUNDLE);
  return m ? m[0] : null;
})();

let pending = false;
let last = 0;

async function check() {
  if (!running || pending || !navigator.onLine || Date.now() - last < 60000) return;
  last = Date.now();
  try {
    const html = await fetch('./index.html', { cache: 'no-store' }).then((r) => (r.ok ? r.text() : ''));
    const m = html.match(BUNDLE);
    if (m && m[0] !== running) {
      pending = true;
      reloadWhenIdle();
    }
  } catch {}
}

function reloadWhenIdle() {
  if (!clock.get().playing) return location.reload();
  toast('Вышла новая версия Blink: обновится после этого трека');
  // A gap between tracks lasts a moment: reload only after two quiet checks in a row.
  let quiet = 0;
  setInterval(() => {
    quiet = clock.get().playing ? 0 : quiet + 1;
    if (quiet >= 2) location.reload();
  }, 3000);
}

export function watchForUpdates() {
  if (!running) return; // dev server
  document.addEventListener('visibilitychange', () => document.visibilityState === 'visible' && check());
  window.addEventListener('focus', check);
  setInterval(check, 20 * 60 * 1000);
}
