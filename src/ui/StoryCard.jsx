import { useEffect, useRef, useState } from 'react';
import { store, useStore, toast } from '../lib/store.js';
import { previewFor, art } from '../lib/api.js';
import { findYandexPreview } from '../lib/apiblink.js';
import { toggle } from '../lib/player.js';
import Icon from './Icon.jsx';

import { humanError } from '../lib/errors.js';
// A 1080×1920 story card with lines from the song: blurred cover behind, the words big,
// title and artist on top, Blink at the bottom. Saved as PNG, copied, or recorded as a short
// video where the lines light up word by word, with a short clip of the track as the soundtrack.
export function openStory(track, lines) {
  const uniq = [...new Set(lines.map((l) => (l || '').trim()).filter(Boolean))];
  store.set({ story: { track, lines: uniq }, sheet: 'story' });
}

const W = 1080;
const H = 1920;

function loadImage(src) {
  return new Promise((resolve) => {
    if (!src) return resolve(null);
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => resolve(null);
    img.src = src;
  });
}

function wrap(ctx, text, max) {
  const words = text.split(/\s+/);
  const out = [];
  let line = '';
  for (const w of words) {
    const test = line ? line + ' ' + w : w;
    if (ctx.measureText(test).width > max && line) {
      out.push(line);
      line = w;
    } else line = test;
  }
  if (line) out.push(line);
  return out;
}

function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

// Fonts, line wrapping and sizes for a card; reused by every frame of the video.
async function prepare(ctx, track, lines) {
  await Promise.all(['700 80px Unbounded', '600 40px Unbounded', '700 40px Manrope', '600 32px Manrope'].map((f) => document.fonts.load(f).catch(() => null)));
  const css = getComputedStyle(document.documentElement);
  const accent = css.getPropertyValue('--accent').trim() || '#ff7a45';
  const pad = 96;
  const text = lines.length ? lines : [track.title];
  const maxW = W - pad * 2 - 40;
  let size = 84;
  let groups;
  const gap = () => size * 0.45;
  const height = () => groups.reduce((a, g) => a + g.length * size * 1.22, 0) + (groups.length - 1) * gap();
  for (; size >= 44; size -= 4) {
    ctx.font = `700 ${size}px Unbounded`;
    groups = text.map((l) => wrap(ctx, l, maxW));
    if (height() <= 900) break;
  }
  ctx.font = `700 ${size}px Unbounded`;
  const rows = groups.map((g) => g.map((r) => ({ text: r, w: ctx.measureText(r).width })));
  return { accent, pad, size, lh: size * 1.22, gap: gap(), blockH: height(), rows };
}

// One frame. `p` is the video's progress (0..1), or null for the still picture with all words lit.
function paint(ctx, track, cover, L, p) {
  const { accent, pad, size, lh, gap, blockH, rows } = L;
  ctx.fillStyle = '#0d0c10';
  ctx.fillRect(0, 0, W, H);
  if (cover) {
    ctx.save();
    ctx.filter = 'blur(70px) saturate(1.5) brightness(0.6)';
    // Slow push-in through the video.
    const s = Math.max(W, H) * (1.25 + (p === null ? 0 : p * 0.12));
    ctx.drawImage(cover, (W - s) / 2, (H - s) / 2, s, s);
    ctx.restore();
  } else {
    const g = ctx.createRadialGradient(W * 0.2, H * 0.15, 0, W * 0.2, H * 0.15, H);
    g.addColorStop(0, accent);
    g.addColorStop(1, '#0d0c10');
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);
  }
  const shade = ctx.createLinearGradient(0, 0, 0, H);
  shade.addColorStop(0, 'rgba(13,12,16,0.45)');
  shade.addColorStop(0.5, 'rgba(13,12,16,0.25)');
  shade.addColorStop(1, 'rgba(13,12,16,0.8)');
  ctx.fillStyle = shade;
  ctx.fillRect(0, 0, W, H);

  // Header: small cover, title, artist.
  const cs = 200;
  if (cover) {
    ctx.save();
    ctx.shadowColor = 'rgba(0,0,0,0.5)';
    ctx.shadowBlur = 40;
    ctx.shadowOffsetY = 16;
    roundRect(ctx, pad, 170, cs, cs, 28);
    ctx.fillStyle = '#000';
    ctx.fill();
    ctx.restore();
    ctx.save();
    roundRect(ctx, pad, 170, cs, cs, 28);
    ctx.clip();
    ctx.drawImage(cover, pad, 170, cs, cs);
    ctx.restore();
  }
  const tx = cover ? pad + cs + 36 : pad;
  const tw = W - tx - pad;
  ctx.fillStyle = '#eee9e2';
  ctx.font = '700 44px Manrope';
  const title = wrap(ctx, track.title, tw).slice(0, 2);
  title.forEach((l, i) => ctx.fillText(l, tx, 240 + i * 54));
  ctx.font = '600 34px Manrope';
  ctx.fillStyle = 'rgba(238,233,226,0.7)';
  ctx.fillText(wrap(ctx, track.artist, tw)[0] || '', tx, 240 + title.length * 54 + 6);

  // The words. In the video each line sweeps word by word, one after another, like karaoke.
  const top = H / 2 - blockH / 2 + 40;
  ctx.fillStyle = accent;
  roundRect(ctx, pad, top, 10, blockH - size * 0.15, 5);
  ctx.fill();
  ctx.font = `700 ${size}px Unbounded`;
  const n = rows.length;
  // A short pause before the first line and after the last one.
  const lead = 0.06;
  const tail = 0.1;
  let y = top + size * 0.9;
  rows.forEach((group, gi) => {
    const total = group.reduce((a, r) => a + r.text.length, 0) || 1;
    const lp = p === null ? 1 : Math.max(0, Math.min(1, ((p - lead) / (1 - lead - tail)) * n - gi));
    let before = 0;
    for (const r of group) {
      const rp = Math.max(0, Math.min(1, (lp * total - before) / Math.max(1, r.text.length)));
      before += r.text.length;
      const x = pad + 40;
      ctx.fillStyle = 'rgba(238,233,226,0.3)';
      ctx.fillText(r.text, x, y);
      if (rp > 0) {
        ctx.save();
        ctx.beginPath();
        ctx.rect(x - 10, y - size * 1.1, (r.w + 20) * rp, size * 1.5);
        ctx.clip();
        ctx.fillStyle = '#eee9e2';
        ctx.shadowColor = 'rgba(0,0,0,0.35)';
        ctx.shadowBlur = 30;
        ctx.fillText(r.text, x, y);
        ctx.restore();
      }
      y += lh;
    }
    if (gi < rows.length - 1) y += gap;
  });

  // Footer: the Blink mark, and a thin progress line in the video.
  ctx.font = '700 52px Unbounded';
  ctx.fillStyle = '#eee9e2';
  ctx.fillText('Blink', pad, H - 150);
  const bw = ctx.measureText('Blink').width;
  ctx.fillStyle = accent;
  ctx.beginPath();
  ctx.arc(pad + bw + 14, H - 158, 9, 0, Math.PI * 2);
  ctx.fill();
  ctx.font = '600 30px Manrope';
  ctx.fillStyle = 'rgba(238,233,226,0.6)';
  ctx.fillText('blinkmusic.cc', pad, H - 100);
  if (p !== null) {
    ctx.fillStyle = 'rgba(238,233,226,0.15)';
    roundRect(ctx, pad, H - 60, W - pad * 2, 6, 3);
    ctx.fill();
    ctx.fillStyle = accent;
    roundRect(ctx, pad, H - 60, Math.max(6, (W - pad * 2) * p), 6, 3);
    ctx.fill();
  }
}

async function draw(canvas, track, lines, cover) {
  const ctx = canvas.getContext('2d');
  canvas.width = W;
  canvas.height = H;
  const L = await prepare(ctx, track, lines);
  paint(ctx, track, cover, L, null);
}

// MP4 where the engine can write it (Chromium 126+, so the app), WebM otherwise.
function pickType() {
  const types = ['video/mp4;codecs=avc1.640028', 'video/mp4;codecs=avc1', 'video/mp4', 'video/webm;codecs=vp9', 'video/webm'];
  return types.find((t) => window.MediaRecorder && MediaRecorder.isTypeSupported(t)) || '';
}

// Builds the video's soundtrack. Tries Yandex Music stream first (full quality, works in Russia),
// then falls back to iTunes 30-second preview. Routes through Web Audio so it can be recorded
// alongside the canvas. Returns a handle, or null when no audio is available.
async function makeBed(track) {
  const s = store.get();
  const country = (s.settings && s.settings.country) || 'US';
  const useYandex = s.yandexAsPrimary || s.yandexSearchOnly;

  // Try Yandex stream first when Yandex is the primary source
  let url = '';
  if (useYandex) {
    url = await findYandexPreview(track.title, track.artist).catch(() => '');
  }
  // Fall back to iTunes preview
  if (!url) {
    url = await previewFor(track, country).catch(() => '');
  }
  // If Yandex wasn't tried yet, still try it as last resort
  if (!url && !useYandex) {
    url = await findYandexPreview(track.title, track.artist).catch(() => '');
  }
  if (!url) return null;
  const el = new Audio();
  el.crossOrigin = 'anonymous';
  el.loop = true;
  el.src = url;
  const ok = await new Promise((resolve) => {
    let done = false;
    const fin = (v) => (done ? null : ((done = true), resolve(v)));
    el.addEventListener('canplay', () => fin(true), { once: true });
    el.addEventListener('error', () => fin(false), { once: true });
    setTimeout(() => fin(false), 6000);
    el.load();
  });
  if (!ok) return null;
  try {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    const actx = new Ctx();
    await actx.resume().catch(() => {});
    const srcNode = actx.createMediaElementSource(el);
    const gain = actx.createGain();
    gain.gain.value = 0;
    const dest = actx.createMediaStreamDestination();
    srcNode.connect(gain);
    gain.connect(dest);
    gain.connect(actx.destination);
    const atrack = dest.stream.getAudioTracks()[0];
    if (!atrack) throw new Error('no track');
    return { el, ctx: actx, gain, track: atrack };
  } catch {
    try {
      el.pause();
    } catch {
      /* ignore */
    }
    return null;
  }
}

function closeBed(bed) {
  if (!bed) return;
  try {
    bed.el.pause();
    bed.el.removeAttribute('src');
    bed.el.load();
  } catch {
    /* ignore */
  }
  try {
    if (bed.ctx.state !== 'closed') bed.ctx.close();
  } catch {
    /* ignore */
  }
}

// Records the animated card in real time: about 3 seconds a line, 8 to 16 seconds in all.
async function record(canvas, track, lines, cover, onProgress, bed) {
  const ctx = canvas.getContext('2d');
  canvas.width = W;
  canvas.height = H;
  const L = await prepare(ctx, track, lines);
  const seconds = Math.max(8, Math.min(16, (lines.length || 1) * 3.2 + 2));
  const type = pickType();
  if (!type) throw new Error('Запись видео тут не поддерживается');
  const stream = canvas.captureStream(30);
  if (bed && bed.track) {
    try {
      stream.addTrack(bed.track);
    } catch {
      /* ignore */
    }
  }
  const rec = new MediaRecorder(stream, { mimeType: type, videoBitsPerSecond: 8_000_000, audioBitsPerSecond: 160_000 });
  const chunks = [];
  rec.ondataavailable = (e) => e.data.size && chunks.push(e.data);
  const done = new Promise((resolve) => (rec.onstop = resolve));
  paint(ctx, track, cover, L, 0);
  // Start the soundtrack with the recording, fading it in and out at the edges.
  if (bed) {
    try {
      bed.el.currentTime = 0;
      await bed.el.play();
      const now = bed.ctx.currentTime;
      const g = bed.gain.gain;
      g.cancelScheduledValues(now);
      g.setValueAtTime(0, now);
      g.linearRampToValueAtTime(1, now + 0.35);
      g.setValueAtTime(1, now + Math.max(0.6, seconds - 0.6));
      g.linearRampToValueAtTime(0, now + seconds);
    } catch {
      /* saved without sound */
    }
  }
  rec.start(250);
  const t0 = performance.now();
  await new Promise((resolve) => {
    const tick = () => {
      const p = Math.min(1, (performance.now() - t0) / (seconds * 1000));
      paint(ctx, track, cover, L, p);
      onProgress(p);
      if (p < 1) requestAnimationFrame(tick);
      else setTimeout(resolve, 200);
    };
    requestAnimationFrame(tick);
  });
  rec.stop();
  await done;
  stream.getTracks().forEach((t) => t.stop());
  return { blob: new Blob(chunks, { type: type.split(';')[0] }), ext: type.startsWith('video/mp4') ? 'mp4' : 'webm' };
}

export default function StoryCard() {
  const story = useStore((s) => s.story);
  const canvas = useRef(null);
  const [picked, setPicked] = useState([]);
  const [cover, setCover] = useState(null);
  const [rec, setRec] = useState(null);
  const track = story && story.track;

  useEffect(() => {
    setPicked(story && story.lines.length ? [0] : []);
    setCover(null);
    if (!track) return;
    let alive = true;
    const src = art(track.artwork || '', 1000);
    // Through the bridge: a data URL keeps the canvas exportable whatever the image host sends.
    (window.blink.image ? window.blink.image(src) : Promise.resolve(null))
      .then((d) => loadImage(d))
      .then((img) => alive && setCover(img));
    return () => {
      alive = false;
    };
  }, [story]);

  const chosen = () => [...picked].sort((a, b) => a - b).map((i) => story.lines[i]);
  useEffect(() => {
    if (!canvas.current || !track || rec !== null) return;
    draw(canvas.current, track, chosen(), cover);
  }, [picked, cover, track, rec]);

  if (!story) return null;
  const flip = (i) => setPicked((p) => (p.includes(i) ? p.filter((x) => x !== i) : p.length >= 4 ? p : [...p, i]));
  const blob = () => new Promise((r) => canvas.current.toBlob(r, 'image/png'));
  const save = async () => {
    const b = await blob();
    const a = document.createElement('a');
    a.href = URL.createObjectURL(b);
    a.download = `Blink - ${track.artist} - ${track.title}.png`.replace(/[\\/:*?"<>|]+/g, ' ');
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 4000);
    toast('Картинка сохранена');
  };
  const video = async () => {
    if (rec !== null) return;
    setRec(0);
    let bed = null;
    const wasPlaying = store.get().status === 'playing';
    try {
      bed = await makeBed(track).catch(() => null);
      // Pause the current track so only the story's soundtrack is recorded (and heard).
      if (bed && wasPlaying) toggle();
      const { blob: b, ext } = await record(canvas.current, track, chosen(), cover, (p) => setRec(p), bed);
      const a = document.createElement('a');
      a.href = URL.createObjectURL(b);
      a.download = `Blink - ${track.artist} - ${track.title}.${ext}`.replace(/[\\/:*?"<>|]+/g, ' ');
      a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 4000);
      toast(bed ? 'Видео со звуком сохранено' : 'Видео сохранено (без звука — превью не нашлось). Музыку добавьте в сторис');
    } catch (e) {
      toast(humanError(e, 'Не получилось записать видео'), 'error');
    } finally {
      closeBed(bed);
      if (bed && wasPlaying) toggle();
      setRec(null);
    }
  };
  // Phones: straight into the share sheet (Instagram, Telegram…) when the browser can send files.
  const canShare = !!(navigator.canShare && window.File && navigator.canShare({ files: [new File([''], 'x.png', { type: 'image/png' })] }));
  const share = async () => {
    try {
      const file = new File([await blob()], `Blink - ${track.title}.png`.replace(/[\\/:*?"<>|]+/g, ' '), { type: 'image/png' });
      await navigator.share({ files: [file], title: track.title });
    } catch (e) {
      if (!e || e.name !== 'AbortError') toast('Не получилось поделиться, сохраните картинку', 'error');
    }
  };
  const copy = async () => {
    try {
      await navigator.clipboard.write([new window.ClipboardItem({ 'image/png': await blob() })]);
      toast('Картинка скопирована, вставьте её в сторис');
    } catch {
      toast('Не получилось скопировать, сохраните картинку', 'error');
    }
  };

  return (
    <div className="story">
      <div className="story-preview">
        <canvas ref={canvas} />
      </div>
      <div className="story-side">
        <h2>Карточка для сторис</h2>
        <p>Выберите до четырёх строк. Картинка или видео 1080×1920, как раз под сторис. В видео строки загораются по словам и играет отрывок трека.</p>
        <div className="story-lines">
          {story.lines.length === 0 && <div className="fine">У этого трека нет текста, на карточке будет название.</div>}
          {story.lines.map((l, i) => (
            <button key={i} className={'story-line' + (picked.includes(i) ? ' on' : '')} onClick={() => flip(i)}>
              {l}
            </button>
          ))}
        </div>
        <div className="story-act">
          {canShare && (
            <button className="btn primary" onClick={share} disabled={rec !== null}>
              <Icon name="share" size={17} /> Поделиться
            </button>
          )}
          <button className={'btn ' + (canShare ? 'ghost' : 'primary')} onClick={save} disabled={rec !== null}>
            <Icon name="down" size={17} /> Сохранить
          </button>
          <button className="btn ghost" onClick={copy} disabled={rec !== null}>
            Скопировать
          </button>
          <button className="btn ghost story-rec" onClick={video} disabled={rec !== null}>
            {rec !== null ? (
              <>
                <span className="rec-dot" /> Записываю {Math.round(rec * 100)}%
              </>
            ) : (
              <>
                <Icon name="clip" size={17} /> Видео-сторис
              </>
            )}
          </button>
        </div>
      </div>
    </div>
  );
}
