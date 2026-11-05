// Support requests and Ctrl+P bug reports (server: server/supportRoute.js).
// Imported first in main.jsx so it keeps a short log and the last error from the very start.
import { MEDIA } from './catalog.js';
import { cloud } from './cloud.js';
import { store } from './store.js';

const LOG_MAX = 60;
const log = [];
let lastError = null;

const time = () => new Date().toTimeString().slice(0, 8);
const text = (a) => (a instanceof Error ? a.message : typeof a === 'string' ? a : (() => { try { return JSON.stringify(a); } catch { return String(a); } })());
const push = (level, args) => {
  log.push(`${time()} ${level} ${args.map(text).join(' ').slice(0, 500)}`);
  if (log.length > LOG_MAX) log.shift();
};
const fail = (e, where) => {
  const err = e instanceof Error ? e : new Error(text(e));
  lastError = { message: (where ? where + ': ' : '') + err.message, stack: err.stack || '', at: new Date().toISOString() };
};

for (const level of ['error', 'warn']) {
  const orig = console[level].bind(console);
  console[level] = (...args) => {
    push(level, args);
    if (level === 'error') fail(args.find((a) => a instanceof Error) || args.map(text).join(' '));
    orig(...args);
  };
}
window.addEventListener('error', (e) => {
  push('error', [e.message + (e.filename ? ` (${e.filename.split('/').pop()}:${e.lineno})` : '')]);
  fail(e.error || e.message);
});
window.addEventListener('unhandledrejection', (e) => {
  push('error', ['unhandled', e.reason]);
  fail(e.reason, 'Promise');
});

// Everything the report window shows and sends.
export function bugDetails() {
  const s = store.get();
  return {
    error: lastError,
    log: log.slice(),
    app: s.appVersion || (window.blink && window.blink.isWeb ? 'web' : ''),
    platform: navigator.userAgent,
    view: s.view ? s.view.name + (s.view.params && Object.keys(s.view.params).length ? ' ' + JSON.stringify(s.view.params) : '') : '',
    track: s.track ? `${s.track.artist || ''} — ${s.track.title || ''} (${s.track.id || ''})` : '',
  };
}

async function call(path, body) {
  const { data } = cloud ? await cloud.auth.getSession() : { data: {} };
  const t = data && data.session ? data.session.access_token : null;
  const res = await fetch(MEDIA + '/api/support/' + path, {
    method: body ? 'POST' : 'GET',
    headers: { ...(body ? { 'Content-Type': 'application/json' } : {}), ...(t ? { Authorization: `Bearer ${t}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const d = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(d.error || (res.status === 404 ? 'Поддержка на сервере ещё не обновлена' : `Сервер поддержки не ответил (${res.status}), попробуйте позже`));
  return d;
}

let faqCache = null;
export const loadFaq = () => (faqCache ||= call('faq').then((d) => d.faq, (e) => ((faqCache = null), Promise.reject(e))));
export const sendTicket = (body) => call('ticket', body);
export const openTicket = (id) => call('ticket/' + id);
export const sendMessage = (id, body, images) => call(`ticket/${id}/message`, { body, images }).then((d) => d.message);

// A picked photo or screenshot as a JPEG data URL, at most 1600px on the long side (fits the 2 MB server limit).
export function shrinkImage(file, max = 1600) {
  return new Promise((resolve, reject) => {
    if (!/^image\//.test(file.type)) return reject(new Error('Можно прикрепить только картинку'));
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      const k = Math.min(1, max / Math.max(img.width, img.height));
      const c = document.createElement('canvas');
      c.width = Math.round(img.width * k);
      c.height = Math.round(img.height * k);
      c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
      URL.revokeObjectURL(url);
      resolve(c.toDataURL('image/jpeg', 0.85));
    };
    img.onerror = () => (URL.revokeObjectURL(url), reject(new Error('Не получилось открыть картинку')));
    img.src = url;
  });
}
export const closeTicket = (id) => call(`ticket/${id}/close`, {});

// Own requests; store.supportNew counts those where the team wrote last (dot on the support button).
export async function myTickets() {
  const { tickets } = await call('mine');
  store.set({ supportNew: tickets.filter((t) => t.status === 'answered').length });
  return tickets;
}
export const refreshSupport = () => (store.get().user ? myTickets().catch(() => {}) : store.set({ supportNew: 0 }));

// Same rule as the server: the answer whose keywords appear in the text most often.
const norm = (s) => String(s || '').toLowerCase().replace(/ё/g, 'е');
export function bestAnswer(faq, q) {
  const t = norm(q);
  let best = null;
  let score = 0;
  for (const f of faq || []) {
    const n = norm(f.keywords).split(',').map((k) => k.trim()).filter((k) => k.length > 1 && t.includes(k)).length;
    if (n > score) [best, score] = [f, n];
  }
  return best;
}
