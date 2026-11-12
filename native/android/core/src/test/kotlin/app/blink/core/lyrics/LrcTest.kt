package app.blink.core.lyrics

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class LrcTest {
    @Test
    fun `parses tags, several stamps per line and sorts by time`() {
        val lines = Lrc.parse(
            """
            [ar:Artist]
            [ti:Title]
            [00:12.50]Second
            [00:01.00]First
            [00:30.00][01:00.25]Chorus
            no stamp here
            """.trimIndent(),
        )
        assertEquals(listOf("First", "Second", "Chorus", "Chorus"), lines.map { it.text })
        assertEquals(listOf(1_000L, 12_500L, 30_000L, 60_250L), lines.map { it.timeMs })
    }

    @Test
    fun `handles windows line endings and bare minutes`() {
        val lines = Lrc.parse("[00:05]a\r\n[01:05.5]b\r\n")
        assertEquals(listOf(5_000L, 65_500L), lines.map { it.timeMs })
        assertEquals(listOf("a", "b"), lines.map { it.text })
    }

    @Test
    fun `enhanced word timings`() {
        val line = Lrc.parse("[00:10.00]<00:10.00>Hel<00:10.40>lo <00:11.00>world").single()
        assertEquals("Hello world", line.text)
        val words = assertNotNull(line.words)
        assertEquals(listOf(10_000L, 10_400L, 11_000L), words.map { it.timeMs })
        assertEquals(listOf("Hel", "lo ", "world"), words.map { it.text })
    }

    @Test
    fun `active line by position`() {
        val lines = Lrc.parse("[00:05.00]a\n[00:10.00]b\n[00:20.00]c")
        assertEquals(-1, Lrc.activeIndex(lines, 0))
        assertEquals(0, Lrc.activeIndex(lines, 5_000))
        assertEquals(0, Lrc.activeIndex(lines, 9_999))
        assertEquals(1, Lrc.activeIndex(lines, 10_000))
        assertEquals(2, Lrc.activeIndex(lines, 3_600_000))
        assertEquals(-1, Lrc.activeIndex(emptyList(), 1000))
        assertNull(Lrc.parse("just text").firstOrNull())
    }
}
