package app.blink.core.wave

import app.blink.core.model.Track
import app.blink.core.net.BlinkConfig
import app.blink.core.net.arr
import app.blink.core.net.bool
import app.blink.core.net.int
import app.blink.core.net.long
import app.blink.core.net.obj
import app.blink.core.net.parseObject
import app.blink.core.net.str
import app.blink.core.net.text
import app.blink.core.net.withCallTimeout
import java.io.IOException
import kotlinx.serialization.json.JsonObject
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request

/** Запросы Вспышки к серверу Blink (без входа). Формы ответов сняты с `waveRoute.js` и `charts.js` сайта. */
class WaveApi(http: OkHttpClient, private val config: BlinkConfig) : WaveSource {
    private val client = http.withCallTimeout(15)

    private suspend fun get(path: String, vararg query: Pair<String, String>): JsonObject {
        val url = config.base.toHttpUrl().newBuilder().addPathSegments(path).apply { query.forEach { addQueryParameter(it.first, it.second) } }.build()
        val res = client.newCall(Request.Builder().url(url).header("Accept", "application/json").build()).text()
        if (res.code !in 200..299) throw IOException("$path ${res.code}")
        return parseObject(res.text) ?: throw IOException("$path: ответ не JSON")
    }

    override suspend fun pool(seeds: List<String>): PoolResult {
        if (seeds.isEmpty()) return PoolResult(emptyList(), emptyList())
        val o = get("api/wave/pool", "seeds" to seeds.joinToString("|"), "n" to seeds.size.toString())
        val tracks = o["tracks"].arr().orEmpty().mapNotNull { e ->
            val r = e.obj() ?: return@mapNotNull null
            val t = poolTrack(r) ?: return@mapNotNull null
            WaveCandidate(t, r.str("src"), r.str("seed"), r.int("hits") ?: 1)
        }
        val genres = o["seedGenre"].arr().orEmpty().mapNotNull { e ->
            val r = e.obj() ?: return@mapNotNull null
            SeedGenre(r.str("q") ?: return@mapNotNull null, r.str("genre").orEmpty(), r.str("id"))
        }
        return PoolResult(tracks, genres)
    }

    override suspend fun genres(items: List<String>): Map<String, String> {
        if (items.isEmpty()) return emptyMap()
        val o = get("api/wave/genres", "items" to items.take(16).joinToString("|"))
        val g = o["genres"].obj() ?: return emptyMap()
        return g.keys.associateWith { g.str(it).orEmpty() }
    }

    override suspend fun similarIds(seed: String): SimilarResult {
        val o = get("api/wave/similar-ids", "seed" to seed)
        return SimilarResult(o["ids"].arr().orEmpty().mapNotNull { (it as? kotlinx.serialization.json.JsonPrimitive)?.content }, o.str("genre").orEmpty())
    }

    override suspend fun topChart(): List<Track> =
        get("api/charts/top")["items"].arr().orEmpty().mapNotNull { e -> e.obj()?.get("track").obj()?.let(::chartTrack) }

    override suspend fun periodChart(kind: String): List<Track> =
        get("api/charts/$kind")["items"].arr().orEmpty().mapNotNull { e -> e.obj()?.let(::periodTrack) }

    internal fun poolTrack(r: JsonObject): Track? {
        val id = r.str("id") ?: return null
        val title = r.str("title") ?: return null
        val artist = r.str("artist") ?: return null
        return Track(
            id = id,
            title = title,
            artist = artist,
            artistId = r.str("artistId"),
            album = r.str("album").orEmpty(),
            albumId = r.str("albumId"),
            artwork = r.str("artwork").orEmpty(),
            duration = r.int("duration") ?: 0,
            explicit = r.bool("explicit") == true,
            year = r.str("year").orEmpty(),
            genre = r.str("genre").orEmpty(),
            released = r.str("released"),
            source = r.str("source"),
        )
    }

    /** Элемент главного чарта Яндекса (`track`) → трек; `released` берём из альбома. */
    internal fun chartTrack(t: JsonObject): Track? {
        val id = t.str("id") ?: return null
        val title = t.str("title") ?: return null
        val artists = t["artists"].arr().orEmpty().mapNotNull { it.obj()?.str("name") }
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
            released = album?.str("releaseDate"),
        )
    }

    /** Элемент недельного или месячного чарта новинок (id `cp…`, длительности и жанра в нём нет). */
    internal fun periodTrack(x: JsonObject): Track? {
        val id = x.str("id") ?: return null
        val title = x.str("trackNameStr") ?: return null
        val artist = x.str("artistNameStr") ?: x["artistNames"].arr()?.mapNotNull { (it as? kotlinx.serialization.json.JsonPrimitive)?.content }?.joinToString(", ")
        if (artist.isNullOrEmpty()) return null
        return Track(id = "cp$id", source = "chart", title = title, artist = artist, artwork = x.str("coverUrl").orEmpty())
    }
}
