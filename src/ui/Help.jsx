// Support page: own requests as chats with the team, a new request with ready answers suggested
// while typing, the common questions; and the Ctrl+P bug report window (lib/support.js).
import { useEffect, useMemo, useRef, useState } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { store, useStore, go } from '../lib/store.js';
import { loadFaq, myTickets, openTicket, sendMessage, closeTicket, sendTicket, bestAnswer, bugDetails, shrinkImage } from '../lib/support.js';
import Icon from './Icon.jsx';

import { humanError } from '../lib/errors.js';
const STATUS = { open: 'Ждёт ответа', answered: 'Есть ответ', closed: 'Решено' };
const when = (iso) => {
  const d = new Date(iso);
  const today = d.toDateString() === new Date().toDateString();
  return today ? d.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' }) : d.toLocaleDateString('ru-RU', { day: 'numeric', month: 'short' });
};
const ease = [0.23, 1, 0.32, 1];

// The Blink mark: the bot's and the team's avatar.
const Logo = () => (
  <span className="sup-ava" aria-hidden="true">
    b<i />
  </span>
);

// Up to 3 photos or screenshots: a paperclip button, previews, and paste (Ctrl+V) into the page.
const MAX_PICS = 3;
function usePics(setErr) {
  const [pics, setPics] = useState([]);
  const add = async (files) => {
    const list = [...files].filter((f) => f.type.startsWith('image/')).slice(0, MAX_PICS);
    for (const f of list) {
      try {
        const d = await shrinkImage(f);
        setPics((p) => (p.length < MAX_PICS ? [...p, d] : p));
      } catch (e) {
        setErr(humanError(e));
      }
    }
  };
  useEffect(() => {
    const paste = (e) => e.clipboardData && e.clipboardData.files.length && add(e.clipboardData.files);
    window.addEventListener('paste', paste);
    return () => window.removeEventListener('paste', paste);
  }, []);
  return { pics, add, clear: () => setPics([]), drop: (i) => setPics((p) => p.filter((_, j) => j !== i)) };
}

function Clip({ p }) {
  const input = useRef(null);
  return (
    <>
      <button type="button" className="btn ghost sup-clip" title="Прикрепить фото или скриншот (можно вставить через Ctrl+V)" disabled={p.pics.length >= MAX_PICS} onClick={() => input.current.click()}>
        <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="m20.5 11.5-8.3 8.3a5 5 0 0 1-7.1-7.1l8.6-8.6a3.3 3.3 0 0 1 4.7 4.7l-8.6 8.6a1.7 1.7 0 0 1-2.4-2.4l7.9-7.9" /></svg>
      </button>
      <input ref={input} type="file" accept="image/*" multiple hidden onChange={(e) => (p.add(e.target.files), (e.target.value = ''))} />
    </>
  );
}

function Previews({ p }) {
  if (!p.pics.length) return null;
  return (
    <div className="sup-pics">
      {p.pics.map((src, i) => (
        <div key={i} className="sup-pic">
          <img src={src} alt="" />
          <button type="button" title="Убрать" onClick={() => p.drop(i)}>
            <Icon name="close" size={12} />
          </button>
        </div>
      ))}
    </div>
  );
}

function Files({ urls }) {
  if (!urls || !urls.length) return null;
  return (
    <div className="sup-files">
      {urls.map((u) => (
        <a key={u} href={u} target="_blank" rel="noopener" onClick={(e) => window.blink && window.blink.open && (e.preventDefault(), window.blink.open(u))}>
          <img src={u} alt="Вложение" />
        </a>
      ))}
    </div>
  );
}

// Signed out, we need somewhere to answer.
function Contact({ value, set }) {
  const user = useStore((s) => s.user);
  if (user) return null;
  return (
    <label className="fld">
      Почта или Telegram для ответа
      <input value={value} onChange={(e) => set(e.target.value)} maxLength={200} placeholder="name@mail.ru или @nick" />
    </label>
  );
}

function Hint({ f, title }) {
  return (
    <motion.div className="sup-hint" initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: 4 }} transition={{ duration: 0.2, ease }}>
      <div className="k">{title}</div>
      <div className="q">{f.question}</div>
      <div className="d">{f.answer}</div>
    </motion.div>
  );
}

function NewTicket({ faq, onSent }) {
  const user = useStore((s) => s.user);
  const [text, setText] = useState('');
  const [contact, setContact] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [sent, setSent] = useState(null);
  const p = usePics(setErr);
  const hint = useMemo(() => (text.trim().length > 5 ? bestAnswer(faq, text) : null), [faq, text]);

  const send = async () => {
    setErr('');
    setBusy(true);
    try {
      const r = await sendTicket({ kind: 'question', message: text, contact, images: p.pics });
      setText('');
      p.clear();
      if (user) onSent(r.id);
      else setSent(r);
    } catch (e) {
      setErr(humanError(e));
    }
    setBusy(false);
  };

  if (sent)
    return (
      <div className="sup-new">
        <h3>Отправлено</h3>
        <p className="sup-sub">Мы ответим на {contact || 'указанный контакт'}. Войдите в аккаунт, чтобы видеть ответы прямо здесь.</p>
        {sent.auto && <Hint f={sent.auto} title="Пока ждёте, возможно, это поможет" />}
        <button className="btn ghost" onClick={() => setSent(null)}>Написать ещё</button>
      </div>
    );

  return (
    <div className="sup-new">
      <h3>Новое обращение</h3>
      <p className="sup-sub">Опишите, что случилось. Если это частый вопрос, ответ появится сразу.</p>
      <label className="fld">
        Ваш вопрос
        <textarea rows={5} value={text} onChange={(e) => setText(e.target.value)} maxLength={4000} placeholder="Например: не переносится плейлист из Spotify" autoFocus />
      </label>
      <Previews p={p} />
      <AnimatePresence>{hint && <Hint key={hint.id} f={hint} title="Похоже на частый вопрос" />}</AnimatePresence>
      <Contact value={contact} set={setContact} />
      <div className="field-err">{err}</div>
      <div className="sup-bar">
        <button className="btn primary" disabled={busy || (!text.trim() && !p.pics.length)} onClick={send}>
          {busy ? 'Отправляю…' : 'Отправить'}
        </button>
        <Clip p={p} />
        <button className="btn ghost" onClick={() => store.set({ sheet: 'bug' })}>
          Сообщить об ошибке <kbd>Ctrl P</kbd>
        </button>
      </div>
    </div>
  );
}

function Bubble({ team, auto, at, files, children }) {
  return (
    <motion.div className={'sup-msg' + (team ? ' team' : ' me')} initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.22, ease }}>
      {team && <Logo />}
      <div className="sup-bubble">
        {team && <div className="who">{auto ? 'Бот Blink' : 'Поддержка Blink'}</div>}
        {children && <div className="txt">{children}</div>}
        <Files urls={files} />
        <div className="at">{when(at)}</div>
      </div>
    </motion.div>
  );
}

function Chat({ id, onChange }) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const end = useRef(null);
  const p = usePics(setErr);

  const load = () => openTicket(id).then(setD, (e) => setErr(humanError(e)));
  useEffect(() => {
    setD(null);
    setErr('');
    load();
    const t = setInterval(() => document.visibilityState === 'visible' && load(), 20e3);
    return () => clearInterval(t);
  }, [id]);
  useEffect(() => {
    end.current && end.current.scrollIntoView({ block: 'end', behavior: 'smooth' });
  }, [d && d.messages.length]);

  const send = async () => {
    if ((!text.trim() && !p.pics.length) || busy) return;
    setBusy(true);
    setErr('');
    try {
      const m = await sendMessage(id, text, p.pics);
      setText('');
      p.clear();
      setD((x) => ({ ...x, ticket: { ...x.ticket, status: 'open' }, messages: [...x.messages, m] }));
      onChange();
    } catch (e) {
      setErr(humanError(e));
    }
    setBusy(false);
  };
  const close = async () => {
    await closeTicket(id).catch(() => {});
    setD((x) => ({ ...x, ticket: { ...x.ticket, status: 'closed' } }));
    onChange();
  };

  if (err && !d) return <div className="sup-empty">{err}</div>;
  if (!d) return <div className="sup-empty">Загружаю…</div>;
  const t = d.ticket;
  return (
    <div className="sup-chat">
      <div className="sup-chat-head">
        <div>
          <div className="sup-kind">{t.kind === 'bug' ? 'Баг-репорт' : 'Вопрос'} · {new Date(t.created_at).toLocaleDateString('ru-RU', { day: 'numeric', month: 'long' })}</div>
          <span className={'sup-st ' + t.status}>{STATUS[t.status]}</span>
        </div>
        {t.status !== 'closed' && (
          <button className="btn ghost sm" onClick={close}>
            <Icon name="check" size={15} /> Вопрос решён
          </button>
        )}
      </div>
      <div className="sup-msgs">
        <Bubble at={t.created_at} files={t.attachments}>{t.message}</Bubble>
        {d.auto && (
          <Bubble team auto at={t.created_at}>
            <b>{d.auto.question}</b>
            {'\n'}
            {d.auto.answer}
            {'\n\n'}
            <span className="muted">Если не помогло, напишите, и ответит человек.</span>
          </Bubble>
        )}
        {d.messages.map((m) => (
          <Bubble key={m.id} team={m.author === 'team'} at={m.created_at} files={m.attachments}>
            {m.body}
          </Bubble>
        ))}
        {!d.messages.some((m) => m.author === 'team') && t.status === 'open' && <div className="sup-wait">Обычно отвечаем в течение дня. Ответ появится здесь.</div>}
        <div ref={end} />
      </div>
      <Previews p={p} />
      <form className="sup-compose" onSubmit={(e) => (e.preventDefault(), send())}>
        <Clip p={p} />
        <textarea
          rows={1}
          value={text}
          maxLength={4000}
          placeholder={t.status === 'closed' ? 'Написать снова откроет обращение' : 'Сообщение'}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && !e.shiftKey && (e.preventDefault(), send())}
        />
        <button className="btn primary" disabled={busy || (!text.trim() && !p.pics.length)} title="Отправить (Enter)">
          Отправить
        </button>
      </form>
      {err && <div className="field-err">{err}</div>}
    </div>
  );
}

function Faq({ faq }) {
  const [q, setQ] = useState('');
  const list = useMemo(() => {
    const t = q.trim().toLowerCase();
    return t ? (faq || []).filter((f) => (f.question + ' ' + f.answer + ' ' + f.keywords).toLowerCase().includes(t)) : faq || [];
  }, [faq, q]);
  return (
    <div className="sup-new">
      <h3>Частые вопросы</h3>
      <div className="field sup-search">
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Поиск по ответам" />
      </div>
      {faq === null ? (
        <p className="sup-sub">Загружаю…</p>
      ) : list.length ? (
        list.map((f) => (
          <details key={f.id} className="sup-faq">
            <summary>{f.question}</summary>
            <div>{f.answer}</div>
          </details>
        ))
      ) : (
        <p className="sup-sub">Ничего не нашлось. Напишите нам, ответим.</p>
      )}
    </div>
  );
}

export function SupportPage({ id }) {
  const user = useStore((s) => s.user);
  const [faq, setFaq] = useState(null);
  const [tickets, setTickets] = useState(null);
  const [pane, setPane] = useState(id ? 'ticket' : 'new');
  const [open, setOpen] = useState(id || null);

  const reload = () => (user ? myTickets().then(setTickets, () => setTickets([])) : setTickets([]));
  useEffect(() => {
    loadFaq().then(setFaq, () => setFaq([]));
  }, []);
  useEffect(() => {
    reload();
  }, [user]);
  useEffect(() => {
    if (id) (setOpen(id), setPane('ticket'));
  }, [id]);

  const pick = (p, tid = null) => (setPane(p), setOpen(tid));
  const sent = (tid) => (reload(), pick('ticket', tid));

  return (
    <div className="view sup">
      <motion.header className="sup-head" initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.3, ease }}>
        <div>
          <div className="label">Поддержка Blink</div>
          <h1>Чем помочь?</h1>
        </div>
      </motion.header>
      <div className={'sup-grid' + (pane === 'ticket' ? ' reading' : '')}>
        <aside className="sup-side">
          <button className={'sup-item new' + (pane === 'new' ? ' on' : '')} onClick={() => pick('new')}>
            <Icon name="plus" size={17} /> Новое обращение
          </button>
          <button className={'sup-item' + (pane === 'faq' ? ' on' : '')} onClick={() => pick('faq')}>
            <Icon name="lyrics" size={17} /> Частые вопросы
          </button>
          <div className="label sup-side-h">Мои обращения</div>
          {!user ? (
            <div className="sup-side-note">
              Войдите, чтобы видеть ответы и переписку.
              <button className="link" onClick={() => store.set({ sheet: 'account' })}>Войти</button>
            </div>
          ) : tickets === null ? (
            <div className="sup-side-note">Загружаю…</div>
          ) : !tickets.length ? (
            <div className="sup-side-note">Пока пусто</div>
          ) : (
            tickets.map((t) => (
              <button key={t.id} className={'sup-item ticket' + (pane === 'ticket' && open === t.id ? ' on' : '')} onClick={() => pick('ticket', t.id)}>
                <span className={'sup-dot ' + t.status} />
                <span className="sup-item-main">
                  <span className="sup-item-top">
                    <span>{t.kind === 'bug' ? 'Баг-репорт' : 'Вопрос'}</span>
                    <span>{when(t.updated_at || t.created_at)}</span>
                  </span>
                  <span className="sup-item-text">{t.message}</span>
                </span>
              </button>
            ))
          )}
        </aside>
        <section className="sup-pane">
          {pane === 'ticket' && (
            <button className="link sup-back" onClick={() => pick('new')}>
              <Icon name="back" size={15} /> Все обращения
            </button>
          )}
          <motion.div key={pane + (open || '')} initial={{ opacity: 0, x: 10 }} animate={{ opacity: 1, x: 0 }} transition={{ duration: 0.22, ease }}>
            {pane === 'ticket' && open ? <Chat id={open} onChange={reload} /> : pane === 'faq' ? <Faq faq={faq} /> : <NewTicket faq={faq} onSent={sent} />}
          </motion.div>
        </section>
      </div>
    </div>
  );
}

export function BugSheet() {
  const user = useStore((s) => s.user);
  const [d] = useState(bugDetails);
  const [text, setText] = useState('');
  const [contact, setContact] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [sent, setSent] = useState(null);
  const p = usePics(setErr);

  const send = async () => {
    setErr('');
    setBusy(true);
    try {
      setSent(await sendTicket({ kind: 'bug', message: text, contact, details: d, images: p.pics }));
    } catch (e) {
      setErr(humanError(e));
    }
    setBusy(false);
  };

  if (sent)
    return (
      <>
        <div className="label" style={{ marginBottom: 10 }}>Баг-репорт</div>
        <h2>Спасибо, отправлено</h2>
        <p>Мы посмотрим ошибку и лог. {user ? 'Ответ придёт в поддержку.' : 'Ответим на указанный контакт.'}</p>
        {user && (
          <button className="btn ghost" onClick={() => (store.set({ sheet: null }), go('support', { id: sent.id }))}>
            Открыть обращение
          </button>
        )}
      </>
    );

  return (
    <>
      <div className="label" style={{ marginBottom: 10 }}>Баг-репорт · Ctrl+P</div>
      <h2>Что пошло не так?</h2>
      <div className={'bug-err' + (d.error ? '' : ' none')}>
        {d.error ? (
          <>
            <div className="k">Последняя ошибка · {when(d.error.at)}</div>
            <div className="d">{d.error.message}</div>
          </>
        ) : (
          <div className="d">Ошибок не было. Опишите, что заметили, этого хватит.</div>
        )}
      </div>
      <details className="sup-faq bug-log">
        <summary>Что ещё уйдёт в отчёт ({d.log.length} строк лога)</summary>
        <pre>{[`Blink ${d.app}`, d.view && `Экран: ${d.view}`, d.track && `Трек: ${d.track}`, d.platform, '', ...d.log, d.error && d.error.stack ? '\n' + d.error.stack : ''].filter((l) => l !== false && l != null).join('\n')}</pre>
      </details>
      <label className="fld">
        Комментарий
        <textarea rows={3} value={text} onChange={(e) => setText(e.target.value)} maxLength={4000} placeholder="Что вы делали, когда это случилось?" autoFocus />
      </label>
      <Previews p={p} />
      <Contact value={contact} set={setContact} />
      <div className="field-err">{err}</div>
      <div className="sup-bar">
        <button className="btn primary" disabled={busy} onClick={send}>
          {busy ? 'Отправляю…' : 'Отправить в поддержку'}
        </button>
        <Clip p={p} />
      </div>
    </>
  );
}
