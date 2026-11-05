// What the listener sees when something fails: plain Russian, never raw "FetchError: …",
// Supabase/Postgres texts or status codes. Our own Russian messages pass through untouched.
const NET = /failed to fetch|fetch ?error|network ?error|load failed|abort|time ?out|econn|enotfound|socket|dns|offline|err_/i;

export function humanError(e, fallback = 'Не получилось, попробуйте ещё раз') {
  const msg = String((e && e.message) || e || '');
  const st = e && e.status;
  if (st === 401) return 'Войдите в аккаунт';
  if (st === 403) return 'Для этого действия нет доступа';
  if (st === 404) return 'Не нашли, возможно уже удалено';
  if (st === 413) return 'Файл слишком большой';
  if (st === 429) return 'Слишком часто, подождите минуту';
  if (st >= 500) return 'Сервер сейчас занят, попробуйте чуть позже';
  if (NET.test(msg) || st === 0) return 'Нет связи с сервером. Проверьте интернет и попробуйте ещё раз';
  if (/[А-Яа-яЁё]/.test(msg) && msg.length < 200) return msg;
  return fallback;
}
