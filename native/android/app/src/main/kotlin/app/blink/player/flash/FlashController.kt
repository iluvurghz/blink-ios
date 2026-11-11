package app.blink.player.flash

import app.blink.core.model.Track
import app.blink.core.wave.LibraryStore
import app.blink.core.wave.WaveEngine
import app.blink.core.wave.WaveMode
import app.blink.core.wave.WaveSettings
import app.blink.player.Graph
import app.blink.player.playback.PlayerUi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Вспышка на телефоне: запускает поток, подкладывает новые треки, пока играет текущий, и пересказывает
 * движку, что слушали, что пропустили и что «не моё». Сам алгоритм живёт в ядре ([WaveEngine]).
 */
class FlashController(
    private val g: Graph,
    private val engine: WaveEngine,
    private val library: LibraryStore,
    private val settings: MutableStateFlow<WaveSettings>,
) {
    private val activeFlow = MutableStateFlow(false)
    val active: StateFlow<Boolean> = activeFlow.asStateFlow()
    private val loadingFlow = MutableStateFlow(false)
    val loading: StateFlow<Boolean> = loadingFlow.asStateFlow()
    val mode: StateFlow<WaveMode> get() = modeFlow
    private val modeFlow = MutableStateFlow(settings.value.mode)

    private val lock = Mutex()
    private val queued = LinkedHashSet<String>()
    private var last: PlayerUi? = null

    /** Подписка на плеер: история, прослушивание, пропуски и догрузка очереди. Зовётся один раз из Graph. */
    fun attach() {
        g.scope.launch {
            g.player.state.collect { ui -> onPlayer(ui) }
        }
    }

    private fun onPlayer(ui: PlayerUi) {
        val before = last
        last = ui
        val now = ui.track
        val prev = before?.track
        if (now != null && now.id != prev?.id) {
            library.noteRecent(now)
            if (before != null && prev != null && activeFlow.value) {
                // Ушли с трека: дослушали или нажали «дальше» в первые секунды.
                val dur = before.durationMs
                val fraction = if (dur > 0) before.positionMs.toDouble() / dur else 0.0
                if (fraction >= 0.7) engine.noteListen(prev, fraction)
                else if (before.positionMs < SKIP_MS) engine.noteSkip(prev)
            }
        }
        if (activeFlow.value && ui.connected && now != null && ui.queueLeft <= REFILL_AT) refill()
    }

    fun start() {
        activeFlow.value = true
        queued.clear()
        g.scope.launch {
            lock.withLock {
                loadingFlow.value = true
                try {
                    val quick = engine.quickStart()
                    if (quick.isNotEmpty()) {
                        queued.addAll(quick.map { it.id })
                        g.actions.play(quick, 0)
                    }
                    val more = fresh()
                    if (quick.isEmpty()) {
                        if (more.isEmpty()) {
                            g.toasts.show("Не получилось собрать Вспышку. Проверьте интернет и попробуйте ещё раз")
                            activeFlow.value = false
                        } else {
                            g.actions.play(more, 0)
                        }
                    } else if (more.isNotEmpty() && g.network.online.value) {
                        g.player.append(more)
                    }
                } finally {
                    loadingFlow.value = false
                }
            }
        }
    }

    fun stop() {
        activeFlow.value = false
    }

    private fun refill() {
        if (loadingFlow.value) return
        g.scope.launch {
            if (!lock.tryLock()) return@launch
            loadingFlow.value = true
            try {
                val more = fresh()
                if (more.isNotEmpty() && activeFlow.value) g.player.append(more)
            } finally {
                loadingFlow.value = false
                lock.unlock()
            }
        }
    }

    /** Свежая партия от движка; если сервер молчит, то чарт и лайки, чтобы музыка не обрывалась. */
    private suspend fun fresh(): List<Track> {
        var batch = engine.batch(BATCH, queued)
        if (batch.isEmpty()) {
            val chart = try { g.api.chart(30) } catch (_: Exception) { emptyList() }
            batch = (library.likes.shuffled() + chart.shuffled()).filter { it.id !in queued }.distinctBy { it.id }.take(BATCH)
        }
        queued.addAll(batch.map { it.id })
        return batch
    }

    fun setMode(mode: WaveMode) {
        modeFlow.value = mode
        settings.value = settings.value.copy(mode = mode)
    }

    /** «Не моё»: запомнить и сразу перейти к следующему. */
    fun dislike(track: Track) {
        g.scope.launch { engine.dislike(track) }
        g.toasts.show("Больше такого не будет")
        g.player.next()
    }

    fun toggleLike(track: Track) {
        val liked = library.toggleLike(track)
        g.toasts.show(if (liked) "Добавлено в понравившееся" else "Убрано из понравившегося")
    }

    private companion object {
        const val BATCH = 16
        const val REFILL_AT = 3
        const val SKIP_MS = 12_000L
    }
}
