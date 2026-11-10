package app.blink.core.net

import app.blink.core.model.Track
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest

class ApiTest {
    private val server = MockWebServer()
    private val seen = java.util.concurrent.CopyOnWriteArrayList<RecordedRequest>()
    private val routes = java.util.concurrent.ConcurrentHashMap<String, (RecordedRequest) -> MockResponse>()

    init {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                seen.add(request)
                val path = request.requestUrl?.encodedPath ?: ""
                return routes[path]?.invoke(request) ?: MockResponse().setResponseCode(404).setBody("{}")
            }
        }
        server.start()
    }

    @AfterTest
    fun tearDown() = server.shutdown()

    private val base get() = server.url("/").toString().trimEnd('/')
    private fun config(key: String = "anon") = BlinkConfig(baseUrl = base, supabaseUrl = base, supabaseAnonKey = key)
    private fun api(token: String? = null, key: String = "anon") = BlinkApi(OkHttpClient(), config(key), token?.let { t -> TokenProvider { t } })
    private fun json(body: String, code: Int = 200) = MockResponse().setResponseCode(code).setHeader("Content-Type", "application/json").setBody(body)
    private fun route(path: String, r: (RecordedRequest) -> MockResponse) { routes[path] = r }

    private val itunes = """{"results":[
        {"kind":"song","trackId":111,"trackName":"Alive","artistName":"Band","artistId":5,"collectionName":"Record - Single","collectionId":7,
         "artworkUrl100":"https://is1.mzstatic.com/image/x/100x100bb.jpg","trackTimeMillis":215400,"releaseDate":"2024-05-01T07:00:00Z","trackExplicitness":"explicit","primaryGenreName":"Rock"},
        {"kind":"song","trackId":222,"trackName":"Second Song","artistName":"Band","artworkUrl100":"https://x/y/100x100bb.jpg","trackTimeMillis":180000,"releaseDate":"2023-01-01T00:00:00Z"},
        {"wrapperType":"collection","collectionName":"not a song"}]}"""

    private val yandex = """{"results":[
        {"kind":"song","trackId":"y9","trackName":"alive!","artistName":"BAND","artworkUrl600":"https://avatars.yandex.net/get-music-content/1/abc/100x100","trackTimeMillis":215000},
        {"kind":"song","trackId":"y10","trackName":"Third","artistName":"Other","artworkUrl600":"https://avatars.yandex.net/get-music-content/1/def/200x200"}]}"""

    private val lic = """[{"id":"11111111-2222-3333-4444-555555555555","artist_id":"a1","title":"Licensed","artist_name":"Band","release_title":"LP","duration":200,
        "explicit":false,"year":2024,"genre":"Pop","lrc":null,"lyrics":null,"cover_path":"covers/x.jpg","offline_allowed":true,"status":"live"},
        {"id":"99999999-2222-3333-4444-555555555555","title":"No offline","artist_name":"Band","cover_path":null,"offline_allowed":false,"status":"live"}]"""

    @Test
    fun `search merges blink, itunes and yandex without duplicates and in that order`() = runBlocking {
        route("/api/itunes/search") { json(itunes) }
        route("/api/yandex/search") { json(yandex) }
        route("/rest/v1/lic_tracks") { json(lic) }

        val r = api().search("band")
        assertEquals(listOf("b:11111111-2222-3333-4444-555555555555", "b:99999999-2222-3333-4444-555555555555", "111", "222", "y10"), r.map { it.id })

        val blink = r[0]
        assertEquals("blink", blink.source)
        assertEquals("11111111-2222-3333-4444-555555555555", blink.lic)
        assertEquals("$base/covers/11111111-2222-3333-4444-555555555555.jpg", blink.artwork)
        assertEquals(true, blink.offline)
        assertEquals("2024", blink.year)
        assertTrue(blink.isLicensed)
        assertEquals(false, r[1].offline)
        assertEquals("", r[1].artwork)

        val song = r[2]
        assertEquals("Alive", song.title)
        assertEquals("Record", song.album, "Single/EP отрезается")
        assertEquals("https://is1.mzstatic.com/image/x/600x600bb.jpg", song.artwork)
        assertEquals(215, song.duration)
        assertTrue(song.explicit)
        assertEquals("2024", song.year)
        assertEquals("5", song.artistId)
        assertEquals("7", song.albumId)
        assertEquals(null, song.source)
        assertEquals("https://avatars.yandex.net/get-music-content/1/def/1000x1000", r[4].artwork)

        val lq = seen.first { it.requestUrl?.encodedPath == "/rest/v1/lic_tracks" }
        assertEquals("anon", lq.getHeader("apikey"))
        assertEquals("Bearer anon", lq.getHeader("Authorization"))
        assertEquals("eq.live", lq.requestUrl?.queryParameter("status"))
        assertEquals("(title.ilike.*band*,artist_name.ilike.*band*,release_title.ilike.*band*)", lq.requestUrl?.queryParameter("or"))
        val iq = seen.first { it.requestUrl?.encodedPath == "/api/itunes/search" }.requestUrl!!
        assertEquals("band", iq.queryParameter("term"))
        assertEquals("ru", iq.queryParameter("country"))
        assertEquals("song", iq.queryParameter("entity"))
    }

    @Test
    fun `search survives one source failing and sanitises the licensed query`() = runBlocking {
        route("/api/itunes/search") { json("boom", 500) }
        route("/api/yandex/search") { json(yandex) }
        route("/rest/v1/lic_tracks") { json(lic, 401) }
        val r = api().search("a,b(c)*%")
        assertEquals(listOf("y9", "y10"), r.map { it.id })
        val lq = seen.first { it.requestUrl?.encodedPath == "/rest/v1/lic_tracks" }
        assertEquals("(title.ilike.*a b c*,artist_name.ilike.*a b c*,release_title.ilike.*a b c*)", lq.requestUrl?.queryParameter("or"))
    }

    @Test
    fun `search without anon key skips the licensed catalog, and all-failed network is an IOException`() = runBlocking {
        route("/api/itunes/search") { json(itunes) }
        route("/api/yandex/search") { json(yandex) }
        val r = api(key = "").search("band")
        assertTrue(r.none { it.source == "blink" })
        assertTrue(seen.none { it.requestUrl?.encodedPath == "/rest/v1/lic_tracks" })

        server.shutdown()
        assertFailsWith<java.io.IOException> { api().search("band") }
        Unit
    }

    @Test
    fun `chart maps yandex items to cr ids with 600px covers`() = runBlocking {
        route("/api/charts/top") {
            json(
                """{"items":[{"track":{"id":4242,"title":"Hit","version":"Remix","artists":[{"name":"A"},{"name":"B"}],
                "albums":[{"title":"LP","year":2024,"genre":"rap"}],"coverUri":"avatars.yandex.net/get-music-content/1/z/%%","durationMs":201400,"contentWarning":"explicit"},
                "chart":{"progress":"up"}},{"track":{"id":1,"title":"No artists","artists":[]}}]}""",
            )
        }
        val t = api().chart().single()
        assertEquals("cr4242", t.id)
        assertEquals("chart", t.source)
        assertEquals("Hit (Remix)", t.title)
        assertEquals("A, B", t.artist)
        assertEquals("https://avatars.yandex.net/get-music-content/1/z/600x600", t.artwork)
        assertEquals(201, t.duration)
        assertTrue(t.explicit)
        assertEquals("2024", t.year)
        assertEquals("rap", t.genre)
    }

    // ---------- проигрывание ----------

    private val licTrack = Track(id = "b:u1", title = "T", artist = "A", source = "blink", lic = "u1", offline = true)
    private val plain = Track(id = "111", title = "Alive", artist = "Band")

    @Test
    fun `licensed tracks stream through api play with bearer`() = runBlocking {
        route("/api/play/u1") { json("""{"url":"/media/u1?sig=zz"}""") }
        assertEquals("$base/media/u1?sig=zz", api(token = "tok").streamFor(licTrack).url)
        assertEquals("Bearer tok", seen.single().getHeader("Authorization"))

        val e = assertFailsWith<StreamException> { api().streamFor(licTrack) }
        assertEquals(StreamException.Kind.NEED_SIGN_IN, e.kind)
        route("/api/play/u1") { json("{}", 404) }
        assertEquals(StreamException.Kind.NOT_FOUND, assertFailsWith<StreamException> { api(token = "tok").streamFor(licTrack) }.kind)
        route("/api/play/u1") { json("{}", 401) }
        assertEquals(StreamException.Kind.NEED_SIGN_IN, assertFailsWith<StreamException> { api(token = "tok").streamFor(licTrack) }.kind)
    }

    @Test
    fun `other tracks stream through apiblink and relative links become absolute`() = runBlocking {
        route("/api/apiblink/play") { json("""{"track":{"title":"Alive","streamUrl":"/api/apiblink/stream/abc","duration":215}}""") }
        assertEquals("$base/api/apiblink/stream/abc", api().streamFor(plain).url)
        val q = seen.single().requestUrl!!
        assertEquals("Band", q.queryParameter("artist"))
        assertEquals("Alive", q.queryParameter("title"))
        assertNull(seen.single().getHeader("Authorization"))

        route("/api/apiblink/play") { json("""{"error":{"code":"apiblink_unavailable"}}""", 503) }
        assertEquals(StreamException.Kind.UNAVAILABLE, assertFailsWith<StreamException> { api().streamFor(plain) }.kind)
        route("/api/apiblink/play") { json("{}", 404) }
        assertEquals(StreamException.Kind.NOT_FOUND, assertFailsWith<StreamException> { api().streamFor(plain) }.kind)
        route("/api/apiblink/play") { json("""{"track":{}}""") }
        assertEquals(StreamException.Kind.NOT_FOUND, assertFailsWith<StreamException> { api().streamFor(plain) }.kind)
        assertEquals("https://jamendo/x.mp3", api().streamFor(plain.copy(stream = "https://jamendo/x.mp3")).url)
    }

    @Test
    fun `absolute fixes relative and leaked local urls`() {
        val c = config()
        assertEquals("$base/api/x", c.absolute("/api/x"))
        assertEquals("$base/api/x", c.absolute("http://127.0.0.1:3000/api/x"))
        assertEquals("$base/api/x", c.absolute("http://localhost/api/x"))
        assertEquals("https://cdn.example/a.mp3", c.absolute("https://cdn.example/a.mp3"))
        assertEquals("https://cdn.example/a.mp3", c.absolute("//cdn.example/a.mp3"))
        assertNull(c.absolute(null))
        assertNull(c.absolute(""))
    }

    @Test
    fun `blink plus status`() = runBlocking {
        val future = java.time.OffsetDateTime.now().plusDays(10).toString()
        route("/api/plus/me") { json("""{"active":true,"plus_until":"$future"}""") }
        val on = assertNotNull(api(token = "t").plus())
        assertTrue(on.active)
        assertTrue(on.untilMs!! > System.currentTimeMillis())
        route("/api/plus/me") { json("""{"active":false,"plus_until":null}""") }
        val off = assertNotNull(api(token = "t").plus())
        assertFalse(off.active)
        assertNull(off.untilMs)
        assertNull(api().plus(), "без входа статуса нет")
        route("/api/plus/me") { json("{}", 500) }
        assertNull(api(token = "t").plus())
    }

    @Test
    fun `dedupe key and art scaling follow the web client`() {
        assertEquals(BlinkApi.dedupeKey(Track("1", "Alive!", "BAND")), BlinkApi.dedupeKey(Track("2", "alive", "Band")))
        assertEquals("https://x/600x600bb.jpg", BlinkApi.scaleArt("https://x/100x100bb.jpg", 600))
        assertEquals("https://avatars/get/600x600", BlinkApi.scaleArt("https://avatars/get/200x200", 600))
        assertEquals("https://other/pic.png", BlinkApi.scaleArt("https://other/pic.png", 600))
        assertEquals("", BlinkApi.scaleArt("", 600))
    }

    // ---------- вход ----------

    private class MemStore : SessionStore {
        var value: String? = null
        override fun load() = value
        override fun save(value: String?) { this.value = value }
    }

    private fun grant(access: String, refresh: String, expiresIn: Long = 3600) =
        """{"access_token":"$access","token_type":"bearer","expires_in":$expiresIn,"refresh_token":"$refresh",
            "user":{"id":"u-1","email":"me@example.com","user_metadata":{"full_name":"Ayori"}}}"""

    @Test
    fun `password sign in stores the session and refresh runs before expiry`() = runBlocking {
        var clock = 1_000_000L
        val store = MemStore()
        val auth = SupabaseAuth(OkHttpClient(), config(), store) { clock }
        route("/auth/v1/token") { req ->
            when (req.requestUrl?.queryParameter("grant_type")) {
                "password" -> json(grant("acc1", "ref1", expiresIn = 3600))
                "refresh_token" -> json(grant("acc2", "ref2", expiresIn = 3600))
                else -> json("{}", 400)
            }
        }
        val s = auth.signIn(" me@example.com ", "pw")
        assertEquals("acc1", s.accessToken)
        assertEquals("Ayori", s.name)
        assertEquals("me@example.com", s.email)
        assertEquals(clock + 3_600_000, s.expiresAtMs)
        val first = seen.single()
        assertEquals("anon", first.getHeader("apikey"))
        assertTrue(first.body.readUtf8().contains(""""email":"me@example.com""""), "почта обрезана по краям")
        assertNotNull(store.value)

        assertEquals("acc1", auth.accessToken())
        assertEquals(1, seen.size, "токен живой, сеть не трогаем")
        clock += 3_600_000 - 30_000 // меньше минуты до конца
        assertEquals("acc2", auth.accessToken())
        assertEquals("ref2", auth.session.value?.refreshToken)

        val restored = SupabaseAuth(OkHttpClient(), config(), store) { clock }
        assertNull(restored.session.value)
        restored.restore()
        assertEquals("acc2", restored.session.value?.accessToken)
    }

    @Test
    fun `bad password, network loss and revoked refresh token`() = runBlocking {
        var clock = 1_000_000L
        val store = MemStore()
        val auth = SupabaseAuth(OkHttpClient(), config(), store) { clock }
        route("/auth/v1/token") { json("""{"error":"invalid_grant","error_description":"Invalid login credentials"}""", 400) }
        assertEquals(AuthException.Kind.BAD_CREDENTIALS, assertFailsWith<AuthException> { auth.signIn("a@b.c", "x") }.kind)
        assertNull(store.value)

        route("/auth/v1/token") { json(grant("acc1", "ref1", expiresIn = 100)) }
        auth.signIn("a@b.c", "x")
        clock += 90_000 // до конца 10 секунд, пора обновлять
        route("/auth/v1/token") { json("""{"error":"invalid_grant"}""", 400) }
        val token = auth.accessToken()
        assertEquals("acc1", token, "пока токен не истёк, отдаём его, даже если обновить не вышло")
        assertNull(auth.session.value, "refresh-токен отозван: сессия сброшена")
        assertNull(store.value)

        route("/auth/v1/token") { json(grant("acc3", "ref3", expiresIn = 100)) }
        auth.signIn("a@b.c", "x")
        clock += 150_000 // токен истёк
        server.shutdown()
        assertNull(auth.accessToken(), "нет сети и токен просрочен")
        assertNotNull(auth.session.value, "сессию из-за сети не сбрасываем")

        assertEquals(AuthException.Kind.NETWORK, assertFailsWith<AuthException> { auth.signIn("a@b.c", "x") }.kind)
        Unit
    }

    @Test
    fun `sign in without a key in the build says so`() = runBlocking {
        val auth = SupabaseAuth(OkHttpClient(), config(key = ""), MemStore())
        assertFalse(auth.configured)
        assertEquals(AuthException.Kind.NOT_CONFIGURED, assertFailsWith<AuthException> { auth.signIn("a@b.c", "x") }.kind)
        assertTrue(seen.isEmpty())
        Unit
    }
}
