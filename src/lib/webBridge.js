// In a normal browser there is no Electron: the same interface runs on plain web APIs.
const KEY = 'blink-data';

export function installWebBridge() {
  const noop = () => {};
  window.blink = {
    isWeb: true,
    async json(url) {
      try {
        const r = await fetch(url);
        const text = await r.text();
        let data = text;
        try {
          data = JSON.parse(text);
        } catch {
          /* not json */
        }
        return { ok: r.ok, status: r.status, data };
      } catch (e) {
        return { ok: false, status: 0, error: e.message };
      }
    },
    async image(url) {
      try {
        const blob = await (await fetch(url)).blob();
        return await new Promise((res) => {
          const fr = new FileReader();
          fr.onload = () => res(fr.result);
          fr.onerror = () => res(null);
          fr.readAsDataURL(blob);
        });
      } catch {
        return null;
      }
    },
    async load() {
      try {
        return JSON.parse(localStorage.getItem(KEY) || '{}');
      } catch {
        return {};
      }
    },
    save(data) {
      try {
        localStorage.setItem(KEY, JSON.stringify(data));
      } catch {
        /* storage full or blocked */
      }
    },
    builtinKey: async () => '',
    minimize: noop,
    maximize: noop,
    close: noop,
    isMaximized: async () => false,
    open: (url) => window.open(url, '_blank', 'noopener'),
    playback: noop,
    thumbIcons: noop,
    onMedia: noop,
    onWinState: noop,
  };
}

// Runs on import, before any module that reads window.blink.
if (!window.blink) installWebBridge();
