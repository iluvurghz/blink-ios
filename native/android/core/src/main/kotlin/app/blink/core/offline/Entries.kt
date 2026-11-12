package app.blink.core.offline

import app.blink.core.model.Track
import app.blink.core.net.BlinkJson

/** Сохранённый трек обратно в объект трека приложения: берём полную копию из манифеста, а если её нет, собираем из полей записи. */
fun ManifestEntry.toTrack(): Track {
    val copy = track?.let { runCatching { BlinkJson.decodeFromJsonElement(Track.serializer(), it) }.getOrNull() }
    return copy ?: Track(
        id = "b:$id",
        title = title,
        artist = artist,
        album = album,
        artwork = cover,
        duration = duration,
        source = Track.SOURCE_BLINK,
        lic = id,
        offline = true,
    )
}
