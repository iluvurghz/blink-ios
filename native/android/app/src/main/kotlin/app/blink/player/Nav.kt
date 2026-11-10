package app.blink.player

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class Tab { Search, Downloads, Account }

/** Куда смотрит приложение. Живёт в Graph, чтобы тосты и сервисы могли переключать экраны. */
class Nav {
    private val tabFlow = MutableStateFlow(Tab.Search)
    val tab: StateFlow<Tab> = tabFlow.asStateFlow()

    private val playerFlow = MutableStateFlow(false)
    val playerOpen: StateFlow<Boolean> = playerFlow.asStateFlow()

    fun go(tab: Tab) {
        tabFlow.value = tab
        playerFlow.value = false
    }

    fun openPlayer(open: Boolean) {
        playerFlow.value = open
    }
}
