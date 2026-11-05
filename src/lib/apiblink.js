// Client for the APIBlink service (Yandex Music search + stream).
// Requests go through blinkmusic.cc/api/apiblink/play → proxied to the local
// APIBlink process on port 3000. Works in both the desktop app and browser.
//
// The proxy rewrites relative URLs to /api/apiblink/<type>/<id> before they
// reach the client, so they're served securely through HTTPS on blinkmusic.cc.

import { cloud } from './cloud.js';

const MEDIA = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '');

// Convert any URL coming from the APIBlink proxy to an absolute HTTPS URL.
// Handles: relative /api/apiblink/..., and mistaken http://127.0.0.1:3000/... leaks.
function toAbsolute(url) {
  if (!url) return url;
  // Strip localhost leak — replace with our MEDIA proxy
  if (/^https?:\/\/127\.0\.0\.1(:\d+)?\//.test(url)) {
    return MEDIA + url.replace(/^https?:\/\/127\.0\.0\.1(:\d+)?/, '');
  }
  if (/^https?:\/\/localhost(:\d+)?\//.test(url)) {
    return MEDIA + url.replace(/^https?:\/\/localhost(:\d+)?/, '');
  }
  // Relative path → absolute
  if (url.startsWith('/')) return MEDIA + url;
  // Already absolute HTTPS (e.g. avatars.yandex.net)
  return url;
}

async function authHeader() {
  if (!cloud) return {};
  const { data } = await cloud.auth.getSession().catch(() => ({ data: {} }));
  const token = data?.session?.access_token;
  return token ? { Authorization: `Bearer ${token}` } : {};
}

/**
 * Find a playable track by title + artist via APIBlink (Yandex Music).
 * Returns { url, duration, artwork, lyrics, video } or null.
 * The url is an absolute URL to the APIBlink stream endpoint (supports Range/seek).
 */
export async function findApiblink(title, artist) {
  try {
    const headers = await authHeader();
    const params = new URLSearchParams({ artist: artist || '', title: title || '' });
    const res = await fetch(`${MEDIA}/api/apiblink/play?${params}`, {
      headers,
      signal: AbortSignal.timeout(18000),
    });
    if (!res.ok) return null;
    const data = await res.json();
    if (!data?.track?.streamUrl) return null;
    // URLs come as /api/apiblink/stream/:id — make them absolute via MEDIA
    const t = data.track;
    return {
      url:      toAbsolute(t.streamUrl),
      duration: t.duration || 0,
      // Use artworkDirect (stable avatars.yandex.net URL) if available, else fall back to proxied ID.
      // artworkDirect is safe to store permanently; artworkUrl expires in ~4h.
      artwork:  t.artworkDirect || toAbsolute(t.artworkUrl) || null,
      lyrics:   toAbsolute(t.lyricsUrl)  || null,
      video:    toAbsolute(t.videoUrl)   || null,
      source: 'apiblink',
    };
  } catch (e) {
    console.warn('[apiblink] findApiblink failed:', e.message);
    return null;
  }
}

/**
 * Search for tracks by free-form query via APIBlink.
 * Uses the dedicated /api/apiblink/search endpoint.
 * Returns array of { title, artist, url, duration, artwork, source } or [].
 */
export async function searchApiblink(query) {
  try {
    const headers = await authHeader();
    const params = new URLSearchParams({ q: query });
    const res = await fetch(`${MEDIA}/api/apiblink/search?${params}`, {
      headers,
      signal: AbortSignal.timeout(18000),
    });
    if (!res.ok) return [];
    const data = await res.json();
    return (data.results || []).map(t => ({
      title:    t.title,
      artist:   t.artist,
      duration: t.duration || 0,
      url:      toAbsolute(t.streamUrl) || '',
      // Prefer artworkDirect (stable avatars.yandex.net) over the expiring /artwork/:id proxy
      artwork:  t.artworkDirect || toAbsolute(t.artworkUrl) || null,
      source:   'apiblink',
    }));
  } catch (e) {
    console.warn('[apiblink] searchApiblink failed:', e.message);
    return [];
  }
}

/**
 * Find a 30-second Yandex Music preview URL for a track.
 * Used as the soundtrack for story card videos when iTunes preview is unavailable.
 * Returns a stream URL string or '' when not found.
 */
export async function findYandexPreview(title, artist) {
  try {
    const headers = await authHeader();
    const params = new URLSearchParams({ artist: artist || '', title: title || '' });
    const res = await fetch(`${MEDIA}/api/apiblink/play?${params}`, {
      headers,
      signal: AbortSignal.timeout(18000),
    });
    if (!res.ok) return '';
    const data = await res.json();
    if (!data?.track?.streamUrl) return '';
    return toAbsolute(data.track.streamUrl);
  } catch {
    return '';
  }
}

/**
 * Check if APIBlink is enabled and reachable.
 * Returns { enabled, status } or { enabled: false }.
 */
export async function apiblinkStatus() {
  try {
    const res = await fetch(`${MEDIA}/api/apiblink/health`, { signal: AbortSignal.timeout(5000) });
    if (!res.ok) return { enabled: false, status: 'error' };
    const data = await res.json();
    return { enabled: data.status === 'ok', status: data.status };
  } catch {
    return { enabled: false, status: 'unreachable' };
  }
}
