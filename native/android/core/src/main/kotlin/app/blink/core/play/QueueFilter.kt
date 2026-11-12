package app.blink.core.play

import app.blink.core.model.Track

/** Очередь, которую можно проиграть без интернета. `skipped` это сколько треков выкинули ради тоста «Пропущено N». */
data class OfflineQueue(val tracks: List<Track>, val startIndex: Int, val skipped: Int)

object QueueFilter {
    /**
     * Без сети оставляем только сохранённые треки. Если выбранный трек не сохранён, стартуем с ближайшего
     * сохранённого после него (а если после нет, то с первого). Пустая очередь значит «играть нечего».
     */
    fun offline(tracks: List<Track>, startIndex: Int, isSaved: (Track) -> Boolean): OfflineQueue {
        val kept = ArrayList<Track>()
        var start = -1
        for ((i, t) in tracks.withIndex()) {
            if (!isSaved(t)) continue
            if (start < 0 && i >= startIndex) start = kept.size
            kept.add(t)
        }
        if (kept.isEmpty()) return OfflineQueue(emptyList(), 0, tracks.size)
        return OfflineQueue(kept, if (start < 0) 0 else start, tracks.size - kept.size)
    }

    /** «Пропущено 3 трека: нужен интернет». */
    fun skippedText(n: Int): String = "Пропущено ${app.blink.core.ui.Format.tracks(n)}: нужен интернет"
}
