// «Точка»: the look of «Вспышка» on the home page. A square of dots with a play icon made of dots. Tap it
// and rings of light run through the dots, then the dots swell and merge into the cover (the real picture,
// drawn through the dots as they grow), and the cover stays. Stop, and the dots come back.
//
//   const dots = createDots(box, { onReveal });   // box: an empty positioned square, its size is read from the page
//   dots.set({ state, on, photo });               // state: 'rest' | 'music' | 'igniting' | 'flash'
//   dots.destroy();
// onReveal is called when the picture is whole: the page then shows the real <img> and the canvas steps aside.
// Cost: while a cover is shown nothing is drawn at all; asleep it is one small canvas at 20 frames a second,
// only while on screen and visible (reduced motion, game mode and low battery draw one still frame).
import { store } from '../lib/store.js';

const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const lerp = (a, b, k) => a + (b - a) * k;
const eo = (x) => 1 - Math.pow(1 - clamp(x), 3);
const hash = (i, j) => {
  let h = Math.imul(i * 374761393 + j * 668265263, 1274126177);
  h ^= h >>> 13;
  h = Math.imul(h, 1274126177);
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
};
const BONE = [238, 233, 226];
const HOT = [255, 238, 212];
const mix = (a, b, k) => [lerp(a[0], b[0], k), lerp(a[1], b[1], k), lerp(a[2], b[2], k)];
const rgba = (c, a) => `rgba(${c[0] | 0},${c[1] | 0},${c[2] | 0},${a})`;

const PAD = 28; // room around the box for the glow
const RINGS_MS = 1100; // one ring every so often while «Вспышка» is still being put together
const REVEAL_MS = 900;

export function createDots(box, { onReveal } = {}) {
  const cv = document.createElement('canvas');
  cv.className = 'fo-dots';
  cv.setAttribute('aria-hidden', 'true');
  box.appendChild(cv);
  const ctx = cv.getContext('2d');
  const probe = document.createElement('canvas').getContext('2d', { willReadFrequently: true });

  const G = { S: 0, N: 0, p: 0, dpr: 1, dots: [], icon: [], maxDm: 1, cx: 0, cy: 0 };
  let accent = [248, 129, 79];
  const readAccent = () => {
    const css = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim();
    probe.fillStyle = '#000';
    probe.fillStyle = css || '#f8814f';
    probe.fillRect(0, 0, 1, 1);
    const d = probe.getImageData(0, 0, 1, 1).data;
    accent = [d[0], d[1], d[2]];
  };

  // ---- the lattice: a rounded square of dots, an odd count so a dot sits in the middle ----
  const build = () => {
    const r = box.getBoundingClientRect();
    const S = Math.min(r.width, r.height);
    if (!S) return false;
    G.S = S;
    G.dpr = Math.min(2, window.devicePixelRatio || 1);
    const N0 = Math.round(S / 10);
    G.N = clamp(N0 % 2 ? N0 : N0 + 1, 17, 49);
    G.p = S / G.N;
    G.cx = S / 2;
    G.cy = S / 2;
    cv.width = Math.round((S + PAD * 2) * G.dpr);
    cv.height = Math.round((S + PAD * 2) * G.dpr);
    cv.style.cssText = `left:${-PAD}px;top:${-PAD}px;width:${S + PAD * 2}px;height:${S + PAD * 2}px`;
    const rho = S * 0.24;
    const dots = [];
    let maxDm = 1;
    for (let j = 0; j < G.N; j++)
      for (let i = 0; i < G.N; i++) {
        const x = (i + 0.5) * G.p;
        const y = (j + 0.5) * G.p;
        const dx = Math.max(Math.abs(x - G.cx) - (S / 2 - rho), 0);
        const dy = Math.max(Math.abs(y - G.cy) - (S / 2 - rho), 0);
        if (Math.hypot(dx, dy) > rho - G.p * 0.35) continue;
        const dm = Math.abs(x - G.cx) + Math.abs(y - G.cy);
        maxDm = Math.max(maxDm, dm);
        dots.push({ x, y, n: hash(i, j), dm, icon: false, ph: 0 });
      }
    // the play icon: a triangle (in units of a dot), nudged so its centre of weight is the centre
    const tri = [[-3.2, -4.9], [-3.2, 4.9], [5.1, 0]];
    const shift = 0.47;
    const inside = (u, v) => {
      let s = 0;
      for (let k = 0; k < 3; k++) {
        const a = tri[k];
        const b = tri[(k + 1) % 3];
        const c = (b[0] - a[0]) * (v - a[1]) - (b[1] - a[1]) * (u - a[0]);
        s += c >= 0 ? 1 : -1;
      }
      return Math.abs(s) === 3;
    };
    const icon = [];
    for (const d of dots) {
      const u = (d.x - G.cx) / G.p - shift;
      const v = (d.y - G.cy) / G.p;
      if (inside(u, v)) {
        d.icon = true;
        d.ph = clamp((u + 3.2) / 8.3);
        icon.push(d);
      }
    }
    G.dots = dots;
    G.icon = icon;
    G.maxDm = maxDm;
    return true;
  };

  // ---- state ----
  const S = { state: 'rest', on: false, photo: '' };
  let mode = 'rest'; // rest → ignite → reveal → cover (and back to rest when stopped)
  let t0 = 0; // when the current mode began (ms)
  let fade = 1; // the lattice fades in again after a stop
  let coverAt = 0; // when the picture became whole
  let img = null; // the cover to be revealed
  let imgReady = false;
  let raf = 0;
  let last = 0;
  let visible = true;
  let lowBattery = false;
  let t = Math.random() * 20;

  const loadImage = (url) => {
    img = null;
    imgReady = false;
    if (!url) {
      imgReady = true; // no picture: the dots swell into plain light
      return;
    }
    const im = new Image();
    im.onload = () => {
      if (img === im) imgReady = true;
      start();
    };
    im.onerror = () => {
      if (img === im) {
        img = null;
        imgReady = true;
      }
      start();
    };
    img = im;
    im.src = url;
  };

  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)');
  const isStill = () => reduce.matches || lowBattery || document.documentElement.dataset.game === 'on';
  const active = () => visible && !document.hidden && !store.get().stage;

  const dot = (x, y, r, c, a) => {
    ctx.fillStyle = rgba(c, a);
    ctx.beginPath();
    ctx.arc(x, y, r, 0, 6.283);
    ctx.fill();
  };

  const drawIcon = (nowS, scale, heat, glow) => {
    const { p, cx, cy } = G;
    const g = ctx.createRadialGradient(cx, cy, 0, cx, cy, G.S * 0.34);
    g.addColorStop(0, rgba(accent, 0.2 * glow));
    g.addColorStop(1, rgba(accent, 0));
    ctx.fillStyle = g;
    ctx.fillRect(-PAD, -PAD, G.S + PAD * 2, G.S + PAD * 2);
    for (const d of G.icon) {
      const shimmer = 0.5 + 0.5 * Math.sin(nowS * 2.6 - d.ph * 3.4);
      const r = p * (0.4 + 0.05 * shimmer) * scale;
      dot(d.x, d.y, r, mix(accent, HOT, clamp(0.16 * shimmer + heat)), 0.96);
    }
  };

  // ---- one frame: `loop` is the animation clock, `step` draws ----
  const loop = (now) => {
    raf = 0;
    if (!G.S || !active()) return;
    const still = isStill();
    if (!still) raf = requestAnimationFrame(loop);
    const busy = mode === 'ignite' || mode === 'reveal';
    if (!still && now - last < (busy ? 33 : 50)) return;
    const dt = Math.min(0.1, (now - last) / 1000 || 0.033);
    last = now;
    step(dt);
  };
  const step = (dt) => {
    if (!G.S) return;
    t += dt;
    if (mode === 'cover') {
      // the real picture is up: after a moment (the page fades its <img> in over the last frame) nothing is left to draw
      if (raf) {
        cancelAnimationFrame(raf);
        raf = 0;
      }
      if (performance.now() - coverAt > 260) {
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.clearRect(0, 0, cv.width, cv.height);
      }
      return;
    }
    ctx.setTransform(G.dpr, 0, 0, G.dpr, PAD * G.dpr, PAD * G.dpr);
    ctx.clearRect(-PAD, -PAD, G.S + PAD * 2, G.S + PAD * 2);
    const { p } = G;
    const tau = (performance.now() - t0) / 1000;

    if (mode === 'rest') {
      fade = Math.min(1, fade + dt * 4);
      const band = ((t * 0.17) % 1.7) - 0.35;
      ctx.globalAlpha = fade;
      for (const d of G.dots) {
        if (d.icon) continue;
        const s = (d.x + d.y) / (G.S * 2);
        const b = Math.exp(-Math.pow((s - band) / 0.07, 2));
        dot(d.x, d.y, (p / 10) * (1.25 + 0.3 * d.n + 1.2 * b), mix(BONE, accent, b * 0.5), 0.2 + 0.1 * d.n + 0.55 * b);
      }
      drawIcon(t, 1, 0, 1);
      ctx.globalAlpha = 1;
    } else if (mode === 'ignite') {
      // the icon flares, then rings run out of it through the dots (diamond rings: the distance is counted along the rows and columns)
      const pop = Math.exp(-Math.pow((tau - 0.08) / 0.09, 2));
      const ringT = tau < 0.04 ? -1 : (tau - 0.04) % (RINGS_MS / 1000);
      const ringN = tau < 0.04 ? 0 : Math.floor((tau - 0.04) / (RINGS_MS / 1000));
      const R = ringT < 0 ? -1 : eo(ringT / 0.78) * G.maxDm * 1.08;
      const w = G.maxDm * 0.085;
      const charge = ringN > 0 ? 1 : R < 0 ? 0 : clamp(R / G.maxDm);
      for (const d of G.dots) {
        if (d.icon) continue;
        const ring = R < 0 ? 0 : Math.exp(-Math.pow((d.dm - R) / w, 2)) * (1 - 0.45 * clamp(R / G.maxDm));
        const swept = ringN > 0 || d.dm < R ? 1 : 0;
        const a = 0.2 + 0.1 * d.n + 0.2 * swept * charge + 0.7 * ring;
        dot(d.x, d.y, (p / 10) * (1.25 + 0.3 * d.n + 0.4 * swept + 2.6 * ring), mix(mix(BONE, accent, 0.55 * swept), HOT, ring * 0.8), Math.min(1, a));
      }
      drawIcon(t, 1 + 0.9 * pop, pop * 0.8, 1 + pop);
      // the cover is in and the first rings are out: swell into the picture
      if (S.state === 'flash' && imgReady && tau > 0.5) {
        mode = 'reveal';
        t0 = performance.now();
      }
    } else if (mode === 'reveal') {
      // every dot grows from the middle outwards; the picture is drawn through the dots, tinted with light until they merge
      const tr = tau;
      const bins = [new Path2D(), new Path2D(), new Path2D(), new Path2D(), new Path2D(), new Path2D()];
      let done = true;
      const rLit = p * 0.34;
      const rFull = p * 0.8;
      const all = G.dots;
      for (const d of all) {
        const delay = (d.dm / G.maxDm) * 0.46;
        const q = clamp((tr - delay) / 0.44);
        if (q < 1) done = false;
        const e = eo(q);
        const r = lerp(rLit, rFull, e);
        const b = Math.min(5, Math.floor(e * 5.999));
        bins[b].moveTo(d.x + r, d.y);
        bins[b].arc(d.x, d.y, r, 0, 6.283);
      }
      const side = img ? Math.min(img.naturalWidth, img.naturalHeight) : 0;
      for (let b = 0; b < 6; b++) {
        ctx.save();
        ctx.clip(bins[b]);
        if (img && side) {
          ctx.drawImage(img, (img.naturalWidth - side) / 2, (img.naturalHeight - side) / 2, side, side, 0, 0, G.S, G.S);
        } else {
          ctx.fillStyle = rgba(mix(accent, [20, 18, 24], 0.55), 1);
          ctx.fillRect(0, 0, G.S, G.S);
        }
        // light over the picture while the dots are small, none once they merge
        ctx.fillStyle = rgba(mix(accent, HOT, 0.25), 0.85 * (1 - (b + 0.5) / 6));
        ctx.fillRect(0, 0, G.S, G.S);
        ctx.restore();
      }
      if (done && tr > REVEAL_MS / 1000 - 0.05) {
        mode = 'cover';
        coverAt = performance.now();
        if (onReveal) onReveal();
        setTimeout(start, 300); // clears the canvas
      }
    }
  };

  const start = () => {
    if (!G.S && !build()) return;
    if (isStill()) {
      // still frame: asleep it is the lattice; a lit state goes straight to the picture
      if (S.state === 'flash' && imgReady && mode !== 'cover') {
        mode = 'cover';
        coverAt = performance.now();
        if (onReveal) onReveal();
      }
      step(0.033);
      return;
    }
    if (mode === 'cover') return step(0);
    if (!raf && active()) raf = requestAnimationFrame(loop);
  };

  if (navigator.getBattery)
    navigator
      .getBattery()
      .then((b) => {
        const check = () => {
          lowBattery = !b.charging && b.level < 0.2;
          start();
        };
        b.addEventListener('levelchange', check);
        b.addEventListener('chargingchange', check);
        check();
      })
      .catch(() => {});

  const ro = new ResizeObserver(() => {
    if (build()) start();
  });
  ro.observe(box);
  const io = new IntersectionObserver(([e]) => {
    visible = e.isIntersecting;
    start();
  });
  io.observe(box);
  const onVis = () => start();
  document.addEventListener('visibilitychange', onVis);
  reduce.addEventListener('change', onVis);
  window.addEventListener('blink-game', onVis);
  const colorTimer = setInterval(readAccent, 2000);
  const unsub = store.subscribe(() => {
    // the palette eases over after a track change: read it again a few times
    start();
  });
  readAccent();
  build();
  start();

  return {
    set({ state, photo }) {
      const was = S.state;
      S.state = state;
      const newPhoto = photo !== undefined && photo !== S.photo;
      if (newPhoto) S.photo = photo;
      const lit = state === 'igniting' || state === 'flash';
      const wasLit = was === 'igniting' || was === 'flash';
      if (lit && !wasLit) {
        // «Вспышка» lights: the rings start and the cover starts loading
        mode = 'ignite';
        t0 = performance.now();
        readAccent();
        loadImage(S.photo);
      } else if (!lit && wasLit) {
        // stopped: the dots come back
        mode = 'rest';
        fade = 0.1;
        t0 = performance.now();
      } else if (newPhoto && (mode === 'ignite' || mode === 'reveal')) {
        loadImage(S.photo);
      }
      start();
    },
    destroy() {
      cancelAnimationFrame(raf);
      clearInterval(colorTimer);
      ro.disconnect();
      io.disconnect();
      unsub();
      document.removeEventListener('visibilitychange', onVis);
      reduce.removeEventListener('change', onVis);
      window.removeEventListener('blink-game', onVis);
      cv.remove();
    },
  };
}
