import { useEffect, useRef } from 'react';

// «Вспышка» background: soft layered waves in the current palette, shimmering into each other.
// Cheap on weak PCs: drawn at half resolution, at most 30 frames a second, and only while it is
// on screen and the window is visible. With reduced motion it draws one still frame.
const LAYERS = [
  { v: '--gA', y: 0.42, amp: 0.1, f: 1.6, s: 0.35, a: 0.75 },
  { v: '--accent', y: 0.55, amp: 0.08, f: 2.3, s: -0.5, a: 0.45 },
  { v: '--gB', y: 0.66, amp: 0.11, f: 1.2, s: 0.28, a: 0.7 },
  { v: '--gC', y: 0.8, amp: 0.07, f: 2.8, s: -0.4, a: 0.65 },
];

export default function FlashWaves({ active = false, className = 'flash-waves' }) {
  const ref = useRef(null);
  const activeRef = useRef(active);
  activeRef.current = active;

  useEffect(() => {
    const canvas = ref.current;
    const ctx = canvas.getContext('2d');
    const still = window.matchMedia('(prefers-reduced-motion: reduce)');
    // Game mode freezes the waves the same way reduced motion does.
    const isStill = () => still.matches || document.documentElement.dataset.game === 'on';
    let w = 0;
    let h = 0;
    let colors = [];
    let raf = 0;
    let last = 0;
    let t = Math.random() * 100;
    let energy = activeRef.current ? 1 : 0.45;
    let visible = true;

    const readColors = () => {
      const css = getComputedStyle(document.documentElement);
      colors = LAYERS.map((l) => css.getPropertyValue(l.v).trim() || '#c06030');
    };
    const resize = () => {
      const r = canvas.getBoundingClientRect();
      w = canvas.width = Math.max(1, Math.round(r.width / 2));
      h = canvas.height = Math.max(1, Math.round(r.height / 2));
    };
    const draw = () => {
      ctx.clearRect(0, 0, w, h);
      ctx.globalCompositeOperation = 'lighter';
      LAYERS.forEach((l, k) => {
        const grad = ctx.createLinearGradient(0, h * (l.y - l.amp * 2), 0, h);
        grad.addColorStop(0, 'transparent');
        grad.addColorStop(0.35, colors[k]);
        grad.addColorStop(1, 'transparent');
        ctx.globalAlpha = l.a * (0.55 + 0.45 * energy);
        ctx.fillStyle = grad;
        ctx.beginPath();
        ctx.moveTo(0, h);
        const amp = h * l.amp * (0.6 + 0.6 * energy);
        for (let x = 0; x <= w; x += 6) {
          const u = x / w;
          const y = h * l.y + amp * (Math.sin(u * Math.PI * l.f + t * l.s + k) + 0.45 * Math.sin(u * Math.PI * l.f * 2.3 - t * l.s * 1.7 + k * 2));
          ctx.lineTo(x, y);
        }
        ctx.lineTo(w, h);
        ctx.closePath();
        ctx.fill();
      });
      ctx.globalAlpha = 1;
      ctx.globalCompositeOperation = 'source-over';
    };
    const frame = (now) => {
      raf = 0;
      if (!visible || document.hidden || isStill()) return;
      raf = requestAnimationFrame(frame);
      if (now - last < 33) return;
      const dt = Math.min(0.1, (now - last) / 1000);
      last = now;
      energy += ((activeRef.current ? 1 : 0.45) - energy) * Math.min(1, dt * 1.5);
      t += dt * (0.35 + 0.9 * energy);
      draw();
    };
    const start = () => {
      if (isStill()) return draw();
      if (!raf && visible && !document.hidden) raf = requestAnimationFrame(frame);
    };

    readColors();
    resize();
    draw();
    start();
    const colorTimer = setInterval(readColors, 1200);
    const ro = new ResizeObserver(() => {
      resize();
      draw();
    });
    ro.observe(canvas);
    const io = new IntersectionObserver(([e]) => {
      visible = e.isIntersecting;
      start();
    });
    io.observe(canvas);
    document.addEventListener('visibilitychange', start);
    still.addEventListener('change', start);
    window.addEventListener('blink-game', start);
    return () => {
      cancelAnimationFrame(raf);
      clearInterval(colorTimer);
      ro.disconnect();
      io.disconnect();
      document.removeEventListener('visibilitychange', start);
      still.removeEventListener('change', start);
      window.removeEventListener('blink-game', start);
    };
  }, []);

  return <canvas ref={ref} className={className} aria-hidden="true" />;
}
