package app.blink.core.offline

import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.SocketPolicy

class DownloaderTest {
    private val backend = FakeBackend().start()
    private val dir: File = tempDir()
    private val storage = FileStorage(dir).also { it.open() }
    private val network = StaticNetwork(true)

    @AfterTest
    fun tearDown() {
        backend.close()
        dir.deleteRecursively()
    }

    private fun downloader(
        resolver: TrackResolver = backend.resolver(),
        st: Storage = storage,
        idle: Long = 20,
        resolveMs: Long = Downloader.RESOLVE_TIMEOUT_MS,
    ) = Downloader(st, resolver, OkHttpClient(), network, idleTimeoutSeconds = idle, resolveTimeoutMs = resolveMs)

    private fun <T> run(block: suspend () -> T): T = runBlocking { withTimeout(60_000) { block() } }

    private fun seedPart(id: String, bytes: ByteArray, n: Int) {
        val key = Key.of("blink", id)
        storage.appendPart(key, bytes, 0, n)
        assertEquals(n.toLong(), storage.partSize(key))
    }

    private fun audioOf(id: String): ByteArray = File(storage.audioPath(Key.of("blink", id))!!).readBytes()

    private fun rangeHeaders() = backend.fileRequests.map { it.getHeader("Range") }

    // ---------- обычные случаи ----------

    @Test
    fun `small file in one request, no auth on the file link`() {
        val f = backend.add("a", 300_000)
        val entry = run { downloader().download(job("a", duration = 10)) }
        assertEquals(300_000, entry.bytes)
        assertEquals("audio/mpeg", entry.mime)
        assertEquals("W/\"e1\"", entry.etag)
        assertContentEquals(f.bytes, audioOf("a"))
        assertFalse(File(dir, Key.fkey("blink:a") + ".part").exists(), ".part превращается в готовый файл")
        assertEquals(listOf<String?>(null), rangeHeaders())
        val req = backend.fileRequests.single()
        assertNull(req.getHeader("Authorization"), "к ссылке на файл Bearer не добавляем")
        assertEquals("identity", req.getHeader("Accept-Encoding"))
    }

    @Test
    fun `stages and progress are reported in order`() {
        backend.add("a", 700_000)
        val stages = ArrayList<Stage>()
        val seen = ArrayList<Long>()
        run {
            downloader().download(
                job("a", duration = 10),
                DownloadHooks(onStage = { stages.add(it) }, onProgress = { have, _ -> seen.add(have) }),
            )
        }
        assertEquals(listOf(Stage.RESOLVING, Stage.DOWNLOADING, Stage.VERIFYING, Stage.COMMITTING), stages)
        assertEquals(seen.sorted(), seen)
        assertEquals(700_000L, seen.last())
    }

    // ---------- контракт: Range ----------

    @Test
    fun `contract vector - cut at 1_000_000 then Range and If-Range with 2 MiB slices`() {
        val f = backend.add("big", 5_000_000, duration = 213)
        backend.fileHook = { req, n -> if (n == 1) backend.cutAt(f, req, 1_000_000) else null }
        val d = downloader()

        val first = assertFailsWith<OfflineException> { run { d.download(job("big", duration = 213)) } }
        assertEquals(OfflineCode.SOURCE_ERROR, first.code, "обрыв при живой сети это SOURCE_ERROR, не NO_NETWORK")
        assertEquals(1_000_000L, storage.partSize(Key.of("blink", "big")), "накопленное сохранено, это и есть смещение Range")

        val entry = run { d.download(job("big", duration = 213)) }
        assertEquals(5_000_000, entry.bytes)
        assertContentEquals(f.bytes, audioOf("big"))
        assertEquals(listOf<String?>(null, "bytes=1000000-", "bytes=3097152-"), rangeHeaders())
        assertEquals(listOf<String?>(null, "W/\"e1\"", "W/\"e1\""), backend.fileRequests.map { it.getHeader("If-Range") }, "etag дословно, вместе с W/ и кавычками")
    }

    @Test
    fun `loops over the 2 MiB cap until total, one 206 is not done`() {
        val f = backend.add("big", 5_000_000, duration = 120)
        seedPart("big", f.bytes, 100)
        val entry = run { downloader().download(job("big", duration = 120)) }
        assertEquals(5_000_000, entry.bytes)
        assertContentEquals(f.bytes, audioOf("big"))
        assertEquals(listOf<String?>("bytes=100-", "bytes=2097252-", "bytes=4194404-"), rangeHeaders())
    }

    @Test
    fun `server ignoring Range answers 200 and we start over`() {
        val f = backend.add("a", 400_000) { honorRange = false }
        seedPart("a", f.bytes, 100_000)
        val entry = run { downloader().download(job("a", duration = 10)) }
        assertEquals(400_000, entry.bytes)
        assertContentEquals(f.bytes, audioOf("a"))
        assertEquals(listOf<String?>("bytes=100000-"), rangeHeaders(), "один запрос: 200 целиком берём с нуля")
    }

    @Test
    fun `changed etag drops the old part and starts from zero`() {
        val f = backend.add("a", 400_000) { etag = "W/\"new\"" }
        seedPart("a", f.bytes, 100_000)
        val old = job("a", duration = 10).copy(etag = "W/\"old\"", total = 400_000)
        val entry = run { downloader().download(old) }
        assertEquals(400_000, entry.bytes)
        assertEquals(listOf<String?>(null), rangeHeaders(), "частичный файл от другой версии выброшен")
        assertContentEquals(f.bytes, audioOf("a"))
    }

    @Test
    fun `416 for a shrunk file restarts from zero`() {
        val f = backend.add("a", 300_000) { resolveBytes = null; etag = null }
        seedPart("a", Audio.bytes(400_000, seed = 99), 400_000)
        val entry = run { downloader().download(job("a", duration = 10)) }
        assertEquals(300_000, entry.bytes)
        assertContentEquals(f.bytes, audioOf("a"))
        assertEquals(listOf<String?>("bytes=400000-", null), rangeHeaders())
    }

    @Test
    fun `without bytes from the resolver (legacy play) the size comes from Content-Range`() {
        val f = backend.add("a", 5_000_000, duration = 120) { resolveBytes = null; etag = null }
        seedPart("a", f.bytes, 5_000)
        val entry = run { downloader().download(job("a", duration = 120)) }
        assertEquals(5_000_000, entry.bytes)
        assertNull(entry.etag)
        assertContentEquals(f.bytes, audioOf("a"))
        assertTrue(backend.fileRequests.all { it.getHeader("If-Range") == null })
    }

    // ---------- ссылка просрочена ----------

    @Test
    fun `403 on the file re-resolves and continues from the same place`() {
        val f = backend.add("big", 5_000_000, duration = 120)
        seedPart("big", f.bytes, 100)
        backend.fileHook = { _, n -> if (n == 2) MockResponse().setResponseCode(403) else null }
        var resolves = 0
        val counting = TrackResolver { s, i -> resolves++; backend.resolver().resolve(s, i) }
        val entry = run { downloader(counting).download(job("big", duration = 120)) }
        assertEquals(5_000_000, entry.bytes)
        assertEquals(2, resolves)
        assertContentEquals(f.bytes, audioOf("big"))
        assertEquals(listOf<String?>("bytes=100-", "bytes=2097252-", "bytes=2097252-", "bytes=4194404-"), rangeHeaders())
        val urls = backend.fileRequests.map { it.path }
        assertTrue(urls[1] != urls[2], "после резолва ссылка новая")
    }

    @Test
    fun `403 more than twice gives up`() {
        val f = backend.add("big", 5_000_000, duration = 120)
        seedPart("big", f.bytes, 100)
        backend.fileHook = { _, _ -> MockResponse().setResponseCode(403) }
        var resolves = 0
        val counting = TrackResolver { s, i -> resolves++; backend.resolver().resolve(s, i) }
        val e = assertFailsWith<OfflineException> { run { downloader(counting).download(job("big", duration = 120)) } }
        assertEquals(OfflineCode.SOURCE_ERROR, e.code)
        assertEquals("expired", e.reason)
        assertEquals(3, resolves, "первый резолв и не больше двух повторных")
        assertEquals(100L, storage.partSize(Key.of("blink", "big")), "накопленное не потеряно")
    }

    @Test
    fun `404 on the file means no file`() {
        backend.add("a", 300_000)
        backend.fileHook = { _, _ -> MockResponse().setResponseCode(404) }
        val e = assertFailsWith<OfflineException> { run { downloader().download(job("a", duration = 10)) } }
        assertEquals(OfflineCode.NOT_DOWNLOADABLE, e.code)
    }

    // ---------- проверки файла ----------

    @Test
    fun `html with an audio type is caught by the first bytes before anything is written`() {
        backend.add("a", 50_000)
        val html = ("<html>" + "x".repeat(50_000)).toByteArray()
        backend.fixtures["a"] = Fixture("a", html.copyOf(50_000))
        val e = assertFailsWith<OfflineException> { run { downloader().download(job("a", duration = 1)) } }
        assertEquals(OfflineCode.BAD_CONTENT, e.code)
        assertEquals("magic", e.reason)
        assertEquals(0L, storage.partSize(Key.of("blink", "a")))
        assertFalse(File(dir, Key.fkey("blink:a") + ".part").exists())
        assertEquals(1, backend.fileRequests.size, "повторов нет")
    }

    @Test
    fun `json error body is not a file`() {
        backend.add("a", 300_000) { contentType = "application/json" }
        val e = assertFailsWith<OfflineException> { run { downloader().download(job("a", duration = 10)) } }
        assertEquals(OfflineCode.BAD_CONTENT, e.code)
        assertEquals("type", e.reason)
    }

    @Test
    fun `too small for its duration is bad content and the part is dropped`() {
        backend.add("a", 300_000, duration = 213)
        val e = assertFailsWith<OfflineException> { run { downloader().download(job("a", duration = 213)) } }
        assertEquals(OfflineCode.BAD_CONTENT, e.code)
        assertEquals("too_small", e.reason)
        assertEquals(0L, storage.partSize(Key.of("blink", "a")), "битое не докачиваем")
        assertNull(storage.audioPath(Key.of("blink", "a")))
    }

    @Test
    fun `size that disagrees with the resolver is bad content`() {
        backend.add("a", 300_000) { resolveBytes = 300_010 }
        val e = assertFailsWith<OfflineException> { run { downloader().download(job("a", duration = 10)) } }
        assertEquals(OfflineCode.BAD_CONTENT, e.code)
        assertEquals("size_mismatch", e.reason)
        assertNull(storage.audioPath(Key.of("blink", "a")))
    }

    // ---------- сеть ----------

    @Test
    fun `io failure with network up is SOURCE_ERROR, with network down NO_NETWORK`() {
        // Ссылка на закрытый порт: соединение не открывается совсем.
        val dead = TrackResolver { _, _ -> Resolved(url = "http://127.0.0.1:1/x", bytes = 300_000, expiresAt = Long.MAX_VALUE) }
        val up = assertFailsWith<OfflineException> { run { downloader(dead).download(job("a", duration = 10)) } }
        assertEquals(OfflineCode.SOURCE_ERROR, up.code)
        network.set(false)
        val down = assertFailsWith<OfflineException> { run { downloader(dead).download(job("a", duration = 10)) } }
        assertEquals(OfflineCode.NO_NETWORK, down.code)
    }

    @Test
    fun `silence from the server is TIMEOUT`() {
        backend.add("a", 300_000)
        backend.fileHook = { _, _ -> MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE) }
        val e = assertFailsWith<OfflineException> { run { downloader(idle = 1).download(job("a", duration = 10)) } }
        assertEquals(OfflineCode.TIMEOUT, e.code)
    }

    @Test
    fun `resolver timeouts and io errors are classified`() {
        val io = TrackResolver { _, _ -> throw java.io.IOException("boom") }
        assertEquals(OfflineCode.SOURCE_ERROR, assertFailsWith<OfflineException> { run { downloader(io).download(job("a")) } }.code)
        network.set(false)
        assertEquals(OfflineCode.NO_NETWORK, assertFailsWith<OfflineException> { run { downloader(io).download(job("a")) } }.code)
        network.set(true)
        val slow = object : TrackResolver {
            override suspend fun resolve(source: String, id: String): Resolved {
                delay(60_000)
                error("unreachable")
            }
        }
        val e = assertFailsWith<OfflineException> { runBlocking { downloader(slow, resolveMs = 300).download(job("a")) } }
        assertEquals(OfflineCode.TIMEOUT, e.code)
    }

    // ---------- место, отмена ----------

    @Test
    fun `no space propagates from the storage`() {
        backend.add("a", 700_000)
        val full = object : Storage by storage {
            override fun appendPart(key: String, bytes: ByteArray, off: Int, len: Int) {
                throw OfflineException(OfflineCode.NO_SPACE)
            }
        }
        val e = assertFailsWith<OfflineException> { run { downloader(st = full).download(job("a", duration = 10)) } }
        assertEquals(OfflineCode.NO_SPACE, e.code)
        assertFalse(OfflineCode.NO_SPACE.retryable)
    }

    @Test
    fun `io errors from disk map to NO_SPACE or SOURCE_ERROR`() {
        assertEquals(OfflineCode.NO_SPACE, FileStorage.mapIo(java.io.IOException("No space left on device")).code)
        assertEquals(OfflineCode.NO_SPACE, FileStorage.mapIo(java.io.IOException("write failed: ENOSPC (No space left on device)")).code)
        assertEquals(OfflineCode.SOURCE_ERROR, FileStorage.mapIo(java.io.IOException("Permission denied")).code)
    }

    @Test
    fun `part shorter than the accepted bytes is BAD_CONTENT truncated, the part is dropped and nothing is committed`() {
        backend.add("a", 1_500_000, duration = 60)
        var batches = 0
        val lossy = object : Storage by storage {
            override fun appendPart(key: String, bytes: ByteArray, off: Int, len: Int) {
                if (++batches == 2) return // вторая порция «принята», но на диске её нет
                storage.appendPart(key, bytes, off, len)
            }
        }
        val key = Key.of("blink", "a")
        val e = assertFailsWith<OfflineException> { run { downloader(st = lossy).download(job("a", duration = 60)) } }
        assertEquals(OfflineCode.BAD_CONTENT, e.code)
        assertEquals("truncated", e.reason)
        assertEquals(0L, storage.partSize(key), "битое не докачиваем")
        assertNull(storage.audioPath(key))
        assertEquals(1, backend.fileRequests.size, "поверх битого не качаем дальше")
    }

    @Test
    fun `cancel keeps the verified prefix and commits nothing`() {
        val f = backend.add("slow", 3_000_000, duration = 60)
        backend.fileHook = { req, _ -> backend.serve(f, req).throttleBody(200_000, 100, TimeUnit.MILLISECONDS) }
        val key = Key.of("blink", "slow")
        runBlocking {
            val work = async(Dispatchers.Default, start = CoroutineStart.DEFAULT) {
                runCatching { downloader().download(job("slow", duration = 60)) }
            }
            withTimeout(30_000) { while (backend.fileRequests.isEmpty()) delay(20) }
            delay(700)
            work.cancelAndJoin()
        }
        val have = storage.partSize(key)
        assertTrue(have in 1 until 3_000_000, "что-то успело записаться: $have")
        assertContentEquals(f.bytes.copyOfRange(0, have.toInt()), storage.readPart(key, 0, have), "в .part только правильный префикс")
        assertNull(storage.audioPath(key))
    }

    @Test
    fun `commit makes the file visible only at the end`() {
        backend.add("a", 700_000)
        var visibleBeforeCommit = false
        val spy = object : Storage by storage {
            override fun commit(key: String) {
                visibleBeforeCommit = storage.hasAudio(key)
                storage.commit(key)
            }
        }
        val entry = run { downloader(st = spy).download(job("a", duration = 10)) }
        assertFalse(visibleBeforeCommit, "I1: плеер видит файл только после commit")
        assertNotNull(storage.audioPath(entry.key))
    }
}
