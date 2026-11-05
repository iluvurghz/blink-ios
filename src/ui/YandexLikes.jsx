import { useEffect, useState } from 'react';
import Icon from './Icon.jsx';
import { TrackRow, plural } from './common.jsx';
import { match } from './Import.jsx';
import { useStore } from '../lib/store.js';
import { playTrack } from '../lib/player.js';
import { canReadYandex, readYandex } from '../lib/yandex.js';

// Experiment, only in builds made with VITE_YANDEX_TAB=1 (yandex-test.bat): the listener's
// Yandex Music likes inside «Любимое», read live from their public profile and played through
// Blink's usual sources. Nothing is played from Yandex: its audio is signed and encrypted for its
// own apps. Lives on this computer only (localStorage), nothing goes to the cloud library.
export const yandexTab = import.meta.env.VITE_YANDEX_TAB === '1' && canReadYandex;

const KEY = 'blink.yandexLikes';
const STALE = 6 * 60 * 60 * 1000;
const load = () => {
  try {
    return JSON.parse(localStorage.getItem(KEY)) || {};
  } catch {
    return {};
  }
};
const save = (v) => {
  try {
    if (v) localStorage.setItem(KEY, JSON.stringify(v));
    else localStorage.removeItem(KEY);
  } catch {}
};

export default function YandexLikes() {
  const country = useStore((s) => s.settings.country);
  const [lib, setLib] = useState(load); // { login, tracks, total, at }
  const [run, setRun] = useState(null); // { done, total } while matching, { error } after a failure
  const [login, setLogin] = useState(lib.login || '');

  const refresh = async (who) => {
    setRun({ done: 0, total: 0 });
    let items;
    try {
      ({ items } = await readYandex(`https://music.yandex.ru/users/${encodeURIComponent(who)}/tracks`));
    } catch (e) {
      return setRun({ error: e.status === 404 ? 'Яндекс не отдал лайки. Проверьте логин и включите «Публичный профиль» в настройках Яндекс Музыки' : 'Яндекс Музыка не ответила. Если вы не в России, она может быть недоступна' });
    }
    const found = new Array(items.length);
    let i = 0;
    let done = 0;
    const worker = async () => {
      while (i < items.length) {
        const n = i++;
        found[n] = await match(items[n], country);
        setRun({ done: ++done, total: items.length });
      }
    };
    await Promise.all([worker(), worker(), worker(), worker()]);
    const tracks = [...new Map(found.filter(Boolean).map((t) => [t.id, t])).values()];
    const next = { login: who, tracks, total: items.length, at: Date.now() };
    save(next);
    setLib(next);
    setRun(null);
  };

  useEffect(() => {
    if (lib.login && Date.now() - (lib.at || 0) > STALE) refresh(lib.login);
  }, []);

  const busy = run && !run.error;
  const progress = busy && (run.total ? `Ищу треки в Blink: ${run.done} из ${run.total}` : 'Читаю лайки Яндекса…');

  if (!lib.login)
    return (
      <div className="err-box">
        <h3>Лайки из Яндекс Музыки</h3>
        <p>Введите логин Яндекса. Профиль в Яндекс Музыке должен быть публичным. Треки играют через Blink.</p>
        <form
          className="field"
          style={{ maxWidth: 420, margin: '18px auto 0' }}
          onSubmit={(e) => {
            e.preventDefault();
            if (login.trim() && !busy) refresh(login.trim());
          }}
        >
          <input value={login} onChange={(e) => setLogin(e.target.value)} placeholder="Логин Яндекса" autoFocus />
          <button className="btn primary" disabled={!login.trim() || busy}>
            Подключить
          </button>
        </form>
        <div className={run && run.error ? 'field-err' : 'field-ok'}>{(run && run.error) || progress || ''}</div>
      </div>
    );

  const tracks = lib.tracks || [];
  return (
    <>
      <div className="actions" style={{ marginBottom: 16, alignItems: 'center' }}>
        <button className="btn primary" disabled={!tracks.length} onClick={() => playTrack(tracks[0], tracks, 0)}>
          <Icon name="play" size={18} /> Слушать
        </button>
        <button className="btn ghost" disabled={busy} onClick={() => refresh(lib.login)}>
          Обновить
        </button>
        <button
          className="btn ghost"
          disabled={busy}
          onClick={() => {
            save(null);
            setLib({});
            setRun(null);
          }}
        >
          Отключить
        </button>
        <span style={{ color: 'var(--mute)', fontSize: 13, fontWeight: 600 }}>
          {(run && run.error) || progress || `Яндекс Музыка · ${lib.login} · нашлось ${plural(tracks.length, 'трек', 'трека', 'треков')} из ${lib.total}`}
        </span>
      </div>
      <div className="tracks">
        {tracks.map((t, i) => (
          <TrackRow key={t.id} track={t} list={tracks} index={i} playlistId={null} />
        ))}
      </div>
    </>
  );
}
