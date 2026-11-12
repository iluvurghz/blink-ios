import { store, clock, toast, pushRecent, ytKey, requireAccount, ytFresh, markDead } from './store.js';
import { resolveVideos, artist as fetchArtist } from './api.js';
import { resolveRemote, recordPlay, DEVICE_NAME, playableIds } from './cloud.js';
import { waveBatch, quickStart, similarTo, noteSkip, noteListen } from './wave.js';
import { playUrl, reportStream, latestLicensed } from './catalog.js';
import { findMp3 } from './apiparser.js';
import { findApiblink } from './apiblink.js';
import { isSaved, savedUrl } from './offline.js';
import { scaleSc } from './img.js';
import { hasEq, wire, gainOf, resume as resumeEq, eqState } from './eq.js';

const bridge = window.blink;
let yt = null;
// The player that lives in the visible #yt-player host (used for the clip/video view). `yt`
// always points at the player of the *current* track; during a crossfade the outgoing track keeps
// playing on the other one, and the two swap roles (ping-pong) from track to track.
let ytMain = null;
let ytSpare = null;
let spareReady = null;
let xf = null; // the outgoing track of a crossfade, still fading out: { p: YouTube player } or { el: audio element }
let ready = null;
let candidates = [];
let candidateIdx = 0;
let currentVideo = null;
let loadToken = 0;
let pendingStart = 0;
let loadAt = 0;

// Official YouTube IFrame player, kept in #yt-player (see YtHost in App.jsx).
function loadApi() {
  if (ready) return ready;
  ready = new Promise((resolve) => {
    window.onYouTubeIframeAPIReady = () => {
      const p = new window.YT.Player('yt-player', {
        width: '100%',
        height: '100%',
        playerVars: { autoplay: 1, controls: 0, disablekb: 1, fs: 0, iv_load_policy: 3, playsinline: 1, rel: 0, origin: location.origin },
        events: {
          onReady: () => resolve(p),
          onStateChange: (e) => onState(e.data, p),
          onError: (e) => onError(e.data, p),
        },
      });
      yt = p;
      ytMain = p;
    };
    const tag = document.createElement('script');
    tag.src = 'https://www.youtube.com/iframe_api';
    tag.onerror = () => {
      ready = null;
      youtubeDown();
    };
    document.head.appendChild(tag);
    setTimeout(() => {
      if (yt) return;
      ready = null;
      setStatus('idle');
      youtubeDown();
    }, 15000);
  });
  return ready;
}

// ---------- overlapping crossfade (second YouTube player) ----------
// Created lazily once a track is playing and «Плавный переход» is on. It lives off-screen in
// #yt-player-2 and is only ever used for audio, so it never needs to be visible.
function ensureSpare() {
  if (ytSpare || spareReady) return;
  if (!window.YT || !window.YT.Player || !document.getElementById('yt-player-2')) return;
  spareReady = new Promise((resolve) => {
    const p = new window.YT.Player('yt-player-2', {
      width: '100%',
      height: '100%',
      playerVars: { autoplay: 0, controls: 0, disablekb: 1, fs: 0, iv_load_policy: 3, playsinline: 1, rel: 0, origin: location.origin },
      events: {
        onReady: () => {
          ytSpare = p;
          try {
            p.setVolume(0);
            p.mute();
          } catch {
            /* ignore */
          }
          resolve(p);
        },
        onStateChange: (e) => onState(e.data, p),
        onError: (e) => onError(e.data, p),
      },
    });
  });
}

// The clip/video view must play in the visible host (#yt-player). If a crossfade left the spare
// as the current player, hand control back to the main one before showing a video.
function useMainPlayer() {
  if (!ytMain || yt === ytMain) return;
  try {
    yt.stopVideo();
  } catch {
    /* ignore */
  }
  ytSpare = yt;
  yt = ytMain;
}

// Crossfade: the current track keeps playing on its own player and fades out over the time it has
// left, while the next one starts the normal way and fades in on top of it, so for a few seconds
// both are heard. Works for any pair of sources (YouTube, parser, Blink's own files).
// Returns false when there is nothing to overlap with; maybeEndFade then just fades out.
function handOff(left) {
  const s = store.get();
  if (!s.queue[s.index + 1] && s.repeat !== 'all') return false;
  if (engine === 'yt') {
    if (!ytSpare || s.videoMode === 'clip') return false;
    xf = { p: yt };
    yt = ytSpare;
    ytSpare = null;
  } else {
    xf = { el: audio };
    if (audio === plainAudio) [plainAudio, plainAlt] = [plainAlt, plainAudio];
    else [eqAudio, eqAlt] = [eqAlt, eqAudio];
    audio = xf.el === plainAlt ? plainAudio : eqAudio;
  }
  xf.from = fadeMul;
  xf.t0 = performance.now();
  xf.dur = left * 1000;
  xf.timer = setInterval(xfTick, 33);
  fadeInNext = true;
  next(true);
  return true;
}

function xfTick() {
  const cur = xf;
  if (!cur) return;
  const p = Math.min(1, (performance.now() - cur.t0) / cur.dur);
  const s = store.get();
  const base = s.muted ? 0 : s.volume || 0;
  const k = cur.from * Math.cos((p * Math.PI) / 2);
  if (cur.p) {
    try {
      cur.p.setVolume(Math.round(base * k));
    } catch {
      /* ignore */
    }
  } else setElGain(cur.el, base, k);
  if (p >= 1) cancelXfade();
}

// Silence and release the outgoing track: at the end of its fade, or when the listener does
// something else (skip, seek, pause, another track) in the middle of the overlap.
function cancelXfade() {
  if (!xf) return;
  const cur = xf;
  xf = null;
  clearInterval(cur.timer);
  if (cur.p) {
    try {
      cur.p.stopVideo();
      cur.p.mute();
    } catch {
      /* ignore */
    }
    ytSpare = cur.p;
  } else {
    cur.el.pause();
    cur.el.removeAttribute('src');
    cur.el.load();
    applyVol();
  }
}

// YouTube's player doesn't load here (blocked network, no internet to youtube.com).
// Silently switch to API parser for all tracks.
function youtubeDown() {
  if (!navigator.onLine) return; // the «Без доступа к интернету» banner already says so
  // Mark YouTube as unavailable globally so we use API parser for everything
  store.set({ youtubeBlocked: true });
  // Try to play current track via API parser (only if it was meant to be playing)
  const s = store.get();
  if (currentVideo && s.track && s.track.source !== 'blink' && s.track.source !== 'jamendo') {
    const track = s.track;
    const token = loadToken;
    // APIBlink (Yandex Music) first — best for Russian users. Fall back to MP3 parser.
    (async () => {
      const st0 = store.get();
      let result = null;
      if (st0.apiblinkEnabled !== false) result = await apiblinkFor(track).catch(() => null);
      if (!result) result = await mp3For(track).catch(() => null);
      if (token !== loadToken || !result) return;
      if (yt && yt.stopVideo) yt.stopVideo();
      if (engine === 'audio') sendAudio({ type: 'stop' });
      engine = 'audio';
      store.set({ hasClip: false, engine: 'audio' });
      currentVideo = 'parser:' + track.id;
      markVia(track, 'mp3');
      loadAt = performance.now();
      // Set initial duration (will be updated by audio.loadedmetadata)
      const duration = result.duration || track.duration || 180;
      clock.set({ time: 0, duration, at: performance.now(), playing: false });
      const st = store.get();
      send({ type: 'volume', v: st.volume, muted: st.muted });
      sendAudio({ type: 'load', url: result.url, start: 0 });
    })().catch(() => {});
  }
}

// Blink's own licensed tracks play from blinkmusic.cc in a plain audio element;
// everything else goes through the official YouTube player above.
let engine = 'yt';
// Elements: plain ones, and ones routed through Web Audio (equalizer and a gain per element for
// the crossfade). Web Audio needs CORS on the file, so the routed ones are used only where the
// response allows it (always in the desktop app, which adds the header itself; on the site only
// for Blink's own and Jamendo's files). Two of each, so the outgoing track of a crossfade keeps
// its own element while the next one plays on the other.
let plainAudio = new Audio();
let eqAudio = new Audio();
let plainAlt = new Audio();
let eqAlt = new Audio();
eqAudio.crossOrigin = eqAlt.crossOrigin = 'anonymous';
const SILENT = 'data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA=';
let audio = plainAudio;
const CORS_OK = /^https:\/\/([a-z0-9-]+\.)*(blinkmusic\.cc|jamendo\.com)(\/|:|$)/i;
// iPhone/iPad cut Web Audio off when the screen locks, so there a file goes through it only while
// the equalizer is on; otherwise it plays from a plain element and keeps going in the background.
const IOS = /iP(hone|ad|od)/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
const eqFor = (url) => hasEq() && (!IOS || eqState().on) && (bridge.corsMedia || CORS_OK.test(url || '') || /^blob:/.test(url || ''));

// A locked iPhone lets the next track start only on the element that is already playing, and
// closes the audio session (freezing the page) as soon as nothing plays. So there every track
// plays on the same element, and between tracks it loops a second of silence while the next file
// is looked up (holdSession); the real file then replaces it on that element.
let silenceUrl = '';
let holding = false;
let holdTimer = 0;
function silence() {
  if (silenceUrl) return silenceUrl;
  const n = 8000; // 1 s of 8 kHz 8-bit mono
  const b = new Uint8Array(44 + n).fill(128, 44);
  const v = new DataView(b.buffer);
  const tag = (at, s) => [...s].forEach((ch, i) => (b[at + i] = ch.charCodeAt(0)));
  tag(0, 'RIFF');
  v.setUint32(4, 36 + n, true);
  tag(8, 'WAVEfmt ');
  v.setUint32(16, 16, true);
  v.setUint16(20, 1, true);
  v.setUint16(22, 1, true);
  v.setUint32(24, 8000, true);
  v.setUint32(28, 8000, true);
  v.setUint16(32, 1, true);
  v.setUint16(34, 8, true);
  tag(36, 'data');
  v.setUint32(40, n, true);
  return (silenceUrl = URL.createObjectURL(new Blob([b], { type: 'audio/wav' })));
}
const quiet = (el) => el.getAttribute('src') === SILENT || (!!silenceUrl && el.getAttribute('src') === silenceUrl);
function holdSession() {
  if (!IOS || engine !== 'audio' || holding) return;
  holding = true;
  audio.loop = true;
  audio.src = silence();
  audio.play().catch(() => {});
  // Never loop silence for long: if nothing comes, let the phone go quiet.
  clearTimeout(holdTimer);
  holdTimer = setTimeout(() => holding && store.get().status === 'loading' && releaseSession(), 30000);
}
function releaseSession() {
  if (!holding) return;
  holding = false;
  clearTimeout(holdTimer);
  audio.loop = false;
  if (quiet(audio)) {
    audio.pause();
    audio.removeAttribute('src');
    audio.load();
  }
}

// What the source promised for each track (seconds), to tell a cut stream from a real end.
const expectedDur = new Map();
let intendedDur = 0;
let cutFor = { id: null, n: 0 };
function cutShort(el) {
  const s = store.get();
  const track = s.track;
  if (!track) return false;
  const want = expectedDur.get(track.id) || intendedDur || 0;
  const at = el.currentTime || 0;
  if (want >= 40) return at < want - 8;
  return at < 20 && cutFor.n < 1;
}
function resumeCut(el, why) {
  const track = store.get().track;
  if (!track || track.source === 'blink' || isSaved(track.id)) return false;
  if (cutFor.id !== track.id) cutFor = { id: track.id, n: 0 };
  if (cutFor.n >= 2) return false;
  cutFor.n++;
  const at = Math.max(0, (el.currentTime || 0) - 0.5);
  console.warn('stream cut, resuming (' + why + ') at', Math.round(at));
  forgetApiblink(track);
  forgetMp3(track);
  setStatus('loading');
  begin(track, at, false, true);
  return true;
}

for (const el of [plainAudio, eqAudio, plainAlt, eqAlt]) {
  el.preload = 'auto';
  const mine = () => engine === 'audio' && el === audio && !quiet(el);
  el.addEventListener('playing', () => mine() && onState(1));
  el.addEventListener('pause', () => mine() && !el.ended && el.src && onState(2));
  el.addEventListener('waiting', () => mine() && onState(3));
  el.addEventListener('ended', () => {
    if (!mine()) return;
    // A stream cut short by the network or the server ends «cleanly» at 5-10 s: carry on from
    // where it stopped instead of skipping on (or, worse, restarting the track from the top).
    if (cutShort(el) && resumeCut(el, 'ended early')) return;
    onState(0);
  });
  el.addEventListener('error', () => {
    if (!mine() || !el.getAttribute('src')) return;
    console.warn('audio error', el.error && el.error.code);
    const s = store.get();
    const track = s.track;
    const src = el.currentSrc || el.getAttribute('src') || '';
    // The stream died (expired link, dropped connection): look the file up again and carry on
    // from the same second, twice at most per track.
    if (track && resumeCut(el, 'error')) return;
    el._apiblinkRetried = false;
    setStatus('idle');
    skipAfterFailure();
  });
  // When audio metadata loads, update the duration (streams without a length report Infinity).
  el.addEventListener('loadedmetadata', () => {
    if (!mine() || !Number.isFinite(el.duration) || el.duration <= 0) return;
    const s = store.get();
    if (s.track) {
      store.set({ track: { ...s.track, duration: Math.round(el.duration) } });
      learnLen(s.track, el.duration);
    }
    clock.set({ time: el.currentTime || 0, duration: el.duration, at: performance.now(), playing: false });
  });
}

// iOS lets an element play without a tap only once it has played from a tap. The next track can
// start on another element while the phone is locked, so all four play a moment of silence on the
// first touch.
function unlockAudio() {
  for (const el of [plainAudio, eqAudio, plainAlt, eqAlt]) {
    if (el.getAttribute('src')) continue;
    el.src = SILENT;
    el.play().then(() => {
      if (el.getAttribute('src') !== SILENT) return;
      el.pause();
      el.removeAttribute('src');
      el.load();
    }).catch(() => {});
  }
}
if (IOS) window.addEventListener('touchend', unlockAudio, { once: true, capture: true });

// Licensed streams count from 30 seconds of actual listening (contract, section 1).
// Counted from the playhead, capped by real time: a hidden phone tab runs timers rarely, and a
// seek forward is not listening.
let listened = 0;
let lastPos = 0;
let lastAt = 0;
let reported = false;
let listenedId = null;

function sendAudio(c) {
  if (c.type === 'load') {
    let want = eqFor(c.url) && wire(eqAudio) ? eqAudio : plainAudio;
    // Prepared in advance by preload(): play from that element, it has already buffered.
    // (Not on iOS: there the playing element carries on, see holdSession.)
    const alt = want === eqAudio ? eqAlt : plainAlt;
    holding = false;
    clearTimeout(holdTimer);
    audio.loop = false;
    if (!IOS && alt.getAttribute('src') === c.url && !(xf && xf.el === alt)) {
      if (want === eqAudio) [eqAudio, eqAlt] = [eqAlt, eqAudio];
      else [plainAudio, plainAlt] = [plainAlt, plainAudio];
      want = alt;
    }
    if (want !== audio) {
      audio.pause();
      audio.removeAttribute('src');
      audio.load();
      want.volume = audio.volume;
      want.muted = audio.muted;
      audio = want;
    }
    if (audio === eqAudio) resumeEq();
    if (audio.getAttribute('src') !== c.url) audio.src = c.url;
    audio.currentTime = c.start || 0;
    audio.play().catch(() => setStatus('paused'));
  } else if (c.type === 'play') {
    if (audio === eqAudio) resumeEq();
    audio.play().catch(() => {});
  }
  else if (c.type === 'pause') audio.pause();
  else if (c.type === 'stop') {
    // Between tracks on iOS the silence keeps playing until the next file replaces it.
    if (holding) return;
    audio.pause();
    audio.removeAttribute('src');
    audio.load();
  } else if (c.type === 'seek') audio.currentTime = c.t;
}

// Equalizer switched on or off mid-track: move the playing file to the right element.
export function refreshEq() {
  if (engine !== 'audio' || !audio.getAttribute('src')) return;
  const url = audio.currentSrc || audio.src;
  const want = eqFor(url) && wire(eqAudio) ? eqAudio : plainAudio;
  if (want === audio) return;
  const t = audio.currentTime;
  const playing = !audio.paused;
  sendAudio({ type: 'load', url, start: t });
  if (!playing) audio.pause();
}

// Smooth transition between tracks («Плавный переход»): a 0..1 multiplier on top of the user's
// volume (a GainNode on routed elements, the element's own volume otherwise; the slider never
// moves). The next track comes in from 0 while the previous one fades out (see handOff).
// 0 s = off, so playback is untouched until the listener turns it on.
let fadeMul = 1;
let fadeTimer = 0;
let fadingOut = false;
let fadeInNext = false;
const cfSecs = () => Math.max(0, Math.min(12, Number(store.get().settings.crossfade) || 0));

function setElGain(el, base, k) {
  const g = gainOf(el);
  el.volume = Math.max(0, Math.min(100, g ? base : base * k)) / 100;
  if (g) g.gain.setTargetAtTime(k, g.context.currentTime, 0.015);
}

function applyVol() {
  const s = store.get();
  const base = s.muted ? 0 : s.volume || 0;
  for (const el of [plainAudio, eqAudio, plainAlt, eqAlt]) {
    if (xf && xf.el === el) continue; // the outgoing track is faded by xfTick
    el.muted = !!s.muted;
    setElGain(el, base, fadeMul);
  }
  if (yt && yt.setVolume) {
    yt.setVolume(Math.round(Math.max(0, Math.min(100, base * fadeMul))));
    s.muted ? yt.mute() : yt.unMute();
  }
}

// Timed by the clock, not by counting ticks, so a late timer never stretches or squeezes a fade.
// Equal-power shape: the two overlapping tracks together stay at a steady loudness.
function rampFade(target, secs) {
  clearInterval(fadeTimer);
  target = Math.max(0, Math.min(1, target));
  if (secs <= 0.05) {
    fadeMul = target;
    applyVol();
    return;
  }
  const from = fadeMul;
  const t0 = performance.now();
  fadeTimer = setInterval(() => {
    const p = Math.min(1, (performance.now() - t0) / (secs * 1000));
    fadeMul = target > from ? from + (target - from) * Math.sin((p * Math.PI) / 2) : target + (from - target) * Math.cos((p * Math.PI) / 2);
    if (p >= 1) {
      clearInterval(fadeTimer);
      fadeTimer = 0;
    }
    applyVol();
  }, 33);
}

// Near the end of a track, start the next one on top of it (unless it is on repeat-one).
function maybeEndFade(time, duration, playing) {
  if (xf || fadingOut) return;
  const cf = cfSecs();
  if (!cf || !playing || store.get().repeat === 'one') return;
  if (!duration || !Number.isFinite(duration)) return;
  const left = duration - time;
  if (left <= 0.2 || left > cf) return;
  // iOS ignores an element's volume and won't start a second one when locked: no overlap there.
  if (IOS && engine === 'audio') return;
  if (handOff(left)) return;
  // Nothing to overlap with (clip view, no spare player yet): fade out, and the next one in.
  fadingOut = true;
  fadeInNext = true;
  rampFade(0, left);
}

function send(c) {
  if (c.type === 'volume') return applyVol();
  if (engine === 'audio') {
    sendAudio(c);
    return;
  }
  if (!yt || !yt.getPlayerState) return;
  if (c.type === 'load') yt.loadVideoById({ videoId: c.id, startSeconds: c.start || 0 });
  else if (c.type === 'play') yt.playVideo();
  else if (c.type === 'pause') yt.pauseVideo();
  else if (c.type === 'stop') yt.stopVideo();
  else if (c.type === 'seek') yt.seekTo(c.t, true);
}

setInterval(() => {
  if (!currentVideo) return;
  const s = store.get();
  const playing = s.status === 'playing';
  if (engine === 'audio') {
    // Streams without a length report Infinity or NaN: fall back to the track's own duration.
    const d = Number.isFinite(audio.duration) && audio.duration > 0 ? audio.duration : Number(s.track && s.track.duration) || 0;
    clock.set({ time: audio.currentTime || 0, duration: d, at: performance.now(), playing });
    updatePosition(audio.currentTime || 0, d);
    maybeEndFade(audio.currentTime || 0, d, playing);
    if (playing) {
      stallSince = 0;
      midStall = 0;
    } else if (s.status === 'buffering' && audio.played.length > 0 && audio.getAttribute('src') && !quiet(audio)) {
      // Froze in the middle of a track (dead connection that never errors): reopen it right here.
      midStall = midStall || performance.now();
      if (performance.now() - midStall > 12000) {
        midStall = 0;
        resumeCut(audio, 'stalled');
      }
    } else if ((s.status === 'loading' || (s.status === 'buffering' && audio.played.length === 0)) && audio.getAttribute('src') && !quiet(audio)) {
      // Stuck loading an audio file: give up after 8 seconds instead of spinning forever.
      stallSince = stallSince || performance.now();
      if (performance.now() - stallSince > 8000) {
        stallSince = 0;
        console.warn('audio stalled', audio.currentSrc);
        sendAudio({ type: 'stop' });
        setStatus('idle');
        const s = store.get();
        const src = audio.currentSrc || '';
        // Retry APIBlink with a fresh URL if stream stalled
        if (s.track && src.includes('/api/apiblink/stream/')) {
          forgetApiblink(s.track);
          forgetMp3(s.track);
          begin(s.track, 0);
        } else {
          skipAfterFailure();
        }
      }
    }
    const pos = audio.currentTime || 0;
    if (playing && s.track && s.track.lic) {
      if (listenedId !== s.track.lic) (listenedId = s.track.lic), (listened = 0), (reported = false);
      listened += Math.max(0, Math.min(pos - lastPos, (performance.now() - lastAt) / 1000));
      if (!reported && listened >= 30) {
        reported = true;
        reportStream(s.track.lic, Math.round(listened));
      }
    }
    lastPos = pos;
    lastAt = performance.now();
    return;
  }
  if (!yt || !yt.getCurrentTime) return;
  const ytDur = yt.getDuration() || Number(s.track && s.track.duration) || 0;
  if (s.track && !s.track.duration && yt.getDuration() > 0) learnLen(s.track, yt.getDuration());
  clock.set({ time: yt.getCurrentTime() || 0, duration: ytDur, at: performance.now(), playing });
  updatePosition(yt.getCurrentTime() || 0, ytDur);
  maybeEndFade(yt.getCurrentTime() || 0, ytDur, playing);
}, 250);
let stallSince = 0;
let midStall = 0;

function setStatus(status) {
  store.set({ status });
  report();
  // While silence bridges two tracks on iOS the lock screen keeps showing «playing».
  if ('mediaSession' in navigator) navigator.mediaSession.playbackState = status === 'playing' || (holding && status === 'loading') ? 'playing' : 'paused';
}

// What plays here, for your other devices (synced through the account).
let lastNow = { id: null, playing: null, at: 0 };
function shareNow(s, t, c) {
  if (!s.user || !t) return;
  const playing = s.status === 'playing';
  const now = Date.now();
  if (lastNow.id === t.id && lastNow.playing === playing && now - lastNow.at < 20000) return;
  lastNow = { id: t.id, playing, at: now };
  store.set({ nowPlaying: { track: t, time: c.time, at: now, playing, device: undefined, deviceName: DEVICE_NAME } });
}

// Window title, taskbar buttons and the Discord status follow this.
function report() {
  const s = store.get();
  const t = s.track;
  const c = clock.get();
  shareNow(s, t, c);
  bridge.playback({
    id: t && t.id,
    playing: s.status === 'playing',
    title: t && t.title,
    artist: t && t.artist,
    album: t && t.album,
    artwork: t && t.artwork,
    art: t && bigArt(t.artwork),
    time: c.time,
    duration: c.duration || (t && t.duration) || 0,
  });
}

// Lookups of where a track plays from are remembered for a while, so a track prepared in advance
// starts without asking the network again. Failed or empty lookups are not kept.
const memo = new Map();
function remember(key, ttlMin, get) {
  const m = memo.get(key);
  if (m && Date.now() - m.at < ttlMin * 60000) return m.p;
  const p = get().then(
    (r) => (r || memo.delete(key), r),
    (e) => (memo.delete(key), Promise.reject(e)),
  );
  memo.set(key, { p, at: Date.now() });
  if (memo.size > 40) memo.delete(memo.keys().next().value);
  return p;
}
const mp3For = (track) => remember('mp3:' + track.id, 20, () => findMp3(track.title, track.artist));
const apiblinkFor = (track) =>
  remember('apiblink:' + track.id, 20, () =>
    findApiblink(track.title, track.artist).then((r) => {
      if (r && r.duration) expectedDur.set(track.id, r.duration);
      return r;
    }),
  );
// Force a fresh lookup — call this when the stream URL has expired (404).
const forgetApiblink = (track) => { memo.delete('apiblink:' + track.id); };
const forgetMp3 = (track) => { memo.delete('mp3:' + track.id); };
// The track's looping video («видеошот»), when the source has one: the direct MP4 link, or ''.
const shots = new Map();
export function shotFor(track) {
  if (!track || ['blink', 'jamendo', 'local', 'parser'].includes(track.source)) return Promise.resolve('');
  const hit = shots.get(track.id);
  if (hit && (hit.url || Date.now() - hit.at < 5 * 60000)) return Promise.resolve(hit.url);
  return (async () => {
    let url = '';
    try {
      const r = await apiblinkFor(track);
      if (r && r.video) {
        const res = await fetch(r.video, { signal: AbortSignal.timeout(8000) });
        if (res.status === 200 && (res.headers.get('content-type') || '').includes('json')) {
          const d = await res.json();
          if (d && /^https:\/\//.test(d.videoUrl || '')) url = d.videoUrl;
        }
      }
    } catch {
      /* no clip */
    }
    shots.set(track.id, { url, at: Date.now() });
    if (shots.size > 80) shots.delete(shots.keys().next().value);
    return url;
  })();
}

const licUrl = (lic) => remember('lic:' + lic, 5, () => playUrl(lic));

// Resolve a YouTube video ID to a direct audio URL via Cobalt (our server-side resolver).
// Much faster than the IFrame player: no JS player init, no YouTube bot checks, no API quota.
const COBALT_BASE = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '');
async function cobaltAudio(ytId) {
  const r = await fetch(`${COBALT_BASE}/api/cobalt/resolve?ytId=${encodeURIComponent(ytId)}`, { signal: AbortSignal.timeout(16000) });
  if (!r.ok) throw new Error('cobalt ' + r.status);
  const d = await r.json();
  if (!d.url) throw new Error('no url');
  return d.url;
}
const cobaltFor = (ytId) => remember('cobalt:' + ytId, 9, () => cobaltAudio(ytId));

// Let a file start buffering on the idle element it will play from (picked up in sendAudio).
// On iOS only the link is found in advance (warm); the file buffers on the playing element.
function preload(url) {
  if (!url || IOS) return;
  const el = eqFor(url) && wire(eqAlt) ? eqAlt : plainAlt;
  if ((xf && xf.el === el) || el.getAttribute('src') === url) return;
  el.src = url;
}

// Get a track ready to start at once: find its file (parser first), and buffer it.
async function warm(track) {
  if (!track || isSaved(track.id)) return;
  const s = store.get();
  if (track.source === 'jamendo') return preload(track.stream);
  if (track.source === 'parser' || track.source === 'local') return preload(track._parserUrl);
  if (track.source === 'blink') return preload(await licUrl(track.lic));
  // APIBlink-first: Yandex Music has the best catalog for Russian users.
  // Fall back to the MP3 parser, then Cobalt/YouTube.
  if (s.apiblinkEnabled !== false) {
    const r = await apiblinkFor(track).catch(() => null);
    if (r) { preload(r.url); return; }
  }
  // APIBlink didn't find it — try the MP3 parser.
  if (s.parserEnabled === true) {
    const r = await mp3For(track).catch(() => null);
    if (r) preload(r.url);
    if (r) return; // parser found it — no need to warm cobalt
  }
  // Parser didn't find it — warm Cobalt for the YouTube fallback.
  if (s.youtubeEnabled !== false) {
    const v = await videosFor(track).catch(() => null);
    if (v && v.audio && v.audio.length) cobaltFor(v.audio[0]).catch(() => {});
  }
}

// While a track plays, prepare the next one, so it starts right away.
let prefetchTimer = 0;
function prefetchNext() {
  clearTimeout(prefetchTimer);
  prefetchTimer = setTimeout(() => {
    const s = store.get();
    warm(s.queue[s.index + 1]).catch(() => {});
  }, 1000);
}

function onState(state, who) {
  // Ignore events from the idle/incoming YouTube player; the crossfade drives it itself.
  // (Audio-element events pass no `who` and always count as the current track.)
  if (who && who !== yt) return;
  // -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued
  if (state === 1) {
    failStreak = 0;
    setStatus('playing');
    // YouTube overwrites the lock-screen info on play — restore Blink's card over it.
    setTimeout(reassertSession, 400);
    setTimeout(reassertSession, 1500);
    if (cfSecs() > 0) ensureSpare();
    if (cfSecs() > 0 && fadeMul < 1 && !fadingOut) rampFade(1, cfSecs());
    else if (cfSecs() === 0 && fadeMul !== 1) {
      fadeMul = 1;
      applyVol();
    }
    prefetchNext();
    // Clips should look like clips: no auto-generated subtitles.
    try {
      yt.unloadModule('captions');
    } catch {
      /* not loaded */
    }
  }
  else if (state === 2) setStatus('paused');
  else if (state === 3) {
    if (store.get().status !== 'loading') setStatus('buffering');
  } else if (state === 0) {
    // «Ended» from a player that was already stopped for a newly chosen track must not skip it.
    if (who && !currentVideo) return;
    if (performance.now() - loadAt > 2000) onEnded();
  }
}

function onError(code, who) {
  if (who && who !== yt) {
    // The outgoing crossfade player failed: just let it go.
    if (xf && who === xf.p) cancelXfade();
    return;
  }
  // 100 removed, 101/150 the owner doesn't allow playback in other apps
  console.warn('youtube error', code, currentVideo);
  if (!currentVideo) return; // late error of a player that was already stopped for another track
  candidateIdx++;
  if (candidateIdx < candidates.length) {
    loadVideo(candidates[candidateIdx], pendingStart);
    return;
  }
  const s = store.get();
  if (s.videoMode === 'clip') {
    store.set({ videoMode: 'audio', hasClip: false });
    toast('Клип недоступен, играю трек');
    startAudio(s.track, clock.get().time);
    return;
  }
  // All YouTube candidates exhausted: try api parser before giving up.
  if (s.track && s.track.source !== 'blink' && s.track.source !== 'jamendo') {
    const track = s.track;
    const start = clock.get().time;
    const token = loadToken;
    mp3For(track).then((result) => {
      if (token !== loadToken) return;
      if (result) {
        if (yt && yt.stopVideo) yt.stopVideo();
        engine = 'audio';
        store.set({ hasClip: false, engine: 'audio' });
        currentVideo = 'parser:' + track.id;
        markVia(track, 'mp3');
        loadAt = performance.now();
        // Set initial duration (will be updated by audio.loadedmetadata)
        const duration = result.duration || track.duration || 180;
        clock.set({ time: start, duration, at: performance.now(), playing: false });
        const st = store.get();
        send({ type: 'volume', v: st.volume, muted: st.muted });
        sendAudio({ type: 'load', url: result.url, start });
      } else {
        // Skip silently
        skipLater(token);
      }
    }).catch(() => skipLater(token));
    return;
  }
  skipAfterFailure();
}

async function loadVideo(id, start = 0) {
  releaseSession();
  currentVideo = id;
  if (store.get().track) markVia(store.get().track, 'yt');
  pendingStart = start;
  loadAt = performance.now();
  await loadApi();
  const s = store.get();
  send({ type: 'volume', v: s.volume, muted: s.muted });
  send({ type: 'load', id, start });
  // Browsers may block autoplay with sound: then wait for the play button.
  const token = loadAt;
  // A video that never starts (no error from YouTube, just endless loading): try the next
  // candidate, and when there is none, move on like any other failed track.
  setTimeout(() => {
    if (token !== loadAt || engine !== 'yt' || currentVideo !== id) return;
    const st = store.get().status;
    if (st !== 'loading' && st !== 'buffering') return;
    if (yt && yt.getCurrentTime && yt.getCurrentTime() > start + 0.5) return;
    console.warn('youtube stalled', id);
    candidateIdx++;
    if (candidateIdx < candidates.length) return loadVideo(candidates[candidateIdx], start);
    if (yt && yt.stopVideo) yt.stopVideo();
    setStatus('idle');
    skipAfterFailure();
  }, 15000);
  if (bridge.isWeb) setTimeout(() => {
    if (token !== loadAt || !yt || !yt.getPlayerState) return;
    const st = yt.getPlayerState();
    if ((st === -1 || st === 5) && store.get().status === 'loading') setStatus('paused');
  }, 3500);
}

// Upscale Apple/Deezer covers so the lock screen gets a crisp image.
function bigArt(url) {
  if (!url) return '';
  // iTunes: ...100x100bb.jpg → ...1000x1000bb.jpg
  if (/\/\d+x\d+bb\.jpg$/.test(url)) return url.replace(/\/\d+x\d+bb\.jpg$/, '/1000x1000bb.jpg');
  // Yandex: .../100x100 → .../1000x1000
  if (/\/\d+x\d+$/.test(url)) return url.replace(/\/\d+x\d+$/, '/1000x1000');
  // SoundCloud: ...-large.jpg → ...-t500x500.jpg
  return scaleSc(url, 500);
}

// Lock-screen / headphone buttons. iOS shows «±10 s» instead of previous/next whenever the page has no
// previoustrack/nexttrack handlers (or has seek handlers), and the YouTube iframe can wipe ours, so this is
// re-applied every time the card is refreshed.
function bindSession() {
  if (!('mediaSession' in navigator)) return;
  const ms = navigator.mediaSession;
  const set = (a, h) => { try { ms.setActionHandler(a, h); } catch {} };
  set('play', () => toggle());
  set('pause', () => toggle());
  set('nexttrack', () => next());
  set('previoustrack', () => prev());
  set('seekto', (d) => seek(d.seekTime));
  set('seekbackward', null);
  set('seekforward', null);
}

function mediaSession(track) {
  if (!('mediaSession' in navigator) || !track) return;
  bindSession();
  // No cover: show Blink's icon, so the lock-screen card is always Blink's own and opens Blink.
  const art = bigArt(track.artwork) || (/^https?:$/.test(location.protocol) ? location.origin + '/icon.png' : '');
  navigator.mediaSession.metadata = new window.MediaMetadata({
    title: track.title || '',
    artist: track.artist || '',
    album: track.album || '',
    // The phone's lock screen shows this card (cover + title), not the YouTube video.
    artwork: art ? ['128', '192', '256', '384', '512'].map((sz) => ({ src: art, sizes: `${sz}x${sz}`, type: 'image/jpeg' })) : [],
  });
}

// The YouTube player sets its own lock-screen info when it starts; put Blink's card back on top.
function reassertSession() {
  const t = store.get().track;
  bindSession();
  if (t) mediaSession(t);
}

function updatePosition(time, duration) {
  if (!('mediaSession' in navigator) || !navigator.mediaSession.setPositionState) return;
  if (!Number.isFinite(duration) || duration <= 0 || !Number.isFinite(time)) return;
  try {
    navigator.mediaSession.setPositionState({ duration, position: Math.min(Math.max(0, time), duration), playbackRate: 1 });
  } catch {}
}

async function videosFor(track) {
  const s = store.get();
  const hit = s.ytCache[track.id];
  // v2: entries found before the duration check may point at hour-long videos
  if (hit && hit.v === 2 && hit.audio && hit.audio.length && ytFresh(hit)) return hit;
  // Your own key (Settings) searches directly; otherwise Blink's server does it.
  // A short burst limit (rateLimitExceeded) passes in seconds: wait and ask again.
  let res;
  for (let attempt = 0; ; attempt++) {
    try {
      res = ytKey(s) ? await resolveVideos(track, ytKey(s)) : await resolveRemote(track);
      break;
    } catch (e) {
      if (e.reason !== 'rateLimitExceeded' || attempt >= 2) throw e;
      await new Promise((r) => setTimeout(r, 1500 * (attempt + 1) + Math.random() * 800));
    }
  }
  const cache = { ...store.get().ytCache, [track.id]: { ...res, v: 2, at: Date.now() } };
  const keys = Object.keys(cache);
  if (keys.length > 3000) for (const k of keys.slice(0, keys.length - 3000)) delete cache[k];
  store.set({ ytCache: cache });
  return res;
}

// Some sources give no length (list rows then showed 0:00): keep the real one once it is known.
function learnLen(track, sec) {
  const n = Math.round(sec);
  const lens = store.get().lens || {};
  if (!n || lens[track.id] === n) return;
  const next = { ...lens, [track.id]: n };
  const keys = Object.keys(next);
  if (keys.length > 3000) for (const k of keys.slice(0, keys.length - 3000)) delete next[k];
  store.set({ lens: next });
}

// Remember how each track actually played, for the source badge on track rows.
function markVia(track, kind) {
  const via = store.get().via || {};
  if (via[track.id] === kind) return;
  const next = { ...via, [track.id]: kind };
  const keys = Object.keys(next);
  if (keys.length > 3000) for (const k of keys.slice(0, keys.length - 3000)) delete next[k];
  store.set({ via: next });
}

async function startAudio(track, start = 0) {
  const token = ++loadToken;
  // Saved with Blink+: play the file kept on the device, no network needed.
  const local = isSaved(track.id) && (await savedUrl(track.id));
  if (token !== loadToken) return;
  if (local) {
    if (engine === 'audio') sendAudio({ type: 'stop' });
    if (yt && yt.stopVideo) yt.stopVideo();
    engine = 'audio';
    store.set({ hasClip: false, engine: 'audio' });
    currentVideo = 'saved:' + track.id;
    loadAt = performance.now();
    clock.set({ time: start, duration: track.duration || 180, at: performance.now(), playing: false });
    const s = store.get();
    send({ type: 'volume', v: s.volume, muted: s.muted });
    sendAudio({ type: 'load', url: local, start });
    return;
  }
  if (track.source === 'blink') return startLicensed(track, start, token);
  if (track.source === 'jamendo') return startStream(track, start, token);
  // Tracks from the search MP3 section carry a ready-to-play URL
  if ((track.source === 'parser' || track.source === 'local') && track._parserUrl) {
    if (engine === 'audio') sendAudio({ type: 'stop' });
    if (yt && yt.stopVideo) yt.stopVideo();
    engine = 'audio';
    store.set({ hasClip: false, engine: 'audio' });
    currentVideo = 'parser:' + track.id;
    markVia(track, 'mp3');
    loadAt = performance.now();
    const duration = track.duration || 180;
    clock.set({ time: start, duration, at: performance.now(), playing: false });
    const s = store.get();
    send({ type: 'volume', v: s.volume, muted: s.muted });
    sendAudio({ type: 'load', url: track._parserUrl, start });
    return;
  }
  
  const s = store.get();
  const cached = s.ytCache[track.id];
  const hasCachedVideo = cached && cached.v === 2 && cached.audio && cached.audio.length && ytFresh(cached);

  // Admin flags: which sources are currently enabled.
  const ytOk = s.youtubeEnabled !== false;
  const parserOk = s.parserEnabled === true;
  const apiblinkOk = s.apiblinkEnabled !== false;

  // Helper: play via APIBlink (Yandex Music).
  async function playViaApiblink(fallbackToParser = true) {
    if (!apiblinkOk) return fallbackToParser ? playViaParser() : (setStatus('idle'), skipLater(token));
    if (engine === 'audio') sendAudio({ type: 'stop' });
    engine = 'audio';
    store.set({ hasClip: false, engine: 'audio' });
    const result = await apiblinkFor(track).catch(() => null);
    if (token !== loadToken) return;
    if (result) {
      if (yt && yt.stopVideo) yt.stopVideo();
      currentVideo = 'apiblink:' + track.id;
      markVia(track, 'mp3');
      loadAt = performance.now();
      const duration = result.duration || track.duration || 180;
      clock.set({ time: start, duration, at: performance.now(), playing: false });
      const st = store.get();
      send({ type: 'volume', v: st.volume, muted: st.muted });
      sendAudio({ type: 'load', url: result.url, start });
    } else if (fallbackToParser) {
      return playViaParser();
    } else {
      setStatus('idle');
      skipLater(token);
    }
  }

  // Helper: play via API parser (avoids code repetition below).
  async function playViaParser() {
    if (!parserOk) { setStatus('idle'); skipLater(token); return; }
    if (engine === 'audio') sendAudio({ type: 'stop' });
    engine = 'audio';
    store.set({ hasClip: false, engine: 'audio' });
    const result = await mp3For(track).catch(() => null);
    if (token !== loadToken) return;
    if (result) {
      if (yt && yt.stopVideo) yt.stopVideo();
      currentVideo = 'parser:' + track.id;
      markVia(track, 'mp3');
      loadAt = performance.now();
      const duration = result.duration || track.duration || 180;
      clock.set({ time: start, duration, at: performance.now(), playing: false });
      const st = store.get();
      send({ type: 'volume', v: st.volume, muted: st.muted });
      sendAudio({ type: 'load', url: result.url, start });
    } else {
      setStatus('idle');
      skipLater(token);
    }
  }

  // If YouTube is disabled by admin — go straight to APIBlink (then parser fallback).
  if (!ytOk) return playViaApiblink(true);

  // If YouTube is blocked at runtime or limit hit:
  // - if track is already cached in ytCache → play from YouTube cache (guaranteed correct track)
  // - if not cached → use API parser
  if (s.youtubeBlocked || limitActive()) {
    if (hasCachedVideo) {
      if (engine === 'audio') sendAudio({ type: 'stop' });
      engine = 'yt';
      store.set({ engine: 'yt', hasClip: !!cached.clip });
      candidates = cached.audio;
      candidateIdx = 0;
      loadVideo(cached.audio[0], start);
      return;
    }
    return playViaApiblink(true); // APIBlink → parser fallback
  }

  // --- Multi-source strategy ---
  // Race APIBlink (Yandex), parser and Cobalt in parallel — use whichever answers first.
  // APIBlink is best for Russian catalog. Parser is accurate. Cobalt is fast for YouTube.
  if (apiblinkOk || parserOk || ytOk) {
    const apiblinkPromise = apiblinkOk ? apiblinkFor(track).catch(() => null) : Promise.resolve(null);
    const parserPromise = parserOk ? mp3For(track).catch(() => null) : Promise.resolve(null);
    const cobaltPromise = ytOk ? (async () => {
      const v = await videosFor(track).catch(() => null);
      if (!v || !v.audio.length) return null;
      store.set({ hasClip: !!v.clip });
      const url = await cobaltFor(v.audio[0]).catch(() => null);
      return url ? { url, ytId: v.audio[0], clip: v.clip } : null;
    })() : Promise.resolve(null);

    // Wait for the first non-null result from any source.
    const result = await Promise.race([
      apiblinkPromise.then((r) => r ? { type: 'apiblink', r } : new Promise(() => {})),
      parserPromise.then((r) => r ? { type: 'parser', r } : new Promise(() => {})),
      cobaltPromise.then((r) => r ? { type: 'cobalt', r } : new Promise(() => {})),
      // Timeout: if all take too long, wait for whichever finishes first.
      Promise.all([apiblinkPromise, parserPromise, cobaltPromise]).then(([a, p, c]) => ({ type: 'both', a, p, c })),
    ]);

    if (token !== loadToken) return;

    if (result.type === 'apiblink' && result.r) {
      if (engine === 'audio') sendAudio({ type: 'stop' });
      if (yt && yt.stopVideo) yt.stopVideo();
      engine = 'audio';
      store.set({ hasClip: false, engine: 'audio' });
      currentVideo = 'apiblink:' + track.id;
      markVia(track, 'mp3');
      loadAt = performance.now();
      const duration = result.r.duration || track.duration || 180;
      clock.set({ time: start, duration, at: performance.now(), playing: false });
      const st = store.get();
      send({ type: 'volume', v: st.volume, muted: st.muted });
      sendAudio({ type: 'load', url: result.r.url, start });
      return;
    }

    if (result.type === 'parser' && result.r) {
      if (engine === 'audio') sendAudio({ type: 'stop' });
      if (yt && yt.stopVideo) yt.stopVideo();
      engine = 'audio';
      store.set({ hasClip: false, engine: 'audio' });
      currentVideo = 'parser:' + track.id;
      markVia(track, 'mp3');
      loadAt = performance.now();
      const duration = result.r.duration || track.duration || 180;
      clock.set({ time: start, duration, at: performance.now(), playing: false });
      const st = store.get();
      send({ type: 'volume', v: st.volume, muted: st.muted });
      sendAudio({ type: 'load', url: result.r.url, start });
      return;
    }

    if (result.type === 'cobalt' && result.r) {
      if (engine === 'audio') sendAudio({ type: 'stop' });
      if (yt && yt.stopVideo) yt.stopVideo();
      engine = 'audio';
      store.set({ hasClip: !!result.r.clip, engine: 'audio' });
      currentVideo = 'cobalt:' + result.r.ytId;
      markVia(track, 'yt');
      loadAt = performance.now();
      const duration = track.duration || 180;
      clock.set({ time: start, duration, at: performance.now(), playing: false });
      const st = store.get();
      send({ type: 'volume', v: st.volume, muted: st.muted });
      sendAudio({ type: 'load', url: result.r.url, start });
      return;
    }

    if (result.type === 'both') {
      const { a, p, c } = result;
      // Prefer APIBlink > parser > cobalt
      const audioResult = a || p;
      if (audioResult) {
        if (engine === 'audio') sendAudio({ type: 'stop' });
        if (yt && yt.stopVideo) yt.stopVideo();
        engine = 'audio';
        store.set({ hasClip: false, engine: 'audio' });
        currentVideo = (a ? 'apiblink:' : 'parser:') + track.id;
        markVia(track, 'mp3');
        loadAt = performance.now();
        const duration = audioResult.duration || track.duration || 180;
        clock.set({ time: start, duration, at: performance.now(), playing: false });
        const st = store.get();
        send({ type: 'volume', v: st.volume, muted: st.muted });
        sendAudio({ type: 'load', url: audioResult.url, start });
        return;
      }
      if (c) {
        if (engine === 'audio') sendAudio({ type: 'stop' });
        if (yt && yt.stopVideo) yt.stopVideo();
        engine = 'audio';
        store.set({ hasClip: !!c.clip, engine: 'audio' });
        currentVideo = 'cobalt:' + c.ytId;
        markVia(track, 'yt');
        loadAt = performance.now();
        const duration = track.duration || 180;
        clock.set({ time: start, duration, at: performance.now(), playing: false });
        const st = store.get();
        send({ type: 'volume', v: st.volume, muted: st.muted });
        sendAudio({ type: 'load', url: c.url, start });
        return;
      }
    }
  }

  // Both parser and Cobalt failed — fall back to YouTube IFrame player.
  if (ytOk) {
    const cached2 = store.get().ytCache[track.id];
    const hasCached2 = cached2 && cached2.v === 2 && cached2.audio && cached2.audio.length && ytFresh(cached2);
    if (hasCached2) {
      if (engine === 'audio') sendAudio({ type: 'stop' });
      engine = 'yt';
      store.set({ engine: 'yt', hasClip: !!cached2.clip });
      candidates = cached2.audio;
      candidateIdx = 0;
      loadVideo(candidates[0], start);
      return;
    }
  }
  // Last resort: IFrame YouTube player directly.
  setStatus('idle');
  skipAfterFailure();
}

// Jamendo tracks play from Jamendo's own stream URL (never stored by Blink).
function startStream(track, start, token) {
  if (token !== loadToken) return;
  if (!track.stream) return skipAfterFailure();
  if (yt && yt.stopVideo) yt.stopVideo();
  engine = 'audio';
  store.set({ hasClip: false, engine: 'audio' });
  currentVideo = track.id;
  loadAt = performance.now();
  const s = store.get();
  send({ type: 'volume', v: s.volume, muted: s.muted });
  sendAudio({ type: 'load', url: track.stream, start });
}

async function startLicensed(track, start, token) {
  try {
    const url = await licUrl(track.lic);
    if (token !== loadToken) return;
    if (yt && yt.stopVideo) yt.stopVideo();
    engine = 'audio';
    store.set({ hasClip: false, engine: 'audio' });
    currentVideo = 'lic:' + track.lic;
    loadAt = performance.now();
    const s = store.get();
    send({ type: 'volume', v: s.volume, muted: s.muted });
    sendAudio({ type: 'load', url, start });
  } catch (e) {
    if (token !== loadToken) return;
    setStatus('idle');
    if (e.status === 401) requireAccount('play');
    else skipAfterFailure();
  }
}

const LIMIT = ['quotaExceeded', 'dailyLimitExceeded', 'rateLimitExceeded'];
const DAILY = ['quotaExceeded', 'dailyLimitExceeded'];
export const limitActive = () => Date.now() - (store.get().limitHit || 0) < 1000 * 60 * 60 * 3;

// One failed track moves on; several in a row stop, so errors never cascade.
let failStreak = 0;
// Moves on after a failure, but only if the listener hasn't already picked something else in
// the meantime (otherwise a stale timer skips the track they just chose).
function skipLater(token = loadToken) {
  const id = store.get().track && store.get().track.id;
  setTimeout(() => {
    if (token !== loadToken) return;
    const t = store.get().track;
    if ((t && t.id) !== id) return;
    next(true);
  }, 500);
}

function skipAfterFailure() {
  failStreak++;
  const cur = store.get().track;
  if (cur && cur.source !== 'local') markDead(cur.id);
  if (failStreak >= 3) {
    failStreak = 0;
    releaseSession();
    // Several YouTube tracks in a row didn't play: offer the licensed ones that don't depend on it.
    if (store.get().track && store.get().track.source !== 'blink') youtubeDown();
    else toast('Не удалось получить несколько треков подряд. Попробуйте другой трек', 'error');
    return;
  }
  // Skip silently
  skipLater();
}

// When new tracks can't be looked up today, jump to the next one that's already known.
async function skipToPlayable(message) {
  const s = store.get();
  const rest = s.queue.slice(s.index + 1);
  const local = new Set(Object.keys(s.ytCache));
  const known = await playableIds(rest.filter((t) => !local.has(t.id)).map((t) => t.id)).catch(() => new Set());
  const at = rest.findIndex((t) => local.has(t.id) || known.has(String(t.id)));
  if (at === -1) {
    toast('Лимит новых треков на сегодня исчерпан. Уже знакомые треки и «Любимое» играют, новые — завтра', 'error');
    return;
  }
  toast(message);
  playIndex(s.index + 1 + at);
}

// Audio files opened with Blink from the computer ({ url, name } from the desktop app).
export function playFiles(files) {
  const tracks = files.map((f, i) => {
    const base = f.name.replace(/\.[^.]+$/, '');
    const dash = base.indexOf(' - ');
    return {
      id: 'local:' + f.url,
      title: dash > 0 ? base.slice(dash + 3) : base,
      artist: dash > 0 ? base.slice(0, dash) : 'Файл с компьютера',
      artistId: null,
      album: '',
      albumId: null,
      artwork: '',
      duration: 0,
      source: 'local',
      _parserUrl: f.url,
    };
  });
  if (tracks.length) playTrack(tracks[0], tracks, 0);
}

// Where a queue was started, for the «Играет: …» caption on the phone home screen.
function sourceLabel(s) {
  const v = s.view || {};
  if (v.name === 'playlist') {
    if (v.params.id === 'likes') return 'Мне нравится';
    const p = (s.playlists || []).find((x) => x.id === v.params.id);
    return p ? p.name : 'Плейлист';
  }
  if (v.name === 'library') return 'Моё';
  if (v.name === 'album') return 'Альбом';
  if (v.name === 'artist' || v.name === 'bartist') return 'Артист';
  if (v.name === 'editorial') return 'Подборка';
  if (v.name === 'search') return 'Поиск';
  if (v.name === 'charts' || v.name === 'home') return 'Чарт';
  return '';
}

export function playTrack(track, list, index, start = 0) {
  const s = store.get();
  if (!requireAccount('play')) return;
  const queue = list && list.length ? list : [track];
  const i = list ? (index !== undefined ? index : queue.findIndex((t) => t.id === track.id)) : 0;
  store.set({ queue, index: i, track, videoMode: 'audio', hasClip: false, wave: false, flow: false, pendingResume: false, remoteFrom: null, queueFrom: sourceLabel(s) });
  begin(track, start);
}

function begin(track, start = 0, fade = false, resume = false) {
  if (!fade) cancelXfade();
  if (!resume) cutFor = { id: track.id, n: 0 };
  intendedDur = track.duration || 0;
  // The stall watchdogs time one track: a fresh one starts from zero, otherwise a quick
  // switch inherits the previous track's «stuck» time and gets skipped as failed.
  stallSince = 0;
  midStall = 0;
  // The previous track must go silent right away, even if the new one fails to load.
  holdSession();
  if (currentVideo) send({ type: 'stop' });
  if (engine === 'audio') sendAudio({ type: 'stop' });
  currentVideo = null;
  listenedId = null;
  clock.set({ time: start, duration: track.duration || 0, at: performance.now(), playing: false });
  setStatus('loading');
  fadingOut = false;
  clearInterval(fadeTimer);
  fadeMul = fade && cfSecs() > 0 ? 0 : 1;
  applyVol();
  mediaSession(track);
  // Files from the computer only live until Blink closes: keep them out of history and stats.
  if (track.source !== 'local' && !resume) {
    pushRecent(track);
    recordPlay(track);
  }
  // Warm the current track immediately so mp3For is cached before startAudio needs it.
  warm(track).catch(() => {});
  startAudio(track, start);
}

function playIndex(i, fade = false) {
  const s = store.get();
  const track = s.queue[i];
  if (!track) return;
  store.set({ index: i, track, videoMode: 'audio', hasClip: false, pendingResume: false, remoteFrom: null });
  begin(track, 0, fade);
  topUp();
}

// «Вспышка» (and the stream after a queue) gathers the next tracks while 4 are still ahead, so
// «next» always has something ready instead of waiting on the network at the end.
let toppingUp = false;
function topUp() {
  const s = store.get();
  if (toppingUp || !(s.wave || s.flow) || s.repeat === 'all' || s.queue.length - 1 - s.index > 4) return;
  toppingUp = true;
  wave(s.track)
    .then((more) => {
      const now = store.get();
      if (!(now.wave || now.flow)) return;
      const have = new Set(now.queue.map((t) => t.id));
      const add = more.filter((t) => t && !have.has(t.id));
      if (add.length) store.set({ queue: [...now.queue, ...add] });
    })
    .catch(() => {})
    .finally(() => (toppingUp = false));
}

// What the listener does by hand (not the player on its own), for «Слушать вместе».
export const userActions = new Set();
const acted = (a) => userActions.forEach((f) => f(a));

export function toggle() {
  const s = store.get();
  if (!s.track || !requireAccount('play')) return;
  cancelXfade();
  if (!currentVideo || s.pendingResume) {
    const at = s.resumeAt || 0;
    store.set({ resumeAt: 0, remoteFrom: null, pendingResume: false });
    begin(s.track, at);
    acted({ playing: true });
    return;
  }
  if (s.status === 'playing' || s.status === 'buffering') {
    send({ type: 'pause' });
    acted({ playing: false });
  } else {
    send({ type: 'play' });
    acted({ playing: true });
  }
}

// The cross on the home page closes the player: whatever plays stops and the queue is dropped, so the
// home page goes back to rest. Your other devices see it as a pause at this spot.
export function stopPlayback() {
  const s = store.get();
  if (s.user && s.track) {
    lastNow = { id: s.track.id, playing: false, at: Date.now() };
    store.set({ nowPlaying: { track: s.track, time: clock.get().time, at: Date.now(), playing: false, device: undefined, deviceName: DEVICE_NAME } });
  }
  loadToken++; // anything still loading must not start by itself
  cancelXfade();
  clearInterval(fadeTimer);
  fadingOut = false;
  fadeMul = 1;
  releaseSession();
  if (currentVideo) send({ type: 'stop' });
  if (engine === 'audio') sendAudio({ type: 'stop' });
  currentVideo = null;
  listenedId = null;
  clock.set({ time: 0, duration: 0, at: performance.now(), playing: false });
  store.set({ track: null, queue: [], index: -1, wave: false, flow: false, waveLoading: false, pendingResume: false, resumeAt: 0, remoteFrom: null, queueFrom: null, hasClip: false });
  setStatus('idle');
  if ('mediaSession' in navigator) navigator.mediaSession.metadata = null;
  applyVol();
}

export async function next(auto = false) {
  const s = store.get();
  if (!s.queue.length) return;
  // Only the automatic move to the next track fades it in; a skip starts it at full volume.
  const fade = auto && fadeInNext;
  fadeInNext = false;
  // Skipped by hand in the first seconds of a stream track: the stream learns it is not liked.
  if (!auto && (s.wave || s.flow) && s.track && clock.get().time < 25) noteSkip(s.track);
  // Skipped late (past 70% of the track) still counts as a listen for the taste profile.
  if (!auto && s.track) {
    const c = clock.get();
    const dur = c.duration || s.track.duration || 0;
    if (dur > 20 && c.time / dur >= 0.7) noteListen(s.track, c.time / dur);
  }
  if (!fade) cancelXfade();
  if (s.index < s.queue.length - 1) return playIndex(s.index + 1, fade);
  if (s.repeat === 'all') return playIndex(0, fade);
  if (auto || s.index === s.queue.length - 1) {
    // «Вспышка после очереди» off: the queue simply ends.
    if (!s.wave && s.settings.flashAfter === false) {
      if (auto) toast('Очередь закончилась');
      return;
    }
    // The continuation is looked up over the network: keep a locked iPhone's audio alive meanwhile.
    if (auto) holdSession();
    const found = await wave(s.track);
    const have = new Set(store.get().queue.map((t) => t.id));
    const more = found.filter((t) => t && !have.has(t.id));
    if (more.length) store.set({ queue: [...store.get().queue, ...more], flow: true });
    const now = store.get();
    if (now.index < now.queue.length - 1) return playIndex(now.index + 1, fade);
    releaseSession();
    // Nothing found anywhere: say so instead of going quiet.
    if (auto) toast('Не получилось подобрать продолжение, включите что-нибудь ещё', 'error');
  }
}

// When the queue runs out, keep going in the spirit of the last track: artists that sound like it
// (Last.fm) and its own artist, then the listener's «Вспышка», so it never just stops.
async function wave(track) {
  if (store.get().wave) return waveBatch(10).catch(() => []);
  const seen = new Set(store.get().queue.map((t) => t.id));
  const fresh = (list) => list.filter((t) => t && !seen.has(t.id));
  const like = track ? await similarTo(track, 10).catch(() => []) : [];
  if (fresh(like).length >= 3) return fresh(like);
  if (track && track.artistId) {
    try {
      const a = await fetchArtist(track.artistId, store.get().settings.country);
      const pool = fresh([...like, ...a.tracks]);
      for (let i = pool.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        [pool[i], pool[j]] = [pool[j], pool[i]];
      }
      if (pool.length) return pool.slice(0, 10);
    } catch {
      /* fall through to the listener's own stream */
    }
  }
  return fresh(await waveBatch(10).catch(() => []));
}

// «Вспышка» starts at once from what is already on the device (a liked or recently played track,
// or the last batch kept from before); the real batch (artists, Last.fm, charts) is gathered
// behind it and joins the queue when ready.
export async function startWave() {
  if (!requireAccount('play')) return;
  const first = quickStart();
  if (first.length) {
    playTrack(first[0], first, 0);
    store.set({ wave: true, waveLoading: false, queueFrom: 'Вспышка' });
    waveBatch(15)
      .then((more) => {
        const s = store.get();
        if (!s.wave) return;
        const have = new Set(s.queue.map((t) => t.id));
        store.set({ queue: [...s.queue, ...more.filter((t) => !have.has(t.id))] });
      })
      .catch(() => {})
      .finally(topUp);
    return;
  }
  store.set({ waveLoading: true });
  const list = await waveBatch(15).catch(() => []);
  store.set({ waveLoading: false });
  if (!list.length) return toast('Не получилось собрать «Вспышку», попробуйте ещё раз', 'error');
  playTrack(list[0], list, 0);
  store.set({ wave: true, queueFrom: 'Вспышка' });
}

export function prev() {
  const s = store.get();
  if (clock.get().time > 3 || s.index <= 0) return seek(0);
  playIndex(s.index - 1);
}

export function seek(t) {
  if (!currentVideo) return;
  cancelXfade();
  t = Math.max(0, Math.min(t, (clock.get().duration || 1e9) - 0.5));
  if (fadingOut) {
    fadingOut = false;
    fadeInNext = false;
    rampFade(1, 0.2);
  }
  send({ type: 'seek', t });
  clock.set({ time: t, at: performance.now() });
  acted({ seek: t });
  setTimeout(report, 800);
}

export function setVolume(v) {
  v = Math.max(0, Math.min(100, Math.round(v)));
  store.set({ volume: v, muted: v === 0 });
  send({ type: 'volume', v, muted: v === 0 });
}
export function toggleMute() {
  const s = store.get();
  const muted = !s.muted;
  const v = !muted && !s.volume ? 50 : s.volume;
  store.set({ muted, volume: v });
  send({ type: 'volume', v, muted });
}

function onEnded() {
  const s = store.get();
  if (s.track) noteListen(s.track, 1); // heard to the end (a repeat counts again)
  if (s.repeat === 'one') {
    if (engine === 'audio') {
      audio.currentTime = 0;
      listenedId = null;
      return audio.play().catch(() => {});
    }
    return loadVideo(currentVideo, 0);
  }
  next(true);
}

export function setVideoMode(mode) {
  const s = store.get();
  if (!s.track || s.videoMode === mode) return;
  cancelXfade();
  const t = clock.get().time;
  if (s.track.source === 'blink' || s.track.source === 'jamendo') return;
  const v = s.ytCache[s.track.id];
  if (mode === 'clip') {
    if (!v || !v.clip) return toast('У этого трека нет клипа');
    useMainPlayer();
    store.set({ videoMode: 'clip' });
    candidates = [v.clip];
    candidateIdx = 0;
    loadVideo(v.clip, t);
  } else {
    store.set({ videoMode: 'audio' });
    candidates = v.audio;
    candidateIdx = 0;
    loadVideo(v.audio[0], t);
  }
}

export function playNext(track) {
  const s = store.get();
  if (!s.track) return playTrack(track);
  const q = [...s.queue];
  q.splice(s.index + 1, 0, track);
  store.set({ queue: q });
  toast('Сыграет следующим');
}
export function addToQueue(track) {
  const s = store.get();
  if (!s.track) return playTrack(track);
  store.set({ queue: [...s.queue, track] });
  toast('Добавлено в очередь');
}
export function removeFromQueue(i) {
  const s = store.get();
  if (i === s.index) return;
  const q = s.queue.filter((_, k) => k !== i);
  store.set({ queue: q, index: i < s.index ? s.index - 1 : s.index });
}
export function jumpTo(i) {
  playIndex(i);
}

export function toggleShuffle() {
  const s = store.get();
  const shuffle = !s.shuffle;
  if (shuffle && s.queue.length > 2) {
    const head = s.queue.slice(0, s.index + 1);
    const rest = s.queue.slice(s.index + 1);
    for (let i = rest.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [rest[i], rest[j]] = [rest[j], rest[i]];
    }
    store.set({ queue: [...head, ...rest] });
  }
  store.set({ shuffle });
  toast(shuffle ? 'Перемешано' : 'Перемешивание выключено');
}
export function cycleRepeat() {
  const order = { off: 'all', all: 'one', one: 'off' };
  const repeat = order[store.get().repeat];
  store.set({ repeat });
  toast(repeat === 'all' ? 'Повтор очереди' : repeat === 'one' ? 'Повтор трека' : 'Повтор выключен');
}

// Another device started playing on this account: pause here, like one stream per account.
store.set({
  onRemotePlay: (np) => {
    cancelXfade();
    if (currentVideo) send({ type: 'pause' });
    toast(`Сейчас играет ${np.deviceName}: ${np.track.title}`);
  },
});

export function initMedia() {
  window.blink.onMedia((cmd) => (cmd === 'toggle' ? toggle() : cmd === 'next' ? next() : prev()));
  bindSession();
  // Restore the last track (paused) so the capsule isn't empty on launch.
  const s = store.get();
  if (s.track) {
    clock.set({ time: 0, duration: s.track.duration, at: performance.now(), playing: false });
    mediaSession(s.track);
    // Prepare it now, so the first press of play doesn't wait for the network.
    warm(s.track).catch(() => {});
    if (s.track.source !== 'blink' && s.track.source !== 'jamendo') loadApi();
  }
}

// ---------- clip behind the lyrics ----------
// A second, muted player shows the clip as a backdrop while the track plays as usual,
// so lyrics stay in sync with the music. It follows the main player's position.
let bg = null;
let bgVideo = null;
let bgSync = null;

export function startBackdrop() {
  const s = store.get();
  const v = s.track && s.ytCache[s.track.id];
  if (!v || !v.clip || !window.YT || !window.YT.Player) return stopBackdrop();
  if (bg && bgVideo === v.clip) return;
  bgVideo = v.clip;
  const t = clock.get().time;
  if (!bg) {
    bg = new window.YT.Player('yt-bg', {
      width: '100%',
      height: '100%',
      videoId: v.clip,
      playerVars: { autoplay: 1, mute: 1, controls: 0, disablekb: 1, fs: 0, iv_load_policy: 3, playsinline: 1, rel: 0, loop: 1, start: Math.floor(t), origin: location.origin },
      events: {
        onReady: (e) => {
          e.target.mute();
          e.target.playVideo();
        },
        onStateChange: (e) => {
          if (e.data === 1) {
            try {
              e.target.unloadModule('captions');
            } catch {
              /* not loaded */
            }
          }
        },
        onError: () => {
          // Hide the backdrop for this track instead of showing YouTube's error card.
          const t = store.get().track;
          store.set({ bgFail: t && t.id });
          stopBackdrop();
        },
      },
    });
  } else {
    bg.loadVideoById({ videoId: v.clip, startSeconds: t });
    bg.mute();
  }
  clearInterval(bgSync);
  bgSync = setInterval(() => {
    if (!bg || !bg.getCurrentTime) return;
    const st = store.get().status;
    if (st === 'paused') return bg.pauseVideo();
    if (st === 'playing' && bg.getPlayerState() !== 1) bg.playVideo();
    const d = (bg.getDuration && bg.getDuration()) || 0;
    const want = d ? Math.min(clock.get().time, d - 1) : clock.get().time;
    if (Math.abs(bg.getCurrentTime() - want) > 1.5) bg.seekTo(want, true);
  }, 1000);
}

export function stopBackdrop(destroy = false) {
  clearInterval(bgSync);
  bgVideo = null;
  if (!bg) return;
  if (destroy) {
    try {
      bg.destroy();
    } catch {
      /* already gone */
    }
    bg = null;
  } else if (bg.stopVideo) bg.stopVideo();
}
