package app.blink.core.social

import app.blink.core.model.Track
import app.blink.core.net.BlinkConfig
import app.blink.core.net.TokenProvider
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest

private const val ROOM = """{"code":"abc123","rev":5,"v":3,"chat":[{"id":"m1","by":"u2","name":"Аня","text":"привет","at":1000}],
  "track":{"id":"111","title":"Alive","artist":"Band","year":2024,"duration":200,"artwork":"https://x/y.jpg"},
  "queue":[{"id":"111","title":"Alive","artist":"Band"},{"id":"222","title":"Next","artist":"Band"}],
  "index":0,"playing":true,"pos":12.5,"at":100000,"by":"u1","host":"u1","mode":"host","skips":["u2"],
  "reactions":[{"id":"r1","by":"u2","name":"Аня","emoji":"🔥","at":99000}],
  "members":[{"id":"u1","name":"Я","host":true},{"id":"u2","name":"Аня","host":false}],"now":100500}"""

class RoomModelTest {
    @Test
    fun `room parses with numeric year and computes target`() {
        val r = assertNotNull(RoomState.parse(ROOM))
        assertEquals("abc123", r.code)
        assertEquals(5, r.rev)
        assertEquals(3, r.v)
        assertEquals("2024", r.track?.year)
        assertEquals(2, r.queue.size)
        assertEquals("host", r.mode)
        assertEquals(listOf("u2"), r.skips)
        assertEquals(2, r.members.size)
        assertTrue(r.isHost("u1"))
        // прошло 1,5 с по серверным часам: 12.5 + 1.5
        assertEquals(14000, r.targetMs(localNowMs = 101_500, offsetMs = 0))
        // часы сервера отстают на 1 с от наших
        assertEquals(14000, r.targetMs(localNowMs = 102_500, offsetMs = -1000))
        assertEquals(12500, r.copy(playing = false).targetMs(101_500, 0))
    }

    @Test
    fun `room codes come from links`() {
        assertEquals("abc123", RoomSession.codeFrom("https://blinkmusic.cc/r/abc123"))
        assertEquals("abc123", RoomSession.codeFrom("https://blinkmusic.cc/?together=abc123"))
        assertNull(RoomSession.codeFrom("https://example.com/"))
        assertEquals("https://blinkmusic.cc/r/zz99", RoomSession.link("zz99"))
    }
}

class RoomApiTest {
    private val server = MockWebServer()
    private val seen = java.util.concurrent.CopyOnWriteArrayList<RecordedRequest>()
    private val routes = java.util.concurrent.ConcurrentHashMap<String, (RecordedRequest) -> MockResponse>()

    init {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                seen.add(request)
                return routes[request.requestUrl?.encodedPath ?: ""]?.invoke(request) ?: MockResponse().setResponseCode(404).setBody("""{"error":"Комната закрыта"}""")
            }
        }
        server.start()
    }

    @AfterTest
    fun tearDown() = server.shutdown()

    private val api get() = RoomApi(OkHttpClient(), BlinkConfig(baseUrl = server.url("/").toString().trimEnd('/')), TokenProvider { "tok" })
    private fun json(body: String, code: Int = 200) = MockResponse().setResponseCode(code).setHeader("Content-Type", "application/json").setBody(body)

    @Test
    fun `create sends the token and returns the room`() = runBlocking {
        routes["/api/together"] = { json(ROOM) }
        val r = api.create()
        assertTrue(r.ok)
        assertEquals("abc123", r.room?.code)
        assertEquals("Bearer tok", seen.first().getHeader("Authorization"))
    }

    @Test
    fun `stale post returns the newer room with 409`() = runBlocking {
        routes["/api/together/abc123"] = { json(ROOM, 409) }
        val r = api.post("abc123", base = 1, playing = true, posSec = 3.0)
        assertEquals(409, r.status)
        assertEquals(5, r.room?.rev)
        val body = seen.first().body.readUtf8()
        assertTrue(body.contains("\"base\":1"), body)
        assertTrue(body.contains("\"playing\":true"), body)
    }

    @Test
    fun `post with a track sends queue and index`() = runBlocking {
        routes["/api/together/abc123"] = { json(ROOM) }
        val t = Track("1", "A", "B")
        api.post("abc123", 3, true, 0.0, t, listOf(t, Track("2", "C", "D")), 1)
        val body = seen.first().body.readUtf8()
        assertTrue(body.contains("\"queue\":["), body)
        assertTrue(body.contains("\"index\":1"), body)
    }

    @Test
    fun `stream reads data lines and ends when the server closes`() = runBlocking {
        routes["/api/together/abc123/stream"] = {
            MockResponse().setResponseCode(200).setHeader("Content-Type", "text/event-stream")
                .setBody("data: " + ROOM.replace("\n", "") + "\n\n: hb\n\ndata: " + ROOM.replace("\"rev\":5", "\"rev\":6").replace("\n", "") + "\n\n")
        }
        val got = ArrayList<Long>()
        val end = api.stream("abc123") { got.add(it.rev) }
        assertEquals(listOf(5L, 6L), got)
        assertEquals(StreamEnd.Dropped, end)
    }

    @Test
    fun `stream to a closed room reports gone`() = runBlocking {
        val end = api.stream("nope") { }
        assertIs<StreamEnd.Gone>(end)
        assertEquals("Комната закрыта", end.message)
    }
}

private class FakePort : RoomPlayerPort {
    var playback = LocalPlayback(null, false, 0)
    var queue: Pair<List<Track>, Int> = emptyList<Track>() to 0
    val calls = ArrayList<String>()
    override fun local() = playback
    override fun playQueue(queue: List<Track>, index: Int, positionMs: Long, playing: Boolean) {
        calls.add("play ${queue.size} $index $positionMs $playing")
        this.queue = queue to index
        playback = LocalPlayback(queue[index], playing, positionMs)
    }
    override fun setPlaying(playing: Boolean, positionMs: Long) {
        calls.add("set $playing $positionMs")
        playback = playback.copy(playing = playing, positionMs = positionMs)
    }
    override fun seekTo(positionMs: Long) {
        calls.add("seek $positionMs")
        playback = playback.copy(positionMs = positionMs)
    }
    override fun appendToQueue(tracks: List<Track>) {
        calls.add("append ${tracks.size}")
        queue = (queue.first + tracks) to queue.second
    }
    override fun queue() = queue
}

private class FakeService : RoomService {
    val posts = ArrayList<String>()
    var reply: RoomReply = RoomReply(200, null, null)
    override suspend fun create() = reply
    override suspend fun serverTime(): Long? = 100_000
    override suspend fun post(code: String, base: Long, playing: Boolean, posSec: Double, track: Track?, queue: List<Track>?, index: Int): RoomReply {
        posts.add("post base=$base playing=$playing pos=$posSec track=${track?.id}")
        return reply
    }
    override suspend fun chat(code: String, text: String) = reply
    override suspend fun react(code: String, emoji: String) = reply
    override suspend fun mode(code: String, mode: String) = reply
    override suspend fun enqueue(code: String, track: Track) = reply
    override suspend fun skip(code: String) = reply
    override suspend fun leave(code: String) {}
    override suspend fun stream(code: String, onRoom: (RoomState) -> Unit): StreamEnd = awaitCancellation()
    override suspend fun poll(code: String, rev: Long) = reply
}

@OptIn(ExperimentalCoroutinesApi::class)
class RoomSessionTest {
    private fun TestScope.bg() = CoroutineScope(UnconfinedTestDispatcher(testScheduler) + SupervisorJob())
    private val room = assertNotNull(RoomState.parse(ROOM))

    private fun session(scope: kotlinx.coroutines.CoroutineScope, service: FakeService, port: FakePort, said: MutableList<String>, now: () -> Long = { 101_500 }) =
        RoomSession(service, scope, port, { "u9" }, { said.add(it) }, nowMs = now, nanos = { 0 })

    @Test
    fun `joining follows the room's track from the right moment`() = runTest {
        val port = FakePort()
        val s = session(bg(), FakeService(), port, ArrayList())
        s.join("abc123")
        s.update(room.copy(code = "abc123"))
        advanceUntilIdle()
        // Часы: сервер впереди на 0 (clockOffset синхронизирован по serverTime=100000 при now=101500 → -1500).
        assertTrue(port.calls.single().startsWith("play 2 0 "), port.calls.toString())
        assertTrue(port.calls.single().endsWith(" true"))
        assertEquals("abc123", s.room.value?.code)
    }

    @Test
    fun `a pause in the room pauses us and is not sent back`() = runTest {
        val port = FakePort()
        val service = FakeService()
        var now = 101_500L
        val s = session(bg(), service, port, ArrayList(), { now })
        s.join("abc123")
        s.update(room)
        port.calls.clear()
        port.playback = port.playback.copy(positionMs = 14_500)
        now += 3000 // окно «подгоняем» (1,5 с) прошло
        s.update(room.copy(rev = 6, v = 4, playing = false, pos = 20.0, at = 104_000))
        assertEquals(listOf("set false 20000"), port.calls)
        s.onLocal(port.local()) // событие плеера от нашей же паузы
        advanceUntilIdle()
        assertTrue(service.posts.isEmpty(), service.posts.toString())
    }

    @Test
    fun `a manual pause is sent to the room with its version`() = runTest {
        val port = FakePort()
        val service = FakeService()
        var now = 101_500L
        val s = session(bg(), service, port, ArrayList(), { now })
        s.join("abc123")
        s.update(room)
        now += 3000
        port.playback = port.local().copy(playing = false, positionMs = 30_000)
        s.onLocal(port.local())
        advanceUntilIdle()
        assertEquals(listOf("post base=3 playing=false pos=30.0 track=null"), service.posts)
    }

    @Test
    fun `a new track picked by hand goes to the room, and chat from others surfaces`() = runTest {
        val port = FakePort()
        val service = FakeService()
        var now = 101_500L
        val s = session(bg(), service, port, ArrayList(), { now })
        s.join("abc123")
        s.update(room)
        now += 3000
        val mine = Track("333", "Mine", "Me")
        port.queue = listOf(mine) to 0
        port.playback = LocalPlayback(mine, true, 0)
        s.onLocal(port.local())
        advanceUntilIdle()
        assertEquals(listOf("post base=3 playing=true pos=0.0 track=333"), service.posts)

        val seen = ArrayList<String>()
        val job = bg().launch { s.incoming.collect { seen.add(it.text) } }
        advanceUntilIdle()
        s.update(room.copy(rev = 9, chat = room.chat + RoomChat("m2", "u2", "Аня", "новое", 2000)))
        advanceUntilIdle()
        assertEquals(listOf("новое"), seen)
        job.cancel()
    }

    @Test
    fun `host-only room that refuses us snaps back and says why`() = runTest {
        val said = ArrayList<String>()
        val port = FakePort()
        val service = FakeService()
        var now = 101_500L
        val s = session(bg(), service, port, said, { now })
        s.join("abc123")
        s.update(room)
        now += 3000
        service.reply = RoomReply(403, room.copy(rev = 7), "Управляет хост комнаты")
        port.playback = port.local().copy(playing = false)
        s.onLocal(port.local())
        advanceUntilIdle()
        assertEquals(listOf("Управляет хост комнаты"), said)
    }

    @Test
    fun `queue growth in the room is appended to the local queue`() = runTest {
        val port = FakePort()
        val s = session(bg(), FakeService(), port, ArrayList())
        s.join("abc123")
        s.update(room)
        port.calls.clear()
        val third = Track("333", "Third", "X")
        s.update(room.copy(rev = 8, queue = room.queue + third))
        assertTrue(port.calls.contains("append 1"), port.calls.toString())
    }
}
