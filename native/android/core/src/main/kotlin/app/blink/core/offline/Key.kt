package app.blink.core.offline

/**
 * Ключ сохранённого трека: `<source>:<sourceId>`, для лицензионных `blink:<uuid lic_tracks>`.
 * Имя файла на диске: hex от UTF-8 ключа (безопасно для любой файловой системы и одинаково на всех платформах).
 */
object Key {
    fun of(source: String, id: String): String = "$source:$id"

    fun fkey(key: String): String {
        val sb = StringBuilder(key.length * 2)
        for (b in key.toByteArray(Charsets.UTF_8)) {
            val v = b.toInt() and 0xff
            sb.append(HEX[v ushr 4]).append(HEX[v and 15])
        }
        return sb.toString()
    }

    fun fromFkey(fkey: String): String? {
        if (fkey.isEmpty() || fkey.length % 2 != 0) return null
        val out = ByteArray(fkey.length / 2)
        for (i in out.indices) {
            val hi = Character.digit(fkey[i * 2], 16)
            val lo = Character.digit(fkey[i * 2 + 1], 16)
            if (hi < 0 || lo < 0) return null
            out[i] = ((hi shl 4) or lo).toByte()
        }
        return String(out, Charsets.UTF_8)
    }

    private val HEX = "0123456789abcdef".toCharArray()
}
