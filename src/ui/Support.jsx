// One-off support for Blink × Spherical through RollyPay. Any payment gives the «Хранитель» badge
// (public table supporters); the more you give in total, the higher the rung: Хранитель, Хранитель II, Хранитель III.
import { useEffect, useState } from 'react';
import { humanError } from '../lib/errors.js';
import { useStore, store } from '../lib/store.js';
import { cloud } from '../lib/cloud.js';
import { plusCall, usePlusConfig, tierFor } from '../lib/plus.js';
import eye from './spherical-eye.png';

const AMOUNTS = [100, 300, 500, 1000];
const MIN = 50;
const MAX = 50000;
const fmt = (iso) => new Date(iso).toLocaleDateString('ru-RU', { day: 'numeric', month: 'long', year: 'numeric' });
const rub = (n) => `${Number(n).toLocaleString('ru-RU')} ₽`;

// Blink's own mark (the "b.") in one pearl colour, to stand next to Spherical's eye at the same height.
export function BlinkMark() {
  return (
    <span className="bk-mark" aria-hidden="true">
      b<i />
    </span>
  );
}
export function Lockup() {
  return (
    <span className="keep-lock" aria-hidden="true">
      <BlinkMark />
      <img src={eye} alt="" />
    </span>
  );
}

// The badge. Without `since` it shows the signed-in account's own status.
export function KeeperChip({ since, tier }) {
  const mine = useStore((s) => s.supporter);
  const myTier = useStore((s) => s.keeperTier);
  const cfg = usePlusConfig();
  const date = since === undefined ? mine : since;
  if (!date) return null;
  const level = Math.max(1, (since === undefined ? myTier : tier) || 1);
  const rung = cfg.tiers.find((t) => t.id === level) || cfg.tiers[0];
  return (
    <span className="keep-chip" data-tier={level} title={`${rung.name} · поддерживает Blink × Spherical с ${fmt(date)}`}>
      {rung.name}
    </span>
  );
}

// Since-date and rung of a profile owner's support, or null.
export function useKeeper(userId) {
  const [k, setK] = useState(null);
  useEffect(() => {
    setK(null);
    if (!cloud || !userId) return;
    const q = (cols) => cloud.from('supporters').select(cols).eq('user_id', userId).maybeSingle();
    // Before the tiers column exists on the server the plain date still works.
    q('since, tier')
      .then(({ data, error }) => (error ? q('since').then((r) => r.data) : data))
      .then((d) => setK(d ? { since: d.since, tier: d.tier || 1 } : null), () => {});
  }, [userId]);
  return k;
}

// Settings → Blink+: the «support Blink × Spherical» card with the ladder.
export default function SupportCard() {
  const user = useStore((s) => s.user);
  const since = useStore((s) => s.supporter);
  const donated = useStore((s) => s.donated) || 0;
  const cfg = usePlusConfig();
  const [amount, setAmount] = useState(300);
  const [custom, setCustom] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const sum = custom ? Math.round(Number(custom)) : amount;
  const ok = sum >= MIN && sum <= MAX;

  const tiers = cfg.tiers;
  const now = tierFor(tiers, donated);
  const next = tiers.find((t) => t.id > now);
  const gap = next ? Math.ceil(next.from - donated) : 0;
  const after = ok ? tierFor(tiers, donated + sum) : now;
  const goal = next && gap >= MIN && gap <= MAX && !AMOUNTS.includes(gap) ? gap : 0;
  // How far the line is filled: whole rungs reached, plus the share of the way to the next one.
  const idx = Math.max(0, now - 1);
  const part = next && now ? (donated - tiers[idx].from) / (next.from - tiers[idx].from) : 0;
  const fill = now ? Math.min(1, (idx + part) / Math.max(1, tiers.length - 1)) : 0;

  const pay = async () => {
    if (!user) return store.set({ sheet: 'account' });
    setErr('');
    setBusy(true);
    try {
      const r = await plusCall('donate', { amount: sum });
      // On the site a pop-up opened after an await gets blocked, so go to the page instead.
      if (window.blink && !window.blink.isWeb) window.blink.open(r.pay_url);
      else location.href = r.pay_url;
    } catch (e) {
      setErr(humanError(e));
    }
    setBusy(false);
  };
  return (
    <div className="keep-card">
      <img className="keep-eye" src={eye} alt="" />
      <div className="keep-brand">
        <Lockup />
        Blink <span>×</span> Spherical
      </div>
      <div className="keep-title">Стать Хранителем</div>
      <p className="keep-text">
        {since
          ? `Вы с нами с ${fmt(since).replace(/\.$/, "")}. Поддержки складываются: чем больше всего, тем выше ваш значок.`
          : 'Музыка в Blink бесплатная, и мы хотим, чтобы так и осталось. Любая сумма помогает платить за серверы. Взамен вы получите значок в профиле, а чем больше поддержите, тем выше он станет.'}
      </p>

      <div className="keep-ladder" style={{ '--n': tiers.length, '--fill': fill }}>
        {tiers.map((t) => (
          <div key={t.id} data-tier={t.id} className={'keep-rung' + (t.id <= now ? ' got' : '') + (t.id === now ? ' now' : '')}>
            <i />
            <b>{t.name}</b>
            <small>от {rub(t.from)}</small>
          </div>
        ))}
      </div>
      {user && next && <div className="keep-goal">{now ? <>Вы поддержали на <b>{rub(donated)}</b>. </> : null}До «{next.name}» ещё <b>{rub(gap)}</b>.</div>}

      <div className="keep-amounts">
        {goal > 0 && (
          <button className={'keep-amt goal' + (!custom && amount === goal ? ' on' : '')} onClick={() => (setAmount(goal), setCustom(''))}>
            {rub(goal)} · до «{next.name}»
          </button>
        )}
        {AMOUNTS.map((a) => (
          <button key={a} className={'keep-amt' + (!custom && amount === a ? ' on' : '')} onClick={() => (setAmount(a), setCustom(''))}>
            {a} ₽
          </button>
        ))}
        <label className={'keep-amt keep-own' + (custom ? ' on' : '')}>
          <input inputMode="numeric" value={custom} onChange={(e) => setCustom(e.target.value.replace(/\D/g, '').slice(0, 5))} placeholder="Своя" />
          {custom && '₽'}
        </label>
      </div>
      <div className="field-err">{custom && !ok ? `От ${MIN} до ${MAX.toLocaleString('ru-RU')} ₽` : err}</div>
      <button className="btn keep-btn" disabled={busy || !ok} onClick={pay}>
        {user ? `Поддержать на ${rub(sum)}` : 'Войти и поддержать'}
      </button>
      <div className="fine keep-fine">
        Разовый платёж через RollyPay, повторно ничего не списывается.
        {ok && after > now && (
          <span className="keep-chip" data-tier={after}>
            {(tiers.find((t) => t.id === after) || tiers[0]).name}
          </span>
        )}
      </div>
    </div>
  );
}
