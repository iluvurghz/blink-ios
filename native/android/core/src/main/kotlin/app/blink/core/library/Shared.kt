package app.blink.core.library

import app.blink.core.model.Track
import app.blink.core.net.BlinkConfig
import app.blink.core.net.BlinkJson
import app.blink.core.wave.Playlist
import app.blink.core.net.TokenProvider
import app.blink.core.net.arr
import app.blink.core.net.obj
import app.blink.core.net.parseObject
import app.blink.core.net.str
import app.blink.core.net.text
import app.blink.core.net.withCallTimeout
import java.io.IOException
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** Плейлист по ссылке `blinkmusic.cc/p/<код>` или подборка редакции. */
data class SharedPlaylist(val code: String, val owner: String, val name: String, val cover: String?, val tracks: List<Track>)

data class EditorialItem(val id: String, val title: String, val description: String, val cover: String)

/** Что скрывается за короткой ссылкой на трек. */
data class SharedTrack(val id: String, val title: String, val artist: String, val artwork: String) {
    /** Трек в форме плеера: лицензионные `b:<uuid>` играют из каталога Blink, остальные ищутся по названию. */
    fun toTrack(): Track =
        if (id.startsWith("b:")) Track(id = id, title = title, artist = artist, artwork = artwork, source = Track.SOURCE_BLINK, lic = id.removePrefix("b:"))
        else Track(id = id, title = title, artist = artist, artwork = artwork)
}

class SharedError(message: String) : Exception(message)

/** Запросы к PostgREST Supabase с зеркалом на сайте (supabase.co режут операторы). Анонимный ключ или токен пользователя. */
internal class SupabaseRest(http: OkHttpClient, private val config: BlinkConfig, private val tokens: TokenProvider?) {
    private val client = http.withCallTimeout(20)

    private fun roots(): List<String> = listOf(config.supabaseMirror, config.supabase).distinct()

    suspend fun call(path: String, query: Map<String, String>, build: (Request.Builder) -> Request.Builder = { it }, auth: Boolean = false): Pair<Int, String> {
        var last: IOException? = null
        for (root in roots()) {
            try {
                val url = root.toHttpUrl().newBuilder().addPathSegments("rest/v1/$path").apply { query.forEach { (k, v) -> addQueryParameter(k, v) } }.build()
                val b = Request.Builder().url(url).header("apikey", config.supabaseAnonKey).header("Accept", "application/json")
                val t = if (auth) tokens?.accessToken() else null
                b.header("Authorization", "Bearer " + (t ?: config.supabaseAnonKey))
                val res = client.newCall(build(b).build()).text()
                return res.code to res.text
            } catch (e: IOException) {
                last = e
            }
        }
        throw last ?: IOException("нет адреса")
    }
}

/** Общие плейлисты (таблицы `shared_playlists`, `editorial_playlists`) и короткие ссылки на треки (`/api/share/track`). */
class SharedApi(http: OkHttpClient, private val config: BlinkConfig, tokens: TokenProvider?, private val userId: () -> String?, private val userName: () -> String?) {
    private val client = http.withCallTimeout(20)
    private val jsonType = "application/json".toMediaType()
    private val db = SupabaseRest(http, config, tokens)

    private suspend fun rest(path: String, query: Map<String, String>, build: (Request.Builder) -> Request.Builder = { it }, auth: Boolean = false) = db.call(path, query, build, auth)

    private fun tracksOf(a: List<kotlinx.serialization.json.JsonElement>?): List<Track> =
        a.orEmpty().mapNotNull { e ->
            try {
                BlinkJson.decodeFromJsonElement(Track.serializer(), e)
            } catch (_: Exception) {
                null
            }
        }

    suspend fun fetchShared(code: String): SharedPlaylist? {
        val (status, text) = rest("shared_playlists", mapOf("select" to "code,owner_name,data", "code" to "eq.$code"))
        if (status !in 200..299) throw IOException("shared $status")
        val row = BlinkJson.parseToJsonElement(text).arr()?.firstOrNull().obj() ?: return null
        val d = row["data"].obj() ?: return null
        return SharedPlaylist(code, row.str("owner_name").orEmpty(), d.str("name").orEmpty(), d.str("cover"), tracksOf(d["tracks"].arr()))
    }

    suspend fun editorial(): List<EditorialItem> {
        val (status, text) = rest("editorial_playlists", mapOf("select" to "id,title,description,cover_url,art:tracks->0->>artwork", "published" to "eq.true", "order" to "position,created_at.desc", "limit" to "24"))
        if (status !in 200..299) throw IOException("editorial $status")
        return BlinkJson.parseToJsonElement(text).arr().orEmpty().mapNotNull { e ->
            val o = e.obj() ?: return@mapNotNull null
            EditorialItem(o.str("id") ?: return@mapNotNull null, o.str("title").orEmpty(), o.str("description").orEmpty(), o.str("cover_url") ?: o.str("art").orEmpty())
        }
    }

    suspend fun editorialOne(id: String): SharedPlaylist? {
        val (status, text) = rest("editorial_playlists", mapOf("select" to "id,title,description,cover_url,tracks", "id" to "eq.$id", "published" to "eq.true"))
        if (status !in 200..299) throw IOException("editorial $status")
        val o = BlinkJson.parseToJsonElement(text).arr()?.firstOrNull().obj() ?: return null
        return SharedPlaylist(id, "Blink", o.str("title").orEmpty(), o.str("cover_url"), tracksOf(o["tracks"].arr()))
    }

    /** Поделиться своим плейлистом: возвращает ссылку `blinkmusic.cc/p/<код>`. Повторный вызов обновляет те же данные. */
    suspend fun share(p: Playlist, code: () -> String = ::newCode): String {
        val uid = userId() ?: throw SharedError("Войдите в аккаунт")
        val data = buildJsonObject {
            put("name", JsonPrimitive(p.name))
            put("cover", p.cover?.let { JsonPrimitive(it) } ?: kotlinx.serialization.json.JsonNull)
            put("tracks", JsonArray(p.tracks.take(500).map { BlinkJson.encodeToJsonElement(Track.serializer(), it) }))
        }
        val (s1, t1) = rest("shared_playlists", mapOf("select" to "code", "owner_id" to "eq.$uid", "playlist_id" to "eq.${p.id}"), auth = true)
        val existing = if (s1 in 200..299) BlinkJson.parseToJsonElement(t1).arr()?.firstOrNull().obj()?.str("code") else null
        val c = existing ?: code()
        val row = buildJsonObject {
            put("code", JsonPrimitive(c))
            put("owner_id", JsonPrimitive(uid))
            put("owner_name", JsonPrimitive(userName().orEmpty()))
            put("playlist_id", JsonPrimitive(p.id))
            put("data", data)
            put("updated_at", JsonPrimitive(java.time.Instant.now().toString()))
        }
        val body = BlinkJson.encodeToString(JsonObject.serializer(), row).toRequestBody(jsonType)
        val (status, _) =
            if (existing != null) rest("shared_playlists", mapOf("code" to "eq.$c"), { it.header("Prefer", "return=minimal").patch(body) }, auth = true)
            else rest("shared_playlists", emptyMap(), { it.header("Prefer", "return=minimal").post(body) }, auth = true)
        if (status !in 200..299) throw SharedError("Не получилось поделиться")
        return link(c)
    }

    suspend fun unshare(p: Playlist) {
        val uid = userId() ?: throw SharedError("Войдите в аккаунт")
        val (status, _) = rest("shared_playlists", mapOf("owner_id" to "eq.$uid", "playlist_id" to "eq.${p.id}"), { it.delete() }, auth = true)
        if (status !in 200..299) throw SharedError("Не получилось закрыть доступ")
    }

    /** Короткая ссылка на трек (`blinkmusic.cc/t/<7 символов>`); без сети или со старым сервером длинная ссылка. */
    suspend fun trackLink(t: Track): String {
        val id = t.id
        if (id.matches(Regex("^\\d{1,15}$"))) return longTrackLink(t)
        try {
            val body = buildJsonObject {
                put("id", JsonPrimitive(id))
                put("title", JsonPrimitive(t.title))
                put("artist", JsonPrimitive(t.artist))
                put("artwork", JsonPrimitive(t.artwork))
            }
            val res = client.newCall(Request.Builder().url("${config.base}/api/share/track").post(BlinkJson.encodeToString(JsonObject.serializer(), body).toRequestBody(jsonType)).build()).text()
            val code = if (res.code == 200) parseObject(res.text)?.str("code") else null
            if (code != null && SHORT.matches(code)) return "${config.base}/t/$code"
        } catch (_: IOException) {
        }
        return longTrackLink(t)
    }

    fun longTrackLink(t: Track): String {
        val id = java.net.URLEncoder.encode(t.id, "UTF-8").replace("+", "%20")
        if (t.id.matches(Regex("^\\d{1,15}$")) || t.id.matches(Regex("^b:[0-9a-f-]{36}$"))) return "${config.base}/t/$id"
        val q = "n=" + java.net.URLEncoder.encode(t.title, "UTF-8") + "&a=" + java.net.URLEncoder.encode(t.artist, "UTF-8")
        return "${config.base}/t/$id?$q"
    }

    /** Что играет по короткому коду (`/t/Xk3p9aQ`); null, если код не найден. */
    suspend fun resolveTrack(code: String): SharedTrack? {
        val res = client.newCall(Request.Builder().url("${config.base}/api/share/track/$code").header("Accept", "application/json").build()).text()
        if (res.code != 200) return null
        val o = parseObject(res.text) ?: return null
        return SharedTrack(o.str("id") ?: return null, o.str("title").orEmpty(), o.str("artist").orEmpty(), o.str("artwork").orEmpty())
    }

    companion object {
        val SHORT = Regex("^[2-9a-km-np-zA-HJ-NP-Z]{7}$")
        private const val ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"

        fun newCode(): String = buildString { repeat(10) { append(ALPHABET[java.util.concurrent.ThreadLocalRandom.current().nextInt(ALPHABET.length)]) } }

        fun link(code: String) = "https://blinkmusic.cc/p/$code"
    }
}

/** Ссылки, которые открывают приложение: что внутри и какой код. */
sealed interface DeepLink {
    data class Room(val code: String) : DeepLink
    data class Friend(val code: String) : DeepLink
    data class Playlist(val code: String) : DeepLink
    /** `t` — код или id; для длинных ссылок рядом название и исполнитель. */
    data class Track(val ref: String, val title: String = "", val artist: String = "") : DeepLink
    data class Artist(val who: String) : DeepLink

    companion object {
        private val HOSTS = Regex("^https?://(?:www\\.|t\\.)?blinkmusic\\.cc", RegexOption.IGNORE_CASE)

        fun query(url: String, key: String): String? {
            val q = url.substringAfter('?', "").substringBefore('#')
            for (part in q.split('&')) {
                val k = part.substringBefore('=')
                if (k == key) return runCatching { java.net.URLDecoder.decode(part.substringAfter('=', ""), "UTF-8") }.getOrNull()?.takeIf { it.isNotEmpty() }
            }
            return null
        }

        /** Разбирает ссылку из браузера, мессенджера или `blink://`. null, если это не наша ссылка. */
        fun parse(url: String?): DeepLink? {
            if (url.isNullOrBlank()) return null
            query(url, "together")?.let { return Room(it) }
            query(url, "friend")?.let { return Friend(it) }
            query(url, "playlist")?.let { return Playlist(it) }
            query(url, "artist")?.let { return Artist(it.lowercase()) }
            query(url, "track")?.let { return Track(it, query(url, "n").orEmpty(), query(url, "a").orEmpty()) }
            val path = HOSTS.find(url)?.let { url.substring(it.range.last + 1).substringBefore('?').substringBefore('#') } ?: return null
            val seg = path.trim('/').split('/')
            val host = url.substringAfter("://").substringBefore('/').lowercase()
            if (host == "t.blinkmusic.cc" && seg.size == 1 && seg[0].isNotEmpty()) return Track(decode(seg[0]))
            if (seg.size < 2) return null
            val v = decode(seg[1])
            return when (seg[0]) {
                "r" -> if (Regex("^[A-Za-z0-9_-]{4,40}$").matches(v)) Room(v) else null
                "p" -> if (Regex("^[A-Za-z0-9]+$").matches(v)) Playlist(v) else null
                "u" -> if (Regex("^[A-Za-z0-9_.-]+$").matches(v)) Artist(v.lowercase()) else null
                "t" -> Track(v, query(url, "n").orEmpty(), query(url, "a").orEmpty())
                else -> null
            }
        }

        private fun decode(s: String) = runCatching { java.net.URLDecoder.decode(s.replace("+", "%2B"), "UTF-8") }.getOrDefault(s)
    }
}
