import { useEffect, useState } from 'react';
import { store, toast } from '../lib/store.js';
import { Switch } from './common.jsx';
import { ask } from './Confirm.jsx';
import Icon from './Icon.jsx';
import logo from './island.svg';

// Blink Island is a separate Windows app; the main process installs and runs it.
// The web and old Blink builds (no island bridge) only see the description and a download link.
const FEED = 'https://blinkmusic.cc/download/island/';
const island = () => window.blink && window.blink.island;

// Launch the island with Blink when the listener turned it on (a second launch is a no-op).
export function useIslandAutostart(loaded) {
  useEffect(() => {
    if (loaded && store.get().settings.islandAuto && island()) island().launch();
  }, [loaded]);
}

const FEATURES = [
  'Карточка трека из Blink и волна под бас прямо у верхнего края экрана',
  'Alt+Space: быстрые команды и история буфера обмена',
  'Полка файлов, таймер и напоминания',
  'Погода и пульт: Wi-Fi, Bluetooth, тема, режим тишины',
  'Запись экрана, повтор последних секунд в играх и чистый микрофон',
];

export default function IslandTab({ on, set }) {
  const bridge = island();
  const [st, setSt] = useState(null);
  const [busy, setBusy] = useState(null);
  const [webFile, setWebFile] = useState(null);

  const refresh = () => bridge.status().then(setSt);
  useEffect(() => {
    if (!bridge) {
      fetch(FEED + 'latest.json')
        .then((r) => r.json())
        .then((d) => setWebFile(d.file))
        .catch(() => {});
      return;
    }
    refresh();
    return bridge.onProgress((p) => setBusy(p.phase === 'download' ? `Загрузка ${p.pct}%` : 'Распаковка…'));
  }, []);

  const install = async () => {
    setBusy('Загрузка…');
    const r = await bridge.install();
    setBusy(null);
    if (r.ok) toast('Blink Island запущен');
    else toast(r.error, 'error');
    refresh();
  };
  const remove = async () => {
    if (!(await ask({ title: 'Удалить Blink Island?', text: 'Островок закроется, его файлы будут удалены.', ok: 'Удалить', danger: true }))) return;
    const r = await bridge.remove();
    if (!r.ok) toast(r.error, 'error');
    refresh();
  };

  const installed = st && st.version;
  let actions;
  if (!bridge)
    actions = (
      <button className="btn primary" onClick={() => window.blink.open(webFile ? FEED + webFile : 'https://blinkmusic.cc/download/')}>
        Скачать <Icon name="external" size={15} />
      </button>
    );
  else if (busy || (st && st.busy)) actions = <span className="island-busy">{busy || 'Устанавливается…'}</span>;
  else if (!st) actions = <span className="island-busy">Проверяю…</span>;
  else if (!installed)
    actions = (
      <button className="btn primary" onClick={install} disabled={!st.latest} title={st.latest ? '' : 'Сервер обновлений недоступен'}>
        Установить
      </button>
    );
  else
    actions = (
      <>
        {st.update && (
          <button className="btn primary" onClick={install}>
            Обновить до {st.latest}
          </button>
        )}
        <button className="btn ghost" onClick={() => bridge.launch()}>
          Запустить
        </button>
        <button className="btn ghost" onClick={remove}>
          Удалить
        </button>
      </>
    );

  return (
    <>
      <div className="game-card island-card">
        <div className="gc-head">
          <img className="island-logo" src={logo} alt="" width="44" height="44" />
          <div className="island-title">
            <div className="k">Blink Island</div>
            <div className="d">{installed ? `Установлен, версия ${st.version}` : 'Динамический остров у верхнего края Windows'}</div>
          </div>
        </div>
        <ul className="gc-list">
          {FEATURES.map((f) => (
            <li key={f}>{f}</li>
          ))}
        </ul>
        <p className="island-privacy">Всё работает на вашем компьютере. В сеть островок ходит только за погодой и обложками.</p>
        <div className="island-actions">{actions}</div>
      </div>
      {installed && (
        <div className="set-row">
          <div>
            <div className="k">Запускать вместе с Blink</div>
            <div className="d">Островок откроется, когда вы запустите Blink</div>
          </div>
          <Switch on={on} onChange={(islandAuto) => set({ islandAuto })} />
        </div>
      )}
    </>
  );
}
