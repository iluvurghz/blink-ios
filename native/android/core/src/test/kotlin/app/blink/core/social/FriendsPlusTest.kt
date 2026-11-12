package app.blink.core.social

import app.blink.core.model.Track
import app.blink.core.net.BlinkConfig
import app.blink.core.net.KeyValue
import app.blink.core.net.TokenProvider
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest

private class Mem : KeyValue {
    val m = HashMap<String, String>()
    override fun get(key: String) = m[key]
    override fun put(key: String, value: String?) {
        if (value == null) m.remove(key) else m[key] = value
    }
}

class FriendsPlusApiTest {
    private val server = MockWebServer()
    private val seen = java.util.concurrent.CopyOnWriteArrayList<RecordedRequest>()
    private val routes = java.util.concurrent.ConcurrentHashMap<String, (RecordedRequest) -> MockResponse>()

    init {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                seen.add(request)
                return routes[request.requestUrl?.encodedPath ?: ""]?.invoke(request) ?: MockResponse().setResponseCode(404).setBody("{}")
            }
        }
        server.start()
    }

    @AfterTest
    fun tearDown() = server.shutdown()

    private val cfg get() = BlinkConfig(baseUrl = server.url("/").toString().trimEnd('/'))
    private val tok = TokenProvider { "tok" }
    private fun json(body: String, code: Int = 200) = MockResponse().setResponseCode(code).setHeader("Content-Type", "application/json").setBody(body)

    @Test
    fun `friends list parses listening state`() = runBlocking {
        routes["/api/friends"] = {
            json("""{"friends":[{"id":"a","name":"Аня","avatar":"https://x/a.jpg","listening":{"track":{"id":"1","title":"T","artist":"A","artwork":""},"room":"r1"}},
                {"id":"b","name":"Боря","avatar":"","listening":null}],"hidden":true}""")
        }
        val l = assertNotNull(FriendsApi(OkHttpClient(), cfg, tok).list())
        assertTrue(l.hidden)
        assertEquals("r1", l.friends[0].room)
        assertTrue(l.friends[0].listening)
        assertFalse(l.friends[1].listening)
    }

    @Test
    fun `accepting a stale invite throws the server text`() = runBlocking {
        routes["/api/friends/accept"] = { json("""{"error":"Ссылка устарела или не работает"}""", 404) }
        val e = assertFailsWith<FriendsException> { FriendsApi(OkHttpClient(), cfg, tok).accept("zzz") }
        assertEquals("Ссылка устарела или не работает", e.message)
    }

    @Test
    fun `invite links round trip`() {
        assertEquals("https://blinkmusic.cc/?friend=abc12345", FriendsApi.link("abc12345"))
        assertEquals("abc12345", FriendsApi.codeFrom("https://blinkmusic.cc/?friend=abc12345"))
        assertNull(FriendsApi.codeFrom("https://blinkmusic.cc/"))
    }

    @Test
    fun `plus config is parsed, cached and falls back`() = runBlocking {
        val mem = Mem()
        val api = PlusApi(OkHttpClient(), cfg, tok, mem)
        assertEquals(PlusConfig.FALLBACK, api.cached())
        routes["/api/plus/config"] = {
            json("""{"title":"Blink+","lead":"L","plans":[{"id":"month","label":"Месяц","price":199,"days":30,"tag":"хит"},{"id":"year","label":"Год","price":1200,"days":365,"old":2388}],
                "perks":[{"icon":"bolt","title":"P","text":"t"}],"compare":[{"label":"X","free":false,"plus":true}],"tiers":[{"name":"Хранитель","from":50},{"name":"II","from":1000}]}""")
        }
        val c = assertNotNull(api.config())
        assertEquals(199, c.plans[0].price)
        assertEquals(100, c.plans[1].monthly)
        assertEquals(2, c.tiers.size)
        assertEquals(0, c.tierFor(10))
        assertEquals(1, c.tierFor(50))
        assertEquals(2, c.tierFor(5000))
        assertEquals(c, api.cached())
    }

    @Test
    fun `me, promo and checkout`() = runBlocking {
        val api = PlusApi(OkHttpClient(), cfg, tok)
        routes["/api/plus/me"] = { json("""{"active":true,"plus_until":"2027-01-01T00:00:00+00:00","supporter_since":"2026-01-01","donated":120,"keeper_tier":1}""") }
        val me = assertNotNull(api.me())
        assertTrue(me.active)
        assertEquals(1798588800000, me.untilMs)
        assertEquals(1, me.keeperTier)

        routes["/api/plus/promo"] = { json("""{"kind":"discount","code":"HI","percent":20}""") }
        assertEquals(PromoResult.Discount("HI", 20), api.promo("hi"))
        routes["/api/plus/promo"] = { json("""{"error":"Такого промокода нет"}""", 400) }
        assertEquals("Такого промокода нет", assertFailsWith<PlusException> { api.promo("x") }.message)

        routes["/api/plus/checkout"] = { json("""{"pay_url":"https://pay.example/1","amount":149}""") }
        assertEquals("https://pay.example/1", api.checkout("month", null))
        assertTrue(seen.last().body.readUtf8().contains("\"plan\":\"month\""))
        routes["/api/plus/donate"] = { json("""{"error":"Оплата пока не настроена"}""", 503) }
        assertEquals("Оплата пока не настроена", assertFailsWith<PlusException> { api.donate(100) }.message)
        assertIs<PromoResult.Discount>(PromoResult.Discount("a", 1))
    }
}

@kotlinx.coroutines.ExperimentalCoroutinesApi
class FriendsModelTest {
    private class Fake : FriendsService {
        val acts = ArrayList<String>()
        var list = FriendsList(listOf(Friend("a", "Аня", "", null, null)), false)
        var okHide = true
        override suspend fun list() = list
        override suspend fun invite() = "code1"
        override suspend fun accept(code: String) = if (code == "bad") throw FriendsException("Это ваша собственная ссылка") else "Аня"
        override suspend fun remove(id: String) = true
        override suspend fun setHidden(hidden: Boolean) = okHide
        override suspend fun activity(track: FriendTrack?, room: String) {
            acts.add("${track?.id}|$room")
        }
    }

    @Test
    fun `activity is sent on change only, and never while hidden`() = runTest {
        val f = Fake()
        val said = ArrayList<String>()
        val m = FriendsModel(f, CoroutineScope(UnconfinedTestDispatcher(testScheduler) + SupervisorJob()), { said.add(it) })
        val t = Track("1", "T", "A")
        m.report(true, t, null)
        m.report(true, t, null)
        m.report(true, t, "r1")
        m.report(false, t, "r1")
        advanceUntilIdle()
        assertEquals(listOf("1|", "1|r1", "null|r1"), f.acts)
        m.refresh()
        m.setHidden(true)
        m.report(true, Track("2", "T", "A"), null)
        advanceUntilIdle()
        assertEquals(3, f.acts.size)
    }

    @Test
    fun `hide rolls back when the server refuses and accept explains`() = runTest {
        val f = Fake().apply { okHide = false }
        val said = ArrayList<String>()
        val m = FriendsModel(f, CoroutineScope(UnconfinedTestDispatcher(testScheduler) + SupervisorJob()), { said.add(it) })
        m.setHidden(true)
        assertFalse(m.state.value.hidden)
        assertEquals(listOf("Не получилось сохранить"), said)
        assertFalse(m.accept("bad"))
        assertTrue(m.accept("ok"))
        assertEquals("Теперь вы друзья с Аня", said.last())
        assertEquals("https://blinkmusic.cc/?friend=code1", m.invite())
    }
}
