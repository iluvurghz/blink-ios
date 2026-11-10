package app.blink.core.offline

import app.blink.core.net.run
import java.io.IOException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

/** Куда загрузчик сообщает о ходе работы. */
class DownloadHooks(
    val onStage: (Stage) -> Unit = {},
    val onProgress: (have: Long, total: Long?) -> Unit = { _, _ -> },
    /** Пора сохранить в job-файл etag/размер: они нужны для докачки после перезапуска. */
    val onMeta: (etag: String?, total: Long?, mime: String?) -> Unit = { _, _, _ -> },
)

/**
 * Скачивает один трек по контракту offline-cache v1:
 * резолв → циклом GET с Range до `total` (сервер режет открытый Range до 2 МиБ, один 206 не значит «готово»)
 * → проверка → атомарный commit. Манифест пишет вызывающий и только после этого.
 */
class Downloader(
    private val storage: Storage,
    private val resolver: TrackResolver,
    http: OkHttpClient,
    private val network: NetworkMonitor,
    private val now: () -> Long = System::currentTimeMillis,
    idleTimeoutSeconds: Long = IDLE_TIMEOUT_SECONDS,
    private val resolveTimeoutMs: Long = RESOLVE_TIMEOUT_MS,
) {
    // Заголовки 20 с, пауза без байтов 20 с. Общего лимита на вызов нет: файлы большие.
    private val http: OkHttpClient = http.newBuilder()
        .connectTimeout(idleTimeoutSeconds, java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(idleTimeoutSeconds, java.util.concurrent.TimeUnit.SECONDS)
        .writeTimeout(idleTimeoutSeconds, java.util.concurrent.TimeUnit.SECONDS)
        .callTimeout(0, java.util.concurrent.TimeUnit.SECONDS)
        .build()

    private class Ctx(
        var url: String,
        var etag: String?,
        var total: Long?,
        var mime: String?,
        var have: Long,
    )

    private enum class Step { MORE, DONE, EXPIRED, RESTART }

    suspend fun download(job: OfflineJob, hooks: DownloadHooks = DownloadHooks()): ManifestEntry {
        val key = job.key
        hooks.onStage(Stage.RESOLVING)
        var resolved = resolve(job)

        var have = storage.partSize(key)
        if (have > 0 && changed(job.etag, job.total, resolved)) {
            storage.truncatePart(key, 0)
            have = 0
        }
        val ctx = Ctx(
            url = resolved.url,
            etag = resolved.etag ?: if (have > 0) job.etag else null,
            total = resolved.bytes ?: if (have > 0) job.total else null,
            mime = resolved.mime ?: job.mime,
            have = have,
        )
        hooks.onMeta(ctx.etag, ctx.total, ctx.mime)
        hooks.onStage(Stage.DOWNLOADING)
        hooks.onProgress(ctx.have, ctx.total)

        var reResolves = 0
        var restarts = 0
        while (true) {
            currentCoroutineContext().ensureActive()
            val total = ctx.total
            if (total != null && ctx.have == total) break
            if (total != null && ctx.have > total) reset(key, ctx)

            when (fetch(job, ctx, hooks)) {
                Step.MORE -> Unit
                Step.DONE -> break
                Step.RESTART -> if (++restarts > MAX_RESTARTS) throw OfflineException(OfflineCode.SOURCE_ERROR, "restart_loop")
                Step.EXPIRED -> {
                    // Ссылка просрочена (403 на файле): резолвим заново и продолжаем с того же места.
                    if (++reResolves > MAX_RE_RESOLVES) throw OfflineException(OfflineCode.SOURCE_ERROR, "expired")
                    resolved = resolve(job)
                    if (ctx.have > 0 && changed(ctx.etag, ctx.total, resolved)) reset(key, ctx)
                    ctx.url = resolved.url
                    ctx.etag = resolved.etag ?: ctx.etag
                    ctx.total = resolved.bytes ?: ctx.total
                    hooks.onMeta(ctx.etag, ctx.total, ctx.mime)
                }
            }
        }

        hooks.onStage(Stage.VERIFYING)
        val have2 = storage.partSize(key)
        val head = storage.readPart(key, 0, Content.SNIFF_BYTES.toLong())
        try {
            if (!Content.magicOk(head)) throw OfflineException(OfflineCode.BAD_CONTENT, "magic")
            Content.verifyFinal(have2, ctx.total, resolved.bytes, resolved.duration ?: job.meta.duration)
        } catch (e: OfflineException) {
            storage.truncatePart(key, 0) // битые данные не докачиваем
            throw e
        }

        hooks.onStage(Stage.COMMITTING)
        storage.commit(key)
        return ManifestEntry(
            key = job.key,
            source = job.source,
            id = job.id,
            title = job.meta.title,
            artist = job.meta.artist,
            album = job.meta.album,
            cover = job.meta.cover,
            duration = resolved.duration ?: job.meta.duration,
            bytes = have2,
            mime = resolved.mime ?: ctx.mime,
            etag = ctx.etag,
            savedAt = now(),
            offlineAllowed = job.meta.offlineAllowed,
            track = job.meta.track,
        )
    }

    // ---------- резолв ----------

    private suspend fun resolve(job: OfflineJob): Resolved =
        try {
            withTimeoutOrNull(resolveTimeoutMs) { resolver.resolve(job.source, job.id) }
                ?: throw OfflineException(OfflineCode.TIMEOUT, "resolve")
        } catch (e: IOException) {
            currentCoroutineContext().ensureActive()
            throw classify(e)
        }

    /** Файл на сервере сменился с тех пор, как начали (etag или размер другие): .part выбрасываем. */
    private fun changed(etag: String?, total: Long?, r: Resolved): Boolean =
        (etag != null && r.etag != null && etag != r.etag) || (total != null && r.bytes != null && total != r.bytes)

    private fun reset(key: String, ctx: Ctx) {
        storage.truncatePart(key, 0)
        ctx.have = 0
    }

    // ---------- один запрос ----------

    private suspend fun fetch(job: OfflineJob, ctx: Ctx, hooks: DownloadHooks): Step {
        val rb = Request.Builder()
            .url(ctx.url)
            .header("Accept", "audio/*,application/octet-stream;q=0.9")
            // Без сжатия: иначе OkHttp сам разожмёт ответ и арифметика Range поедет.
            .header("Accept-Encoding", "identity")
        if (ctx.have > 0) {
            rb.header("Range", "bytes=${ctx.have}-")
            ctx.etag?.let { rb.header("If-Range", it) } // дословно, вместе с W/ и кавычками
        }
        return try {
            http.newCall(rb.build()).run { resp -> consume(resp, job.key, ctx, hooks) }
        } catch (e: IOException) {
            currentCoroutineContext().ensureActive()
            throw classify(e)
        }
    }

    private fun consume(resp: Response, key: String, ctx: Ctx, hooks: DownloadHooks): Step {
        when (val code = resp.code) {
            200 -> {
                requireAudio(resp)
                // 200 на запрос с Range: сервер отдаёт файл целиком, начинаем с нуля.
                if (ctx.have > 0) reset(key, ctx)
                val len = resp.header("Content-Length")?.trim()?.toLongOrNull()
                if (len != null) {
                    if (ctx.total != null && ctx.total != len) throw OfflineException(OfflineCode.BAD_CONTENT, "size_mismatch")
                    ctx.total = len
                }
                readBody(resp, key, ctx, hooks)
                if (ctx.total == null) ctx.total = ctx.have // чистый конец потока без длины: берём что пришло
                return Step.MORE
            }
            206 -> {
                requireAudio(resp)
                val cr = ContentRange.parse(resp.header("Content-Range"))
                    ?: throw OfflineException(OfflineCode.SOURCE_ERROR, "bad_content_range")
                if (cr.start != ctx.have) {
                    // Сервер ответил с другого места: доверять нельзя, начинаем сначала.
                    reset(key, ctx)
                    return Step.RESTART
                }
                if (cr.total != null) {
                    if (ctx.total != null && ctx.total != cr.total) throw OfflineException(OfflineCode.BAD_CONTENT, "size_mismatch")
                    ctx.total = cr.total
                }
                readBody(resp, key, ctx, hooks)
                return Step.MORE
            }
            416 -> {
                val total = ctx.total
                if (total != null && ctx.have == total) return Step.DONE
                reset(key, ctx)
                return Step.RESTART
            }
            401, 403, 410 -> return Step.EXPIRED
            404 -> throw OfflineException(OfflineCode.NOT_DOWNLOADABLE, "missing")
            else -> throw OfflineException(OfflineCode.SOURCE_ERROR, "http_$code") // 408/425/429/5xx и прочее: повтор
        }
    }

    private fun requireAudio(resp: Response) {
        val type = resp.header("Content-Type")
        if (!Content.typeOk(type)) throw OfflineException(OfflineCode.BAD_CONTENT, "type")
    }

    /**
     * Читает тело и дописывает в `.part` порциями не меньше 256 КиБ строго подряд.
     * Первые байты проверяются сразу, до записи на диск. Накопленное при обрыве сохраняется.
     */
    private fun readBody(resp: Response, key: String, ctx: Ctx, hooks: DownloadHooks) {
        val body = resp.body ?: throw OfflineException(OfflineCode.SOURCE_ERROR, "empty_body")
        if (ctx.mime == null) ctx.mime = resp.header("Content-Type")?.substringBefore(';')?.trim()?.takeIf { it.isNotEmpty() }
        val input = body.byteStream()
        val chunk = ByteArray(READ_CHUNK)
        val pending = ByteArray(WRITE_BATCH)
        var pLen = 0
        var sniffed = ctx.have > 0
        var received = 0L
        var shown = ctx.have

        fun flush() {
            if (pLen > 0) {
                storage.appendPart(key, pending, 0, pLen)
                ctx.have += pLen
                pLen = 0
            }
        }

        try {
            while (true) {
                val n = input.read(chunk)
                if (n < 0) break
                var off = 0
                while (off < n) {
                    val take = minOf(n - off, pending.size - pLen)
                    System.arraycopy(chunk, off, pending, pLen, take)
                    pLen += take
                    off += take
                    if (!sniffed && pLen >= Content.SNIFF_BYTES) {
                        if (!Content.magicOk(pending, pLen)) throw OfflineException(OfflineCode.BAD_CONTENT, "magic")
                        sniffed = true
                    }
                    if (pLen == pending.size) flush()
                }
                received += n
                val seen = ctx.have + pLen
                if (seen - shown >= PROGRESS_STEP) {
                    shown = seen
                    hooks.onProgress(seen, ctx.total)
                }
            }
            if (!sniffed) {
                // Весь ответ короче 12 байт: пусто, "<", "{" и подобное
                if (!Content.magicOk(pending, pLen)) throw OfflineException(OfflineCode.BAD_CONTENT, "magic")
                sniffed = true
            }
        } catch (t: Throwable) {
            // Уже полученное и проверенное сохраняем: докачка пойдёт с этого места.
            if (sniffed) {
                try {
                    flush()
                } catch (_: Exception) {
                }
            }
            throw t
        }
        flush()
        // I4: длину берём после сброса на диск
        ctx.have = storage.partSize(key)
        hooks.onProgress(ctx.have, ctx.total)
        if (received == 0L) throw OfflineException(OfflineCode.SOURCE_ERROR, "empty") // ни байта: не зацикливаемся
    }

    private fun classify(e: IOException): OfflineException =
        when {
            e.isTimeoutError() -> OfflineException(OfflineCode.TIMEOUT, cause = e)
            !network.online.value -> OfflineException(OfflineCode.NO_NETWORK, cause = e)
            else -> OfflineException(OfflineCode.SOURCE_ERROR, "io", e.message, e)
        }

    private fun IOException.isTimeoutError(): Boolean =
        this is java.net.SocketTimeoutException ||
            (this is java.io.InterruptedIOException && (message ?: "").contains("timeout", ignoreCase = true))

    companion object {
        const val RESOLVE_TIMEOUT_MS = 15_000L
        const val IDLE_TIMEOUT_SECONDS = 20L
        const val MAX_RE_RESOLVES = 2
        const val MAX_RESTARTS = 3
        const val WRITE_BATCH = 256 * 1024
        private const val READ_CHUNK = 32 * 1024
        private const val PROGRESS_STEP = 64 * 1024
    }
}

/** Заголовок Content-Range вида `bytes 1000000-3097151/5000000`; вместо размера бывает звёздочка. */
internal data class ContentRange(val start: Long, val end: Long, val total: Long?) {
    companion object {
        private val RE = Regex("""^\s*bytes\s+(\d+)\s*-\s*(\d+)\s*/\s*(\d+|\*)\s*$""", RegexOption.IGNORE_CASE)

        fun parse(header: String?): ContentRange? {
            val m = RE.find(header ?: return null) ?: return null
            val (a, b, t) = m.destructured
            val total = if (t == "*") null else t.toLongOrNull()
            return ContentRange(a.toLongOrNull() ?: return null, b.toLongOrNull() ?: return null, total)
        }
    }
}
