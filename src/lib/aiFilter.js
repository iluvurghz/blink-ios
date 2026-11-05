// Нейротреки: AI-generated songs are kept out of search and «Вспышка».
// Apple and the other catalogs carry no AI flag, so this goes by three signs:
// a short list of known AI projects, AI words in the title/album/artist, and artists
// the listener marked «Это нейротрек» (kept on this device).
import { store } from './store.js';
import { splitArtists } from './api.js';

const KNOWN = new Set(['the velvet sundown', 'velvet sundown', 'breaking rust', 'xania monet', 'aventhis', 'cain walker']);

// Not bare «нейро»: real bands use it (Нейромонах Феофан).
const WORDS = /\b(suno|udio)\b|\bai[\s-]?(generated|cover|song|music|version|remix)\b|нейросет|нейро[\s-]?(кавер|трек|верси|песн)|(^|[^а-яё])ии[\s-]?(кавер|верси|песн)/i;

const names = (t) => splitArtists(t.artist || '').map((n) => n.toLowerCase());

export function isAi(track) {
  if (!track) return false;
  const banned = (store.get().aiBan || {}).artists || [];
  const ns = names(track);
  if (ns.some((n) => KNOWN.has(n) || banned.includes(n))) return true;
  return WORDS.test(`${track.title || ''} ${track.album || ''} ${track.artist || ''}`);
}

export const noAi = (list) => (list || []).filter((t) => !isAi(t));

// «Это нейротрек»: hide the artist everywhere and drop their songs from the queue ahead.
export function markAi(track) {
  const s = store.get();
  const artists = [...new Set([...((s.aiBan || {}).artists || []), ...names(track)])].slice(-1000);
  const ns = new Set(names(track));
  const queue = s.queue.filter((t, i) => i <= s.index || !names(t).some((n) => ns.has(n)));
  store.set({ aiBan: { artists }, queue });
}
