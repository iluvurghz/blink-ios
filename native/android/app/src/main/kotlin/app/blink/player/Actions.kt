package app.blink.player

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import app.blink.core.model.Track
import app.blink.core.offline.EnqueueResult
import app.blink.core.offline.ManifestEntry
import app.blink.core.offline.OfflineCode
import app.blink.core.offline.OfflinePolicy
import app.blink.core.offline.OfflineText
import app.blink.core.offline.OfflineTexts
import app.blink.core.offline.toTrack
import app.blink.core.play.QueueFilter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Что происходит по нажатиям: сохранить, играть, объяснить отказ. Правила сохранения берутся из ядра
 * (OfflinePolicy), здесь только склейка с экраном: тосты, переходы, очередь плеера.
 */
class Actions(private val g: Graph) {
    private fun now(): Long = System.currentTimeMillis()

    private fun decide(track: Track): OfflinePolicy.Decision =
        OfflinePolicy.check(track, signedIn = g.auth.session.value != null, plusActive = g.plus.info.value.activeAt(now()))

    // ---------- сохранить ----------

    fun save(track: Track) {
        g.scope.launch { saveNow(listOf(track)) }
    }

    fun saveAll(tracks: List<Track>) {
        g.scope.launch { saveNow(tracks) }
    }

    private suspend fun saveNow(tracks: List<Track>) {
        var verdicts = tracks.map { it to decide(it) }
        // Подписку могли оформить на сайте: перед отказом «нужен Blink+» спрашиваем сервер ещё раз.
        if (verdicts.any { (it.second as? OfflinePolicy.Decision.Denied)?.reason == "plus" }) {
            g.plus.refresh()
            verdicts = tracks.map { it to decide(it) }
        }
        val allowed = verdicts.filter { it.second is OfflinePolicy.Decision.Allowed }.map { it.first }
        if (allowed.isEmpty()) {
            val denials = verdicts.mapNotNull { it.second as? OfflinePolicy.Decision.Denied }
            // Для пакета важнее причина «войдите» или «нужен Blink+», чем «этот трек только онлайн».
            val best = denials.firstOrNull { it.reason == "auth" || it.reason == "plus" } ?: denials.firstOrNull() ?: return
            explain(best.code, best.reason, null)
            return
        }
        val candidates = allowed.mapNotNull { OfflinePolicy.candidate(it) }
        val results = withContext(Dispatchers.IO) { g.offline.enqueue(candidates) }
        if (candidates.size == 1) {
            val key = candidates[0].key
            when (val r = results[key]) {
                EnqueueResult.AlreadySaved -> g.toasts.show("Уже сохранён")
                is EnqueueResult.Remembered -> explain(r.code, r.reason, key)
                is EnqueueResult.Rejected -> explain(r.code, r.reason, key)
                else -> Unit
            }
        }
    }

    /** Человеческая причина отказа и кнопка, которая это чинит (войти, открыть Blink+, повторить). */
    fun explain(code: OfflineCode, reason: String?, key: String?) {
        val text = OfflineTexts.of(code, reason)
        val label = text.action?.label
        when (text.action) {
            OfflineText.Action.SIGN_IN -> g.toasts.show(text.message, label) { g.nav.go(Tab.Account) }
            OfflineText.Action.OPEN_PLUS -> g.toasts.show(text.message, label) { openPlus() }
            OfflineText.Action.FREE_SPACE -> g.toasts.show(text.message, label) { openStorageSettings() }
            OfflineText.Action.RETRY -> g.toasts.show(text.message, if (key != null) label else null) { if (key != null) retry(key) }
            null -> g.toasts.show(text.message)
        }
    }

    /** Нажали на значок «играет только онлайн». */
    fun explainOnlineOnly(track: Track) {
        val reason = if (track.offline == false && !track.lic.isNullOrEmpty()) "artist" else "source"
        explain(OfflineCode.NOT_ALLOWED, reason, null)
    }

    fun removeSaved(key: String) {
        g.scope.launch(Dispatchers.IO) { g.offline.remove(key) }
    }

    fun retry(key: String) {
        g.scope.launch(Dispatchers.IO) { g.offline.retry(key) }
    }

    fun cancel(key: String) {
        g.scope.launch(Dispatchers.IO) { g.offline.cancel(key) }
    }

    // ---------- играть ----------

    fun play(tracks: List<Track>, index: Int) {
        if (tracks.isEmpty()) return
        val start = index.coerceIn(0, tracks.lastIndex)
        if (g.network.online.value) {
            g.player.play(tracks, start)
            return
        }
        // Без сети играют только сохранённые, и только с активным Blink+ (по последней известной дате).
        if (!OfflinePolicy.canPlaySaved(false, g.plus.info.value.offlineUntilMs(), now())) {
            g.toasts.show("Без интернета сохранённые играют с Blink+", "Открыть Blink+") { openPlus() }
            return
        }
        val queue = QueueFilter.offline(tracks, start) { t -> OfflinePolicy.keyOf(t)?.let { g.offline.isSaved(it) } == true }
        if (queue.tracks.isEmpty()) {
            g.toasts.show("Нет интернета. Без него играют только сохранённые треки")
            return
        }
        if (queue.skipped > 0) g.toasts.show(QueueFilter.skippedText(queue.skipped))
        g.player.play(queue.tracks, queue.startIndex)
    }

    fun playSaved(entries: List<ManifestEntry>, index: Int) = play(entries.map { it.toTrack() }, index)

    // ---------- прочее ----------

    fun openStorageSettings() {
        val intent = Intent(Settings.ACTION_INTERNAL_STORAGE_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            g.app.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            g.toasts.show("Освободите место в настройках телефона и нажмите «Повторить»")
        }
    }

    /** Оформление подписки пока на сайте: в M1 появится встроенный экран. */
    fun openPlus() {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(g.config.base)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            g.app.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            g.toasts.show("Откройте blinkmusic.cc в браузере: раздел Blink+")
        }
    }
}
