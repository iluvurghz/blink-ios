package app.blink.core.net

import java.io.IOException
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PlusTrackerTest {
    private class Mem : KeyValue {
        val map = HashMap<String, String>()
        override fun get(key: String) = map[key]
        override fun put(key: String, value: String?) {
            if (value == null) map.remove(key) else map[key] = value
        }
    }

    @Test
    fun `refresh stores the answer and survives a restart`() = runTest {
        val mem = Mem()
        val t1 = PlusTracker({ PlusStatus(true, 5_000L) }, mem, now = { 1_000L })
        assertFalse(t1.info.value.active)
        assertTrue(t1.refresh())
        assertTrue(t1.info.value.activeAt(4_999L))
        assertFalse(t1.info.value.activeAt(5_000L))
        // «перезапуск» без сети: берём последнюю известную дату
        val t2 = PlusTracker({ throw IOException("offline") }, mem, now = { 2_000L })
        assertEquals(5_000L, t2.info.value.untilMs)
        assertEquals(5_000L, t2.info.value.offlineUntilMs())
        assertFalse(t2.refresh())
        assertEquals(5_000L, t2.info.value.untilMs)
    }

    @Test
    fun `a failed or empty answer keeps the previous value, a no-subscription answer replaces it`() = runTest {
        val mem = Mem()
        var next: PlusStatus? = PlusStatus(true, 9_000L)
        val t = PlusTracker({ next }, mem, now = { 1L })
        t.refresh()
        next = null
        assertFalse(t.refresh())
        assertTrue(t.info.value.active)
        next = PlusStatus(false, null)
        assertTrue(t.refresh())
        assertFalse(t.info.value.active)
        assertNull(t.info.value.offlineUntilMs())
    }

    @Test
    fun `lifetime plus has no end date and never expires offline`() {
        val info = PlusInfo(active = true, untilMs = null)
        assertTrue(info.activeAt(Long.MAX_VALUE - 1))
        assertEquals(Long.MAX_VALUE, info.offlineUntilMs())
    }

    @Test
    fun `clear forgets everything`() = runTest {
        val mem = Mem()
        val t = PlusTracker({ PlusStatus(true, 9_000L) }, mem, now = { 1L })
        t.refresh()
        t.clear()
        assertFalse(t.info.value.active)
        assertTrue(mem.map.isEmpty())
    }
}
