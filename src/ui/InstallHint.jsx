import { useState } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import Icon from './Icon.jsx';

// iPhone Safari has no install button of its own: once, a small card shows how to put Blink on
// the home screen, where it opens full screen like an app.
const IOS = /iP(hone|ad|od)/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
const standalone = () => navigator.standalone || window.matchMedia('(display-mode: standalone)').matches;
const KEY = 'blink-install-hint';

function seen() {
  try {
    return !!localStorage.getItem(KEY);
  } catch {
    return true;
  }
}

export default function InstallHint() {
  const [show, setShow] = useState(() => window.blink && window.blink.isWeb && IOS && !standalone() && !seen());
  const close = () => {
    setShow(false);
    try {
      localStorage.setItem(KEY, '1');
    } catch {
      /* private mode */
    }
  };
  return (
    <AnimatePresence>
      {show && (
        <motion.div className="install-hint" initial={{ opacity: 0, y: -12 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -8 }} transition={{ type: 'spring', duration: 0.45, bounce: 0.15 }}>
          <img src="./apple-touch-icon.png" alt="" />
          <div>
            <b>Blink как приложение</b>
            <span>
              Нажмите <Icon name="share" size={14} /> внизу Safari, затем «На экран Домой»
            </span>
          </div>
          <button className="icon-btn" title="Закрыть" onClick={close}>
            <Icon name="close" size={18} />
          </button>
        </motion.div>
      )}
    </AnimatePresence>
  );
}
