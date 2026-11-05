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

// blinkmusic.cc/?gsignin=desktop: the desktop app opens this in the real browser (Google doesn't
// allow sign-in inside app windows); the token goes back to the app through the blink:// link.
export function desktopHandoffPage() {
  document.body.style.cssText = 'margin:0;background:#0d0c10;color:#eee9e2;font:600 18px system-ui;display:grid;place-items:center;min-height:100vh';
  document.body.innerHTML =
    '<div style="text-align:center;padding:24px"><div style="margin-bottom:20px">Вход в Blink через Google</div><div id="g" style="display:flex;justify-content:center"></div><div id="m" style="color:#9a95a1;font-size:14px;margin-top:18px"></div></div>';
  const msg = (t) => (document.getElementById('m').textContent = t);
  renderGoogleButton(document.getElementById('g'), (token, nonce) => {
    location.replace('blink://auth?id_token=' + encodeURIComponent(token) + '&nonce=' + encodeURIComponent(nonce));
    msg('Возвращаемся в Blink… Эту вкладку можно закрыть.');
  }).catch(() => msg('Google не загрузился. Проверьте интернет и обновите страницу.'));
}
