package app.blink.core.search

import app.blink.core.model.Track
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class SearchState(
    val loading: Boolean = false,
    /** Результаты относятся к введённому запросу (а не к пустой строке). */
    val searched: Boolean = false,
    val results: List<Track> = emptyList(),
    /** Поиск не дошёл до сервера (сеть, сервер). Пустой результат без ошибки это «ничего не нашли». */
    val error: Boolean = false,
    val newest: List<Track> = emptyList(),
    val chart: List<Track> = emptyList(),
    val homeLoading: Boolean = false,
    val homeError: Boolean = false,
)

/**
 * Поиск с задержкой 350 мс и «побеждает последний запрос» плюс стартовая страница (новое в Blink и чарт).
 * Сеть приходит снаружи функциями, поэтому модель одинаково проверяется тестами без Android.
 */
class SearchModel(
    private val scope: CoroutineScope,
    private val search: suspend (String) -> List<Track>,
    private val newest: suspend () -> List<Track>,
    private val chart: suspend () -> List<Track>,
    private val debounceMs: Long = 350,
) {
    private data class Query(val text: String, val nonce: Int)

    private val query = MutableStateFlow(Query("", 0))
    private val mutable = MutableStateFlow(SearchState())
    val state: StateFlow<SearchState> = mutable.asStateFlow()

    init {
        scope.launch {
            query.collectLatest { q ->
                val text = q.text.trim()
                if (text.isEmpty()) {
                    mutable.update { it.copy(loading = false, searched = false, results = emptyList(), error = false) }
                    return@collectLatest
                }
                mutable.update { it.copy(loading = true, error = false) }
                if (q.nonce == 0) delay(debounceMs)
                try {
                    val found = search(text)
                    mutable.update { it.copy(loading = false, searched = true, results = found, error = false) }
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    mutable.update { it.copy(loading = false, searched = true, results = emptyList(), error = true) }
                }
            }
        }
    }

    fun setQuery(text: String) {
        query.update { Query(text, 0) }
    }

    /** «Повторить» после ошибки: тот же запрос, без задержки. */
    fun retry() {
        query.update { Query(it.text, it.nonce + 1) }
    }

    /** Новое в Blink и чарт. Каждая часть живёт сама: упал чарт, новое всё равно покажется. */
    fun refreshHome() {
        scope.launch {
            mutable.update { it.copy(homeLoading = true, homeError = false) }
            val (fresh, top) = coroutineScope {
                val a = async { runCatching { newest() } }
                val b = async { runCatching { chart() } }
                a.await() to b.await()
            }
            mutable.update {
                it.copy(
                    homeLoading = false,
                    newest = fresh.getOrNull() ?: it.newest,
                    chart = top.getOrNull() ?: it.chart,
                    homeError = fresh.isFailure && top.isFailure && it.newest.isEmpty() && it.chart.isEmpty(),
                )
            }
        }
    }
}
