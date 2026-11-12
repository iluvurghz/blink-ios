package app.blink.core.offline

/** Текст итога пакета: «Сохранено 3 из 5. 2 не вышло: …» (контракт v1). Подробности по каждому треку видны во вкладке «Скачанное». */
object BatchSummary {
    fun text(e: OfflineEvent.BatchDone): String {
        if (e.failures.isEmpty()) return if (e.total <= 1) "Сохранено" else "Сохранено ${e.ok} из ${e.total}"
        if (e.total <= 1) {
            val f = e.failures[0]
            return "${f.title}: ${f.text.message}"
        }
        val shown = e.failures.take(2).joinToString("; ") { "${it.title}: ${it.text.message}" }
        val more = if (e.failures.size > 2) " и ещё ${e.failures.size - 2}" else ""
        return "Сохранено ${e.ok} из ${e.total}. ${e.failures.size} не вышло: $shown$more"
    }
}
