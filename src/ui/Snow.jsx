import { useEffect, useRef } from 'react';
import { useStore } from '../lib/store.js';

// Falling snow for the New Year / winter theme. Lightweight canvas: ~60 flakes,
// pauses when the tab is hidden or when reduced-motion is preferred.
export default function Snow() {
  const on = useStore((s) => s.winterTheme);
  const ref = useRef(null);

  useEffect(() => {
    if (!on) return;
    const canvas = ref.current;
    if (!canvas) return;

    const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduced) return; // static snowflakes aren't worth drawing

    const ctx = canvas.getContext('2d');
    let raf = 0;
    let running = true;
    const N = 60;
    const flakes = [];

    const resize = () => {
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = window.innerWidth * dpr;
      canvas.height = window.innerHeight * dpr;
      canvas.style.width = window.innerWidth + 'px';
      canvas.style.height = window.innerHeight + 'px';
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      // (Re)seed flakes across the new viewport.
      const W = window.innerWidth, H = window.innerHeight;
      flakes.length = 0;
      for (let i = 0; i < N; i++) {
        flakes.push({
          x: Math.random() * W,
          y: Math.random() * H,
          r: 1 + Math.random() * 2.5,
          vy: 0.3 + Math.random() * 0.9,
          vx: (Math.random() - 0.5) * 0.5,
          drift: Math.random() * Math.PI * 2,
          ds: 0.004 + Math.random() * 0.01,
          a: 0.35 + Math.random() * 0.5,
        });
      }
    };
    resize();
    window.addEventListener('resize', resize);

    const tick = () => {
      if (!running) return;
      const W = window.innerWidth, H = window.innerHeight;
      ctx.clearRect(0, 0, W, H);
      for (const f of flakes) {
        f.drift += f.ds;
        f.y += f.vy;
        f.x += f.vx + Math.sin(f.drift) * 0.4;
        if (f.y > H + 4) { f.y = -4; f.x = Math.random() * W; }
        if (f.x > W + 4) f.x = -4;
        if (f.x < -4) f.x = W + 4;
        ctx.beginPath();
        ctx.arc(f.x, f.y, f.r, 0, Math.PI * 2);
        ctx.fillStyle = `rgba(255, 255, 255, ${f.a})`;
        ctx.fill();
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);

    const onVis = () => {
      running = !document.hidden;
      if (running) { raf = requestAnimationFrame(tick); }
      else { cancelAnimationFrame(raf); }
    };
    document.addEventListener('visibilitychange', onVis);

    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener('resize', resize);
      document.removeEventListener('visibilitychange', onVis);
    };
  }, [on]);

  if (!on) return null;
  return <canvas ref={ref} className="snow" aria-hidden="true" />;
}
