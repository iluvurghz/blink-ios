package app.blink.core.library

import app.blink.core.net.BlinkConfig
import app.blink.core.net.BlinkJson
import app.blink.core.net.arr
import app.blink.core.net.obj
import app.blink.core.net.str
import app.blink.core.net.text
import app.blink.core.net.withCallTimeout
import java.util.concurrent.ConcurrentHashMap
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request

data class SimilarTrack(val artist: String, val title: String)

data class SimilarArtist(val name: String, val match: Double)

/** Last.fm через наш сервер (`/api/lastfm`): ключ лежит на сервере. Без сети или ключа отвечает «ничего». */
class LastfmApi(http: OkHttpClient, private val config: BlinkConfig) {
    private val client = http.withCallTimeout(12)
    private val cache = ConcurrentHashMap<String, Any>()

    private suspend fun call(params: Map<String, String>): kotlinx.serialization.json.JsonObject? = try {
        val url = "${config.base}/api/lastfm".toHttpUrl().newBuilder().apply { params.forEach { (k, v) -> addQueryParameter(k, v) } }.build()
        val res = client.newCall(Request.Builder().url(url).header("Accept", "application/json").build()).text()
        if (res.code !in 200..299) null else BlinkJson.parseToJsonElement(res.text).obj()?.takeIf { it["error"] == null }
    } catch (_: Exception) {
        null
    }

    @Suppress("UNCHECKED_CAST")
    private suspend fun <T : Any> cached(key: String, load: suspend () -> T?): T? {
        (cache[key] as? T)?.let { return it }
        val v = load() ?: return null
        cache[key] = v
        return v
    }

    /** Слушатели артиста за всё время; null, если Last.fm не знает такого (или подменил тёзкой). */
    suspend fun listeners(artist: String): Long? = cached("l:$artist") {
        val want = mainName(artist)
        val d = call(mapOf("method" to "artist.getinfo", "artist" to want)) ?: return@cached null
        val a = d["artist"].obj() ?: return@cached null
        if (squash(a.str("name").orEmpty()) != squash(want)) return@cached null
        a["stats"].obj()?.str("listeners")?.toLongOrNull()
    }

    suspend fun similarTracks(artist: String, title: String, limit: Int = 12): List<SimilarTrack> = cached("st:$artist:$title") {
        val d = call(mapOf("method" to "track.getsimilar", "artist" to mainName(artist), "track" to cleanTitle(title), "limit" to limit.toString())) ?: return@cached null
        d["similartracks"].obj()?.get("track").arr().orEmpty().mapNotNull { e ->
            val t = e.obj() ?: return@mapNotNull null
            SimilarTrack(t["artist"].obj()?.str("name") ?: return@mapNotNull null, t.str("name") ?: return@mapNotNull null)
        }
    }.orEmpty()

    suspend fun similarArtists(name: String, limit: Int = 15): List<SimilarArtist> = cached("sa:$name") {
        val d = call(mapOf("method" to "artist.getsimilar", "artist" to mainName(name), "limit" to limit.toString())) ?: return@cached null
        val own = mainName(name).lowercase()
        d["similarartists"].obj()?.get("artist").arr().orEmpty().mapNotNull { e ->
            val a = e.obj() ?: return@mapNotNull null
            val n = a.str("name") ?: return@mapNotNull null
            SimilarArtist(n, a.str("match")?.toDoubleOrNull() ?: 0.0)
        }.filter { it.match >= 0.35 && !it.name.lowercase().contains(own) }
    }.orEmpty()

    companion object {
        private val SPLIT = Regex("""\s*(?:,|&|\sfeat\.?\s|\sft\.?\s|\sx\s)\s*""", RegexOption.IGNORE_CASE)
        private val FEAT = Regex("""\s*[(\[](feat|with|prod)[^)\]]*[)\]]""", RegexOption.IGNORE_CASE)

        fun mainName(s: String): String = s.split(SPLIT).first().trim()
        fun cleanTitle(s: String): String = s.replace(FEAT, "").trim()
        private fun squash(s: String) = s.lowercase().filter { it.isLetterOrDigit() }
    }
}
