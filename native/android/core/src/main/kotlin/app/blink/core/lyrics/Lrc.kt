package app.blink.core.lyrics

data class LrcWord(val timeMs: Long, val text: String)

data class LrcLine(val timeMs: Long, val text: String, val words: List<LrcWord>? = null)

/** Разбор LRC: те же правила, что у `parseLrc` на сайте (метки `[mm:ss.xx]`, у строки может быть несколько меток). */
object Lrc {
    private val TAG = Regex("""\[(\d+):(\d+(?:\.\d+)?)]""")
    private val WORD = Regex("""<(\d+):(\d+(?:\.\d+)?)>([^<]*)""")
    private val HAS_WORDS = Regex("""<\d+:\d+(?:\.\d+)?>""")

    fun parse(text: String): List<LrcLine> {
        val out = ArrayList<LrcLine>()
        for (raw in text.split('\n')) {
            val line = raw.trimEnd('\r')
            val tags = TAG.findAll(line).toList()
            if (tags.isEmpty()) continue
            var body = TAG.replace(line, "").trim()
            var words: List<LrcWord>? = null
            if (HAS_WORDS.containsMatchIn(body)) {
                val list = ArrayList<LrcWord>()
                for (m in WORD.findAll(body)) {
                    val w = m.groupValues[3]
                    if (w.isNotEmpty()) list.add(LrcWord(ms(m.groupValues[1], m.groupValues[2]), w))
                }
                words = list
                body = list.joinToString("") { it.text }.trim()
            }
            for (t in tags) out.add(LrcLine(ms(t.groupValues[1], t.groupValues[2]), body, words))
        }
        out.sortBy { it.timeMs }
        return out
    }

    /** Индекс строки, которая звучит в этот момент, или -1 до первой. */
    fun activeIndex(lines: List<LrcLine>, positionMs: Long): Int {
        var lo = 0
        var hi = lines.size - 1
        var ans = -1
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            if (lines[mid].timeMs <= positionMs) {
                ans = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return ans
    }

    private fun ms(min: String, sec: String): Long = (min.toLong() * 60_000L) + Math.round(sec.toDouble() * 1000.0)
}
