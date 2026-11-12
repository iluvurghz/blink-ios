package app.blink.core.offline

import app.blink.core.model.Track
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PolicyTest {
    private val licensed = Track(id = "b:u1", title = "T", artist = "A", album = "LP", artwork = "https://x/c.jpg", duration = 200, source = "blink", lic = "u1", offline = true)

    private fun denied(t: Track, signedIn: Boolean = true, plus: Boolean = true) =
        assertIs<OfflinePolicy.Decision.Denied>(OfflinePolicy.check(t, signedIn, plus))

    @Test
    fun `only licensed catalog with artist consent, signed in, with plus`() {
        assertEquals(OfflinePolicy.Decision.Allowed, OfflinePolicy.check(licensed, signedIn = true, plusActive = true))
        denied(licensed.copy(source = null, lic = null, id = "123")).also { assertEquals("source", it.reason) }
        denied(licensed.copy(source = "soundcloud")).also { assertEquals("source", it.reason) }
        denied(licensed.copy(source = "jamendo", id = "j:1", lic = null)).also { assertEquals("source", it.reason) }
        denied(licensed.copy(source = "chart", id = "cr1")).also { assertEquals("source", it.reason) }
        denied(licensed.copy(lic = null)).also { assertEquals("source", it.reason) }
        denied(licensed.copy(offline = false)).also { assertEquals("artist", it.reason) }
        denied(licensed, signedIn = false).also { assertEquals("auth", it.reason) }
        denied(licensed, plus = false).also {
            assertEquals("plus", it.reason)
            assertEquals(OfflineText.Action.OPEN_PLUS, it.text.action)
        }
        assertEquals("Этот трек играет только онлайн", denied(licensed.copy(source = "vk")).text.message)
    }

    @Test
    fun `savable decides whether the save button exists at all`() {
        assertTrue(OfflinePolicy.savable(licensed))
        assertFalse(OfflinePolicy.savable(licensed.copy(offline = false)))
        assertFalse(OfflinePolicy.savable(licensed.copy(source = "chart", lic = null)))
        assertEquals("blink:u1", OfflinePolicy.keyOf(licensed))
        assertNull(OfflinePolicy.keyOf(licensed.copy(offline = false)))
    }

    @Test
    fun `saved copy plays online always and offline only while plus lasts`() {
        val now = 1_000L
        assertTrue(OfflinePolicy.canPlaySaved(online = true, plusUntilMs = null, nowMs = now))
        assertTrue(OfflinePolicy.canPlaySaved(online = false, plusUntilMs = now + 1, nowMs = now))
        assertFalse(OfflinePolicy.canPlaySaved(online = false, plusUntilMs = now, nowMs = now))
        assertFalse(OfflinePolicy.canPlaySaved(online = false, plusUntilMs = null, nowMs = now))
    }

    @Test
    fun `candidate carries a full copy of the track for the manifest`() {
        val c = assertNotNull(OfflinePolicy.candidate(licensed))
        assertEquals("blink:u1", c.key)
        assertEquals("u1", c.id)
        assertEquals("T", c.meta.title)
        assertEquals("https://x/c.jpg", c.meta.cover)
        assertEquals(200, c.meta.duration)
        val json = assertNotNull(c.meta.track)
        assertEquals("b:u1", (json["id"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertNull(OfflinePolicy.candidate(licensed.copy(offline = false)))
    }

    @Test
    fun `manifest entry round trips as schema 1`() {
        val e = ManifestEntry(key = "blink:u1", source = "blink", id = "u1", title = "T", artist = "A", bytes = 10, savedAt = 5, track = OfflinePolicy.candidate(licensed)!!.meta.track)
        val back = assertNotNull(ManifestEntry.decode(e.encode()))
        assertEquals(e, back)
        assertTrue(e.encode().contains("\"schema\":1") && e.encode().contains("\"status\":\"saved\""))
        assertNull(ManifestEntry.decode("""{"schema":2,"key":"k","source":"s","id":"i","title":"t","artist":"a","bytes":1,"savedAt":1}"""))
        assertNull(ManifestEntry.decode("not json"))
    }
}
