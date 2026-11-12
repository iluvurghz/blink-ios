// Pulls a small palette out of the artwork so the whole window takes its light.
import { proxied, scaleSc } from './img.js';
const cache = new Map();

function rgbToHsl(r, g, b) {
  r /= 255;
  g /= 255;
  b /= 255;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  let h = 0;
  let s = 0;
  const l = (max + min) / 2;
  if (max !== min) {
    const d = max - min;
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    if (max === r) h = (g - b) / d + (g < b ? 6 : 0);
    else if (max === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
    h *= 60;
  }
  return [h, s, l];
}

const hsl = (h, s, l) => `hsl(${Math.round(h)} ${Math.round(s * 100)}% ${Math.round(l * 100)}%)`;

export const DEFAULT_PALETTE = {
  accent: 'hsl(18 92% 64%)',
  accentInk: 'hsl(18 60% 10%)',
  glowA: 'hsl(18 70% 38%)',
  glowB: 'hsl(352 48% 28%)',
  glowC: 'hsl(24 42% 19%)',
};

// New Year / winter theme: a cold blue palette that replaces the artwork-derived one.
export const WINTER_PALETTE = {
  accent: 'hsl(200 85% 66%)',
  accentInk: 'hsl(210 55% 12%)',
  glowA: 'hsl(200 70% 36%)',
  glowB: 'hsl(220 48% 28%)',
  glowC: 'hsl(190 42% 22%)',
};

export async function paletteFor(url) {
  if (!url) return DEFAULT_PALETTE;
  if (cache.has(url)) return cache.get(url);
  const small = scaleSc(url.replace(/\/\d+x\d+bb\.jpg$/, '/60x60bb.jpg'), 100);
  // Slow hosts (SoundCloud, Deezer, Apple) come through Blink's server; if it can't give the
  // picture, the original address is tried once.
  const via = proxied(small);
  const data = (await window.blink.image(via)) || (via !== small ? await window.blink.image(small) : null);
  if (!data) return DEFAULT_PALETTE;
  const img = new Image();
  img.src = data;
  await img.decode().catch(() => {});
  const c = document.createElement('canvas');
  c.width = c.height = 24;
  const ctx = c.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(img, 0, 0, 24, 24);
  const px = ctx.getImageData(0, 0, 24, 24).data;

  const buckets = new Map();
  for (let i = 0; i < px.length; i += 4) {
    const [h, s, l] = rgbToHsl(px[i], px[i + 1], px[i + 2]);
    const key = s < 0.12 ? 'n' + Math.round(l * 4) : Math.round(h / 24) % 15;
    const b = buckets.get(key) || { n: 0, h: 0, s: 0, l: 0, hx: 0, hy: 0 };
    b.n++;
    b.hx += Math.cos((h * Math.PI) / 180);
    b.hy += Math.sin((h * Math.PI) / 180);
    b.s += s;
    b.l += l;
    buckets.set(key, b);
  }
  const groups = [...buckets.entries()].map(([k, b]) => {
    let h = (Math.atan2(b.hy, b.hx) * 180) / Math.PI;
    if (h < 0) h += 360;
    return { neutral: String(k).startsWith('n'), n: b.n, h, s: b.s / b.n, l: b.l / b.n };
  });
  const chroma = groups.filter((g) => !g.neutral).sort((a, b) => b.n * (0.3 + b.s) - a.n * (0.3 + a.s));
  let out;
  if (!chroma.length || chroma[0].n < 8) {
    // Monochrome cover: keep it monochrome, warm it a touch.
    const l = groups.sort((a, b) => b.n - a.n)[0];
    out = {
      accent: hsl(36, 0.2, 0.82),
      accentInk: hsl(36, 0.1, 0.1),
      glowA: hsl(30, 0.08, Math.min(0.32, 0.12 + (l ? l.l * 0.2 : 0.1))),
      glowB: hsl(250, 0.08, 0.2),
      glowC: hsl(30, 0.06, 0.16),
    };
  } else {
    const a = chroma[0];
    const b = chroma[1] || { ...a, h: (a.h + 40) % 360 };
    const c3 = chroma[2] || { ...a, h: (a.h + 300) % 360 };
    const sat = Math.max(0.55, Math.min(0.95, a.s + 0.25));
    out = {
      accent: hsl(a.h, sat, 0.66),
      accentInk: hsl(a.h, 0.6, 0.1),
      glowA: hsl(a.h, Math.min(0.75, a.s + 0.15), 0.36),
      glowB: hsl(b.h, Math.min(0.7, b.s + 0.1), 0.3),
      glowC: hsl(c3.h, Math.min(0.6, c3.s + 0.05), 0.24),
    };
  }
  cache.set(url, out);
  return out;
}
