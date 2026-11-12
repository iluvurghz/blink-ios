// Any avatar picture that fails to load (blocked host, slow mobile network, dead link) turns into a round
// neutral placeholder instead of a broken-image icon or a stray «?».
const PH =
  "data:image/svg+xml;utf8," +
  encodeURIComponent(
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'><defs><radialGradient id='g' cx='30%' cy='25%' r='90%'><stop offset='0' stop-color='#ff8a3d' stop-opacity='.35'/><stop offset='1' stop-color='#2a2630'/></radialGradient></defs><rect width='64' height='64' fill='url(#g)'/><circle cx='32' cy='25' r='10' fill='#eee9e2' fill-opacity='.7'/><path d='M12 56c2-12 11-18 20-18s18 6 20 18z' fill='#eee9e2' fill-opacity='.7'/></svg>"
  );
const AVA = '.prof-ava, .avatar img, .comment img, .comment-ava, .post-head img, img[data-ava]';

export function initImgFallback() {
  document.addEventListener(
    'error',
    (e) => {
      const el = e.target;
      if (!el || el.tagName !== 'IMG' || el.dataset.phDone || !el.matches(AVA)) return;
      el.dataset.phDone = '1';
      el.removeAttribute('srcset');
      el.src = PH;
    },
    true
  );
}
