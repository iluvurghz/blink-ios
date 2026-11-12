package app.blink.core.wave

import app.blink.core.model.Track
import app.blink.core.net.BlinkConfig
import app.blink.core.net.BlinkJson
import app.blink.core.net.TokenProvider
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest

class LibraryTest {
    private class Mem : BlobStore {
        var value: String? = null
        override fun load() = value
        override fun save(value: String?) { this.value = value }
    }

    private val server = MockWebServer()
    private val seen = java.util.concurrent.CopyOnWriteArrayList<RecordedRequest>()
    private var remote = """[{"data":{"likes":[{"id":"cr2","title":"Remote","artist":"R","artistRef":"abc"},{"id":"cr1","title":"Dup","artist":"D"}],"recent":[{"id":"cr9","title":"Rec","artist":"X"}],"playlists":[{"id":"p1","name":"Дорога","tracks":[]}],"nowPlaying":{"time":3},"device":"web"}}]"""

    init {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                seen.add(request)
                return if (request.method == "GET") MockResponse().setResponseCode(200).setBody(remote) else MockResponse().setResponseCode(201)
            }
        }
        server.start()
    }

    @AfterTest
    fun tearDown() = server.shutdown()

    private fun t(id: String) = Track(id = id, title = "T $id", artist = "A")

    @Test
    fun `likes go to the top, can be removed and survive a restart`() {
        val mem = Mem()
        val lib = LibraryStore(mem)
        assertTrue(lib.toggleLike(t("cr1")))
        assertTrue(lib.toggleLike(t("cr2")))
        assertEquals(listOf("cr2", "cr1"), lib.likes.map { it.id })
        assertTrue(lib.isLiked("cr1"))
        assertFalse(lib.toggleLike(t("cr1")))
        assertEquals(listOf("cr2"), LibraryStore(mem).likes.map { it.id })
    }

    @Test
    fun `recent keeps the newest first without duplicates and at most 60`() {
        val lib = LibraryStore(Mem())
        for (i in 1..70) lib.noteRecent(t("cr$i"))
        lib.noteRecent(t("cr50"))
        assertEquals(60, lib.recent.size)
        assertEquals("cr50", lib.recent.first().id)
        assertEquals(1, lib.recent.count { it.id == "cr50" })
    }

    @Test
    fun `merge keeps local first, drops duplicates and keeps unknown fields`() {
        val lib = LibraryStore(Mem())
        lib.toggleLike(t("cr1"))
        lib.mergeRemote(BlinkJson.parseToJsonElement(remote).let { (it as kotlinx.serialization.json.JsonArray)[0] as JsonObject }["data"] as JsonObject)
        assertEquals(listOf("cr1", "cr2"), lib.likes.map { it.id })
        val snap = lib.snapshot("dev")
        assertTrue(snap.toString().contains("artistRef"), "поле сайта не потеряно")
        assertTrue(snap.containsKey("playlists") && snap.containsKey("nowPlaying"), "чужие разделы остаются")
        assertEquals("\"dev\"", snap["device"].toString())
    }

    @Test
    fun `pull merges the server copy and pushes the result once`() = runBlocking {
        val lib = LibraryStore(Mem())
        lib.toggleLike(t("cr1"))
        val cfg = BlinkConfig(baseUrl = server.url("/").toString().trimEnd('/'), supabaseUrl = server.url("/").toString().trimEnd('/'), supabaseAnonKey = "anon")
        val sync = LibrarySync(OkHttpClient(), cfg, TokenProvider { "tok" }, lib, { "u1" }, "dev")
        assertTrue(sync.pull())
        val get = seen[0]
        assertEquals("/rest/v1/library", get.requestUrl?.encodedPath)
        assertEquals("eq.u1", get.requestUrl?.queryParameter("user_id"))
        assertEquals("Bearer tok", get.getHeader("Authorization"))
        val post = seen[1]
        assertEquals("POST", post.method)
        assertTrue(post.getHeader("Prefer")!!.contains("merge-duplicates"))
        val body = post.body.readUtf8()
        assertTrue(body.contains("\"user_id\":\"u1\"") && body.contains("playlists") && body.contains("cr2") && body.contains("artistRef"), body)
        assertTrue(sync.push())
        assertEquals(2, seen.size, "ничего не изменилось: повторно не пишем")
        lib.toggleLike(t("cr3"))
        assertTrue(sync.push())
        assertEquals(3, seen.size)
    }

    @Test
    fun `signed out means nothing is sent`() = runBlocking {
        val lib = LibraryStore(Mem())
        val cfg = BlinkConfig(baseUrl = server.url("/").toString().trimEnd('/'), supabaseUrl = server.url("/").toString().trimEnd('/'), supabaseAnonKey = "anon")
        val sync = LibrarySync(OkHttpClient(), cfg, TokenProvider { null }, lib, { null })
        assertFalse(sync.pull())
        assertFalse(sync.push())
        assertEquals(0, seen.size)
    }
}
