import { useEffect, useState } from 'react';
import { humanError } from '../lib/errors.js';
import { useStore, store, toast, go } from '../lib/store.js';
import { plural } from './common.jsx';
import Icon from './Icon.jsx';
import { plusCall, usePlus, usePlusConfig, monthly } from '../lib/plus.js';

const fmt = (iso) => new Date(iso).toLocaleDateString('ru-RU', { day: 'numeric', month: 'long', year: 'numeric' });
const rub = (n) => `${Number(n).toLocaleString('ru-RU')} ₽`;
const daysLeft = (iso) => Math.max(1, Math.ceil((Date.parse(iso) - Date.now()) / 86400000));

// Small «Blink+» mark next to a subscriber's name.
export function PlusChip() {
  const until = useStore((s) => s.plus);
  if (!usePlus()) return null;
  return (
    <span className="plus-chip" role="link" title={`Blink+ до ${fmt(until)}`} onClick={() => (store.set({ sheet: null }), go('plus'))}>
      Blink<b>+</b>
    </span>
  );
}

// Header button for people without a subscription: quiet, but always there.
export function PlusNavButton() {
  if (usePlus()) return null;
  return (
    <button className="plus-nav" title="Что даёт Blink+" onClick={() => go('plus')}>
      Blink<b>+</b>
    </button>
  );
}

const OFF_KEY = 'blink.plusPromoOff';
const promoHidden = () => {
  try {
    return Date.now() - Number(localStorage.getItem(OFF_KEY) || 0) < 14 * 86400000;
  } catch {
    return false;
  }
};

// A slim strip for the library: what Blink+ gives and from what price. Closes for two weeks.
export function PlusPromo() {
  const plus = usePlus();
  const cfg = usePlusConfig();
  const [off, setOff] = useState(promoHidden);
  if (plus || off) return null;
  const from = Math.min(...cfg.plans.map(monthly));
  return (
    <div className="plus-promo" role="link" tabIndex={0} onClick={() => go('plus')} onKeyDown={(e) => e.key === 'Enter' && go('plus')}>
      <span className="plus-orb">+</span>
      <span>
        <span className="plus-promo-t">
          Blink<b>+</b>
        </span>
        <span className="plus-promo-d">{cfg.perks.slice(0, 3).map((p) => p.title).join(' · ')}</span>
      </span>
      <span className="plus-promo-p">от {rub(from)} в месяц</span>
      <button
        className="plus-promo-x"
        title="Скрыть на две недели"
        onClick={(e) => {
          e.stopPropagation();
          try { localStorage.setItem(OFF_KEY, String(Date.now())); } catch {}
          setOff(true);
        }}
      >
        <Icon name="close" size={14} />
      </button>
    </div>
  );
}

// Blink+ page: what it gives, how others see you, the plans and the pay button.
export function PlusPage({ children }) {
  const plus = usePlus();
  const cfg = usePlusConfig();
  const user = useStore((s) => s.user);
  const name = user ? user.name || user.email || 'Вы' : 'Ваш ник';
  const toPay = () => document.getElementById('plus-pay')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  return (
    <div className="set-page plus-page">
      <div className="plus-hero">
        <div>
          <span className="plus-word">
            Blink<b>+</b>
          </span>
          <p>{plus ? 'Подписка активна. Спасибо, что вы с нами!' : cfg.lead}</p>
          {!plus && (
            <button className="btn primary plus-hero-cta" onClick={toPay}>
              Выбрать тариф
            </button>
          )}
        </div>
        <div className="plus-stage">
          <span className="avatar on plus big">{user && user.avatar ? <img src={user.avatar} alt="" referrerPolicy="no-referrer" /> : name.slice(0, 1).toUpperCase()}</span>
          <div className="plus-stage-name">
            <span>{name}</span>
            <span className="plus-chip">
              Blink<b>+</b>
            </span>
          </div>
          <div className="plus-stage-cap">{plus ? 'Так вас видят другие' : 'Так будет выглядеть ваш профиль'}</div>
        </div>
      </div>

      <section>
        <h2 className="plus-h">Что внутри</h2>
        <div className="plus-perks">
          {cfg.perks.map((p) => (
            <div key={p.title} className="plus-perk">
              <span className="plus-perk-ic">
                <Icon name={p.icon} size={19} />
              </span>
              <div>
                <b>{p.title}</b>
                <p>{p.text}</p>
              </div>
            </div>
          ))}
        </div>
      </section>

      <section>
        <h2 className="plus-h">Бесплатно и с Blink+</h2>
        <div className="plus-cmp">
          <div className="plus-cmp-row head">
            <span />
            <span>Free</span>
            <span>Blink+</span>
          </div>
          {cfg.compare.map((r) => (
            <div key={r.label} className="plus-cmp-row">
              <span>{r.label}</span>
              <span>{r.free ? <i className="yes free"><Icon name="check" size={13} stroke={2.4} /></i> : <i className="no" />}</span>
              <span>{r.plus ? <i className="yes"><Icon name="check" size={13} stroke={2.4} /></i> : <i className="no" />}</span>
            </div>
          ))}
        </div>
      </section>

      <section id="plus-pay">
        <h2 className="plus-h">{plus ? 'Продлить' : 'Оформить'}</h2>
        <PlusPane cfg={cfg} />
      </section>
      {children}
    </div>
  );
}

function PlusPane({ cfg }) {
  const user = useStore((s) => s.user);
  const [me, setMe] = useState(null);
  const [plan, setPlan] = useState('year');
  const [code, setCode] = useState('');
  const [discount, setDiscount] = useState(null); // { code, percent }
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  const load = () =>
    user &&
    plusCall('me').then(
      (d) => (setMe(d), store.set({ plus: d.active ? d.plus_until : null, supporter: d.supporter_since || null, keeperTier: d.keeper_tier || 0, donated: d.donated || 0 })),
      (e) => setErr(humanError(e))
    );
  useEffect(() => {
    load();
    // Back from the payment page: show the new status.
    window.addEventListener('focus', load);
    return () => window.removeEventListener('focus', load);
  }, [user]);

  if (!user)
    return (
      <div className="set-row">
        <div>
          <div className="k">Blink+</div>
          <div className="d">Войдите, чтобы оформить подписку</div>
        </div>
        <button className="btn ghost" onClick={() => store.set({ sheet: 'account' })}>Войти</button>
      </div>
    );

  const applyCode = async () => {
    setErr('');
    setBusy(true);
    try {
      const r = await plusCall('promo', { code });
      if (r.kind === 'plus') {
        toast(`Blink+ на ${r.days} дн. активирован`);
        setCode('');
        load();
      } else setDiscount(r);
    } catch (e) {
      setErr(humanError(e));
    }
    setBusy(false);
  };

  const pay = async () => {
    setErr('');
    setBusy(true);
    try {
      const r = await plusCall('checkout', { plan, code: discount ? discount.code : '' });
      // On the site a pop-up opened after an await gets blocked, so go to the page instead.
      if (window.blink && !window.blink.isWeb) window.blink.open(r.pay_url);
      else location.href = r.pay_url;
    } catch (e) {
      setErr(humanError(e));
    }
    setBusy(false);
  };

  const price = (p) => (discount ? Math.max(1, Math.round(p.price * (100 - discount.percent)) / 100) : p.price);
  const plans = cfg.plans;
  const month = plans.find((p) => p.days < 365);
  const year = plans.find((p) => p.days >= 365);
  const save = month && year ? Math.round((1 - year.price / (month.price * 12)) * 100) : 0;
  const tag = (p) => p.tag || (p === year && save > 0 ? `−${save}%` : '');
  const left = me && me.active ? daysLeft(me.plus_until) : 0;

  return (
    <div className="plus-pane">
      {me && me.active ? (
        <div className="plus-card">
          <div className="plus-card-top">
            <span className="plus-card-until">Подписка активна до {fmt(me.plus_until)}</span>
            <span className="plus-left">{plural(left, 'день', 'дня', 'дней')}</span>
          </div>
          <div className="plus-meter"><i style={{ width: `${Math.min(100, (left / 30) * 100)}%` }} /></div>
          <div className="plus-card-thanks">
            {left <= 7 ? 'Скоро закончится. Продлить можно уже сейчас: дни сложатся.' : 'Спасибо, что поддерживаете Blink. Продлить можно заранее: дни сложатся.'}
          </div>
        </div>
      ) : null}
      <div className="plus-plans">
        {plans.map((p) => (
          <button key={p.id} className={'plus-plan' + (plan === p.id ? ' on' : '')} onClick={() => setPlan(p.id)}>
            <span className="t">{p.label}</span>
            <span className="p">
              {(discount || p.old) && <s>{rub(discount ? p.price : p.old)}</s>} {rub(price(p))}
            </span>
            <span className="m">{p.days >= 365 ? `${rub(Math.round(price(p) / 12))} в месяц` : 'на 30 дней'}</span>
            {tag(p) && <span className="tag">{tag(p)}</span>}
          </button>
        ))}
      </div>
      <div className="field">
        <input value={code} onChange={(e) => (setCode(e.target.value), setDiscount(null))} placeholder="Промокод" maxLength={40} />
        <button className="btn ghost" disabled={busy || !code.trim()} onClick={applyCode}>Применить</button>
      </div>
      {discount && <div className="fine">Скидка {discount.percent}% применится при оплате</div>}
      <div className="field-err">{err}</div>
      <button className="btn primary" disabled={busy || !me} onClick={pay}>
        {me && me.active ? 'Продлить' : 'Оформить'} Blink+
      </button>
      <div className="fine">Оплата через RollyPay: СБП или криптовалюта. Подписка не продлевается сама.</div>
    </div>
  );
}
