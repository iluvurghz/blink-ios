// Line-by-line translation of lyrics into Russian, kept per track for the session.
// Returns { lang, lines: Map(original line → translation) }; lang 'ru' means nothing to do.
// The main translator rate-limits some networks; a second one takes over then.
const SELF = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '');
const cache = new Map();
const SEP = '\n';

async function get(url) {
  const r = await window.blink.json(url, { tries: 1, timeout: 10000 });
  if (!r.ok) throw Object.assign(new Error('HTTP ' + r.status), { status: r.status });
  return r.data;
}

async function primary(lines) {
  const d = await get(`${SELF}/api/translate/google?q=${encodeURIComponent(lines.join(SEP))}`);
  if (!Array.isArray(d)) throw new Error('translate');
  const text = (d[0] || []).map((seg) => (seg && seg[0]) || '').join('');
  return text.split(SEP).map((x) => x.trim());
}

async function backup(lines, from) {
  const d = await get(`${SELF}/api/translate/mymemory?q=${encodeURIComponent(lines.join(SEP))}&from=${from}`);
  if (!d || !d.responseData || Number(d.responseStatus) !== 200) throw new Error('translate');
  return String(d.responseData.translatedText || '').split(/\r?\n/).map((x) => x.trim());
}

// Cyrillic lyrics don't need translating; Latin ones are guessed as English for the backup.
function guessLang(texts) {
  const s = texts.join(' ');
  const cyr = (s.match(/[Ѐ-ӿ]/g) || []).length;
  const lat = (s.match(/[a-z]/gi) || []).length;
  if (cyr > lat) return 'ru';
  if (/[ñ¿¡]/i.test(s)) return 'es';
  if (/[äöüß]/i.test(s)) return 'de';
  if (/[àâçéèêëîïôûùœ]/i.test(s)) return 'fr';
  return 'en';
}

async function batch(part, lang, state) {
  if (!state.backup) {
    try {
      const out = await primary(part);
      if (out.length === part.length) return out;
    } catch {
      state.backup = true;
    }
  }
  // The backup takes up to 500 characters per request.
  const out = [];
  let group = [];
  const flush = async () => {
    if (!group.length) return;
    const res = await backup(group, lang).catch(() => null);
    if (res && res.length === group.length) out.push(...res);
    else for (const t of group) out.push(((await backup([t], lang).catch(() => [''])) || [''])[0]);
    group = [];
  };
  for (const t of part) {
    if ([...group, t].join(SEP).length > 450) await flush();
    group.push(t);
  }
  await flush();
  return out;
}

export async function translateLines(id, texts) {
  if (cache.has(id)) return cache.get(id);
  const job = (async () => {
    const uniq = [...new Set(texts.map((t) => (t || '').trim()).filter(Boolean))];
    const lang = guessLang(uniq);
    const map = new Map();
    if (lang === 'ru' || !uniq.length) return { lang: 'ru', lines: map };
    const state = { backup: false };
    for (let i = 0; i < uniq.length; i += 25) {
      const part = uniq.slice(i, i + 25);
      const out = await batch(part, lang, state);
      part.forEach((t, k) => out[k] && map.set(t, out[k]));
    }
    if (!map.size) throw new Error('translate');
    return { lang, lines: map };
  })();
  cache.set(id, job);
  job.catch(() => cache.delete(id));
  return job;
}
