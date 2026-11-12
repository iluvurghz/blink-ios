package app.blink.core.ui

import java.time.ZoneId
import kotlin.test.Test
import kotlin.test.assertEquals

class FormatTest {
    @Test
    fun `duration`() {
        assertEquals("0:00", Format.duration(0))
        assertEquals("0:00", Format.duration(-5))
        assertEquals("3:33", Format.duration(213))
        assertEquals("10:05", Format.duration(605))
        assertEquals("1:02:03", Format.duration(3723))
    }

    @Test
    fun `bytes in Russian`() {
        assertEquals("0 Б", Format.bytes(0))
        assertEquals("512 Б", Format.bytes(512))
        assertEquals("1 КБ", Format.bytes(1024))
        assertEquals("840 КБ", Format.bytes(840L * 1024))
        assertEquals("12,3 МБ", Format.bytes((12.3 * 1024 * 1024).toLong()))
        assertEquals("5,0 МБ", Format.bytes(5L * 1024 * 1024))
        assertEquals("120 МБ", Format.bytes(120L * 1024 * 1024))
        assertEquals("1,25 ГБ", Format.bytes((1.25 * 1024 * 1024 * 1024).toLong()))
        assertEquals("0 Б", Format.bytes(-3))
    }

    @Test
    fun `plural forms`() {
        val forms = listOf(0 to "треков", 1 to "трек", 2 to "трека", 4 to "трека", 5 to "треков", 11 to "треков", 12 to "треков", 14 to "треков", 21 to "трек", 22 to "трека", 25 to "треков", 101 to "трек", 111 to "треков")
        for ((n, word) in forms) assertEquals(word, Format.plural(n, "трек", "трека", "треков"), "n=$n")
        assertEquals("3 трека", Format.tracks(3))
    }

    @Test
    fun `date in Russian`() {
        // 2026-12-12 12:00 UTC
        assertEquals("12 декабря 2026", Format.date(1_797_076_800_000L, ZoneId.of("UTC")))
        assertEquals("1 января 2027", Format.date(1_798_761_600_000L, ZoneId.of("UTC")))
    }
}
