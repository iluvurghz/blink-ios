package app.blink.core.offline

import app.blink.core.model.Track
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

class SaveUiTest {
    private val track = Track(id = "b:u1", title = "T", artist = "A", source = "blink", lic = "u1", offline = true)

    private fun job(stage: Stage, have: Long = 0, total: Long? = null, code: OfflineCode? = null, reason: String? = null) =
        JobView("blink:u1", "T", "A", "", stage, have, total, 0, code, reason, null)

    private fun state(vararg jobs: JobView, saved: List<ManifestEntry> = emptyList()) = OfflineState(ready = true, jobs = jobs.toList(), saved = saved)

    @Test
    fun `not savable tracks are online only with the right reason`() {
        assertEquals(SaveUi.OnlineOnly("source"), SaveUi.of(track.copy(source = "soundcloud", lic = null, id = "sc1"), state()))
        assertEquals(SaveUi.OnlineOnly("source"), SaveUi.of(track.copy(source = null, lic = null, id = "123"), state()))
        assertEquals(SaveUi.OnlineOnly("artist"), SaveUi.of(track.copy(offline = false), state()))
    }

    @Test
    fun `available then queued then progress then saved`() {
        assertEquals(SaveUi.Available, SaveUi.of(track, state()))
        assertEquals(SaveUi.Queued, SaveUi.of(track, state(job(Stage.QUEUED))))
        assertEquals(SaveUi.Progress(0f, true), SaveUi.of(track, state(job(Stage.RESOLVING))))
        assertEquals(SaveUi.Progress(0.25f, false), SaveUi.of(track, state(job(Stage.DOWNLOADING, 250, 1000))))
        assertEquals(SaveUi.Progress(0f, true), SaveUi.of(track, state(job(Stage.DOWNLOADING, 250, null))))
        assertEquals(SaveUi.Progress(1f, false), SaveUi.of(track, state(job(Stage.VERIFYING, 1000, 1000))))
        val entry = ManifestEntry(key = "blink:u1", source = "blink", id = "u1", title = "T", artist = "A", bytes = 10, savedAt = 1)
        assertEquals(SaveUi.Saved, SaveUi.of(track, state(saved = listOf(entry))))
    }

    @Test
    fun `failed carries the human text`() {
        val ui = assertIs<SaveUi.Failed>(SaveUi.of(track, state(job(Stage.FAILED, code = OfflineCode.NOT_ALLOWED, reason = "plus"))))
        assertEquals("Сохранение для офлайна доступно с Blink+", ui.text.message)
        assertEquals(OfflineText.Action.OPEN_PLUS, ui.text.action)
        val timeout = assertIs<SaveUi.Failed>(SaveUi.of(track, state(job(Stage.FAILED, code = OfflineCode.TIMEOUT))))
        assertTrue(timeout.text.message.isNotEmpty())
    }
}
