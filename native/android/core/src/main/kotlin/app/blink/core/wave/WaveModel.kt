package app.blink.core.wave

import app.blink.core.model.Track

/** Режимы «Вспышки» (как на сайте). */
enum class WaveMode(val id: String, val title: String) {
    MIX("mix", "Микс"),
    KNOWN("known", "Знакомое"),
    DISCOVER("discover", "Открытия"),
    FRESH("fresh", "Новое"),
    ;

    companion object {
        fun of(id: String?): WaveMode = entries.firstOrNull { it.id == id } ?: MIX
    }
}

data class WaveSettings(val mode: WaveMode = WaveMode.MIX, val explore: Boolean = true)

/** Трек-кандидат из подборки сервера: откуда взялся, по какому сиду и у скольких сидов всплыл. */
data class WaveCandidate(val track: Track, val src: String?, val seed: String?, val hits: Int)

data class PoolResult(val tracks: List<WaveCandidate>, val seedGenre: List<SeedGenre>)

data class SeedGenre(val query: String, val genre: String, val id: String?)

data class SimilarResult(val ids: List<String>, val genre: String)

/** Откуда Вспышка берёт кандидатов: сервер Blink (Яндекс.Музыка, чарты). Сеть спрятана за интерфейс, чтобы ядро проверялось тестами. */
interface WaveSource {
    suspend fun pool(seeds: List<String>): PoolResult

    suspend fun genres(items: List<String>): Map<String, String>

    suspend fun similarIds(seed: String): SimilarResult

    /** Чарт «Россия» (id `cr…`). */
    suspend fun topChart(): List<Track>

    /** Недельный и месячный чарты новинок: `weekly` или `monthly` (id `cp…`). */
    suspend fun periodChart(kind: String): List<Track>
}

/** Лайки (новые первыми) и недавно сыгранное (новые первыми, до 60): из них строится вкус. */
interface Library {
    val likes: List<Track>
    val recent: List<Track>
}

/** Места в памяти приложения, где лежит JSON. На Android это приватные SharedPreferences. */
interface BlobStore {
    fun load(): String?

    fun save(value: String?)
}
