package app.blink.core.offline

import app.blink.core.model.Track

/** Что рисуем на кнопке «Сохранить» у трека. Считается из состояния менеджера, UI только показывает. */
sealed interface SaveUi {
    /** Трек нельзя сохранять (не из каталога Blink или артист не разрешил): играет только онлайн. */
    data class OnlineOnly(val reason: String) : SaveUi

    data object Available : SaveUi
    data object Queued : SaveUi

    /** `fraction` от 0 до 1; `indeterminate` пока неизвестен размер. */
    data class Progress(val fraction: Float, val indeterminate: Boolean) : SaveUi
    data object Saved : SaveUi
    data class Failed(val text: OfflineText) : SaveUi

    companion object {
        fun of(track: Track, state: OfflineState): SaveUi {
            if (!OfflinePolicy.savable(track)) {
                val allowedSource = (track.source ?: "") in OfflinePolicy.allowedSources && !track.lic.isNullOrEmpty()
                return OnlineOnly(if (allowedSource && track.offline == false) "artist" else "source")
            }
            val key = OfflinePolicy.keyOf(track) ?: return OnlineOnly("source")
            if (key in state.savedKeys) return Saved
            val job = state.job(key) ?: return Available
            return when (job.stage) {
                Stage.QUEUED -> Queued
                Stage.RESOLVING -> Progress(0f, true)
                Stage.DOWNLOADING -> Progress(job.fraction, job.total == null)
                Stage.VERIFYING, Stage.COMMITTING -> Progress(1f, false)
                Stage.FAILED -> Failed(job.text ?: OfflineTexts.of(OfflineCode.SOURCE_ERROR))
            }
        }
    }
}
