import FlashHome from './FlashHome.jsx';
import { useEffect, useRef, useState } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import Icon from './Icon.jsx';
import { Cover, TrackRow, AlbumCard, ArtistCard, ArtistLinks, Skeleton, ErrorBox, useAsync, fmt, totalTime, plural, openMenu, Eq } from './common.jsx';
import { ask } from './Confirm.jsx';
import { Progress, Transport, Volume } from './Capsule.jsx';
import { store, useStore, go, playable, createPlaylist, deletePlaylist, renamePlaylist, toast, toggleLike } from '../lib/store.js';
import { playTrack, startWave, next } from '../lib/player.js';
import { tasteArtists, waveBatch, notThis, WAVE_MODES } from '../lib/wave.js';
import * as api from '../lib/api.js';
import { proxied, coverFallback } from '../lib/img.js';
import { paletteFor } from '../lib/color.js';
import { searchLicensed, latestLicensed, searchJamendo, uploadPlaylistCover } from '../lib/catalog.js';
import { sharePlaylist, sharedState, unsharePlaylist, shareLink, fetchEditorial, fetchEditorialOne } from '../lib/cloud.js';
import { searchMp3 } from '../lib/apiparser.js';
import { searchApiblink, searchSoundcloud, searchVk } from '../lib/apiblink.js';
import { topRu, periodChart } from '../lib/charts.js';
import { FriendsStrip } from './Friends.jsx';
import { searchMore, trackKey } from '../lib/moreMeta.js';
import { noAi } from '../lib/aiFilter.js';
import { rankTracks } from '../lib/rank.js';
import { FollowFeed } from './Profile.jsx';
import YandexLikes, { yandexTab } from './YandexLikes.jsx';
import { saveTracks, pauseDownloads, resumeDownloads, cancelDownloads } from '../lib/offline.js';
import { usePlus } from '../lib/plus.js';
import { PlusPromo } from './Plus.jsx';

import { humanError } from '../lib/errors.js';
const ease = [0.23, 1, 0.32, 1];
const rise = (i = 0) => ({
  initial: { opacity: 0, y: 14 },
  animate: { opacity: 1, y: 0 },
  transition: { duration: 0.45, ease, delay: Math.min(i, 10) * 0.04 },
});

function compact(n) {
  if (n >= 1e6) return (n / 1e6).toFixed(n >= 1e7 ? 0 : 1).replace('.', ',') + ' млн';
  if (n >= 1e3) return Math.round(n / 1e3) + ' тыс.';
  return String(n);
}

function shuffled(list) {
  const a = [...list];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

async function playAlbum(album, country) {
  try {
    const a = await api.album(album.id, country);
    if (a.tracks.length) playTrack(a.tracks[0], a.tracks, 0);
  } catch {
    toast('Не получилось открыть альбом', 'error');
  }
}


// ---------------- Home ----------------

// Home sections are kept on disk this long before a quiet refresh.
const HOME_TTL = 30 * 60 * 1000;

// «Главная» is «Вспышка» alone on one screen, on phones and on the computer alike: playing or asleep.
// That screen lives in FlashHost (outside the page transitions); the chart has its own «Чарт» tab.
export function Home() {
  return null;
}

// Keeps the «Вспышка» screen mounted once shown, so coming back to «Главная» doesn't rebuild it
// (no blink, no new WebGL setup); it is only hidden on other pages.
export function FlashHost() {
  const shown = useStore((s) => s.view.name === 'home');
  const [kept, setKept] = useState(shown);
  useEffect(() => {
    if (shown) setKept(true);
  }, [shown]);
  if (!kept) return null;
  return (
    <div className="flash-host" hidden={!shown}>
      <FlashHome shown={shown} />
    </div>
  );
}

// The chart home: number one, «Вспышка», recent tracks and the charts. The phone «Чарт» tab shows it without «Вспышка».
export function Overview({ noFlash = false }) {
  const country = useStore((s) => s.settings.country);
  const recent = useStore((s) => s.recent);
  const nowId = useStore((s) => s.track && s.track.id);
  const playing = useStore((s) => s.status === 'playing');
  // While «Вспышка» plays, its player takes the top of the home page.
  const flashOn = useStore((s) => s.wave && !!s.track);
  const { data, loading: appleLoading, error, retry } = useAsync('charts:' + country, () => api.charts(country).then((d) => (d.tracks.length || d.albums.length ? d : null)), { persist: HOME_TTL });
  // The real chart of Russia when it can be had; the older feed stays as the fallback.
  const ru = useAsync('charts:ru-top', () => topRu().catch(() => null), { persist: HOME_TTL });
  const tracks = (ru.data && ru.data.length ? ru.data : data && data.tracks) || [];
  // The hero waits only while there is nothing at all to show, not for every source.
  const loading = !tracks.length && (appleLoading || ru.loading);
  // A slow connection used to leave the skeleton up for ~20 s with no word: say so after 8 s.
  const [slow, setSlow] = useState(false);
  useEffect(() => {
    if (!loading) return setSlow(false);
    const t = setTimeout(() => setSlow(true), 8000);
    return () => clearTimeout(t);
  }, [loading]);

  if (error && !tracks.length) return <ErrorBox retry={retry} />;
  const top = tracks[0];
  const hour = new Date().getHours();
  const greet = hour < 5 ? 'Доброй ночи' : hour < 12 ? 'Доброе утро' : hour < 18 ? 'Добрый день' : 'Добрый вечер';

  return (
    <div className="view">
      {flashOn && !noFlash ? (
        <FlashCard />
      ) : loading ? (
        <div className="hero">
          <div>
            <div className="sk" style={{ width: 160, height: 14 }} />
            <div className="sk" style={{ width: '70%', height: 150, marginTop: 24 }} />
          </div>
          <div className="sk" style={{ aspectRatio: 1, borderRadius: 24 }} />
          {slow && (
            <div className="slow-note" style={{ gridColumn: '1 / -1' }}>
              Чарт грузится дольше обычного.
              <button className="btn ghost" onClick={retry}>
                Повторить
              </button>
            </div>
          )}
        </div>
      ) : top ? (
        <section className="hero">
          <motion.div {...rise(0)}>
            <div className="label">
              {greet} · Номер один в России
            </div>
            <h1>{top.title}</h1>
            <div className="who">
              <button onClick={() => top.artistId && go('artist', { id: top.artistId })}>{top.artist}</button>
            </div>
            <div className="actions">
              <button className="btn primary" onClick={() => playTrack(top, tracks, 0)}>
                <Icon name="play" size={18} /> Слушать чарт
              </button>
              <button
                className="btn ghost"
                onClick={() => {
                  const s = shuffled(tracks);
                  playTrack(s[0], s, 0);
                }}
              >
                <Icon name="shuffle" size={18} /> Вперемешку
              </button>
            </div>
          </motion.div>
          <motion.div initial={{ opacity: 0, scale: 0.96 }} animate={{ opacity: 1, scale: 1 }} transition={{ duration: 0.7, ease }}>
            <button style={{ width: '100%' }} onClick={() => playTrack(top, tracks, 0)} title="Слушать">
              <Cover src={top.artwork} size={800} />
            </button>
          </motion.div>
        </section>
      ) : null}

      {!flashOn && !noFlash && <FlashCard fallback={tracks.slice(0, 8)} />}

      {recent.length > 0 && (
        <section className="section">
          <div className="section-head">
            <h2 className="h-section">Вы недавно слушали</h2>
          </div>
          <div className="recent-strip">
            {recent.slice(0, 8).map((t, i) => (
              <motion.button key={t.id} className="chip" {...rise(i)} onClick={() => playTrack(t, recent, i)} onContextMenu={(e) => openMenu(e, t)}>
                <Cover src={t.artwork} size={100} className="cv" />
                <div style={{ minWidth: 0 }}>
                  <div className="tt">{t.title}</div>
                  <div className="ar">{t.artist}</div>
                </div>
              </motion.button>
            ))}
          </div>
        </section>
      )}

      <FollowFeed />

      {!data && appleLoading && (
        <section className="section" aria-hidden="true">
          <div className="section-head">
            <h2 className="h-section">Альбомы недели</h2>
          </div>
          <div className="row-scroll">
            {[0, 1, 2, 3].map((i) => (
              <div key={i} className="card">
                <div className="sk" style={{ aspectRatio: 1, borderRadius: 16 }} />
                <div className="sk" style={{ height: 14, width: '70%', marginTop: 12 }} />
              </div>
            ))}
          </div>
        </section>
      )}

      {data && data.albums.length > 0 && (
        <section className="section">
          <div className="section-head">
            <h2 className="h-section">Альбомы недели</h2>
          </div>
          <div className="row-scroll">
            {data.albums.map((a) => (
              <AlbumCard key={a.id} album={a} onPlay={(al) => playAlbum(al, country)} />
            ))}
          </div>
        </section>
      )}

      {tracks.length > 0 ? <ChartSection title="Топ в России" tracks={tracks} /> : loading && <section className="section chart-hold" aria-hidden="true" />}

      <HotCharts />

      <NewInBlink />

      <TopPlaylists />

      <div className="home-foot">
        <a className="powered" href="https://spherical.media" target="_blank" rel="noopener" onClick={(e) => (e.preventDefault(), window.blink.open('https://spherical.media'))}>
          Blink · при поддержке <b>Spherical Media</b>
        </a>
        <div className="tg-links">
          <a href="https://t.me/blinkmusic_live" target="_blank" rel="noopener" onClick={(e) => (e.preventDefault(), window.blink.open('https://t.me/blinkmusic_live'))}>Telegram-канал</a>
          <a href="https://t.me/blinkmusic_commits" target="_blank" rel="noopener" onClick={(e) => (e.preventDefault(), window.blink.open('https://t.me/blinkmusic_commits'))}>Тех. ТГК</a>
          <a href="https://t.me/SYLQENMNGR" target="_blank" rel="noopener" onClick={(e) => (e.preventDefault(), window.blink.open('https://t.me/SYLQENMNGR'))}>Менеджер</a>
        </div>
        <div className="copyright">© 2026 <b>SYLQEN</b></div>
      </div>
    </div>
  );
}

// A numbered two-column chart, the first 20 shown until "show all".
function ChartSection({ title, tracks, head = null }) {
  const nowId = useStore((s) => s.track && s.track.id);
  const playing = useStore((s) => s.status === 'playing');
  const [all, setAll] = useState(false);
  const shown = all ? tracks : tracks.slice(0, 20);
  return (
    <section className="section">
      <div className="section-head">
        <h2 className="h-section">{title}</h2>
        {head || <span className="label">{plural(tracks.length, 'трек', 'трека', 'треков')}</span>}
      </div>
      <div className="chart">
        {shown.map((t, i) => (
          <button key={t.id} className={'crow' + (nowId === t.id ? ' current' : '')} onClick={() => playTrack(t, tracks, i)} onContextMenu={(e) => openMenu(e, t)}>
            <span className="n">{i + 1}</span>
            <Cover src={t.artwork} size={100} className="cv" />
            <span style={{ minWidth: 0 }}>
              <div className="tt">{t.title}</div>
              <div className="ar">
                {t.explicit && <span className="explicit">E</span>}
                {t.artist}
              </div>
            </span>
            <span className="dur">
              {nowId === t.id ? (
                <span style={{ position: 'relative', display: 'inline-block', width: 20, height: 14 }}>
                  <Eq on={playing} />
                </span>
              ) : t.duration ? (
                fmt(t.duration)
              ) : (
                <Move v={t.move} />
              )}
            </span>
          </button>
        ))}
      </div>
      {tracks.length > 20 && (
        <div style={{ textAlign: 'center', marginTop: 24 }}>
          <button className="btn ghost" onClick={() => setAll(!all)}>
            {all ? 'Свернуть' : `Показать все ${tracks.length}`}
          </button>
        </div>
      )}
    </section>
  );
}

// Movement in the chart: "New", "12" (up), "-3" (down) or nothing.
function Move({ v }) {
  if (!v || v === '0') return null;
  if (/new/i.test(v)) return <span className="move new">NEW</span>;
  const n = Number(v);
  if (!Number.isFinite(n) || !n) return null;
  return <span className={'move ' + (n > 0 ? 'up' : 'down')}>{n > 0 ? '▲' : '▼'} {Math.abs(n)}</span>;
}

// What's hot among new Russian releases: today, this week, this month.
const PERIODS = [
  ['daily', 'День'],
  ['weekly', 'Неделя'],
  ['monthly', 'Месяц'],
];
function HotCharts() {
  const [kind, setKind] = useState(() => {
    try {
      return localStorage.getItem('blink-hot') || 'daily';
    } catch {
      return 'daily';
    }
  });
  const pick = (k) => {
    setKind(k);
    try {
      localStorage.setItem('blink-hot', k);
    } catch {
      /* private window */
    }
  };
  const { data } = useAsync('charts:hot:' + kind, () => periodChart(kind).catch(() => []), { persist: HOME_TTL });
  if (!data) return null;
  if (!data.length && kind === 'daily') return null;
  const tabs = (
    <div className="seg-mini" role="tablist">
      {PERIODS.map(([k, label]) => (
        <button key={k} role="tab" aria-selected={kind === k} className={kind === k ? 'on' : ''} onClick={() => pick(k)}>
          {label}
        </button>
      ))}
    </div>
  );
  return <ChartSection title="Горячие новинки" tracks={data} head={tabs} />;
}

// «Вспышка» has no animated background any more: a WebGL shader plus blurred full-screen layers
// were the heaviest thing in the app (it lagged on phones). The mood comes from a plain
// gradient in the accent colour, drawn by CSS (.pf-bg / .flash).
function Aura() {
  return null;
}

// "Вспышка": your own endless stream. The card shimmers with waves in the current palette;
// once it plays, the top of the home page turns into its player.
function FlashCard({ fallback = [] }) {
  const wave = useStore((s) => s.wave);
  const playing = useStore((s) => s.status === 'playing' || s.status === 'buffering');
  const loading = useStore((s) => s.waveLoading);
  const track = useStore((s) => s.wave && s.track);
  const on = wave && playing;
  const names = tasteArtists()
    .slice(0, 3)
    .map((a) => a.name.split(/,|&| feat/i)[0].trim());
  const hint = names.length ? `${names.join(', ')} и похожее на них` : fallback.length ? 'Начнём с того, что слушают сейчас' : 'Слушайте и ставьте лайки, и поток подстроится под вас';
  if (wave && track) return <FlashScreen track={track} on={on} />;
  return (
    <motion.section className="section" {...rise(1)}>
      <div className="flash">
        <Aura active={loading} gl="flash-gl" waves="flash-waves" />
        <button className="flash-core" onClick={() => startWave()} disabled={loading} aria-label="Включить Вспышку">
          <span className="core-ico">{loading ? <span className="spin" /> : <Icon name="play" size={30} />}</span>
        </button>
        <div className="flash-text">
          <span className="label">Ваш личный поток</span>
          <span className="flash-title">
            Вспышка<span className="dot" />
          </span>
          <span className="flash-hint">{hint}</span>
          <span className="flash-sub">Любимое, новое от ваших артистов и музыка в том же стиле. Без конца.</span>
        </div>
      </div>
    </motion.section>
  );
}

// Home while «Вспышка» plays: a player screen with the same cover as the full-screen stage.
function FlashScreen({ track, on }) {
  const liked = useStore((s) => s.likes.some((t) => t.id === track.id));
  const mode = useStore((s) => s.settings.waveMode || 'mix');
  const photo = api.art(track.artwork || '', 1000);
  const setMode = async (m) => {
    if (m === mode) return;
    store.set({ settings: { ...store.get().settings, waveMode: m } });
    // The new mode takes over from the next track.
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
  return (
    <motion.section className="section" initial={{ opacity: 0, scale: 0.98 }} animate={{ opacity: 1, scale: 1 }} transition={{ duration: 0.5, ease }}>
      <div className={'flash flash-screen' + (on ? ' on' : '')}>
        <Aura active={on} gl="flash-gl" waves="flash-waves" />
        <div className="fs-info">
          <span className="label">
            <Icon name="wave" size={13} /> Вспышка · {on ? 'играет сейчас' : 'на паузе'}
          </span>
          <div className="seg-mini fs-modes" role="tablist" aria-label="Режим Вспышки">
            {WAVE_MODES.map(([k, label]) => (
              <button key={k} role="tab" aria-selected={mode === k} className={mode === k ? 'on' : ''} onClick={() => setMode(k)}>
                {label}
              </button>
            ))}
          </div>
          <AnimatePresence mode="wait" initial={false}>
            <motion.div key={track.id} initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -10 }} transition={{ duration: 0.3, ease }}>
              <h1 className="fs-title">{track.title}</h1>
              <div className="fs-artist">
                <ArtistLinks track={track} />
              </div>
            </motion.div>
          </AnimatePresence>
          <div className="fs-ctl">
            <Transport big />
            <button className="fs-skip" title="Больше такое не ставить во «Вспышке»" onClick={skipThis}>
              <Icon name="thumbDown" size={17} /> Не моё
            </button>
            <button className={'icon-btn' + (liked ? ' on' : '')} title="Любимое" onClick={() => toggleLike(track)}>
              <Icon name={liked ? 'heartFill' : 'heart'} size={22} />
            </button>
            <Volume />
          </div>
          <div className="fs-progress">
            <Progress showTimes />
          </div>
        </div>
        <button className="fs-art" onClick={() => store.set({ stage: true, stageTab: 'lyrics' })} title="Развернуть">
          <AnimatePresence mode="popLayout" initial={false}>
            <motion.img key={track.id} src={proxied(photo)} {...coverFallback(photo)} alt="" draggable={false} initial={{ opacity: 0, scale: 1.04 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.5, ease }} />
          </AnimatePresence>
        </button>
      </div>
    </motion.section>
  );
}

// Playlists made by Blink's editors in the admin panel (genres and picks).
function TopPlaylists() {
  const { data } = useAsync('editorial:list', () => fetchEditorial().catch(() => []), { persist: HOME_TTL });
  if (!data || !data.length) return null;
  return (
    <section className="section">
      <div className="section-head">
        <h2 className="h-section">Выбор редакции</h2>
      </div>
      <div className="row-scroll">
        {data.map((p) => (
          <div key={p.id} className="card" role="button" tabIndex={0} onClick={() => go('editorial', { id: p.id })} onKeyDown={(e) => e.key === 'Enter' && go('editorial', { id: p.id })}>
            <Cover src={p.cover_url || p.art} size={400} />
            <div className="t">{p.title}</div>
            <div className="s">{p.description || (p.kind === 'genre' ? 'Жанр' : 'Выбор редакции')}</div>
          </div>
        ))}
      </div>
    </section>
  );
}

// One editorial playlist: listen, or keep a copy in your library.
export function Editorial({ id }) {
  const { data, loading, error, retry } = useAsync('editorial:' + id, () => fetchEditorialOne(id));
  if (error) return <ErrorBox retry={retry} />;
  if (loading && !data) return <div className="view"><Skeleton /></div>;
  if (!data)
    return (
      <div className="view empty">
        <div>
          <h2>Плейлист не найден</h2>
          <button className="btn ghost" onClick={() => go('home')}>
            На главную
          </button>
        </div>
      </div>
    );
  const tracks = data.tracks || [];
  const keep = () => {
    const p = createPlaylist(data.title, tracks);
    if (!p) return;
    if (data.cover_url) store.set({ playlists: store.get().playlists.map((x) => (x.id === p.id ? { ...x, cover: data.cover_url } : x)) });
    toast(`«${data.title}» теперь у вас`);
  };
  return (
    <div className="view">
      <div className="page-head">
        <motion.div initial={{ opacity: 0, scale: 0.96 }} animate={{ opacity: 1, scale: 1 }} transition={{ duration: 0.5, ease }}>
          <Mosaic tracks={tracks} cover={data.cover_url} />
        </motion.div>
        <motion.div {...rise(1)} style={{ minWidth: 0 }}>
          <div className="label">{data.kind === 'genre' ? 'Жанровый плейлист' : 'Плейлист редакции'}</div>
          <h1>{data.title}</h1>
          {data.description && <p className="page-desc">{data.description}</p>}
          <div className="sub">
            <span>{plural(tracks.length, 'трек', 'трека', 'треков')}</span>
            {tracks.length > 0 && <span>{totalTime(tracks)}</span>}
          </div>
          <div className="actions">
            <button className="btn primary" disabled={!tracks.length} onClick={() => playTrack(tracks[0], tracks, 0)}>
              <Icon name="play" size={18} /> Слушать
            </button>
            <button
              className="btn ghost"
              disabled={!tracks.length}
              onClick={() => {
                const s = shuffled(tracks);
                playTrack(s[0], s, 0);
              }}
            >
              <Icon name="shuffle" size={18} /> Вперемешку
            </button>
            <button className="icon-btn" title="Добавить к себе" onClick={keep}>
              <Icon name="plus" size={19} />
            </button>
          </div>
        </motion.div>
      </div>
      <div className="tracks">
        {tracks.map((t, i) => (
          <TrackRow key={t.id} track={t} list={tracks} index={i} />
        ))}
      </div>
    </div>
  );
}

// Fresh releases from Blink's own catalog (artist uploads and partners).
function NewInBlink() {
  const { data } = useAsync('lic:latest', () => latestLicensed(12).catch(() => []), { persist: HOME_TTL });
  if (!data || !data.length) return null;
  return (
    <section className="section">
      <div className="section-head">
        <h2 className="h-section">
          Новинки в <span className="accent-word">Blink</span>
        </h2>
      </div>
      <div className="recent-strip">
        {data.map((t, i) => (
          <button key={t.id} className="chip" onClick={() => playTrack(t, data, i)} onContextMenu={(e) => openMenu(e, t)}>
            <Cover src={t.artwork} size={200} className="cv" />
            <div style={{ minWidth: 0 }}>
              <div className="tt">{t.title}</div>
              <div className="ar">{t.artist}</div>
            </div>
          </button>
        ))}
      </div>
    </section>
  );
}

// ---------------- Search ----------------

const IDEAS = ['Miyagi', 'Скриптонит', 'The Weeknd', 'Земфира', 'Kendrick Lamar', 'Макс Корж', 'Billie Eilish', 'Баста'];

export function Search() {
  const q = useStore((s) => s.query.trim());
  const country = useStore((s) => s.settings.country);
  const debounced = useDebounced(q, 280);
  if (!debounced) return <SearchEmpty />;
  return <SearchResults q={debounced} country={country} />;
}

function useDebounced(v, ms) {
  const [d, setD] = useState(v);
  useEffect(() => {
    const t = setTimeout(() => setD(v), v ? ms : 0);
    return () => clearTimeout(t);
  }, [v, ms]);
  return d;
}

function SearchEmpty() {
  return (
    <div className="view empty">
      <div>
        <h2>Что послушаем?</h2>
        <div>Начните печатать: трек, артист или альбом.</div>
        <div className="chips">
          {IDEAS.map((x) => (
            <button key={x} className="qchip" onClick={() => store.set({ query: x })}>
              {x}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

function SearchResults({ q, country }) {
  useStore((s) => s.aiBan); // re-filter after «Это нейротрек»
  const { data, loading, error, retry } = useAsync(`search:${country}:${q.toLowerCase()}`, () => api.search(q, country));
  const own = useAsync(`lic:${q.toLowerCase()}`, () => searchLicensed(q).catch(() => []));
  const exclusive = own.data || [];
  const jam = useAsync(`jam:${q.toLowerCase()}`, () => searchJamendo(q).catch(() => []));
  const free = noAi(jam.data);
  const parserOn = useStore((s) => s.parserEnabled === true);
  const yandexPrimary = useStore((s) => s.yandexAsPrimary || s.yandexSearchOnly);
  useStore((s) => s.dead); // re-filter after a track fails to play
  const likes = useStore((s) => s.likes);
  const recent = useStore((s) => s.recent);
  const mp3 = useAsync(`mp3:${parserOn}:${q.toLowerCase()}`, () => (parserOn ? searchMp3(q, 10).catch(() => []) : Promise.resolve([])));
  const apiblink = useAsync(`apiblink:${q.toLowerCase()}`, () => searchApiblink(q).catch(() => []));
  const sc = useAsync(`sc:${q.toLowerCase()}`, () => searchSoundcloud(q).catch(() => []));
  const vk = useAsync(`vk:${q.toLowerCase()}`, () => searchVk(q).catch(() => []));
  // Other catalogs fill in what Apple doesn't have (many Russian and independent releases).
  const more = useAsync(`more:${q.toLowerCase()}`, () => searchMore(q).catch(() => []));

  // Convert API parser results to track objects — enrich with artwork from iTunes if available.
  const mp3tracks = (mp3.data || []).map((item, i) => {
    // Try to find matching artwork from Apple results (same title+artist).
    const norm = (s) => (s || '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
    const match = data && data.tracks.find(
      (t) => norm(t.title) === norm(item.title) && norm(t.artist).includes(norm((item.artist || '').split(/,|&|\sfeat/i)[0]))
    );
    return {
      id: 'parser:' + q + ':' + i,
      source: 'parser',
      title: item.title,
      artist: item.artist,
      artistId: null,
      album: match ? match.album : '',
      albumId: null,
      artwork: match ? match.artwork : '',
      duration: item.duration || match?.duration || 0,
      _parserUrl: item.url,
    };
  });

  // Convert APIBlink (Yandex) results to track objects.
  const apiblinkTracks = (apiblink.data || []).map((item, i) => {
    const norm = (s) => (s || '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
    const match = data && data.tracks.find(
      (t) => norm(t.title) === norm(item.title) && norm(t.artist).includes(norm((item.artist || '').split(/,|&|\sfeat/i)[0]))
    );
    return {
      id: 'apiblink:' + q + ':' + i,
      source: 'parser',
      title: item.title,
      artist: item.artist,
      artistId: null,
      album: match ? match.album : '',
      albumId: null,
      artwork: item.artwork || (match ? match.artwork : ''),
      duration: item.duration || match?.duration || 0,
      _parserUrl: item.url,
    };
  });
  // SoundCloud: independent artists, remixes, things no other catalog has. Plays through the same
  // direct-URL path as the other APIBlink sources.
  const scTracks = noAi(
    (sc.data || [])
      .filter((item) => item.title && item.url)
      .map((item, i) => ({
        id: 'soundcloud:' + (item.id || q + ':' + i),
        source: 'parser',
        title: item.title,
        artist: item.artist,
        artistId: null,
        album: '',
        albumId: null,
        artwork: item.artwork || '',
        duration: item.duration || 0,
        _parserUrl: item.url,
      })),
  );
  // VK (experiment, off unless the admin flag is on): same direct-URL path as SoundCloud.
  const vkTracks = noAi(
    (vk.data || [])
      .filter((item) => item.title && item.url)
      .map((item, i) => ({
        id: 'vk:' + (item.id || q + ':' + i),
        source: 'parser',
        title: item.title,
        artist: item.artist,
        artistId: null,
        album: '',
        albumId: null,
        artwork: item.artwork || '',
        duration: item.duration || 0,
        _parserUrl: item.url,
      })),
  );
  if (error) return <ErrorBox retry={retry} />;
  if (!data) return <div className="view">{loading && <Skeleton />}</div>;
  // Blink's own releases (Spherical and partners) come first, as ordinary results.
  const appleKeys = new Set(data.tracks.map(trackKey));
  const extra = (more.data || []).filter((t) => !appleKeys.has(trackKey(t)));
  // Merge parser tracks into main list — they fill gaps Apple doesn't have.
  // Deduplicate by trackKey so the same song doesn't appear twice.
  const allKeys = new Set([...data.tracks.map(trackKey), ...extra.map(trackKey)]);
  const parserExtra = mp3tracks.filter((t) => t.title && t.artist && !allKeys.has(trackKey(t)));
  // Merge APIBlink tracks — they fill gaps, especially for Russian catalog.
  const apiblinkExtra = apiblinkTracks.filter((t) => t.title && t.artist && !allKeys.has(trackKey(t)) && !parserExtra.some(p => trackKey(p) === trackKey(t)));
  const allExtra = [...parserExtra, ...apiblinkExtra];
  // Apple first when it has the song; otherwise the other catalogs lead.
  // Нейротреки are dropped from every catalog (Blink's own releases are moderated).
  // If Yandex is the primary source, APIBlink results come first.
  const merged = yandexPrimary
    ? [...exclusive, ...noAi([...apiblinkExtra, ...data.tracks, ...extra, ...parserExtra])]
    : data.tracks.length >= 3
    ? [...exclusive, ...noAi([...data.tracks, ...extra, ...allExtra])]
    : [...exclusive, ...noAi([...extra, ...data.tracks, ...allExtra])];
  // Familiar tracks first, then best match, then popularity; ones that failed to play are hidden.
  const tracks = rankTracks(playable(merged), q, { likes, recent });
  const { albums, artists } = data;
  if (!tracks.length && !albums.length && !artists.length && !exclusive.length && !free.length && !more.loading)
    return (
      <div className="view empty">
        <div>
          <h2>Ничего не нашлось</h2>
          <div>Попробуйте написать название иначе или только имя артиста.</div>
        </div>
      </div>
    );
  const topArtist = artists[0];
  return (
    <div className="view" style={{ opacity: loading ? 0.6 : 1, transition: 'opacity .2s ease' }}>
      <div className="search-top">
        {topArtist ? (
          <motion.div {...rise(0)}>
            <div className="section-head">
              <h2 className="h-section">Лучшее совпадение</h2>
            </div>
            <button className="top-card" style={{ width: '100%' }} onClick={() => go('artist', { id: topArtist.id })}>
              <Cover src={topArtist.artwork} size={300} />
              <div>
                <div className="name">{topArtist.name}</div>
                <div className="label">{topArtist.genre ? `Артист · ${topArtist.genre}` : 'Артист'}</div>
              </div>
            </button>
          </motion.div>
        ) : null}
        <motion.div {...rise(1)} style={{ minWidth: 0 }}>
          <div className="section-head">
            <h2 className="h-section">Треки</h2>
          </div>
          <div className="tracks">
            {tracks.slice(0, 5).map((t, i) => (
              <TrackRow key={t.id} track={t} list={tracks} index={i} showAlbum={false} />
            ))}
          </div>
        </motion.div>
      </div>

      {free.length > 0 && (
        <section className="section">
          <div className="section-head">
            <h2 className="h-section">Свободная музыка · Jamendo</h2>
            <span className="label">без YouTube, Creative Commons</span>
          </div>
          <div className="tracks">
            {free.slice(0, 8).map((t, i) => (
              <TrackRow key={t.id} track={t} list={free} index={i} showAlbum={false} />
            ))}
          </div>
        </section>
      )}

      {scTracks.length > 0 && (
        <section className="section">
          <div className="section-head">
            <h2 className="h-section">SoundCloud</h2>
            <span className="label">независимые артисты и ремиксы</span>
          </div>
          <div className="tracks">
            {scTracks.slice(0, 8).map((t, i) => (
              <TrackRow key={t.id} track={t} list={scTracks} index={i} showAlbum={false} />
            ))}
          </div>
        </section>
      )}

      {vkTracks.length > 0 && (
        <section className="section">
          <div className="section-head">
            <h2 className="h-section">VK</h2>
            <span className="label">эксперимент</span>
          </div>
          <div className="tracks">
            {vkTracks.slice(0, 8).map((t, i) => (
              <TrackRow key={t.id} track={t} list={vkTracks} index={i} showAlbum={false} />
            ))}
          </div>
        </section>
      )}

      {albums.length > 0 && (
        <section className="section">
          <div className="section-head">
            <h2 className="h-section">Альбомы и синглы</h2>
          </div>
          <div className="row-scroll">
            {albums.map((a) => (
              <AlbumCard key={a.id} album={a} onPlay={(al) => playAlbum(al, country)} />
            ))}
          </div>
        </section>
      )}

      {artists.length > 1 && (
        <section className="section">
          <div className="section-head">
            <h2 className="h-section">Артисты</h2>
          </div>
          <div className="row-scroll">
            {artists.map((a) => (
              <ArtistCard key={a.id} artist={a} />
            ))}
          </div>
        </section>
      )}

      {tracks.length > 5 && (
        <section className="section">
          <div className="section-head">
            <h2 className="h-section">Ещё треки</h2>
          </div>
          <div className="tracks">
            {tracks.slice(5).map((t, i) => (
              <TrackRow key={t.id} track={t} list={tracks} index={i + 5} />
            ))}
          </div>
        </section>
      )}
    </div>
  );
}

// ---------------- Artist ----------------

export function Artist({ id }) {
  const country = useStore((s) => s.settings.country);
  const { data, error, retry } = useAsync(`artist:${country}:${id}`, () => api.artist(id, country));
  const [more, setMore] = useState(false);
  const [glow, setGlow] = useState(null);
  useEffect(() => {
    if (data && data.artwork) paletteFor(data.artwork).then(setGlow);
  }, [data && data.artwork]);
  if (error) return <ErrorBox retry={retry} />;
  if (!data)
    return (
      <div className="view">
        <div className="sk" style={{ height: 300, marginTop: 24, borderRadius: 24 }} />
        <Skeleton rows={5} />
      </div>
    );
  const albums = data.albums.filter((a) => a.type === 'Альбом');
  const singles = data.albums.filter((a) => a.type !== 'Альбом');
  const top = playable(data.tracks);
  return (
    <div className="view">
      <div className="artist-hero" style={glow ? { '--hA': glow.glowA, '--hB': glow.glowB } : null}>
        <div className="glow" />
        {data.artwork && (
          <motion.div
            className="art"
            style={{ backgroundImage: `url(${api.art(data.artwork, 1000)})` }}
            initial={{ opacity: 0, scale: 1.06 }}
            animate={{ opacity: 1, scale: 1 }}
            transition={{ duration: 1.1, ease }}
          />
        )}
        <motion.div className="inner" {...rise(0)}>
          <div className="label">{data.genre || 'Артист'}</div>
          <h1 className={data.name.length > 14 ? 'long' : ''}>{data.name}</h1>
          <div className="meta">
            {[albums.length ? plural(albums.length, 'альбом', 'альбома', 'альбомов') : null, singles.length ? plural(singles.length, 'сингл', 'сингла', 'синглов') : null, data.albums[0] && data.albums[0].year ? `последний релиз ${data.albums[0].year}` : null]
              .filter(Boolean)
              .join(' · ')}
          </div>
          <div className="actions">
            <button className="btn primary" disabled={!top.length} onClick={() => playTrack(top[0], top, 0)}>
              <Icon name="play" size={18} /> Слушать
            </button>
            <button
              className="btn ghost"
              disabled={!top.length}
              onClick={() => {
                const s = shuffled(top);
                playTrack(s[0], s, 0);
              }}
            >
              <Icon name="shuffle" size={18} /> Вперемешку
            </button>
          </div>
        </motion.div>
      </div>

      {top.length > 0 && (
        <section className="section" style={{ marginTop: 40 }}>
          <div className="section-head">
            <h2 className="h-section">Популярное</h2>
          </div>
          <div className="tracks">
            {(more ? top : top.slice(0, 6)).map((t, i) => (
              <TrackRow key={t.id} track={t} list={top} index={i} />
            ))}
          </div>
          {top.length > 6 && (
            <button className="link" style={{ marginTop: 12, marginLeft: 10 }} onClick={() => setMore(!more)}>
              {more ? 'Свернуть' : 'Показать ещё'}
            </button>
          )}
        </section>
      )}

      {albums.length > 0 && (
        <section className="section">
          <div className="section-head">
            <h2 className="h-section">Альбомы</h2>
          </div>
          <div className="grid-cards">
            {albums.map((a) => (
              <AlbumCard key={a.id} album={a} onPlay={(al) => playAlbum(al, country)} />
            ))}
          </div>
        </section>
      )}
      {singles.length > 0 && (
        <section className="section">
          <div className="section-head">
            <h2 className="h-section">Синглы и EP</h2>
          </div>
          <div className="grid-cards">
            {singles.map((a) => (
              <AlbumCard key={a.id} album={a} onPlay={(al) => playAlbum(al, country)} />
            ))}
          </div>
        </section>
      )}
    </div>
  );
}

// ---------------- Album ----------------

export function Album({ id }) {
  const country = useStore((s) => s.settings.country);
  const { data, error, retry } = useAsync(`album:${country}:${id}`, () => api.album(id, country));
  if (error) return <ErrorBox retry={retry} />;
  if (!data)
    return (
      <div className="view">
        <div className="page-head">
          <div className="sk" style={{ aspectRatio: 1, borderRadius: 24 }} />
          <div className="sk" style={{ height: 120 }} />
        </div>
        <Skeleton rows={6} />
      </div>
    );
  const t = data.tracks;
  return (
    <div className="view">
      <div className="page-head">
        <motion.div initial={{ opacity: 0, scale: 0.96 }} animate={{ opacity: 1, scale: 1 }} transition={{ duration: 0.5, ease }}>
          <Cover src={data.artwork} size={600} />
        </motion.div>
        <motion.div {...rise(1)} style={{ minWidth: 0 }}>
          <div className="label">
            {data.type}
            {data.genre ? ` · ${data.genre}` : ''}
          </div>
          <h1>{data.title}</h1>
          <div className="sub">
            <button onClick={() => data.artistId && go('artist', { id: data.artistId })}>{data.artist}</button>
            <span>{data.year}</span>
            <span>{plural(t.length, 'трек', 'трека', 'треков')}</span>
            <span>{totalTime(t)}</span>
          </div>
          <div className="actions">
            <button className="btn primary" disabled={!t.length} onClick={() => playTrack(t[0], t, 0)}>
              <Icon name="play" size={18} /> Слушать
            </button>
            <button
              className="btn ghost"
              disabled={!t.length}
              onClick={() => {
                const s = shuffled(t);
                playTrack(s[0], s, 0);
              }}
            >
              <Icon name="shuffle" size={18} /> Вперемешку
            </button>
            <button
              className="icon-btn"
              title="Сохранить как плейлист"
              onClick={() => {
                if (createPlaylist(data.title, t)) toast(`Плейлист «${data.title}» создан`);
              }}
            >
              <Icon name="plus" size={22} />
            </button>
          </div>
        </motion.div>
      </div>
      <section className="section" style={{ marginTop: 40 }}>
        <div className="tracks">
          {t.map((tr, i) => (
            <TrackRow key={tr.id} track={tr} list={t} index={i} number={tr.no} showAlbum={false} />
          ))}
        </div>
        {data.copyright && <div className="fine" style={{ marginTop: 24, paddingLeft: 10 }}>{data.copyright}</div>}
      </section>
    </div>
  );
}

// ---------------- Library ----------------

function Mosaic({ tracks, cover }) {
  if (cover) return <Cover src={cover} size={400} />;
  const arts = [...new Set(tracks.map((t) => t.artwork))].slice(0, 4);
  if (arts.length < 4) return <Cover src={arts[0]} size={400} />;
  return (
    <div className="cover">
      <div className="mosaic">
        {arts.map((a) => (
          <img key={a} src={a.replace(/\/\d+x\d+bb\.jpg$/, '/200x200bb.jpg')} alt="" draggable={false} />
        ))}
      </div>
    </div>
  );
}

export function Library() {
  const likes = useStore((s) => s.likes);
  const playlists = useStore((s) => s.playlists);
  const recent = useStore((s) => s.recent);
  const saved = useStore((s) => s.saved || []);
  const plus = usePlus();
  const newPlaylist = () => {
    const p = createPlaylist(`Плейлист ${playlists.length + 1}`);
    if (p) go('playlist', { id: p.id });
  };
  return (
    <div className="view">
      <motion.h1 {...rise(0)} className="lib-title">
        Моя музыка
      </motion.h1>
      <button className="link import-link" onClick={() => store.set({ sheet: 'import' })}>
        <Icon name="plus" size={16} /> Перенести музыку из другого сервиса
      </button>
      <PlusPromo />
      <FriendsStrip />
      <div className="lib-grid">
        <motion.button className="liked-tile" {...rise(1)} onClick={() => go('playlist', { id: 'likes' })}>
          <Icon name="heartFill" size={28} className="heart" />
          <div className="big">Любимое</div>
          <div className="peek">
            {likes.length
              ? `${plural(likes.length, 'трек', 'трека', 'треков')} · ${likes
                  .slice(0, 4)
                  .map((t) => t.artist)
                  .filter((v, i, a) => a.indexOf(v) === i)
                  .join(', ')}`
              : 'Нажимайте на сердце у трека, и он появится здесь'}
          </div>
        </motion.button>
        {(plus || saved.length > 0) && (
          <motion.div className="card saved-card" role="button" tabIndex={0} {...rise(2)} onClick={() => go('playlist', { id: 'saved' })}>
            <div style={{ marginBottom: 12, position: 'relative' }}>
              {saved.length ? <Mosaic tracks={saved} /> : <div className="saved-empty"><Icon name="download" size={40} /></div>}
              <span className="saved-mark"><Icon name="download" size={14} /></span>
            </div>
            <div className="t">Сохранённые треки</div>
            <div className="s">{saved.length ? `${plural(saved.length, 'трек', 'трека', 'треков')} · без интернета` : 'Играют без интернета'}</div>
          </motion.div>
        )}
        {playlists.map((p, i) => (
          <motion.div key={p.id} className="card" role="button" tabIndex={0} {...rise(i + 2)} onClick={() => go('playlist', { id: p.id })}>
            <div style={{ marginBottom: 12 }}>
              <Mosaic tracks={p.tracks} cover={p.cover} />
            </div>
            <div className="t">{p.name}</div>
            <div className="s">{plural(p.tracks.length, 'трек', 'трека', 'треков')}</div>
          </motion.div>
        ))}
        <motion.div {...rise(playlists.length + 2)}>
          <button className="new-tile" style={{ width: '100%' }} onClick={newPlaylist}>
            <div>
              <Icon name="plus" size={28} />
              Новый плейлист
            </div>
          </button>
        </motion.div>
      </div>

      {recent.length > 0 && (
        <section className="section">
          <div className="section-head">
            <h2 className="h-section">История</h2>
            <button className="link" onClick={() => store.set({ recent: [] })}>
              Очистить
            </button>
          </div>
          <div className="tracks">
            {recent.slice(0, 30).map((t, i) => (
              <TrackRow key={t.id} track={t} list={recent} index={i} />
            ))}
          </div>
        </section>
      )}
    </div>
  );
}

// Saving for offline: overall progress of the queue, with pause and cancel.
function DownloadBar() {
  const dl = useStore((s) => s.dl);
  if (!dl || !dl.total) return null;
  const pct = Math.round(((dl.done + (dl.paused ? 0 : dl.pct || 0)) / dl.total) * 100);
  return (
    <motion.div className="dl-bar" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.3, ease }}>
      <Icon name="download" size={18} className="dl-ico" />
      <div className="dl-info">
        <div className="dl-k">
          {dl.paused ? 'Загрузка на паузе' : 'Сохраняю для офлайна'} · {Math.min(dl.done + 1, dl.total)} из {dl.total}
        </div>
        <div className="dl-track">
          <span style={{ width: `${pct}%` }} />
        </div>
      </div>
      <span className="dl-pct">{pct}%</span>
      <button className="btn ghost" onClick={dl.paused ? resumeDownloads : pauseDownloads}>
        <Icon name={dl.paused ? 'play' : 'pause'} size={16} /> {dl.paused ? 'Продолжить' : 'Пауза'}
      </button>
      <button className="icon-btn" title="Отменить загрузку" onClick={cancelDownloads}>
        <Icon name="close" size={18} />
      </button>
    </motion.div>
  );
}

export function Playlist({ id }) {
  const likes = useStore((s) => s.likes);
  const pl = useStore((s) => s.playlists.find((p) => p.id === id));
  const [editing, setEditing] = useState(false);
  const signedIn = useStore((s) => !!s.user);
  const isLikes = id === 'likes';
  const isSavedList = id === 'saved';
  const fixed = isLikes || isSavedList;
  const saved = useStore((s) => s.saved || []);
  const [from, setFrom] = useState('blink');
  const showYandex = isLikes && yandexTab && from === 'yandex';
  // The public link, when this playlist is shared (undefined while checking).
  const [shared, setShared] = useState(undefined);
  useEffect(() => {
    setShared(undefined);
    if (fixed || !signedIn) return setShared(null);
    let live = true;
    sharedState({ id }).then((r) => live && setShared(r ? shareLink(r.code) : null), () => live && setShared(null));
    return () => {
      live = false;
    };
  }, [id, fixed, signedIn]);
  // A shared playlist keeps its public copy current.
  const prevPl = useRef(pl);
  useEffect(() => {
    const changed = prevPl.current !== pl;
    prevPl.current = pl;
    if (!changed || !shared || !pl) return;
    const t = setTimeout(() => sharePlaylist(pl).catch(() => {}), 2000);
    return () => clearTimeout(t);
  }, [pl, shared]);
  const [coverBusy, setCoverBusy] = useState(false);
  const setCover = async (file) => {
    if (!file || coverBusy) return;
    setCoverBusy(true);
    try {
      const url = await uploadPlaylistCover(file);
      store.set({ playlists: store.get().playlists.map((p) => (p.id === id ? { ...p, cover: url } : p)) });
      toast('Обложка обновлена');
    } catch (e) {
      toast(e.status === 401 ? 'Войдите в аккаунт, чтобы поставить обложку' : humanError(e), 'error');
    } finally {
      setCoverBusy(false);
    }
  };
  const share = async () => {
    try {
      const link = shared || (await sharePlaylist(store.get().playlists.find((p) => p.id === id)));
      setShared(link);
      await navigator.clipboard.writeText(link).catch(() => {});
      toast('Ссылка на плейлист скопирована');
    } catch (e) {
      toast(humanError(e), 'error');
    }
  };
  const unshare = async () => {
    if (!(await ask({ title: 'Закрыть доступ?', text: 'Ссылка на плейлист перестанет открываться. Копии, которые уже добавили себе, останутся у людей.', ok: 'Закрыть доступ', danger: true, icon: 'close' }))) return;
    try {
      await unsharePlaylist({ id });
      setShared(null);
      toast('Доступ по ссылке закрыт');
    } catch (e) {
      toast(humanError(e), 'error');
    }
  };
  if (!fixed && !pl)
    return (
      <div className="view empty">
        <div>
          <h2>Плейлист удалён</h2>
          <button className="btn ghost" onClick={() => go('library')}>
            К моей музыке
          </button>
        </div>
      </div>
    );
  const name = isLikes ? 'Любимое' : isSavedList ? 'Сохранённые треки' : pl.name;
  const tracks = isLikes ? likes : isSavedList ? saved : pl.tracks;
  return (
    <div className="view">
      <div className="page-head">
        <motion.div initial={{ opacity: 0, scale: 0.96 }} animate={{ opacity: 1, scale: 1 }} transition={{ duration: 0.5, ease }}>
          {fixed ? (
            <div className="cover" style={{ background: 'linear-gradient(135deg, var(--gA), var(--gC))', display: 'grid', placeItems: 'center' }}>
              <Icon name={isLikes ? 'heartFill' : 'download'} size={72} />
            </div>
          ) : (
            <label className="cover-edit" title="Сменить обложку">
              <Mosaic tracks={tracks} cover={pl.cover} />
              <span className="cover-edit-ico">
                <Icon name="edit" size={18} /> Обложка
              </span>
              <input
                type="file"
                accept="image/jpeg,image/png,image/webp"
                hidden
                disabled={coverBusy}
                onChange={(e) => {
                  setCover(e.target.files[0]);
                  e.target.value = '';
                }}
              />
            </label>
          )}
        </motion.div>
        <motion.div {...rise(1)} style={{ minWidth: 0 }}>
          <div className="label">Плейлист</div>
          {editing ? (
            <input
              autoFocus
              defaultValue={name}
              className="h1-edit"
              style={{ fontFamily: 'var(--display)', fontWeight: 600, fontSize: 'clamp(32px, 4vw, 60px)', letterSpacing: '-0.04em', background: 'none', border: 0, borderBottom: '2px solid var(--accent)', outline: 'none', width: '100%', margin: '10px 0 14px' }}
              onBlur={(e) => {
                renamePlaylist(id, e.target.value.trim() || name);
                setEditing(false);
              }}
              onKeyDown={(e) => {
                if (e.key === 'Enter') e.currentTarget.blur();
                if (e.key === 'Escape') setEditing(false);
              }}
            />
          ) : (
            <h1 onDoubleClick={() => !fixed && setEditing(true)}>{name}</h1>
          )}
          <div className="sub">
            <span>{plural(tracks.length, 'трек', 'трека', 'треков')}</span>
            {tracks.length > 0 && <span>{totalTime(tracks)}</span>}
          </div>
          <div className="actions">
            <button className="btn primary" disabled={!tracks.length} onClick={() => playTrack(tracks[0], tracks, 0)}>
              <Icon name="play" size={18} /> Слушать
            </button>
            <button
              className="btn ghost"
              disabled={!tracks.length}
              onClick={() => {
                const s = shuffled(tracks);
                playTrack(s[0], s, 0);
              }}
            >
              <Icon name="shuffle" size={18} /> Вперемешку
            </button>
            {isLikes && tracks.length > 0 && (
              <button className="btn ghost" title="Треки будут играть без интернета (Blink+)" onClick={() => saveTracks(tracks)}>
                <Icon name="download" size={18} /> Сохранить для офлайна
              </button>
            )}
            {!fixed && (
              <>
                <button className="icon-btn" title={shared ? 'Скопировать ссылку' : 'Поделиться ссылкой'} onClick={share}>
                  <Icon name="external" size={19} />
                </button>
                {shared && (
                  <button className="btn ghost" title="Ссылка перестанет открываться" onClick={unshare}>
                    Закрыть доступ
                  </button>
                )}
                <button className="icon-btn" title="Переименовать" onClick={() => setEditing(true)}>
                  <Icon name="edit" size={19} />
                </button>
                <button
                  className="icon-btn"
                  title="Удалить плейлист"
                  onClick={async () => {
                    if (await ask({ title: `Удалить «${name}»?`, text: 'Плейлист пропадёт из библиотеки на всех устройствах. Треки останутся в каталоге.', ok: 'Удалить', danger: true })) {
                      deletePlaylist(id);
                      go('library');
                    }
                  }}
                >
                  <Icon name="trash" size={19} />
                </button>
              </>
            )}
          </div>
        </motion.div>
      </div>
      {fixed && <DownloadBar />}
      <section className="section" style={{ marginTop: 40 }}>
        {isLikes && yandexTab && (
          <div className="seg-mini" role="tablist" style={{ margin: '0 0 20px' }}>
            {[['blink', 'Blink'], ['yandex', 'Яндекс Музыка']].map(([k, label]) => (
              <button key={k} role="tab" aria-selected={from === k} className={from === k ? 'on' : ''} onClick={() => setFrom(k)}>
                {label}
              </button>
            ))}
          </div>
        )}
        {showYandex ? (
          <YandexLikes />
        ) : tracks.length ? (
          <div className="tracks">
            {tracks.map((t, i) => (
              <TrackRow key={t.id} track={t} list={tracks} index={i} playlistId={fixed ? null : id} />
            ))}
          </div>
        ) : (
          <div className="err-box">
            <h3>Пока пусто</h3>
            <p>{isSavedList ? 'В «Любимом» нажмите «Сохранить для офлайна» или выберите «Сохранить» в меню трека. Нужен Blink+.' : isLikes ? 'Нажмите на сердце у любого трека.' : 'Нажмите правой кнопкой на трек и выберите «Добавить в плейлист».'}</p>
            <button className="btn ghost" onClick={() => go('search')}>
              <Icon name="search" size={18} /> Найти музыку
            </button>
          </div>
        )}
      </section>
    </div>
  );
}

