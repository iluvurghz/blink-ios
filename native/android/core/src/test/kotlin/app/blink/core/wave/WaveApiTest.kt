package app.blink.core.wave

import app.blink.core.net.BlinkConfig
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest

class WaveApiTest {
    private val server = MockWebServer()
    private val seen = java.util.concurrent.CopyOnWriteArrayList<RecordedRequest>()

    init {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                seen.add(request)
                val body = when (request.requestUrl?.encodedPath) {
                    "/api/wave/pool" -> """{"tracks":[{"id":"cr5","source":"chart","title":"Song","artist":"A, B","artwork":"https://x/600x600","duration":187,"explicit":false,"year":"2024","genre":"rap","released":"2024-05-10T00:00:00+03:00","src":"similar","seed":"S","hits":2},{"title":"no id"}],"seedGenre":[{"q":"Art Seed","genre":"rap","id":"cr9"}]}"""
                    "/api/wave/genres" -> """{"genres":{"cr1":"rap","Artist Title":""}}"""
                    "/api/wave/similar-ids" -> """{"ids":["cr1","cr2"],"genre":"rap","id":"cr7"}"""
                    "/api/charts/top" -> """{"items":[{"id":153919218,"chart":{"position":1,"progress":"same"},"track":{"id":"153919218","title":"ДИНАСТИЯ","contentWarning":"explicit","durationMs":150420,"artists":[{"name":"VILLIAN"},{"name":"madk1d"}],"albums":[{"title":"Красивое Зло","year":2026,"releaseDate":"2026-07-24T00:00:00+03:00","coverUri":"x","genre":"rusrap"}],"coverUri":"avatars.yandex.net/get-music-content/1/abc/%%"}},{"track":{"id":"1","title":"no artists","artists":[]}}]}"""
                    "/api/charts/weekly" -> """{"items":[{"id":"wVIq7","rank":1,"trackNameStr":"милый ублюдок","artistNameStr":"Егор Крид","artistNames":["Егор Крид"],"coverUrl":"https://music-bandlink.s3.yandex.net/img/x_1120_1120.jpeg","rankDiffStr":"New"},{"id":"zz","trackNameStr":"Joined","artistNames":["A","B"]}]}"""
                    else -> return MockResponse().setResponseCode(502).setBody("{}")
                }
                return MockResponse().setResponseCode(200).setBody(body)
            }
        }
        server.start()
    }

    @AfterTest
    fun tearDown() = server.shutdown()

    private fun api(): WaveApi {
        val base = server.url("/").toString().trimEnd('/')
        return WaveApi(OkHttpClient(), BlinkConfig(baseUrl = base, supabaseUrl = base))
    }

    @Test
    fun `pool parses candidates and seed genres and sends seeds joined by a bar`() = runBlocking {
        val r = api().pool(listOf("Art Seed", "Other One"))
        assertEquals("Art Seed|Other One", seen.single().requestUrl?.queryParameter("seeds"))
        assertEquals("2", seen.single().requestUrl?.queryParameter("n"))
        val c = r.tracks.single()
        assertEquals("cr5", c.track.id)
        assertEquals("similar", c.src)
        assertEquals(2, c.hits)
        assertEquals("2024-05-10T00:00:00+03:00", c.track.released)
        assertEquals(SeedGenre("Art Seed", "rap", "cr9"), r.seedGenre.single())
    }

    @Test
    fun `genres and similar ids`() = runBlocking {
        assertEquals(mapOf("cr1" to "rap", "Artist Title" to ""), api().genres(listOf("cr1", "Artist Title")))
        assertEquals(SimilarResult(listOf("cr1", "cr2"), "rap"), api().similarIds("cr7"))
    }

    @Test
    fun `main chart maps like the website, with the release date`() = runBlocking {
        val top = api().topChart().single()
        assertEquals("cr153919218", top.id)
        assertEquals("VILLIAN, madk1d", top.artist)
        assertEquals("https://avatars.yandex.net/get-music-content/1/abc/600x600", top.artwork)
        assertEquals(150, top.duration)
        assertTrue(top.explicit)
        assertEquals("rusrap", top.genre)
        assertEquals("2026", top.year)
        assertEquals("2026-07-24T00:00:00+03:00", top.released)
    }

    @Test
    fun `period chart maps cp tracks`() = runBlocking {
        val list = api().periodChart("weekly")
        assertEquals(listOf("cpwVIq7", "cpzz"), list.map { it.id })
        assertEquals("Егор Крид", list[0].artist)
        assertEquals("A, B", list[1].artist)
        assertEquals("https://music-bandlink.s3.yandex.net/img/x_1120_1120.jpeg", list[0].artwork)
    }
}
