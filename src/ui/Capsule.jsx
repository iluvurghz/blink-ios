import { useEffect, useRef, useState } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import Icon from './Icon.jsx';
import { Cover, fmt, ArtistLinks } from './common.jsx';
import { store, useStore, useClock, clock, nowTime, go, toggleLike, toast } from '../lib/store.js';
import { toggle, next, prev, seek, setVolume, toggleMute, toggleShuffle, cycleRepeat } from '../lib/player.js';
import { notThis } from '../lib/wave.js';
import { shareTrack } from './share.js';

// Progress rail: painted per frame from the interpolated clock, no React renders.
export function Progress({ showTimes }) {
  const rail = useRef(null);
  const fill = useRef(null);
  const knob = useRef(null);
  const tip = useRef(null);
  const cur = useRef(null);
  const [drag, setDrag] = useState(false);
  const dragRef = useRef(null);
  const duration = useClock((c) => c.duration);

  useEffect(() => {
    let raf;
    // Touch the page only when what is shown changes (a tenth of a percent, or the clock's second).
    let lastP = -1;
    let lastT = '';
    const paint = () => {
      const d = clock.get().duration || 1;
      const t = dragRef.current !== null ? dragRef.current : nowTime();
      const p = Math.round(Math.max(0, Math.min(1, t / d)) * 1000) / 10;
      if (p !== lastP) {
        lastP = p;
        if (fill.current) fill.current.style.width = p + '%';
        if (knob.current) knob.current.style.left = p + '%';
      }
      const label = fmt(t);
      if (label !== lastT && cur.current) cur.current.textContent = lastT = label;
      raf = requestAnimationFrame(paint);
    };
    raf = requestAnimationFrame(paint);
    return () => cancelAnimationFrame(raf);
  }, []);

  const at = (e) => {
    const r = rail.current.getBoundingClientRect();
    return Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * (clock.get().duration || 0);
  };
  const move = (e) => {
    const t = at(e);
    if (tip.current) {
      const r = rail.current.getBoundingClientRect();
      tip.current.style.left = Math.max(0, Math.min(r.width, e.clientX - r.left)) + 'px';
      tip.current.textContent = fmt(t);
    }
    if (dragRef.current !== null) dragRef.current = t;
  };

  const bar = (
    <div
      className={'progress' + (drag ? ' drag' : '')}
      onPointerDown={(e) => {
        e.currentTarget.setPointerCapture(e.pointerId);
        dragRef.current = at(e);
        setDrag(true);
      }}
      onPointerMove={move}
      onPointerUp={(e) => {
        if (dragRef.current !== null) seek(at(e));
        dragRef.current = null;
        setDrag(false);
      }}
    >
      <div className="rail" ref={rail}>
        <div className="fill" ref={fill} />
        <div className="knob" ref={knob} />
      </div>
      <div className="tip" ref={tip} />
    </div>
  );
  if (!showTimes) return bar;
  return (
    <div className="stage-scrub">
      <span ref={cur}>0:00</span>
      {bar}
      <span>{fmt(duration)}</span>
    </div>
  );
}

export function Volume() {
  const volume = useStore((s) => s.volume);
  const muted = useStore((s) => s.muted);
  const rail = useRef(null);
  const set = (e) => {
    const r = rail.current.getBoundingClientRect();
    setVolume(((e.clientX - r.left) / r.width) * 100);
  };
  const v = muted ? 0 : volume;
  return (
    <div className="vol" onWheel={(e) => setVolume(volume + (e.deltaY < 0 ? 5 : -5))}>
      <button className="icon-btn" title={muted ? 'Включить звук' : 'Выключить звук'} onClick={toggleMute}>
        <Icon name={v === 0 ? 'mute' : 'volume'} size={20} />
      </button>
      <div
        className="slider"
        title={`Громкость ${v}%`}
        onPointerDown={(e) => {
          e.currentTarget.setPointerCapture(e.pointerId);
          set(e);
        }}
        onPointerMove={(e) => e.buttons && set(e)}
      >
        <div className="rail" ref={rail}>
          <div className="fill" style={{ width: v + '%' }} />
        </div>
      </div>
    </div>
  );
}

export function PlayButton({ big }) {
  const status = useStore((s) => s.status);
  const playing = status === 'playing' || status === 'buffering';
  const loading = status === 'loading' || status === 'buffering';
  return (
    <button className={'iris' + (big ? ' big' : '')} title={playing ? 'Пауза (пробел)' : 'Играть (пробел)'} onClick={toggle}>
      <span className={'ico' + (playing ? ' off' : '')}>
        <Icon name="play" size={big ? 30 : 22} />
      </span>
      <span className={'ico' + (playing ? '' : ' off')}>
        <Icon name="pause" size={big ? 30 : 22} />
      </span>
      {loading && <span className="spin" />}
    </button>
  );
}

export function Transport({ big }) {
  const shuffle = useStore((s) => s.shuffle);
  const repeat = useStore((s) => s.repeat);
  const size = big ? 24 : 20;
  return (
    <>
      <button className={'icon-btn' + (shuffle ? ' on' : '')} title="Перемешать" onClick={toggleShuffle}>
        <Icon name="shuffle" size={size - 2} />
      </button>
      <button className="icon-btn" title="Назад" onClick={prev}>
        <Icon name="prev" size={size} />
      </button>
      <PlayButton big={big} />
      <button className="icon-btn" title="Дальше" onClick={() => next()}>
        <Icon name="next" size={size} />
      </button>
      <button className={'icon-btn' + (repeat !== 'off' ? ' on' : '')} title="Повтор" onClick={cycleRepeat}>
        <Icon name={repeat === 'one' ? 'repeatOne' : 'repeat'} size={size - 2} />
      </button>
    </>
  );
}

export default function Capsule() {
  const track = useStore((s) => s.track);
  const stage = useStore((s) => s.stage);
  const liked = useStore((s) => !!s.track && s.likes.some((t) => t.id === s.track.id));
  const duration = useClock((c) => c.duration);
  const wave = useStore((s) => s.wave);
  const flow = useStore((s) => s.flow);
  const remoteFrom = useStore((s) => s.remoteFrom);
  // On the home page «Вспышка» has its own big player, so the capsule steps aside.
  const flashHome = useStore((s) => s.wave && s.view.name === 'home');
  const together = useStore((s) => s.together);
  // The stage always opens on the lyrics, unless a button asks for another tab.
  const openStage = (tab) => store.set({ stage: true, stageTab: tab || 'lyrics' });
  // Phones: the whole bar opens the stage, a sideways swipe skips (buttons keep their own taps).
  const swipe = useRef(null);
  const phone = {
    onPointerDown: (e) => (swipe.current = e.target.closest('button, a') ? null : { x: e.clientX, y: e.clientY }),
    onPointerUp: (e) => {
      const from = swipe.current;
      swipe.current = null;
      if (!from || !window.matchMedia('(max-width: 760px)').matches) return;
      const dx = e.clientX - from.x;
      if (Math.abs(dx) > 40 && Math.abs(dx) > Math.abs(e.clientY - from.y)) return dx < 0 ? next() : prev();
      if (Math.abs(dx) < 8 && Math.abs(e.clientY - from.y) < 8) openStage();
    },
  };

  return (
    <div className="capsule-wrap">
      <AnimatePresence>
        {track && !stage && !flashHome && (
          <motion.div
            className="capsule"
            initial={{ opacity: 0, y: 24, scale: 0.98 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 24, scale: 0.98, transition: { duration: 0.2 } }}
            transition={{ type: 'spring', duration: 0.5, bounce: 0.18 }}
            {...phone}
          >
            <Progress />
            <div className="now">
              <motion.button layoutId="stage-cover" className="cv-btn" title="Открыть сцену" onClick={() => openStage()} transition={{ type: 'spring', duration: 0.55, bounce: 0.12 }}>
                <Cover src={track.artwork} size={200} />
              </motion.button>
              <div className="info">
                <AnimatePresence mode="popLayout" initial={false}>
                  <motion.div key={track.id} initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -8 }} transition={{ duration: 0.22, ease: [0.23, 1, 0.32, 1] }}>
                    <div className="tt" title={track.title}>
                      {track.title}
                    </div>
                    <div className="ar">
                      {remoteFrom && (
                        <span className="wave-pill" title="Нажмите «Играть», чтобы продолжить с того же места">
                          Играло {remoteFrom}
                        </span>
                      )}
                      {wave && (
                        <span className="wave-pill" title="Играет «Вспышка»">
                          <Icon name="wave" size={11} stroke={2.2} /> Вспышка
                        </span>
                      )}
                      <ArtistLinks track={track} />
                    </div>
                  </motion.div>
                </AnimatePresence>
              </div>
              {(wave || flow) && (
                <button className="icon-btn cap-skip" title="Не то: больше такое не ставить в потоке" onClick={() => { notThis(track); next(); toast('Понял, такое больше не ставлю'); }} style={{ flex: 'none' }}>
                  <Icon name="thumbDown" size={18} />
                </button>
              )}
              <button className={'icon-btn' + (liked ? ' on' : '')} title="Любимое (L)" onClick={() => toggleLike(track)} style={{ flex: 'none' }}>
                <Icon name={liked ? 'heartFill' : 'heart'} size={19} />
              </button>
            </div>
            <div className="ctl">
              <Transport />
            </div>
            <div className="side">
              <span className="times" title="Длительность">
                <TimeNow /> / {fmt(duration)}
              </span>
              <button className="icon-btn" title="Текст песни" onClick={() => openStage('lyrics')}>
                <Icon name="lyrics" size={20} />
              </button>
              <button className="icon-btn" title="Очередь" onClick={() => openStage('queue')}>
                <Icon name="queue" size={20} />
              </button>
              <button className={'icon-btn' + (together ? ' on' : '')} title={together ? `Слушаете вместе: ${together.members.length}` : 'Слушать вместе'} onClick={() => store.set({ sheet: 'together' })}>
                <Icon name="together" size={20} />
              </button>
              <button
                className="icon-btn"
                title="Поделиться треком"
                onClick={() => shareTrack(track)}
              >
                <Icon name="share" size={20} />
              </button>
              <Volume />
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}

function TimeNow() {
  const ref = useRef(null);
  useEffect(() => {
    const id = setInterval(() => {
      if (ref.current) ref.current.textContent = fmt(nowTime());
    }, 250);
    return () => clearInterval(id);
  }, []);
  return <span ref={ref}>{fmt(nowTime())}</span>;
}
