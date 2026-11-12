// «Слушать вместе»: one scene. The cover, the track, who is here. Queue and chat stay out of the
// way until asked for.
import { useEffect, useRef, useState } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import Icon from './Icon.jsx';
import { Cover } from './common.jsx';
import { store, useStore, toast } from '../lib/store.js';
import { isDesktop } from '../lib/cloud.js';
import { createRoom, joinRoom, leaveRoom, sendChat, setMode, togetherLink, voteSkip } from '../lib/together.js';

function copy(code) {
  navigator.clipboard.writeText(togetherLink(code)).then(
    () => toast('Ссылка скопирована. Отправьте её другу'),
    () => toast('Не получилось скопировать ссылку', 'error'),
  );
}

const ease = [0.23, 1, 0.32, 1];
const initial = (name) => (name || '?').trim().charAt(0).toUpperCase();
const hhmm = (ms) => {
  const d = new Date(ms);
  return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
};
const plural = (n, a, b, c) => (n % 10 === 1 && n % 100 !== 11 ? a : n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 10 || n % 100 >= 20) ? b : c);

// The room's chat: messages show at once (sent in the background), others' names and avatars
// start each run, and the list follows new messages unless the reader scrolled up.
function Chat({ chat, me, members }) {
  const [text, setText] = useState('');
  const [pending, setPending] = useState([]); // my messages not yet confirmed by the room
  const list = useRef(null);
  const input = useRef(null);
  const stick = useRef(true);
  const myName = (members.find((m) => m.id === me) || {}).name || 'Вы';

  // A pending message is done once the room has it.
  const shown = chat.concat(pending.filter((p) => p.failed || !chat.some((c) => c.by === me && c.text === p.text && c.at >= p.at - 10000)));
  useEffect(() => {
    const el = list.current;
    if (el && stick.current) el.scrollTop = el.scrollHeight;
  }, [shown.length, pending]);
  useEffect(() => {
    if (input.current) input.current.focus({ preventScroll: true });
  }, []);

  const send = async (t, id) => {
    const ok = await sendChat(t);
    setPending((p) => (ok ? p.filter((x) => x.id !== id) : p.map((x) => (x.id === id ? { ...x, failed: true } : x))));
  };
  const submit = (e) => {
    e.preventDefault();
    const t = text.trim();
    if (!t) return;
    const id = 'p' + Math.random().toString(36).slice(2, 8);
    setPending((p) => [...p, { id, by: me, name: myName, text: t, at: Date.now(), pending: true }]);
    setText('');
    stick.current = true;
    send(t, id);
  };
  const retry = (p) => {
    setPending((list) => list.map((x) => (x.id === p.id ? { ...x, failed: false } : x)));
    send(p.text, p.id);
  };

  return (
    <div className="tgr-chat">
      <div
        className="tgr-msgs"
        ref={list}
        onScroll={(e) => {
          const el = e.currentTarget;
          stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
        }}
      >
        {shown.length ? (
          shown.map((c, i) => {
            const mine = c.by === me;
            const prev = shown[i - 1];
            const first = !prev || prev.by !== c.by || c.at - prev.at > 120000;
            return (
              <div key={c.id} className={'tgr-msg' + (mine ? ' mine' : '') + (first ? ' first' : '') + (c.pending ? ' pending' : '') + (c.failed ? ' failed' : '')}>
                {!mine && <i className={'tgr-ava' + (first ? '' : ' ghost')}>{first ? initial(c.name) : ''}</i>}
                <div className="tgr-bub">
                  {first && !mine && <b>{c.name}</b>}
                  <span>{c.text}</span>
                  {first && <time>{c.failed ? 'не отправлено' : hhmm(c.at)}</time>}
                  {c.failed && (
                    <button type="button" onClick={() => retry(c)}>
                      Повторить
                    </button>
                  )}
                </div>
              </div>
            );
          })
        ) : (
          <div className="tgr-hint">Пока тихо. Напишите первым</div>
        )}
      </div>
      <form className="tgr-send" onSubmit={submit}>
        <input ref={input} value={text} maxLength={500} placeholder="Сообщение" aria-label="Сообщение" enterKeyHint="send" onChange={(e) => setText(e.target.value)} />
        <button disabled={!text.trim()} aria-label="Отправить">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <path d="M12 19V5M5 12l7-7 7 7" />
          </svg>
        </button>
      </form>
    </div>
  );
}

// Chat as its own screen: a mini player on top so the room stays in view, the whole height for messages.
function ChatMode({ together, me, onBack }) {
  const track = useStore((s) => s.track);
  return (
    <div className="tgr tgr-chatmode">
      <div className="tgr-top">
        <button className="tgr-back" onClick={onBack} aria-label="Назад к комнате">
          <Icon name="back" size={18} /> Чат
        </button>
        <span className="tgr-live">
          <i />
          {together.members.length} {plural(together.members.length, 'слушает', 'слушают', 'слушают')}
        </span>
      </div>
      <div className="tgr-mini">
        {track ? <Cover src={track.artwork} size={120} className="tgr-minic" /> : <div className="tgr-minic empty" />}
        <div>
          <b>{track ? track.title : 'Тихо'}</b>
          <span>{track ? track.artist : 'Ничего не играет'}</span>
        </div>
      </div>
      <Chat chat={together.chat || []} me={me} members={together.members} />
    </div>
  );
}

function Queue() {
  const queue = useStore((s) => s.queue) || [];
  const index = useStore((s) => s.index) || 0;
  const next = queue.slice(index + 1, index + 9);
  const more = queue.length - index - 1 - next.length;
  if (!next.length) return <div className="tgr-hint">Дальше пусто. «В очередь комнаты» есть в меню любого трека</div>;
  return (
    <div className="tgr-queue">
      {next.map((t, i) => (
        <div key={t.id + i} className="tgr-q">
          <Cover src={t.artwork} size={80} className="tgr-qc" />
          <div>
            <b>{t.title}</b>
            <span>{t.addedBy ? `${t.artist} · ${t.addedBy}` : t.artist}</span>
          </div>
        </div>
      ))}
      {more > 0 && <div className="tgr-more">и ещё {more}</div>}
    </div>
  );
}

function Scene({ together, me, onClose }) {
  const track = useStore((s) => s.track);
  const playing = useStore((s) => s.status === 'playing');
  const queue = useStore((s) => s.queue) || [];
  const index = useStore((s) => s.index) || 0;
  const [panel, setPanel] = useState(null); // null | 'queue' | 'chat'
  const seen = useRef(0);
  const chatLen = (together.chat || []).length;
  useEffect(() => {
    if (panel === 'chat') seen.current = chatLen;
  }, [panel, chatLen]);
  const unread = panel === 'chat' ? 0 : Math.max(0, chatLen - seen.current);
  const members = together.members;
  const need = Math.floor(members.length / 2) + 1;
  const skips = together.skips || [];
  const voted = skips.includes(me);
  const isHost = together.host === me;
  const hostOnly = together.mode === 'host';
  const left = Math.max(0, queue.length - index - 1);
  const toggle = (p) => setPanel((cur) => (cur === p ? null : p));
  if (panel === 'chat') return <ChatMode together={together} me={me} onBack={() => setPanel(null)} />;

  return (
    <div className={'tgr' + (playing ? ' on' : '')}>
      <div className="tgr-top">
        <span className="tgr-live">
          <i />
          {members.length} {plural(members.length, 'слушает', 'слушают', 'слушают')}
        </span>
        <div className="tgr-icons">
          <button onClick={() => copy(together.code)} title="Скопировать ссылку" aria-label="Скопировать ссылку-приглашение">
            <Icon name="share" size={18} />
          </button>
          <button
            onClick={() => {
              leaveRoom();
              onClose();
            }}
            title="Выйти из комнаты"
            aria-label="Выйти из комнаты"
          >
            <Icon name="close" size={18} />
          </button>
        </div>
      </div>

      <div className="tgr-stage">
        {track && <Cover src={track.artwork} size={500} className="tgr-aura" />}
        <AnimatePresence mode="wait">
          <motion.div
            key={track ? track.id : 'none'}
            className="tgr-coverwrap"
            initial={{ opacity: 0, scale: 0.94, y: 10 }}
            animate={{ opacity: 1, scale: 1, y: 0 }}
            exit={{ opacity: 0, scale: 0.97, transition: { duration: 0.15 } }}
            transition={{ duration: 0.45, ease }}
          >
            {track ? (
              <Cover src={track.artwork} size={600} className="tgr-cover" />
            ) : (
              <div className="tgr-cover empty">
                <Icon name="queue" size={36} />
              </div>
            )}
          </motion.div>
        </AnimatePresence>
      </div>

      <AnimatePresence mode="wait">
        <motion.div key={track ? track.id : 'none'} className="tgr-text" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, transition: { duration: 0.1 } }} transition={{ duration: 0.35, ease, delay: 0.05 }}>
          {track ? (
            <>
              <h2>{track.title}</h2>
              <p>{track.artist}</p>
            </>
          ) : (
            <>
              <h2>Тихо</h2>
              <p>Включите трек, и он заиграет у всех</p>
            </>
          )}
        </motion.div>
      </AnimatePresence>

      <div className="tgr-people">
        <div className="tgr-faces" aria-label="Слушатели">
          {members.map((m, i) => (
            <span key={m.id} style={{ zIndex: members.length - i }} className={'tgr-face' + (m.host ? ' host' : '')} title={m.id === me ? `${m.name} (вы)` : m.name}>
              {initial(m.name)}
            </span>
          ))}
        </div>
        {isHost ? (
          <button className="tgr-mode" onClick={() => setMode(hostOnly ? 'all' : 'host')} title="Кто управляет музыкой">
            {hostOnly ? 'Управляю только я' : 'Управляют все'}
          </button>
        ) : (
          hostOnly && <span className="tgr-mode static">Управляет хост</span>
        )}
      </div>

      <div className="tgr-bar">
        <button className={voted ? 'on' : ''} disabled={!track} onClick={voteSkip}>
          {members.length > 1 ? `Пропуск ${skips.length}/${need}` : 'Пропуск'}
        </button>
        <button className={panel === 'queue' ? 'on' : ''} onClick={() => toggle('queue')}>
          Очередь{left > 0 && <em>{left}</em>}
        </button>
        <button className={panel === 'chat' ? 'on' : ''} onClick={() => toggle('chat')}>
          Чат{unread > 0 && <em className="dot">{unread}</em>}
        </button>
      </div>

      <AnimatePresence initial={false}>
        {panel === 'queue' && (
          <motion.div key="panel" className="tgr-panel" initial={{ height: 0, opacity: 0 }} animate={{ height: 'auto', opacity: 1 }} exit={{ height: 0, opacity: 0 }} transition={{ duration: 0.32, ease }}>
            <div className="tgr-panel-in"><Queue /></div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}

export default function TogetherSheet({ onClose }) {
  const together = useStore((s) => s.together);
  const invite = useStore((s) => s.togetherInvite);
  const me = useStore((s) => s.user && s.user.id);
  const [busy, setBusy] = useState(false);

  // Opened by a friend's link, not in that room yet.
  if (invite && (!together || together.code !== invite)) {
    return (
      <div className="tgr-start">
        <h2>Вас зовут слушать вместе</h2>
        <p>Музыка, пауза и перемотка будут общими для всех в комнате.</p>
        <div className="tgr-actions">
          <button
            className="btn primary"
            onClick={() => {
              store.set({ togetherInvite: null });
              joinRoom(invite);
            }}
          >
            <Icon name="play" size={18} /> Присоединиться
          </button>
          {!isDesktop && (
            <a className="btn ghost" href={`blink://together?together=${invite}`} style={{ textDecoration: 'none' }}>
              Открыть в приложении
            </a>
          )}
        </div>
      </div>
    );
  }

  if (!together) {
    return (
      <div className="tgr-start">
        <h2>Слушайте вместе</h2>
        <p>Одна комната, до 8 человек. Трек, пауза и перемотка у всех общие.</p>
        <div className="tgr-actions">
          <button
            className="btn primary"
            disabled={busy}
            onClick={async () => {
              setBusy(true);
              const code = await createRoom();
              setBusy(false);
              if (code) copy(code);
            }}
          >
            <Icon name="share" size={18} /> Создать комнату
          </button>
        </div>
      </div>
    );
  }

  return <Scene together={together} me={me} onClose={onClose} />;
}
