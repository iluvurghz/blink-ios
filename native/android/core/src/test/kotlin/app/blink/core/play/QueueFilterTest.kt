package app.blink.core.play

import app.blink.core.model.Track
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class QueueFilterTest {
    private fun t(n: Int) = Track(id = "b:$n", title = "T$n", artist = "A", source = "blink", lic = "$n", offline = true)

    private val all = (0..5).map { t(it) }

    @Test
    fun `keeps saved only and moves the start`() {
        val saved = setOf("b:1", "b:3", "b:4")
        val q = QueueFilter.offline(all, 3) { it.id in saved }
        assertEquals(listOf("b:1", "b:3", "b:4"), q.tracks.map { it.id })
        assertEquals(1, q.startIndex)
        assertEquals(3, q.skipped)
    }

    @Test
    fun `unsaved start goes to the next saved one`() {
        val saved = setOf("b:1", "b:4")
        val q = QueueFilter.offline(all, 2) { it.id in saved }
        assertEquals("b:4", q.tracks[q.startIndex].id)
    }

    @Test
    fun `nothing after the start wraps to the first saved`() {
        val saved = setOf("b:0", "b:1")
        val q = QueueFilter.offline(all, 4) { it.id in saved }
        assertEquals(0, q.startIndex)
        assertEquals(4, q.skipped)
    }

    @Test
    fun `nothing saved means nothing to play`() {
        val q = QueueFilter.offline(all, 0) { false }
        assertTrue(q.tracks.isEmpty())
        assertEquals(6, q.skipped)
    }

    @Test
    fun `toast text`() {
        assertEquals("Пропущено 1 трек: нужен интернет", QueueFilter.skippedText(1))
        assertEquals("Пропущено 3 трека: нужен интернет", QueueFilter.skippedText(3))
        assertEquals("Пропущено 7 треков: нужен интернет", QueueFilter.skippedText(7))
    }
}
