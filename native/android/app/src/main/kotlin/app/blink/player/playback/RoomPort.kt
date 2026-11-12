package app.blink.player.playback

import app.blink.core.model.Track
import app.blink.core.social.LocalPlayback
import app.blink.core.social.RoomPlayerPort

/** Рука комнаты на плеере устройства. */
class RoomPort(private val player: PlayerController) : RoomPlayerPort {
    override fun local(): LocalPlayback {
        val s = player.state.value
        return LocalPlayback(s.track, s.playing, s.positionMs, loading = s.buffering)
    }

    override fun playQueue(queue: List<Track>, index: Int, positionMs: Long, playing: Boolean) = player.playFrom(queue, index, positionMs, playing)

    override fun setPlaying(playing: Boolean, positionMs: Long) = player.setPlaying(playing, positionMs)

    override fun seekTo(positionMs: Long) = player.seekTo(positionMs)

    override fun appendToQueue(tracks: List<Track>) = player.append(tracks)

    override fun queue(): Pair<List<Track>, Int> = player.queue()
}
