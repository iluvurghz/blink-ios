package app.blink.player

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class Tab { Flash, Search, Downloads, Account }

/** Экраны поверх вкладок: комната, друзья, Blink+. */
enum class Overlay { None, Room, Friends, Plus }

/** Куда смотрит приложение. Живёт в Graph, чтобы тосты и сервисы могли переключать экраны. */
class Nav {
    private val tabFlow = MutableStateFlow(Tab.Flash)
    val tab: StateFlow<Tab> = tabFlow.asStateFlow()

    private val playerFlow = MutableStateFlow(false)
    val playerOpen: StateFlow<Boolean> = playerFlow.asStateFlow()

    private val overlayFlow = MutableStateFlow(Overlay.None)
    val overlay: StateFlow<Overlay> = overlayFlow.asStateFlow()

    fun open(o: Overlay) {
        overlayFlow.value = o
        playerFlow.value = false
    }

    fun close() {
        overlayFlow.value = Overlay.None
    }

    fun go(tab: Tab) {
        tabFlow.value = tab
        playerFlow.value = false
        overlayFlow.value = Overlay.None
    }

    fun openPlayer(open: Boolean) {
        playerFlow.value = open
    }
}
