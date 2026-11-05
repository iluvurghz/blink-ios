import { useEffect, useState } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import Icon from './Icon.jsx';

// Blink's own "are you sure?" instead of the system confirm():
//   if (await ask({ title: 'Удалить плейлист?', text: '…', ok: 'Удалить', danger: true })) …
let show = null;
export function ask(opts) {
  if (!show) return Promise.resolve(window.confirm(opts.title));
  return new Promise((resolve) => show({ ...opts, resolve }));
}

export default function Confirm() {
  const [q, setQ] = useState(null);
  useEffect(() => {
    show = setQ;
    return () => (show = null);
  }, []);
  const done = (v) => {
    if (!q) return;
    q.resolve(v);
    setQ(null);
  };
  useEffect(() => {
    if (!q) return;
    const key = (e) => {
      if (e.key === 'Escape') done(false);
      if (e.key === 'Enter') done(true);
    };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, [q]);

  return (
    <AnimatePresence>
      {q && (
        <motion.div className="scrim confirm-scrim" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0, transition: { duration: 0.16 } }} onPointerDown={(e) => e.target === e.currentTarget && done(false)}>
          <motion.div
            className={'confirm' + (q.danger ? ' danger' : '')}
            role="alertdialog"
            aria-modal="true"
            initial={{ opacity: 0, y: 16, scale: 0.95 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 8, scale: 0.97, transition: { duration: 0.14 } }}
            transition={{ type: 'spring', duration: 0.4, bounce: 0.18 }}
          >
            <span className="confirm-ico">
              <Icon name={q.icon || (q.danger ? 'trash' : 'check')} size={22} />
            </span>
            <h3>{q.title}</h3>
            {q.text && <p>{q.text}</p>}
            <div className="confirm-act">
              <button className="btn ghost" onClick={() => done(false)}>
                {q.cancel || 'Отмена'}
              </button>
              <button className={'btn ' + (q.danger ? 'danger' : 'primary')} onClick={() => done(true)} autoFocus>
                {q.ok || 'Да'}
              </button>
            </div>
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}
