package app.blink.player.playback

import android.content.ComponentName
import android.content.Context
import androidx.core.content.ContextCompat
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import app.blink.core.model.Track
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Пульт к плееру в сервисе (MediaController). Подключается, пока приложение на экране; музыка при этом
 * продолжает играть в сервисе. Команды, пришедшие до подключения, ждут в очереди. Любой поток может звать методы.
 */
class PlayerController(private val context: Context, private val scope: CoroutineScope) {
    private val main = ContextCompat.getMainExecutor(context)
    private var future: ListenableFuture<MediaController>? = null
    private var controller: MediaController? = null
    private val pending = ArrayList<(MediaController) -> Unit>()
    private var ticker: Job? = null
    private var cachedId: String? = null
    private var cachedTrack: Track? = null

    private val mutable = MutableStateFlow(PlayerUi())
    val state: StateFlow<PlayerUi> = mutable.asStateFlow()

    private val listener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) {
            sync(player)
        }
    }

    fun connect() {
        main.execute {
            if (future != null) return@execute
            val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
            val f = MediaController.Builder(context, token).buildAsync()
            future = f
            f.addListener(
                {
                    try {
                        val c = f.get()
                        controller = c
                        c.addListener(listener)
                        sync(c)
                        startTicker()
                        val todo = ArrayList(pending)
                        pending.clear()
                        todo.forEach { it(c) }
                    } catch (_: Exception) {
                        future = null
                    }
                },
                main,
            )
        }
    }

    fun disconnect() {
        main.execute {
            ticker?.cancel()
            ticker = null
            controller?.removeListener(listener)
            future?.let { MediaController.releaseFuture(it) }
            controller = null
            future = null
            mutable.update { it.copy(connected = false) }
        }
    }

    private fun command(block: (MediaController) -> Unit) {
        main.execute {
            val c = controller
            if (c != null) {
                block(c)
            } else {
                pending.add(block)
                connect()
            }
        }
    }

    // ---------- команды ----------

    fun play(tracks: List<Track>, index: Int) {
        if (tracks.isEmpty()) return
        val items = tracks.map { MediaItems.of(it) }
        command { c ->
            c.setMediaItems(items, index.coerceIn(0, items.lastIndex), 0L)
            c.prepare()
            c.play()
        }
    }

    /** Дописать треки в конец очереди (Вспышка подкладывает новые, пока играет текущий). */
    fun append(tracks: List<Track>) {
        if (tracks.isEmpty()) return
        val items = tracks.map { MediaItems.of(it) }
        command { c -> c.addMediaItems(items) }
    }

    fun toggle() {
        command { c ->
            if (c.playbackState == Player.STATE_ENDED) c.seekToDefaultPosition()
            if (c.playWhenReady) {
                c.pause()
            } else {
                if (c.playbackState == Player.STATE_IDLE) c.prepare()
                c.play()
            }
        }
    }

    fun seekTo(positionMs: Long) {
        command { c ->
            c.seekTo(positionMs.coerceAtLeast(0))
            sync(c)
        }
    }

    fun next() {
        command { c -> c.seekToNextMediaItem() }
    }

    fun previous() {
        command { c -> c.seekToPrevious() }
    }

    // ---------- состояние ----------

    private fun trackFor(item: MediaItem?): Track? {
        if (item == null) return null
        if (item.mediaId == cachedId) return cachedTrack
        val track = MediaItems.trackOf(item)
        cachedId = item.mediaId
        cachedTrack = track
        return track
    }

    private fun sync(p: Player) {
        val track = trackFor(p.currentMediaItem)
        val d = p.duration
        val duration = if (d != C.TIME_UNSET && d > 0) d else (track?.duration ?: 0) * 1000L
        val buffering = p.playbackState == Player.STATE_BUFFERING
        mutable.value = PlayerUi(
            track = track,
            playing = p.isPlaying || (p.playWhenReady && buffering),
            buffering = buffering,
            positionMs = p.currentPosition.coerceAtLeast(0),
            durationMs = duration,
            hasNext = p.hasNextMediaItem(),
            hasPrevious = p.hasPreviousMediaItem(),
            connected = true,
            queueLeft = (p.mediaItemCount - p.currentMediaItemIndex - 1).coerceAtLeast(0),
        )
    }

    private fun startTicker() {
        if (ticker?.isActive == true) return
        ticker = scope.launch(Dispatchers.Main) {
            while (isActive) {
                delay(TICK_MS)
                val c = controller ?: continue
                if (c.isPlaying) {
                    val position = c.currentPosition.coerceAtLeast(0)
                    mutable.update { it.copy(positionMs = position) }
                }
            }
        }
    }

    private companion object {
        const val TICK_MS = 500L
    }
}
