import { useEffect, useRef, useState } from 'react';
import Icon from './Icon.jsx';
import { useStore } from '../lib/store.js';
import { runStatus } from '../lib/status.js';

const DOT = { up: 'Работает', slow: 'С задержкой', down: 'Недоступно', off: 'Выключено' };
const OVERALL = {
  up: 'Все сервисы работают',
  slow: 'Есть замедления или мелкие сбои',
  down: 'Часть сервисов недоступна',
};

function ago(at) {
  if (!at) return '';
  const s = Math.round((Date.now() - at) / 1000);
  if (s < 60) return 'только что';
  const m = Math.round(s / 60);
  return `${m} мин назад`;
}

// The wifi glyph, coloured by overall state. Used here and in Settings.
export function StatusGlyph({ state, size = 20 }) {
  return <Icon name="wifi" size={size} className={'svc-glyph svc-' + (state || 'wait')} />;
}

export default function StatusSheet() {
  const svc = useStore((s) => s.svc);
  const [busy, setBusy] = useState(false);
  const timer = useRef(null);

  const check = () => {
    setBusy(true);
    runStatus().finally(() => setBusy(false));
  };

  useEffect(() => {
    check();
    // Keep it fresh while the sheet is open, then stop.
    timer.current = setInterval(check, 30000);
    return () => clearInterval(timer.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const rows = (svc && svc.rows) || [];
  const overall = svc ? svc.overall : 'wait';

  return (
    <>
      <div className="label" style={{ marginBottom: 10 }}>
        Состояние сервисов
      </div>
      <div className={'svc-head svc-' + overall}>
        <StatusGlyph state={overall} size={26} />
        <div>
          <h2 style={{ margin: 0 }}>{busy && !rows.length ? 'Проверяю…' : OVERALL[overall] || 'Проверяю…'}</h2>
          <div className="svc-sub">{svc ? `обновлено ${ago(svc.at)}` : 'первая проверка'}</div>
        </div>
        <button className="btn ghost svc-refresh" onClick={check} disabled={busy} title="Проверить снова">
          <Icon name={busy ? 'wave' : 'repeat'} size={16} /> {busy ? 'Проверяю' : 'Обновить'}
        </button>
      </div>

      <div className="svc-list">
        {(rows.length ? rows : SKELETON).map((r) => (
          <div className="svc-row" key={r.key} title={r.note || ''}>
            <span className={'svc-ic svc-ic-' + (r.state || 'wait')}>
              <Icon name={r.icon || 'wifi'} size={17} />
            </span>
            <div className="svc-name">
              <b>{r.label}</b>
              <small>{r.note || r.desc}</small>
            </div>
            <div className="svc-meta">
              <span className="svc-state">
                <i className={'svc-dot svc-' + (r.state || 'wait')} />
                {DOT[r.state] || '…'}
              </span>
              {r.ms != null && r.state !== 'off' && <span className="svc-ms">{r.ms} мс</span>}
            </div>
          </div>
        ))}
      </div>

      <p className="svc-foot">Проверяется автоматически. Это состояние сервисов, а не вашего интернета.</p>
    </>
  );
}

const SKELETON = [
  { key: 'yt', label: 'YouTube', desc: ' ', icon: 'youtube' },
  { key: 'server', label: 'Сервер Blink', desc: ' ', icon: 'library' },
  { key: 'meta', label: 'Поиск и метаданные', desc: ' ', icon: 'search' },
  { key: 'lyrics', label: 'Тексты песен', desc: ' ', icon: 'lyrics' },
  { key: 'accounts', label: 'Аккаунт и синхронизация', desc: ' ', icon: 'user' },
  { key: 'charts', label: 'Чарты', desc: ' ', icon: 'eq' },
  { key: 'relay', label: 'YouTube через сервер', desc: ' ', icon: 'wifi' },
  { key: 'api', label: 'API', desc: ' ', icon: 'api' },
];
