package app.blink.core.offline

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class Failure(val key: String, val title: String, val code: OfflineCode, val reason: String?) {
    val text: OfflineText get() = OfflineTexts.of(code, reason)
}

sealed interface OfflineEvent {
    /** Итог пакета: «Сохранено 3 из 5. 2 не вышло: …». */
    data class BatchDone(val ok: Int, val total: Int, val failures: List<Failure>) : OfflineEvent
}

data class JobView(
    val key: String,
    val title: String,
    val artist: String,
    val cover: String,
    val stage: Stage,
    val have: Long,
    val total: Long?,
    val attempt: Int,
    val code: OfflineCode?,
    val reason: String?,
    /** Когда ближайший автоповтор (мс эпохи), если ждёт его. */
    val retryAt: Long?,
) {
    val fraction: Float
        get() = total?.takeIf { it > 0 }?.let { (have.toDouble() / it).toFloat().coerceIn(0f, 1f) } ?: 0f
    val failed: Boolean get() = stage == Stage.FAILED
    val text: OfflineText? get() = code?.let { OfflineTexts.of(it, reason) }
}

data class OfflineState(
    val ready: Boolean = false,
    val jobs: List<JobView> = emptyList(),
    val saved: List<ManifestEntry> = emptyList(),
    val paused: Boolean = false,
    val online: Boolean = true,
) {
    val savedKeys: Set<String> by lazy(LazyThreadSafetyMode.NONE) { saved.mapTo(HashSet()) { it.key } }
    val usedBytes: Long get() = saved.sumOf { it.bytes }
    val active: Boolean get() = jobs.any { !it.failed }
    fun job(key: String): JobView? = jobs.firstOrNull { it.key == key }
}

sealed interface EnqueueResult {
    data object Queued : EnqueueResult
    data object AlreadySaved : EnqueueResult
    data object AlreadyQueued : EnqueueResult

    /** Отказ запомнен на 24 часа: источник не дёргаем. «Повторить» сбрасывает. */
    data class Remembered(val code: OfflineCode, val reason: String?) : EnqueueResult
    data class Rejected(val code: OfflineCode, val reason: String?) : EnqueueResult
}

/**
 * Очередь сохранений: FIFO, 2 загрузки параллельно, пауза глобальная, автоповторы 1/3/9/27 с,
 * без сети попытка не тратится и задача ждёт появления сети. Всё живёт на диске, переживает перезапуск.
 */
class OfflineManager(
    private val storage: Storage,
    private val downloader: Downloader,
    private val network: NetworkMonitor,
    private val scope: CoroutineScope,
    private val config: Config = Config(),
    private val now: () -> Long = System::currentTimeMillis,
) {
    data class Config(
        val maxParallel: Int = 2,
        val retryDelaysMs: List<Long> = listOf(1_000L, 3_000L, 9_000L, 27_000L),
        val jitter: Double = 0.2,
        val refusalMemoryMs: Long = 24L * 60 * 60 * 1000,
        val random: () -> Double = { Math.random() },
    )

    private class Rt(var job: OfflineJob) {
        @Volatile var stage: Stage = Stage.QUEUED
        @Volatile var have: Long = 0
        @Volatile var total: Long? = job.total
        var runner: Job? = null
        var retryAt: Long = 0
        var requeue: Boolean = false
        var cancelled: Boolean = false

        /** Длина .part в начале попытки: если к концу выросла, попытка шла не вхолостую (поправка 2, повторы). */
        @Volatile var haveAtStart: Long = 0

        /** Задача, поставленная самим менеджером (восстановление потерянного файла): без тостов про пакет. */
        var silent: Boolean = false
    }

    private val lock = Any()
    private val jobs = LinkedHashMap<String, Rt>()
    private val saved = LinkedHashMap<String, ManifestEntry>()
    private var paused = false
    private var started = false
    private var lastPublish = 0L

    private var batchTotal = 0
    private var batchOk = 0
    private val batchFailures = ArrayList<Failure>()

    private val stateFlow = MutableStateFlow(OfflineState())
    val state: StateFlow<OfflineState> = stateFlow.asStateFlow()

    private val eventFlow = MutableSharedFlow<OfflineEvent>(extraBufferCapacity = 32)
    val events: SharedFlow<OfflineEvent> = eventFlow.asSharedFlow()

    // ---------- запуск ----------

    /** Открывает хранилище, наводит порядок (reconcile) и продолжает незаконченное. */
    suspend fun start() {
        if (synchronized(lock) { started }) return
        withContext(Dispatchers.IO) {
            storage.open()
            synchronized(lock) { reconcile() }
        }
        synchronized(lock) { started = true }
        scope.launch {
            network.online.collect { on ->
                if (on) pump() else interruptRunning()
                publish()
            }
        }
        publish()
        pump()
    }

    /** I6: сироты, задачи уже сохранённых, missing, старые отказы. Вызывается под замком. */
    private fun reconcile() {
        val t = now()
        val entries = HashMap<String, ManifestEntry>()
        for (key in storage.listMeta(MetaKind.ENTRY)) {
            val e = storage.getMeta(MetaKind.ENTRY, key)?.let { ManifestEntry.decode(it) }
            if (e == null || e.key != key) {
                storage.delMeta(MetaKind.ENTRY, key)
                continue
            }
            entries[key] = e
        }
        val onDisk = HashMap<String, OfflineJob>()
        for (key in storage.listMeta(MetaKind.JOB)) {
            val j = storage.getMeta(MetaKind.JOB, key)?.let { OfflineJob.decode(it) }
            if (j == null || j.key != key) {
                storage.delMeta(MetaKind.JOB, key)
                storage.deletePart(key)
                continue
            }
            onDisk[key] = j
        }
        val audio = storage.listAudio().toSet()

        // Запись без звука: файл пропал. Запись удаляем, а если у неё есть объект трека, тихо ставим скачивание заново
        // (поправка 2): человек сохранял этот трек и вправе ждать, что он снова будет на телефоне.
        val silentKeys = HashSet<String>()
        for (key in entries.keys.toList()) {
            if (key in audio) continue
            val lost = entries.remove(key) ?: continue
            storage.delMeta(MetaKind.ENTRY, key)
            if (lost.track != null && key !in onDisk) {
                val job = OfflineJob(
                    key = lost.key, source = lost.source, id = lost.id,
                    meta = JobMeta(
                        title = lost.title, artist = lost.artist, album = lost.album, cover = lost.cover,
                        duration = lost.duration, offlineAllowed = lost.offlineAllowed, track = lost.track,
                    ),
                    createdAt = t,
                )
                storage.putMeta(MetaKind.JOB, key, job.encode())
                onDisk[key] = job
                silentKeys.add(key)
            }
        }
        // Звук без записи: упали между commit и манифестом (достраиваем из job, если размер сошёлся) либо сирота.
        for (key in audio) {
            if (key in entries) continue
            val j = onDisk[key]
            val size = storage.audioSize(key)
            if (j != null && j.total != null && j.total == size) {
                val e = ManifestEntry(
                    key = j.key, source = j.source, id = j.id, title = j.meta.title, artist = j.meta.artist,
                    album = j.meta.album, cover = j.meta.cover, duration = j.meta.duration, bytes = size,
                    mime = j.mime, etag = j.etag, savedAt = t, offlineAllowed = j.meta.offlineAllowed, track = j.meta.track,
                )
                storage.putMeta(MetaKind.ENTRY, key, e.encode())
                entries[key] = e
            } else {
                storage.deleteAudio(key)
            }
        }
        // Задачи: у сохранённого не нужны; упавшие живут только как запомненный отказ моложе суток.
        for (j in onDisk.values.sortedBy { it.createdAt }) {
            val key = j.key
            if (key in entries) {
                storage.delMeta(MetaKind.JOB, key)
                storage.deletePart(key)
                continue
            }
            if (j.stage == Stage.FAILED) {
                val fresh = j.failedAt != null && t - j.failedAt < config.refusalMemoryMs
                if (j.failure?.isRefusal == true && fresh) {
                    jobs[key] = Rt(j).also { it.stage = Stage.FAILED }
                } else {
                    storage.delMeta(MetaKind.JOB, key)
                    storage.deletePart(key)
                }
                continue
            }
            jobs[key] = Rt(j.copy(state = Stage.QUEUED.name)).also {
                it.have = storage.partSize(key)
                it.silent = key in silentKeys
            }
        }
        for (key in storage.listParts()) if (key !in jobs) storage.deletePart(key)

        saved.clear()
        entries.values.sortedByDescending { it.savedAt }.forEach { saved[it.key] = it }
    }

    // ---------- команды ----------

    fun enqueue(candidates: List<Candidate>): Map<String, EnqueueResult> {
        val out = LinkedHashMap<String, EnqueueResult>()
        val t = now()
        synchronized(lock) {
            for (c in candidates) {
                if (c.key in saved) {
                    out[c.key] = EnqueueResult.AlreadySaved
                    continue
                }
                val existing = jobs[c.key]
                if (existing != null) {
                    if (existing.stage != Stage.FAILED) {
                        out[c.key] = EnqueueResult.AlreadyQueued
                        continue
                    }
                    val code = existing.job.failure
                    val fresh = existing.job.failedAt?.let { t - it < config.refusalMemoryMs } == true
                    if (code != null && code.isRefusal && fresh) {
                        out[c.key] = EnqueueResult.Remembered(code, existing.job.reason)
                        continue
                    }
                    resetForRetry(existing)
                    out[c.key] = EnqueueResult.Queued
                    continue
                }
                val job = OfflineJob(key = c.key, source = c.source, id = c.id, meta = c.meta, createdAt = t)
                try {
                    storage.putMeta(MetaKind.JOB, c.key, job.encode())
                } catch (e: Exception) {
                    out[c.key] = FileStorage.mapIo(java.io.IOException(e.message, e)).let { EnqueueResult.Rejected(it.code, it.reason) }
                    continue
                }
                jobs[c.key] = Rt(job)
                batchTotal++
                out[c.key] = EnqueueResult.Queued
            }
        }
        publish()
        pump()
        return out
    }

    fun pause() {
        synchronized(lock) {
            paused = true
            interruptRunningLocked()
        }
        publish()
    }

    fun resume() {
        synchronized(lock) { paused = false }
        publish()
        pump()
    }

    /** «Повторить» по одному треку: сбрасывает и запомненный отказ. */
    fun retry(key: String) {
        synchronized(lock) {
            val rt = jobs[key] ?: return
            if (rt.runner == null && rt.stage == Stage.FAILED) resetForRetry(rt)
        }
        publish()
        pump()
    }

    fun retryAll() {
        synchronized(lock) {
            for (rt in jobs.values.toList()) if (rt.runner == null && rt.stage == Stage.FAILED) resetForRetry(rt)
        }
        publish()
        pump()
    }

    /** Убирает одну задачу из очереди (если качается, останавливает) вместе с `.part`. */
    fun cancel(key: String) {
        synchronized(lock) {
            val rt = jobs.remove(key) ?: return
            rt.cancelled = true
            batchFailures.removeAll { it.key == key }
            val runner = rt.runner
            if (runner != null) runner.cancel() else storage.remove(key)
            if (batchTotal > 0 && rt.stage != Stage.FAILED && !rt.silent) batchTotal--
            checkBatchDone()
        }
        publish()
        pump()
    }

    fun cancelAll() {
        synchronized(lock) {
            for (rt in jobs.values.toList()) {
                rt.cancelled = true
                val runner = rt.runner
                if (runner != null) runner.cancel() else storage.remove(rt.job.key)
            }
            jobs.clear()
            batchTotal = 0
            batchOk = 0
            batchFailures.clear()
        }
        publish()
    }

    /** Удаляет сохранённый трек: сначала запись, потом звук (I2). */
    fun remove(key: String) {
        synchronized(lock) {
            if (saved.remove(key) == null) return
            storage.remove(key)
        }
        publish()
    }

    /** «Очистить всё» в настройках. */
    fun clearAll() {
        cancelAll()
        synchronized(lock) {
            saved.clear()
            storage.clear()
        }
        publish()
    }

    fun markPlayed(key: String) {
        synchronized(lock) {
            val e = saved[key] ?: return
            val updated = e.copy(lastPlayedAt = now())
            saved[key] = updated
            try {
                storage.putMeta(MetaKind.ENTRY, key, updated.encode())
            } catch (_: Exception) {
            }
        }
    }

    // ---------- чтение ----------

    fun isSaved(key: String): Boolean = synchronized(lock) { key in saved }

    /** Путь к готовому файлу для плеера, если трек сохранён. */
    fun audioPath(key: String): String? = synchronized(lock) { if (key in saved) storage.audioPath(key) else null }

    fun usage(): Usage = storage.usage()

    // ---------- внутренности ----------

    private fun resetForRetry(rt: Rt) {
        rt.job = rt.job.copy(state = Stage.QUEUED.name, attempts = 0, code = null, reason = null, failedAt = null)
        rt.stage = Stage.QUEUED
        rt.retryAt = 0
        rt.silent = false // человек сам нажал «Повторить»: итог пакета ему положен
        batchFailures.removeAll { it.key == rt.job.key }
        batchTotal++
        try {
            storage.putMeta(MetaKind.JOB, rt.job.key, rt.job.encode())
        } catch (_: Exception) {
        }
    }

    private fun interruptRunning() {
        synchronized(lock) { interruptRunningLocked() }
    }

    private fun interruptRunningLocked() {
        for (rt in jobs.values) {
            val runner = rt.runner ?: continue
            rt.requeue = true
            runner.cancel()
        }
    }

    private fun pump() {
        synchronized(lock) {
            if (!started || paused || !network.online.value) return
            val t = now()
            var running = jobs.values.count { it.runner != null }
            for (rt in jobs.values) {
                if (running >= config.maxParallel) break
                if (rt.runner == null && rt.stage == Stage.QUEUED && rt.retryAt <= t) {
                    rt.requeue = false
                    rt.stage = Stage.RESOLVING
                    rt.haveAtStart = rt.have
                    rt.runner = scope.launch(Dispatchers.IO) { work(rt) }
                    running++
                }
            }
        }
        publish()
    }

    private suspend fun work(rt: Rt) {
        var entry: ManifestEntry? = null
        var failure: OfflineException? = null
        try {
            entry = downloader.download(rt.job, hooksFor(rt))
        } catch (_: CancellationException) {
            // пауза, пропала сеть, отмена пользователем или остановка приложения: разбирается finish
        } catch (e: OfflineException) {
            failure = e
        } catch (e: Exception) {
            failure = OfflineException(OfflineCode.SOURCE_ERROR, "unexpected", e.message, e)
        }
        val retryIn = withContext(NonCancellable) { finish(rt, entry, failure) }
        publish()
        if (retryIn != null) {
            scope.launch {
                delay(retryIn)
                pump()
            }
        } else {
            pump()
        }
    }

    private fun hooksFor(rt: Rt) = DownloadHooks(
        onStage = { s ->
            rt.stage = s
            publish()
        },
        onProgress = { have, total ->
            rt.have = have
            if (total != null) rt.total = total
            publishThrottled()
        },
        onMeta = { etag, total, mime ->
            if (total != null) rt.total = total
            rt.job = rt.job.copy(etag = etag, total = total, mime = mime)
            try {
                storage.putMeta(MetaKind.JOB, rt.job.key, rt.job.encode())
            } catch (_: Exception) {
            }
        },
    )

    /** Разбор итога работы. Возвращает задержку автоповтора, если он нужен. */
    private fun finish(rt: Rt, entry: ManifestEntry?, failure: OfflineException?): Long? =
        synchronized(lock) {
            rt.runner = null
            when {
                rt.cancelled -> {
                    storage.remove(rt.job.key)
                    null
                }
                entry != null -> complete(rt, entry)
                failure != null -> fail(rt, failure)
                else -> {
                    rt.stage = Stage.QUEUED // прервали паузой, потерей сети или остановкой
                    rt.requeue = false
                    rt.have = storage.partSize(rt.job.key)
                    null
                }
            }
        }

    private fun complete(rt: Rt, entry: ManifestEntry): Long? {
        val key = rt.job.key
        return try {
            storage.putMeta(MetaKind.ENTRY, key, entry.encode()) // I2: запись после звука
            storage.delMeta(MetaKind.JOB, key) // I5: задача уходит только после записи
            jobs.remove(key)
            saved[key] = entry
            if (!rt.silent) batchOk++
            checkBatchDone()
            null
        } catch (e: Exception) {
            storage.deleteAudio(key)
            fail(rt, FileStorage.mapIo(java.io.IOException(e.message, e)))
        }
    }

    private fun fail(rt: Rt, e: OfflineException): Long? {
        val job = rt.job
        if (e.code == OfflineCode.NO_NETWORK) {
            rt.stage = Stage.QUEUED // попытка не тратится, продолжим по событию «сеть появилась»
            rt.have = storage.partSize(job.key)
            return null
        }
        // Считаем сбои подряд без прогресса: если в упавшей попытке байты шли, счёт начинается заново.
        val streak = if (storage.partSize(job.key) > rt.haveAtStart) 0 else job.attempts
        if (e.code.retryable && streak < config.retryDelaysMs.size) {
            val attempts = streak + 1
            rt.job = job.copy(attempts = attempts)
            persistJob(rt)
            rt.stage = Stage.QUEUED
            rt.have = storage.partSize(job.key)
            val base = config.retryDelaysMs[attempts - 1]
            val k = 1.0 + (config.random() * 2.0 - 1.0) * config.jitter
            val delay = (base * k).toLong().coerceAtLeast(0)
            rt.retryAt = now() + delay
            return delay
        }
        if (e.code == OfflineCode.BAD_CONTENT || e.code == OfflineCode.NOT_ALLOWED || e.code == OfflineCode.NOT_DOWNLOADABLE) {
            storage.deletePart(job.key)
            rt.have = 0
        }
        rt.job = job.copy(state = Stage.FAILED.name, code = e.code.name, reason = e.reason, failedAt = now())
        persistJob(rt)
        rt.stage = Stage.FAILED
        if (!rt.silent) batchFailures.add(Failure(job.key, job.meta.title, e.code, e.reason))
        checkBatchDone()
        return null
    }

    private fun persistJob(rt: Rt) {
        try {
            storage.putMeta(MetaKind.JOB, rt.job.key, rt.job.encode())
        } catch (_: Exception) {
        }
    }

    /** Когда в очереди не осталось ничего живого, отдаём итог пакета. Вызывается под замком. */
    private fun checkBatchDone() {
        if (batchTotal == 0 && batchFailures.isEmpty()) return
        if (jobs.values.any { it.stage != Stage.FAILED }) return
        val ev = OfflineEvent.BatchDone(batchOk, batchTotal.coerceAtLeast(batchOk + batchFailures.size), batchFailures.toList())
        batchTotal = 0
        batchOk = 0
        batchFailures.clear()
        eventFlow.tryEmit(ev)
    }

    private fun publishThrottled() {
        val t = now()
        if (t - lastPublish >= PUBLISH_EVERY_MS) {
            lastPublish = t
            publish()
        }
    }

    private fun publish() {
        stateFlow.value = synchronized(lock) {
            OfflineState(
                ready = started,
                jobs = jobs.values.map { rt ->
                    val failed = rt.stage == Stage.FAILED
                    JobView(
                        key = rt.job.key,
                        title = rt.job.meta.title,
                        artist = rt.job.meta.artist,
                        cover = rt.job.meta.cover,
                        stage = rt.stage,
                        have = rt.have,
                        total = rt.total ?: rt.job.total,
                        attempt = rt.job.attempts,
                        code = if (failed) rt.job.failure else null,
                        reason = if (failed) rt.job.reason else null,
                        retryAt = rt.retryAt.takeIf { it > now() && rt.stage == Stage.QUEUED },
                    )
                },
                saved = saved.values.toList(),
                paused = paused,
                online = network.online.value,
            )
        }
    }

    private companion object {
        const val PUBLISH_EVERY_MS = 150L
    }
}
