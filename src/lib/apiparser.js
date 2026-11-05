// Client for the api parser service (multi-source MP3 search).
// Requests go through blinkmusic.cc/api/mp3/search → proxied to the local
// api parser process on the server. Works in both the desktop app and browser.

import { cloud } from './cloud.js';

const MEDIA = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '');

async function authHeader() {
  if (!cloud) return {};
  const { data } = await cloud.auth.getSession().catch(() => ({ data: {} }));
  const token = data?.session?.access_token;
  return token ? { Authorization: `Bearer ${token}` } : {};
}

// Helper: clean track/artist names (remove suffixes that break exact search)
function cleanStr(str) {
  return str
    .replace(/\[.*?\]/gi, '')
    .replace(/\(.*?(slowed|speed\s*up|remix|edit|version|prod\.?|feat\.?).*?\)/gi, '')
    .replace(/\s+/g, ' ')
    .trim();
}

// Helper: fetch one search page and return first item with a valid url, or null
// HLS playlists (.m3u8) require MSE/hls.js — plain <audio> can't play them on most platforms.
const isPlayable = (url) =>
  url && url.startsWith('https://') && !url.includes('.m3u8') && !url.includes('playlist.m3u8');

// Wrap parser source URLs through our server proxy so they work from Russia (hitmos.fm etc.
// block or time out for Russian IPs). The proxy fetches from Sweden and streams to the client.
const proxyUrl = (url) => `${MEDIA}/api/mp3/stream?url=${encodeURIComponent(url)}`;

async function fetchOne(params, headers) {
  try {
    // The parser walks its sources one by one; past this it is not worth waiting.
    const res = await fetch(`${MEDIA}/api/mp3/search?${params}`, { headers, signal: AbortSignal.timeout(15000) });
    if (!res.ok) return null;
    const data = await res.json();
    if (!data?.items?.length) return null;
    // Find first item with a directly playable (non-HLS) URL.
    const item = data.items.find((i) => isPlayable(i.download_url));
    if (!item) return null;
    return { url: proxyUrl(item.download_url), duration: item.duration_seconds || 0 };
  } catch {
    return null;
  }
}

/**
 * Search for a track by title + artist via the api parser proxy.
 * Returns { url, duration } or null.
 * Fires all strategies in parallel and uses the first valid result — much faster
 * than trying them one by one.
 */
export async function findMp3(title, artist) {
  try {
    const headers = await authHeader();
    const cleanTitle = cleanStr(title);
    const cleanArtist = cleanStr(artist);
    const firstArtist = artist.split(/,|&|\sfeat\.?\s|\sft\.?\s/i)[0].trim();
    const cleanFirstArtist = cleanStr(firstArtist);

    // Build all search strategies — each is a URLSearchParams.
    const strategies = [
      new URLSearchParams({ q: title, artist, mode: 'track', limit: 1 }),
    ];
    if (cleanTitle !== title || cleanArtist !== artist) {
      strategies.push(new URLSearchParams({ q: cleanTitle, artist: cleanArtist, mode: 'track', limit: 1 }));
    }
    if (cleanFirstArtist !== cleanArtist) {
      strategies.push(new URLSearchParams({ q: cleanTitle, artist: cleanFirstArtist, mode: 'track', limit: 1 }));
    }
    strategies.push(new URLSearchParams({ q: `${firstArtist} - ${cleanTitle}`, mode: 'track', limit: 1 }));

    // Fire all at once, return the first that finds a playable track.
    // (Not Promise.all: that waited for the slowest strategy even when the first had the track.)
    return await new Promise((resolve) => {
      let left = strategies.length;
      for (const params of strategies)
        fetchOne(params, headers).then((r) => (r ? resolve(r) : --left === 0 && resolve(null)));
    });
  } catch (e) {
    console.warn('[apiparser] findMp3 failed:', e.message);
    return null;
  }
}

/**
 * Search for tracks by free-form query via the api parser proxy.
 * Used in the Blink search UI as a supplementary source.
 * Returns array of { title, artist, url, duration } or [].
 */
export async function searchMp3(query, limit = 20) {
  try {
    const headers = await authHeader();
    const params = new URLSearchParams({ q: query, mode: 'auto', limit });
    const res = await fetch(`${MEDIA}/api/mp3/search?${params}`, { headers });
    if (!res.ok) return [];
    const data = await res.json();
    if (!data?.items?.length) return [];
    return data.items
      .filter((item) => isPlayable(item.download_url))
      .map((item) => ({
        title: item.title || query,
        artist: item.artist || '',
        url: proxyUrl(item.download_url),
        duration: item.duration_seconds || 0,
        source: item.source || 'parser',
      }));
  } catch (e) {
    console.warn('[apiparser] searchMp3 failed:', e.message);
    return [];
  }
}
