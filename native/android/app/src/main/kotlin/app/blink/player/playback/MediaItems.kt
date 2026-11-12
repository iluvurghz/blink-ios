package app.blink.player.playback

import android.net.Uri
import android.os.Bundle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import app.blink.core.model.Track
import app.blink.core.net.BlinkJson

/**
 * Трек ⇄ MediaItem. В адресе лежит только то, чем сервис находит звук (id, источник, lic, исполнитель, название),
 * а полный объект трека едет в extras метаданных, чтобы экран получил его обратно без запросов.
 * Слова песни в очередь не кладём: они тяжёлые, а Binder ограничен.
 */
object MediaItems {
    const val SCHEME = "blinktrack"
    private const val EXTRA_TRACK = "blink.track"

    fun of(track: Track): MediaItem {
        val uri = Uri.Builder().scheme(SCHEME).authority("play")
            .appendQueryParameter("id", track.id)
            .appendQueryParameter("src", track.source.orEmpty())
            .appendQueryParameter("lic", track.lic.orEmpty())
            .appendQueryParameter("artist", track.artist)
            .appendQueryParameter("title", track.title)
            .apply { track.stream?.let { appendQueryParameter("stream", it) } }
            .build()
        val extras = Bundle().apply {
            putString(EXTRA_TRACK, BlinkJson.encodeToString(Track.serializer(), track.copy(lrc = null, lyrics = null)))
        }
        val meta = MediaMetadata.Builder()
            .setTitle(track.title)
            .setArtist(track.artist)
            .setAlbumTitle(track.album.ifEmpty { null })
            .setArtworkUri(track.artwork.takeIf { it.isNotEmpty() }?.let { Uri.parse(it) })
            .setIsPlayable(true)
            .setExtras(extras)
            .build()
        return MediaItem.Builder().setMediaId(track.id).setUri(uri).setMediaMetadata(meta).build()
    }

    /** Трек из очереди плеера. Если полной копии нет, собираем из метаданных. */
    fun trackOf(item: MediaItem): Track {
        val json = item.mediaMetadata.extras?.getString(EXTRA_TRACK)
        if (json != null) {
            runCatching { BlinkJson.decodeFromString(Track.serializer(), json) }.getOrNull()?.let { return it }
        }
        return Track(
            id = item.mediaId,
            title = item.mediaMetadata.title?.toString().orEmpty(),
            artist = item.mediaMetadata.artist?.toString().orEmpty(),
        )
    }

    /** Из адреса достаём ровно столько, сколько надо для поиска звука. */
    fun trackFromUri(uri: Uri): Track =
        Track(
            id = uri.getQueryParameter("id").orEmpty(),
            title = uri.getQueryParameter("title").orEmpty(),
            artist = uri.getQueryParameter("artist").orEmpty(),
            source = uri.getQueryParameter("src")?.takeIf { it.isNotEmpty() },
            lic = uri.getQueryParameter("lic")?.takeIf { it.isNotEmpty() },
            stream = uri.getQueryParameter("stream")?.takeIf { it.isNotEmpty() },
        )
}
