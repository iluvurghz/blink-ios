// The launch picture of Blink: «blink» written in dots, and the orange full stop that starts it all.
// The full stop pops, a diamond ring of light runs out of it through a field of dots, and the letters
// grow out of the dots as the ring passes (so the word is born from the dot, right to left). Then it waits
// (the full stop blinks) until outro() floods it with light.
// A plain script that puts DotWord on window (imported by App.jsx for the app's own intro). No dependencies.
//
//   const dw = DotWord.create(canvas, { w, h, weight: 600, lit: false });
//   dw.start();            // build-up, then waits
//   dw.outro(() => {});    // flood of light; calls back when it is over (~0.25 s)
//   dw.still();            // draws the finished picture once (iOS launch images, a start that is already lit)
//   dw.destroy();
(function (root) {
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
  const ACC = [248, 129, 79];
  const mix = (a, b, k) => [lerp(a[0], b[0], k), lerp(a[1], b[1], k), lerp(a[2], b[2], k)];
  const rgba = (c, a) => `rgba(${c[0] | 0},${c[1] | 0},${c[2] | 0},${a})`;

  function create(canvas, o) {
    const W = o.w;
    const H = o.h;
    const dpr = o.dpr || Math.min(2, root.devicePixelRatio || 1);
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    canvas.style.width = W + 'px';
    canvas.style.height = H + 'px';
    const ctx = canvas.getContext('2d');
    const weight = o.weight || 600;
    const family = o.family || 'Unbounded';

    // ---- the field of dots and the word ----
    const pitch = Math.max(5.5, Math.sqrt((W * H) / 9000));
    const cols = Math.ceil(W / pitch);
    const rows = Math.ceil(H / pitch);
    const fs = Math.min((W * 0.78) / 3.2, H * 0.3);
    const cx = W / 2;
    const cy = H * 0.46;
    const tc = document.createElement('canvas');
    tc.width = cols;
    tc.height = rows;
    const tctx = tc.getContext('2d', { willReadFrequently: true });
    tctx.fillStyle = '#000';
    tctx.fillRect(0, 0, cols, rows);
    tctx.fillStyle = '#fff';
    tctx.textBaseline = 'alphabetic';
    tctx.font = `${weight} ${fs / pitch}px ${family}, system-ui, sans-serif`;
    if (tctx.letterSpacing !== undefined) tctx.letterSpacing = (-0.04 * fs) / pitch + 'px';
    const m = tctx.measureText('blink').width;
    const dotR = fs * 0.1; // the radius of the full stop, in px
    const x0 = (cols - (m + (dotR * 3.4) / pitch)) / 2;
    const base = cy / pitch + (fs * 0.36) / pitch;
    tctx.fillText('blink', x0, base);
    const data = tctx.getImageData(0, 0, cols, rows).data;
    const px = (x0 + m) * pitch + dotR * 1.9; // the full stop
    const py = (base - (fs * 0.09) / pitch) * pitch;
    const far = Math.max(px, W - px) + Math.max(py, H - py); // largest distance (along rows and columns) from the full stop
    const lattice = [];
    const word = [];
    for (let j = 0; j < rows; j++)
      for (let i = 0; i < cols; i++) {
        const x = (i + 0.5) * pitch;
        const y = (j + 0.5) * pitch;
        const cov = data[(j * cols + i) * 4] / 255;
        const dm = Math.abs(x - px) + Math.abs(y - py);
        const n = hash(i, j);
        const vig = 1 - clamp((Math.hypot(x - cx, y - cy) / Math.hypot(W, H) - 0.18) / 0.32);
        if (cov > 0.3) word.push({ x, y, cov, dm, n });
        else lattice.push({ x, y, n, dm, vig });
      }

    // ---- three still layers (dim, lit, hot) drawn once, so a frame is a few draws ----
    const layer = (r, color, alphaOf) => {
      const c = document.createElement('canvas');
      c.width = canvas.width;
      c.height = canvas.height;
      const g = c.getContext('2d');
      g.scale(dpr, dpr);
      for (const d of lattice) {
        const a = alphaOf(d);
        if (a < 0.01) continue;
        g.fillStyle = rgba(color, a);
        g.beginPath();
        g.arc(d.x, d.y, r * (0.8 + 0.5 * d.n), 0, 6.283);
        g.fill();
      }
      return c;
    };
    const L = {
      dim: layer(pitch * 0.15, BONE, (d) => (0.12 + 0.07 * d.n) * (0.15 + 0.85 * d.vig)),
      lit: layer(pitch * 0.2, mix(BONE, ACC, 0.6), (d) => (0.26 + 0.1 * d.n) * (0.15 + 0.85 * d.vig)),
      hot: layer(pitch * 0.3, HOT, (d) => 0.95 * (0.35 + 0.65 * d.vig)),
    };

    const diamond = (g, R) => {
      g.moveTo(px - R, py);
      g.lineTo(px, py - R);
      g.lineTo(px + R, py);
      g.lineTo(px, py + R);
      g.closePath();
    };

    // ---- one frame at time t (seconds since the start) ----
    let flood = 0;
    const draw = (t) => {
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.drawImage(L.dim, 0, 0);
      const ring = clamp((t - 0.3) / 0.62);
      const R = eo(ring) * far * 1.12;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      if (t > 0.3) {
        // inside the ring the dots stay lit; at the ring itself they are white-hot
        ctx.save();
        ctx.beginPath();
        diamond(ctx, R);
        ctx.clip();
        ctx.globalAlpha = 0.9;
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.drawImage(L.lit, 0, 0);
        ctx.restore();
        if (ring < 1) {
          ctx.save();
          ctx.beginPath();
          const w = far * 0.07;
          diamond(ctx, R);
          diamond(ctx, Math.max(0, R - w));
          ctx.clip('evenodd');
          ctx.setTransform(1, 0, 0, 1, 0, 0);
          ctx.globalAlpha = 1 - ring * 0.6;
          ctx.drawImage(L.hot, 0, 0);
          ctx.restore();
        }
      }
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      // the letters grow out of the dots as the ring passes
      for (const d of word) {
        const q = clamp((R - d.dm) / (far * 0.1));
        const k = eo(q);
        const r = pitch * 0.5 * (0.2 + 0.78 * k) * Math.min(1, d.cov * 1.2) * (1 + 0.3 * flood);
        if (r < 0.3) continue;
        ctx.fillStyle = rgba(mix(mix(BONE, HOT, (1 - q) * 0.7), HOT, flood), 0.2 + 0.8 * k);
        ctx.beginPath();
        ctx.arc(d.x, d.y, r, 0, 6.283);
        ctx.fill();
      }
      // the full stop: pops first, blinks while waiting
      const pop = eo(t / 0.3);
      const bl = t > 1.1 ? (((t - 1.1) % 2.4) / 2.4 < 0.05 ? 1 - 0.85 * Math.sin((((t - 1.1) % 2.4) / 2.4 / 0.05) * Math.PI) : 1) : 1;
      const r = dotR * (0.3 + 0.7 * pop) * (1 + 0.12 * flood);
      const g = ctx.createRadialGradient(px, py, 0, px, py, r * 5);
      g.addColorStop(0, rgba(ACC, 0.45 + 0.4 * flood));
      g.addColorStop(1, rgba(ACC, 0));
      ctx.fillStyle = g;
      ctx.beginPath();
      ctx.arc(px, py, r * 5, 0, 6.283);
      ctx.fill();
      ctx.fillStyle = rgba(mix(ACC, HOT, flood * 0.8), 1);
      ctx.beginPath();
      ctx.ellipse(px, py, r, Math.max(0.5, r * bl), 0, 0, 6.283);
      ctx.fill();
      if (flood > 0) {
        // the flood: every dot of the field flares
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.globalAlpha = flood * 0.9;
        ctx.drawImage(L.hot, 0, 0);
        ctx.globalAlpha = 1;
      }
    };

    // ---- the clock ----
    let raf = 0;
    let t0 = 0;
    let floodAt = 0;
    let onOutro = null;
    let alive = true;
    const reduce = root.matchMedia && root.matchMedia('(prefers-reduced-motion: reduce)').matches;
    const tick = (now) => {
      if (!alive) return;
      raf = requestAnimationFrame(tick);
      const t = (now - t0) / 1000 + (o.lit ? 1.1 : 0);
      if (floodAt) {
        flood = eo((now - floodAt) / 220);
        if (now - floodAt >= 220) {
          const cb = onOutro;
          onOutro = null;
          floodAt = 0;
          flood = 1;
          draw(t);
          cancelAnimationFrame(raf);
          raf = 0;
          if (cb) cb();
          return;
        }
      }
      draw(t);
    };
    return {
      start() {
        t0 = performance.now();
        if (reduce) {
          draw(2);
          return;
        }
        raf = requestAnimationFrame(tick);
      },
      outro(cb) {
        if (reduce || !raf) {
          flood = 1;
          draw(2);
          if (cb) cb();
          return;
        }
        onOutro = cb;
        floodAt = performance.now();
      },
      still() {
        draw(2);
      },
      seek(t, fl) {
        // one frame at an exact moment (screenshots)
        cancelAnimationFrame(raf);
        raf = 0;
        flood = fl || 0;
        draw(t);
      },
      destroy() {
        alive = false;
        cancelAnimationFrame(raf);
      },
    };
  }

  root.DotWord = { create };
})(typeof window !== 'undefined' ? window : globalThis);
