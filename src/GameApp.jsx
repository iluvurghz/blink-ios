// Game mode: the whole Blink in one small window. No animations, no blur, no visualizer,
// no GPU (the main process turns hardware acceleration off), the clock ticks once a second.
import { useEffect, useRef } from 'react';
import Icon from './ui/Icon.jsx';
import GameSwitch from './ui/GameSwitch.jsx';
import { Cover, fmt } from './ui/common.jsx';
import { store, useStore, clock, nowTime, toggleLike, isLiked } from './lib/store.js';
import { playTrack, toggle, next, prev, seek, setVolume, initMedia } from './lib/player.js';
import { syncRelay } from './lib/relay.js';
import { switchGame, resumeAfterSwitch } from './lib/gamemode.js';

function Progress() {
  const fill = useRef(null);
  const cur = useRef(null);
  const total = useRef(null);
  useEffect(() => {
    const paint = () => {
      if (document.hidden) return;
      const d = clock.get().duration || 0;
      const t = nowTime();
      fill.current.style.width = (d ? Math.min(1, t / d) * 100 : 0) + '%';
      cur.current.textContent = fmt(t);
      total.current.textContent = fmt(d);
    };
    paint();
    const id = setInterval(paint, 1000);
    document.addEventListener('visibilitychange', paint);
    return () => {
      clearInterval(id);
      document.removeEventListener('visibilitychange', paint);
    };
  }, []);
  const at = (e) => {
    const r = e.currentTarget.getBoundingClientRect();
    seek(((e.clientX - r.left) / r.width) * (clock.get().duration || 0));
  };
  return (
    <div className="lite-progress">
      <span ref={cur}>0:00</span>
      <div className="bar" onClick={at}>
        <i ref={fill} />
      </div>
      <span ref={total}>0:00</span>
    </div>
  );
}

function useLiteKeys() {
  useEffect(() => {
    const onKey = (e) => {
      if (e.target.tagName === 'INPUT') return;
      const s = store.get();
      if (e.code === 'Space') {
        e.preventDefault();
        return toggle();
      }
      if (e.key === 'ArrowRight') return seek(nowTime() + 5);
      if (e.key === 'ArrowLeft') return seek(nowTime() - 5);
      if (e.key === 'ArrowUp') return setVolume(s.volume + 5);
      if (e.key === 'ArrowDown') return setVolume(s.volume - 5);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
}

export default function GameApp() {
  const loaded = useStore((s) => s.loaded);
  const track = useStore((s) => s.track);
  const playing = useStore((s) => s.status === 'playing');
  const volume = useStore((s) => (s.muted ? 0 : s.volume));
  const likes = useStore((s) => s.likes);
  const liked = useStore((s) => !!s.track && isLiked(s.track.id));
  useLiteKeys();
  useEffect(() => {
    if (!loaded) return;
    syncRelay();
    initMedia();
    resumeAfterSwitch();
    if (window.blink.setTrayOnClose) window.blink.setTrayOnClose(store.get().settings.tray !== false);
    if (window.blink.setDiscord) window.blink.setDiscord(store.get().settings.discord !== false);
  }, [loaded]);

  return (
    <div className="lite">
      <header className="lite-bar">
        <span className="lite-mark">
          <i />
          Blink · игровой
        </span>
        <button title="Свернуть" onClick={() => window.blink.minimize()}>
          <Icon name="min" size={16} />
        </button>
        <button title="Закрыть" onClick={() => window.blink.close()}>
          <Icon name="close" size={16} />
        </button>
      </header>

      {track ? (
        <div className="lite-now">
          <Cover src={track.artwork} size={160} />
          <div className="meta">
            <b>{track.title}</b>
            <span>{track.artist}</span>
          </div>
          <button className={'lite-ic' + (liked ? ' on' : '')} title="Нравится" onClick={() => toggleLike(track)}>
            <Icon name={liked ? 'heartFill' : 'heart'} size={18} />
          </button>
        </div>
      ) : (
        <div className="lite-now empty">
          <span>Ничего не играет</span>
          {likes.length > 0 && (
            <button className="lite-pill" onClick={() => playTrack(likes[0], likes, 0)}>
              Включить «Моё»
            </button>
          )}
        </div>
      )}

      <Progress />

      <div className="lite-ctl">
        <button className="lite-ic" title="Назад" onClick={prev}>
          <Icon name="prev" size={18} />
        </button>
        <button className="lite-play" title="Пауза / играть" onClick={toggle}>
          <Icon name={playing ? 'pause' : 'play'} size={18} />
        </button>
        <button className="lite-ic" title="Дальше" onClick={() => next()}>
          <Icon name="next" size={18} />
        </button>
        <input className="lite-vol" type="range" min="0" max="100" value={volume} onChange={(e) => setVolume(Number(e.target.value))} title="Громкость" />
        <button className="lite-ic" title="Выйти из игрового режима" onClick={() => switchGame(false)}>
          <Icon name="bolt" size={18} />
        </button>
      </div>

      {/* YouTube players: small on purpose, so YouTube picks the lightest video stream. */}
      <div className="lite-yt">
        <div id="yt-player" />
      </div>
      <div className="lite-yt">
        <div id="yt-player-2" />
      </div>
      <GameSwitch />
    </div>
  );
}
