// Google sign-in right on blinkmusic.cc (Google Identity Services). The old way went through
// Supabase's own address: Google showed "wjyohhvpqvfhyhrrbhgc.supabase.co" on its screen, and
// the hop back through supabase.co hangs on many Russian networks. Here Google hands the ID token
// to our page and Supabase only checks it (through the mirror when needed, see sbroute.js).
const CLIENT_ID = '985494076827-sort0i6eo7hso8sa89jspbdqh3fhjl2q.apps.googleusercontent.com';
const SRC = 'https://accounts.google.com/gsi/client';

let loading = null;
function loadGis() {
  if (window.google && window.google.accounts) return Promise.resolve(window.google.accounts.id);
  if (!loading)
    loading = new Promise((ok, no) => {
      const s = document.createElement('script');
      s.src = SRC;
      s.async = true;
      s.onload = () => (window.google && window.google.accounts ? ok(window.google.accounts.id) : no(new Error('gis')));
      s.onerror = () => no(new Error('gis'));
      document.head.appendChild(s);
      setTimeout(() => no(new Error('gis timeout')), 8000);
    }).catch((e) => {
      loading = null;
      throw e;
    });
  return loading;
}

// Starts loading Google's script ahead of time (the sign-in page then opens instantly).
export const warmGis = () => loadGis().catch(() => {});

async function sha256hex(s) {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// Pages Google refuses to sign in from (in-app browsers of Telegram, VK, Instagram…).
export const inAppBrowser = () => /Telegram|VKClient|vkclient|Instagram|FBAN|FBAV|; wv\)/i.test(navigator.userAgent);

// The home-screen app on iPhone can't get the popup's answer back: it keeps the old redirect way.
export const gisUsable = () => !!(window.crypto && crypto.subtle) && !navigator.standalone;

// Draws Google's button into `el`; onToken(idToken, rawNonce) fires after the person picks an account.
export async function renderGoogleButton(el, onToken, width = 320) {
  const id = await loadGis();
  const raw = [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, '0')).join('');
  id.initialize({
    client_id: CLIENT_ID,
    nonce: await sha256hex(raw),
    ux_mode: 'popup',
    auto_select: false,
    itp_support: true,
    callback: (r) => r && r.credential && onToken(r.credential, raw),
  });
  el.innerHTML = '';
  // Dark rectangle in the colour of Blink's frame around it (.gsi-box), so both read as one button.
  id.renderButton(el, { theme: 'filled_black', size: 'large', shape: 'rectangular', text: 'continue_with', logo_alignment: 'left', locale: 'ru', width: Math.min(400, Math.max(200, width)) });
}

// Google sign-in without Supabase's address and without pop-ups: the person lands on Google's own "Choose an account" page in the
// same window or tab, and Google sends the ID token back to blinkmusic.cc (implicit flow, response_type=id_token), where it goes to
// Supabase's signInWithIdToken (site) or to the app through blink://auth (app window).
//
// REDIRECT_FLOW needs both addresses below in the OAuth client's "Authorized redirect URIs" (Google Cloud Console > APIs &
// Services > Credentials > the Web client > Authorized redirect URIs). Until they are there Google answers
// "Error 400: redirect_uri_mismatch" (the addresses were added on 2026-11-12, so it is on).
const REDIRECT_FLOW = true;
// Only on the addresses registered with the OAuth client (Authorized redirect URIs: <origin>/?gsignin=web and
// <origin>/?gsignin=desktop). Every other origin (the app's bundled copy, a mirror, an IP) keeps the old way.
// 'https://eu.blinkmusic.cc' joins once Google accepts https://eu.blinkmusic.cc/?gsignin=web and /?gsignin=desktop (checked by a request).
const REDIRECT_ORIGINS = ['https://blinkmusic.cc'];
export const googleRedirectOn = () => REDIRECT_FLOW && REDIRECT_ORIGINS.includes(location.origin);
// The site returns to the very origin it was opened on (the mirror eu.blinkmusic.cc exists for lines where the main
// domain hangs); the app's sign-in window always opens blinkmusic.cc.
const redirectUri = (kind) => (kind === 'web' ? location.origin : 'https://blinkmusic.cc') + '/?gsignin=' + kind;
const NONCE_KEY = 'blink-gsignin-nonce';

// The address of Google's account page; the raw nonce waits in sessionStorage for the way back.
export async function googleRedirectUrl(kind) {
  const nonce = [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, '0')).join('');
  try {
    sessionStorage.setItem(NONCE_KEY, nonce);
  } catch {}
  const q = new URLSearchParams({
    client_id: CLIENT_ID,
    response_type: 'id_token',
    scope: 'openid email profile',
    nonce: await sha256hex(nonce),
    redirect_uri: redirectUri(kind),
    prompt: 'select_account',
  });
  return 'https://accounts.google.com/o/oauth2/v2/auth?' + q.toString();
}

// The token Google put into the address fragment on the way back, or null.
export function googleReturn() {
  const back = new URLSearchParams(location.hash.slice(1));
  let nonce = null;
  try {
    nonce = sessionStorage.getItem(NONCE_KEY);
  } catch {}
  return back.get('id_token') && nonce ? { token: back.get('id_token'), nonce } : null;
}

function backToApp(token, nonce, msg) {
  location.replace('blink://auth?id_token=' + encodeURIComponent(token) + '&nonce=' + encodeURIComponent(nonce));
  msg('Возвращаемся в Blink… Эту вкладку можно закрыть.');
}

// blinkmusic.cc/?gsignin=desktop: the desktop app opens this in its sign-in window; the token goes back to the app through the
// blink:// link (which closes the window).
export function desktopHandoffPage() {
  document.body.style.cssText = 'margin:0;background:#0d0c10;color:#eee9e2;font:600 18px system-ui;display:grid;place-items:center;min-height:100vh';
  document.body.innerHTML =
    '<div style="text-align:center;padding:24px"><div style="margin-bottom:20px">Вход в Blink через Google</div><div id="g" style="display:flex;justify-content:center"></div><div id="m" style="color:#9a95a1;font-size:14px;margin-top:18px"></div></div>';
  const msg = (t) => (document.getElementById('m').textContent = t);
  if (REDIRECT_FLOW) {
    const back = googleReturn();
    if (back) return backToApp(back.token, back.nonce, msg);
    googleRedirectUrl('desktop').then((u) => location.replace(u), () => msg('Не получилось открыть Google. Закройте окно и попробуйте ещё раз.'));
    return;
  }
  renderGoogleButton(document.getElementById('g'), (token, nonce) => backToApp(token, nonce, msg)).catch(() => msg('Google не загрузился. Проверьте интернет и обновите страницу.'));
}
