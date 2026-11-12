package app.blink.core.offline

import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import okio.Buffer

object Audio {
    /** Правдоподобный «mp3»: ID3-заголовок и детерминированный шум. */
    fun bytes(size: Int, seed: Long = 7): ByteArray {
        val b = ByteArray(size)
        java.util.Random(seed).nextBytes(b)
        "ID3".toByteArray().copyInto(b)
        b[3] = 4
        return b
    }
}

class Fixture(val id: String, val bytes: ByteArray) {
    @Volatile var etag: String? = "W/\"e1\""
    @Volatile var honorRange: Boolean = true
    @Volatile var cap: Long = 2L * 1024 * 1024
    @Volatile var contentType: String = "audio/mpeg"
    @Volatile var duration: Int = 60
    @Volatile var resolveBytes: Long? = bytes.size.toLong()
    val fileHits = AtomicInteger()
}

/** Сервер-двойник: резолвер `/api/offline/resolve` и подписанные ссылки `/media/<id>` с поведением `streamController.js`. */
class FakeBackend : AutoCloseable {
    val server = MockWebServer()
    val fixtures = ConcurrentHashMap<String, Fixture>()
    val fileRequests = CopyOnWriteArrayList<RecordedRequest>()
    val resolveRequests = CopyOnWriteArrayList<RecordedRequest>()
    val playRequests = CopyOnWriteArrayList<RecordedRequest>()

    /** Подмена ответа на файл: (запрос, номер запроса к этому id начиная с 1) → ответ или null (обычное поведение). */
    @Volatile var fileHook: ((RecordedRequest, Int) -> MockResponse?)? = null
    @Volatile var resolveHook: ((RecordedRequest) -> MockResponse?)? = null
    @Volatile var legacyOnly: Boolean = false

    /** Замедление отдачи: байт за период в мс. 0 = без замедления. */
    @Volatile var throttleBytes: Long = 0
    @Volatile var throttleMs: Long = 100
    val inFlight = AtomicInteger()
    val maxInFlight = AtomicInteger()

    val base: String get() = server.url("/").toString().trimEnd('/')

    fun add(id: String, size: Int, seed: Long = 7, duration: Int = 60, configure: Fixture.() -> Unit = {}): Fixture =
        Fixture(id, Audio.bytes(size, seed)).apply { this.duration = duration }.apply(configure).also { fixtures[id] = it }

    fun start(): FakeBackend {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.requestUrl?.encodedPath ?: return MockResponse().setResponseCode(404)
                return when {
                    path == "/api/offline/resolve" -> resolve(request)
                    path.startsWith("/api/play/") -> play(request, path.removePrefix("/api/play/"))
                    path.startsWith("/media/") -> file(request, path.removePrefix("/media/"))
                    else -> MockResponse().setResponseCode(404).setBody("not found")
                }
            }
        }
        server.start()
        return this
    }

    private fun json(code: Int, build: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit): MockResponse =
        MockResponse().setResponseCode(code).setHeader("Content-Type", "application/json").setBody(buildJsonObject(build).toString())

    private fun resolve(req: RecordedRequest): MockResponse {
        resolveRequests.add(req)
        resolveHook?.invoke(req)?.let { return it }
        if (legacyOnly) return MockResponse().setResponseCode(404).setBody("Cannot GET /api/offline/resolve")
        val auth = req.getHeader("Authorization")
        if (auth == null) return json(401) { put("ok", JsonPrimitive(false)); put("error", JsonPrimitive("NOT_ALLOWED")); put("reason", JsonPrimitive("auth")) }
        val id = req.requestUrl?.queryParameter("id").orEmpty()
        val f = fixtures[id] ?: return json(404) { put("ok", JsonPrimitive(false)); put("error", JsonPrimitive("NOT_DOWNLOADABLE")); put("reason", JsonPrimitive("missing")) }
        return json(200) {
            put("ok", JsonPrimitive(true))
            put("source", JsonPrimitive("blink"))
            put("id", JsonPrimitive(id))
            put("url", JsonPrimitive("$base/media/$id?sig=${resolveRequests.size}"))
            put("mime", JsonPrimitive(f.contentType))
            f.resolveBytes?.let { put("bytes", JsonPrimitive(it)) }
            put("duration", JsonPrimitive(f.duration))
            f.etag?.let { put("etag", JsonPrimitive(it)) }
            put("expiresAt", JsonPrimitive(System.currentTimeMillis() + 3_600_000))
        }
    }

    private fun play(req: RecordedRequest, id: String): MockResponse {
        playRequests.add(req)
        if (req.getHeader("Authorization") == null) return json(401) { put("error", JsonPrimitive("auth")) }
        if (fixtures[id] == null) return json(404) { put("error", JsonPrimitive("not_found")) }
        return json(200) { put("url", JsonPrimitive("/media/$id?legacy=1")) }
    }

    private fun file(req: RecordedRequest, id: String): MockResponse {
        fileRequests.add(req)
        val f = fixtures[id] ?: return MockResponse().setResponseCode(404)
        val n = f.fileHits.incrementAndGet()
        val now = inFlight.incrementAndGet()
        maxInFlight.updateAndGet { maxOf(it, now) }
        try {
            fileHook?.invoke(req, n)?.let { return it }
            return serve(f, req)
        } finally {
            inFlight.decrementAndGet()
        }
    }

    fun serve(f: Fixture, req: RecordedRequest): MockResponse {
        val total = f.bytes.size.toLong()
        val range = req.getHeader("Range")
        val ifRange = req.getHeader("If-Range")
        val full = range == null || !f.honorRange || (ifRange != null && ifRange != f.etag)
        val res = MockResponse().setHeader("Content-Type", f.contentType).setHeader("Accept-Ranges", "bytes")
        f.etag?.let { res.setHeader("ETag", it) }
        if (full) {
            return res.setResponseCode(200).setBody(Buffer().write(f.bytes)).slow()
        }
        val m = Regex("""bytes=(\d+)-(\d*)""").find(range!!) ?: return res.setResponseCode(416).setHeader("Content-Range", "bytes */$total")
        val start = m.groupValues[1].toLong()
        if (start >= total) return res.setResponseCode(416).setHeader("Content-Range", "bytes */$total")
        val asked = m.groupValues[2].takeIf { it.isNotEmpty() }?.toLong()
        val end = minOf(asked ?: Long.MAX_VALUE, start + f.cap - 1, total - 1)
        return res.setResponseCode(206)
            .setHeader("Content-Range", "bytes $start-$end/$total")
            .setBody(Buffer().write(f.bytes, start.toInt(), (end - start + 1).toInt()))
            .slow()
    }

    private fun MockResponse.slow(): MockResponse =
        if (throttleBytes > 0) throttleBody(throttleBytes, throttleMs, java.util.concurrent.TimeUnit.MILLISECONDS) else this

    /** Ответ, у которого заголовок обещает весь файл, а тело обрывается после [cut] байт. */
    fun cutAt(f: Fixture, req: RecordedRequest, cut: Int): MockResponse {
        val ok = serve(f, req)
        val all = ok.getBody()!!.snapshot().toByteArray()
        val declared = all.size
        return MockResponse().setResponseCode(ok.status.split(" ")[1].toInt())
            .apply { ok.headers.forEach { (k, v) -> if (!k.equals("Content-Length", true)) addHeader(k, v) } }
            .setBody(Buffer().write(all, 0, cut)) // setBody ставит свой Content-Length, поэтому заголовок после него
            .setHeader("Content-Length", declared.toString())
            .setSocketPolicy(SocketPolicy.DISCONNECT_AT_END)
    }

    fun resolver(): TrackResolver = TrackResolver { _, id ->
        val f = fixtures[id] ?: throw OfflineException(OfflineCode.NOT_DOWNLOADABLE, "missing")
        Resolved(
            url = "$base/media/$id?sig=${fileRequests.size}",
            mime = f.contentType,
            bytes = f.resolveBytes,
            etag = f.etag,
            expiresAt = System.currentTimeMillis() + 3_600_000,
            duration = f.duration,
        )
    }

    override fun close() {
        try {
            server.shutdown()
        } catch (_: Exception) {
        }
    }
}

fun tempDir(): File = java.nio.file.Files.createTempDirectory("blink-offline-").toFile().also { it.deleteOnExit() }

fun job(id: String, duration: Int = 60, title: String = "Track $id"): OfflineJob =
    OfflineJob(
        key = Key.of("blink", id),
        source = "blink",
        id = id,
        meta = JobMeta(title = title, artist = "Artist", duration = duration),
        createdAt = System.currentTimeMillis(),
    )

fun candidate(id: String, duration: Int = 60, title: String = "Track $id"): Candidate =
    Candidate(Key.of("blink", id), "blink", id, JobMeta(title = title, artist = "Artist", duration = duration))
