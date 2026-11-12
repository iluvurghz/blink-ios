package app.blink.core.offline

import app.blink.core.net.BlinkConfig
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse

class ResolverTest {
    private val backend = FakeBackend().start()
    private val config get() = BlinkConfig(baseUrl = backend.base, supabaseUrl = backend.base, supabaseAnonKey = "anon")

    @AfterTest
    fun tearDown() = backend.close()

    private fun resolver(token: String? = "tok", legacy: Boolean = true, now: () -> Long = System::currentTimeMillis) =
        ServerResolver(OkHttpClient(), config, { token }, now, legacy)

    private fun resolve(r: ServerResolver, id: String = "a") = runBlocking { r.resolve("blink", id) }

    private fun code(r: ServerResolver, id: String = "a"): OfflineException = assertFailsWith { resolve(r, id) }

    @Test
    fun `resolves with bearer and reads every field`() {
        backend.add("a", 300_000, duration = 213)
        val res = resolve(resolver())
        assertEquals(300_000L, res.bytes)
        assertEquals("audio/mpeg", res.mime)
        assertEquals("W/\"e1\"", res.etag)
        assertEquals(213, res.duration)
        assertTrue(res.url.startsWith("${backend.base}/media/a"), res.url)
        assertTrue(res.expiresAt > System.currentTimeMillis())
        val req = backend.resolveRequests.single()
        assertEquals("Bearer tok", req.getHeader("Authorization"))
        assertEquals("blink", req.requestUrl?.queryParameter("source"))
        assertEquals("a", req.requestUrl?.queryParameter("id"))
    }

    @Test
    fun `relative file url is made absolute`() {
        backend.add("a", 300_000)
        backend.resolveHook = {
            MockResponse().setHeader("Content-Type", "application/json")
                .setBody("""{"ok":true,"url":"/media/a?sig=1","bytes":300000,"etag":"W/\"e1\"","mime":"audio/mpeg","expiresAt":9999999999999}""")
        }
        assertEquals("${backend.base}/media/a?sig=1", resolve(resolver()).url)
    }

    @Test
    fun `no token means sign in, no request`() {
        backend.add("a", 300_000)
        val e = code(resolver(token = null))
        assertEquals(OfflineCode.NOT_ALLOWED, e.code)
        assertEquals("auth", e.reason)
        assertTrue(backend.resolveRequests.isEmpty())
    }

    @Test
    fun `server errors map to contract codes`() {
        backend.add("a", 300_000)
        fun reply(status: Int, body: String) {
            backend.resolveHook = { MockResponse().setResponseCode(status).setHeader("Content-Type", "application/json").setBody(body) }
        }
        reply(401, """{"ok":false,"error":"NOT_ALLOWED","reason":"auth"}""")
        assertEquals("auth", code(resolver()).reason)
        reply(403, """{"ok":false,"error":"NOT_ALLOWED","reason":"plus"}""")
        assertEquals("plus", code(resolver()).reason)
        reply(403, """{"ok":false,"error":"NOT_ALLOWED","reason":"artist"}""")
        assertEquals("artist", code(resolver()).reason)
        reply(403, """{"ok":false,"error":"NOT_ALLOWED"}""")
        assertEquals("source", code(resolver()).reason)
        reply(404, """{"ok":false,"error":"NOT_DOWNLOADABLE","reason":"unreleased"}""")
        code(resolver()).also {
            assertEquals(OfflineCode.NOT_DOWNLOADABLE, it.code)
            assertEquals("unreleased", it.reason)
        }
        reply(400, """{"ok":false,"error":"SOURCE_ERROR","reason":"bad_request"}""")
        assertEquals(OfflineCode.SOURCE_ERROR, code(resolver()).code)
        reply(503, """{"ok":false,"error":"SOURCE_ERROR"}""")
        assertEquals(OfflineCode.SOURCE_ERROR, code(resolver()).code)
        reply(502, "<html>bad gateway</html>")
        assertEquals(OfflineCode.SOURCE_ERROR, code(resolver()).code)
    }

    @Test
    fun `bad 200 answers are source errors`() {
        for (body in listOf(
            """{"ok":true,"url":"/media/a"}""", // нет bytes
            """{"ok":true,"url":"/media/a","bytes":0}""",
            """{"ok":true,"bytes":10}""", // нет url
            """{"ok":false,"bytes":10,"url":"/media/a"}""",
            "not json",
        )) {
            backend.resolveHook = { MockResponse().setHeader("Content-Type", "application/json").setBody(body) }
            val e = code(resolver())
            assertEquals(OfflineCode.SOURCE_ERROR, e.code, body)
            assertEquals("bad_response", e.reason, body)
        }
    }

    @Test
    fun `until the resolver is on prod it falls back to api play, with no size and no etag`() {
        backend.legacyOnly = true
        backend.add("a", 300_000)
        val fixed = 1_000_000L
        val res = resolve(resolver(now = { fixed }))
        assertTrue(res.url.startsWith("${backend.base}/media/a"), res.url)
        assertNull(res.bytes)
        assertNull(res.etag)
        assertNull(res.mime)
        assertEquals(fixed + 55 * 60 * 1000, res.expiresAt)
        assertEquals("Bearer tok", backend.playRequests.single().getHeader("Authorization"))
    }

    @Test
    fun `legacy fallback maps its own errors, and a real NOT_DOWNLOADABLE is not mistaken for a missing endpoint`() {
        backend.legacyOnly = true
        assertEquals(OfflineCode.NOT_DOWNLOADABLE, code(resolver(), "ghost").code) // /api/play/ghost → 404
        assertEquals(0, backend.playRequests.count { it.getHeader("Authorization") == null })

        backend.legacyOnly = false
        backend.resolveHook = null
        code(resolver(), "ghost").also {
            assertEquals(OfflineCode.NOT_DOWNLOADABLE, it.code, "наш JSON с NOT_DOWNLOADABLE это настоящий ответ")
        }
        assertTrue(backend.playRequests.size == 1, "в /api/play второй раз не ходили")

        backend.legacyOnly = true
        assertEquals(OfflineCode.NOT_DOWNLOADABLE, code(resolver(legacy = false), "a").code)
    }

    @Test
    fun `only blink goes to the legacy fallback`() {
        backend.legacyOnly = true
        backend.add("a", 300_000)
        val e = assertFailsWith<OfflineException> { runBlocking { resolver().resolve("soundcloud", "a") } }
        assertEquals(OfflineCode.NOT_DOWNLOADABLE, e.code)
        assertTrue(backend.playRequests.isEmpty())
    }
}
