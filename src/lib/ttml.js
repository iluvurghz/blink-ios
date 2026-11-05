// TTML lyrics (Apple-style timed text): lines from <p begin end>, and word timings from
// the <span begin> inside them, so karaoke can light up word by word.

function seconds(v) {
  if (!v) return null;
  v = String(v).trim();
  let m = /^(\d+(?:\.\d+)?)(h|m|s|ms)$/.exec(v);
  if (m) return Number(m[1]) * { h: 3600, m: 60, s: 1, ms: 0.001 }[m[2]];
  m = /^(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$/.exec(v);
  if (m) return (Number(m[1]) || 0) * 3600 + Number(m[2]) * 60 + Number(m[3]);
  return Number.isFinite(Number(v)) ? Number(v) : null;
}

export function parseTtml(xml) {
  const doc = new DOMParser().parseFromString(xml, 'application/xml');
  if (doc.getElementsByTagName('parsererror').length) return null;
  const lines = [];
  for (const p of doc.getElementsByTagNameNS('*', 'p')) {
    const t = seconds(p.getAttribute('begin'));
    if (t === null) continue;
    const end = seconds(p.getAttribute('end'));
    const words = [];
    for (const sp of p.getElementsByTagNameNS('*', 'span')) {
      const wt = seconds(sp.getAttribute('begin'));
      const text = sp.textContent;
      // Background vocals (ttm:role="x-bg") nest their own spans; keep only timed leaf words.
      if (wt === null || sp.getElementsByTagNameNS('*', 'span').length) continue;
      words.push({ t: wt, end: seconds(sp.getAttribute('end')), w: text });
    }
    // Spans often drop the spaces between words: restore them from the line's own text.
    const text = p.textContent.replace(/\s+/g, ' ').trim();
    if (!text) continue;
    if (words.length) {
      let at = 0;
      for (const w of words) {
        const i = text.indexOf(w.w.trim(), at);
        if (i >= 0) {
          w.from = i;
          at = i + w.w.trim().length;
          w.to = at;
        }
      }
    }
    lines.push({ t, end: end ?? undefined, text, words: words.length ? words : null });
  }
  lines.sort((a, b) => a.t - b.t);
  return lines.length ? lines : null;
}
