// «Поделиться» for a track: the phone's own share sheet when there is one, otherwise the link is copied.
import { trackLink } from '../lib/cloud.js';
import { toast } from '../lib/store.js';

export async function shareTrack(track) {
  const url = trackLink(track);
  const title = track.artist ? `${track.title} — ${track.artist}` : track.title;
  if (navigator.share && window.matchMedia('(pointer: coarse)').matches) {
    try {
      await navigator.share({ title, url });
      return;
    } catch (e) {
      if (e && e.name === 'AbortError') return;
    }
  }
  try {
    await navigator.clipboard.writeText(url);
    toast('Ссылка на трек скопирована');
  } catch {
    toast('Не получилось скопировать', 'error');
  }
}
