// Equalizer: 10 bands over Blink's own audio element through Web Audio.
// It can only hear what plays in that element (Blink's catalog and other direct audio files):
// the YouTube player is a cross-origin frame, its sound never reaches the page.
import { store } from './store.js';

export const BANDS = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
export const BAND_LABELS = ['32', '64', '125', '250', '500', '1K', '2K', '4K', '8K', '16K'];

export const PRESETS = [
  ['flat', 'Ровно', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]],
  ['bass', 'Бас', [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]],
  ['deep', 'Глубокий бас', [8, 7, 5, 2, -1, -1, 0, 0, 0, 0]],
  ['vocal', 'Вокал', [-2, -2, -1, 1, 3, 4, 4, 2, 0, -1]],
  ['electro', 'Электроника', [5, 4, 1, 0, -2, 1, 1, 2, 4, 5]],
  ['rock', 'Рок', [4, 3, 2, 0, -1, -1, 1, 2, 3, 4]],
  ['hiphop', 'Хип-хоп', [5, 4, 2, 3, -1, -1, 1, 0, 2, 3]],
  ['acoustic', 'Акустика', [3, 3, 2, 1, 1, 1, 2, 3, 2, 1]],
  ['night', 'Ночь', [2, 1, 0, 0, 0, -1, -2, -3, -4, -5]],
  ['bright', 'Яркость', [-1, -1, 0, 0, 0, 1, 2, 4, 5, 6]],
];

// The equalizer UI was removed in 1.8.0: the bands stay flat, the graph still carries crossfade gains.
export const eqState = () => {
  const e = store.get().settings.eq || {};
  return { on: false, preset: e.preset || 'flat', bands: Array.isArray(e.bands) && e.bands.length === 10 ? e.bands : PRESETS[0][2], pre: Number(e.pre) || 0 };
};

export function setEq(patch) {
  const s = store.get();
  store.set({ settings: { ...s.settings, eq: { ...eqState(), ...patch } } });
  apply();
}

let ctx = null;
let filters = [];
let pre = null;
const wired = new WeakSet();
const gains = new WeakMap();

const db = (v) => Math.pow(10, v / 20);

function build() {
  const AC = window.AudioContext || window.webkitAudioContext;
  if (!AC) return false;
  ctx = new AC();
  pre = ctx.createGain();
  filters = BANDS.map((f, i) => {
    const b = ctx.createBiquadFilter();
    b.type = i === 0 ? 'lowshelf' : i === BANDS.length - 1 ? 'highshelf' : 'peaking';
    b.frequency.value = f;
    b.Q.value = 1.1;
    return b;
  });
  pre.connect(filters[0]);
  filters.reduce((a, b) => (a.connect(b), b));
  filters[filters.length - 1].connect(ctx.destination);
  return true;
}

// Routes an <audio> element through the bands (once; it stays routed for good).
export function wire(el) {
  if (wired.has(el)) return true;
  if (!ctx && !build()) return false;
  try {
    // Each element gets its own gain, so a crossfade can fade one track while the other comes in.
    const g = ctx.createGain();
    ctx.createMediaElementSource(el).connect(g);
    g.connect(pre);
    gains.set(el, g);
    wired.add(el);
    apply();
    return true;
  } catch (e) {
    console.warn('eq wire', e);
    return false;
  }
}

export const gainOf = (el) => gains.get(el);

export function resume() {
  if (ctx && ctx.state !== 'running') ctx.resume().catch(() => {});
}

// A phone call or the lock screen can stop Web Audio on phones ('suspended', or 'interrupted' on
// iOS): wake it when the page comes back.
document.addEventListener('visibilitychange', () => document.visibilityState === 'visible' && resume());

export function apply() {
  if (!ctx) return;
  const e = eqState();
  const t = ctx.currentTime;
  filters.forEach((f, i) => f.gain.setTargetAtTime(e.on ? e.bands[i] : 0, t, 0.03));
  // Boosts are balanced by a little headroom, so loud presets don't clip.
  const peak = e.on ? Math.max(0, ...e.bands) : 0;
  pre.gain.setTargetAtTime(db((e.on ? e.pre : 0) - peak * 0.6), t, 0.03);
}

export const hasEq = () => !!(window.AudioContext || window.webkitAudioContext);
