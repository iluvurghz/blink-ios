package app.blink.core.offline

import kotlin.test.Test
import kotlin.test.assertEquals

class BatchSummaryTest {
    private fun fail(title: String, code: OfflineCode, reason: String? = null) = Failure("blink:$title", title, code, reason)

    @Test
    fun `all saved`() {
        assertEquals("Сохранено", BatchSummary.text(OfflineEvent.BatchDone(1, 1, emptyList())))
        assertEquals("Сохранено 5 из 5", BatchSummary.text(OfflineEvent.BatchDone(5, 5, emptyList())))
    }

    @Test
    fun `single failure names the track and the reason`() {
        val e = OfflineEvent.BatchDone(0, 1, listOf(fail("Rain", OfflineCode.NOT_DOWNLOADABLE)))
        assertEquals("Rain: Для этого трека нет файла", BatchSummary.text(e))
    }

    @Test
    fun `mixed batch lists the first reasons`() {
        val e = OfflineEvent.BatchDone(3, 5, listOf(fail("A", OfflineCode.TIMEOUT), fail("B", OfflineCode.NOT_ALLOWED, "plus")))
        assertEquals(
            "Сохранено 3 из 5. 2 не вышло: A: Сервер долго не отвечает; B: Сохранение для офлайна доступно с Blink+",
            BatchSummary.text(e),
        )
    }

    @Test
    fun `long failure lists are cut`() {
        val fails = (1..4).map { fail("T$it", OfflineCode.BAD_CONTENT) }
        val text = BatchSummary.text(OfflineEvent.BatchDone(1, 5, fails))
        assertEquals("Сохранено 1 из 5. 4 не вышло: T1: Файл пришёл повреждённым; T2: Файл пришёл повреждённым и ещё 2", text)
    }
}
