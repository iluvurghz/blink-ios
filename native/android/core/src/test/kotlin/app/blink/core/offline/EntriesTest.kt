package app.blink.core.offline

import app.blink.core.model.Track
import app.blink.core.net.BlinkJson
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals

class EntriesTest {
    private fun entry(track: JsonObject?) =
        ManifestEntry(key = "blink:u1", source = "blink", id = "u1", title = "Rain", artist = "Ayo", album = "LP", cover = "https://c/1.jpg", duration = 200, bytes = 10, savedAt = 1, track = track)

    @Test
    fun `full copy wins`() {
        val original = Track(id = "b:u1", title = "Rain", artist = "Ayo", lyrics = "la la", source = "blink", lic = "u1", offline = true, explicit = true)
        val json = BlinkJson.encodeToJsonElement(Track.serializer(), original) as JsonObject
        assertEquals(original, entry(json).toTrack())
    }

    @Test
    fun `rebuilds from entry fields when the copy is missing or broken`() {
        val expected = Track(id = "b:u1", title = "Rain", artist = "Ayo", album = "LP", artwork = "https://c/1.jpg", duration = 200, source = "blink", lic = "u1", offline = true)
        assertEquals(expected, entry(null).toTrack())
        assertEquals(expected, entry(JsonObject(mapOf("id" to JsonPrimitive(5)))).toTrack())
    }
}
