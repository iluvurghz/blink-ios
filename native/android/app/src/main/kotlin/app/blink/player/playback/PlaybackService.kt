package app.blink.player.playback

import android.content.Intent
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import app.blink.core.offline.OfflinePolicy
import app.blink.core.play.QueueFilter
import app.blink.player.BlinkApp
import app.blink.player.Graph
import app.blink.player.Tab

/** Плеер живёт в сервисе: музыка играет с выключенным экраном, управляется из шторки и с наушников. */
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        val graph = (application as BlinkApp).graph
        val upstream = DefaultDataSource.Factory(this, OkHttpDataSource.Factory(graph.http))
        val dataSource = ResolvingDataSource.Factory(upstream, BlinkResolver(graph))
        val player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(this).setDataSourceFactory(dataSource))
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(),
                true,
            )
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build()
        player.addListener(FailureHandler(graph, player))
        session = MediaSession.Builder(this, player).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    // Смахнули приложение: если музыка не играет, сервис не держим.
    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = session?.player
        if (player == null || !player.playWhenReady || player.mediaItemCount == 0) stopSelf()
    }

    override fun onDestroy() {
        session?.run {
            player.release()
            release()
        }
        session = null
        super.onDestroy()
    }
}

/**
 * Ошибка на треке не должна ронять очередь молча. Что-то неоткрываемое пропускаем с понятным тостом,
 * без сети перескакиваем сразу к ближайшему сохранённому (один тост на всю пачку).
 */
private class FailureHandler(private val graph: Graph, private val player: ExoPlayer) : Player.Listener {
    override fun onPlayerError(error: PlaybackException) {
        val failure = generateSequence<Throwable>(error) { it.cause }.filterIsInstance<PlayFailure>().firstOrNull()
        when (failure?.kind) {
            PlayFailure.Kind.NEEDS_NETWORK -> skipToSaved()
            PlayFailure.Kind.PLUS_REQUIRED -> {
                graph.toasts.show(failure?.message ?: "Нужен Blink+", "Открыть Blink+") { graph.actions.openPlus() }
                player.pause()
            }
            PlayFailure.Kind.NEED_SIGN_IN -> {
                graph.toasts.show(failure?.message ?: "Войдите в аккаунт", "Войти") { graph.nav.go(Tab.Account) }
                player.pause()
            }
            PlayFailure.Kind.NOT_FOUND, null -> {
                graph.toasts.show(failure?.message ?: "Не получилось проиграть трек")
                advance()
            }
        }
    }

    private fun advance() {
        if (!player.hasNextMediaItem()) return
        player.seekToNextMediaItem()
        player.prepare()
        player.play()
    }

    private fun skipToSaved() {
        var skipped = 1
        for (i in player.currentMediaItemIndex + 1 until player.mediaItemCount) {
            if (isSaved(player.getMediaItemAt(i))) {
                player.seekTo(i, C.TIME_UNSET)
                player.prepare()
                player.play()
                graph.toasts.show(QueueFilter.skippedText(skipped))
                return
            }
            skipped++
        }
        graph.toasts.show("Нет интернета. Дальше в очереди нет сохранённых треков")
        player.pause()
    }

    private fun isSaved(item: MediaItem): Boolean {
        val uri = item.localConfiguration?.uri ?: return false
        val key = OfflinePolicy.keyOf(MediaItems.trackFromUri(uri)) ?: return false
        return graph.offline.isSaved(key)
    }
}
