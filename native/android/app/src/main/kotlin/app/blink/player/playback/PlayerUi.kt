package app.blink.player.playback

import app.blink.core.model.Track

/** Что видит экран: текущий трек, состояние и позиция. Всё остальное знает сервис. */
data class PlayerUi(
    val track: Track? = null,
    val playing: Boolean = false,
    val buffering: Boolean = false,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val hasNext: Boolean = false,
    val hasPrevious: Boolean = false,
    val connected: Boolean = false,
    /** Сколько треков осталось в очереди после текущего. */
    val queueLeft: Int = 0,
    /** Номер текущего трека в очереди. */
    val index: Int = 0,
)
