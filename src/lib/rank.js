// Search ranking: what the listener already knows comes first (liked, recently played, similar
// titles), then how well the track matches the query, then the catalog's own popularity order.

const norm = (s) => (s || '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
const words = (s) => new Set(norm(s).split(' ').filter(Boolean));

function overlap(a, b) {
  const A = words(a);
  const B = words(b);
  if (!A.size || !B.size) return 0;
  let n = 0;
  for (const w of A) if (B.has(w)) n++;
  return n / Math.max(A.size, B.size);
}

// How well a track answers the query: 0..1.
function match(t, q) {
  const nq = norm(q);
  const title = norm(t.title);
  const artist = norm(t.artist);
  if (!nq) return 0;
  if (title === nq || `${artist} ${title}` === nq || `${title} ${artist}` === nq) return 1;
  if (artist === nq) return 0.8; // query is the artist's name: all their tracks fit
  if (title.startsWith(nq)) return 0.75;
  return Math.max(overlap(`${artist} ${title}`, q), overlap(t.title, q) * 0.9);
}

// tracks: in the catalog's order (Apple's is by popularity). state: { likes, recent }.
export function rankTracks(tracks, q, { likes = [], recent = [] } = {}) {
  const liked = new Set(likes.map((t) => t.id));
  const played = new Map(recent.map((t, i) => [t.id, i]));
  const known = [...likes, ...recent].map((t) => norm(t.title)).filter(Boolean);
  const knownArtists = new Set([...likes, ...recent].map((t) => norm((t.artist || '').split(/,|&|\sfeat/i)[0])));
  const n = tracks.length || 1;
  const scored = tracks.map((t, i) => {
    let s = match(t, q) * 3;
    if (liked.has(t.id)) s += 4;
    if (played.has(t.id)) s += 3 - (played.get(t.id) / 60) * 1.5;
    const title = norm(t.title);
    if (!liked.has(t.id) && !played.has(t.id) && known.some((k) => k === title || overlap(k, title) >= 0.6)) s += 1.5;
    if (knownArtists.has(norm((t.artist || '').split(/,|&|\sfeat/i)[0]))) s += 0.8;
    if (t.source === 'blink') s += 0.5; // Blink's own releases
    s += (1 - i / n) * 1.2; // popularity: earlier in the catalog list = more popular
    return { t, s };
  });
  return scored.sort((a, b) => b.s - a.s).map((x) => x.t);
}
