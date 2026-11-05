// «Слушать вместе»: make a room, send the link, see who's listening, leave.
import { useEffect, useRef, useState } from 'react';
import Icon from './Icon.jsx';
import { store, useStore, toast } from '../lib/store.js';
import { isDesktop } from '../lib/cloud.js';
import { createRoom, joinRoom, leaveRoom, sendChat, togetherLink } from '../lib/together.js';

function copy(code) {
  navigator.clipboard.writeText(togetherLink(code)).then(
    () => toast('Ссылка скопирована. Отправьте её другу'),
    () => toast('Не получилось скопировать ссылку', 'error'),
  );
}

function Chat({ chat, me }) {
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const list = useRef(null);
  useEffect(() => {
    if (list.current) list.current.scrollTop = list.current.scrollHeight;
  }, [chat.length]);
  const submit = async (e) => {
    e.preventDefault();
    const t = text.trim();
    if (!t || busy) return;
    setBusy(true);
    if (await sendChat(t)) setText('');
    setBusy(false);
  };
  return (
    <div className="together-chat">
      <div className="together-msgs" ref={list}>
        {chat.length ? (
          chat.map((c) => (
            <div key={c.id} className={'together-msg' + (c.by === me ? ' mine' : '')}>
              {c.by !== me && <div className="who">{c.name}</div>}
              {c.text}
            </div>
          ))
        ) : (
          <div className="together-empty">Здесь можно переписываться, пока слушаете</div>
        )}
      </div>
      <form className="together-send" onSubmit={submit}>
        <input value={text} maxLength={500} placeholder="Сообщение" onChange={(e) => setText(e.target.value)} />
        <button className="btn primary" disabled={busy || !text.trim()}>
          Отправить
        </button>
      </form>
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
      <>
        <div className="label" style={{ marginBottom: 12 }}>Слушать вместе</div>
        <p>Вас позвали слушать музыку вместе. Треки, пауза и перемотка будут общими для всех в комнате.</p>
        <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
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
      </>
    );
  }

  if (!together) {
    return (
      <>
        <div className="label" style={{ marginBottom: 12 }}>Слушать вместе</div>
        <p>Создайте комнату и отправьте ссылку друзьям, до 8 человек. Кто бы ни включил трек, поставил паузу или перемотал, у всех играет одно и то же.</p>
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
      </>
    );
  }

  return (
    <>
      <div className="label" style={{ marginBottom: 12 }}>Вы слушаете вместе</div>
      <div className="together-link">
        <span>{togetherLink(together.code)}</span>
        <button className="btn ghost" onClick={() => copy(together.code)}>
          Скопировать
        </button>
      </div>
      <div className="together-members">
        {together.members.map((m) => (
          <div key={m.id} className="together-member">
            <Icon name="user" size={16} /> {m.name}
            {m.id === me ? ' (вы)' : ''}
          </div>
        ))}
        <div className="together-count">{together.members.length} из 8</div>
      </div>
      <Chat chat={together.chat || []} me={me} />
      <button
        className="btn ghost"
        onClick={() => {
          leaveRoom();
          onClose();
        }}
      >
        Выйти из комнаты
      </button>
    </>
  );
}
