import { useEffect, useRef } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import Icon from './Icon.jsx';
import FlashObject from './FlashObject.jsx';
import { ArtistLinks } from './common.jsx';
import DotProgress from './DotProgress.jsx';
import { PlayButton } from './Capsule.jsx';
import { store, useStore, toast, toggleLike } from '../lib/store.js';
import { startWave, next, prev, stopPlayback } from '../lib/player.js';
import { tasteArtists, waveBatch, notThis, WAVE_MODES } from '../lib/wave.js';
import * as api from '../lib/api.js';

const ease = [0.23, 1, 0.32, 1];

// «Главная» is one calm screen with one object: «Вспышка». It has four states:
//   rest     nothing plays: only the object, a word and a line, tap the object to light «Вспышка»
//   music    plain music plays: the same rest screen plus a small pill «Играет ваша музыка ×», no player
//   igniting «Вспышка» is being put together (the object warms up)
//   flash    «Вспышка» plays: the object, the track and the controls (the only player on this page)
// The cross on the pill stops whatever plays and returns the page to rest.
export default function FlashHome({ shown = true }) {
  const wave = useStore((s) => s.wave);
  const track = useStore((s) => s.track);
  const playing = useStore((s) => s.status === 'playing' || s.status === 'buffering');
  const loading = useStore((s) => s.waveLoading);
  const liked = useStore((s) => !!s.track && s.likes.some((t) => t.id === s.track.id));
  const mode = useStore((s) => s.settings.waveMode || 'mix');
  const state = wave && track ? 'flash' : loading ? 'igniting' : track ? 'music' : 'rest';
  const on = !!track && playing;
  const swipe = useRef(null);

  // The top bar and the tab bar get out of the way of this page (see mobile.css and styles.css).
  useEffect(() => {
    if (!shown) return;
    document.documentElement.classList.add('phone-flash');
    return () => document.documentElement.classList.remove('phone-flash');
  }, [shown]);

  const igniteFlash = () => {
    store.set({ settings: { ...store.get().settings, flashAfter: true } });
    startWave();
  };
  const openStage = () => store.set({ stage: true, stageTab: 'cover' });
  const setMode = async (m) => {
    if (m === mode) return;
    store.set({ settings: { ...store.get().settings, waveMode: m } });
    const more = await waveBatch(10).catch(() => []);
    if (!more.length) return toast('В этом режиме пока мало музыки, оставил прежнюю очередь');
    const s = store.get();
    store.set({ queue: [...s.queue.slice(0, s.index + 1), ...more] });
  };
  const skipThis = () => {
    notThis(track);
    next();
    toast('Не моё, понял: такое больше не ставлю');
  };

  // One gesture area on the object: a tap lights «Вспышка» (rest, music) or opens the stage (flash);
  // while «Вспышка» plays a swipe sideways is next / previous.
  const touch = {
    onPointerDown: (e) => (swipe.current = { x: e.clientX, y: e.clientY }),
    onPointerUp: (e) => {
      const from = swipe.current;
      swipe.current = null;
      if (!from) return;
      const dx = e.clientX - from.x;
      const dy = e.clientY - from.y;
      if (state === 'flash' && Math.abs(dx) > 48 && Math.abs(dx) > Math.abs(dy)) return dx < 0 ? next() : prev();
      if (Math.abs(dx) > 8 || Math.abs(dy) > 8) return;
      if (state === 'flash') openStage();
      else if (state !== 'igniting') igniteFlash();
    },
    onPointerCancel: () => (swipe.current = null),
  };

  const names = tasteArtists()
    .slice(0, 3)
    .map((a) => a.name.split(/,|&| feat/i)[0].trim());
  const hint = names.length ? `${names.join(', ')} и похожее на них` : 'Слушайте и ставьте лайки, и поток подстроится под вас';
  const modeLabel = (WAVE_MODES.find(([k]) => k === mode) || [])[1] || 'Микс';
  const photo = track ? api.art(track.artwork || '', 1000) : '';

  return (
    <div className={`hm hm-${state}` + (on ? ' on' : '')}>
      <AnimatePresence>
        {(state === 'music' || state === 'flash') && (
          <motion.div key="pill" className="hm-pill" initial={{ opacity: 0, y: -10, scale: 0.97 }} animate={{ opacity: 1, y: 0, scale: 1 }} exit={{ opacity: 0, y: -10, scale: 0.97, transition: { duration: 0.18 } }} transition={{ duration: 0.3, ease }}>
            <button className="hm-pill-main" onClick={openStage} aria-label="Открыть плеер">
              <span className={'hm-pill-dot' + (state === 'flash' ? ' big' : '') + (on ? ' on' : '')} aria-hidden="true">
                <i />
              </span>
              <span className="hm-pill-text">
                <b>{state === 'music' ? 'Играет ваша музыка' : 'Играет Вспышка'}</b>
                <em>{state === 'music' ? `${track.title} · ${track.artist}` : modeLabel}</em>
              </span>
            </button>
            <button className="hm-pill-x" onClick={stopPlayback} title="Остановить" aria-label="Остановить и закрыть">
              <Icon name="close" size={16} stroke={2.2} />
            </button>
          </motion.div>
        )}
      </AnimatePresence>

      <div className="hm-body">
        <div
          className="hm-obj"
          role={state === 'flash' ? undefined : 'button'}
          aria-label={state === 'flash' ? undefined : 'Включить Вспышку'}
          tabIndex={state === 'rest' || state === 'music' ? 0 : -1}
          onKeyDown={(e) => (e.key === 'Enter' || e.key === ' ') && (state === 'rest' || state === 'music') && (e.preventDefault(), igniteFlash())}
          {...touch}
        >
          <FlashObject state={state} track={track} photo={photo} />
        </div>

        {state === 'flash' && track ? (
          <div className="hm-play">
            <AnimatePresence mode="wait" initial={false}>
              <motion.div key={track.id} className="hm-meta" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -8 }} transition={{ duration: 0.28, ease }}>
                <h1 className="hm-title">{track.title}</h1>
                <div className="hm-artist">
                  <ArtistLinks track={track} />
                </div>
              </motion.div>
            </AnimatePresence>
            <DotProgress />
            <div className="hm-ctl">
              <button className="hm-b" title="Не моё: больше такое не ставить" onClick={skipThis}>
                <Icon name="thumbDown" size={22} />
              </button>
              <button className="hm-b" title="Назад" onClick={() => prev()}>
                <Icon name="prev" size={24} />
              </button>
              <PlayButton big />
              <button className="hm-b" title="Дальше" onClick={() => next()}>
                <Icon name="next" size={24} />
              </button>
              <button className={'hm-b' + (liked ? ' on' : '')} title="Любимое" onClick={() => toggleLike(track)}>
                <motion.span key={liked ? 'y' : 'n'} style={{ display: 'grid' }} initial={liked ? { scale: 0.6 } : false} animate={{ scale: [0.6, 1.3, 1] }} transition={{ duration: 0.35, ease }}>
                  <Icon name={liked ? 'heartFill' : 'heart'} size={22} />
                </motion.span>
              </button>
            </div>
            <div className="hm-modes" role="tablist" aria-label="Режим Вспышки">
              {WAVE_MODES.map(([k, label]) => (
                <button key={k} role="tab" aria-selected={mode === k} className={mode === k ? 'on' : ''} onClick={() => setMode(k)}>
                  <span>{label}</span>
                  {mode === k && <motion.i layoutId="hm-mode" className="hm-mode-dot" transition={{ type: 'spring', duration: 0.4, bounce: 0.2 }} />}
                </button>
              ))}
            </div>
          </div>
        ) : (
          <div className="hm-text">
            <div className="hm-eyebrow">Ваш личный поток</div>
            <h1 className="hm-hero">
              Вспышка<span className="dot" />
            </h1>
            <p className="hm-hint">{state === 'igniting' ? 'Подбираю музыку…' : hint}</p>
          </div>
        )}
      </div>
    </div>
  );
}
