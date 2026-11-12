// Tactile feedback. Phones: a short buzz on taps (Android), a hidden iOS 18 switch click as a fallback.
// Desktop app: a soft two-note chime at launch. Both are off with settings.haptics === false / settings.startSound === false.
import { store } from './store.js';

const coarse = typeof matchMedia === 'function' && matchMedia('(pointer: coarse)').matches;
const canBuzz = typeof navigator !== 'undefined' && 'vibrate' in navigator;
let sw = null;

function iosTick() {
  try {
    if (!sw) {
      sw = document.createElement('label');
      sw.setAttribute('aria-hidden', 'true');
      sw.style.cssText = 'position:fixed;left:-99px;top:-99px;opacity:0;pointer-events:none';
      const i = document.createElement('input');
      i.type = 'checkbox';
      i.setAttribute('switch', '');
      sw.appendChild(i);
      document.body.appendChild(sw);
    }
    sw.click();
  } catch {}
}

export function buzz(pattern = 8) {
  if (store.get().settings.haptics === false) return;
  if (canBuzz) navigator.vibrate(pattern);
  else if (coarse) iosTick();
}

function chime() {
  try {
    const A = window.AudioContext || window.webkitAudioContext;
    if (!A) return;
    const ctx = new A();
    const t = ctx.currentTime + 0.05;
    [[659.25, 0], [987.77, 0.11]].forEach(([f, d]) => {
      const o = ctx.createOscillator();
      const g = ctx.createGain();
      o.type = 'sine';
      o.frequency.value = f;
      g.gain.setValueAtTime(0.0001, t + d);
      g.gain.exponentialRampToValueAtTime(0.05, t + d + 0.02);
      g.gain.exponentialRampToValueAtTime(0.0001, t + d + 0.45);
      o.connect(g).connect(ctx.destination);
      o.start(t + d);
      o.stop(t + d + 0.5);
    });
    setTimeout(() => ctx.close().catch(() => {}), 1200);
  } catch {}
}

export function launchFeel() {
  // The PC app chimes; a phone (site or app) gives a short buzz.
  if (window.blink && !window.blink.isWeb && !window.blink.mobile) {
    if (store.get().settings.startSound !== false) chime();
  } else buzz([14, 50, 10]);
}

const TAP = '.nav .tab, .iris, .icon-btn, .btn, .hm-b, .hm-modes button, .hm-pill-x, .set-tabs button, .avatar-btn';
export function initHaptics() {
  if (!coarse) return;
  document.addEventListener('pointerdown', (e) => e.target.closest && e.target.closest(TAP) && buzz(6), { passive: true });
}
