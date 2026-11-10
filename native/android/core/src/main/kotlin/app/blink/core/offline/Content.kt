package app.blink.core.offline

/**
 * Проверки файла из контракта: тип ответа, первые байты и итоговый размер.
 * Любой отказ здесь это BAD_CONTENT без автоповторов.
 */
object Content {
    const val MIN_BYTES_FLOOR = 16_384L
    const val BYTES_PER_SECOND_FLOOR = 2_000L
    const val MAX_BYTES = 400L * 1024 * 1024

    /** Сколько первых байт нужно, чтобы опознать любой из форматов (RIFF....WAVE = 12). */
    const val SNIFF_BYTES = 12

    /** Тип ответа: любой audio или application/octet-stream; всё остальное (text/html, json) это не файл. */
    fun typeOk(contentType: String?): Boolean {
        val t = contentType?.substringBefore(';')?.trim()?.lowercase() ?: return true
        if (t.isEmpty()) return true
        return t.startsWith("audio/") || t == "application/octet-stream" || t == "binary/octet-stream"
    }

    /** Первые байты должны быть похожи на звук. `head` содержит не меньше SNIFF_BYTES, если файл столько весит. */
    fun magicOk(head: ByteArray, len: Int = head.size): Boolean {
        if (len <= 0) return false
        val b0 = head[0].toInt() and 0xff
        if (b0 == '<'.code || b0 == '{'.code) return false
        // MP3: ID3-тег или кадр FF Ex / FF Fx
        if (len >= 3 && head[0] == 'I'.code.toByte() && head[1] == 'D'.code.toByte() && head[2] == '3'.code.toByte()) return true
        if (len >= 2 && b0 == 0xff && (head[1].toInt() and 0xe0) == 0xe0) return true
        // MP4/M4A: "ftyp" со смещения 4
        if (len >= 8 && head[4] == 'f'.code.toByte() && head[5] == 't'.code.toByte() && head[6] == 'y'.code.toByte() && head[7] == 'p'.code.toByte()) return true
        // Ogg, FLAC
        if (len >= 4 && head[0] == 'O'.code.toByte() && head[1] == 'g'.code.toByte() && head[2] == 'g'.code.toByte() && head[3] == 'S'.code.toByte()) return true
        if (len >= 4 && head[0] == 'f'.code.toByte() && head[1] == 'L'.code.toByte() && head[2] == 'a'.code.toByte() && head[3] == 'C'.code.toByte()) return true
        // WAV: RIFF....WAVE
        if (len >= 12 &&
            head[0] == 'R'.code.toByte() && head[1] == 'I'.code.toByte() && head[2] == 'F'.code.toByte() && head[3] == 'F'.code.toByte() &&
            head[8] == 'W'.code.toByte() && head[9] == 'A'.code.toByte() && head[10] == 'V'.code.toByte() && head[11] == 'E'.code.toByte()
        ) return true
        return false
    }

    /** Нижняя граница размера по длительности: меньше этого файл точно обрезан. */
    fun minBytes(durationSec: Int): Long = maxOf(MIN_BYTES_FLOOR, durationSec.toLong() * BYTES_PER_SECOND_FLOOR)

    /** Итоговая проверка перед commit. Бросает BAD_CONTENT с причиной. */
    fun verifyFinal(have: Long, total: Long?, resolvedBytes: Long?, durationSec: Int) {
        if (total == null || total <= 0) throw OfflineException(OfflineCode.BAD_CONTENT, "no_size")
        if (have != total) throw OfflineException(OfflineCode.BAD_CONTENT, "truncated")
        if (resolvedBytes != null && resolvedBytes != total) throw OfflineException(OfflineCode.BAD_CONTENT, "size_mismatch")
        if (have < minBytes(durationSec)) throw OfflineException(OfflineCode.BAD_CONTENT, "too_small")
        if (have > MAX_BYTES) throw OfflineException(OfflineCode.BAD_CONTENT, "too_big")
    }
}
