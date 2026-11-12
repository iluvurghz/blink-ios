package app.blink.core.net

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Маленькое хранилище строк. На Android это SharedPreferences. */
interface KeyValue {
    fun get(key: String): String?
    fun put(key: String, value: String?)
}

/** Последнее, что известно про Blink+. Без сети живём по сохранённой дате. */
data class PlusInfo(val active: Boolean = false, val untilMs: Long? = null, val checkedAtMs: Long = 0) {
    /** Активна ли подписка прямо сейчас по последней известной дате. */
    fun activeAt(nowMs: Long): Boolean = active && (untilMs == null || untilMs > nowMs)

    /** Дата для `OfflinePolicy.canPlaySaved`: бессрочной подписке даём «бесконечность». */
    fun offlineUntilMs(): Long? = if (!active) null else untilMs ?: Long.MAX_VALUE
}

/**
 * Состояние Blink+ с кэшем на диске. `refresh` ходит на сервер; при сбое остаётся прежнее значение
 * (важно в самолёте: сохранённые треки должны играть по последней известной дате).
 */
class PlusTracker(
    private val fetch: suspend () -> PlusStatus?,
    private val store: KeyValue,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val flow = MutableStateFlow(load())
    val info: StateFlow<PlusInfo> = flow.asStateFlow()

    private fun load(): PlusInfo {
        val active = store.get(K_ACTIVE) == "1"
        val until = store.get(K_UNTIL)?.toLongOrNull()
        val checked = store.get(K_CHECKED)?.toLongOrNull() ?: 0
        return PlusInfo(active, until, checked)
    }

    /** Возвращает true, если сервер ответил (даже «подписки нет»). */
    suspend fun refresh(): Boolean {
        val status = try {
            fetch()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        } ?: return false
        val next = PlusInfo(status.active, status.untilMs, now())
        store.put(K_ACTIVE, if (next.active) "1" else "0")
        store.put(K_UNTIL, next.untilMs?.toString())
        store.put(K_CHECKED, next.checkedAtMs.toString())
        flow.value = next
        return true
    }

    /** При выходе из аккаунта: подписка принадлежит аккаунту. */
    fun clear() {
        store.put(K_ACTIVE, null)
        store.put(K_UNTIL, null)
        store.put(K_CHECKED, null)
        flow.value = PlusInfo()
    }

    private companion object {
        const val K_ACTIVE = "plus.active"
        const val K_UNTIL = "plus.until"
        const val K_CHECKED = "plus.checked"
    }
}
