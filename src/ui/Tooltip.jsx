import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { motion, AnimatePresence } from 'motion/react';

// One styled tooltip for the whole app instead of the system one: anything with a title gets it.
// On hover the title moves to data-tip, so Windows doesn't draw its own grey box on top.
// «Назад (Alt+←)» → text «Назад» and a key cap «Alt+←».
const KEYS = /^(.+?)\s*\(((?:Ctrl|Alt|Shift|Пробел|Space|Esc|Enter|[A-Z←→↑↓])(?:[ +][^()]*)?)\)$/;
const split = (text) => {
  const m = KEYS.exec(text);
  return m ? [m[1], m[2]] : [text, null];
};

export default function Tooltip() {
  const [tip, setTip] = useState(null);
  const box = useRef(null);

  // Keep it inside the window: slide the box in from the edge, the tail stays on the target.
  useLayoutEffect(() => {
    const el = box.current;
    if (!el || !tip) return;
    const w = el.offsetWidth;
    const shift = Math.max(12 - (tip.x - w / 2), Math.min(0, window.innerWidth - 12 - (tip.x + w / 2)));
    el.style.marginLeft = shift + 'px';
    el.style.setProperty('--tail', `calc(50% - ${shift}px)`);
  }, [tip]);

  useEffect(() => {
    if (!window.matchMedia('(hover: hover)').matches) return;
    let timer = 0;
    let cur = null;
    let shown = 0; // when the last tooltip went away: moving along a toolbar shows the next one at once
    const hide = () => {
      clearTimeout(timer);
      if (cur) shown = performance.now();
      cur = null;
      setTip(null);
    };
    const over = (e) => {
      const el = e.target.closest ? e.target.closest('[title], [data-tip]') : null;
      if (el === cur) return;
      hide();
      if (!el) return;
      const title = el.getAttribute('title');
      if (title !== null) {
        el.removeAttribute('title');
        if (title) el.dataset.tip = title;
        if (title && !el.hasAttribute('aria-label') && !el.textContent.trim()) el.setAttribute('aria-label', title);
      }
      const text = el.dataset.tip;
      if (!text) return;
      cur = el;
      timer = setTimeout(() => {
        if (cur !== el || !el.isConnected) return;
        const r = el.getBoundingClientRect();
        const below = r.top < 64;
        const x = r.left + r.width / 2;
        setTip({ text, x, y: below ? r.bottom + 10 : r.top - 10, below });
      }, performance.now() - shown < 400 ? 0 : 320);
    };
    const out = (e) => !e.relatedTarget && hide();
    document.addEventListener('mouseover', over);
    document.addEventListener('mouseout', out);
    document.addEventListener('mousedown', hide, true);
    document.addEventListener('wheel', hide, { capture: true, passive: true });
    window.addEventListener('blur', hide);
    return () => {
      hide();
      document.removeEventListener('mouseover', over);
      document.removeEventListener('mouseout', out);
      document.removeEventListener('mousedown', hide, true);
      document.removeEventListener('wheel', hide, { capture: true });
      window.removeEventListener('blur', hide);
    };
  }, []);

  return (
    <AnimatePresence>
      {tip && (
        <motion.div
          key={tip.text + tip.x + tip.y}
          ref={box}
          className={'tip-pop' + (tip.below ? ' below' : '')}
          style={{ left: tip.x, top: tip.y }}
          initial={{ opacity: 0, y: tip.below ? -4 : 4, scale: 0.96 }}
          animate={{ opacity: 1, y: 0, scale: 1 }}
          exit={{ opacity: 0, transition: { duration: 0.1 } }}
          transition={{ duration: 0.18, ease: [0.23, 1, 0.32, 1] }}
        >
          {split(tip.text)[0]}
          {split(tip.text)[1] && <kbd>{split(tip.text)[1]}</kbd>}
        </motion.div>
      )}
    </AnimatePresence>
  );
}
