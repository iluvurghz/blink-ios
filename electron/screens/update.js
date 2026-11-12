// Window 05. main.cjs passes ?from=&to=&notes=<json array of lines>.
(function () {
  const q = new URLSearchParams(location.search);
  const bridge = window.screenBridge || { send() {} };
  const $ = (id) => document.getElementById(id);
  let notes = [];
  try {
    notes = JSON.parse(q.get('notes') || '[]');
  } catch {}
  if (!notes.length) notes = ['Исправления и улучшения'];
  $('from').textContent = q.get('from') || '';
  $('to').textContent = q.get('to') || '';
  const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
  $('chg').innerHTML = notes
    .slice(0, 4)
    .map((n) => {
      // «Вспышка: …» or «Вспышка — …» → the name in bold
      const m = n.match(/^(.{2,28}?)(:| —)\s+(.+)$/);
      return '<li><span>' + (m ? '<b>' + esc(m[1]) + (m[2] === ':' ? ':' : '') + '</b> ' + esc(m[3]) : esc(n)) + '</span></li>';
    })
    .join('');
  const leave = (msg) => {
    document.body.classList.add('out');
    setTimeout(() => bridge.send(msg), 240);
  };
  $('later').onclick = () => leave('later');
  $('x').onclick = () => leave('later');
  $('restart').onclick = () => leave('restart');
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') leave('later');
  });
  document.fonts.ready.then(() => {
    bridge.send('shown');
    requestAnimationFrame(() => document.body.classList.add('ready'));
  });
})();
