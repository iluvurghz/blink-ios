import { useEffect, useRef, useState } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import Shot from './Shot.jsx';
import { createDots } from './dots.js';
import { proxied, coverFallback } from '../lib/img.js';

const ease = [0.23, 1, 0.32, 1];

// The object of the home page: «Точка» (see dots.js). Asleep it is a square of dots with a play icon made
// of dots; lit, the dots swell and merge into the cover. The cover itself is the real picture (an <img>, so
// the video shot, the swap between tracks and the crisp edges all work); the dots only play the way to it.
export default function FlashObject({ state, track, photo }) {
  const box = useRef(null);
  const dots = useRef(null);
  const [whole, setWhole] = useState(false); // the dots have become the picture: show the real cover
  useEffect(() => {
    dots.current = createDots(box.current, { onReveal: () => setWhole(true) });
    return () => dots.current.destroy();
  }, []);
  useEffect(() => {
    if (state !== 'flash') setWhole(false);
    if (dots.current) dots.current.set({ state, photo: proxied(photo) });
  }, [state, photo]);

  // the cover on show; it stays mounted for a moment after «Вспышка» stops, so it can fade out
  const lit = state === 'flash' && track;
  const [on, setOn] = useState(null);
  useEffect(() => {
    if (lit) {
      setOn({ track, photo });
      return;
    }
    const t = setTimeout(() => setOn(null), 400);
    return () => clearTimeout(t);
  }, [lit, track, photo]);
  const c = lit ? { track, photo } : on;
  return (
    <div className={'fo fo-' + state}>
      <div className="fo-fx" ref={box} aria-hidden="true" />
      <div className={'fo-cover' + (lit && whole ? ' show' : '')}>
        {c && (
          <>
            <AnimatePresence mode="popLayout" initial={false}>
              {c.photo ? (
                <motion.img key={c.track.id} src={proxied(c.photo)} {...coverFallback(c.photo)} alt="" draggable={false} initial={{ opacity: 0, scale: 1.04 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.5, ease }} />
              ) : (
                <motion.div key={c.track.id} className="fo-blank" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.4, ease }} />
              )}
            </AnimatePresence>
            {lit && <Shot track={c.track} />}
          </>
        )}
      </div>
    </div>
  );
}
