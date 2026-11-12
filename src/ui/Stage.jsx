import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import Icon from './Icon.jsx';
import { Cover, TrackRow, ArtistLinks, openMenu } from './common.jsx';
import { Progress, Transport, Volume, PlayButton } from './Capsule.jsx';
import { store, useStore, nowTime, go, toggleLike, toast } from '../lib/store.js';
import { seek, setVideoMode, jumpTo, stopBackdrop, next, prev, toggleShuffle, cycleRepeat } from '../lib/player.js';
import { notThis } from '../lib/wave.js';
import * as api from '../lib/api.js';
import { fetchTtml } from '../lib/catalog.js';
import { openStory } from './StoryCard.jsx';
import { shareTrack } from './share.js';
import { artistPhoto } from '../lib/photos.js';
import { Comments } from './Profile.jsx';
import { proxied, scaleSc, coverFallback } from '../lib/img.js';
import Shot from './Shot.jsx';
import { parseTtml } from '../lib/ttml.js';
import { translateLines } from '../lib/translate.js';

const lyricCache = new Map();
// Found lyrics also stay on disk (the last 150 tracks), so a replay opens them at once,
// even offline or while the lyrics service is down.
const LYR_DISK = 'blink-lyrics';
function diskLyrics() {
  try {
    return JSON.parse(localStorage.getItem(LYR_DISK)) || {};
  } catch {
    return {};
  }
}
function keepLyrics(id, data) {
  if (!data) return;
  const all = diskLyrics();
  delete all[id];
  all[id] = data;
  const ids = Object.keys(all);
  for (const old of ids.slice(0, Math.max(0, ids.length - 150))) delete all[old];
  try {
    localStorage.setItem(LYR_DISK, JSON.stringify(all));
  } catch {
    /* storage full */
  }
}

// Lyric lines already known on this device (for a story made from the «⋯» menu).
export function knownLines(id) {
  const d = lyricCache.get(id) || diskLyrics()[id];
  if (!d) return [];
  return (d.synced ? d.synced.map((l) => l.text) : d.plain || []).filter(Boolean);
}

function useLyrics(track) {
  const [state, setState] = useState({ loading: true });
  const [nonce, setNonce] = useState(0);
  useEffect(() => {
    if (!track) return;
    if (lyricCache.has(track.id)) return setState({ data: lyricCache.get(track.id) });
    const saved = diskLyrics()[track.id];
    if (saved) {
      lyricCache.set(track.id, saved);
      return setState({ data: saved });
    }
    let alive = true;
    setState({ loading: true });
    const load =
      track.source === 'blink'
        ? fetchTtml(track.lic).then((xml) => {
            const lines = xml && parseTtml(xml);
            return lines ? { synced: lines } : api.lyrics(track);
          })
        : api.lyrics(track);
    load
      .then((data) => {
        lyricCache.set(track.id, data);
        keepLyrics(track.id, data);
        if (alive) setState({ data });
      })
      .catch(() => alive && setState({ failed: true }));
    return () => {
      alive = false;
    };
  }, [track && track.id, nonce]);
  return { ...state, retry: () => setNonce((n) => n + 1) };
}

function buildLines(synced) {
  const out = [];
  if (synced.length && synced[0].t > 4) out.push({ t: 0, gap: true });
  synced.forEach((l, i) => {
    const nextT = synced[i + 1] ? synced[i + 1].t : l.t + 6;
    if (!l.text) {
      if (nextT - l.t > 3) out.push({ t: l.t, gap: true });
      return;
    }
    const end = l.end && l.end < nextT ? l.end : nextT;
    out.push({ ...l, end });
    // A long instrumental break inside a song gets its own breathing dots.
    if (synced[i + 1] && nextT - end > 4) out.push({ t: end, gap: true });
  });
  return out;
}

// Split a line into the words that light up one by one. Word-timed TTML keeps its own timings;
// a plain synced line spreads its words over the whole line, up to the next one, longer words taking longer.
// Only a line followed by a long pause is capped, so the sweep doesn't crawl through the break.
function lineWords(l) {
  const text = l.text;
  const timed = l.words ? l.words.filter((w) => w.from !== undefined) : [];
  if (timed.length) {
    const out = [];
    let at = 0;
    timed.forEach((w, k) => {
      if (w.from > at) out.push({ s: text.slice(at, w.from) });
      const next = timed[k + 1];
      out.push({ s: text.slice(w.from, w.to), t: w.t, end: w.end || (next ? next.t : l.end) });
      at = w.to;
    });
    if (at < text.length) out.push({ s: text.slice(at) });
    return out;
  }
  const parts = text.split(/(\s+)/).filter(Boolean);
  const weight = parts.reduce((n, s) => n + (/^\s+$/.test(s) ? 0 : s.length + 1), 0) || 1;
  const span = Math.max(0.6, Math.min(l.end - l.t - 0.12, Math.max(3, text.length * 0.25)));
  let t = l.t;
  return parts.map((s) => {
    if (/^\s+$/.test(s)) return { s };
    const d = (span * (s.length + 1)) / weight;
    const w = { s, t, end: t + d };
    t += d;
    return w;
  });
}

function Synced({ lines, tr }) {
  const box = useRef(null);
  const trackRef = useRef(null);
  const refs = useRef([]);
  const wordRefs = useRef([]);
  const [active, setActive] = useState(-1);
  const activeRef = useRef(-1);
  // Seconds left before the next line, shown as 3·2·1 at the end of an intro or a break.
  const [count, setCount] = useState(0);
  const countRef = useRef(0);
  const words = useMemo(() => lines.map((l) => (l.gap ? null : lineWords(l))), [lines]);

  useEffect(() => {
    let raf;
    const loop = () => {
      const t = nowTime();
      let i = -1;
      for (let k = 0; k < lines.length; k++) {
        if (lines[k].t <= t) i = k;
        else break;
      }
      if (i !== activeRef.current) {
        activeRef.current = i;
        setActive(i);
      }
      const l = lines[i];
      let c = 0;
      if (l && l.gap && lines[i + 1]) {
        const left = lines[i + 1].t - t;
        if (left > 0 && left <= 3) c = Math.ceil(left);
      }
      if (c !== countRef.current) {
        countRef.current = c;
        setCount(c);
      }
      const ws = words[i];
      const els = wordRefs.current[i];
      if (ws && els) {
        // Each word fills on its own, so a line that wraps onto two rows lights up row by row.
        ws.forEach((w, k) => {
          const el = els[k];
          if (!el || w.t === undefined) return;
          const p = Math.max(0, Math.min(1, (t - w.t) / Math.max(0.05, w.end - w.t)));
          const v = (p * 140 - 20).toFixed(1) + '%';
          if (el._p === v) return;
          el._p = v;
          el.style.setProperty('--p', v);
          el.classList.toggle('lit', p > 0);
        });
      }
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(raf);
  }, [lines, words]);

  useLayoutEffect(() => {
    const el = refs.current[Math.max(0, active)];
    if (!el || !box.current || !trackRef.current) return;
    const y = box.current.clientHeight * 0.36 - el.offsetTop - el.offsetHeight / 2;
    trackRef.current.style.transform = `translateY(${y}px)`;
  }, [active, lines, tr]);

  useEffect(() => {
    const onResize = () => {
      const el = refs.current[Math.max(0, activeRef.current)];
      if (el && box.current && trackRef.current) trackRef.current.style.transform = `translateY(${box.current.clientHeight * 0.36 - el.offsetTop - el.offsetHeight / 2}px)`;
    };
    window.addEventListener('resize', onResize);
    return () => window.removeEventListener('resize', onResize);
  }, []);

  return (
    <div className="lyrics" ref={box}>
      <div className="track" ref={trackRef}>
        {lines.map((l, i) =>
          l.gap ? (
            <div key={i} ref={(el) => (refs.current[i] = el)} className={'gap' + (i === active ? ' on' : '') + (i === active && count ? ' counting' : '')}>
              <span className="dots">• • •</span>
              {i === active && count > 0 && (
                <span key={count} className="cd">
                  {count}
                </span>
              )}
            </div>
          ) : (
            <button
              key={i}
              ref={(el) => (refs.current[i] = el)}
              className={'ln' + (i === active ? ' on' : i < active ? ' past' : '') + (Math.abs(i - active) > 3 ? ' far' : '')}
              onClick={() => seek(Math.max(0, l.t + 0.05))}
            >
              {words[i].map((w, k) =>
                w.t === undefined ? (
                  w.s
                ) : (
                  <span key={k} className="w" ref={(el) => ((wordRefs.current[i] ||= [])[k] = el)}>
                    {w.s}
                  </span>
                )
              )}
              {tr && tr.get(l.text.trim()) && tr.get(l.text.trim()).toLowerCase() !== l.text.trim().toLowerCase() && <span className="tr">{tr.get(l.text.trim())}</span>}
            </button>
          )
        )}
      </div>
    </div>
  );
}

// Translation under the lyrics, on demand: { state: 'off' | 'loading' | 'on' | 'native' | 'error', map }.
function useTranslation(track, data) {
  const want = useStore((s) => !!s.settings.lyricsTr);
  const [tr, setTr] = useState({ state: 'off', map: null });
  useEffect(() => {
    if (!want || !data || data.instrumental) return setTr({ state: 'off', map: null });
    const texts = data.synced ? data.synced.map((l) => l.text) : data.plain || [];
    let alive = true;
    setTr({ state: 'loading', map: null });
    translateLines(track.id, texts)
      .then((r) => alive && setTr(r.lang === 'ru' ? { state: 'native', map: null } : { state: 'on', map: r.lines }))
      .catch(() => alive && setTr({ state: 'error', map: null }));
    return () => {
      alive = false;
    };
  }, [want, data, track.id]);
  const toggle = () => store.set({ settings: { ...store.get().settings, lyricsTr: !want } });
  return { ...tr, want, toggle };
}

// Lyrics that are mostly Cyrillic need no translation.
function isRussian(data) {
  const text = (data.synced ? data.synced.map((l) => l.text) : data.plain || []).join(' ');
  const cyr = (text.match(/[а-яё]/gi) || []).length;
  const lat = (text.match(/[a-z]/gi) || []).length;
  return cyr > lat;
}

function TrButton({ tr, off }) {
  const label = tr.state === 'loading' ? 'Перевожу…' : 'Перевод';
  const disabled = off || tr.state === 'native' || tr.state === 'error';
  return (
    <button className={tr.want && !disabled ? 'on' : ''} disabled={disabled} onClick={tr.toggle} title={disabled ? 'Перевод не нужен' : 'Перевод строк на русский под оригиналом'}>
      <Icon name="translate" size={15} /> {label}
    </button>
  );
}

// `lyr` lets the phone stage share the lyrics it already loaded (to know whether there are any).
function Lyrics({ track, lyr }) {
  const own = useLyrics(lyr ? null : track);
  const { data, loading, failed, retry } = lyr || own;
  const native = useMemo(() => !!data && isRussian(data), [data]);
  const lines = useMemo(() => (data && data.synced ? buildLines(data.synced) : null), [data]);
  const tr = useTranslation(track, data);
  const trMap = tr.state === 'on' ? tr.map : null;

  if (loading)
    return (
      <div className="lyr-empty">
        {[72, 54, 64].map((w, i) => (
          <div key={i} className="sk" style={{ height: 36, width: w + '%', marginBottom: 18, opacity: 1 - i * 0.25 }} />
        ))}
      </div>
    );
  if (failed)
    return (
      <div className="lyr-empty">
        <div className="big">Тексты сейчас недоступны</div>
        <div>Сервис с текстами не отвечает. Обычно это ненадолго.</div>
        <button className="btn ghost" style={{ marginTop: 18 }} onClick={retry}>
          Повторить
        </button>
      </div>
    );
  if (!data)
    return (
      <div className="lyr-empty">
        <div className="big">Текста для этого трека пока нет</div>
        <div>Просто слушайте. Тексты берутся из открытой базы LRCLIB, она пополняется каждый день.</div>
      </div>
    );
  if (data.instrumental)
    return (
      <div className="lyr-empty">
        <div className="big">Инструментал</div>
        <div>В этом треке нет слов.</div>
      </div>
    );
  if (data.plain)
    return (
      <div style={{ position: 'relative', height: '100%' }}>
        <div className="plain">
          {data.plain.map((l, i) => (
            <p key={i}>
              {l || ' '}
              {trMap && l && trMap.get(l.trim()) && <span className="tr">{trMap.get(l.trim())}</span>}
            </p>
          ))}
        </div>
        <div className="lyr-tools">
          <TrButton tr={tr} off={native} />
          <button onClick={() => openStory(track, data.plain.filter(Boolean))} title="Карточка со строчкой для сторис">
            <Icon name="share" size={15} />
          </button>
        </div>
      </div>
    );
  return (
    <div style={{ position: 'relative', height: '100%' }}>
      <Synced lines={lines} tr={trMap} />
      <div className="lyr-tools">
        <TrButton tr={tr} off={native} />
        <button onClick={() => openStory(track, data.synced.map((l) => l.text).filter(Boolean))} title="Карточка со строчкой для сторис">
          <Icon name="share" size={15} />
        </button>
      </div>
    </div>
  );
}

function QueuePane() {
  const queue = useStore((s) => s.queue);
  const index = useStore((s) => s.index);
  const ref = useRef(null);
  useEffect(() => {
    const el = ref.current && ref.current.querySelector('.trow.current');
    if (el) el.scrollIntoView({ block: 'center' });
  }, []);
  return (
    <div className="queue-pane" ref={ref}>
      <div className="label" style={{ margin: '0 10px 8px' }}>
        Сейчас и дальше
      </div>
      <div className="tracks">
        {queue.map((t, i) =>
          i < index - 3 ? null : (
            <div key={t.id + ':' + i} style={i < index ? { opacity: 0.45 } : null}>
              <TrackRow track={t} index={i} showAlbum={false} onPlay={() => jumpTo(i)} queueIndex={i} />
            </div>
          )
        )}
      </div>
      <div className="fine" style={{ margin: '24px 10px 0' }}>
        Когда очередь закончится, Blink продолжит похожими треками этих артистов.
      </div>
    </div>
  );
}

// No mouse, touch or keys for a few seconds while music plays: the controls fade away and the
// lyrics, cover and clip take the screen. Any movement brings everything back.
export function useIdle(active, ms = 2500) {
  const [idle, setIdle] = useState(false);
  useEffect(() => {
    if (!active) return setIdle(false);
    let t;
    const wake = () => {
      setIdle(false);
      clearTimeout(t);
      t = setTimeout(() => setIdle(true), ms);
    };
    const events = ['mousemove', 'mousedown', 'keydown', 'touchstart', 'touchmove', 'touchend', 'pointerdown', 'wheel'];
    events.forEach((e) => window.addEventListener(e, wake, { passive: true }));
    wake();
    return () => {
      clearTimeout(t);
      events.forEach((e) => window.removeEventListener(e, wake));
    };
  }, [active, ms]);
  return idle;
}

// The artist's photo for the round thumb on the phone stage; the cover until it loads.
function useArtistPhoto(track) {
  const [url, setUrl] = useState(null);
  const key = track && track.id;
  useEffect(() => {
    setUrl(null);
    if (!track) return;
    let alive = true;
    artistPhoto(track).then((u) => alive && setUrl(u));
    return () => {
      alive = false;
    };
  }, [key]);
  return url;
}

// Phones only (the same breakpoint as mobile.css).
const narrowQuery = typeof window !== 'undefined' && window.matchMedia ? window.matchMedia('(max-width: 760px)') : null;
function useNarrow() {
  const [narrow, setNarrow] = useState(() => !!(narrowQuery && narrowQuery.matches));
  useEffect(() => {
    if (!narrowQuery) return;
    const on = () => setNarrow(narrowQuery.matches);
    narrowQuery.addEventListener('change', on);
    return () => narrowQuery.removeEventListener('change', on);
  }, []);
  return narrow;
}

export default function Stage() {
  const track = useStore((s) => s.track);
  const tab = useStore((s) => s.stageTab);
  const status = useStore((s) => s.status);
  const liked = useStore((s) => !!s.track && s.likes.some((t) => t.id === s.track.id));
  const wave = useStore((s) => s.wave);
  const flow = useStore((s) => s.flow);
  const idle = useIdle(status === 'playing');
  const swipeFrom = useRef(null);
  const narrow = useNarrow();
  // The stage looks the lyrics up quietly (cached on disk), so «Текст» knows whether there are
  // any; they are only drawn once the listener asks for them.
  const lyr = useLyrics(track);
  const hasLyrics = !!(lyr.data && !lyr.data.instrumental && (lyr.data.synced || lyr.data.plain));
  const photo = useArtistPhoto(narrow ? track : null);
  const shuffle = useStore((s) => s.shuffle);
  const repeat = useStore((s) => s.repeat);
  const [full, setFull] = useState(false);
  const queueFrom = useStore((s) => s.queueFrom);
  const [origin] = useState(() => {
    const el = document.querySelector('.capsule .cv-btn');
    if (!el) return '50% 100%';
    const r = el.getBoundingClientRect();
    return `${r.left + r.width / 2}px ${r.top + r.height / 2}px`;
  });

  // YouTube clips are gone from the stage: it always plays audio only.
  useEffect(() => {
    setVideoMode('audio');
    stopBackdrop(true);
  }, []);
  // The stage opens on the cover; the lyrics come on with «Текст», and only when there are some.
  useEffect(() => {
    if (['lyrics', 'clip'].includes(store.get().stageTab) || (narrow && store.get().stageTab === 'comments')) store.set({ stageTab: 'cover' });
  }, []);
  useEffect(() => {
    if (tab === 'lyrics' && !lyr.loading && !hasLyrics) store.set({ stageTab: 'cover' });
  }, [tab, lyr.loading, hasLyrics]);
  // In «Вспышка» what plays next stays a surprise: no queue.
  useEffect(() => {
    if (wave && tab === 'queue') store.set({ stageTab: narrow ? 'cover' : 'lyrics' });
  }, [wave, tab, narrow]);

  const brand = useStore((s) => s.settings.brandMark !== false);

  if (!track) return null;
  const setTab = (t) => store.set({ stageTab: t });
  // Phones: a swipe down closes the stage, except over the parts that scroll or seek.
  const swipe = {
    onTouchStart: (e) => {
      const t = e.touches[0];
      swipeFrom.current = e.target.closest('.lyrics, .plain, .queue-pane, .stage-scrub, .comments') ? null : { x: t.clientX, y: t.clientY };
    },
    onTouchEnd: (e) => {
      const from = swipeFrom.current;
      const t = e.changedTouches[0];
      if (from && t.clientY - from.y > 90 && Math.abs(t.clientX - from.x) < 70) store.set({ stage: false });
    },
  };
  const tabs = [
    ['cover', 'Обложка', 'disc'],
    ['lyrics', 'Текст', 'lyrics'],
    ...(wave ? [] : [['queue', 'Очередь', 'queue']]),
    ...(track && track.lic ? [['comments', 'Комментарии', 'chat']] : []),
  ];

  // Phones: one column. The header says where the music comes from; the middle is either the lyrics
  // on a glass card over the dimmed cover, or the cover itself across the whole screen; under it the
  // track, the progress, the controls and a row of repeat / text / shuffle.
  // Phones: one column. The header says where the music comes from; the middle is the square cover,
  // or the lyrics on a glass card when «текст» is on (expanded, the lyrics take the whole screen
  // with a small track pill at the bottom); under it the track, the progress, the controls and a
  // row of repeat / text / shuffle.
  if (narrow) {
    const scaleArt = (u, s) => !u ? '' : /\/\d+x\d+bb\.jpg$/.test(u) ? u.replace(/\/\d+x\d+bb\.jpg$/, `/${s}x${s}bb.jpg`) : /\/\d+x\d+$/.test(u) ? u.replace(/\/\d+x\d+$/, `/${s}x${s}`) : scaleSc(u, s);
    const cover = scaleArt(track.artwork || '', 1000);
    const textOn = tab === 'lyrics' && hasLyrics;
    const big = full && textOn;
    const from = wave ? 'Вспышка' : queueFrom || (flow ? 'Поток' : 'Сейчас играет');
    const pick = (t) => {
      setFull(false);
      setTab(tab === t ? 'cover' : t);
    };
    return (
      <motion.div
        className={'stage pstage' + (big ? ' full' : '') + (idle ? ' idle' : '')}
        initial={{ opacity: 0, y: 48 }}
        animate={{ opacity: 1, y: 0 }}
        exit={{ opacity: 0, y: 48, transition: { duration: 0.25, ease: [0.4, 0, 1, 1] } }}
        transition={{ duration: 0.38, ease: [0.23, 1, 0.32, 1] }}
        {...swipe}
      >
        <div className="ps-bg" aria-hidden="true">
          <AnimatePresence initial={false}>
            <motion.img key={track.id} src={proxied(cover)} {...coverFallback(cover)} alt="" draggable={false} decoding="async" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.9, ease: [0.23, 1, 0.32, 1] }} />
          </AnimatePresence>
        </div>
        <div className="ps-shade" aria-hidden="true" />
        <Shot track={track} stage idle={idle} />

        <div className="ps-top">
          <button className="icon-btn" title="Свернуть" onClick={() => store.set({ stage: false })}>
            <Icon name="down" size={24} />
          </button>
          <span className="ps-from">
            {brand && (
              <span className="ps-brand" aria-hidden="true">
                blink<i />
              </span>
            )}
            {from}
          </span>
          <div className="ps-top-r">
            {track.lic && (
              <button className={'icon-btn' + (tab === 'comments' ? ' on' : '')} title="Комментарии" onClick={() => pick('comments')}>
                <Icon name="chat" size={20} />
              </button>
            )}
            {!wave && (
              <button className={'icon-btn' + (tab === 'queue' ? ' on' : '')} title="Очередь" onClick={() => pick('queue')}>
                <Icon name="queue" size={22} />
              </button>
            )}
          </div>
        </div>

        <div className="ps-main">
          {big ? (
            <div className="ps-lyr-full">
              <button className="icon-btn ps-expand" title="Свернуть текст" onClick={() => setFull(false)}>
                <Icon name="min" size={18} />
              </button>
              <Lyrics track={track} lyr={lyr} />
            </div>
          ) : tab === 'queue' || tab === 'comments' || textOn ? (
            <div className="ps-card">
              {textOn && (
                <button className="icon-btn ps-expand" title="Весь текст" onClick={() => setFull(true)}>
                  <Icon name="max" size={18} />
                </button>
              )}
              <AnimatePresence mode="wait" initial={false}>
                <motion.div key={tab + track.id} className="ps-card-in" initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -10 }} transition={{ duration: 0.25, ease: [0.23, 1, 0.32, 1] }}>
                  {tab === 'queue' ? <QueuePane /> : tab === 'comments' && track.lic ? <Comments trackId={track.lic} /> : <Lyrics track={track} lyr={lyr} />}
                </motion.div>
              </AnimatePresence>
            </div>
          ) : (
            <div className="ps-art">
              <AnimatePresence mode="popLayout" initial={false}>
                <motion.img key={track.id} src={proxied(cover)} {...coverFallback(cover)} alt="" draggable={false} decoding="async" initial={{ opacity: 0, scale: 0.96 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.4, ease: [0.23, 1, 0.32, 1] }} />
              </AnimatePresence>
            </div>
          )}
        </div>

        {big ? (
          <div className="ps-pill" role="button" tabIndex={0} onClick={(e) => !e.target.closest('button') && setFull(false)}>
            <img src={proxied(scaleSc(track.artwork, 100))} {...coverFallback(scaleSc(track.artwork, 100))} alt="" draggable={false} />
            <div className="ps-name">
              <div className="ps-title">{track.title}</div>
              <div className="ps-artist">{track.artist}</div>
            </div>
            <PlayButton />
          </div>
        ) : (
          <>
            <div className="ps-meta">
              <button className="ps-thumb" onClick={() => track.artistId && (store.set({ stage: false }), go('artist', { id: track.artistId }))} title={track.artist}>
                <img src={proxied(photo || scaleSc(track.artwork, 100))} {...coverFallback(photo || scaleSc(track.artwork, 100))} alt="" draggable={false} decoding="async" />
              </button>
              <div className="ps-name">
                <div className="ps-title">{track.title}</div>
                <div className="ps-artist">
                  <ArtistLinks track={track} />
                </div>
              </div>
              <button className="icon-btn" title="Поделиться ссылкой" onClick={() => shareTrack(track)}>
                <Icon name="share" size={20} />
              </button>
              <button className="icon-btn" title="Ещё" onClick={(e) => openMenu(e, track)}>
                <Icon name="more" size={20} />
              </button>
            </div>

            <div className="ps-scrub">
              <Progress showTimes />
            </div>

            <div className="ps-ctl">
              {wave || flow ? (
                <button className="icon-btn" title="Не моё: больше такое не ставить" onClick={() => { notThis(track); next(); toast('Не моё, понял: такое больше не ставлю'); }}>
                  <Icon name="thumbDown" size={22} />
                </button>
              ) : (
                <span className="ps-gap" />
              )}
              <button className="icon-btn" title="Назад" onClick={() => prev()}>
                <Icon name="prev" size={28} />
              </button>
              <PlayButton big />
              <button className="icon-btn" title="Дальше" onClick={() => next()}>
                <Icon name="next" size={28} />
              </button>
              <button className={'icon-btn' + (liked ? ' on' : '')} title="Любимое" onClick={() => toggleLike(track)}>
                <Icon name={liked ? 'heartFill' : 'heart'} size={24} />
              </button>
            </div>

            <div className="ps-row">
              <button className={repeat !== 'off' ? 'on' : ''} title="Повтор" onClick={cycleRepeat}>
                <Icon name={repeat === 'one' ? 'repeatOne' : 'repeat'} size={20} />
              </button>
              <button className={textOn ? 'on' : ''} disabled={!hasLyrics} title={!hasLyrics ? (lyr.loading ? 'Ищу текст…' : 'У этого трека нет текста') : textOn ? 'Убрать текст' : 'Показать текст'} onClick={() => { setFull(false); setTab(textOn ? 'cover' : 'lyrics'); }}>
                <Icon name="lyrics" size={20} />
              </button>
              <button className={shuffle ? 'on' : ''} title="Перемешать" onClick={toggleShuffle}>
                <Icon name="shuffle" size={20} />
              </button>
            </div>
          </>
        )}
      </motion.div>
    );
  }

  return (
    <motion.div
      className={'stage' + (idle ? ' idle' : '')}
      initial={{ clipPath: `circle(0px at ${origin})` }}
      animate={{ clipPath: `circle(150% at ${origin})` }}
      exit={{ clipPath: `circle(0px at ${origin})`, transition: { duration: 0.4, ease: [0.77, 0, 0.175, 1] } }}
      transition={{ duration: 0.6, ease: [0.32, 0.72, 0, 1] }}
      {...swipe}
    >
      <Shot track={track} stage idle={idle} />
      <div className="ambient lit">
        <div className="blob a" />
        <div className="blob b" />
        <div className="blob c" />
        <div className="veil" />
      </div>
      <div className="stage-top">
        <button className="icon-btn close" title="Свернуть (Esc)" onClick={() => store.set({ stage: false })} style={{ WebkitAppRegion: 'no-drag' }}>
          <Icon name="down" size={22} />
        </button>
        <div className="seg">
          {tabs.map(([id, label, icon]) => (
            <button key={id} className={tab === id ? 'active' : ''} disabled={id === 'lyrics' && !hasLyrics} onClick={() => setTab(id)} title={id === 'lyrics' && !hasLyrics ? (lyr.loading ? 'Ищу текст…' : 'У этого трека нет текста') : label}>
              {tab === id && <motion.span layoutId="seg-pill" className="pill" transition={{ type: 'spring', duration: 0.4, bounce: 0.15 }} />}
              <Icon name={icon} size={17} />
              <span>{label}</span>
            </button>
          ))}
        </div>
      </div>

      <div className={'stage-body' + (tab === 'cover' ? ' cover-only' : '')}>
        {tab === 'cover' ? (
          <motion.div layoutId="stage-cover" className="stage-cover big" transition={{ type: 'spring', duration: 0.6, bounce: 0.12 }}>
            <AnimatePresence mode="popLayout" initial={false}>
              <motion.div key={track.id} style={{ width: '100%', height: '100%' }} initial={{ opacity: 0, scale: 1.04 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.5, ease: [0.23, 1, 0.32, 1] }}>
                <Cover src={track.artwork} size={1200} />
              </motion.div>
            </AnimatePresence>
            <Shot track={track} />
          </motion.div>
        ) : (
          <>
            <motion.div layoutId="stage-cover" className="stage-cover" transition={{ type: 'spring', duration: 0.6, bounce: 0.12 }}>
              <AnimatePresence mode="popLayout" initial={false}>
                <motion.div key={track.id} style={{ width: '100%', height: '100%' }} initial={{ opacity: 0, scale: 1.04 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.5, ease: [0.23, 1, 0.32, 1] }}>
                  <Cover src={track.artwork} size={1000} />
                </motion.div>
              </AnimatePresence>
              <Shot track={track} />
            </motion.div>
            <div style={{ height: '100%', minHeight: 0, position: 'relative' }}>
              <AnimatePresence mode="wait" initial={false}>
                <motion.div key={tab + track.id} style={{ height: '100%' }} initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -12 }} transition={{ duration: 0.25, ease: [0.23, 1, 0.32, 1] }}>
                  {tab === 'queue' ? <QueuePane /> : tab === 'comments' && track.lic ? <Comments trackId={track.lic} /> : <Lyrics track={track} lyr={lyr} />}
                </motion.div>
              </AnimatePresence>
            </div>
          </>
        )}
      </div>

      <div className="stage-foot">
        <Progress showTimes />
        <div style={{ minWidth: 0 }}>
          <div className="title">{track.title}</div>
          <div className="artist">
            <ArtistLinks track={track} />
            {track.album ? (
              <>
                {' · '}
                <button onClick={() => track.albumId && go('album', { id: track.albumId })}>{track.album}</button>
              </>
            ) : null}
          </div>
        </div>
        <div className="ctl">
          <Transport big />
        </div>
        <div className="right">
          {(wave || flow) && (
            <button className="fs-skip" title="Больше такое не ставить во «Вспышке»" onClick={() => { notThis(track); next(); toast('Не моё, понял: такое больше не ставлю'); }}>
              <Icon name="thumbDown" size={16} /> Не моё
            </button>
          )}
          <button className={'icon-btn' + (liked ? ' on' : '')} title="Любимое (L)" onClick={() => toggleLike(track)}>
            <Icon name={liked ? 'heartFill' : 'heart'} size={22} />
          </button>
          <Volume />
        </div>
      </div>
    </motion.div>
  );
}
