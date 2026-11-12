package app.blink.core.lyrics

import app.blink.core.library.SharedError
import app.blink.core.model.Track
import app.blink.core.net.BlinkConfig
import app.blink.core.net.BlinkJson
import app.blink.core.net.TokenProvider
import app.blink.core.net.arr
import app.blink.core.net.bool
import app.blink.core.net.long
import app.blink.core.net.obj
import app.blink.core.net.str
import app.blink.core.net.text
import app.blink.core.net.withCallTimeout
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request

/** Слово с собственным временем (TTML). `from`/`to`: место слова в тексте строки (UTF-16, как на сайте). */
data class LyricWord(val t: Double, val end: Double? = null, val text: String, val from: Int? = null, val to: Int? = null)

/** Строка текста со временем в секундах (как `{ t, end, text, words }` на сайте). */
data class LyricLine(val t: Double, val end: Double? = null, val text: String, val words: List<LyricWord>? = null)

/** Что нашлось: строки со временем, простой текст или «инструментал». */
sealed class LyricsData {
    data class Synced(val lines: List<LyricLine>) : LyricsData()
    data class Plain(val lines: List<String>) : LyricsData()
    object Instrumental : LyricsData()

    val texts: List<String>
        get() = when (this) {
            is Synced -> lines.map { it.text }
            is Plain -> lines
            Instrumental -> emptyList()
        }

    /** Текст в основном кириллицей: перевод не нужен. */
    val isRussian: Boolean
        get() {
            val s = texts.joinToString(" ").lowercase()
            val cyr = s.count { it in 'а'..'я' || it == 'ё' }
            val lat = s.count { it in 'a'..'z' }
            return cyr > lat
        }
}

/** Сервис текстов не ответил: «нет текста» не запоминаем, можно повторить. */
class LyricsUnavailable : IOException("lyrics unavailable")

/** Кусок строки для караоке: слово со временем или пробел/хвост без него. */
data class KaraokeSeg(val text: String, val t: Double? = null, val end: Double? = null) {
    /** Насколько слово уже «залито» к моменту [time]: 0…1. */
    fun progress(time: Double): Double {
        val s = t ?: return 0.0
        val e = end ?: return 0.0
        return ((time - s) / max(0.05, e - s)).coerceIn(0.0, 1.0)
    }
}

/** Строка караоке: обычная или «• • •» на паузе. */
data class KaraokeRow(val t: Double, val end: Double, val gap: Boolean, val text: String, val segs: List<KaraokeSeg>)

/** Разметка караоке, как `buildLines` и `lineWords` в Stage.jsx. */
object Karaoke {
    private val SPACES = Regex("""(\s+)""")

    fun build(synced: List<LyricLine>): List<KaraokeRow> {
        val out = ArrayList<KaraokeRow>()
        if (synced.isNotEmpty() && synced[0].t > 4) out.add(KaraokeRow(0.0, synced[0].t, true, "", emptyList()))
        synced.forEachIndexed { i, l ->
            val next = synced.getOrNull(i + 1)
            val nextT = next?.t ?: (l.t + 6)
            if (l.text.isEmpty()) {
                if (nextT - l.t > 3) out.add(KaraokeRow(l.t, nextT, true, "", emptyList()))
                return@forEachIndexed
            }
            val end = l.end?.takeIf { it > 0 && it < nextT } ?: nextT
            out.add(KaraokeRow(l.t, end, false, l.text, words(l.copy(end = end))))
            if (next != null && nextT - end > 4) out.add(KaraokeRow(end, nextT, true, "", emptyList()))
        }
        return out
    }

    /** Слова строки: у TTML свои времена, у обычной строки слова растянуты на всю строку (длинные дольше). */
    fun words(l: LyricLine): List<KaraokeSeg> {
        val text = l.text
        val lineEnd = l.end ?: (l.t + 6)
        val timed = l.words.orEmpty().filter { it.from != null && it.to != null }
        if (timed.isNotEmpty()) {
            val out = ArrayList<KaraokeSeg>()
            var at = 0
            timed.forEachIndexed { k, w ->
                val from = w.from!!
                val to = w.to!!
                if (from > at) out.add(KaraokeSeg(text.substring(at, from)))
                out.add(KaraokeSeg(text.substring(from, to), w.t, w.end ?: timed.getOrNull(k + 1)?.t ?: lineEnd))
                at = to
            }
            if (at < text.length) out.add(KaraokeSeg(text.substring(at)))
            return out
        }
        val parts = splitKeepingSpaces(text)
        val weight = max(1, parts.sumOf { if (it.isBlank()) 0 else it.length + 1 })
        val span = max(0.6, min(lineEnd - l.t - 0.12, max(3.0, text.length * 0.25)))
        var t = l.t
        return parts.map { s ->
            if (s.isBlank()) {
                KaraokeSeg(s)
            } else {
                val d = span * (s.length + 1) / weight
                val seg = KaraokeSeg(s, t, t + d)
                t += d
                seg
            }
        }
    }

    internal fun splitKeepingSpaces(text: String): List<String> {
        val out = ArrayList<String>()
        var at = 0
        for (m in SPACES.findAll(text)) {
            if (m.range.first > at) out.add(text.substring(at, m.range.first))
            out.add(m.value)
            at = m.range.last + 1
        }
        if (at < text.length) out.add(text.substring(at))
        return out
    }

    /** Строка, что звучит сейчас, или -1 до первой. */
    fun active(rows: List<KaraokeRow>, t: Double): Int {
        var i = -1
        for (k in rows.indices) {
            if (rows[k].t <= t) i = k else break
        }
        return i
    }

    /** Обратный отсчёт 3·2·1 в конце паузы, 0 если не нужен. */
    fun countdown(rows: List<KaraokeRow>, active: Int, t: Double): Int {
        if (active !in rows.indices || !rows[active].gap || active + 1 >= rows.size) return 0
        val left = rows[active + 1].t - t
        return if (left > 0 && left <= 3) ceil(left).toInt() else 0
    }
}

/** TTML (Apple-style): строки из `<p begin end>`, слова из `<span begin>` внутри (lib/ttml.js). */
object Ttml {
    private val P = Regex("""<(?:[\w-]+:)?p\b([^>]*)>([\s\S]*?)</(?:[\w-]+:)?p>""")
    private val SPAN = Regex("""<(?:[\w-]+:)?span\b([^>]*)>([^<]*)</(?:[\w-]+:)?span>""")
    private val TAG = Regex("""<[^>]+>""")
    private val WS = Regex("""\s+""")
    private val UNIT = Regex("""^(\d+(?:\.\d+)?)(h|ms|m|s)$""")
    private val CLOCK = Regex("""^(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$""")
    private val NUM_ENTITY = Regex("""&#(x?)([0-9a-fA-F]+);""")

    fun seconds(raw: String?): Double? {
        val v = raw?.trim().orEmpty()
        if (v.isEmpty()) return null
        UNIT.matchEntire(v)?.let { m ->
            val n = m.groupValues[1].toDouble()
            return when (m.groupValues[2]) {
                "h" -> n * 3600
                "m" -> n * 60
                "ms" -> n * 0.001
                else -> n
            }
        }
        CLOCK.matchEntire(v)?.let { m ->
            return (m.groupValues[1].toDoubleOrNull() ?: 0.0) * 3600 + m.groupValues[2].toDouble() * 60 + m.groupValues[3].toDouble()
        }
        return v.toDoubleOrNull()
    }

    fun parse(xml: String): List<LyricLine>? {
        val lines = ArrayList<LyricLine>()
        for (pm in P.findAll(xml)) {
            val attrs = pm.groupValues[1]
            val t = seconds(attr(attrs, "begin")) ?: continue
            val end = seconds(attr(attrs, "end"))
            val inner = pm.groupValues[2]
            val words = ArrayList<LyricWord>()
            for (sm in SPAN.findAll(inner)) {
                val wt = seconds(attr(sm.groupValues[1], "begin")) ?: continue
                words.add(LyricWord(wt, seconds(attr(sm.groupValues[1], "end")), decode(sm.groupValues[2])))
            }
            val text = WS.replace(decode(TAG.replace(inner, "")), " ").trim()
            if (text.isEmpty()) continue
            var at = 0
            for (i in words.indices) {
                val w = words[i].text.trim()
                if (w.isEmpty()) continue
                val idx = text.indexOf(w, at)
                if (idx >= 0) {
                    at = idx + w.length
                    words[i] = words[i].copy(from = idx, to = at)
                }
            }
            lines.add(LyricLine(t, end, text, words.ifEmpty { null }))
        }
        lines.sortBy { it.t }
        return lines.ifEmpty { null }
    }

    private fun attr(attrs: String, name: String): String? =
        Regex("""(?:^|\s)$name\s*=\s*"([^"]*)"""").find(attrs)?.groupValues?.get(1)
            ?: Regex("""(?:^|\s)$name\s*=\s*'([^']*)'""").find(attrs)?.groupValues?.get(1)

    internal fun decode(s: String): String {
        if (!s.contains('&')) return s
        val nums = NUM_ENTITY.replace(s) { m ->
            val n = m.groupValues[2].toIntOrNull(if (m.groupValues[1] == "x") 16 else 10)
            if (n != null && Character.isValidCodePoint(n)) String(Character.toChars(n)) else m.value
        }
        return nums.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'")
            .replace("&nbsp;", " ").replace("&amp;", "&")
    }
}

/**
 * Тексты песен, как `api.lyrics` + `useLyrics` на сайте: свои треки Blink (TTML, LRC, текст), остальные через LRCLIB
 * и lyrics.ovh на сервере Blink. Найденное держим в памяти на время работы.
 */
class LyricsApi(http: OkHttpClient, private val config: BlinkConfig, private val tokens: TokenProvider?) {
    private val quick = http.withCallTimeout(7)
    private val slow = http.withCallTimeout(10)
    private val cache = ConcurrentHashMap<String, Holder>()
    private val translations = ConcurrentHashMap<String, Map<String, String>>()

    private class Holder(val data: LyricsData?)

    private class Status(val code: Int) : IOException("HTTP $code")

    /** Уже найденное для трека: null — ещё не искали; Holder(null) — текста нет. */
    fun cachedOrNull(id: String): Pair<Boolean, LyricsData?> = cache[id]?.let { true to it.data } ?: (false to null)

    suspend fun load(track: Track): LyricsData? {
        cache[track.id]?.let { return it.data }
        val data = fetch(track)
        cache[track.id] = Holder(data)
        return data
    }

    private suspend fun fetch(track: Track): LyricsData? {
        if (track.source == Track.SOURCE_BLINK) {
            val lic = track.lic
            if (!lic.isNullOrEmpty()) ttml(lic)?.let { Ttml.parse(it) }?.let { return LyricsData.Synced(it) }
            if (!track.lrc.isNullOrEmpty()) return LyricsData.Synced(fromLrc(track.lrc))
            if (!track.lyrics.isNullOrEmpty()) return LyricsData.Plain(lines(track.lyrics))
            return null
        }
        val title = cleanTitle(track.title)
        val main = mainArtist(track.artist)
        val q = ArrayList<Pair<String, String>>()
        q.add("track_name" to title)
        q.add("artist_name" to main)
        if (track.album.isNotEmpty()) q.add("album_name" to track.album)
        if (track.duration > 0) q.add("duration" to track.duration.toString())
        var down = false
        var plain: LyricsData? = null
        try {
            val got = pick(json("api/lrclib/get", q).obj())
            if (got is LyricsData.Synced || got == LyricsData.Instrumental) return got
            plain = got
        } catch (e: Status) {
            down = e.code != 404
        } catch (_: IOException) {
            down = true
        } catch (_: Exception) {
            // ответ не JSON: считаем, что текста нет
        }
        if (!down) {
            try {
                val list = json("api/lrclib/search", listOf("track_name" to title, "artist_name" to track.artist)).arr().orEmpty().mapNotNull { it.obj() }
                if (list.isNotEmpty()) {
                    val nt = norm(title)
                    val best = list.mapIndexed { i, d ->
                        var s = 0.0
                        if (norm(d.str("trackName").orEmpty()) == nt) s += 5
                        if (!d.str("syncedLyrics").isNullOrEmpty()) s += 4
                        val dd = d.long("duration") ?: d.str("duration")?.toDoubleOrNull()?.toLong()
                        if (track.duration > 0 && dd != null && dd > 0) s -= min(6.0, abs(dd - track.duration) / 2.0)
                        Triple(d, s, i)
                    }.sortedWith(compareByDescending<Triple<JsonObject, Double, Int>> { it.second }.thenBy { it.third }).first()
                    pick(best.first)?.let { return it }
                }
            } catch (e: Status) {
                down = e.code != 404
            } catch (_: IOException) {
                down = true
            } catch (_: Exception) {
            }
        }
        if (plain != null) return plain
        try {
            val d = json("api/lyricsovh", listOf("artist" to main, "title" to title)).obj()
            val text = d?.str("lyrics")?.replace(Regex("""^Paroles de la chanson.*\r?\n"""), "")?.trim()
            if (!text.isNullOrEmpty()) return LyricsData.Plain(lines(text))
        } catch (_: Exception) {
        }
        if (down) throw LyricsUnavailable()
        return null
    }

    private suspend fun json(path: String, q: List<Pair<String, String>>): JsonElement? {
        val b = "${config.base}/$path".toHttpUrlOrNull()?.newBuilder() ?: throw Status(400)
        for ((k, v) in q) b.addQueryParameter(k, v)
        val res = quick.newCall(Request.Builder().url(b.build()).header("Accept", "application/json").build()).text()
        if (res.code !in 200..299) throw Status(res.code)
        return BlinkJson.parseToJsonElement(res.text)
    }

    private suspend fun ttml(lic: String): String? = try {
        val b = Request.Builder().url("${config.base}/api/tracks/$lic/ttml")
        tokens?.accessToken()?.let { b.header("Authorization", "Bearer $it") }
        val res = slow.newCall(b.build()).text()
        if (res.code in 200..299 && res.text.isNotBlank()) res.text else null
    } catch (_: Exception) {
        null
    }

    /** Перевод строк на русский: исходная строка → перевод. Пусто, если текст и так русский. */
    suspend fun translate(id: String, texts: List<String>): Map<String, String> {
        translations[id]?.let { return it }
        val uniq = texts.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        val lang = guessLang(uniq)
        if (lang == "ru" || uniq.isEmpty()) return emptyMap()
        val map = HashMap<String, String>()
        var backup = false
        for (part in uniq.chunked(25)) {
            var out: List<String>? = null
            if (!backup) {
                out = try {
                    google(part).takeIf { it.size == part.size }
                } catch (_: Exception) {
                    null
                }
                if (out == null) backup = true
            }
            if (out == null) out = part.map { t -> try { mymemory(listOf(t), lang).firstOrNull().orEmpty() } catch (_: Exception) { "" } }
            part.forEachIndexed { k, t -> out.getOrNull(k)?.takeIf { it.isNotEmpty() }?.let { map[t] = it } }
        }
        if (map.isEmpty()) throw SharedError("Перевод сейчас недоступен")
        translations[id] = map
        return map
    }

    private suspend fun google(lines: List<String>): List<String> {
        val d = json("api/translate/google", listOf("q" to lines.joinToString("\n"))).arr() ?: throw IOException("translate")
        val segs = d.firstOrNull().arr() ?: throw IOException("translate")
        val text = segs.joinToString("") { s -> ((s as? JsonArray)?.firstOrNull() as? JsonPrimitive)?.takeIf { it.isString }?.content.orEmpty() }
        return text.split("\n").map { it.trim() }
    }

    private suspend fun mymemory(lines: List<String>, from: String): List<String> {
        val d = json("api/translate/mymemory", listOf("q" to lines.joinToString("\n"), "from" to from)).obj() ?: throw IOException("translate")
        val rd = d["responseData"].obj() ?: throw IOException("translate")
        val status = d.long("responseStatus") ?: d.str("responseStatus")?.toLongOrNull()
        if (status != 200L) throw IOException("translate")
        return rd.str("translatedText").orEmpty().split(Regex("\r?\n")).map { it.trim() }
    }

    companion object {
        internal fun pick(d: JsonObject?): LyricsData? {
            d ?: return null
            if (d.bool("instrumental") == true) return LyricsData.Instrumental
            d.str("syncedLyrics")?.takeIf { it.isNotEmpty() }?.let { return LyricsData.Synced(fromLrc(it)) }
            d.str("plainLyrics")?.takeIf { it.isNotEmpty() }?.let { return LyricsData.Plain(lines(it)) }
            return null
        }

        /** Слова из расширенного LRC сайт отдельно не подсвечивает: строка растягивается целиком. */
        fun fromLrc(text: String): List<LyricLine> = Lrc.parse(text).map { LyricLine(it.timeMs / 1000.0, null, it.text) }

        internal fun lines(text: String): List<String> = text.split(Regex("\r?\n"))

        internal fun cleanTitle(title: String): String = title.replaceFirst(Regex("""\s*\((feat|with|prod)\.?[^)]*\)""", RegexOption.IGNORE_CASE), "").trim()

        internal fun mainArtist(artist: String): String = artist.split(Regex(",|&| feat", RegexOption.IGNORE_CASE))[0].trim()

        internal fun norm(s: String): String = s.lowercase()
            .replace(Regex("""\(.*?\)|\[.*?]"""), "")
            .replace(Regex("""feat\..*$"""), "")
            .replace(Regex("""[^\p{L}\p{N} ]"""), " ")
            .replace(Regex("""\s+"""), " ")
            .trim()

        internal fun guessLang(texts: List<String>): String {
            val s = texts.joinToString(" ")
            val cyr = s.count { it in 'Ѐ'..'ӿ' }
            val lat = s.count { it in 'a'..'z' || it in 'A'..'Z' }
            if (cyr > lat) return "ru"
            val low = s.lowercase()
            if (low.any { it in "ñ¿¡" }) return "es"
            if (low.any { it in "äöüß" }) return "de"
            if (low.any { it in "àâçéèêëîïôûùœ" }) return "fr"
            return "en"
        }
    }
}
