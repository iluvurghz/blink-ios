package app.blink.core.library

import app.blink.core.model.Track
import app.blink.core.net.BlinkApi
import app.blink.core.net.BlinkConfig
import app.blink.core.net.BlinkJson
import app.blink.core.net.arr
import app.blink.core.net.obj
import app.blink.core.net.parseObject
import app.blink.core.net.str
import app.blink.core.net.text
import app.blink.core.net.withCallTimeout
import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request

/** Строка списка для переноса: исполнитель и название. */
data class TrackRef(val artist: String, val title: String)

enum class ImportSource(val title: String, val api: String, val pattern: Regex, val closed: String) {
    Spotify(
        "Spotify", "spotify",
        Regex("open\\.spotify\\.com/(?:intl-[a-z-]+/)?(?:playlist|album)/[A-Za-z0-9]+|spotify:(?:playlist|album):[A-Za-z0-9]+"),
        "Spotify не отдал этот плейлист. Открытые плейлисты и альбомы переносятся, а закрытые и подборки самого Spotify нет",
    ),
    Yandex(
        "Яндекс Музыки", "yandex",
        Regex("(?:https?://)?music\\.yandex\\.[a-z]{2,3}/(?:users/[^/\\s]+/(?:playlists/\\d+|tracks)|playlists/[A-Za-z0-9.-]+|album/\\d+(?:/track/\\d+)?)"),
        "Яндекс не отдал этот плейлист. Сделайте его публичным (для «Мне нравится» откройте профиль в настройках Яндекс Музыки) и попробуйте ещё раз",
    ),
}

class ImportException(message: String) : Exception(message)

data class ImportRun(val title: String, val found: List<Track>, val missed: List<TrackRef>, val total: Int)

/** Перенос музыки: ссылка Spotify/Яндекс, CSV из TuneMyMusic или список «Артист — Название». Порт `Import.jsx`. */
class Importer(http: OkHttpClient, private val config: BlinkConfig, private val api: BlinkApi) {
    private val client = http.withCallTimeout(40)

    /** Читает список по ссылке через сервер Blink. */
    suspend fun read(src: ImportSource, link: String): Pair<String, List<TrackRef>> {
        val url = config.base.toHttpUrl().newBuilder().addPathSegments("api/${src.api}/list").addQueryParameter("url", link).build()
        val res = try {
            client.newCall(Request.Builder().url(url).header("Accept", "application/json").build()).text()
        } catch (_: IOException) {
            throw ImportException("Не получилось прочитать ссылку, попробуйте ещё раз")
        }
        val o = parseObject(res.text)
        val items = o?.get("items").arr()
        if (res.code in 200..299 && items != null && items.isNotEmpty()) {
            val refs = items.mapNotNull { e -> e.obj()?.let { TrackRef(it.str("artist").orEmpty(), it.str("title").orEmpty()) }?.takeIf { r -> r.title.isNotEmpty() } }
            return (o?.str("name") ?: "") to refs
        }
        if (res.code == 404 || (res.code in 200..299 && items != null)) throw ImportException(src.closed)
        if (src == ImportSource.Yandex) throw ImportException("Яндекс Музыка не ответила. Если вы не в России, она может быть недоступна: попробуйте ещё раз или загрузите CSV из TuneMyMusic")
        throw ImportException("Не получилось прочитать ссылку, попробуйте ещё раз")
    }

    /**
     * Весь перенос: читаем (если ссылка), ищем каждый трек в четыре потока, `progress(сделано, всего)` по ходу.
     * Бросает [ImportException] с текстом для человека.
     */
    suspend fun run(text: String, progress: (Int, Int) -> Unit = { _, _ -> }): ImportRun {
        val src = sourceOf(text)
        var title = ""
        val list: List<TrackRef>
        if (src != null) {
            val (name, refs) = read(src, src.pattern.find(text)!!.value)
            title = name
            list = refs
        } else {
            list = parseList(text)
        }
        val refs = list.take(MAX)
        if (refs.isEmpty()) throw ImportException("Не нашёл треков в тексте")
        val found = arrayOfNulls<Track>(refs.size)
        val next = AtomicInteger(0)
        val done = AtomicInteger(0)
        coroutineScope {
            List(4) {
                async {
                    while (true) {
                        val i = next.getAndIncrement()
                        if (i >= refs.size) break
                        found[i] = match(refs[i])
                        progress(done.incrementAndGet(), refs.size)
                    }
                }
            }.awaitAll()
        }
        val hits = found.filterNotNull().distinctBy { it.id }
        val missed = refs.filterIndexed { i, _ -> found[i] == null }
        return ImportRun(title.ifBlank { "Перенесённое" }.take(80), hits, missed, refs.size)
    }

    suspend fun match(ref: TrackRef): Track? =
        try {
            pick(ref, api.search("${ref.artist} ${ref.title}".trim()))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }

    companion object {
        const val MAX = 2000

        fun sourceOf(text: String): ImportSource? = ImportSource.entries.firstOrNull { it.pattern.containsMatchIn(text) }

        fun norm(s: String): String = s.lowercase().replace(Regex("[^\\p{L}\\p{N}]+"), " ").trim()

        /** Лучший трек из выдачи: артист и название, иначе хотя бы артист. */
        fun pick(ref: TrackRef, tracks: List<Track>): Track? {
            val a = norm(ref.artist.split(',', '&').firstOrNull().orEmpty())
            val t = norm(ref.title.replace(Regex("\\(.*?\\)"), ""))
            return tracks.firstOrNull { norm(it.artist).contains(a) && norm(it.title).contains(t) } ?: tracks.firstOrNull { norm(it.artist).contains(a) }
        }

        private fun splitCsv(line: String): List<String> {
            val out = ArrayList<String>()
            val cur = StringBuilder()
            var q = false
            var i = 0
            while (i < line.length) {
                val c = line[i]
                if (c == '"') {
                    if (q && i + 1 < line.length && line[i + 1] == '"') {
                        cur.append('"')
                        i++
                    } else {
                        q = !q
                    }
                } else if ((c == ',' || c == ';') && !q) {
                    out.add(cur.toString().trim())
                    cur.clear()
                } else {
                    cur.append(c)
                }
                i++
            }
            out.add(cur.toString().trim())
            return out
        }

        /** CSV из TuneMyMusic или строки «Артист — Название». */
        fun parseList(text: String): List<TrackRef> {
            val lines = text.split(Regex("\\r?\\n")).map { it.trim() }.filter { it.isNotEmpty() }
            if (lines.isEmpty()) return emptyList()
            val head = splitCsv(lines[0]).map { it.lowercase() }
            val ti = head.indexOfFirst { Regex("track|title|трек|назв").containsMatchIn(it) }
            val ai = head.indexOfFirst { Regex("artist|исполн|артист").containsMatchIn(it) }
            if (ti >= 0 && ai >= 0 && ti != ai) {
                return lines.drop(1).map(::splitCsv).map { r -> TrackRef(r.getOrNull(ai).orEmpty(), r.getOrNull(ti).orEmpty()) }.filter { it.title.isNotEmpty() }
            }
            return lines.map { l ->
                val m = l.split(Regex("\\s+[-–—]\\s+"))
                if (m.size >= 2) TrackRef(m[0], m.drop(1).joinToString(" - ")) else TrackRef("", l)
            }.filter { it.title.isNotEmpty() }
        }
    }
}
