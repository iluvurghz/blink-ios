package app.blink.core.offline

import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse

class OfflineManagerTest {
    private val backend = FakeBackend().start()
    private val dir: File = tempDir()
    private val network = StaticNetwork(true)
    private val scopes = ArrayList<CoroutineScope>()
    private var clock: () -> Long = System::currentTimeMillis

    private val fast = OfflineManager.Config(retryDelaysMs = listOf(20L, 20L, 20L, 20L), jitter = 0.0)

    @AfterTest
    fun tearDown() {
        scopes.forEach { it.cancel() }
        backend.close()
        dir.deleteRecursively()
    }

    private fun storage() = FileStorage(dir)

    private fun manager(
        st: Storage = storage(),
        resolver: TrackResolver = backend.resolver(),
        config: OfflineManager.Config = fast,
    ): OfflineManager {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default).also { scopes.add(it) }
        val dl = Downloader(st, resolver, OkHttpClient(), network, { clock() }, idleTimeoutSeconds = 3)
        return OfflineManager(st, dl, network, scope, config) { clock() }
    }

    private suspend fun OfflineManager.ready(): OfflineManager = apply { start() }

    private suspend fun OfflineManager.until(timeoutMs: Long = 30_000, cond: (OfflineState) -> Boolean): OfflineState =
        withTimeout(timeoutMs) { state.first(cond) }

    private fun run(block: suspend CoroutineScope.() -> Unit) {
        runBlocking { withTimeout(90_000) { block() } }
    }

    private fun key(id: String) = Key.of("blink", id)

    // ---------- основной путь ----------

    @Test
    fun `saves tracks, plays from disk, reports the batch`() = run {
        val a = backend.add("a", 400_000, seed = 1)
        val b = backend.add("b", 500_000, seed = 2)
        val m = manager().ready()
        val ev = async(start = CoroutineStart.UNDISPATCHED) { m.events.first() }

        val res = m.enqueue(listOf(candidate("a", 10, "Alpha"), candidate("b", 10, "Beta")))
        assertEquals(EnqueueResult.Queued, res[key("a")])
        val s = m.until { it.saved.size == 2 && it.jobs.isEmpty() }

        assertEquals(setOf(key("a"), key("b")), s.savedKeys)
        assertContentEquals(a.bytes, File(m.audioPath(key("a"))!!).readBytes())
        assertContentEquals(b.bytes, File(m.audioPath(key("b"))!!).readBytes())
        val e = s.saved.first { it.key == key("a") }
        assertEquals("Alpha", e.title)
        assertEquals(400_000, e.bytes)
        assertEquals(1, e.schema)
        assertEquals("saved", e.status)
        val done = withTimeout(5_000) { ev.await() }
        assertEquals(OfflineEvent.BatchDone(ok = 2, total = 2, failures = emptyList()), done)
        // на диске нет хвостов: только звук и записи манифеста
        val names = dir.list()!!.toSet()
        assertFalse(names.any { it.endsWith(".part") || it.endsWith(".job.json") || it.endsWith(".tmp") }, names.toString())
    }

    @Test
    fun `batch summary names every failure with its reason`() = run {
        backend.add("a", 400_000)
        backend.add("b", 400_000)
        val m = manager().ready()
        val ev = async(start = CoroutineStart.UNDISPATCHED) { m.events.first() }
        m.enqueue(listOf(candidate("a"), candidate("ghost", title = "Призрак"), candidate("b")))
        m.until { it.saved.size == 2 && it.jobs.size == 1 && it.jobs[0].failed }

        val done = assertIs<OfflineEvent.BatchDone>(withTimeout(5_000) { ev.await() })
        assertEquals(2, done.ok)
        assertEquals(3, done.total)
        val f = done.failures.single()
        assertEquals(key("ghost"), f.key)
        assertEquals("Призрак", f.title)
        assertEquals(OfflineCode.NOT_DOWNLOADABLE, f.code)
        assertEquals("Для этого трека нет файла", f.text.message)
        assertEquals("Для этого трека нет файла", m.state.value.jobs.single().text?.message)
    }

    @Test
    fun `two downloads at a time, queue is FIFO`() = run {
        for (c in "abcde") backend.add(c.toString(), 600_000)
        backend.throttleBytes = 100_000
        val m = manager().ready()
        var most = 0
        val watcher = async(Dispatchers.Default, start = CoroutineStart.UNDISPATCHED) {
            m.state.collect { s -> most = maxOf(most, s.jobs.count { it.stage == Stage.DOWNLOADING }) }
        }
        m.enqueue("abcde".map { candidate(it.toString()) })
        m.until { it.saved.size == 5 }
        watcher.cancel()
        assertEquals(2, most, "одновременно качаются две, не больше")
        val firstTwo = backend.fileRequests.take(2).map { it.requestUrl?.encodedPath }.toSet()
        assertEquals(setOf("/media/a", "/media/b"), firstTwo)
    }

    @Test
    fun `saving the same track again is a no-op`() = run {
        backend.add("a", 400_000)
        backend.throttleBytes = 50_000
        val m = manager().ready()
        assertEquals(EnqueueResult.Queued, m.enqueue(listOf(candidate("a")))[key("a")])
        assertEquals(EnqueueResult.AlreadyQueued, m.enqueue(listOf(candidate("a")))[key("a")])
        m.until { it.saved.size == 1 && it.jobs.isEmpty() }
        assertEquals(EnqueueResult.AlreadySaved, m.enqueue(listOf(candidate("a")))[key("a")])
        delay(100)
        assertEquals(1, backend.fileRequests.size)
    }

    // ---------- повторы ----------

    @Test
    fun `network hiccups retry by themselves and the track gets saved`() = run {
        val f = backend.add("a", 400_000)
        backend.fileHook = { _, n -> if (n <= 2) MockResponse().setResponseCode(503) else null }
        val m = manager().ready()
        m.enqueue(listOf(candidate("a")))
        m.until { it.saved.size == 1 }
        assertEquals(3, backend.fileRequests.size)
        assertContentEquals(f.bytes, File(m.audioPath(key("a"))!!).readBytes())
    }

    @Test
    fun `gives up after four retries, retry button starts over`() = run {
        backend.add("a", 400_000)
        backend.fileHook = { _, _ -> MockResponse().setResponseCode(500) }
        val m = manager().ready()
        m.enqueue(listOf(candidate("a")))
        val failed = m.until { it.jobs.singleOrNull()?.failed == true }
        assertEquals(5, backend.fileRequests.size, "первый запуск и четыре повтора")
        val j = failed.jobs.single()
        assertEquals(OfflineCode.SOURCE_ERROR, j.code)
        assertEquals("Сервер сейчас не отвечает", j.text?.message)
        assertEquals(OfflineText.Action.RETRY, j.text?.action)

        backend.fileHook = null
        m.retry(key("a"))
        m.until { it.saved.size == 1 }
    }

    @Test
    fun `bad content and no space are not retried`() = run {
        backend.add("a", 400_000) { contentType = "text/html" }
        val m = manager().ready()
        m.enqueue(listOf(candidate("a")))
        val s = m.until { it.jobs.singleOrNull()?.failed == true }
        assertEquals(OfflineCode.BAD_CONTENT, s.jobs.single().code)
        assertEquals(1, backend.fileRequests.size)
        assertEquals(0L, storage().partSize(key("a")))

        val full = object : Storage by storage() {
            override fun appendPart(key: String, bytes: ByteArray, off: Int, len: Int) = throw OfflineException(OfflineCode.NO_SPACE)
        }
        backend.add("b", 700_000)
        val m2 = manager(st = full).ready()
        m2.enqueue(listOf(candidate("b")))
        val s2 = m2.until { st -> st.jobs.any { it.key == key("b") && it.failed } }
        assertEquals(OfflineCode.NO_SPACE, s2.job(key("b"))?.code)
        assertEquals("Не хватает места на устройстве", s2.job(key("b"))?.text?.message)
        assertEquals(1, backend.fileRequests.count { it.path?.startsWith("/media/b") == true })
    }

    // ---------- сеть, пауза ----------

    @Test
    fun `without network the job waits and does not spend an attempt, then goes on its own`() = run {
        backend.add("a", 400_000)
        network.set(false)
        val m = manager().ready()
        m.enqueue(listOf(candidate("a")))
        delay(300)
        val waiting = m.state.value
        assertFalse(waiting.online)
        assertEquals(Stage.QUEUED, waiting.jobs.single().stage)
        assertEquals(0, waiting.jobs.single().attempt)
        assertTrue(backend.fileRequests.isEmpty() && backend.resolveRequests.isEmpty())

        network.set(true)
        m.until { it.saved.size == 1 }
    }

    @Test
    fun `losing the network mid-download keeps the part and resumes with Range`() = run {
        val f = backend.add("a", 3_000_000, duration = 60)
        backend.throttleBytes = 200_000
        val m = manager().ready()
        m.enqueue(listOf(candidate("a", 60)))
        m.until { (it.job(key("a"))?.have ?: 0) > 700_000 }
        network.set(false)
        val paused = m.until { it.job(key("a"))?.stage == Stage.QUEUED }
        assertEquals(0, paused.jobs.single().attempt, "попытка не потрачена")
        val kept = storage().partSize(key("a"))
        assertTrue(kept > 0, "накопленное осталось")

        backend.throttleBytes = 0
        network.set(true)
        m.until { it.saved.size == 1 }
        assertContentEquals(f.bytes, File(m.audioPath(key("a"))!!).readBytes())
        assertEquals("bytes=$kept-", backend.fileRequests.last().getHeader("Range"))
    }

    @Test
    fun `pause stops everything, resume finishes`() = run {
        backend.add("a", 3_000_000)
        backend.add("b", 3_000_000)
        backend.throttleBytes = 300_000
        val m = manager().ready()
        m.enqueue(listOf(candidate("a", 60), candidate("b", 60)))
        m.until { (it.job(key("a"))?.have ?: 0) > 300_000 }
        m.pause()
        val p = m.until { it.paused && it.jobs.all { j -> j.stage == Stage.QUEUED } }
        assertTrue(p.paused)
        val seen = backend.fileRequests.size
        delay(400)
        assertEquals(seen, backend.fileRequests.size, "на паузе новых запросов нет")

        backend.throttleBytes = 0
        m.resume()
        m.until { it.saved.size == 2 }
    }

    @Test
    fun `cancel removes the job and its part`() = run {
        backend.add("a", 3_000_000)
        backend.throttleBytes = 300_000
        val m = manager().ready()
        m.enqueue(listOf(candidate("a", 60)))
        m.until { (it.job(key("a"))?.have ?: 0) > 300_000 }
        m.cancel(key("a"))
        m.until { it.jobs.isEmpty() }
        delay(500)
        val names = dir.list()!!.toList()
        assertTrue(names.isEmpty(), "ни .part, ни job, ни записи: $names")
        assertEquals(0, m.state.value.saved.size)
    }

    // ---------- отказы запоминаются ----------

    @Test
    fun `refusals are remembered for 24 hours and the retry button forgets them`() = run {
        backend.add("a", 400_000)
        var asked = 0
        val refusing = TrackResolver { _, _ -> asked++; throw OfflineException(OfflineCode.NOT_ALLOWED, "plus") }
        var now = 1_000_000L
        clock = { now }
        val m = manager(resolver = refusing).ready()
        m.enqueue(listOf(candidate("a")))
        m.until { it.jobs.singleOrNull()?.failed == true }
        assertEquals(1, asked)

        val again = m.enqueue(listOf(candidate("a")))[key("a")]
        assertEquals(EnqueueResult.Remembered(OfflineCode.NOT_ALLOWED, "plus"), again)
        assertEquals(1, asked, "источник не дёргали")

        now += 23 * 3_600_000L
        assertIs<EnqueueResult.Remembered>(m.enqueue(listOf(candidate("a")))[key("a")])

        m.retry(key("a"))
        m.until { asked == 2 && it.jobs.singleOrNull()?.failed == true }

        now += 25 * 3_600_000L
        assertEquals(EnqueueResult.Queued, m.enqueue(listOf(candidate("a")))[key("a")], "через сутки память стёрта")
        m.until { asked == 3 }
    }

    // ---------- перезапуск ----------

    @Test
    fun `after a restart the queue goes on with Range from the part length`() = run {
        val f = backend.add("a", 3_000_000, duration = 60)
        backend.throttleBytes = 250_000
        val st1 = storage()
        val m1 = manager(st = st1).ready()
        m1.enqueue(listOf(candidate("a", 60)))
        m1.until { (it.job(key("a"))?.have ?: 0) > 800_000 }
        scopes.first().cancel() // процесс убили
        delay(300)
        val onDisk = storage().partSize(key("a"))
        assertTrue(onDisk in 1 until 3_000_000)
        assertNotNull(storage().getMeta(MetaKind.JOB, key("a")))

        backend.throttleBytes = 0
        backend.fileRequests.clear()
        val m2 = manager().ready()
        assertEquals(1, m2.state.value.jobs.size, "задача пережила перезапуск")
        m2.until { it.saved.size == 1 }
        assertEquals("bytes=$onDisk-", backend.fileRequests.first().getHeader("Range"))
        assertContentEquals(f.bytes, File(m2.audioPath(key("a"))!!).readBytes())
    }

    @Test
    fun `reconcile at start sorts out orphans, half-finished commits and stale jobs`() = run {
        val st = storage().also { it.open() }
        val now = System.currentTimeMillis()
        fun entry(id: String, size: Long) = ManifestEntry(key = key(id), source = "blink", id = id, title = "T$id", artist = "A", bytes = size, savedAt = now)
        fun putAudio(id: String, n: Int) { st.appendPart(key(id), Audio.bytes(n), 0, n); st.commit(key(id)) }
        fun putPart(id: String, n: Int) = st.appendPart(key(id), Audio.bytes(n), 0, n)

        // saved: нормальный
        putAudio("ok", 1000); st.putMeta(MetaKind.ENTRY, key("ok"), entry("ok", 1000).encode())
        // запись без звука
        st.putMeta(MetaKind.ENTRY, key("missing"), entry("missing", 1000).encode())
        // битая запись
        st.putMeta(MetaKind.ENTRY, key("garbage"), "{ не json")
        // сирота: звук без записи и без задачи
        putAudio("orphan", 1000)
        // упали между commit и записью: размер звука равен total из job
        putAudio("half", 2000)
        st.putMeta(MetaKind.JOB, key("half"), job("half").copy(total = 2000, etag = "W/\"x\"", mime = "audio/mpeg").encode())
        // звук не того размера
        putAudio("wrongsize", 2000)
        st.putMeta(MetaKind.JOB, key("wrongsize"), job("wrongsize").copy(total = 9999).encode())
        // задача уже сохранённого
        st.putMeta(MetaKind.JOB, key("ok"), job("ok").encode()); putPart("ok", 10)
        // .part без задачи
        putPart("stray", 500)
        // живая задача с .part
        st.putMeta(MetaKind.JOB, key("live"), job("live").copy(total = 5000, etag = "W/\"l\"").encode()); putPart("live", 700)
        // упавшие
        st.putMeta(MetaKind.JOB, key("srv"), job("srv").copy(state = Stage.FAILED.name, code = "SOURCE_ERROR", failedAt = now).encode()); putPart("srv", 300)
        st.putMeta(MetaKind.JOB, key("refused"), job("refused").copy(state = Stage.FAILED.name, code = "NOT_ALLOWED", reason = "plus", failedAt = now - 3_600_000).encode())
        st.putMeta(MetaKind.JOB, key("oldrefusal"), job("oldrefusal").copy(state = Stage.FAILED.name, code = "NOT_ALLOWED", reason = "plus", failedAt = now - 25 * 3_600_000).encode())
        st.putMeta(MetaKind.JOB, key("brokenjob"), "{")

        network.set(false) // чтобы живая задача не стартовала и её было видно
        val m = manager(st = st).ready()
        val s = m.state.value

        assertEquals(setOf(key("ok"), key("half")), s.savedKeys, "ok остаётся, half достроен из job")
        assertEquals(key("half"), s.saved.first { it.key == key("half") }.key)
        assertEquals(2000, s.saved.first { it.key == key("half") }.bytes)
        assertEquals("audio/mpeg", s.saved.first { it.key == key("half") }.mime)
        assertNull(st.getMeta(MetaKind.JOB, key("half")), "I5: задача ушла после записи")
        assertNull(st.audioPath(key("orphan")))
        assertNull(st.audioPath(key("wrongsize")))
        assertNull(st.getMeta(MetaKind.ENTRY, key("missing")))
        assertNull(st.getMeta(MetaKind.ENTRY, key("garbage")))
        assertEquals(0L, st.partSize(key("stray")))
        assertNull(st.getMeta(MetaKind.JOB, key("ok")))
        assertEquals(0L, st.partSize(key("ok")))

        val byKey = s.jobs.associateBy { it.key }
        assertEquals(Stage.QUEUED, byKey[key("live")]?.stage)
        assertEquals(Stage.QUEUED, byKey[key("wrongsize")]?.stage, "звук не того размера выброшен, а сама задача жива")
        assertEquals(700L, byKey[key("live")]?.have)
        assertEquals(Stage.FAILED, byKey[key("refused")]?.stage)
        assertEquals(OfflineCode.NOT_ALLOWED, byKey[key("refused")]?.code)
        assertNull(byKey[key("srv")], "упавшее на сетевой ошибке уходит вместе с .part")
        assertEquals(0L, st.partSize(key("srv")))
        assertNull(byKey[key("oldrefusal")])
        assertNull(st.getMeta(MetaKind.JOB, key("brokenjob")))
        assertEquals(setOf(key("live"), key("wrongsize"), key("refused")), s.jobs.map { it.key }.toSet())
    }

    // ---------- хранилище ----------

    @Test
    fun `remove deletes the file and the record, clearAll wipes everything`() = run {
        backend.add("a", 400_000)
        backend.add("b", 400_000)
        val m = manager().ready()
        m.enqueue(listOf(candidate("a"), candidate("b")))
        m.until { it.saved.size == 2 }
        assertTrue(m.usage().bytes >= 800_000)

        m.remove(key("a"))
        assertFalse(m.isSaved(key("a")))
        assertNull(m.audioPath(key("a")))
        assertNull(storage().getMeta(MetaKind.ENTRY, key("a")))
        assertTrue(m.isSaved(key("b")))

        m.clearAll()
        assertEquals(0, m.state.value.saved.size)
        assertTrue(dir.list()!!.isEmpty())
    }

    @Test
    fun `markPlayed is stored in the record`() = run {
        backend.add("a", 400_000)
        val m = manager().ready()
        m.enqueue(listOf(candidate("a")))
        m.until { it.saved.size == 1 }
        assertNull(m.state.value.saved.single().lastPlayedAt)
        m.markPlayed(key("a"))
        val disk = ManifestEntry.decode(storage().getMeta(MetaKind.ENTRY, key("a"))!!)
        assertNotNull(disk?.lastPlayedAt)
    }

    @Test
    fun `saved tracks survive a new manager on the same folder and play offline`() = run {
        val f = backend.add("a", 400_000)
        manager().ready().apply {
            enqueue(listOf(candidate("a", 10, "Alpha")))
            until { it.saved.size == 1 }
        }
        scopes.forEach { it.cancel() }
        backend.close() // сервера нет совсем
        network.set(false)
        val m2 = manager().ready()
        assertEquals("Alpha", m2.state.value.saved.single().title)
        assertContentEquals(f.bytes, File(m2.audioPath(key("a"))!!).readBytes())
    }
}
