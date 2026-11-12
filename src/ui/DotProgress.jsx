import { useEffect, useRef } from 'react';
import { fmt } from './common.jsx';
import { useClock, clock, nowTime } from '../lib/store.js';
import { seek } from '../lib/player.js';

const BONE = '238,233,226';

// The progress of «Вспышка» as a row of dots: played ones are bright, the rest dim, the current one is the
// brand dot. Drag or tap to seek, like the plain progress bar. Painted by hand, only when the dot changes.
export default function DotProgress() {
  const cv = useRef(null);
  const cur = useRef(null);
  const drag = useRef(null);
  const duration = useClock((c) => c.duration);

  useEffect(() => {
    const el = cv.current;
    const ctx = el.getContext('2d');
    const probe = document.createElement('canvas').getContext('2d', { willReadFrequently: true });
    let w = 0;
    let n = 40;
    let dpr = 1;
    let accent = '248,129,79';
    let lastIdx = -2;
    let lastLabel = '';
    let raf = 0;
    let lastRead = 0;

    const readAccent = () => {
      probe.fillStyle = '#000';
      probe.fillStyle = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#f8814f';
      probe.fillRect(0, 0, 1, 1);
      const d = probe.getImageData(0, 0, 1, 1).data;
      accent = `${d[0]},${d[1]},${d[2]}`;
    };
    const size = () => {
      const r = el.getBoundingClientRect();
      w = r.width;
      dpr = Math.min(2, window.devicePixelRatio || 1);
      n = Math.max(24, Math.min(90, Math.floor(w / 7.2)));
      el.width = Math.round(w * dpr);
      el.height = Math.round(22 * dpr);
      lastIdx = -2;
    };
    const paint = (idx) => {
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, w, 22);
      const pad = 6;
      const step = (w - pad * 2) / (n - 1);
      for (let i = 0; i < n; i++) {
        if (i === idx) continue;
        ctx.fillStyle = i < idx ? `rgba(${BONE},.92)` : `rgba(${BONE},.24)`;
        ctx.beginPath();
        ctx.arc(pad + i * step, 11, i < idx ? 1.7 : 1.5, 0, 6.283);
        ctx.fill();
      }
      const x = pad + Math.max(0, idx) * step;
      ctx.fillStyle = `rgba(${accent},.22)`;
      ctx.beginPath();
      ctx.arc(x, 11, 8, 0, 6.283);
      ctx.fill();
      ctx.fillStyle = `rgb(${accent})`;
      ctx.beginPath();
      ctx.arc(x, 11, 4.4, 0, 6.283);
      ctx.fill();
    };
    const at = (e) => {
      const r = el.getBoundingClientRect();
      return Math.max(0, Math.min(1, (e.clientX - r.left - 6) / Math.max(1, r.width - 12))) * (clock.get().duration || 0);
    };
    const tick = (now) => {
      raf = requestAnimationFrame(tick);
      if (now - lastRead > 1500) {
        lastRead = now;
        readAccent();
        lastIdx = -2;
      }
      const d = clock.get().duration || 1;
      const t = drag.current !== null ? drag.current : nowTime();
      const idx = Math.round(Math.max(0, Math.min(1, t / d)) * (n - 1));
      if (idx !== lastIdx) {
        lastIdx = idx;
        paint(idx);
      }
      const label = fmt(t);
      if (label !== lastLabel && cur.current) cur.current.textContent = lastLabel = label;
    };
    const down = (e) => {
      el.setPointerCapture(e.pointerId);
      drag.current = at(e);
    };
    const move = (e) => {
      if (drag.current !== null) drag.current = at(e);
    };
    const up = (e) => {
      if (drag.current !== null) seek(at(e));
      drag.current = null;
    };
    const cancel = () => (drag.current = null);
    const ro = new ResizeObserver(size);
    ro.observe(el);
    el.addEventListener('pointerdown', down);
    el.addEventListener('pointermove', move);
    el.addEventListener('pointerup', up);
    el.addEventListener('pointercancel', cancel);
    readAccent();
    size();
    raf = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
      el.removeEventListener('pointerdown', down);
      el.removeEventListener('pointermove', move);
      el.removeEventListener('pointerup', up);
      el.removeEventListener('pointercancel', cancel);
    };
  }, []);

  return (
    <div className="hm-dprog">
      <span ref={cur}>0:00</span>
      <canvas ref={cv} role="slider" aria-label="Перемотка" aria-valuemin={0} aria-valuemax={Math.round(duration || 0)} />
      <span>{fmt(duration)}</span>
    </div>
  );
}
