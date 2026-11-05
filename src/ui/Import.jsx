import { useState } from 'react';
import { store, useStore, createPlaylist, requireAccount } from '../lib/store.js';
import { search } from '../lib/api.js';
import { MEDIA } from '../lib/catalog.js';
import { canReadYandex, readYandex } from '../lib/yandex.js';
import { plural } from './common.jsx';

import { humanError } from '../lib/errors.js';
// Reads a TuneMyMusic export (CSV) or any list of "Artist - Track" lines.
function parseList(text) {
  const lines = text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (!lines.length) return [];
  const splitCsv = (line) => {
    const out = [];
    let cur = '';
    let q = false;
    for (let i = 0; i < line.length; i++) {
      const c = line[i];
      if (c === '"') {
        if (q && line[i + 1] === '"') (cur += '"'), i++;
        else q = !q;
      } else if ((c === ',' || c === ';') && !q) out.push(cur.trim()), (cur = '');
      else cur += c;
    }
    out.push(cur.trim());
    return out;
  };
  const head = splitCsv(lines[0]).map((h) => h.toLowerCase());
  const ti = head.findIndex((h) => /track|title|трек|назв/.test(h));
  const ai = head.findIndex((h) => /artist|исполн|артист/.test(h));
  if (ti >= 0 && ai >= 0) {
    return lines
      .slice(1)
      .map(splitCsv)
      .map((r) => ({ artist: r[ai] || '', title: r[ti] || '' }))
      .filter((r) => r.title);
  }
  return lines
    .map((l) => {
      const m = l.split(/\s+[-–—]\s+/);
      return m.length >= 2 ? { artist: m[0], title: m.slice(1).join(' - ') } : { artist: '', title: l };
    })
    .filter((r) => r.title);
}

// A Spotify playlist or album link: our server reads its track list (open ones only).
const SPOTIFY = /open\.spotify\.com\/(?:intl-[a-z-]+\/)?(?:playlist|album)\/[A-Za-z0-9]+|spotify:(?:playlist|album):[A-Za-z0-9]+/;

// A Yandex Music playlist, album, track or «Мне нравится» link (public ones only).
const YANDEX = /(?:https?:\/\/)?music\.yandex\.[a-z]{2,3}\/(?:users\/[^/\s]+\/(?:playlists\/\d+|tracks)|playlists\/[A-Za-z0-9.-]+|album\/\d+(?:\/track\/\d+)?)/;

const SOURCES = [
  { re: SPOTIFY, name: 'Spotify', api: 'spotify', closed: 'Spotify не отдал этот плейлист. Открытые плейлисты и альбомы переносятся, а закрытые и подборки самого Spotify нет' },
  { re: YANDEX, name: 'Яндекс Музыки', api: 'yandex', closed: 'Яндекс не отдал этот плейлист. Сделайте его публичным (для «Мне нравится» откройте профиль в настройках Яндекс Музыки) и попробуйте ещё раз' },
];
const sourceOf = (text) => SOURCES.find((s) => s.re.test(text));

async function readLink(src, link) {
  // The desktop app reads Yandex itself: Yandex blocks our server by country.
  if (src.api === 'yandex' && canReadYandex) {
    const d = await readYandex(link).catch((e) => ({ status: e.status || 0 }));
    if (d.items && d.items.length) return { name: d.name, list: d.items };
    if (d.items || d.status === 404) throw new Error(src.closed);
    throw new Error('Яндекс Музыка не ответила. Если вы не в России, она может быть недоступна, попробуйте ещё раз или через VPN');
  }
  const r = await fetch(`${MEDIA}/api/${src.api}/list?url=${encodeURIComponent(link)}`).catch(() => null);
  const d = r ? await r.json().catch(() => ({})) : {};
  if (r && r.ok && d.items && d.items.length) return { name: d.name, list: d.items };
  if (r && (r.status === 404 || (r.ok && d.items))) throw new Error(src.closed);
  if (src.api === 'yandex') throw new Error('В браузере Яндекс Музыка не отдаёт плейлисты. Перенесите их в приложении Blink для компьютера или загрузите CSV из TuneMyMusic');
  throw new Error('Не получилось прочитать ссылку, попробуйте ещё раз');
}

const norm = (s) => s.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();

export async function match(ref, country) {
  const YM_SEARCH = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '') + '/api/yandex/search';
  try {
    const r = await search(`${ref.artist} ${ref.title}`, country);
    const a = norm(ref.artist.split(/,|&/)[0] || '');
    const t = norm(ref.title.replace(/\(.*?\)/g, ''));
    const found = r.tracks.find((x) => norm(x.artist).includes(a) && norm(x.title).includes(t)) || r.tracks.find((x) => norm(x.artist).includes(a)) || null;

    if (found) {
      // If no artwork yet, or has temp APIBlink URL, fetch stable Yandex artwork via search
      const hasStableArtwork = found.artwork && !/\/api\/apiblink\/artwork\//.test(found.artwork);
      if (!hasStableArtwork) {
        try {
          // Use /api/yandex/search which returns stable avatars.yandex.net URLs
          const ym = await fetch(`${YM_SEARCH}?q=${encodeURIComponent(ref.artist + ' ' + ref.title)}&type=track&limit=5`, {
            signal: AbortSignal.timeout(8000),
          });
          if (ym.ok) {
            const ymData = await ym.json();
            const results = ymData.results || [];
            const normStr = (s) => (s || '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
            const hit = results.find((x) =>
              x.kind === 'song' &&
              normStr(x.trackName || '').includes(normStr(ref.title)) &&
              normStr(x.artistName || '').includes(normStr((ref.artist || '').split(/,|&/)[0]))
            ) || results.find((x) => x.kind === 'song');
            if (hit && (hit.artworkUrl600 || hit.artworkUrl100)) {
              return { ...found, artwork: hit.artworkUrl600 || hit.artworkUrl100 };
            }
          }
        } catch { /* ignore, use iTunes artwork */ }
      }
    }
    return found;
  } catch {
    return null;
  }
}

export default function ImportSheet({ onClose }) {
  const country = useStore((s) => s.settings.country);
  const [text, setText] = useState('');
  const [target, setTarget] = useState('likes');
  const [run, setRun] = useState(null);

  const load = (file) => {
    const fr = new FileReader();
    fr.onload = () => setText(String(fr.result || ''));
    fr.readAsText(file);
  };

  const start = async () => {
    if (!requireAccount('save')) return;
    const src = sourceOf(text);
    let list;
    let name = '';
    if (src) {
      setRun({ reading: true });
      try {
        ({ list, name } = await readLink(src, src.re.exec(text)[0]));
      } catch (e) {
        return setRun({ error: humanError(e) });
      }
    } else list = parseList(text);
    list = list.slice(0, 2000);
    if (!list.length) return setRun({ error: 'Не нашёл треков в тексте' });
    const title = (name || 'Перенесённое').slice(0, 80);
    const found = [];
    const missed = [];
    setRun({ done: 0, total: list.length });
    let i = 0;
    const worker = async () => {
      while (i < list.length) {
        const ref = list[i++];
        const t = await match(ref, country);
        if (t) found.push(t);
        else missed.push(ref);
        setRun({ done: found.length + missed.length, total: list.length });
      }
    };
    await Promise.all([worker(), worker(), worker(), worker()]);
    const uniq = [...new Map(found.map((t) => [t.id, t])).values()];
    if (target === 'likes') {
      const s = store.get();
      const have = new Set(s.likes.map((t) => t.id));
      store.set({ likes: [...uniq.filter((t) => !have.has(t.id)), ...s.likes] });
    } else {
      createPlaylist(title, uniq);
    }
    setRun({ finished: true, found: uniq.length, missed, total: list.length, title });
  };

  if (run && run.finished)
    return (
      <>
        <h2>Готово</h2>
        <p>
          Перенесено {plural(run.found, 'трек', 'трека', 'треков')} из {run.total} {target === 'likes' ? 'в «Любимое»' : `в плейлист «${run.title}»`}.
        </p>
        {run.missed.length > 0 && (
          <div className="import-missed">
            <div className="label" style={{ marginBottom: 8 }}>
              Не нашлись ({run.missed.length})
            </div>
            {run.missed.slice(0, 50).map((m, k) => (
              <div key={k}>
                {m.artist ? `${m.artist} — ` : ''}
                {m.title}
              </div>
            ))}
          </div>
        )}
        <button className="btn primary" style={{ marginTop: 16 }} onClick={onClose}>
          Отлично
        </button>
      </>
    );

  return (
    <>
      <div className="label" style={{ marginBottom: 12 }}>
        Перенос музыки
      </div>
      <h2>Перенесите свою музыку в Blink</h2>
      <ol className="steps">
        <li>
          <div>
            <b>Скопируйте ссылку на плейлист</b>
            <small>
              В Яндекс Музыке: «Поделиться» → «Скопировать ссылку». Плейлист должен быть публичным, а для «Мне нравится» откройте профиль в настройках. Подойдут и альбомы, и ссылки Spotify.
            </small>
          </div>
        </li>
        <li>
          <div>
            <b>Вставьте её в поле ниже</b>
            <small>Или загрузите CSV (например, из TuneMyMusic), или вставьте список, по треку в строке: «Артист — Название».</small>
          </div>
          <label className="go" style={{ cursor: 'pointer' }}>
            Выбрать файл
            <input type="file" accept=".csv,.txt" hidden onChange={(e) => e.target.files[0] && load(e.target.files[0])} />
          </label>
        </li>
      </ol>
      <textarea className="import-text" value={text} onChange={(e) => setText(e.target.value)} placeholder={'https://music.yandex.ru/users/…/playlists/…\n\nили списком:\nMiyagi & Andy Panda — Kosandra'} spellCheck={false} />
      <div className="import-target">
        <button className={target === 'likes' ? 'on' : ''} onClick={() => setTarget('likes')}>
          В «Любимое»
        </button>
        <button className={target === 'playlist' ? 'on' : ''} onClick={() => setTarget('playlist')}>
          В новый плейлист
        </button>
      </div>
      {run && !run.error ? (
        <div className="import-progress">
          <span>{run.reading ? 'Читаю плейлист…' : `Ищу треки… ${run.done} из ${run.total}`}</span>
          <span className="bar">
            <i style={{ width: (run.reading ? 0 : (run.done / run.total) * 100) + '%' }} />
          </span>
        </div>
      ) : (
        <>
          <button className="btn primary" disabled={!text.trim()} onClick={start}>
            {sourceOf(text) ? `Перенести из ${sourceOf(text).name}` : `Перенести ${text.trim() ? plural(parseList(text).length, 'трек', 'трека', 'треков') : ''}`}
          </button>
          <div className="field-err">{run && run.error}</div>
        </>
      )}
    </>
  );
}
