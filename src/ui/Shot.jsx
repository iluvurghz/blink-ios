import { useEffect, useRef, useState } from 'react';
import { useStore } from '../lib/store.js';
import { shotFor } from '../lib/player.js';

// A short looping video of the track (Yandex «видеошот») drawn over its cover while it plays.
// Quiet failure: no video, a slow one or an error leaves the plain cover as it was.
export default function Shot({ track, stage = false, idle = false }) {
  const [src, setSrc] = useState('');
  const [on, setOn] = useState(false);
  const playing = useStore((s) => s.status === 'playing');
  const enabled = useStore((s) => s.settings.shots !== false && !s.settings.game);
  const el = useRef(null);
  const id = track && track.id;
  useEffect(() => {
    setSrc('');
    setOn(false);
    if (!track || !enabled) return;
    let alive = true;
    // Let the track itself start first: the clip is a nicety, not worth competing with the audio.
    const t = setTimeout(() => shotFor(track).then((u) => alive && u && setSrc(u)).catch(() => {}), 1200);
    return () => {
      alive = false;
      clearTimeout(t);
    };
  }, [id, enabled]);
  useEffect(() => {
    const v = el.current;
    if (!v) return;
    if (playing) v.play().catch(() => {});
    else v.pause();
  }, [playing, src, idle]);
  if (!src) return null;
  return <video ref={el} className={'shot' + (stage ? ' stage-shot' : '') + (on ? ' on' : '')} src={src} muted loop playsInline autoPlay preload="auto" disablePictureInPicture onCanPlay={() => { setOn(true); if (playing) el.current && el.current.play().catch(() => {}); }} onError={() => setSrc('')} />;
}
