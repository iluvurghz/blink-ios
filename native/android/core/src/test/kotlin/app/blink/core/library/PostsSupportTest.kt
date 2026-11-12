package app.blink.core.library

import app.blink.core.net.BlinkApi
import app.blink.core.net.BlinkConfig
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest

private fun serve(handler: (RecordedRequest) -> MockResponse, block: suspend (BlinkConfig, OkHttpClient, List<RecordedRequest>) -> Unit) = runBlocking {
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
        block(BlinkConfig(baseUrl = base, supabaseUrl = base, supabaseAnonKey = "anon"), OkHttpClient(), seen)
    } finally {
        server.shutdown()
    }
    Unit
}

class PostsApiTest {
    @Test
    fun feedCommentsAndErrors() = serve({ r ->
        val p = r.path.orEmpty()
        when {
            p.startsWith("/sb/rest/v1/rpc/post_list") ->
                MockResponse().setBody("""[{"id":"p1","artist_id":"a1","artist_name":"Ник","avatar_url":null,"body":"Новый трек","track_id":"11111111-2222-3333-4444-555555555555","created_at":"2026-11-01T10:00:00Z","likes":"3","liked":true}]""")
            p.startsWith("/sb/rest/v1/lic_tracks") ->
                MockResponse().setBody("""[{"id":"11111111-2222-3333-4444-555555555555","title":"Песня","artist_name":"Ник","duration":180,"cover_path":"c"}]""")
            p.startsWith("/sb/rest/v1/rpc/comment_list") ->
                MockResponse().setBody("""[{"id":"c1","user_id":"u2","artist_id":null,"name":"Аня","avatar":null,"body":"Огонь","created_at":"2026-11-01T11:00:00Z"}]""")
            p.startsWith("/sb/rest/v1/posts") && r.method == "POST" -> MockResponse().setResponseCode(400).setBody("""{"message":"too_often"}""")
            p.startsWith("/sb/rest/v1/comments") && r.method == "POST" -> MockResponse().setResponseCode(201)
            p.startsWith("/sb/rest/v1/post_likes") -> MockResponse().setResponseCode(409)
            p.startsWith("/sb/rest/v1/reports") -> MockResponse().setResponseCode(409)
            p.startsWith("/sb/rest/v1/artists") && r.method == "PATCH" -> MockResponse().setResponseCode(204)
            else -> MockResponse().setResponseCode(404)
        }
    }) { cfg, http, seen ->
        val api = PostsApi(http, cfg, null, BlinkApi(http, cfg), { "u1" })
        val list = api.posts("a1")
        assertEquals(1, list.size)
        assertEquals(3L, list[0].likes)
        assertTrue(list[0].liked)
        assertEquals("Песня", list[0].track?.title)
        val c = api.comments(postId = "p1")
        assertEquals("Аня", c.single().name)
        val e = assertFailsWith<SharedError> { api.createPost("a1", "x", null) }
        assertEquals("Анонс можно публиковать раз в 10 минут", e.message)
        api.addComment("  Класс  ", postId = "p1")
        assertTrue(seen.any { it.method == "POST" && it.path!!.startsWith("/sb/rest/v1/comments") && it.body.readUtf8().contains("\"Класс\"") })
        assertFailsWith<SharedError> { api.addComment("   ", postId = "p1") }
        assertTrue(api.setPostLike("p1", true), "повтор лайка не ошибка")
        api.report("post", "p1")
        api.saveBio("a1", "  Привет ")
        assertTrue(seen.any { it.method == "PATCH" && it.body.readUtf8().contains("Привет") })
    }
}

class SupportApiTest {
    @Test
    fun faqTicketAndErrors() = serve({ r ->
        val p = r.path.orEmpty()
        when {
            p == "/api/support/faq" -> MockResponse().setBody("""{"faq":[{"id":"1","question":"Как скачать?","answer":"Нужен Blink+","keywords":"скачать, офлайн"},{"id":"2","question":"Пароль","answer":"Сбросьте","keywords":"пароль"}]}""")
            p == "/api/support/ticket" -> MockResponse().setBody("""{"id":"t1","auto":{"question":"Как скачать?","answer":"Нужен Blink+"}}""")
            p == "/api/support/mine" -> MockResponse().setBody("""{"tickets":[{"id":"t1","kind":"question","message":"Привет","status":"answered","last_author":"team","updated_at":"2026-11-01"}]}""")
            p == "/api/support/ticket/t1" -> MockResponse().setBody("""{"ticket":{"id":"t1","kind":"question","message":"Привет","status":"open","attachments":["https://x/a.jpg"]},"auto":null,"messages":[{"id":"m1","author":"team","body":"Здравствуйте","attachments":[],"created_at":"2026-11-01"}]}""")
            p == "/api/support/ticket/t1/message" -> MockResponse().setBody("""{"message":{"id":"m2","author":"user","body":"Спасибо","attachments":[],"created_at":"2026-11-02"}}""")
            p == "/api/support/ticket/t2" -> MockResponse().setResponseCode(404).setBody("""{"error":"Обращение не найдено"}""")
            else -> MockResponse().setResponseCode(500)
        }
    }) { cfg, http, _ ->
        val api = SupportApi(http, cfg, null)
        val faq = api.faq()
        assertEquals("1", SupportApi.bestAnswer(faq, "Как СКАЧАТЬ треки офлайн")?.id)
        assertNull(SupportApi.bestAnswer(faq, "ничего"))
        val sent = api.send("Привет", "a@b.c")
        assertEquals("t1", sent.id)
        assertEquals("Нужен Blink+", sent.autoAnswer)
        assertEquals("answered", api.mine().single().status)
        val t = api.open("t1")
        assertEquals(listOf("https://x/a.jpg"), t.images)
        assertEquals("team", t.messages.single().author)
        assertEquals("Спасибо", api.reply("t1", "Спасибо").body)
        assertEquals("Обращение не найдено", assertFailsWith<SharedError> { api.open("t2") }.message)
        assertNotNull(assertFailsWith<SharedError> { api.mine().also { api.open("zz") } }.message)
    }
}

class CabinetAndLastfmTest {
    @Test
    fun cabinetUploadAndChecks() = serve({ r ->
        val p = r.path.orEmpty()
        when {
            p == "/api/artist/me" -> MockResponse().setBody("""{"artist":{"id":"a1","name":"Ник","handle":"nick","bio":null,"offer_accepted_at":"2026-11-01"}}""")
            p == "/api/tracks/mine" -> MockResponse().setBody("""{"tracks":[{"id":"t1","title":"Песня","release_title":"EP","status":"live","release_date":"2026-11-01","explicit":false,"cover_url":"https://x/c.jpg","streams":{"total":10,"this_month":4}}]}""")
            p == "/api/tracks" && r.method == "POST" -> MockResponse().setBody("""{"track":{"id":"new1"}}""")
            p.startsWith("/api/tracks/") && r.method == "DELETE" -> MockResponse().setBody("""{"ok":true}""")
            else -> MockResponse().setResponseCode(404)
        }
    }) { cfg, http, seen ->
        val api = CabinetApi(http, cfg, null)
        assertTrue(api.me()!!.offerAccepted)
        val mine = api.mine().single()
        assertEquals(4L, mine.streamsMonth)
        val audio = java.io.File.createTempFile("aud", ".mp3").apply { writeBytes(ByteArray(5000) { 1 }); deleteOnExit() }
        val cover = java.io.File.createTempFile("cov", ".jpg").apply { writeBytes(ByteArray(800) { 2 }); deleteOnExit() }
        val af = UploadFile("a.mp3", "audio/mpeg", audio)
        val cf = UploadFile("c.jpg", "image/jpeg", cover)
        val d = UploadDraft("Песня", "EP", "Ник, Аня", "Ник", "2026", "Поп", "Русский", "2026-11-12", rights = true)
        assertEquals("Подтвердите права на трек", api.check(d.copy(rights = false), af, cf))
        assertEquals("Укажите авторов музыки и текста", api.check(d.copy(authors = " , "), af, cf))
        assertEquals("Не заполнено поле «Жанр»", api.check(d.copy(genre = ""), af, cf))
        assertEquals("Прикрепите обложку", api.check(d, af, null))
        val marks = mutableListOf<Double>()
        assertEquals("new1", api.upload(d, af, cf) { marks.add(it) })
        assertEquals(1.0, marks.last())
        val req = seen.first { it.path == "/api/tracks" }
        val text = req.body.readUtf8()
        assertTrue(text.contains("name=\"authors\"") && text.contains("музыка и текст"))
        assertTrue(text.contains("name=\"rights\"") && text.contains("true"))
        api.takedown("t1")
    }

    @Test
    fun lastfm() = serve({ r ->
        val p = r.path.orEmpty()
        when {
            p.contains("method=artist.getinfo") && p.contains("artist=Kahoma") -> MockResponse().setBody("""{"artist":{"name":"Kaoma","stats":{"listeners":"99"}}}""")
            p.contains("method=artist.getinfo") -> MockResponse().setBody("""{"artist":{"name":"Ник","stats":{"listeners":"12345"}}}""")
            p.contains("method=artist.getsimilar") -> MockResponse().setBody("""{"similarartists":{"artist":[{"name":"Аня","match":"0.8"},{"name":"Слабый","match":"0.1"},{"name":"Ник и друзья","match":"0.9"}]}}""")
            p.contains("method=track.getsimilar") -> MockResponse().setBody("""{"similartracks":{"track":[{"name":"Песня 2","artist":{"name":"Аня"}}]}}""")
            else -> MockResponse().setResponseCode(503).setBody("""{"error":"lastfm_off"}""")
        }
    }) { cfg, http, seen ->
        val api = LastfmApi(http, cfg)
        assertEquals(12345L, api.listeners("Ник feat. Аня"))
        assertNull(api.listeners("Kahoma"), "тёзка вместо артиста не показывается")
        assertEquals(listOf("Аня"), api.similarArtists("Ник").map { it.name })
        assertEquals("Песня 2", api.similarTracks("Ник", "Трек (feat. X)").single().title)
        assertTrue(seen.any { it.path!!.contains("track=%D0%A2%D1%80%D0%B5%D0%BA") && !it.path!!.contains("feat") })
        assertEquals("Ник", LastfmApi.mainName("Ник & Аня"))
        assertEquals(12345L, api.listeners("Ник feat. Аня"))
        assertEquals(1, seen.count { it.path!!.contains("artist=%D0%9D%D0%B8%D0%BA") && it.path!!.contains("getinfo") }, "второй раз из кеша")
    }
}
