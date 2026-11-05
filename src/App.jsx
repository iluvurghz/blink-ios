import { useEffect, useRef, useState } from 'react';
import { launchFeel } from './lib/haptic.js';
import { renderGoogleButton, gisUsable, inAppBrowser, warmGis } from './lib/gsignin.js';
import { motion, AnimatePresence, MotionConfig } from 'motion/react';
import Icon from './ui/Icon.jsx';
import Capsule from './ui/Capsule.jsx';
import Tooltip from './ui/Tooltip.jsx';
import Confirm, { ask } from './ui/Confirm.jsx';
import Stage, { knownLines } from './ui/Stage.jsx';
import { Home, Overview, FlashHost, Search, Artist, Album, Library, Playlist, Editorial } from './ui/views.jsx';
import { PlusChip, PlusPage, PlusNavButton } from './ui/Plus.jsx';
import SupportCard, { KeeperChip } from './ui/Support.jsx';
import { SupportPage, BugSheet } from './ui/Help.jsx';
import { refreshSupport } from './lib/support.js';
import { refreshPlus, usePlus } from './lib/plus.js';
import { BlinkArtist, MyPage } from './ui/Profile.jsx';
import { store, useStore, go, goBack, toggleLike, addToPlaylist, createPlaylist, removeFromPlaylist, toast } from './lib/store.js';
import { playTrack, toggle, next, prev, seek, playNext, addToQueue, removeFromQueue, setVolume, initMedia, playFiles } from './lib/player.js';
import { clock } from './lib/store.js';
import { paletteFor, DEFAULT_PALETTE } from './lib/color.js';
import { checkKey, lookupTracks } from './lib/api.js';
import { isDesktop, signIn, signUp, signInGoogle, signInGoogleToken, signOut, fetchStats, reloadUser, fetchShared, listDevices, revokeDevice } from './lib/cloud.js';
import { uploadAvatar, saveName as saveNickname } from './lib/catalog.js';
import { plural, Cover, Switch } from './ui/common.jsx';
import StoryCard, { openStory } from './ui/StoryCard.jsx';
import { shareTrack } from './ui/share.js';
import InstallHint from './ui/InstallHint.jsx';
import TogetherSheet from './ui/Together.jsx';
import ImportSheet from './ui/Import.jsx';
import StatusSheet, { StatusGlyph } from './ui/StatusSheet.jsx';
import { runStatus } from './lib/status.js';
import { syncRelay } from './lib/relay.js';
import IslandTab, { useIslandAutostart } from './ui/IslandTab.jsx';
import GameSwitch from './ui/GameSwitch.jsx';
import { switchGame, resumeAfterSwitch } from './lib/gamemode.js';
import { markAi } from './lib/aiFilter.js';
import { saveTrack, removeSaved, unqueue, savedBytes, clearSaved } from './lib/offline.js';

import { humanError } from './lib/errors.js';
import { proxied } from './lib/img.js';
const ease = [0.23, 1, 0.32, 1];

function useMaximized() {
  const [max, setMax] = useState(false);
  useEffect(() => {
    window.blink.isMaximized().then(setMax);
    window.blink.onWinState((s) => setMax(s.maximized));
  }, []);
  return max;
}

// iPhone: a small Blink mark in the status-bar row, right where the Dynamic Island or the notch is.
// In use the island covers it; on a screenshot it shows, like other music apps do. Drawn only where
// the page reaches under the status bar (the home-screen app); elsewhere its row has no height.
function IslandMark() {
  const on = useStore((s) => s.settings.brandMark !== false);
  if (!on) return null;
  return (
    <div className="island-mark" aria-hidden="true">
      <span>
        b<i />
      </span>
    </div>
  );
}

function Wordmark() {
  const trackId = useStore((s) => s.track && s.track.id);
  const [k, setK] = useState(0);
  useEffect(() => setK((x) => x + 1), [trackId]);
  return (
    <button className="wordmark" onClick={() => go('home')} title="Главная">
      blink<span key={k} className="dot blink" />
      <span className="beta">beta</span>
    </button>
  );
}

function TitleBar() {
  const view = useStore((s) => s.view.name);
  const canBack = useStore((s) => s.back.length > 0);
  const query = useStore((s) => s.query);
  const onStage = useStore((s) => s.stage);
  const max = useMaximized();
  const input = useRef(null);

  useEffect(() => {
    window.__focusSearch = (ch) => {
      if (store.get().view.name !== 'search') go('search');
      if (ch) store.set({ query: ch });
      requestAnimationFrame(() => input.current && input.current.focus());
    };
  }, []);

  const tabs = [
    ['home', 'Главная', 'home'],
    ['library', 'Моё', 'library'],
  ];
  const activeTab = view === 'playlist' ? 'library' : view === 'editorial' ? 'home' : view;

  return (
    <header className={'titlebar' + (onStage ? ' on-stage' : '') + (view === 'search' ? ' searching' : '')} onDoubleClick={(e) => e.target === e.currentTarget && window.blink.maximize()}>
      <div className="left">
        <button className="icon-btn" title="Назад (Alt+←)" disabled={!canBack} onClick={goBack}>
          <Icon name="back" size={20} />
        </button>
        <Wordmark />
      </div>
      <nav className="nav">
        {tabs.map(([id, label, icon]) => (
          <button key={id} className={'tab' + (activeTab === id ? ' active' : '')} onClick={() => go(id)}>
            {activeTab === id && <motion.span layoutId="nav-pill" className="pill" transition={{ type: 'spring', duration: 0.45, bounce: 0.15 }} />}
            <Icon name={icon} size={17} />
            <span>{label}</span>
          </button>
        ))}
        {/* Phones: «Главная» is «Вспышка» alone, the chart and the rest are a tab of their own. */}
        <button className={'tab m-charts' + (view === 'charts' ? ' active' : '')} onClick={() => go('charts')}>
          {view === 'charts' && <motion.span layoutId="nav-pill" className="pill" transition={{ type: 'spring', duration: 0.45, bounce: 0.15 }} />}
          <Icon name="disc" size={17} />
          <span>Чарт</span>
        </button>
        {/* Phones: «Поиск» is a tab of the bottom bar; the search field itself sits on top of the search screen. */}
        <button className={'tab m-only' + (view === 'search' ? ' active' : '')} onClick={() => go('search')}>
          {view === 'search' && <motion.span layoutId="nav-pill" className="pill" transition={{ type: 'spring', duration: 0.45, bounce: 0.15 }} />}
          <Icon name="search" size={17} />
          <span>Поиск</span>
        </button>
        <label className="searchbox" onClick={() => view !== 'search' && go('search')}>
          <Icon name="search" size={17} />
          <input
            ref={input}
            value={query}
            placeholder="Трек, артист, альбом"
            spellCheck={false}
            onFocus={() => view !== 'search' && go('search')}
            onChange={(e) => store.set({ query: e.target.value })}
            onKeyDown={(e) => {
              if (e.key === 'Escape') {
                if (query) store.set({ query: '' });
                else e.currentTarget.blur();
              }
            }}
          />
          {!query && <kbd>Ctrl K</kbd>}
          {query && (
            <button className="icon-btn" style={{ width: 24, height: 24 }} onClick={() => store.set({ query: '' })} title="Очистить">
              <Icon name="close" size={14} />
            </button>
          )}
        </label>
      </nav>
      <div className="right">
        {!isDesktop && (
          <a className="get-app" href="https://blinkmusic.cc/download/" target="_blank" rel="noopener">
            Приложение для Windows
          </a>
        )}
        <PlusNavButton />
        <SupportButton active={view === 'support'} />
        <button className={'icon-btn' + (view === 'settings' || view === 'params' ? ' active' : '')} title="Настройки и параметры" onClick={() => go('settings')}>
          <Icon name="settings" size={19} />
        </button>
        <AccountButton />
        {isDesktop && <div className="winctl">
          <button title="Свернуть" onClick={() => window.blink.minimize()}>
            <Icon name="min" size={16} stroke={1.5} />
          </button>
          <button title={max ? 'Восстановить' : 'Развернуть'} onClick={() => window.blink.maximize()}>
            <Icon name={max ? 'restore' : 'max'} size={15} stroke={1.5} />
          </button>
          <button className="x" title="Закрыть" onClick={() => window.blink.close()}>
            <Icon name="close" size={16} stroke={1.5} />
          </button>
        </div>}
      </div>
    </header>
  );
}

function Avatar({ user, big }) {
  const plus = usePlus();
  // No photo (or it won't load): the first letter of the name in a round placeholder, never a blank oval.
  const [bad, setBad] = useState(false);
  useEffect(() => setBad(false), [user.avatar]);
  return (
    <span className={'avatar on' + (big ? ' big' : '') + (plus ? ' plus' : '')}>
      {user.avatar && !bad ? <img src={proxied(user.avatar)} alt="" referrerPolicy="no-referrer" decoding="async" onError={() => setBad(true)} /> : (user.name || '?').slice(0, 1).toUpperCase()}
    </span>
  );
}

// Avatar and nickname are editable right in the account sheet.
function ProfileHead({ user }) {
  const [name, setName] = useState(user.name || '');
  useEffect(() => setName(user.name || ''), [user.name]);
  const [busy, setBusy] = useState(false);
  const saveName = async () => {
    const v = name.trim();
    if (!v || v === user.name) return setName(user.name || '');
    try {
      await saveNickname(v);
      await reloadUser();
      store.set({ toast: { text: 'Ник сохранён', tone: 'info', id: Date.now() } });
    } catch (e) {
      store.set({ toast: { text: humanError(e), tone: 'error', id: Date.now() } });
    }
  };
  const pickAvatar = async (file) => {
    if (!file) return;
    setBusy(true);
    try {
      await uploadAvatar(file);
      await reloadUser();
      store.set({ toast: { text: 'Аватарка обновлена', tone: 'info', id: Date.now() } });
    } catch (e) {
      store.set({ toast: { text: humanError(e), tone: 'error', id: Date.now() } });
    }
    setBusy(false);
  };
  return (
    <div className="acc-head">
      <label className={'avatar-edit' + (busy ? ' busy' : '')} title="Сменить аватарку">
        <Avatar user={user} big />
        <span className="avatar-edit-ico">
          <Icon name="edit" size={16} />
        </span>
        <input type="file" accept="image/jpeg,image/png,image/webp" hidden onChange={(e) => pickAvatar(e.target.files[0])} />
      </label>
      <div style={{ minWidth: 0, flex: 1 }}>
        <input
          className="name-edit"
          value={name}
          maxLength={40}
          onChange={(e) => setName(e.target.value)}
          onBlur={saveName}
          onKeyDown={(e) => e.key === 'Enter' && e.currentTarget.blur()}
          title="Нажмите, чтобы изменить ник"
        />
        <div className="acc-sub">
          <PlusChip />
          <KeeperChip />
          <span>{user.email}</span>
        </div>
      </div>
    </div>
  );
}

function AccountButton() {
  const user = useStore((s) => s.user);
  return (
    <button className="avatar-btn" title={user ? user.email : 'Войти'} onClick={() => store.set({ sheet: 'account' })}>
      {user ? (
        <Avatar user={user} />
      ) : (
        <span className="avatar">
          <Icon name="user" size={17} />
        </span>
      )}
    </button>
  );
}

const AUTH_ERRORS = {
  'Invalid login credentials': 'Неверная почта или пароль',
  'User already registered': 'Такая почта уже зарегистрирована, войдите',
  'Email not confirmed': 'Подтвердите почту: письмо уже у вас во входящих',
};

// On the site Google's own button signs in right on blinkmusic.cc (lib/gsignin.js); the app, the
// iPhone home-screen app and a failed load keep Blink's button and the redirect way.
function GoogleSignIn({ onDone, onError }) {
  const box = useRef(null);
  const [gis, setGis] = useState(!isDesktop && gisUsable() && !inAppBrowser());
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (!gis) return;
    renderGoogleButton(
      box.current,
      (token, nonce) =>
        signInGoogleToken(token, nonce).then(
          () => onDone(),
          () => onError('Не получилось войти через Google, попробуйте ещё раз'),
        ),
      // Google's button fills our 52px frame (6px inside it), in the same colour as the frame.
      box.current.offsetWidth - 12,
    ).catch(() => setGis(false));
  }, [gis]);
  if (inAppBrowser())
    return <div className="field-err">Google не пускает из встроенного браузера. Откройте blinkmusic.cc в Safari или Chrome, или войдите по почте ниже.</div>;
  if (gis) return <div ref={box} className="gsi-box" />;
  return (
        <button
          className={'btn google' + (busy ? ' busy' : '')}
          disabled={busy}
          onClick={() => {
            setBusy(true);
            signInGoogle().catch(() => {
              setBusy(false);
              onError('Вход через Google пока недоступен');
            });
          }}
        >
          <svg width="18" height="18" viewBox="0 0 48 48" aria-hidden="true">
            <path fill="#FFC107" d="M43.6 20.5H42V20H24v8h11.3C33.7 32.7 29.2 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.4-.4-3.5z" />
            <path fill="#FF3D00" d="m6.3 14.7 6.6 4.8C14.7 15.1 19 12 24 12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z" />
            <path fill="#4CAF50" d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.7 36 24 36c-5.2 0-9.6-3.3-11.3-8l-6.5 5C9.5 39.6 16.2 44 24 44z" />
            <path fill="#1976D2" d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.2C37 39.2 44 34 44 24c0-1.3-.1-2.4-.4-3.5z" />
          </svg>
          Продолжить с Google
        </button>
  );
}

function AccountSheet({ onClose }) {
  const user = useStore((s) => s.user);
  const reason = useStore((s) => s.authReason);
  const likes = useStore((s) => s.likes.length);
  const playlists = useStore((s) => s.playlists.length);
  const [mode, setMode] = useState('in');
  const [form, setForm] = useState({ name: '', email: '', password: '' });
  const [state, setState] = useState({});
  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value });

  if (user)
    return (
      <>
        <ProfileHead user={user} />
        <div className="set-row">
          <div>
            <div className="k">Синхронизация включена</div>
            <div className="d">
              {plural(likes, 'любимый трек', 'любимых трека', 'любимых треков')} и {plural(playlists, 'плейлист', 'плейлиста', 'плейлистов')} одинаковые в приложении и на сайте
            </div>
          </div>
          <Icon name="check" size={22} style={{ color: 'var(--accent)', flex: 'none' }} />
        </div>
        <div style={{ display: 'flex', gap: 10, marginTop: 8, flexWrap: 'wrap' }}>
          <button
            className="btn primary"
            onClick={() => {
              go('me');
              onClose();
            }}
          >
            Моя страница
          </button>
          <button
            className="btn ghost plus-btn"
            onClick={() => {
              go('plus');
              onClose();
            }}
          >
            Blink<b>+</b>
          </button>
          <button
            className="btn ghost"
            onClick={async () => {
              await signOut();
              onClose();
            }}
          >
            Выйти
          </button>
        </div>
      </>
    );

  const submit = async (e) => {
    e.preventDefault();
    if (!form.email.trim() || form.password.length < 6) return setState({ err: 'Введите почту и пароль от 6 символов' });
    setState({ busy: true });
    try {
      if (mode === 'in') {
        await signIn(form.email.trim(), form.password);
        onClose();
      } else {
        const r = await signUp(form.email.trim(), form.password, form.name.trim());
        if (r.session) onClose();
        else setState({ ok: 'Мы отправили письмо: подтвердите почту и войдите' });
      }
    } catch (err) {
      setState({ err: AUTH_ERRORS[err.message] || 'Не получилось, попробуйте ещё раз' });
    }
  };

  return (
    <>
      <div className="label" style={{ marginBottom: 12 }}>
        Аккаунт Blink
      </div>
      <h2>{reason === 'play' ? 'Войдите, чтобы слушать' : reason === 'save' ? 'Войдите, чтобы сохранять музыку' : mode === 'in' ? 'С возвращением' : 'Создайте аккаунт'}</h2>
      <p>{reason ? 'Это бесплатно и займёт полминуты. Любимое и плейлисты будут с вами в приложении и на сайте.' : 'Любимое, плейлисты и история будут одинаковыми в приложении и на сайте.'}</p>
      <GoogleSignIn onDone={onClose} onError={(err) => setState({ err })} />
      <div className="or">или по почте</div>
      <form onSubmit={submit} className="auth-form">
        {mode === 'up' && <input placeholder="Как вас зовут" value={form.name} onChange={set('name')} autoComplete="name" />}
        <input placeholder="Почта" type="email" value={form.email} onChange={set('email')} autoComplete="email" />
        <input placeholder="Пароль" type="password" value={form.password} onChange={set('password')} autoComplete={mode === 'in' ? 'current-password' : 'new-password'} />
        <button className="btn primary" disabled={state.busy}>
          {state.busy ? 'Секунду…' : mode === 'in' ? 'Войти' : 'Создать аккаунт'}
        </button>
      </form>
      <div className={state.ok ? 'field-ok' : 'field-err'}>{state.err || state.ok || ''}</div>
      <button className="link" onClick={() => (setMode(mode === 'in' ? 'up' : 'in'), setState({}))}>
        {mode === 'in' ? 'Нет аккаунта? Создать' : 'Уже есть аккаунт? Войти'}
      </button>
    </>
  );
}

function Ambient() {
  const art = useStore((s) => s.track && s.track.artwork);
  useEffect(() => {
    let alive = true;
    paletteFor(art).then((p) => {
      if (!alive) return;
      const root = document.documentElement.style;
      root.setProperty('--gA', p.glowA);
      root.setProperty('--gB', p.glowB);
      root.setProperty('--gC', p.glowC);
      root.setProperty('--accent', p.accent);
      root.setProperty('--accent-ink', p.accentInk);
    });
    return () => {
      alive = false;
    };
  }, [art]);
  return (
    <div className="ambient">
      <div className="blob a" />
      <div className="blob b" />
      <div className="blob c" />
      <div className="veil" />
    </div>
  );
}

// The YouTube iframe never moves in the DOM (that would reload it); it is only
// positioned over the clip slot when the stage shows the video.
// The YouTube iframe never moves in the DOM (that would reload it); it is only
// positioned over the clip slot when the stage shows the video.
function YtHost() {
  const ref = useRef(null);
  const clip = useStore((s) => s.stage && s.stageTab === 'clip' && s.videoMode === 'clip');
  useEffect(() => {
    let raf;
    const place = () => {
      const host = ref.current;
      const slot = document.getElementById('clip-slot');
      if (host) {
        if (clip && slot) {
          const r = slot.getBoundingClientRect();
          host.style.left = r.left + 'px';
          host.style.top = r.top + 'px';
          host.style.width = r.width + 'px';
          host.style.height = r.height + 'px';
        } else {
          host.style.left = '-2000px';
          host.style.width = '480px';
          host.style.height = '270px';
        }
      }
      raf = requestAnimationFrame(place);
    };
    raf = requestAnimationFrame(place);
    return () => cancelAnimationFrame(raf);
  }, [clip]);
  return (
    <>
      <div className={'yt-host' + (clip ? ' show' : '')} ref={ref}>
        <div id="yt-player" />
      </div>
      {/* Spare player for the overlapping crossfade: audio only, always off-screen. */}
      <div className="yt-host2">
        <div id="yt-player-2" />
      </div>
    </>
  );
}

function Menu() {
  const menu = useStore((s) => s.menu);
  const playlists = useStore((s) => s.playlists);
  const [pick, setPick] = useState(false);
  const ref = useRef(null);
  const [pos, setPos] = useState(null);

  useEffect(() => {
    setPick(false);
    setPos(null);
  }, [menu]);
  useEffect(() => {
    if (!menu || !ref.current) return;
    const r = ref.current.getBoundingClientRect();
    const x = Math.min(menu.x, window.innerWidth - r.width - 12);
    const y = Math.min(menu.y, window.innerHeight - r.height - 12);
    setPos({ x: Math.max(12, x), y: Math.max(12, y) });
  }, [menu, pick]);
  useEffect(() => {
    if (!menu) return;
    const close = (e) => {
      if (ref.current && ref.current.contains(e.target)) return;
      store.set({ menu: null });
    };
    const esc = (e) => e.key === 'Escape' && store.set({ menu: null });
    window.addEventListener('pointerdown', close, true);
    window.addEventListener('keydown', esc);
    window.addEventListener('blur', close);
    return () => {
      window.removeEventListener('pointerdown', close, true);
      window.removeEventListener('keydown', esc);
      window.removeEventListener('blur', close);
    };
  }, [menu]);

  const t = menu && menu.track;
  const liked = useStore((s) => !!t && s.likes.some((x) => x.id === t.id));
  const saved = useStore((s) => !!t && (s.saved || []).some((x) => x.id === t.id));
  const queued = useStore((s) => !!t && !!s.dl && s.dl.ids.includes(t.id));
  const done = (fn) => () => {
    fn();
    store.set({ menu: null });
  };
  // Phones: a bottom sheet with the track on top; a swipe down closes it.
  const phone = window.matchMedia('(max-width: 760px)').matches;
  const drag = useRef(null);
  const swipe = phone
    ? {
        onTouchStart: (e) => (drag.current = e.touches[0].clientY),
        onTouchEnd: (e) => {
          if (drag.current !== null && e.changedTouches[0].clientY - drag.current > 70) store.set({ menu: null });
          drag.current = null;
        },
      }
    : {};

  return (
    <AnimatePresence>
      {menu && phone && <motion.div key="menu-scrim" className="menu-scrim" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.18 }} />}
      {menu && (
        <motion.div
          key="menu"
          ref={ref}
          className="menu"
          style={phone ? undefined : { left: pos ? pos.x : menu.x, top: pos ? pos.y : menu.y, transformOrigin: 'top left' }}
          initial={phone ? { y: '100%' } : { opacity: 0, scale: 0.96 }}
          animate={phone ? { y: 0 } : { opacity: 1, scale: 1 }}
          exit={phone ? { y: '100%', transition: { duration: 0.2 } } : { opacity: 0, scale: 0.97, transition: { duration: 0.1 } }}
          transition={phone ? { duration: 0.28, ease: [0.23, 1, 0.32, 1] } : { duration: 0.16, ease }}
          {...swipe}
        >
          {phone && (
            <div className="menu-head">
              <span className="menu-grip" />
              <img src={t.artwork} alt="" draggable={false} />
              <div>
                <b>{t.title}</b>
                <span>{t.artist}</span>
              </div>
            </div>
          )}
          {!pick ? (
            <>
              <button onClick={done(() => playNext(t))}>
                <Icon name="next" size={17} /> Играть следующим
              </button>
              <button onClick={done(() => addToQueue(t))}>
                <Icon name="queue" size={17} /> Добавить в очередь
              </button>
              <hr />
              <button onClick={done(() => toggleLike(t))}>
                <Icon name={liked ? 'heartFill' : 'heart'} size={17} /> {liked ? 'Убрать из любимого' : 'В любимое'}
              </button>
              <button onClick={() => setPick(true)}>
                <Icon name="plus" size={17} /> Добавить в плейлист
              </button>
              {t.source !== 'local' && (
                <button className={saved || queued ? 'danger' : ''} onClick={done(() => (saved ? removeSaved(t.id) : queued ? unqueue(t.id) : saveTrack(t)))}>
                  <Icon name={saved ? 'trash' : queued ? 'close' : 'download'} size={17} /> {saved ? 'Убрать из сохранённых' : queued ? 'Отменить сохранение' : 'Сохранить для офлайна'}
                </button>
              )}
              {menu.playlistId && (
                <button className="danger" onClick={done(() => removeFromPlaylist(menu.playlistId, t.id))}>
                  <Icon name="trash" size={17} /> Убрать из плейлиста
                </button>
              )}
              {menu.queueIndex !== undefined && menu.queueIndex !== store.get().index && (
                <button className="danger" onClick={done(() => removeFromQueue(menu.queueIndex))}>
                  <Icon name="close" size={17} /> Убрать из очереди
                </button>
              )}
              <hr />
              <button onClick={done(() => shareTrack(t))}>
                <Icon name="share" size={17} /> Поделиться
              </button>
              <button onClick={done(() => openStory(t, knownLines(t.id)))}>
                <Icon name="clip" size={17} /> Сторис
              </button>
              {t.artistId && (
                <button onClick={done(() => (store.set({ stage: false }), go('artist', { id: t.artistId })))}>
                  <Icon name="user" size={17} /> К артисту
                </button>
              )}
              {t.albumId && (
                <button onClick={done(() => (store.set({ stage: false }), go('album', { id: t.albumId })))}>
                  <Icon name="disc" size={17} /> К альбому
                </button>
              )}
              {t.source !== 'blink' && (
                <button
                  onClick={done(() => {
                    const playing = store.get().track && store.get().track.id === t.id;
                    markAi(t);
                    if (playing) next();
                    toast('Скрыл артиста: его треки больше не попадутся');
                  })}
                >
                  <Icon name="close" size={17} /> Это нейротрек
                </button>
              )}
              {t.artistId && (
                <button onClick={done(() => go('artist', { id: t.artistId }))}>
                  <Icon name="disc" size={17} /> К артисту
                </button>
              )}
              {t.albumId && (
                <button onClick={done(() => go('album', { id: t.albumId }))}>
                  <Icon name="library" size={17} /> К альбому
                </button>
              )}
            </>
          ) : (
            <>
              <div className="sublabel">В плейлист</div>
              <button
                onClick={done(() => {
                  const p = createPlaylist(`Плейлист ${playlists.length + 1}`, [t]);
                  if (p) store.set({ toast: { text: `Создан «${p.name}»`, tone: 'info', id: Date.now() } });
                })}
              >
                <Icon name="plus" size={17} /> Новый плейлист
              </button>
              {playlists.length > 0 && <hr />}
              <div style={{ maxHeight: 260, overflowY: 'auto' }}>
                {playlists.map((p) => (
                  <button key={p.id} onClick={done(() => addToPlaylist(p.id, t))}>
                    <Icon name="library" size={17} /> <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{p.name}</span>
                  </button>
                ))}
              </div>
            </>
          )}
        </motion.div>
      )}
    </AnimatePresence>
  );
}

function Toast() {
  const toast = useStore((s) => s.toast);
  return (
    <div className="toast-wrap">
      <AnimatePresence mode="popLayout">
        {toast && (
          <motion.div
            key={toast.id}
            className={'toast ' + toast.tone}
            initial={{ opacity: 0, y: 12, scale: 0.96 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 6, transition: { duration: 0.15 } }}
            transition={{ type: 'spring', duration: 0.4, bounce: 0.2 }}
          >
            {toast.text}
            {toast.action && (
              <button
                className="toast-btn"
                onClick={() => {
                  store.set({ toast: null });
                  toast.action.run();
                }}
              >
                {toast.action.label}
              </button>
            )}
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}

const KEY_STEPS = [
  ['Создайте проект в Google Cloud', 'Войдите своим Google-аккаунтом, придумайте любое имя и нажмите «Создать».', 'https://console.cloud.google.com/projectcreate'],
  ['Включите YouTube Data API v3', 'На странице API нажмите «Включить».', 'https://console.cloud.google.com/apis/library/youtube.googleapis.com'],
  ['Создайте ключ API', '«Создать учётные данные» → «Ключ API». Скопируйте ключ.', 'https://console.cloud.google.com/apis/credentials'],
];

function KeySheet({ onClose }) {
  const current = useStore((s) => s.settings.ytKey);
  const [val, setVal] = useState(current);
  const [state, setState] = useState({});
  const submit = async () => {
    const key = val.trim();
    if (!key) return setState({ err: 'Вставьте ключ' });
    setState({ busy: true });
    const r = await checkKey(key);
    if (!r.ok) {
      const msg =
        r.reason === 'keyInvalid' || r.reason === 'badRequest'
          ? 'Ключ не подходит. Проверьте, что скопировали его целиком'
          : r.reason === 'accessNotConfigured' || r.reason === 'forbidden'
            ? 'Ключ есть, но YouTube Data API не включён (шаг 2)'
            : r.reason === 'quotaExceeded'
              ? 'Ключ рабочий, но лимит на сегодня исчерпан'
              : 'Не удалось проверить ключ. Проверьте интернет';
      if (r.reason !== 'quotaExceeded') return setState({ err: msg });
    }
    store.set({ settings: { ...store.get().settings, ytKey: key }, toast: { text: 'YouTube подключён', tone: 'info', id: Date.now() } });
    onClose();
  };
  return (
    <>
      <div className="label" style={{ marginBottom: 12 }}>
        Один раз, минуты три
      </div>
      <h2>Подключите YouTube</h2>
      <p>Музыка и клипы играют через официальный плеер YouTube. Для поиска видео нужен ваш бесплатный ключ Google. Карта не нужна.</p>
      <ol className="steps">
        {KEY_STEPS.map(([b, s, url]) => (
          <li key={url}>
            <div>
              <b>{b}</b>
              <small>{s}</small>
            </div>
            <button className="go" onClick={() => window.blink.open(url)}>
              Открыть <Icon name="external" size={14} />
            </button>
          </li>
        ))}
      </ol>
      <div className="field">
        <input autoFocus value={val} placeholder="Вставьте ключ сюда" spellCheck={false} onChange={(e) => setVal(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && submit()} />
        <button className="btn primary" onClick={submit} disabled={state.busy}>
          {state.busy ? 'Проверяю…' : 'Подключить'}
        </button>
      </div>
      <div className="field-err">{state.err || ''}</div>
      <div className="fine">Ключ хранится только на этом компьютере. Бесплатного лимита хватает примерно на 100 новых треков в день; уже сыгранные треки запоминаются и лимит не тратят.</div>
    </>
  );
}

function useUpdates() {
  useEffect(() => {
    const b = window.blink;
    if (!b.onUpdate) return;
    b.version().then((version) => store.set({ appVersion: version }));
    b.updateState().then((update) => store.set({ update }));
    b.onUpdate((update) => store.set({ update }));
  }, []);
}

function updateLabel(u) {
  if (!u) return '';
  if (u.state === 'downloading') return `Скачиваю обновление… ${u.percent || 0}%`;
  if (u.state === 'ready') return 'Обновление скачано, перезапускаю Blink…';
  if (u.state === 'error') return 'Не получилось скачать обновление. Проверьте интернет';
  return `Доступна версия ${u.version}`;
}

function useOnline() {
  const [online, setOnline] = useState(navigator.onLine);
  useEffect(() => {
    const on = () => setOnline(true);
    const off = () => setOnline(false);
    window.addEventListener('online', on);
    window.addEventListener('offline', off);
    return () => {
      window.removeEventListener('online', on);
      window.removeEventListener('offline', off);
    };
  }, []);
  return online;
}

// No network: says so at the top and offers the tracks saved for offline.
function OfflineBanner() {
  const online = useOnline();
  const saved = useStore((s) => (s.saved || []).length > 0);
  return (
    <AnimatePresence>
      {!online && (
        <motion.div
          className="update-banner offline"
          role="status"
          initial={{ opacity: 0, y: -12 }}
          animate={{ opacity: 1, y: 0 }}
          exit={{ opacity: 0, y: -8, transition: { duration: 0.15 } }}
          transition={{ type: 'spring', duration: 0.45, bounce: 0.2 }}
        >
          <span className="dot" />
          <span>Без доступа к интернету</span>
          {saved && (
            <button className="go" onClick={() => go('playlist', { id: 'saved' })}>
              Слушать сохранённое
            </button>
          )}
        </motion.div>
      )}
    </AnimatePresence>
  );
}

function UpdateBanner() {
  const u = useStore((s) => s.update);
  const [hidden, setHidden] = useState(false);
  const online = useOnline();
  const show = online && u && ['available', 'downloading', 'ready', 'error'].includes(u.state) && !hidden;
  return (
    <AnimatePresence>
      {show && (
        <motion.div
          className="update-banner"
          initial={{ opacity: 0, y: -12 }}
          animate={{ opacity: 1, y: 0 }}
          exit={{ opacity: 0, y: -8, transition: { duration: 0.15 } }}
          transition={{ type: 'spring', duration: 0.45, bounce: 0.2 }}
        >
          <span className="dot" />
          <span>{u.state === 'available' ? `Доступно обновление Blink ${u.version}` : updateLabel(u)}</span>
          {(u.state === 'available' || u.state === 'error') && (
            <button className="go" onClick={() => window.blink.installUpdate()}>
              {u.state === 'error' ? 'Ещё раз' : 'Обновить'}
            </button>
          )}
          {u.state === 'downloading' && (
            <span className="bar">
              <i style={{ width: (u.percent || 0) + '%' }} />
            </span>
          )}
          {u.state !== 'downloading' && u.state !== 'ready' && (
            <button className="icon-btn" style={{ width: 28, height: 28 }} title="Позже" onClick={() => setHidden(true)}>
              <Icon name="close" size={14} />
            </button>
          )}
        </motion.div>
      )}
    </AnimatePresence>
  );
}

function VersionRow() {
  const version = useStore((s) => s.appVersion);
  const u = useStore((s) => s.update) || { state: 'idle' };
  if (!version) return null;
  const busy = u.state === 'checking' || u.state === 'downloading' || u.state === 'ready';
  return (
    <div className="set-row">
      <div>
        <div className="k">Blink {version}</div>
        <div className="d">
          {u.state === 'available'
            ? `Доступна версия ${u.version}`
            : u.state === 'checking'
              ? 'Проверяю обновления…'
              : u.state === 'downloading' || u.state === 'ready' || u.state === 'error'
                ? updateLabel(u)
                : 'У вас последняя версия'}
        </div>
      </div>
      {u.state === 'available' || u.state === 'error' ? (
        <button className="btn primary" onClick={() => window.blink.installUpdate()}>
          Обновить и перезапустить
        </button>
      ) : (
        <button className="btn ghost" disabled={busy} onClick={() => window.blink.checkUpdate()}>
          Проверить
        </button>
      )}
    </div>
  );
}

// "Слушать вместе" from a friend's Discord status: same track, same moment.
function parseListen(search) {
  const p = new URLSearchParams(search);
  const id = p.get('listen');
  if (id) return { id, t: Number(p.get('t')) || 0, at: Number(p.get('at')) || Date.now() };
  // A shared track (?track=, or /t/<id> when the site is served without the preview route).
  const track = p.get('track') || decodeURIComponent((location.pathname.match(/^\/t\/([^/]+)/) || [])[1] || '');
  if (!track) return null;
  return { id: track, shared: true, t: 0, at: Date.now(), title: p.get('n') || '', artist: p.get('a') || '', artwork: p.get('c') || '' };
}

function useListenLinks() {
  useEffect(() => {
    // Shared playlist links: ?playlist=<code> (current), /p/<code> (older links that may be in the wild).
    const pathCode = (location.pathname.match(/^\/p\/([A-Za-z0-9]+)/) || [])[1];
    const shared = new URLSearchParams(location.search).get('playlist') || pathCode;
    if (shared) {
      store.set({ sharedCode: shared, sheet: 'shared' });
      history.replaceState(null, '', location.pathname);
    }
    if (window.blink.onDeepLink)
      window.blink.onDeepLink((url) => {
        if (!url.startsWith('blink://playlist')) return;
        const c = new URLSearchParams(url.slice(url.indexOf('?'))).get('playlist');
        if (c) store.set({ sharedCode: c, sheet: 'shared' });
      });
    // «Слушать вместе» room links: ?together=<code>, blink://together?together=<code>.
    const room = new URLSearchParams(location.search).get('together');
    if (room) {
      store.set({ togetherInvite: room, sheet: 'together' });
      history.replaceState(null, '', location.pathname);
    }
    if (window.blink.onDeepLink)
      window.blink.onDeepLink((url) => {
        if (!url.startsWith('blink://together')) return;
        const c = new URLSearchParams(url.slice(url.indexOf('?'))).get('together');
        if (c) store.set({ togetherInvite: c, sheet: 'together' });
      });
    // mp3/wav opened with Blink («Открыть с помощью» / double click).
    if (window.blink.onOpenFiles) window.blink.onOpenFiles(playFiles);
    const fromUrl = parseListen(location.search);
    if (fromUrl) {
      store.set({ listen: fromUrl, sheet: 'listen' });
      history.replaceState(null, '', fromUrl.shared ? '/' : location.pathname);
    }
    if (window.blink.onDeepLink)
      window.blink.onDeepLink((url) => {
        if (!url.startsWith('blink://listen') && !url.startsWith('blink://track')) return;
        const l = parseListen(url.slice(url.indexOf('?')));
        if (l) store.set({ listen: l, sheet: 'listen' });
      });
  }, []);
}

function ListenSheet({ onClose }) {
  const l = useStore((s) => s.listen);
  const country = useStore((s) => s.settings.country);
  const [track, setTrack] = useState(null);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    if (!l) return;
    // Shared tracks from other sources come with their title, artist and cover.
    const fallback = l.title ? { id: l.id, title: l.title, artist: l.artist, artistId: null, album: '', albumId: null, artwork: l.artwork, duration: 0, ...(l.id.startsWith('b:') ? { lic: l.id.slice(2), source: 'blink' } : {}) } : null;
    lookupTracks([l.id], country)
      .then((r) => (r[0] || fallback ? setTrack(r[0] || fallback) : setFailed(true)))
      .catch(() => (fallback ? setTrack(fallback) : setFailed(true)));
  }, [l && l.id]);
  if (!l) return null;
  const position = () => {
    const t = l.t + (Date.now() - l.at) / 1000;
    return track && track.duration && t > track.duration - 5 ? 0 : Math.max(0, t);
  };
  const appLink = l.shared
    ? `blink://track?${new URLSearchParams({ track: l.id, n: l.title, a: l.artist, c: l.artwork })}`
    : `blink://listen?listen=${encodeURIComponent(l.id)}&t=${l.t}&at=${l.at}`;
  return (
    <>
      <div className="label" style={{ marginBottom: 12 }}>
        {l.shared ? 'С вами поделились треком' : 'Слушать вместе'}
      </div>
      {track ? (
        <div className="listen-track">
          <Cover src={track.artwork} size={300} />
          <div style={{ minWidth: 0 }}>
            <h2 style={{ margin: 0 }}>{track.title}</h2>
            <div style={{ color: 'var(--mute)', fontWeight: 600 }}>{track.artist}</div>
          </div>
        </div>
      ) : failed ? (
        <p>Не удалось открыть этот трек.</p>
      ) : (
        <div className="sk" style={{ height: 96, borderRadius: 18 }} />
      )}
      {!l.shared && <p style={{ marginTop: 16 }}>Ваш друг слушает это прямо сейчас. Включим с того же места?</p>}
      <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
        <button
          className="btn primary"
          disabled={!track}
          onClick={() => {
            onClose();
            playTrack(track, [track], 0, position());
          }}
        >
          <Icon name="play" size={18} /> {l.shared ? 'Слушать' : 'Слушать вместе'}
        </button>
        {!isDesktop && (
          <a className="btn ghost" href={appLink} style={{ textDecoration: 'none' }}>
            Открыть в приложении
          </a>
        )}
      </div>
    </>
  );
}

// Someone's playlist opened by link: preview it and add a copy to your library.
function SharedSheet({ onClose }) {
  const code = useStore((s) => s.sharedCode);
  const [pl, setPl] = useState(undefined);
  useEffect(() => {
    fetchShared(code).then(setPl).catch(() => setPl(null));
  }, [code]);
  if (pl === undefined) return <div className="sk" style={{ height: 160, borderRadius: 18 }} />;
  if (!pl)
    return (
      <>
        <h2>Плейлист не найден</h2>
        <p>Возможно, автор перестал им делиться.</p>
      </>
    );
  const d = pl.data;
  const add = () => {
    const p = createPlaylist(d.name, d.tracks);
    if (!p) return;
    if (d.cover) store.set({ playlists: store.get().playlists.map((x) => (x.id === p.id ? { ...x, cover: d.cover } : x)) });
    onClose();
    go('playlist', { id: p.id });
    store.set({ toast: { text: `«${d.name}» теперь у вас`, tone: 'info', id: Date.now() } });
  };
  const appLink = `blink://playlist?playlist=${encodeURIComponent(pl.code)}`;
  return (
    <>
      <div className="label" style={{ marginBottom: 12 }}>
        {pl.owner_name ? `${pl.owner_name} делится плейлистом` : 'Плейлист'}
      </div>
      <div className="listen-track">
        <Cover src={d.cover || (d.tracks[0] && d.tracks[0].artwork)} size={300} />
        <div style={{ minWidth: 0 }}>
          <h2 style={{ margin: 0 }}>{d.name}</h2>
          <div style={{ color: 'var(--mute)', fontWeight: 600 }}>{plural(d.tracks.length, 'трек', 'трека', 'треков')}</div>
        </div>
      </div>
      <p style={{ marginTop: 16 }}>{d.tracks.slice(0, 4).map((t) => `${t.artist} — ${t.title}`).join(' · ')}</p>
      <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
        <button className="btn primary" onClick={add}>
          <Icon name="plus" size={18} /> Добавить к себе
        </button>
        {!isDesktop && (
          <a className="btn ghost" href={appLink} style={{ textDecoration: 'none' }}>
            Открыть в приложении
          </a>
        )}
      </div>
    </>
  );
}

function Stats() {
  const [n, setN] = useState(null);
  useEffect(() => {
    fetchStats().then(setN);
  }, []);
  if (!n) return null;
  const f = (x) => Number(x || 0).toLocaleString('ru-RU');
  return (
    <div className="stats">
      <div className="label">Blink в цифрах</div>
      <div className="stats-grid">
        <div>
          <b>{f(n.users)}</b>
          <span>зарегистрированных слушателей</span>
        </div>
        <div>
          <b>{f(n.active)}</b>
          <span>активных слушателей за 7 дней</span>
        </div>
        <div>
          <b>{f(n.plays)}</b>
          <span>прослушиваний за всё время</span>
        </div>
        <div>
          <b>{f(n.likes)}</b>
          <span>треков в «Любимом»</span>
        </div>
      </div>
    </div>
  );
}


function relTime(iso) {
  const d = (Date.now() - new Date(iso).getTime()) / 1000;
  if (d < 90) return 'только что';
  if (d < 3600) return Math.round(d / 60) + ' мин назад';
  if (d < 86400) return Math.round(d / 3600) + ' ч назад';
  return Math.round(d / 86400) + ' дн назад';
}

function CrossfadeRow({ s, set }) {
  const cf = Number(s.crossfade) || 0;
  return (
    <div className="set-row">
      <div>
        <div className="k">Плавный переход</div>
        <div className="d">{cf ? `Треки плавно сменяют друг друга за ${cf} с` : 'Выключен · включите, чтобы треки перетекали друг в друга'}</div>
      </div>
      <div className="pref-slider">
        <input type="range" min={0} max={12} step={1} value={cf} onChange={(e) => set({ crossfade: Number(e.target.value) })} aria-label="Плавный переход, секунды" />
        <span>{cf ? cf + ' с' : 'выкл'}</span>
      </div>
    </div>
  );
}

function DevicesTab() {
  const user = useStore((x) => x.user);
  const [list, setList] = useState(user ? null : []);
  useEffect(() => {
    let live = true;
    if (user) listDevices().then((l) => live && setList(l), () => live && setList([]));
    else setList([]);
    return () => (live = false);
  }, [user]);
  if (!user)
    return <div className="set-intro">Войдите в аккаунт, чтобы видеть устройства, на которых вы слушаете Blink, и выходить на них.</div>;
  if (list === null) return <div className="set-intro">Загружаю…</div>;
  const drop = async (d) => {
    if (!(await ask({ title: 'Выйти на этом устройстве?', text: `«${d.name}» выйдет из аккаунта. Прослушивание там остановится.`, ok: 'Выйти', danger: true, icon: 'close' }))) return;
    try {
      await revokeDevice(d.device_id);
      setList((l) => l.filter((x) => x.device_id !== d.device_id));
      toast('Устройство отключено');
    } catch {
      toast('Не получилось, попробуйте ещё раз', 'error');
    }
  };
  return (
    <>
      <div className="set-intro">Где выполнен вход в ваш аккаунт Blink. «Выйти» завершит сессию на выбранном устройстве.</div>
      <div className="dev-list">
        {list.map((d) => (
          <div className="dev-row" key={d.device_id}>
            <span className="dev-ic">
              <Icon name={d.platform === 'mobile' ? 'phone' : d.platform === 'app' ? 'disc' : 'library'} size={18} />
            </span>
            <div className="dev-name">
              <b>
                {d.name}
                {d.current && <span className="dev-here"> · это устройство</span>}
              </b>
              <small>{d.current ? 'активно сейчас' : relTime(d.last_seen)}</small>
            </div>
            {!d.current && (
              <button className="btn ghost" onClick={() => drop(d)}>
                Выйти
              </button>
            )}
          </div>
        ))}
      </div>
    </>
  );
}

// Game mode restarts Blink into GameApp.jsx. An older app without that (site updated first)
// stays here, and data-game on <html> switches off every animation, blur and shadow (see styles.css).
function useGameMode(game) {
  useEffect(() => {
    document.documentElement.dataset.game = game ? 'on' : 'off';
    window.dispatchEvent(new Event('blink-game'));
  }, [game]);
}

function GameTab({ on }) {
  return (
    <>
      <div className={'game-card' + (on ? ' on' : '')}>
        <div className="gc-head">
          <div>
            <div className="k">Игровой режим</div>
            <div className="d">Blink перезапустится в маленьком окне и почти не будет грузить процессор, видеокарту и память</div>
          </div>
          <Switch on={on} onChange={switchGame} />
        </div>
        <ul className="gc-list">
          <li>Только плеер: обложка, трек, управление и громкость</li>
          <li>Без видеокарты, анимаций, фона и визуализаций</li>
          <li>YouTube играет в самом лёгком качестве, звук тот же</li>
          <li>Медиаклавиши и трей работают, музыка продолжится с того же места</li>
        </ul>
      </div>
    </>
  );
}

const SETTINGS_TABS = [
  ['main', 'Аккаунт'],
  ['security', 'Безопасность'],
  ['storage', 'Хранилище'],
  ['about', 'О программе'],
];

// «Настройки» (account, security, storage, about) and «Параметры» (how the app behaves) are two
// pages; this switch on top moves between them.
function PrefsHead({ page }) {
  return (
    <div className="prefs-head" role="tablist">
      {[
        ['settings', 'Настройки'],
        ['params', 'Параметры'],
      ].map(([k, label]) => (
        <button key={k} role="tab" aria-selected={page === k} className={page === k ? 'on' : ''} onClick={() => page !== k && go(k)}>
          {label}
        </button>
      ))}
    </div>
  );
}

const mb = (b) => (b >= 1e9 ? `${(b / 1e9).toFixed(1)} ГБ` : `${Math.round(b / 1e6)} МБ`);

// Settings → Хранилище: the space saved tracks take on this device, and wiping them.
function StorageTab() {
  const saved = useStore((s) => s.saved || []);
  const dl = useStore((s) => !!s.dl);
  const [bytes, setBytes] = useState(null);
  const [free, setFree] = useState(null);
  useEffect(() => {
    savedBytes().then(setBytes, () => setBytes(0));
    if (navigator.storage && navigator.storage.estimate) navigator.storage.estimate().then((e) => setFree(e.quota - e.usage), () => {});
  }, [saved.length]);
  const wipe = async () => {
    const ok = await ask({ title: 'Стереть сохранённые треки?', text: 'Файлы удалятся с этого устройства, и без интернета треки играть не будут. Любимое и плейлисты останутся.', ok: 'Стереть', danger: true, icon: 'trash' });
    if (!ok) return;
    await clearSaved();
    toast('Сохранённые треки стёрты');
  };
  return (
    <>
      <div className="set-row">
        <div>
          <div className="k">Сохранённые треки</div>
          <div className="d">
            {saved.length ? `${plural(saved.length, 'трек', 'трека', 'треков')} · ${bytes === null ? 'считаю…' : mb(bytes)}` : 'На этом устройстве ничего не сохранено'}
            {dl && ' · идёт загрузка'}
          </div>
        </div>
        {saved.length > 0 && (
          <button className="btn ghost" onClick={() => go('playlist', { id: 'saved' })}>
            Открыть
          </button>
        )}
      </div>
      {free !== null && (
        <div className="set-row">
          <div>
            <div className="k">Свободно для Blink</div>
            <div className="d">Столько ещё можно сохранить на этом устройстве</div>
          </div>
          <span className="set-val">{mb(free)}</span>
        </div>
      )}
      <div className="set-row">
        <div>
          <div className="k">Стереть с устройства</div>
          <div className="d">Удалит все сохранённые файлы. Треки останутся в «Любимом» и плейлистах</div>
        </div>
        <button className="btn ghost wipe" disabled={!saved.length && !dl} onClick={wipe}>
          <Icon name="trash" size={16} /> Стереть
        </button>
      </div>
    </>
  );
}

// Top bar: the support page, with a dot when the team has answered.
function SupportButton({ active }) {
  const fresh = useStore((s) => s.supportNew);
  return (
    <button className={'icon-btn sup-btn' + (active ? ' active' : '')} title={fresh ? 'Поддержка: есть ответ' : 'Поддержка'} onClick={() => go('support')}>
      <Icon name="support" size={20} />
      {fresh > 0 && <span className="sup-btn-dot" />}
    </button>
  );
}

// Old links (go('settings', { tab })) still land somewhere sensible.
const OLD_TABS = { devices: 'security', plus: null, sound: 'params', game: 'params', island: 'params' };

function SettingsPage() {
  const user = useStore((x) => x.user);
  const svc = useStore((x) => x.svc);
  const askTab = useStore((x) => x.view.params.tab);
  const pick = (t) => (t && t in OLD_TABS ? OLD_TABS[t] : t) || 'main';
  const [tab, setTab] = useState(pick(askTab));
  useEffect(() => {
    const t = pick(askTab);
    if (askTab === 'plus') go('plus');
    else if (t === 'params') go('params');
    else if (askTab) setTab(t);
  }, [askTab]);
  useEffect(() => {
    runStatus();
  }, []);
  return (
    <div className="set-page">
      <PrefsHead page="settings" />
      <div className="set-tabs" role="tablist">
        {SETTINGS_TABS.map(([k, label]) => (
          <button key={k} role="tab" aria-selected={tab === k} className={tab === k ? 'on' : ''} onClick={(e) => (setTab(k), e.currentTarget.scrollIntoView({ inline: 'center', block: 'nearest', behavior: 'smooth' }))}>
            {label}
          </button>
        ))}
      </div>

      <motion.div key={tab} className="set-pane" initial={{ opacity: 0, x: 12 }} animate={{ opacity: 1, x: 0 }} transition={{ duration: 0.22, ease: [0.23, 1, 0.32, 1] }}>
      {tab === 'main' && (
        <>
          <div className="set-row">
            <div>
              <div className="k">Аккаунт</div>
              <div className="d">{user ? user.email : 'Войдите, чтобы музыка была с вами везде'}</div>
            </div>
            <button className="btn ghost" onClick={() => store.set({ sheet: 'account' })}>
              {user ? 'Открыть' : 'Войти'}
            </button>
          </div>
          <div className="set-row">
            <div>
              <div className="k">Blink+</div>
              <div className="d">Что даёт подписка и как её оформить</div>
            </div>
            <button className="btn ghost" onClick={() => go('plus')}>
              Подробнее
            </button>
          </div>
          <div className="set-row">
            <div>
              <div className="k">Перенос музыки</div>
              <div className="d">Из Яндекс Музыки, Spotify и других сервисов</div>
            </div>
            <button className="btn ghost" onClick={() => store.set({ sheet: 'import' })}>
              Перенести
            </button>
          </div>
          <div className="set-row">
            <div>
              <div className="k">История прослушиваний</div>
              <div className="d">По ней подбирается «Вспышка»</div>
            </div>
            <button className="btn ghost" onClick={async () => (await ask({ title: 'Очистить историю?', text: 'Список «Вы недавно слушали» станет пустым.', ok: 'Очистить', danger: true })) && store.set({ recent: [] })}>
              Очистить
            </button>
          </div>
        </>
      )}

      {tab === 'security' && (
        <>
          {user && (
            <div className="set-row">
              <div>
                <div className="k">Вход выполнен</div>
                <div className="d">{user.email}</div>
              </div>
              <button className="btn ghost" onClick={async () => (await ask({ title: 'Выйти из аккаунта?', text: 'Любимое и плейлисты останутся в облаке, войдите снова, чтобы их вернуть.', ok: 'Выйти', icon: 'close' })) && signOut()}>
                Выйти
              </button>
            </div>
          )}
          <div className="label set-label">Устройства</div>
          <DevicesTab />
        </>
      )}

      {tab === 'storage' && <StorageTab />}

      {tab === 'about' && (
        <>
          <VersionRow />
          <div className="about-links">
            <button onClick={() => store.set({ sheet: 'status' })}>
              <StatusGlyph state={svc ? svc.overall : 'wait'} size={18} />
              <b>Состояние сервисов</b>
              <span>{svc ? ({ up: 'Всё работает', slow: 'Есть замедления', down: 'Часть сервисов недоступна' })[svc.overall] : 'Проверяю…'}</span>
            </button>
            <button onClick={() => go('support')}>
              <Icon name="support" size={18} />
              <b>Поддержка</b>
              <span>Частые вопросы и связь с командой</span>
            </button>
            <button onClick={() => window.blink.open('https://spherical.media')}>
              <Icon name="external" size={18} />
              <b>Для артистов</b>
              <span>Выпускайте музыку через Spherical Media</span>
            </button>
          </div>
          <div className="set-row keys">
            <div className="k">Горячие клавиши</div>
            <dl>
              <dt>Пробел</dt>
              <dd>пауза</dd>
              <dt>← →</dt>
              <dd>перемотка</dd>
              <dt>Ctrl ← →</dt>
              <dd>треки</dd>
              <dt>↑ ↓</dt>
              <dd>громкость</dd>
              <dt>L</dt>
              <dd>в любимое</dd>
              <dt>F</dt>
              <dd>сцена</dd>
              <dt>Ctrl K</dt>
              <dd>поиск</dd>
              <dt>Ctrl P</dt>
              <dd>сообщить об ошибке</dd>
            </dl>
          </div>
          <Stats />
          <a className="powered" href="https://spherical.media" target="_blank" rel="noopener" onClick={(e) => (e.preventDefault(), window.blink.open('https://spherical.media'))}>
            При поддержке <b>Spherical Media</b>
          </a>
        </>
      )}
      </motion.div>
    </div>
  );
}

// «Параметры»: how the app plays and behaves. Blink Island sits folded under «Дополнительно».
function ParamsPage() {
  const s = useStore((x) => x.settings);
  const set = (patch) => store.set({ settings: { ...store.get().settings, ...patch } });
  return (
    <div className="set-page">
      <PrefsHead page="params" />
      <div className="label set-label">Воспроизведение</div>
      <CrossfadeRow s={s} set={set} />
      {isDesktop && (
        <>
          <div className="label set-label">Окно</div>
          <div className="set-row">
            <div>
              <div className="k">Сворачивать в трей</div>
              <div className="d">Кнопка «закрыть» прячет Blink к часам, музыка продолжает играть</div>
            </div>
            <Switch on={s.tray !== false} onChange={(tray) => set({ tray })} />
          </div>
          {window.blink.setDiscord && (
            <div className="set-row">
              <div>
                <div className="k">Показывать в Discord</div>
                <div className="d">В профиле видно, что вы слушаете в Blink, с обложкой и кнопкой для друзей</div>
              </div>
              <Switch on={s.discord !== false} onChange={(discord) => set({ discord })} />
            </div>
          )}
        </>
      )}
      {!isDesktop && (
        <>
          <div className="label set-label">Экран</div>
          <div className="set-row">
            <div>
              <div className="k">Логотип на скриншотах</div>
              <div className="d">Надпись blink в плеере и значок Blink под «островком» iPhone: на скриншотах видно, откуда трек</div>
            </div>
            <Switch on={s.brandMark !== false} onChange={(brandMark) => set({ brandMark })} />
          </div>
          <div className="set-row">
            <div>
              <div className="k">Клипы-петли на обложке</div>
              <div className="d">Короткое видео трека вместо картинки, когда оно есть. Если телефон или ПК тормозит, выключите</div>
            </div>
            <Switch on={s.shots !== false} onChange={(shots) => set({ shots })} />
          </div>
        </>
      )}
      <div className="label set-label">Игры</div>
      <GameTab on={!!s.game} />
      <details className="set-more">
        <summary>
          Дополнительно <Icon name="down" size={16} />
        </summary>
        <div className="label set-label">Blink Island</div>
        <IslandTab on={!!s.islandAuto} set={set} />
      </details>
    </div>
  );
}

// Sign-in is a page of its own, not a pop-up: more room, the keyboard doesn't push it around,
// and the browser's back button / swipe closes it.
function AuthPage({ onClose }) {
  useEffect(() => {
    const esc = (e) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', esc);
    document.body.classList.add('auth-open');
    return () => {
      window.removeEventListener('keydown', esc);
      document.body.classList.remove('auth-open');
    };
  }, []);
  return (
    <div className="auth-page" role="dialog" aria-label="Вход в Blink">
      <button className="auth-back" onClick={onClose}>
        <Icon name="back" size={18} /> Назад
      </button>
      <div className="auth-card">
        <div className="auth-logo">Blink</div>
        <AccountSheet onClose={onClose} />
      </div>
    </div>
  );
}

function Sheets() {
  const sheet = useStore((s) => s.sheet);
  const user = useStore((s) => s.user);
  const close = () => store.set({ sheet: null, authReason: null });
  const sheetDrag = useRef(null);
  useEffect(() => {
    if (user || isDesktop || !gisUsable()) return;
    const t = setTimeout(warmGis, 3500);
    return () => clearTimeout(t);
  }, [!!user]);
  useEffect(() => {
    if (!sheet) return;
    const esc = (e) => e.key === 'Escape' && close();
    window.addEventListener('keydown', esc);
    return () => window.removeEventListener('keydown', esc);
  }, [sheet]);
  if (sheet === 'account' && !user) return <AuthPage onClose={close} />;
  return (
    <AnimatePresence>
      {sheet && (
        <motion.div className="scrim" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0, transition: { duration: 0.18 } }} onPointerDown={(e) => e.target === e.currentTarget && close()}>
          <motion.div
            key={sheet}
            className={'sheet' + (sheet === 'story' ? ' wide' : '')}
            onTouchStart={(e) => (sheetDrag.current = e.currentTarget.scrollTop <= 0 ? e.touches[0].clientY : null)}
            onTouchEnd={(e) => {
              if (sheetDrag.current !== null && e.changedTouches[0].clientY - sheetDrag.current > 90 && window.matchMedia('(max-width: 760px)').matches) close();
              sheetDrag.current = null;
            }}
            initial={{ opacity: 0, y: 24, scale: 0.97 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 12, scale: 0.98, transition: { duration: 0.16 } }}
            transition={{ type: 'spring', duration: 0.45, bounce: 0.15 }}
          >
            <button className="icon-btn x" onClick={close} title="Закрыть">
              <Icon name="close" size={18} />
            </button>
            {sheet === 'key' ? <KeySheet onClose={close} /> : sheet === 'account' ? <AccountSheet onClose={close} /> : sheet === 'listen' ? <ListenSheet onClose={close} /> : sheet === 'import' ? <ImportSheet onClose={close} /> : sheet === 'status' ? <StatusSheet /> : sheet === 'shared' ? <SharedSheet onClose={close} /> : sheet === 'story' ? <StoryCard /> : sheet === 'together' ? <TogetherSheet onClose={close} /> : sheet === 'bug' ? <BugSheet /> : null}
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}

function Intro({ onDone }) {
  useEffect(() => {
    const t = setTimeout(onDone, 1250);
    return () => clearTimeout(t);
  }, [onDone]);
  return (
    <motion.div className="intro" exit={{ opacity: 0, transition: { duration: 0.35 } }}>
      <motion.div
        className="mark"
        initial={{ clipPath: 'inset(50% 0 50% 0)', opacity: 0 }}
        animate={{ clipPath: 'inset(0% 0 0% 0)', opacity: 1 }}
        transition={{ duration: 0.55, ease: [0.32, 0.72, 0, 1] }}
      >
        blink
        <motion.span className="dot" initial={{ scaleY: 1 }} animate={{ scaleY: [1, 1, 0.1, 1] }} transition={{ duration: 0.9, times: [0, 0.6, 0.78, 1], delay: 0.2 }} />
      </motion.div>
    </motion.div>
  );
}

function View() {
  const view = useStore((s) => s.view);
  const main = useRef(null);
  const phone = window.matchMedia('(max-width: 760px)').matches;
  const key = view.name + JSON.stringify(view.params);
  useEffect(() => {
    if (main.current) main.current.scrollTo({ top: 0, behavior: 'instant' });
  }, [key]);
  let el;
  switch (view.name) {
    case 'search':
      el = <Search />;
      break;
    case 'artist':
      el = <Artist id={view.params.id} />;
      break;
    case 'bartist':
      el = <BlinkArtist id={view.params.id} />;
      break;
    case 'me':
      el = <MyPage />;
      break;
    case 'album':
      el = <Album id={view.params.id} />;
      break;
    case 'charts':
      el = <Overview noFlash />;
      break;
    case 'library':
      el = <Library />;
      break;
    case 'playlist':
      el = <Playlist id={view.params.id} />;
      break;
    case 'editorial':
      el = <Editorial id={view.params.id} />;
      break;
    case 'settings':
      el = <SettingsPage />;
      break;
    case 'params':
      el = <ParamsPage />;
      break;
    case 'plus':
      el = (
        <PlusPage>
          <SupportCard />
        </PlusPage>
      );
      break;
    case 'support':
      el = <SupportPage id={view.params.id} />;
      break;
    default:
      el = <Home />;
  }
  return (
    <main className={'main' + (view.name === 'search' ? ' searching' : '')} ref={main}>
      {/* Phones: opacity only (a moving page shifts fixed screens inside it and looks like a glitch). */}
      <motion.div key={view.name === 'search' ? 'search' : key} initial={phone ? { opacity: 0 } : { opacity: 0, y: 10 }} animate={phone ? { opacity: 1 } : { opacity: 1, y: 0 }} transition={{ duration: phone ? 0.15 : 0.28, ease }}>
        {el}
      </motion.div>
    </main>
  );
}

function useKeys() {
  useEffect(() => {
    const onKey = (e) => {
      const typing = /INPUT|TEXTAREA|SELECT/.test(document.activeElement && document.activeElement.tagName);
      const s = store.get();
      if ((e.ctrlKey && e.key.toLowerCase() === 'k') || (e.ctrlKey && e.key.toLowerCase() === 'л') || (!typing && e.key === '/')) {
        e.preventDefault();
        return window.__focusSearch && window.__focusSearch();
      }
      if (e.altKey && e.key === 'ArrowLeft') return goBack();
      // Ctrl+P (any layout): bug report with the last error, instead of printing.
      if ((e.ctrlKey || e.metaKey) && e.code === 'KeyP') {
        e.preventDefault();
        return store.set({ sheet: 'bug', menu: null });
      }
      if (typing || s.sheet || s.menu) return;
      if (e.code === 'Space') {
        e.preventDefault();
        return toggle();
      }
      if (e.key === 'Escape' && s.stage) return store.set({ stage: false });
      if (e.ctrlKey && e.key === 'ArrowRight') return next();
      if (e.ctrlKey && e.key === 'ArrowLeft') return prev();
      if (e.key === 'ArrowRight') return seek(clock.get().time + 5);
      if (e.key === 'ArrowLeft') return seek(clock.get().time - 5);
      if (e.key === 'ArrowUp') {
        e.preventDefault();
        return setVolume(s.volume + 5);
      }
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        return setVolume(s.volume - 5);
      }
      if (e.code === 'KeyL' && s.track) return toggleLike(s.track);
      if (e.code === 'KeyF' && s.track) return store.set({ stage: !s.stage });
      if (!e.ctrlKey && !e.altKey && !e.metaKey && e.key.length === 1 && /[\p{L}\p{N}]/u.test(e.key)) {
        e.preventDefault();
        window.__focusSearch && window.__focusSearch(e.key);
      }
    };
    const onMouse = (e) => e.button === 3 && goBack();
    window.addEventListener('keydown', onKey);
    window.addEventListener('mouseup', onMouse);
    return () => {
      window.removeEventListener('keydown', onKey);
      window.removeEventListener('mouseup', onMouse);
    };
  }, []);
}

// Thumbnail-toolbar icons for the Windows taskbar preview, drawn once.
function drawThumbIcons() {
  const paths = {
    prev: 'M19 6.2v11.6c0 .7-.8 1.1-1.4.7l-8.2-5.8c-.5-.4-.5-1.1 0-1.4l8.2-5.8c.6-.4 1.4 0 1.4.7Z M4.6 5.5h1.8v13H4.6z',
    next: 'M5 6.2v11.6c0 .7.8 1.1 1.4.7l8.2-5.8c.5-.4.5-1.1 0-1.4L6.4 5.5C5.8 5.1 5 5.5 5 6.2Z M17.6 5.5h1.8v13h-1.8z',
    play: 'M8 5.6v12.8c0 .8.9 1.3 1.6.8l9.6-6.4c.6-.4.6-1.2 0-1.6L9.6 4.8C8.9 4.3 8 4.8 8 5.6Z',
    pause: 'M6.5 5h4v14h-4z M13.5 5h4v14h-4z',
  };
  const out = {};
  for (const [k, d] of Object.entries(paths)) {
    const c = document.createElement('canvas');
    c.width = c.height = 32;
    const ctx = c.getContext('2d');
    ctx.scale(32 / 24, 32 / 24);
    ctx.fillStyle = '#ffffff';
    ctx.fill(new Path2D(d));
    out[k] = c.toDataURL('image/png');
  }
  window.blink.thumbIcons(out);
}

export default function App() {
  const loaded = useStore((s) => s.loaded);
  const stage = useStore((s) => s.stage);
  const [intro, setIntro] = useState(true);
  useKeys();
  useUpdates();
  useListenLinks();
  useIslandAutostart(loaded);
  const uid = useStore((s) => s.user && s.user.id);
  const hadUid = useRef(null);
  useEffect(() => {
    if (!loaded) return;
    // The session comes up a moment after start, so only an actual sign-out clears the status.
    if (hadUid.current && hadUid.current !== uid) store.set({ plus: null, supporter: null });
    hadUid.current = uid;
    refreshPlus();
    refreshSupport();
    // Back from the payment page or after a long break: pick up the new status.
    window.addEventListener('focus', refreshPlus);
    return () => window.removeEventListener('focus', refreshPlus);
  }, [loaded, uid]);
  const tray = useStore((s) => s.settings.tray !== false);
  useEffect(() => {
    if (window.blink.setTrayOnClose) window.blink.setTrayOnClose(tray);
  }, [tray]);
  const discord = useStore((s) => s.settings.discord !== false);
  useEffect(() => {
    if (window.blink.setDiscord) window.blink.setDiscord(discord);
  }, [discord]);
  useEffect(() => {
    if (loaded) syncRelay();
  }, [loaded]);
  useEffect(() => {
    if (!loaded) return;
    initMedia();
    resumeAfterSwitch();
    drawThumbIcons();
    const root = document.documentElement.style;
    root.setProperty('--accent', DEFAULT_PALETTE.accent);
  }, [loaded]);

  const game = useStore((s) => !!s.settings.game);
  useGameMode(game);

  return (
    <MotionConfig reducedMotion={game ? 'always' : 'user'}>
      <Ambient />
      {loaded && <View />}
      {loaded && <FlashHost />}
      <TitleBar />
      <UpdateBanner />
      <OfflineBanner />
      <Capsule />
      <AnimatePresence>{stage && <Stage />}</AnimatePresence>
      <IslandMark />
      <YtHost />
      <Menu />
      <Sheets />
      <Toast />
      <InstallHint />
      <Tooltip />
      <Confirm />
      <div className="grain" />
      <AnimatePresence>{intro && <Intro onDone={() => (setIntro(false), launchFeel())} />}</AnimatePresence>
      <GameSwitch />
    </MotionConfig>
  );
}
