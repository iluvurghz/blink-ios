package app.blink.core.ui

import java.time.Instant
import java.time.ZoneId
import java.util.Locale

/** Подписи для экранов: одинаковые на всех платформах. Локаль не трогаем: цифры всегда обычные. */
object Format {
    /** 213 → «3:33», 3723 → «1:02:03». */
    fun duration(seconds: Int): String {
        val s = seconds.coerceAtLeast(0)
        val h = s / 3600
        val m = s % 3600 / 60
        val sec = s % 60
        return if (h > 0) String.format(Locale.ROOT, "%d:%02d:%02d", h, m, sec) else String.format(Locale.ROOT, "%d:%02d", m, sec)
    }

    /** Размер файлов по-русски: «512 Б», «840 КБ», «12,3 МБ», «1,25 ГБ». */
    fun bytes(n: Long): String {
        val v = n.coerceAtLeast(0)
        return when {
            v < 1024L -> "$v Б"
            v < 1024L * 1024 -> "${(v + 512) / 1024} КБ"
            v < 1024L * 1024 * 1024 -> {
                val mb = v / (1024.0 * 1024.0)
                if (mb >= 100) "${Math.round(mb)} МБ" else decimal(mb, 1) + " МБ"
            }
            else -> decimal(v / (1024.0 * 1024.0 * 1024.0), 2) + " ГБ"
        }
    }

    private fun decimal(x: Double, digits: Int): String = String.format(Locale.ROOT, "%.${digits}f", x).replace('.', ',')

    /** Русские формы числительных: 1 трек, 2 трека, 5 треков, 21 трек, 12 треков. */
    fun plural(n: Int, one: String, few: String, many: String): String {
        val a = Math.abs(n) % 100
        val b = a % 10
        return when {
            a in 11..14 -> many
            b == 1 -> one
            b in 2..4 -> few
            else -> many
        }
    }

    fun count(n: Int, one: String, few: String, many: String): String = "$n ${plural(n, one, few, many)}"

    fun tracks(n: Int): String = count(n, "трек", "трека", "треков")

    private val MONTHS = listOf(
        "января", "февраля", "марта", "апреля", "мая", "июня",
        "июля", "августа", "сентября", "октября", "ноября", "декабря",
    )

    /** «12 декабря 2026». */
    fun date(epochMs: Long, zone: ZoneId = ZoneId.systemDefault()): String {
        val d = Instant.ofEpochMilli(epochMs).atZone(zone).toLocalDate()
        return "${d.dayOfMonth} ${MONTHS[d.monthValue - 1]} ${d.year}"
    }
}
