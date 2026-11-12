package app.blink.core.net

import app.blink.core.model.Track
import java.io.IOException
import java.time.OffsetDateTime
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.json.JsonObject
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request

/** Как найти звук для проигрывания; к офлайну это отношения не имеет (скачивание идёт через `Resolver`). */
class StreamException(val kind: Kind, message: String) : Exception(message) {
    enum class Kind { NEED_SIGN_IN, NOT_FOUND, UNAVAILABLE }
}

data class StreamSource(val url: String)

data class PlusStatus(val active: Boolean, val untilMs: Long?)

/** Запросы к серверу Blink и каталогу. Формы ответов сняты с `server.js` и веб-клиента (см. docs/api-map.md). */
class BlinkApi(
    private val http: OkHttpClient,
    private val config: BlinkConfig,
    private val tokens: TokenProvider? = null,
) {
    private val client = http.withCallTimeout(20)

    // ---------- поиск ----------

    /**
     * Лицензионный каталог Blink первым (его можно сохранять офлайн), затем iTunes и Яндекс без дублей.
     * Если отвечает хоть один источник, это результат; если ни один и причина в сети, бросает IOException.
     */
    suspend fun search(term: String, country: String = "ru"): List<Track> {
        val q = term.trim()
        if (q.isEmpty()) return emptyList()
        return coroutineScope {
            val licensed = async { runCatching { licensed(q) } }
            val itunes = async { runCatching { itunes(q, country) } }
            val yandex = async { runCatching { yandex(q, 30) } }
            val results = listOf(licensed.await(), itunes.await(), yandex.await())
            val firstNetworkError = results.firstNotNullOfOrNull { it.exceptionOrNull() as? IOException }
            if (results.all { it.isFailure } && firstNetworkError != null) throw firstNetworkError
            merge(results.map { it.getOrNull().orEmpty() })
        }
    }

    suspend fun latestLicensed(limit: Int = 12): List<Track> {
        if (config.supabaseAnonKey.isBlank()) return emptyList()
        val url = rest("lic_tracks")
            .addQueryParameter("select", LIC_FIELDS)
            .addQueryParameter("status", "eq.live")
            .addQueryParameter("order", "created_at.desc")
            .addQueryParameter("limit", limit.toString())
            .build()
        return restTracks(url)
    }

    private suspend fun licensed(q: String): List<Track> {
        if (config.supabaseAnonKey.isBlank()) return emptyList()
        val like = "*" + q.replace(Regex("[%_,()*:]"), " ").trim() + "*"
        val url = rest("lic_tracks")
            .addQueryParameter("select", LIC_FIELDS)
            .addQueryParameter("status", "eq.live")
            .addQueryParameter("or", "(title.ilike.$like,artist_name.ilike.$like,release_title.ilike.$like)")
            .addQueryParameter("limit", "20")
            .build()
        return restTracks(url)
    }

    private fun rest(table: String): HttpUrl.Builder = config.supabase.toHttpUrl().newBuilder().addPathSegments("rest/v1/$table")

    private suspend fun restTracks(url: HttpUrl): List<Track> {
        val token = tokens?.accessToken() ?: config.supabaseAnonKey
        val req = Request.Builder().url(url)
            .header("apikey", config.supabaseAnonKey)
            .header("Authorization", "Bearer $token")
            .header("Accept", "application/json")
            .build()
        val res = client.newCall(req).text()
        if (res.code !in 200..299) throw IOException("catalog ${res.code}")
        val arr = try {
            BlinkJson.parseToJsonElement(res.text).arr()
        } catch (_: Exception) {
            null
        } ?: return emptyList()
        return arr.mapNotNull { fromLicRow(it.obj() ?: return@mapNotNull null) }
    }

    internal fun fromLicRow(r: JsonObject): Track? {
        val id = r.str("id") ?: return null
        val title = r.str("title") ?: return null
        return Track(
            id = "b:$id",
            lic = id,
            source = Track.SOURCE_BLINK,
            title = title,
            artist = r.str("artist_name").orEmpty(),
            album = r.str("release_title").orEmpty(),
            artwork = if (!r.str("cover_path").isNullOrEmpty()) "${config.base}/covers/$id.jpg" else "",
            duration = r.int("duration") ?: 0,
            explicit = r.bool("explicit") == true,
            year = r.str("year").orEmpty(),
            genre = r.str("genre").orEmpty(),
            lrc = r.str("lrc"),
            lyrics = r.str("lyrics"),
            offline = r.bool("offline_allowed") == true,
        )
    }

    private suspend fun itunes(q: String, country: String): List<Track> {
        val url = config.base.toHttpUrl().newBuilder().addPathSegments("api/itunes/search")
            .addQueryParameter("term", q)
            .addQueryParameter("country", country)
            .addQueryParameter("media", "music")
            .addQueryParameter("entity", "song")
            .addQueryParameter("limit", "50")
            .build()
        return songs(url)
    }

    /** Трек Apple по числовому id (из ссылки `/t/<id>`); null, если не нашли. */
    suspend fun lookup(id: String): Track? {
        val url = config.base.toHttpUrl().newBuilder().addPathSegments("api/itunes/lookup")
            .addQueryParameter("id", id).addQueryParameter("country", "ru").addQueryParameter("entity", "song").build()
        return songs(url).firstOrNull()
    }

    private suspend fun yandex(q: String, limit: Int): List<Track> {
        val url = config.base.toHttpUrl().newBuilder().addPathSegments("api/yandex/search")
            .addQueryParameter("q", q)
            .addQueryParameter("type", "track")
            .addQueryParameter("limit", limit.toString())
            .build()
        return songs(url)
    }

    private suspend fun songs(url: HttpUrl): List<Track> {
        val res = client.newCall(Request.Builder().url(url).header("Accept", "application/json").build()).text()
        if (res.code !in 200..299) throw IOException("search ${res.code}")
        val results = parseObject(res.text)?.get("results").arr() ?: return emptyList()
        return results.mapNotNull { e -> e.obj()?.takeIf { it.str("kind") == "song" }?.let(::fromItunes) }
    }

    internal fun fromItunes(r: JsonObject): Track? {
        val id = r.str("trackId") ?: return null
        val title = r.str("trackName") ?: return null
        val a600 = r.str("artworkUrl600")
        val a100 = r.str("artworkUrl100")
        val artwork = when {
            !a600.isNullOrEmpty() -> a600.replace(Regex("/\\d+x\\d+$"), "/1000x1000")
            !a100.isNullOrEmpty() -> scaleArt(a100, 600)
            else -> ""
        }
        return Track(
            id = id,
            title = title,
            artist = r.str("artistName").orEmpty(),
            artistId = r.str("artistId"),
            album = r.str("collectionName").orEmpty().replace(Regex("\\s*-\\s*(Single|EP)$", RegexOption.IGNORE_CASE), ""),
            albumId = r.str("collectionId"),
            artwork = artwork,
            duration = r.long("trackTimeMillis")?.let { Math.round(it / 1000.0).toInt() } ?: 0,
            explicit = r.str("trackExplicitness") == "explicit",
            year = r.str("releaseDate")?.take(4).orEmpty(),
            genre = r.str("primaryGenreName").orEmpty(),
        )
    }

    // ---------- чарт ----------

    suspend fun chart(limit: Int = 30): List<Track> {
        val url = config.base.toHttpUrl().newBuilder().addPathSegments("api/charts/top").build()
        val res = client.newCall(Request.Builder().url(url).header("Accept", "application/json").build()).text()
        if (res.code !in 200..299) throw IOException("charts ${res.code}")
        val items = parseObject(res.text)?.get("items").arr() ?: return emptyList()
        return items.mapNotNull { fromChart(it.obj()?.get("track").obj() ?: return@mapNotNull null) }.take(limit)
    }

    internal fun fromChart(t: JsonObject): Track? {
        val id = t.str("id") ?: return null
        val title = t.str("title") ?: return null
        val artists = t["artists"].arr()?.mapNotNull { it.obj()?.str("name") }.orEmpty()
        if (artists.isEmpty()) return null
        val album = t["albums"].arr()?.firstOrNull().obj()
        val version = t.str("version")
        val cover = t.str("coverUri")
        return Track(
            id = "cr$id",
            source = "chart",
            title = if (!version.isNullOrEmpty()) "$title ($version)" else title,
            artist = artists.joinToString(", "),
            album = album?.str("title").orEmpty(),
            artwork = if (!cover.isNullOrEmpty()) "https://" + cover.replace("%%", "600x600") else "",
            duration = t.long("durationMs")?.let { Math.round(it / 1000.0).toInt() } ?: 0,
            explicit = t.str("contentWarning") == "explicit",
            year = album?.str("year").orEmpty(),
            genre = album?.str("genre").orEmpty(),
        )
    }

    // ---------- проигрывание (стрим, не скачивание) ----------

    /**
     * Куда идти за звуком. Лицензионный трек: `/api/play/<lic>` (нужен вход). Остальные: APIBlink,
     * как в вебе (`/api/apiblink/play?artist&title` → `streamUrl`, с Range). Скачивать этим путём нельзя.
     */
    suspend fun streamFor(track: Track): StreamSource {
        track.stream?.let { return StreamSource(it) }
        if (track.isLicensed) {
            val token = tokens?.accessToken() ?: throw StreamException(StreamException.Kind.NEED_SIGN_IN, "Войдите, чтобы слушать треки Blink")
            val url = config.base.toHttpUrl().newBuilder().addPathSegments("api/play").addPathSegment(track.lic!!).build()
            val res = client.newCall(Request.Builder().url(url).header("Authorization", "Bearer $token").build()).text()
            return when {
                res.code == 401 -> throw StreamException(StreamException.Kind.NEED_SIGN_IN, "Войдите в аккаунт")
                res.code == 404 -> throw StreamException(StreamException.Kind.NOT_FOUND, "Трек снят или ещё не вышел")
                res.code !in 200..299 -> throw StreamException(StreamException.Kind.UNAVAILABLE, "Сервер не отдал трек (${res.code})")
                else -> StreamSource(
                    config.absolute(parseObject(res.text)?.str("url"))
                        ?: throw StreamException(StreamException.Kind.UNAVAILABLE, "Сервер не отдал ссылку"),
                )
            }
        }
        val url = config.base.toHttpUrl().newBuilder().addPathSegments("api/apiblink/play")
            .addQueryParameter("artist", track.artist)
            .addQueryParameter("title", track.title)
            .build()
        val res = client.withCallTimeout(25).newCall(Request.Builder().url(url).header("Accept", "application/json").build()).text()
        if (res.code == 503) throw StreamException(StreamException.Kind.UNAVAILABLE, "Источник сейчас недоступен")
        if (res.code !in 200..299) throw StreamException(StreamException.Kind.NOT_FOUND, "Не нашли поток для этого трека")
        val stream = config.absolute(parseObject(res.text)?.get("track").obj()?.str("streamUrl"))
            ?: throw StreamException(StreamException.Kind.NOT_FOUND, "Не нашли поток для этого трека")
        return StreamSource(stream)
    }

    // ---------- подписка ----------

    /** Статус Blink+. null без входа или без ответа сервера: тогда остаётся последняя известная дата. */
    suspend fun plus(): PlusStatus? {
        val token = tokens?.accessToken() ?: return null
        val url = config.base.toHttpUrl().newBuilder().addPathSegments("api/plus/me").build()
        val res = client.newCall(Request.Builder().url(url).header("Authorization", "Bearer $token").build()).text()
        if (res.code !in 200..299) return null
        val o = parseObject(res.text) ?: return null
        val until = o.str("plus_until")?.let { runCatching { OffsetDateTime.parse(it).toInstant().toEpochMilli() }.getOrNull() }
        val active = (o.bool("active") == true) && (until == null || until > System.currentTimeMillis())
        return PlusStatus(active = active, untilMs = if (o.bool("active") == true) until else null)
    }

    companion object {
        const val LIC_FIELDS = "id,artist_id,title,artist_name,release_title,duration,explicit,year,genre,lrc,lyrics,cover_path,offline_allowed,status"

        /** iTunes: …/100x100bb.jpg → …/600x600bb.jpg, Яндекс: …/100x100 → …/600x600. */
        fun scaleArt(url: String, size: Int): String {
            if (url.isEmpty()) return ""
            if (Regex("/\\d+x\\d+bb\\.jpg$").containsMatchIn(url)) return url.replace(Regex("/\\d+x\\d+bb\\.jpg$"), "/${size}x${size}bb.jpg")
            if (Regex("/\\d+x\\d+$").containsMatchIn(url)) return url.replace(Regex("/\\d+x\\d+$"), "/${size}x$size")
            return url
        }

        private val KEEP = Regex("[^\\p{L}\\p{N}|]+")

        /** Ключ дубля как на сайте: `название|артист` без знаков и регистра. */
        fun dedupeKey(t: Track): String = (t.title + "|" + t.artist).lowercase().replace(KEEP, "")

        /** Склеивает списки по порядку источников, убирая повторы по `название|артист`. */
        fun merge(lists: List<List<Track>>): List<Track> {
            val seenIds = HashSet<String>()
            val seen = HashSet<String>()
            val out = ArrayList<Track>()
            for (list in lists) for (t in list) {
                if (!seenIds.add(t.id)) continue
                if (!seen.add(dedupeKey(t))) continue
                out.add(t)
            }
            return out
        }
    }

    private fun merge(lists: List<List<Track>>): List<Track> = Companion.merge(lists)
    private fun scaleArt(url: String, size: Int): String = Companion.scaleArt(url, size)
}
