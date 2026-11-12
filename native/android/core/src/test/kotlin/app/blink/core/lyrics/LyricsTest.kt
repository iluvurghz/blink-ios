package app.blink.core.lyrics

import app.blink.core.model.Track
import app.blink.core.net.BlinkConfig
import app.blink.core.ui.ArtUrl
import app.blink.core.ui.Hsl
import app.blink.core.ui.Palette
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest

private fun serve(handler: (RecordedRequest) -> MockResponse, block: suspend (LyricsApi, List<RecordedRequest>) -> Unit) = runBlocking {
    val server = MockWebServer()
    val seen = java.util.concurrent.CopyOnWriteArrayList<RecordedRequest>()
    server.dispatcher = object : Dispatcher() {
        override fun dispatch(request: RecordedRequest): MockResponse {
            seen.add(request)
            return handler(request)
        }
    }
    server.start()
    try {
        val base = server.url("/").toString().trimEnd('/')
        block(LyricsApi(OkHttpClient(), BlinkConfig(baseUrl = base, supabaseUrl = base), { "tok" }), seen)
    } finally {
        server.shutdown()
    }
    Unit
}

class LyricsTest {
    @Test
    fun karaokeAddsGapsAndSpreadsWords() {
        val rows = Karaoke.build(
            listOf(
                LyricLine(10.0, null, "Hello world"),
                LyricLine(14.0, null, ""),
                LyricLine(20.0, null, "Again"),
            ),
        )
        // вступление, строка, пауза из пустой строки, строка
        assertEquals(listOf(true, false, true, false), rows.map { it.gap })
        assertEquals(0.0, rows[0].t)
        assertEquals(14.0, rows[1].end)
        val segs = rows[1].segs
        assertEquals(listOf("Hello", " ", "world"), segs.map { it.text })
        assertEquals(10.0, segs[0].t)
        // span = max(0.6, min(4 - 0.12, max(3, 11 * 0.25))) = 3; слова поровну (по 6 из 12)
        assertEquals(10.0 + 3.0 / 2, segs[0].end!!, 1e-9)
        assertEquals(segs[0].end, segs[2].t)
        assertEquals(1, Karaoke.active(rows, 10.5))
        assertEquals(-1, Karaoke.active(listOf(rows[1]), 1.0))
        // пауза 14…20: за 2.5 с до строки отсчёт показывает 3
        assertEquals(3, Karaoke.countdown(rows, 2, 17.5))
        assertEquals(0, Karaoke.countdown(rows, 2, 15.0))
        assertEquals(0.5, segs[0].progress(10.0 + 3.0 / 4), 1e-9)
    }

    @Test
    fun longBreakAfterLineGetsDots() {
        val rows = Karaoke.build(listOf(LyricLine(0.5, 2.0, "One"), LyricLine(9.0, null, "Two")))
        assertEquals(listOf(false, true, false), rows.map { it.gap })
        assertEquals(2.0, rows[1].t)
    }

    @Test
    fun ttmlLinesAndWordTimings() {
        val xml = """<tt xmlns="http://www.w3.org/ns/ttml"><body><div>
            <p begin="00:01.500" end="00:04.000"><span begin="1.5s" end="2s">Hey</span><span begin="2s" end="3s">you&amp;me</span></p>
            <p begin="1:00:00.0">Second <br/> line</p>
            <p begin="bad">skip</p>
            </div></body></tt>"""
        val lines = Ttml.parse(xml)!!
        assertEquals(2, lines.size)
        assertEquals(1.5, lines[0].t)
        assertEquals(4.0, lines[0].end)
        assertEquals("Heyyou&me", lines[0].text)
        assertEquals(listOf(0 to 3, 3 to 9), lines[0].words!!.map { it.from!! to it.to!! })
        assertEquals(3600.0, lines[1].t)
        assertEquals("Second line", lines[1].text)
        val segs = Karaoke.words(lines[0])
        assertEquals(listOf("Hey", "you&me"), segs.map { it.text })
        assertEquals(3.0, segs[1].end)
        assertEquals(0.25, Ttml.seconds("250ms")!!, 1e-9)
        assertEquals(90.0, Ttml.seconds("1.5m"))
        assertNull(Ttml.parse("<tt></tt>"))
    }

    @Test
    fun helpersMatchSite() {
        assertEquals("Song", LyricsApi.cleanTitle("Song (feat. X)"))
        assertEquals("A", LyricsApi.mainArtist("A, B & C"))
        assertEquals("A", LyricsApi.mainArtist("A feat. B"))
        assertEquals("hello world", LyricsApi.norm("Hello (Live) World!"))
        assertEquals("ru", LyricsApi.guessLang(listOf("Привет мир")))
        assertEquals("de", LyricsApi.guessLang(listOf("schön")))
        assertTrue(LyricsData.Plain(listOf("Ёлка")).isRussian)
    }

    @Test
    fun blinkTrackUsesTtmlThenLrc() = serve({ r ->
        when (r.path) {
            "/api/tracks/L1/ttml" -> MockResponse().setBody("""<tt><p begin="1s">Мой текст</p></tt>""")
            else -> MockResponse().setResponseCode(404)
        }
    }) { api, seen ->
        val t = Track("b:L1", "Песня", "Ник", source = Track.SOURCE_BLINK, lic = "L1", lrc = "[00:05.00]lrc")
        val d = api.load(t) as LyricsData.Synced
        assertEquals("Мой текст", d.lines[0].text)
        assertEquals("Bearer tok", seen[0].getHeader("Authorization"))
        val t2 = Track("b:L2", "Песня", "Ник", source = Track.SOURCE_BLINK, lic = "L2", lrc = "[00:05.00]из lrc")
        assertEquals(5.0, (api.load(t2) as LyricsData.Synced).lines[0].t)
        val t3 = Track("b:L3", "Песня", "Ник", source = Track.SOURCE_BLINK, lic = "L3", lyrics = "a\r\nb")
        assertEquals(listOf("a", "b"), (api.load(t3) as LyricsData.Plain).lines)
    }

    @Test
    fun lrclibGetSearchAndFallbacks() = serve({ r ->
        val p = r.requestUrl!!
        when (p.encodedPath) {
            "/api/lrclib/get" -> when (p.queryParameter("track_name")) {
                "Synced" -> MockResponse().setBody("""{"syncedLyrics":"[00:01.00]one\n[00:03.00]two","plainLyrics":"one"}""")
                "PlainOnly" -> MockResponse().setBody("""{"plainLyrics":"x\ny"}""")
                "Down" -> MockResponse().setResponseCode(502)
                else -> MockResponse().setResponseCode(404)
            }
            "/api/lrclib/search" -> MockResponse().setBody(
                """[{"trackName":"Other","syncedLyrics":"[00:01.00]bad","duration":500},{"trackName":"Found","syncedLyrics":"[00:02.00]good","duration":200}]""",
            )
            "/api/lyricsovh" -> MockResponse().setResponseCode(404)
            else -> MockResponse().setResponseCode(404)
        }
    }) { api, seen ->
        val a = api.load(Track("1", "Synced (feat. Z)", "Ann, Bob", album = "Alb", duration = 180)) as LyricsData.Synced
        assertEquals(listOf("one", "two"), a.lines.map { it.text })
        val q = seen.first().requestUrl!!
        assertEquals("Synced", q.queryParameter("track_name"))
        assertEquals("Ann", q.queryParameter("artist_name"))
        assertEquals("Alb", q.queryParameter("album_name"))
        assertEquals("180", q.queryParameter("duration"))
        // /get без синхронного текста: поиск находит лучший вариант
        val b = api.load(Track("2", "Found", "Ann", duration = 200)) as LyricsData.Synced
        assertEquals("good", b.lines[0].text)
        // лишь простой текст и поиск дал то же: берём лучшее из поиска
        val c = api.load(Track("3", "PlainOnly", "Ann", duration = 500))
        assertTrue(c is LyricsData.Synced)
        // сервис лёг: ошибка, и она не запоминается
        assertFailsWith<LyricsUnavailable> { api.load(Track("4", "Down", "Ann")) }
        assertEquals(false, api.cachedOrNull("4").first)
        assertEquals(true, api.cachedOrNull("1").first)
    }

    @Test
    fun paletteFromCover() {
        // красная обложка
        val red = IntArray(24 * 24) { 0xFFCC2020.toInt() }
        val p = Palette.fromArgb(red)
        assertEquals(0.0, p.accent.h, 0.5)
        assertEquals(0.66, p.accent.l)
        assertEquals(0.95, p.accent.s, 1e-9)
        // серая обложка: монохром
        val gray = Palette.fromArgb(IntArray(24 * 24) { 0xFF808080.toInt() })
        assertEquals(Hsl(36.0, 0.2, 0.82), gray.accent)
        assertEquals(Palette.FALLBACK, Palette.fromArgb(IntArray(0)))
        assertEquals(0xFFFF0000.toInt(), Hsl(0.0, 1.0, 0.5).argb())
    }

    @Test
    fun artSizes() {
        assertEquals("https://a/x/100x100bb.jpg", ArtUrl.scaled("https://a/x/600x600bb.jpg", 100))
        assertEquals("https://avatars.yandex.net/a/1000x1000", ArtUrl.scaled("https://avatars.yandex.net/a/200x200", 1000))
        assertEquals("https://i1.sndcdn.com/a-t300x300.jpg", ArtUrl.scaled("https://i1.sndcdn.com/a-large.jpg", 100))
        assertEquals("https://x/y.png", ArtUrl.scaled("https://x/y.png", 100))
    }
}
