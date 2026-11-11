package app.blink.core.model

import kotlinx.serialization.Serializable

/**
 * Трек в той же форме, что у сайта и ПК-версии. Лайки и плейлисты на сервере хранят такие объекты
 * целиком, поэтому `id` обязан совпадать: `String(trackId)` у iTunes/Яндекса, `b:<uuid>` у лицензионных,
 * `cr<id>` у подборок, `j:<id>` у Jamendo.
 */
@Serializable
data class Track(
    val id: String,
    val title: String,
    val artist: String,
    val artistId: String? = null,
    val album: String = "",
    val albumId: String? = null,
    val artwork: String = "",
    val duration: Int = 0,
    val explicit: Boolean = false,
    val year: String = "",
    val genre: String = "",
    /** Дата выхода (ISO), если сервер её отдаёт: нужна «Вспышке» для свежести. */
    val released: String? = null,
    val source: String? = null,
    val lic: String? = null,
    val lrc: String? = null,
    val lyrics: String? = null,
    /** Артист разрешил офлайн-копии. null у нелицензионных треков. */
    val offline: Boolean? = null,
    val stream: String? = null,
) {
    /** Трек из лицензионного каталога Blink (`lic_tracks`). */
    val isLicensed: Boolean get() = source == SOURCE_BLINK && !lic.isNullOrEmpty()

    companion object {
        const val SOURCE_BLINK = "blink"
    }
}
