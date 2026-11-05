import './lib/webBridge.js';
import './lib/support.js'; // first: catches errors for the Ctrl+P bug report from the start
import { createRoot } from 'react-dom/client';
import '@fontsource/unbounded/cyrillic-300.css';
import '@fontsource/unbounded/cyrillic-500.css';
import '@fontsource/unbounded/cyrillic-600.css';
import '@fontsource/unbounded/cyrillic-700.css';
import '@fontsource/unbounded/latin-300.css';
import '@fontsource/unbounded/latin-500.css';
import '@fontsource/unbounded/latin-600.css';
import '@fontsource/unbounded/latin-700.css';
import '@fontsource/manrope/cyrillic-400.css';
import '@fontsource/manrope/cyrillic-500.css';
import '@fontsource/manrope/cyrillic-600.css';
import '@fontsource/manrope/cyrillic-700.css';
import '@fontsource/manrope/cyrillic-800.css';
import '@fontsource/manrope/latin-400.css';
import '@fontsource/manrope/latin-500.css';
import '@fontsource/manrope/latin-600.css';
import '@fontsource/manrope/latin-700.css';
import '@fontsource/manrope/latin-800.css';
import './styles.css';
import './plus.css';
import './mobile.css';
import './perf.css';
import * as player from './lib/player.js';
import * as wave from './lib/wave.js';
import { loadState, store } from './lib/store.js';

import { initCloud } from './lib/cloud.js';
import { startPresence } from './lib/presence.js';
import { watchForUpdates } from './lib/freshness.js';
import { desktopHandoffPage } from './lib/gsignin.js';
import { initHaptics } from './lib/haptic.js';
initHaptics();

// Hidden or minimised: pause CSS animations (see perf.css).
document.addEventListener('visibilitychange', () => (document.documentElement.dataset.bg = document.hidden ? '1' : ''));

// The shell service worker made the iPhone home-screen app open on a white screen: remove any
// copy a phone still has (public/sw.js does the same from its side).
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.getRegistrations().then((rs) => rs.forEach((r) => r.unregister()), () => {});
}

if (new URLSearchParams(location.search).get('gsignin') === 'desktop') {
  window.__blinkHandoff = true;
  desktopHandoffPage();
}

if (!window.__blinkHandoff) {
  loadState().then(initCloud).then(startPresence, startPresence);
  window.__blink = { store, player, wave };
  // Game mode (the app starts with --blink-game) loads only the small player, not the full interface.
  const root = createRoot(document.getElementById('root'));
  (window.blink && window.blink.game ? import('./GameApp.jsx') : import('./App.jsx')).then((m) => root.render(<m.default />));
  if (!(window.blink && window.blink.game)) watchForUpdates();
}
