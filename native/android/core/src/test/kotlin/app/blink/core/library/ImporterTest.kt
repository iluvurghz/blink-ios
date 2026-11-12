package app.blink.core.library

import app.blink.core.model.Track
import app.blink.core.net.BlinkApi
import app.blink.core.net.BlinkConfig
import app.blink.core.wave.LibraryStore
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

class ImporterTest {
    @Test
    fun parsesCsvAndPlainLines() {
        val csv = "Track name,Artist name,Album\n\"Kosandra\",\"Miyagi & Andy Panda\",x\nSolo,Band,y"
        assertEquals(listOf(TrackRef("Miyagi & Andy Panda", "Kosandra"), TrackRef("Band", "Solo")), Importer.parseList(csv))
        assertEquals(listOf(TrackRef("Артист", "Название - часть 2"), TrackRef("", "Без артиста")), Importer.parseList("Артист — Название - часть 2\nБез артиста"))
        assertTrue(Importer.parseList("  \n ").isEmpty())
    }

    @Test
    fun recognizesLinksAndPicksTheBestMatch() {
        assertEquals(ImportSource.Spotify, Importer.sourceOf("смотри https://open.spotify.com/playlist/37i9dQZF1DX"))
        assertEquals(ImportSource.Yandex, Importer.sourceOf("https://music.yandex.ru/users/ivan/playlists/1003"))
        assertNull(Importer.sourceOf("Артист — Название"))
        val tracks = listOf(Track("1", "Other", "Miyagi"), Track("2", "Kosandra (Remix)", "Miyagi, Andy Panda"))
        assertEquals("2", Importer.pick(TrackRef("Miyagi & Andy Panda", "Kosandra"), tracks)?.id)
        assertEquals("1", Importer.pick(TrackRef("Miyagi", "Нет такого"), tracks)?.id)
        assertNull(Importer.pick(TrackRef("Никто", "Ничто"), tracks))
    }

    @Test
    fun runsAnImportAndReportsMisses() = runBlocking {
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val p = request.path.orEmpty()
                return when {
                    p.startsWith("/api/spotify/list") -> MockResponse().setBody("""{"name":"Мой микс","items":[{"artist":"Band","title":"Solo"},{"artist":"Ghost","title":"Nothing"}]}""")
                    p.startsWith("/api/itunes/search") && p.contains("Band") ->
                        MockResponse().setBody("""{"results":[{"kind":"song","trackId":7,"trackName":"Solo","artistName":"Band"}]}""")
                    p.startsWith("/api/itunes/search") || p.startsWith("/api/yandex/search") -> MockResponse().setBody("""{"results":[]}""")
                    p.startsWith("/sb/rest") || p.startsWith("/rest") -> MockResponse().setBody("[]")
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }
        server.start()
        try {
            val base = server.url("/").toString().trimEnd('/')
            val cfg = BlinkConfig(baseUrl = base, supabaseUrl = base, supabaseAnonKey = "")
            val http = OkHttpClient()
            val imp = Importer(http, cfg, BlinkApi(http, cfg))
            var last = 0 to 0
            val r = imp.run("https://open.spotify.com/playlist/abc123") { d, t -> last = d to t }
            assertEquals("Мой микс", r.title)
            assertEquals(2, r.total)
            assertEquals(listOf("7"), r.found.map { it.id })
            assertEquals(listOf(TrackRef("Ghost", "Nothing")), r.missed)
            assertEquals(2, last.first)
            val lib = LibraryStore(object : app.blink.core.wave.BlobStore {
                var t: String? = null
                override fun load() = t
                override fun save(value: String?) { t = value }
            })
            assertEquals(1, lib.addLikes(r.found))
            assertEquals(0, lib.addLikes(r.found))
            assertFailsWith<ImportException> { imp.run("   ") }
        } finally {
            server.shutdown()
        }
        Unit
    }
}
