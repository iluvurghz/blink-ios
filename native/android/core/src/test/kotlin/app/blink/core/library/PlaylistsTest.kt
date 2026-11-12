package app.blink.core.library

import app.blink.core.model.Track
import app.blink.core.net.BlinkConfig
import app.blink.core.wave.BlobStore
import app.blink.core.wave.LibraryStore
import app.blink.core.wave.Playlist
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest

private class MemBlob : BlobStore {
    var text: String? = null
    override fun load() = text
    override fun save(value: String?) {
        text = value
    }
}

private fun t(id: String) = Track(id = id, title = "T$id", artist = "A")

class PlaylistsTest {
    @Test
    fun createAddRemoveRenameDelete() {
        val lib = LibraryStore(MemBlob())
        val p = lib.createPlaylist("  Дорога ", now = 1000)
        assertEquals("Дорога", p.name)
        assertEquals("p" + 1000L.toString(36), p.id)
        assertTrue(lib.addToPlaylist(p.id, t("1")))
        assertFalse(lib.addToPlaylist(p.id, t("1")), "дубль не добавляется")
        assertTrue(lib.addToPlaylist(p.id, t("2")))
        assertEquals(listOf("1", "2"), lib.playlist(p.id)!!.tracks.map { it.id })
        lib.removeFromPlaylist(p.id, "1")
        assertEquals(listOf("2"), lib.playlist(p.id)!!.tracks.map { it.id })
        lib.renamePlaylist(p.id, "Ночь")
        assertEquals("Ночь", lib.playlist(p.id)!!.name)
        lib.renamePlaylist(p.id, "   ")
        assertEquals("Ночь", lib.playlist(p.id)!!.name)
        lib.deletePlaylist(p.id)
        assertTrue(lib.playlists.isEmpty())
        assertEquals("Новый плейлист", lib.createPlaylist("", now = 5).name)
    }

    @Test
    fun survivesRestartAndKeepsSiteFields() {
        val blob = MemBlob()
        val lib = LibraryStore(blob)
        lib.createPlaylist("A", listOf(t("1")), now = 10)
        val again = LibraryStore(blob)
        assertEquals(listOf("A"), again.playlists.map { it.name })
        assertEquals("1", again.playlists[0].tracks[0].id)
    }

    @Test
    fun mergeKeepsBothSidesAndLocalWins() {
        val lib = LibraryStore(MemBlob())
        val mine = lib.createPlaylist("Моё", listOf(t("1")), now = 2000)
        fun pl(id: String, name: String, created: Long, vararg ids: String) = buildJsonObject {
            put("id", JsonPrimitive(id))
            put("name", JsonPrimitive(name))
            put("created", JsonPrimitive(created))
            put("tracks", JsonArray(ids.map { i -> buildJsonObject { put("id", JsonPrimitive(i)); put("title", JsonPrimitive("T$i")); put("artist", JsonPrimitive("A")) } }))
        }
        lib.mergeRemote(JsonObject(mapOf("playlists" to JsonArray(listOf(pl(mine.id, "Старое имя", 2000, "9", "1"), pl("pz", "С сайта", 3000, "5"))))))
        val list = lib.playlists
        assertEquals(listOf("pz", mine.id), list.map { it.id }, "новые первыми")
        val m = list.first { it.id == mine.id }
        assertEquals("Моё", m.name)
        assertEquals(listOf("1", "9"), m.tracks.map { it.id })
    }

    @Test
    fun deepLinks() {
        assertEquals(DeepLink.Room("abc123"), DeepLink.parse("https://blinkmusic.cc/r/abc123"))
        assertEquals(DeepLink.Room("abc123"), DeepLink.parse("blink://together?together=abc123"))
        assertEquals(DeepLink.Friend("fr1x"), DeepLink.parse("https://blinkmusic.cc/?friend=fr1x"))
        assertEquals(DeepLink.Playlist("k3j4h5"), DeepLink.parse("https://blinkmusic.cc/p/k3j4h5"))
        assertEquals(DeepLink.Playlist("k3j4h5"), DeepLink.parse("https://blinkmusic.cc/?playlist=k3j4h5"))
        assertEquals(DeepLink.Artist("nick.x"), DeepLink.parse("https://www.blinkmusic.cc/u/Nick.X"))
        assertEquals(DeepLink.Track("Xk3p9aQ"), DeepLink.parse("https://blinkmusic.cc/t/Xk3p9aQ"))
        assertEquals(DeepLink.Track("Xk3p9aQ"), DeepLink.parse("https://t.blinkmusic.cc/Xk3p9aQ"))
        assertEquals(DeepLink.Track("b:11111111-2222-3333-4444-555555555555"), DeepLink.parse("https://blinkmusic.cc/t/b%3A11111111-2222-3333-4444-555555555555"))
        assertEquals(DeepLink.Track("yt1", "Песня", "Артист"), DeepLink.parse("https://blinkmusic.cc/t/yt1?n=%D0%9F%D0%B5%D1%81%D0%BD%D1%8F&a=%D0%90%D1%80%D1%82%D0%B8%D1%81%D1%82"))
        assertNull(DeepLink.parse("https://example.com/p/abc"))
        assertNull(DeepLink.parse(null))
    }

    @Test
    fun sharedApi() = runBlocking {
        val server = MockWebServer()
        val seen = java.util.concurrent.CopyOnWriteArrayList<RecordedRequest>()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                seen.add(request)
                val p = request.path.orEmpty()
                return when {
                    p.startsWith("/sb/rest/v1/shared_playlists") && request.method == "GET" && p.contains("code=eq.abc") ->
                        MockResponse().setBody("""[{"code":"abc","owner_name":"Аня","data":{"name":"Лето","tracks":[{"id":"1","title":"x","artist":"y"}]}}]""")
                    p.startsWith("/sb/rest/v1/shared_playlists") && request.method == "GET" -> MockResponse().setBody("[]")
                    p.startsWith("/sb/rest/v1/shared_playlists") && request.method == "POST" -> MockResponse().setResponseCode(201)
                    p == "/api/share/track" -> MockResponse().setBody("""{"code":"Xk3p9aQ","url":"x"}""")
                    p == "/api/share/track/Xk3p9aQ" -> MockResponse().setBody("""{"id":"b:11111111-2222-3333-4444-555555555555","title":"Т","artist":"Я","artwork":"https://blinkmusic.cc/c.jpg"}""")
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }
        server.start()
        try {
            val base = server.url("/").toString().trimEnd('/')
            val api = SharedApi(OkHttpClient(), BlinkConfig(baseUrl = base, supabaseUrl = base, supabaseAnonKey = "anon"), null, { "u1" }, { "Я" })
            val s = api.fetchShared("abc")!!
            assertEquals("Лето", s.name)
            assertEquals("Аня", s.owner)
            assertEquals(listOf("1"), s.tracks.map { it.id })
            assertNull(api.fetchShared("nope"))
            assertEquals("https://blinkmusic.cc/p/zzz", api.share(Playlist("p1", "N", 1, listOf(Track("1", "x", "y")), null)) { "zzz" })
            val post = seen.first { it.method == "POST" }
            assertTrue(post.body.readUtf8().contains("\"owner_id\":\"u1\""))
            assertEquals("${base}/t/Xk3p9aQ", api.trackLink(Track("yt1", "x", "y")))
            val m = api.resolveTrack("Xk3p9aQ")!!
            val track = m.toTrack()
            assertEquals("11111111-2222-3333-4444-555555555555", track.lic)
            assertEquals("blink", track.source)
            assertNull(api.resolveTrack("22222222"))
            assertTrue(api.longTrackLink(Track("yt1", "Пе", "А")).startsWith("$base/t/yt1?n="))
        } finally {
            server.shutdown()
        }
    }
}

class ArtistApiTest {
    @Test
    fun profileFollowAndMissing() = runBlocking {
        val server = MockWebServer()
        val seen = java.util.concurrent.CopyOnWriteArrayList<RecordedRequest>()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                seen.add(request)
                val p = request.path.orEmpty()
                return when {
                    p.startsWith("/sb/rest/v1/artists") && p.contains("handle=eq.nick") ->
                        MockResponse().setBody("""[{"id":"a1","user_id":"u9","name":"Ник","handle":"nick","bio":"Привет","avatar_url":"https://x/a.jpg","verified":false}]""")
                    p.startsWith("/sb/rest/v1/artists") -> MockResponse().setBody("[]")
                    p.startsWith("/sb/rest/v1/lic_tracks") ->
                        MockResponse().setBody("""[{"id":"11111111-2222-3333-4444-555555555555","title":"Песня","artist_name":"Ник","duration":180,"cover_path":"c"}]""")
                    p.startsWith("/sb/rest/v1/rpc/artist_stats") -> MockResponse().setBody("""[{"followers":"12","likes":5}]""")
                    p.startsWith("/sb/rest/v1/follows") && request.method == "GET" -> MockResponse().setBody("""[{"artist_id":"a1"}]""")
                    p.startsWith("/sb/rest/v1/follows") -> MockResponse().setResponseCode(201)
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }
        server.start()
        try {
            val base = server.url("/").toString().trimEnd('/')
            val cfg = BlinkConfig(baseUrl = base, supabaseUrl = base, supabaseAnonKey = "anon")
            val http = OkHttpClient()
            val api = ArtistApi(http, cfg, null, app.blink.core.net.BlinkApi(http, cfg), { "u1" })
            val a = api.profile("nick")!!
            assertEquals("Ник", a.name)
            assertEquals(12L, a.followers)
            assertEquals(5L, a.likes)
            assertEquals(listOf("b:11111111-2222-3333-4444-555555555555"), a.tracks.map { it.id })
            assertNull(api.profile("ghost"))
            assertTrue(api.isFollowing("a1"))
            assertTrue(api.setFollow("a1", true))
            assertTrue(seen.any { it.method == "POST" && it.path!!.startsWith("/sb/rest/v1/follows") })
        } finally {
            server.shutdown()
        }
    }
}
