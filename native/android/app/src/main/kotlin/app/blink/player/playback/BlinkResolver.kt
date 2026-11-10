package app.blink.player.playback

import android.net.Uri
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.ResolvingDataSource
import app.blink.core.net.StreamException
import app.blink.core.offline.OfflinePolicy
import app.blink.player.Graph
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import kotlinx.coroutines.runBlocking

/**
 * Почему трек не заиграл. Наследуем FileNotFoundException нарочно: плеер не повторяет такие ошибки
 * (повторять «нужен интернет» или «войдите» бессмысленно) и сразу отдаёт нам причину.
 */
class PlayFailure(val kind: Kind, message: String) : FileNotFoundException(message) {
    enum class Kind { NEED_SIGN_IN, NOT_FOUND, NEEDS_NETWORK, PLUS_REQUIRED }
}

/**
 * Превращает адрес `blinktrack://play?...` в реальный: сохранённый файл с диска (всегда первым), иначе ссылка
 * с сервера. Вызывается на потоке загрузки плеера, поэтому здесь можно ждать сеть блокирующе.
 */
class BlinkResolver(private val graph: Graph) : ResolvingDataSource.Resolver {
    override fun resolveDataSpec(dataSpec: DataSpec): DataSpec {
        val uri = dataSpec.uri
        if (uri.scheme != MediaItems.SCHEME) return dataSpec
        val track = MediaItems.trackFromUri(uri)
        val online = graph.network.online.value

        val key = OfflinePolicy.keyOf(track)
        val path = key?.let { graph.offline.audioPath(it) }
        if (key != null && path != null) {
            if (!OfflinePolicy.canPlaySaved(online, graph.plus.info.value.offlineUntilMs(), System.currentTimeMillis())) {
                throw PlayFailure(PlayFailure.Kind.PLUS_REQUIRED, "Без интернета сохранённые играют с Blink+")
            }
            // Отметку «играли» пишем один раз за трек, а не при каждой перемотке.
            if (dataSpec.position == 0L) graph.offline.markPlayed(key)
            return dataSpec.buildUpon().setUri(Uri.fromFile(File(path))).build()
        }

        if (!online) throw PlayFailure(PlayFailure.Kind.NEEDS_NETWORK, "Нужен интернет: этот трек не сохранён")
        val stream = try {
            runBlocking { graph.api.streamFor(track) }
        } catch (e: StreamException) {
            throw when (e.kind) {
                StreamException.Kind.NEED_SIGN_IN -> PlayFailure(PlayFailure.Kind.NEED_SIGN_IN, e.message ?: "Войдите в аккаунт")
                StreamException.Kind.NOT_FOUND -> PlayFailure(PlayFailure.Kind.NOT_FOUND, e.message ?: "Не нашли звук для этого трека")
                StreamException.Kind.UNAVAILABLE -> IOException(e.message ?: "Источник недоступен")
            }
        }
        return dataSpec.buildUpon().setUri(Uri.parse(stream.url)).build()
    }
}
