# Карта API для нативных клиентов

Снято с `server.js` (снимок 8 ноября) и веб-клиента `src/lib/*` (v1.8.7). Ничего не придумано; чего не видел, помечено «не проверено».
База: `https://blinkmusic.cc`. CORS нативным клиентам не мешает. С песочницы разработки `blinkmusic.cc` недоступен, поэтому ответы вживую ещё не сверены.

## Трек (общий для сайта, ПК и нативки)

```json
{ "id": "123456789", "title": "…", "artist": "…", "artistId": "…|null", "album": "…", "albumId": "…|null",
  "artwork": "https://…", "duration": 215, "explicit": false, "year": "2024", "genre": "…",
  "source": "chart|blink|jamendo|soundcloud|vk|parser|local|(пусто)",
  "lic": "<uuid>", "lrc": "…", "lyrics": "…", "offline": true, "stream": "https://…" }
```
`id`: iTunes/Яндекс `String(trackId)`, лицензионный `b:<uuid>`, подборка `cr<id>`, Jamendo `j:<id>`. Лайки и плейлисты на сервере хранят такие объекты целиком, поэтому нативка обязана выдавать те же `id`.

## Без авторизации

| Запрос | Ответ |
|---|---|
| `GET /api/mp3/config` | `{youtubeEnabled, parserEnabled, apiblinkEnabled, vkEnabled, yandexAsPrimary, yandexSearchOnly, winterTheme}`. Сейчас `parserEnabled:false`. |
| `GET /api/apiblink/play?artist=&title=` | `{track:{title, artist, duration, streamUrl:"/api/apiblink/stream/<id>", artworkDirect, artworkUrl:"/api/apiblink/artwork/<id>", lyricsUrl, videoUrl}}`. 503 `{error:{code:"apiblink_disabled"\|"apiblink_unavailable"}}`. Не нашёл: не 2xx. Ответ кэшируется на сервере 20 минут. |
| `GET /api/apiblink/search?q=` | `{results:[track]}` (один лучший матч; «Артист - Название» делится по ` - `). |
| `GET /api/apiblink/soundcloud?q=`, `/vk?q=` | `{results:[{title, artist, duration, streamUrl, artworkDirect, sourceId, externalUrl}]}`. VK выключен: `{results:[], disabled:true}`. |
| `GET /api/apiblink/stream/:id` | Аудио. `Accept-Ranges: bytes`, 206 на `Range`, `Content-Length`. Если апстрим оборвался, сервер сам переоткрывает с нужного байта, иначе рвёт соединение (клиент должен докачать по Range). |
| `GET /api/apiblink/artwork/:id`, `/lyrics/:id` (204 нет), `/video/:id` (204 нет, иначе `{videoUrl}`), `/health` | Обложка, текст, клип, `{status}`. |
| `GET /api/itunes/search?term=&country=ru&entity=song\|album\|musicArtist&media=music&limit=` | Ответ Apple как есть; если Apple не ответил, в том же формате отдаёт Яндекс. |
| `GET /api/itunes/lookup?id=&entity=&country=&limit=` | То же для карточек. |
| `GET /api/yandex/search?q=&type=track\|album\|artist&limit=` | `{results:[{kind:"song", trackId, trackName, artistName, artistId, collectionName, collectionId, artworkUrl100, artworkUrl600, trackTimeMillis, releaseDate}]}` |
| `GET /api/yandex/artist/:id/tracks?limit=&metaOnly=true`, `/albums` | В том же iTunes-подобном виде. |
| `GET /api/deezer/search`, `/artist/:id`, `/album/:id`, `/match?q=` | Метаданные Deezer. |
| `GET /api/lrclib/get?track_name=&artist_name=&album_name=&duration=`, `/search`, `GET /api/lyricsovh?artist=&title=` | Тексты: `syncedLyrics` (LRC), `plainLyrics`. |
| `GET /api/jamendo/search?q=` | `{enabled, tracks:[{id,title,artist,album,artwork,duration,stream,link}]}` |
| `GET /api/charts/top`, `/api/charts/daily` | `{items:[{track:{title, artists:[{name}], albums:[…]}, chart:{…}}]}` (формат Яндекса; не проверено вживую). |
| `GET /api/wave/pool?seeds=Артист Трек\|Артист Трек&n=5` | `{tracks:[{id:"cr…", source:"chart", title, artist, album, artwork, duration, src:"similar\|popular\|simArtist", seed, hits}]}` |
| `GET /api/plus/config`, `GET /api/health`, `GET /api/yt-relay` | Цены и ступени Blink+, `{ok:true}`, настройки реле. |

## С авторизацией (`Authorization: Bearer <Supabase access_token>`)

| Запрос | Что |
|---|---|
| `GET /api/play/:licId` | `{url}`: подписанная ссылка на `/media/:id` на час. Только лицензионные треки (`lic_tracks.status='live'`). |
| `POST /api/streams {trackId, seconds, offline?}` | Учёт прослушивания (с 30 секунд). |
| `POST /api/presence`, `/api/together/*` (SSE), `/api/plus/*`, `/api/profile/*`, `/api/artist/*`, `/api/tracks*`, `/api/auth/telegram` | Не проверено подробно, нужны с M1. |

## Supabase (`https://wjyohhvpqvfhyhrrbhgc.supabase.co`)

- Auth (GoTrue): e-mail, Google (id-token), Telegram (через `/api/auth/telegram` → `token_hash`).
- PostgREST: `lic_tracks` (каталог лицензионных), `artists`, `follows`, `track_likes`, `posts`, `comments`, `shared_playlists`, `editorial_playlists`, `plays`, `user_devices`; RPC `artist_stats`, `post_list`, `comment_list`, `blink_stats`; Edge Function `charts`.
- Анонимный ключ (`anon key`) публичный и лежит в бандле сайта; в этот репозиторий не копировал, возьмём из сборки в M1.

## Что нужно нативке в M0

Поиск: `itunes/search` + `yandex/search` (слить и убрать дубли по `название|артист`, как делает `api.js`).
Играть и качать: `apiblink/play` → `streamUrl` (до появления резолвера офлайна).
Лицензионные треки: `/api/play/:id` (нужен вход, M1).
Чарты для кнопки «Вспышка» без сида: `charts/top`.
