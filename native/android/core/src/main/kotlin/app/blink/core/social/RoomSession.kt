package app.blink.core.social

import app.blink.core.model.Track
import kotlin.math.abs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Что сейчас играет у нас. */
data class LocalPlayback(val track: Track?, val playing: Boolean, val positionMs: Long, val loading: Boolean = false) {
    val trackId: String? get() = track?.id
}

/** Рука сессии на плеере устройства. На Android это `PlayerController`, на тестах подделка. */
interface RoomPlayerPort {
    fun local(): LocalPlayback

    /** Очередь целиком и что в ней играть ([index]), с места [positionMs]. */
    fun playQueue(queue: List<Track>, index: Int, positionMs: Long, playing: Boolean)

    /** Тот же трек: встать на [positionMs] и играть или встать на паузу. */
    fun setPlaying(playing: Boolean, positionMs: Long)

    fun seekTo(positionMs: Long)

    fun appendToQueue(tracks: List<Track>)

    /** Очередь плеера и номер текущего: уходит в комнату, когда сменили трек руками. */
    fun queue(): Pair<List<Track>, Int>
}

/**
 * Логика комнаты «Слушать вместе»: слушаем сервер (поток или long poll), подгоняем плеер под комнату и
 * отправляем в комнату то, что человек сделал руками. Порт с сайта (`src/lib/together.js`); числа те же.
 */
class RoomSession(
    private val service: RoomService,
    private val scope: CoroutineScope,
    private val port: RoomPlayerPort,
    private val userId: () -> String?,
    private val say: (String) -> Unit,
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val nanos: () -> Long = System::nanoTime,
) {
    private val lock = Any()
    private val sendLock = Mutex()
    private val flow = MutableStateFlow<RoomState?>(null)
    val room: StateFlow<RoomState?> = flow.asStateFlow()

    private val chatFlow = MutableSharedFlow<RoomChat>(extraBufferCapacity = 16)

    /** Новые сообщения от других людей (для всплывашки, пока чат закрыт). */
    val incoming: SharedFlow<RoomChat> = chatFlow.asSharedFlow()

    private var current: RoomState? = null
    private var job: Job? = null
    private var offset = 0L
    private var clockOffset: Long? = null
    private var applyingUntil = 0L
    private var lastTrackId: String? = null
    private val seenChat = HashSet<String>()

    val inRoom: Boolean get() = synchronized(lock) { current != null }

    fun isHost(): Boolean = flow.value?.isHost(userId()) == true

    // ---------- вход и выход ----------

    /** Создать комнату; то, что играет сейчас, становится треком комнаты. Возвращает код или null. */
    suspend fun create(): String? {
        if (inRoom) leave()
        val reply = service.create()
        val r = reply.room
        if (!reply.ok || r == null) {
            say(reply.error ?: "Не получилось создать комнату")
            return null
        }
        synchronized(lock) {
            current = r
            seenChat.clear()
            r.chat.forEach { seenChat.add(it.id) }
        }
        flow.value = r
        val local = port.local()
        lastTrackId = local.trackId
        start(r.code)
        val t = local.track
        if (t != null) {
            val (queue, index) = port.queue()
            post(local.playing, local.positionMs / 1000.0, t, queue.ifEmpty { listOf(t) }, index)
        }
        return r.code
    }

    fun join(code: String) {
        val c = code.trim()
        if (c.isEmpty()) return
        if (synchronized(lock) { current?.code == c }) return
        if (inRoom) leave()
        val placeholder = RoomState(code = c, rev = 0, v = 0)
        synchronized(lock) {
            current = placeholder
            seenChat.clear()
        }
        flow.value = placeholder
        lastTrackId = port.local().trackId
        start(c)
    }

    fun leave() {
        val code = synchronized(lock) { current?.code } ?: return
        scope.launch { service.leave(code) }
        end(null)
    }

    private fun end(message: String?) {
        job?.cancel()
        job = null
        synchronized(lock) { current = null }
        flow.value = null
        if (message != null) say(message)
    }

    // ---------- слушаем комнату ----------

    private fun start(code: String) {
        job?.cancel()
        job = scope.launch {
            launch { syncClock() }
            launch { catchUpLoop(code) }
            listen(code)
        }
    }

    private suspend fun listen(code: String) {
        var fails = 0
        while (scope.isActive && stillIn(code) && fails < 3) {
            var got = 0
            val result = try {
                service.stream(code) { r ->
                    got++
                    update(r)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                StreamEnd.Dropped
            }
            when (result) {
                is StreamEnd.Gone -> return end(result.message)
                StreamEnd.Unsupported -> break
                StreamEnd.Dropped -> {
                    fails = if (got > 0) 0 else fails + 1
                    delay(if (got > 0) 500 else 1500)
                }
            }
        }
        poll(code)
    }

    /** Запасной путь: сервер без потока или поток заблокирован. */
    private suspend fun poll(code: String) {
        while (scope.isActive && stillIn(code)) {
            val rev = synchronized(lock) { current?.rev ?: 0 }
            val reply = try {
                service.poll(code, rev)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                delay(3000)
                continue
            }
            val r = reply.room
            when {
                reply.ok && r != null -> update(r)
                reply.gone -> return end(reply.error ?: "Комната закрыта")
                else -> delay(3000)
            }
        }
    }

    private fun stillIn(code: String): Boolean = synchronized(lock) { current?.code == code }

    /** Серверные часы минус наши по самому быстрому из нескольких обращений: задержка сети сокращается. */
    private suspend fun syncClock() {
        var bestRtt = Long.MAX_VALUE
        var best: Long? = null
        repeat(4) {
            val a = nanos()
            val server = try {
                service.serverTime()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                null
            }
            val rtt = (nanos() - a) / 1_000_000
            if (server != null && rtt < bestRtt) {
                bestRtt = rtt
                best = server + rtt / 2 - nowMs()
            }
        }
        best?.let { b ->
            synchronized(lock) {
                clockOffset = b
                offset = b
            }
        }
    }

    private suspend fun catchUpLoop(code: String) {
        while (scope.isActive && stillIn(code)) {
            delay(5000)
            val r = synchronized(lock) { current } ?: return
            val t = r.track ?: continue
            val local = port.local()
            if (local.trackId == t.id && local.playing && r.playing) {
                val target = r.targetMs(nowMs(), synchronized(lock) { offset })
                if (abs(local.positionMs - target) > 3000) {
                    quiet()
                    port.seekTo(target)
                }
            }
        }
    }

    // ---------- комната пришла ----------

    internal fun update(r: RoomState) {
        val mine = userId()
        val fresh = ArrayList<RoomChat>()
        synchronized(lock) {
            val cur = current ?: return
            if (r.code != cur.code || r.rev < cur.rev) return
            val first = cur.rev == 0L
            for (c in r.chat) if (seenChat.add(c.id) && !first && c.by != mine) fresh.add(c)
            current = r
            offset = clockOffset ?: (r.now - nowMs())
        }
        flow.value = r
        fresh.forEach { chatFlow.tryEmit(it) }
        follow(r)
    }

    private fun follow(r: RoomState) {
        val t = r.track ?: return
        val local = port.local()
        val target = r.targetMs(nowMs(), synchronized(lock) { offset })
        if (local.trackId != t.id) {
            quiet()
            lastTrackId = t.id
            port.playQueue(r.queue.ifEmpty { listOf(t) }, r.index, target, r.playing)
            return
        }
        // Другие добавили треки в очередь комнаты: у нас они появляются в очереди плеера.
        val (have, _) = port.queue()
        if (r.queue.size > have.size && r.queue.take(have.size).map { it.id } == have.map { it.id }) {
            port.appendToQueue(r.queue.drop(have.size))
        }
        if (local.loading) return
        if (r.playing != local.playing) {
            quiet()
            port.setPlaying(r.playing, target)
            return
        }
        if (abs(local.positionMs - target) > 2500) {
            quiet()
            port.seekTo(target)
        }
    }

    /** Следующие полторы секунды всё, что делает плеер, считаем своим, а не действием человека. */
    private fun quiet() {
        applyingUntil = nowMs() + 1500
    }

    // ---------- человек сделал руками ----------

    /** Плеер сменил трек или состояние: если это не мы его подогнали, сообщаем комнате. */
    fun onLocal(snap: LocalPlayback) {
        val r = synchronized(lock) { current } ?: return
        if (r.rev == 0L || nowMs() < applyingUntil) return
        val id = snap.trackId
        if (id != null && id != r.track?.id) {
            if (id == lastTrackId) return
            lastTrackId = id
            val (queue, index) = port.queue()
            scope.launch { post(true, 0.0, snap.track, queue.ifEmpty { listOfNotNull(snap.track) }, index) }
            return
        }
        if (id != null && id == r.track?.id && !snap.loading && snap.playing != r.playing) {
            scope.launch { post(snap.playing, snap.positionMs / 1000.0) }
        }
    }

    /** Человек перемотал. */
    fun onUserSeek(positionMs: Long) {
        if (!inRoom) return
        val playing = port.local().playing
        scope.launch { post(playing, positionMs / 1000.0) }
    }

    private suspend fun post(playing: Boolean, posSec: Double, track: Track? = null, queue: List<Track>? = null, index: Int = 0) {
        sendLock.withLock {
            val r = synchronized(lock) { current } ?: return
            val reply = try {
                service.post(r.code, r.v, playing, posSec, track, queue, index)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                return
            }
            handle(reply)
        }
    }

    private fun handle(reply: RoomReply): Boolean {
        val r = reply.room
        return when {
            reply.ok || reply.status == 409 -> {
                r?.let(::update)
                if (reply.status == 409 && reply.error != null) say(reply.error)
                reply.ok
            }
            reply.status == 403 && r != null -> {
                update(r) // комната под управлением хоста: возвращаем то, что играет в ней
                say(reply.error ?: "Управляет хост комнаты")
                false
            }
            reply.gone -> {
                end(reply.error ?: "Комната закрыта")
                false
            }
            else -> {
                if (reply.error != null) say(reply.error)
                false
            }
        }
    }

    // ---------- команды ----------

    private fun code(): String? = synchronized(lock) { current?.code }

    suspend fun sendChat(text: String): Boolean {
        val c = code() ?: return false
        val reply = service.chat(c, text.trim())
        if (reply.ok) {
            reply.room?.let(::update)
            return true
        }
        say(reply.error ?: "Сообщение не отправилось")
        return false
    }

    suspend fun react(emoji: String) {
        val c = code() ?: return
        val reply = service.react(c, emoji)
        if (reply.ok) reply.room?.let(::update)
    }

    suspend fun setMode(mode: String) {
        val c = code() ?: return
        val reply = service.mode(c, mode)
        if (reply.ok) reply.room?.let(::update) else say(reply.error ?: "Не получилось")
    }

    suspend fun addToQueue(track: Track): Boolean {
        val c = code() ?: return false
        val reply = service.enqueue(c, track)
        if (reply.ok) {
            reply.room?.let(::update)
            say("Добавлено в очередь комнаты")
            return true
        }
        say(reply.error ?: "Не получилось добавить")
        return false
    }

    suspend fun voteSkip() {
        val c = code() ?: return
        val reply = service.skip(c)
        reply.room?.let { if (reply.ok || reply.status == 409) update(it) }
        if (!reply.ok) say(reply.error ?: "Не получилось")
    }

    companion object {
        val EMOJI = listOf("🔥", "❤️", "😂", "🥹", "🤯", "👏", "💃", "🎧")
        const val MAX_MEMBERS = 8

        /** Ссылка-приглашение, как на сайте. */
        fun link(code: String): String = "https://blinkmusic.cc/r/$code"

        /** Код комнаты из ссылки (`/r/<код>` или `?together=<код>`) или null. */
        fun codeFrom(url: String?): String? {
            if (url.isNullOrBlank()) return null
            Regex("""blinkmusic\.cc/r/([A-Za-z0-9_-]{4,40})""").find(url)?.let { return it.groupValues[1] }
            Regex("""[?&]together=([A-Za-z0-9_-]{4,40})""").find(url)?.let { return it.groupValues[1] }
            return null
        }
    }
}
