// Every account's public page, like SoundCloud: tracks the owner uploads, posts, follows, likes and comments.
import { useEffect, useMemo, useState } from 'react';
import { motion } from 'motion/react';
import Icon from './Icon.jsx';
import { TrackRow, Skeleton, ErrorBox, plural, fmt } from './common.jsx';
import { ask } from './Confirm.jsx';
import { KeeperChip, useKeeper } from './Support.jsx';
import { store, useStore, go, toast, requireAccount } from '../lib/store.js';
import { playTrack } from '../lib/player.js';
import { MEDIA, artistProfile, isFollowing, setFollow, artistMe, acceptOffer, myTracks, takedown, uploadTrack, saveArtistProfile, listPosts, createPost, deletePost, setPostLike, listComments, addComment, deleteComment, report, fromRow } from '../lib/catalog.js';

import { humanError } from '../lib/errors.js';
import { proxied } from '../lib/img.js';
const ease = [0.23, 1, 0.32, 1];
const when = (iso) => new Date(iso).toLocaleString('ru-RU', { day: 'numeric', month: 'long', hour: '2-digit', minute: '2-digit' });

// «Моя страница»: the signed-in account's own page (made on first visit).
// Round avatar; without a photo (or when it fails to load) a placeholder with the first letter.
function ProfAva({ url, name }) {
  const [bad, setBad] = useState(false);
  useEffect(() => setBad(false), [url]);
  if (url && !bad) return <img className="prof-ava" src={proxied(url)} alt="" referrerPolicy="no-referrer" decoding="async" onError={() => setBad(true)} />;
  return (
    <div className="prof-ava ph" aria-hidden="true">
      {(name || '?').slice(0, 1).toUpperCase()}
    </div>
  );
}

export function MyPage() {
  const user = useStore((s) => s.user);
  const [me, setMe] = useState(null);
  const [err, setErr] = useState(false);
  useEffect(() => {
    if (user)
      artistMe()
        .then((d) => setMe(d.artist))
        .catch(() => setErr(true));
  }, [user]);
  if (!user)
    return (
      <div className="view prof-login">
        <h2>Моя страница</h2>
        <p className="prof-empty">Войдите, чтобы выкладывать треки и посты, как в SoundCloud.</p>
        <button className="btn primary" onClick={() => store.set({ sheet: 'account' })}>
          Войти
        </button>
      </div>
    );
  if (err) return <ErrorBox retry={() => location.reload()} />;
  if (!me) return <Skeleton rows={5} />;
  return <ProfilePage id={me.id} />;
}

export function BlinkArtist({ id }) {
  return <ProfilePage id={id} />;
}

function ProfilePage({ id }) {
  const user = useStore((s) => s.user);
  const [data, setData] = useState(undefined);
  const [error, setError] = useState(false);
  const [tab, setTab] = useState('tracks');
  const [following, setFollowing] = useState(false);
  const [followers, setFollowers] = useState(0);
  const [uploading, setUploading] = useState(false);
  const keeper = useKeeper(data && data.user_id);
  const load = () =>
    artistProfile(id)
      .then((d) => {
        setData(d);
        if (d) setFollowers(d.followers);
      })
      .catch(() => setError(true));
  useEffect(() => {
    load();
  }, [id]);
  useEffect(() => {
    if (data && user && data.user_id !== user.id) isFollowing(data.id).then(setFollowing);
  }, [data, user]);
  if (error) return <ErrorBox retry={() => (setError(false), load())} />;
  if (data === null) return <ErrorBox text="Такой страницы нет" />;
  if (!data)
    return (
      <div className="view">
        <div className="sk" style={{ height: 260, marginTop: 24, borderRadius: 24 }} />
        <Skeleton rows={5} />
      </div>
    );
  const own = !!(user && data.user_id === user.id);
  const t = data.tracks;
  const toggleFollow = async () => {
    if (!requireAccount('follow')) return;
    const on = !following;
    setFollowing(on);
    setFollowers((n) => n + (on ? 1 : -1));
    try {
      await setFollow(data.id, on);
    } catch {
      setFollowing(!on);
      setFollowers((n) => n - (on ? 1 : -1));
      toast('Не получилось, попробуйте ещё раз', 'error');
    }
  };
  return (
    <div className="view">
      <div className="prof-head">
        <motion.div className="prof-inner" initial={{ opacity: 0, y: 14 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.45, ease }}>
          <ProfAva url={data.avatar_url} name={data.name} />
          <div className="prof-text">
            <h1>
              {data.name}
              {data.verified && (
                <span className="prof-ok" title="Подтверждённый артист">
                  <Icon name="check" size={16} />
                </span>
              )}
              <KeeperChip since={keeper && keeper.since} tier={keeper && keeper.tier} />
            </h1>
            <div className="prof-meta">{[plural(followers, 'подписчик', 'подписчика', 'подписчиков'), plural(t.length, 'трек', 'трека', 'треков'), data.likes ? plural(data.likes, 'лайк', 'лайка', 'лайков') : null].filter(Boolean).join(' · ')}</div>
            <Bio data={data} own={own} onSaved={load} />
            <div className="actions">
              {t.length > 0 && (
                <button className="btn primary" onClick={() => playTrack(t[0], t, 0)}>
                  <Icon name="play" size={18} /> Слушать
                </button>
              )}
              {own ? (
                <button className={'btn ' + (t.length ? 'ghost' : 'primary')} onClick={() => setUploading(!uploading)}>
                  <Icon name="plus" size={18} /> Загрузить трек
                </button>
              ) : (
                <button className="btn ghost" onClick={toggleFollow}>
                  <Icon name={following ? 'check' : 'plus'} size={18} /> {following ? 'Вы подписаны' : 'Подписаться'}
                </button>
              )}
            </div>
          </div>
        </motion.div>
      </div>

      {own && uploading && (
        <UploadForm
          onDone={() => {
            setUploading(false);
            load();
          }}
          onCancel={() => setUploading(false)}
        />
      )}

      <div className="seg-mini prof-tabs" role="tablist">
        {[
          ['tracks', 'Треки'],
          ['posts', 'Посты'],
        ].map(([k, label]) => (
          <button key={k} role="tab" aria-selected={tab === k} className={tab === k ? 'on' : ''} onClick={() => setTab(k)}>
            {label}
          </button>
        ))}
      </div>

      {tab === 'tracks' ? own ? <OwnTracks onChange={load} onUpload={() => setUploading(true)} /> : <Tracks list={t} /> : <Posts artistId={data.id} own={own} tracks={t} />}
    </div>
  );
}

function Bio({ data, own, onSaved }) {
  const [edit, setEdit] = useState(false);
  const [bio, setBio] = useState(data.bio || '');
  if (!own) return data.bio ? <p className="prof-bio">{data.bio}</p> : null;
  if (!edit)
    return (
      <p className="prof-bio">
        {data.bio || <span className="prof-empty">Расскажите о себе</span>}{' '}
        <button className="link" onClick={() => setEdit(true)}>
          Изменить
        </button>
      </p>
    );
  const save = async () => {
    try {
      await saveArtistProfile(data.id, { bio: bio.trim() });
      setEdit(false);
      onSaved();
    } catch (e) {
      toast(humanError(e), 'error');
    }
  };
  return (
    <div className="prof-bio-edit">
      <textarea className="cab-area" rows={3} maxLength={500} value={bio} onChange={(e) => setBio(e.target.value)} autoFocus />
      <div className="post-foot">
        <span className="post-count">Имя и фото меняются в аккаунте</span>
        <button className="link" onClick={() => setEdit(false)}>
          Отмена
        </button>
        <button className="btn primary" onClick={save}>
          Сохранить
        </button>
      </div>
    </div>
  );
}

// A track with its comments folded under it.
function TrackItem({ track, list, index, extra }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="prof-track">
      <TrackRow track={track} list={list} index={index} showAlbum={false} />
      <div className="prof-track-foot">
        {extra}
        <button className={'link' + (open ? ' on' : '')} onClick={() => setOpen(!open)}>
          <Icon name="chat" size={14} /> Комментарии
        </button>
      </div>
      {open && <Comments trackId={track.lic} />}
    </div>
  );
}

function Tracks({ list }) {
  if (!list.length) return <p className="prof-empty">Пока нет треков</p>;
  return (
    <div className="tracks prof-list">
      {list.map((tr, i) => (
        <TrackItem key={tr.id} track={tr} list={list} index={i} />
      ))}
    </div>
  );
}

const STATUS = { live: 'Опубликован', processing: 'Обрабатывается', hidden: 'Скрыт модерацией' };

// The owner sees every own track with its state and plays, and can take it down.
function OwnTracks({ onChange, onUpload }) {
  const [list, setList] = useState(null);
  const load = () => myTracks().then(setList).catch(() => setList([]));
  useEffect(() => {
    load();
  }, []);
  if (!list) return <Skeleton rows={3} />;
  if (!list.length)
    return (
      <div className="prof-first">
        <p>Здесь будут ваши треки. Загрузите первый, и его услышат все в Blink.</p>
        <button className="btn primary" onClick={onUpload}>
          <Icon name="plus" size={18} /> Загрузить трек
        </button>
      </div>
    );
  const tracks = list.map((r) => ({ ...fromRow(r), artwork: r.cover_url || '' }));
  const remove = async (r) => {
    if (!(await ask({ title: 'Снять трек?', text: `«${r.title}» пропадёт из Blink.`, ok: 'Снять', danger: true }))) return;
    await takedown(r.id).catch((e) => toast(humanError(e), 'error'));
    load();
    onChange();
  };
  return (
    <div className="tracks prof-list">
      {list.map((r, i) => (
        <TrackItem
          key={r.id}
          track={tracks[i]}
          list={tracks}
          index={i}
          extra={
            <>
              <span className="post-count">
                {STATUS[r.status] || r.status} · {plural(r.streams.total, 'прослушивание', 'прослушивания', 'прослушиваний')}
              </span>
              <button className="link" onClick={() => remove(r)}>
                Снять
              </button>
            </>
          }
        />
      ))}
    </div>
  );
}

// ---------------- Upload ----------------

const TEXT = [
  ['title', 'Название трека'],
  ['release_title', 'Альбом или сингл'],
  ['authors', 'Авторы музыки и текста, через запятую'],
  ['phonogram_maker', 'Кто записал (изготовитель фонограммы)'],
  ['genre', 'Жанр'],
  ['language', 'Язык'],
];

function UploadForm({ onDone, onCancel }) {
  const today = new Date().toISOString().slice(0, 10);
  const [me, setMe] = useState(null);
  const [f, setF] = useState({ year: String(new Date().getFullYear()), release_date: today });
  useEffect(() => {
    artistMe().then((d) => {
      setMe(d.artist);
      setF((x) => ({ ...x, phonogram_maker: x.phonogram_maker || d.artist.name }));
    });
  }, []);
  const [files, setFiles] = useState({});
  // One preview URL per picked cover, freed when it changes (not a new blob on every keystroke).
  const coverUrl = useMemo(() => files.cover && URL.createObjectURL(files.cover), [files.cover]);
  useEffect(() => () => coverUrl && URL.revokeObjectURL(coverUrl), [coverUrl]);
  const [offer, setOffer] = useState(false);
  const [progress, setProgress] = useState(null);
  const [err, setErr] = useState('');
  const needOffer = !me || !me.offer_accepted_at;
  const set = (k) => (e) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });
  const submit = async () => {
    setErr('');
    if (!me) return;
    if (needOffer && !offer) return setErr('Примите условия оферты');
    const fd = new FormData();
    for (const [k, v] of Object.entries(f)) if (k !== 'authors') fd.append(k, String(v));
    const authors = String(f.authors || '')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean)
      .map((name) => ({ name, role: 'музыка и текст' }));
    fd.append('authors', JSON.stringify(authors));
    if (files.audio) fd.append('audio', files.audio);
    if (files.cover) fd.append('cover', files.cover);
    setProgress(0);
    try {
      if (needOffer) await acceptOffer(me.name);
      await uploadTrack(fd, setProgress);
      toast('Трек опубликован');
      onDone();
    } catch (e) {
      setErr(humanError(e));
    }
    setProgress(null);
  };
  return (
    <section className="upload">
      <div className="upload-head">
        <h3>Новый трек</h3>
        <button className="icon-btn" title="Закрыть" onClick={onCancel}>
          <Icon name="close" size={18} />
        </button>
      </div>
      <div className="cab-files">
        <label className={'drop' + (files.audio ? ' on' : '')}>
          <Icon name="disc" size={22} />
          <span>{files.audio ? files.audio.name : 'Аудио: WAV, FLAC или MP3'}</span>
          <input type="file" hidden accept="audio/*,.wav,.flac,.mp3" onChange={(e) => setFiles({ ...files, audio: e.target.files[0] })} />
        </label>
        <label className={'drop' + (files.cover ? ' on' : '')}>
          {files.cover ? <img src={coverUrl} alt="" referrerPolicy="no-referrer" /> : <Icon name="plus" size={22} />}
          <span>{files.cover ? 'Обложка выбрана' : 'Обложка: JPEG или PNG'}</span>
          <input type="file" hidden accept="image/jpeg,image/png,image/webp" onChange={(e) => setFiles({ ...files, cover: e.target.files[0] })} />
        </label>
      </div>
      <div className="cab-grid">
        {TEXT.map(([k, label]) => (
          <input key={k} className="cab-in" placeholder={label} value={f[k] || ''} onChange={set(k)} />
        ))}
        <input className="cab-in" placeholder="Год" inputMode="numeric" value={f.year} onChange={set('year')} />
        <input className="cab-in" type="date" title="Дата релиза" value={f.release_date} onChange={set('release_date')} />
      </div>
      <input className="cab-in" placeholder="Сэмплы и чужие фрагменты, если есть" value={f.samples || ''} onChange={set('samples')} />
      <textarea className="cab-area" rows={3} placeholder="Текст песни (необязательно)" value={f.lyrics || ''} onChange={set('lyrics')} />
      <label className="cab-check">
        <input type="checkbox" checked={!!f.explicit} onChange={set('explicit')} /> Есть ненормативная лексика
      </label>
      <label className="cab-check">
        <input type="checkbox" checked={!!f.ai_used} onChange={set('ai_used')} /> При создании использовался ИИ
      </label>
      <label className="cab-check">
        <input type="checkbox" checked={!!f.rights} onChange={set('rights')} /> У меня есть все права на этот трек
      </label>
      {needOffer && (
        <label className="cab-check">
          <input type="checkbox" checked={offer} onChange={(e) => setOffer(e.target.checked)} /> Принимаю{' '}
          <a href={`${MEDIA}/offer.html`} target="_blank" rel="noopener" onClick={(e) => window.blink && window.blink.open && (e.preventDefault(), window.blink.open(`${MEDIA}/offer.html`))}>
            условия оферты
          </a>
        </label>
      )}
      <div className="post-foot">
        <div className="field-err">{err}</div>
        <button className="btn primary" disabled={progress !== null} onClick={submit}>
          {progress !== null ? `Загрузка ${Math.round(progress * 100)}%` : 'Опубликовать'}
        </button>
      </div>
    </section>
  );
}

// ---------------- Posts ----------------

function Posts({ artistId, own, tracks }) {
  const [list, setList] = useState(null);
  const load = () => listPosts(artistId).then(setList).catch(() => setList([]));
  useEffect(() => {
    load();
  }, [artistId]);
  if (!list) return <Skeleton rows={2} />;
  return (
    <div className="posts">
      {own && <Composer artistId={artistId} tracks={tracks} onDone={load} />}
      {list.map((p) => (
        <PostCard key={p.id} post={p} own={own} onDeleted={load} />
      ))}
      {!list.length && !own && <p className="prof-empty">Постов пока нет</p>}
    </div>
  );
}

function Composer({ artistId, tracks, onDone }) {
  const [body, setBody] = useState('');
  const [trackId, setTrackId] = useState('');
  const [busy, setBusy] = useState(false);
  const send = async () => {
    setBusy(true);
    try {
      await createPost(artistId, body.trim(), tracks.find((t) => t.id === trackId)?.lic);
      setBody('');
      setTrackId('');
      onDone();
    } catch (e) {
      toast(humanError(e), 'error');
    }
    setBusy(false);
  };
  return (
    <div className="post composer">
      <textarea className="cab-area" rows={3} maxLength={1000} value={body} onChange={(e) => setBody(e.target.value)} placeholder="Новый пост: релиз, концерт, новость" />
      <div className="post-foot">
        {tracks.length > 0 && (
          <select className="cab-in" value={trackId} onChange={(e) => setTrackId(e.target.value)}>
            <option value="">Без трека</option>
            {tracks.map((t) => (
              <option key={t.id} value={t.id}>
                {t.title}
              </option>
            ))}
          </select>
        )}
        <span className="post-count">{body.length}/1000</span>
        <button className="btn primary" disabled={busy || !body.trim()} onClick={send}>
          Опубликовать
        </button>
      </div>
    </div>
  );
}

function PostCard({ post, own, showArtist, onDeleted }) {
  const [liked, setLiked] = useState(post.liked);
  const [likes, setLikes] = useState(post.likes);
  const [open, setOpen] = useState(false);
  const like = async () => {
    if (!requireAccount('like')) return;
    const on = !liked;
    setLiked(on);
    setLikes((n) => n + (on ? 1 : -1));
    try {
      await setPostLike(post.id, on);
    } catch {
      setLiked(!on);
      setLikes((n) => n - (on ? 1 : -1));
    }
  };
  const remove = async () => {
    if (!(await ask({ title: 'Удалить пост?', ok: 'Удалить', danger: true }))) return;
    await deletePost(post.id).then(onDeleted, (e) => toast(humanError(e), 'error'));
  };
  return (
    <article className="post">
      <div className="post-head">
        {showArtist && (
          <button className="post-artist" onClick={() => go('bartist', { id: post.artist_id })}>
            {post.avatar_url && <img src={post.avatar_url} alt="" referrerPolicy="no-referrer" />}
            <b>{post.artist_name}</b>
          </button>
        )}
        <span className="post-time">{when(post.created_at)}</span>
      </div>
      <p className="post-body">{post.body}</p>
      {post.track && (
        <div className="tracks">
          <TrackRow track={post.track} list={[post.track]} index={0} showAlbum={false} />
        </div>
      )}
      <div className="post-foot">
        <button className={'icon-btn like' + (liked ? ' on' : '')} onClick={like} title="Нравится">
          <Icon name={liked ? 'heartFill' : 'heart'} size={18} />
        </button>
        <span className="post-count">{likes || ''}</span>
        <button className={'icon-btn' + (open ? ' on' : '')} onClick={() => setOpen(!open)} title="Комментарии">
          <Icon name="chat" size={18} />
        </button>
        {own ? (
          <button className="link post-report" onClick={remove}>
            Удалить
          </button>
        ) : (
          <button className="link post-report" onClick={() => sendReport('post', post.id)}>
            Пожаловаться
          </button>
        )}
      </div>
      {open && <Comments postId={post.id} />}
    </article>
  );
}

async function sendReport(kind, id) {
  if (!requireAccount('report')) return;
  if (!(await ask({ title: 'Пожаловаться?', text: 'Модераторы Blink посмотрят и скроют, если это нарушает правила.', ok: 'Отправить' }))) return;
  report(kind, id).then(() => toast('Жалоба отправлена'), (e) => toast(humanError(e), 'error'));
}

// Comments under a post (postId) or a Blink track (trackId); names open the author's page.
export function Comments({ postId = null, trackId = null }) {
  const user = useStore((s) => s.user);
  const [list, setList] = useState(null);
  const [body, setBody] = useState('');
  const [busy, setBusy] = useState(false);
  const where = { postId, trackId };
  const load = () => listComments(where).then(setList).catch(() => setList([]));
  useEffect(() => {
    load();
  }, [postId, trackId]);
  const send = async () => {
    if (!requireAccount('comment')) return;
    setBusy(true);
    try {
      await addComment(where, body.trim());
      setBody('');
      load();
    } catch (e) {
      toast(humanError(e), 'error');
    }
    setBusy(false);
  };
  const remove = async (c) => {
    await deleteComment(c.id).catch((e) => toast(humanError(e), 'error'));
    load();
  };
  return (
    <div className="comments">
      {!list ? (
        <Skeleton rows={2} />
      ) : (
        list.map((c) => (
          <div className="comment" key={c.id}>
            {c.avatar ? <img src={c.avatar} alt="" referrerPolicy="no-referrer" /> : <span className="comment-ava" />}
            <div className="comment-main">
              <div className="comment-head">
                {c.artist_id ? (
                  <button className="post-artist" onClick={() => go('bartist', { id: c.artist_id })}>
                    <b>{c.name}</b>
                  </button>
                ) : (
                  <b>{c.name}</b>
                )}{' '}
                <span className="post-time">{when(c.created_at)}</span>
              </div>
              <p className="post-body">{c.body}</p>
            </div>
            {user && c.user_id === user.id ? (
              <button className="link" onClick={() => remove(c)}>
                Удалить
              </button>
            ) : (
              <button className="link post-report" onClick={() => sendReport('comment', c.id)}>
                Пожаловаться
              </button>
            )}
          </div>
        ))
      )}
      {list && !list.length && <p className="prof-empty">Комментариев пока нет</p>}
      <div className="comment-new">
        <input className="cab-in" maxLength={500} value={body} placeholder="Написать комментарий" onChange={(e) => setBody(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && body.trim() && !busy && send()} />
        <button className="btn ghost" disabled={busy || !body.trim()} onClick={send}>
          Отправить
        </button>
      </div>
    </div>
  );
}

// Home block: posts from accounts the listener follows.
export function FollowFeed() {
  const user = useStore((s) => s.user);
  const [list, setList] = useState(null);
  useEffect(() => {
    if (user) listPosts().then(setList).catch(() => setList(null));
  }, [user]);
  if (!user || !list || !list.length) return null;
  return (
    <section className="section">
      <div className="section-head">
        <h2 className="h-section">Посты от подписок</h2>
      </div>
      <div className="posts">
        {list.slice(0, 6).map((p) => (
          <PostCard key={p.id} post={p} showArtist />
        ))}
      </div>
    </section>
  );
}
