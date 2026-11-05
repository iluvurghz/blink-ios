// Blink+ and one-off support: status, promo codes and pay links (server: server/plusRoute.js).
import { useEffect, useState } from 'react';
import { MEDIA } from './catalog.js';
import { cloud } from './cloud.js';
import { store, useStore } from './store.js';

export async function plusCall(path, body) {
  const { data } = cloud ? await cloud.auth.getSession() : { data: {} };
  const t = data && data.session ? data.session.access_token : null;
  const res = await fetch(MEDIA + '/api/plus/' + path, {
    method: body ? 'POST' : 'GET',
    headers: { ...(body ? { 'Content-Type': 'application/json' } : {}), ...(t ? { Authorization: `Bearer ${t}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const d = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(d.error || 'Не получилось, попробуйте ещё раз');
  return d;
}

// Keeps store.plus in step with the server. Offline or on an error the last known date stays,
// so a subscriber doesn't lose the badge without a network.
export async function refreshPlus() {
  if (!store.get().user) return;
  try {
    const d = await plusCall('me');
    store.set({ plus: d.active ? d.plus_until : null, supporter: d.supporter_since || null, keeperTier: d.keeper_tier || 0, donated: d.donated || 0 });
    return d;
  } catch {}
}

export const usePlus = () => useStore((s) => !!s.plus && Date.parse(s.plus) > Date.now());

// What the Blink+ page says (prices, perks, ladder). The owner edits it in the admin panel; this copy
// shows at once and offline, and the server's version replaces it as soon as it arrives.
export const PLUS_FALLBACK = {
  title: 'Blink+',
  lead: 'Музыка в Blink остаётся бесплатной. Blink+ добавляет то, что нужно каждый день, и отмечает вас в профиле.',
  plans: [
    { id: 'month', label: 'Месяц', price: 149, days: 30 },
    { id: 'year', label: 'Год', price: 1290, days: 365 },
  ],
  perks: [
    { icon: 'download', title: 'Музыка без интернета', text: 'Сохраняйте треки и плейлисты на устройство. Играют в метро, самолёте и без сети.' },
    { icon: 'user', title: 'Орбита у аватарки', text: 'Тонкий световой круг у вашей аватарки и значок Blink+ рядом с ником. Его видят все.' },
    { icon: 'bolt', title: 'Ранний доступ', text: 'Новые функции приходят к подписчикам первыми, пока мы их дорабатываем.' },
    { icon: 'heart', title: 'Вы держите Blink', text: 'Подписка оплачивает серверы и помогает выпускать обновления быстрее.' },
  ],
  compare: [
    { label: 'Вся музыка и Вспышка', free: true, plus: true },
    { label: 'Плейлисты и перенос музыки', free: true, plus: true },
    { label: 'Сохранение треков без интернета', free: false, plus: true },
    { label: 'Орбита у аватарки и значок', free: false, plus: true },
    { label: 'Ранний доступ к новому', free: false, plus: true },
  ],
  tiers: [
    { id: 1, name: 'Хранитель', from: 50 },
    { id: 2, name: 'Хранитель II', from: 1000 },
    { id: 3, name: 'Хранитель III', from: 5000 },
  ],
};

let cfgNow = PLUS_FALLBACK;
try {
  const c = JSON.parse(localStorage.getItem('blink.plusCfg'));
  if (c && c.plans && c.tiers) cfgNow = c;
} catch {}
const watchers = new Set();
let asked = false;

export function usePlusConfig() {
  const [cfg, setCfg] = useState(cfgNow);
  useEffect(() => {
    watchers.add(setCfg);
    if (!asked) {
      asked = true;
      fetch(MEDIA + '/api/plus/config')
        .then((r) => (r.ok ? r.json() : Promise.reject()))
        .then((d) => {
          if (!d || !d.plans) return;
          cfgNow = d;
          try { localStorage.setItem('blink.plusCfg', JSON.stringify(d)); } catch {}
          watchers.forEach((f) => f(d));
        })
        .catch(() => (asked = false));
    }
    return () => watchers.delete(setCfg);
  }, []);
  return cfg;
}

export const monthly = (p) => (p.days >= 365 ? Math.round(p.price / 12) : p.price);
// Highest rung a total reaches, 0 below the first.
export const tierFor = (tiers, total) => tiers.reduce((t, x) => (total >= x.from ? x.id : t), 0);
