package app.blink.core.offline

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** Есть ли сеть. На Android это ConnectivityManager, на iOS NWPathMonitor, в тестах переключатель. */
interface NetworkMonitor {
    val online: StateFlow<Boolean>
}

class StaticNetwork(initial: Boolean = true) : NetworkMonitor {
    private val flow = MutableStateFlow(initial)
    override val online: StateFlow<Boolean> get() = flow
    fun set(value: Boolean) {
        flow.value = value
    }
}
