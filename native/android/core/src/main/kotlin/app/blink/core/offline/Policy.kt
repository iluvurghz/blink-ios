package app.blink.core.offline

import app.blink.core.model.Track
import app.blink.core.net.BlinkJson
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.encodeToJsonElement

/**
 * Что можно сохранять: только лицензионный каталог Blink (`source=blink`, `offline_allowed=true`) и только с Blink+.
 * Остальные источники играют только онлайн. Список один и тот же с серверным OFFLINE_SOURCES.
 */
object OfflinePolicy {
    val allowedSources: Set<String> = setOf(Track.SOURCE_BLINK)

    sealed interface Decision {
        data object Allowed : Decision
        data class Denied(val code: OfflineCode, val reason: String?) : Decision {
            val text: OfflineText get() = OfflineTexts.of(code, reason)
        }
    }

    fun check(track: Track, signedIn: Boolean, plusActive: Boolean): Decision {
        val source = track.source ?: ""
        if (source !in allowedSources || track.lic.isNullOrEmpty()) return Decision.Denied(OfflineCode.NOT_ALLOWED, "source")
        if (track.offline == false) return Decision.Denied(OfflineCode.NOT_ALLOWED, "artist")
        if (!signedIn) return Decision.Denied(OfflineCode.NOT_ALLOWED, "auth")
        if (!plusActive) return Decision.Denied(OfflineCode.NOT_ALLOWED, "plus")
        return Decision.Allowed
    }

    /** Можно ли показывать кнопку «Сохранить» в принципе (без учёта входа и подписки). */
    fun savable(track: Track): Boolean =
        (track.source ?: "") in allowedSources && !track.lic.isNullOrEmpty() && track.offline != false

    /** Сохранённое играет с диска всегда первым; без сети нужна активная подписка по последней известной дате. */
    fun canPlaySaved(online: Boolean, plusUntilMs: Long?, nowMs: Long): Boolean =
        online || (plusUntilMs != null && plusUntilMs > nowMs)

    fun keyOf(track: Track): String? =
        if (savable(track)) Key.of(Track.SOURCE_BLINK, track.lic!!) else null

    fun candidate(track: Track): Candidate? {
        val lic = track.lic?.takeIf { savable(track) } ?: return null
        val json = BlinkJson.encodeToJsonElement(Track.serializer(), track) as JsonObject
        return Candidate(
            key = Key.of(Track.SOURCE_BLINK, lic),
            source = Track.SOURCE_BLINK,
            id = lic,
            meta = JobMeta(
                title = track.title,
                artist = track.artist,
                album = track.album,
                cover = track.artwork,
                duration = track.duration,
                offlineAllowed = track.offline != false,
                track = json,
            ),
        )
    }
}

/** Что ставим в очередь: ключ, источник и описание трека. */
data class Candidate(val key: String, val source: String, val id: String, val meta: JobMeta)
