package app.blink.core.net

import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest

class AuthLinkTest {
    private val server = MockWebServer()
    private val seen = java.util.concurrent.CopyOnWriteArrayList<RecordedRequest>()
    private val session = """{"access_token":"acc","refresh_token":"ref","expires_in":3600,"user":{"id":"u1","email":"a@b.c","user_metadata":{"full_name":"Имя"}}}"""

    init {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                seen.add(request)
                val path = request.requestUrl?.encodedPath ?: ""
                return when {
                    path.endsWith("/auth/v1/token") || path.endsWith("/auth/v1/verify") -> MockResponse().setResponseCode(200).setBody(session)
                    else -> MockResponse().setResponseCode(404).setBody("{}")
                }
            }
        }
        server.start()
    }

    @AfterTest
    fun tearDown() = server.shutdown()

    private val base get() = server.url("/").toString().trimEnd('/')

    private class Mem : SessionStore {
        var value: String? = null
        override fun load() = value
        override fun save(value: String?) { this.value = value }
    }

    @Test
    fun `parse reads google, telegram and error links`() {
        val g = AuthLink.parse("blink://auth?id_token=aaa.bbb.ccc&nonce=0f%2Bab")
        assertEquals(AuthLink.IdToken("aaa.bbb.ccc", "0f+ab"), g)
        assertEquals(AuthLink.TelegramHash("h4sh"), AuthLink.parse("blink://auth?tg_hash=h4sh"))
        assertEquals(AuthLink.TelegramHash("h4sh"), AuthLink.parse("blink://auth#tg_hash=h4sh"))
        assertIs<AuthLink.Failed>(AuthLink.parse("blink://auth?error=access_denied&error_description=No"))
        assertNull(AuthLink.parse("blink://auth?foo=bar"))
        assertNull(AuthLink.parse("https://blinkmusic.cc/?id_token=x&nonce=y"))
        assertNull(AuthLink.parse(null))
    }

    @Test
    fun `start urls point to the site pages`() {
        assertEquals("https://blinkmusic.cc/?gsignin=desktop", AuthLink.startUrl("https://blinkmusic.cc/", AuthLink.Provider.GOOGLE))
        assertEquals("https://blinkmusic.cc/?tgsignin=desktop", AuthLink.startUrl("https://blinkmusic.cc", AuthLink.Provider.TELEGRAM))
    }

    @Test
    fun `google id token goes to the id_token grant with the raw nonce`() = runBlocking {
        val store = Mem()
        val auth = SupabaseAuth(OkHttpClient(), BlinkConfig(baseUrl = base, supabaseUrl = base, supabaseAnonKey = "anon"), store)
        val s = auth.finish(AuthLink.IdToken("tok", "rawnonce"))
        assertEquals("u1", s.userId)
        assertEquals("Имя", s.name)
        val req = seen.single()
        assertEquals("id_token", req.requestUrl?.queryParameter("grant_type"))
        val body = req.body.readUtf8()
        assertTrue(body.contains("\"provider\":\"google\"") && body.contains("\"id_token\":\"tok\"") && body.contains("\"nonce\":\"rawnonce\""), body)
        assertEquals("anon", req.getHeader("apikey"))
        assertTrue(store.value!!.contains("acc"))
    }

    @Test
    fun `telegram hash is verified as a magic link`() = runBlocking {
        val auth = SupabaseAuth(OkHttpClient(), BlinkConfig(baseUrl = base, supabaseUrl = base, supabaseAnonKey = "anon"), Mem())
        auth.finish(AuthLink.TelegramHash("h4sh"))
        val req = seen.single()
        assertEquals("/auth/v1/verify", req.requestUrl?.encodedPath)
        val body = req.body.readUtf8()
        assertTrue(body.contains("\"type\":\"magiclink\"") && body.contains("\"token_hash\":\"h4sh\""), body)
    }

    @Test
    fun `failed link is a human error and does not call the server`() {
        val auth = SupabaseAuth(OkHttpClient(), BlinkConfig(baseUrl = base, supabaseUrl = base, supabaseAnonKey = "anon"), Mem())
        assertFailsWith<AuthException> { runBlocking { auth.finish(AuthLink.Failed("x")) } }
        assertEquals(0, seen.size)
    }

    @Test
    fun `dead supabase falls back to the site mirror and remembers it`() = runBlocking {
        val dead = "http://127.0.0.1:1"
        val auth = SupabaseAuth(OkHttpClient(), BlinkConfig(baseUrl = base, supabaseUrl = dead, supabaseAnonKey = "anon"), Mem())
        auth.signIn("a@b.c", "pw")
        assertEquals("/sb/auth/v1/token", seen.single().requestUrl?.encodedPath)
        auth.signIn("a@b.c", "pw")
        assertEquals(2, seen.size)
    }
}
