import { useEffect, useState } from 'react';
import Icon from './Icon.jsx';
import { store, useStore, go, toggleLike, toast } from '../lib/store.js';
import { splitArtists, findArtistId } from '../lib/api.js';
import { playTrack } from '../lib/player.js';
import { hasRelay, relayOn } from '../lib/relay.js';
import { unqueue } from '../lib/offline.js';
import { proxied, scaleSc } from '../lib/img.js';

// Seconds (or a "3:41" string from some sources) as m:ss; anything unknown shows as 0:00.
export const secs = (v) => {
  if (typeof v === 'string' && v.includes(':')) return v.split(':').reduce((a, x) => a * 60 + (Number(x) || 0), 0);
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : 0;
};

export function fmt(s) {
  s = Math.floor(secs(s));
  const m = Math.floor(s / 60);
  return `${m}:${String(s % 60).padStart(2, '0')}`;
}

export function totalTime(tracks) {
  const s = tracks.reduce((a, t) => a + secs(t.duration), 0);
  const h = Math.floor(s / 3600);
  const m = Math.round((s % 3600) / 60);
  return h ? `${h} ч ${m} мин` : `${m} мин`;
}

export function plural(n, one, few, many) {
  const a = n % 10;
  const b = n % 100;
  if (a === 1 && b !== 11) return `${n} ${one}`;
  if (a >= 2 && a <= 4 && (b < 12 || b > 14)) return `${n} ${few}`;
  return `${n} ${many}`;
}

export function Cover({ src, size = 600, className = '', style, alt = '' }) {
  const [ok, setOk] = useState(false);
  const [broken, setBroken] = useState(false);
  // A cover that failed once (a dropped connection on a phone) gets two more tries before the
  // placeholder is shown for good.
  const [tries, setTries] = useState(0);
  // An http:// image on an https page is blocked as mixed content: don't request it.
  const insecure = src && /^http:/i.test(src) && typeof location !== 'undefined' && location.protocol === 'https:';
  // Scale to requested size: handles both iTunes (NxNbb.jpg) and Yandex (/NxN) URL formats.
  const scaleUrl = (u, s) => {
    if (!u) return '';
    // iTunes: ...100x100bb.jpg → ...600x600bb.jpg
    if (/\/\d+x\d+bb\.jpg$/.test(u)) return u.replace(/\/\d+x\d+bb\.jpg$/, `/${s}x${s}bb.jpg`);
    // Yandex: .../100x100 → .../1000x1000 (1000 is its largest square; 1200 answers 404)
    if (/\/\d+x\d+$/.test(u)) return u.replace(/\/\d+x\d+$/, `/${Math.min(s, 1000)}x${Math.min(s, 1000)}`);
    // SoundCloud: ...-large.jpg → ...-t500x500.jpg
    return scaleSc(u, s);
  };
  const base = src && !insecure ? scaleUrl(src, size) : '';
  // First try through Blink's server (fast, cached), then the original address, then once more.
  const url = !base ? '' : tries === 1 ? base : tries >= 2 ? proxied(base) + '#r' + tries : proxied(base);
  useEffect(() => (setOk(false), setBroken(false), setTries(0)), [base]);
  return (
    <div className={'cover ' + className} style={style}>
      {url && !broken ? <img
          src={url}
          alt={alt}
          loading="lazy"
          decoding="async"
          referrerPolicy="no-referrer"
          draggable={false}
          className={ok ? 'ok' : ''}
          onLoad={() => setOk(true)}
          onError={() => {
            if (tries < 2) setTimeout(() => setTries((n) => n + 1), 700 * (tries + 1));
            else setBroken(true);
          }}
          ref={(el) => el && el.complete && el.naturalWidth > 0 && !ok && setOk(true)}
        /> : null}
      {(!url || broken) && (
        <div className="ph">
          <Icon name="disc" size={28} />
        </div>
      )}
    </div>
  );
}

// Fetch helper with cache so going back is instant. With `persist` (ms) the result also
// lives on disk: the next launch shows it at once and refreshes it quietly once it's older.
const cache = new Map();
const DISK = 'blink-c:';
const empty = (d) => d == null || (Array.isArray(d) && !d.length);
function saved(key, persist) {
  if (cache.has(key)) return { data: cache.get(key), fresh: true };
  if (!persist) return null;
  try {
    const d = JSON.parse(localStorage.getItem(DISK + key));
    return d && !empty(d.data) ? { data: d.data, fresh: Date.now() - d.t < persist } : null;
  } catch {
    return null;
  }
}
export function useAsync(key, fn, { persist = 0 } = {}) {
  const [state, setState] = useState(() => {
    const s = saved(key, persist);
    return s ? { data: s.data, loading: !s.fresh } : { loading: true };
  });
  const [nonce, setNonce] = useState(0);
  useEffect(() => {
    let alive = true;
    const s = nonce === 0 ? saved(key, persist) : null;
    if (s) {
      setState({ data: s.data, loading: !s.fresh });
      if (s.fresh) return;
    } else setState((p) => ({ data: p.data, loading: true }));
    fn()
      .then((data) => {
        if (!alive) return;
        // A failed source comes back empty: keep what we already showed instead.
        if (empty(data) && s) return setState({ data: s.data, loading: false });
        cache.set(key, data);
        if (persist && !empty(data)) {
          try {
            localStorage.setItem(DISK + key, JSON.stringify({ t: Date.now(), data }));
          } catch {
            /* storage full or private window */
          }
        }
        setState({ data, loading: false });
      })
      .catch((error) => alive && setState(s ? { data: s.data, loading: false } : { error, loading: false }));
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, nonce]);
  return { ...state, retry: () => setNonce((n) => n + 1) };
}

export function ErrorBox({ retry, text = 'Не получилось загрузить' }) {
  return (
    <div className="err-box">
      <h3>{text}</h3>
      <p>Проверьте интернет и попробуйте ещё раз.</p>
      <button className="btn ghost" onClick={retry}>
        Повторить
      </button>
    </div>
  );
}

export function openMenu(e, track, extra = {}) {
  e.preventDefault();
  e.stopPropagation();
  const r = e.currentTarget.getBoundingClientRect();
  const x = e.type === 'contextmenu' ? e.clientX : r.right;
  const y = e.type === 'contextmenu' ? e.clientY : r.bottom + 4;
  store.set({ menu: { x, y, track, ...extra } });
}

export function Eq({ on }) {
  return (
    <span className={'eq' + (on ? ' on' : '')}>
      <i />
      <i />
      <i />
    </span>
  );
}

// Small icon on a track row: where the track plays from. Blink and Jamendo releases are known up
// front; for everything else it shows how the track actually played last time (MP3 parser or YouTube).
function SourceBadge({ track }) {
  const last = useStore((s) => s.via && s.via[track.id]);
  const relay = useStore((s) => hasRelay() && relayOn(s.settings || {}));
  const kind = track.source === 'blink' || track.source === 'jamendo' ? track.source : track.source === 'parser' ? 'mp3' : last;
  if (!kind) return null;
  const info = {
    blink: ['disc', 'Релиз Blink'],
    jamendo: ['wave', 'Jamendo'],
    mp3: ['api', 'MP3'],
    yt: ['youtube', 'YouTube'],
  }[kind];
  return (
    <span className={'via via-' + kind} title={info[1]}>
      <Icon name={info[0]} size={13} />
    </span>
  );
}

export function TrackRow({ track, list, index, number, showAlbum = true, playlistId, queueIndex, onPlay }) {
  const current = useStore((s) => s.track && s.track.id === track.id);
  const playing = useStore((s) => s.status === 'playing');
  const liked = useStore((s) => s.likes.some((t) => t.id === track.id));
  const saved = useStore((s) => (s.saved || []).some((t) => t.id === track.id));
  // Waiting to be saved: -1; downloading now: 0..1.
  const dl = useStore((s) => (s.dl && s.dl.ids.includes(track.id) ? (s.dl.cur === track.id && !s.dl.paused ? s.dl.pct || 0 : -1) : null));
  const len = useStore((s) => secs(track.duration) || (s.lens && s.lens[track.id]) || 0);
  const play = () => (onPlay ? onPlay() : playTrack(track, list, index));
  return (
    <div
      role="button"
      tabIndex={0}
      className={'trow' + (current ? ' current' : '') + (showAlbum ? '' : ' no-album')}
      onClick={play}
      onKeyDown={(e) => e.key === 'Enter' && play()}
      onContextMenu={(e) => openMenu(e, track, { playlistId, queueIndex })}
    >
      <div className="idx">
        <span className="num">{number !== undefined ? number : index + 1}</span>
        <span className="hov">
          <Icon name="play" size={16} />
        </span>
        {current && <Eq on={playing} />}
      </div>
      <Cover src={track.artwork} size={100} className="cv" />
      <div className="meta">
        <div className="tt">{track.title}</div>
        <div className="ar">
          {saved && (
            <span className="saved-dot" title="Сохранён, играет без интернета">
              <Icon name="download" size={12} />
            </span>
          )}
          {dl !== null && (
            <button
              className={'dl-ring' + (dl < 0 ? ' wait' : '')}
              title={dl < 0 ? 'В очереди на сохранение. Нажмите, чтобы убрать' : `Сохраняю ${Math.round(dl * 100)}%. Нажмите, чтобы отменить`}
              onClick={(e) => {
                e.stopPropagation();
                unqueue(track.id);
              }}
            >
              <svg viewBox="0 0 20 20" width="16" height="16">
                <circle cx="10" cy="10" r="8" />
                <circle cx="10" cy="10" r="8" className="fg" strokeDasharray={`${Math.max(dl, 0) * 50.3} 50.3`} />
              </svg>
            </button>
          )}
          <SourceBadge track={track} />
          {track.explicit && <span className="explicit">E</span>}
          <ArtistLinks track={track} />
        </div>
      </div>
      <div className="album">
        {track.albumId ? (
          <button
            onClick={(e) => {
              e.stopPropagation();
              go('album', { id: track.albumId });
            }}
          >
            {track.album}
          </button>
        ) : (
          track.album
        )}
      </div>
      <button
        className={'icon-btn like' + (liked ? ' on' : '')}
        title={liked ? 'Убрать из любимого' : 'В любимое'}
        onClick={(e) => {
          e.stopPropagation();
          toggleLike(track);
        }}
      >
        <Icon name={liked ? 'heartFill' : 'heart'} size={18} />
      </button>
      <div className="dur">{len ? fmt(len) : '—'}</div>
      <button className="icon-btn more" title="Ещё" onClick={(e) => openMenu(e, track, { playlistId, queueIndex })}>
        <Icon name="more" size={18} />
      </button>
    </div>
  );
}

export function AlbumCard({ album, onPlay }) {
  return (
    <div className="card" role="button" tabIndex={0} onClick={() => go('album', { id: album.id })} onKeyDown={(e) => e.key === 'Enter' && go('album', { id: album.id })}>
      <div style={{ position: 'relative' }}>
        <Cover src={album.artwork} size={400} />
        {onPlay && (
          <button
            className="play-fab"
            title="Слушать"
            onClick={(e) => {
              e.stopPropagation();
              onPlay(album);
            }}
          >
            <Icon name="play" size={20} />
          </button>
        )}
      </div>
      <div className="t">
        {album.title}
        {album.fresh && <span className="badge fresh">NEW</span>}
      </div>
      <div className="s">{[album.type !== 'Альбом' ? album.type : null, album.year, album.artist].filter(Boolean).join(' · ')}</div>
    </div>
  );
}

export function ArtistCard({ artist }) {
  return (
    <button className="card artist" onClick={() => go('artist', { id: artist.id })}>
      <Cover src={artist.artwork} size={400} />
      <div className="t">{artist.name}</div>
      <div className="s">{artist.genre || 'Артист'}</div>
    </button>
  );
}

export function Skeleton({ rows = 8 }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12, marginTop: 24 }}>
      {Array.from({ length: rows }, (_, i) => (
        <div key={i} className="sk" style={{ height: 56, opacity: 1 - i * 0.09 }} />
      ))}
    </div>
  );
}


// Each artist name is its own link, even when Apple lists them as one combined artist.
export function ArtistLinks({ track, className }) {
  const names = splitArtists(track.artist);
  const open = async (e, name) => {
    e.stopPropagation();
    // Blink's own artists aren't in Apple's catalog: show everything they have here.
    if (track.source === 'blink' && track.artistRef && names.length === 1) return go('bartist', { id: track.artistRef });
    if (track.source === 'blink' || track.source === 'jamendo') {
      store.set({ query: name });
      return go('search');
    }
    // Parser tracks don't have an Apple artistId — search by name instead.
    if (track.source === 'parser' || track.source === 'chart') {
      const id = await findArtistId(name, store.get().settings.country).catch(() => null);
      if (id) return go('artist', { id });
      store.set({ query: name });
      return go('search');
    }
    if (names.length === 1 && track.artistId) return go('artist', { id: track.artistId });
    const id = await findArtistId(name, store.get().settings.country).catch(() => null);
    if (id) go('artist', { id });
    else toast('Не нашёл страницу этого артиста');
  };
  return (
    <span className={className}>
      {names.map((n, i) => (
        <span key={n + i}>
          {i > 0 && <span className="sep">{i === names.length - 1 ? ' & ' : ', '}</span>}
          <button className="artist-link" onClick={(e) => open(e, n)}>
            {n}
          </button>
        </span>
      ))}
      {/* Jamendo's terms: credit Jamendo with a link to the track's page. */}
      {track.source === 'jamendo' && track.link && (
        <>
          <span className="sep"> · </span>
          <a className="artist-link jamendo-link" href={track.link} target="_blank" rel="noopener" onClick={(e) => e.stopPropagation()}>
            Jamendo
          </a>
        </>
      )}
    </span>
  );
}

export function Switch({ on, onChange }) {
  return (
    <button className={'switch' + (on ? ' on' : '')} role="switch" aria-checked={on} onClick={() => onChange(!on)}>
      <i />
    </button>
  );
}
