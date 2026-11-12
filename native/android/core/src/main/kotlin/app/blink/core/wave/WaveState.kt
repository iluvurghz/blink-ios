package app.blink.core.wave

import app.blink.core.model.Track
import app.blink.core.net.BlinkJson
import kotlinx.serialization.Serializable

@Serializable
data class SeenEntry(val at: Long, val artist: String)

@Serializable
data class ListenEntry(val score: Double, val at: Long)

@Serializable
data class GenreNeg(val pen: Double, val at: Long)

/** Всё, что Вспышка помнит о слушателе на этом устройстве (на сайте это ключи `blink-wave-*` и `waveBan`). */
@Serializable
data class WaveData(
    /** Что уже показано: id → когда и чей артист. */
    val seen: Map<String, SeenEntry> = emptyMap(),
    /** Дослушивания по артистам (затухают с полураспадом 45 дней). */
    val listen: Map<String, ListenEntry> = emptyMap(),
    /** Жанры треков; «-» значит «жанра нет». */
    val genres: Map<String, String> = emptyMap(),
    /** «Не моё»: id треков, похожих на дизлайкнутые, и штрафы жанров (30 дней). */
    val negIds: Map<String, Long> = emptyMap(),
    val negGenres: Map<String, GenreNeg> = emptyMap(),
    val banIds: List<String> = emptyList(),
    val banArtists: Map<String, Int> = emptyMap(),
    val skips: List<String> = emptyList(),
    val skipArtists: Map<String, Int> = emptyMap(),
    /** Запас кандидатов для быстрого старта. */
    val spare: List<Track> = emptyList(),
)

/** Хранит [WaveData] и пишет её на диск после каждого изменения. */
class WaveStore(private val blob: BlobStore) {
    @Volatile
    var data: WaveData = load()
        private set

    private fun load(): WaveData {
        val text = blob.load() ?: return WaveData()
        return try {
            BlinkJson.decodeFromString(WaveData.serializer(), text)
        } catch (_: Exception) {
            WaveData()
        }
    }

    @Synchronized
    fun update(change: (WaveData) -> WaveData) {
        data = change(data)
        blob.save(BlinkJson.encodeToString(WaveData.serializer(), data))
    }
}
