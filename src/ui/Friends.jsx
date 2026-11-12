// Друзья: who is listening now, invite link, hide-my-listening switch.
import { useEffect, useState } from 'react';
import Icon from './Icon.jsx';
import { store, useStore, toast } from '../lib/store.js';
import { loadFriends, makeInvite, acceptInvite, removeFriend, setHidden } from '../lib/friends.js';
import { joinRoom } from '../lib/together.js';
import { playTrack } from '../lib/player.js';

// Keep the list fresh while it is on screen.
function useFriends() {
  const friends = useStore((s) => s.friends);
  useEffect(() => {
    loadFriends();
    const t = setInterval(loadFriends, 20000);
    return () => clearInterval(t);
  }, []);
  return friends || [];
}

function Avatar({ f }) {
  return f.avatar ? <img className="fr-ava" src={f.avatar} alt="" /> : <i className="fr-ava">{(f.name || '?').trim().charAt(0).toUpperCase()}</i>;
}

function Row({ f, onClose, manage }) {
  const l = f.listening;
  return (
    <div className={'fr-row' + (l ? ' on' : '')}>
      <Avatar f={f} />
      <div className="fr-text">
        <b>{f.name}</b>
        <span>{l ? `${l.track.title} · ${l.track.artist}` : 'Не слушает'}</span>
      </div>
      {l && l.room && (
        <button
          className="btn primary"
          onClick={() => {
            joinRoom(l.room);
            store.set({ sheet: 'together' });
          }}
        >
          В комнату
        </button>
      )}
      {l && !l.room && (
        <button
          className="btn ghost"
          onClick={() => {
            playTrack(l.track, [l.track], 0);
            onClose && onClose();
          }}
        >
          Послушать то же
        </button>
      )}
      {manage && (
        <button className="icon-btn" title="Убрать из друзей" onClick={() => window.confirm(`Убрать ${f.name} из друзей?`) && removeFriend(f.id)}>
          <Icon name="close" size={16} />
        </button>
      )}
    </div>
  );
}

// A strip on «Моё»: only friends who are listening right now, and a way into the full list.
export function FriendsStrip() {
  const friends = useFriends();
  const user = useStore((s) => s.user);
  if (!user) return null;
  const on = friends.filter((f) => f.listening);
  return (
    <div className="fr-strip">
      <div className="fr-head">
        <span className="label">Друзья {on.length ? `· слушают ${on.length}` : ''}</span>
        <button className="link" onClick={() => store.set({ sheet: 'friends' })}>
          {friends.length ? 'Все' : 'Позвать друга'}
        </button>
      </div>
      {on.slice(0, 3).map((f) => (
        <Row key={f.id} f={f} />
      ))}
    </div>
  );
}

export default function FriendsSheet({ onClose }) {
  const friends = useFriends();
  const hidden = useStore((s) => !!s.friendsHidden);
  const invite = useStore((s) => s.friendInvite);
  const [busy, setBusy] = useState(false);

  // Opened from a friend's link.
  if (invite) {
    return (
      <>
        <div className="label" style={{ marginBottom: 12 }}>Друзья</div>
        <p>Вас позвали в друзья в Blink. Друзья видят, что вы слушаете сейчас, и могут зайти к вам в комнату. Скрыть это можно в любой момент.</p>
        <div style={{ display: 'flex', gap: 10 }}>
          <button
            className="btn primary"
            disabled={busy}
            onClick={async () => {
              setBusy(true);
              await acceptInvite(invite);
              setBusy(false);
              store.set({ friendInvite: null });
            }}
          >
            Добавить в друзья
          </button>
          <button className="btn ghost" onClick={() => store.set({ friendInvite: null })}>
            Не сейчас
          </button>
        </div>
      </>
    );
  }

  const copy = async () => {
    setBusy(true);
    const link = await makeInvite();
    setBusy(false);
    if (!link) return;
    navigator.clipboard.writeText(link).then(
      () => toast('Ссылка скопирована. Отправьте её другу'),
      () => toast(link),
    );
  };

  return (
    <>
      <div className="label" style={{ marginBottom: 12 }}>Друзья</div>
      <p>Друзья добавляются только по вашей ссылке: найти вас по имени нельзя.</p>
      <button className="btn primary" disabled={busy} onClick={copy} style={{ marginBottom: 18 }}>
        <Icon name="share" size={18} /> Скопировать ссылку-приглашение
      </button>
      <div className="fr-list">
        {friends.length ? friends.map((f) => <Row key={f.id} f={f} manage onClose={onClose} />) : <div className="together-empty">Пока никого. Отправьте ссылку другу</div>}
      </div>
      <label className="fr-switch">
        <input type="checkbox" checked={hidden} onChange={(e) => setHidden(e.target.checked)} />
        <span>Скрывать, что я слушаю</span>
      </label>
    </>
  );
}
