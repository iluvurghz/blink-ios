// Sign-in with Telegram (Login Widget). Telegram hands the page a signed user object; our server
// (server/telegramAuth.js) checks it and returns a one-time token that Supabase turns into a session.
// The widget refuses to run inside app windows, so the desktop app does it in the real browser:
// blinkmusic.cc/?tgsignin=desktop shows the widget and hands the token back through blink://auth.
export const TG_BOT = 'blinkupdaterobot';
const API = (import.meta.env.VITE_MEDIA_URL || 'https://blinkmusic.cc').replace(/\/$/, '');

// Draws Telegram's own button into `el`; onUser(user) fires after the person confirms in Telegram.
export function renderTelegramButton(el, onUser) {
  window.__blinkTgAuth = onUser;
  el.innerHTML = '';
  const s = document.createElement('script');
  s.async = true;
  s.src = 'https://telegram.org/js/telegram-widget.js?22';
  s.setAttribute('data-telegram-login', TG_BOT);
  s.setAttribute('data-size', 'large');
  s.setAttribute('data-radius', '14');
  s.setAttribute('data-userpic', 'false');
  s.setAttribute('data-request-access', 'write');
  s.setAttribute('data-onauth', '__blinkTgAuth(user)');
  return new Promise((ok, no) => {
    s.onload = ok;
    s.onerror = () => no(new Error('tg'));
    setTimeout(() => no(new Error('tg timeout')), 10000);
    el.appendChild(s);
  });
}

// Signed user from the widget → one-time token for Supabase's verifyOtp.
export async function telegramToken(user) {
  const r = await fetch(API + '/api/auth/telegram', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(user) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.token_hash) throw new Error(j.error || 'telegram');
  return j.token_hash;
}

// blinkmusic.cc/?tgsignin=desktop, opened by the desktop app in the real browser.
export function desktopTelegramPage() {
  document.body.style.cssText = 'margin:0;background:#0d0c10;color:#eee9e2;font:600 18px system-ui;display:grid;place-items:center;min-height:100vh';
  document.body.innerHTML =
    '<div style="text-align:center;padding:24px"><div style="margin-bottom:20px">Вход в Blink через Telegram</div><div id="g" style="display:flex;justify-content:center"></div><div id="m" style="color:#9a95a1;font-size:14px;margin-top:18px"></div></div>';
  const msg = (t) => (document.getElementById('m').textContent = t);
  renderTelegramButton(document.getElementById('g'), (user) => {
    msg('Проверяем…');
    telegramToken(user).then(
      (hash) => {
        location.replace('blink://auth?tg_hash=' + encodeURIComponent(hash));
        msg('Возвращаемся в Blink… Эту вкладку можно закрыть.');
      },
      () => msg('Не получилось войти. Попробуйте ещё раз.'),
    );
  }).catch(() => msg('Telegram не загрузился. Проверьте интернет и обновите страницу.'));
}
