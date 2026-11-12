package app.blink.player

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class Tab { Flash, Search, Downloads, Account }

/** Экраны поверх вкладок: комната, друзья, Blink+. */
enum class Overlay { None, Room, Friends, Plus, Library }

/** Что открыто внутри экрана «Музыка»: список плейлистов, любимое, плейлист, чужой плейлист по ссылке, подборка редакции. */
sealed interface LibRoute {
    data object Home : LibRoute
    data object Likes : LibRoute
    data class Mine(val id: String) : LibRoute
    data class Shared(val code: String) : LibRoute
    data class Editorial(val id: String) : LibRoute
}

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

    private val libFlow = MutableStateFlow<LibRoute>(LibRoute.Home)
    val library: StateFlow<LibRoute> = libFlow.asStateFlow()

    fun openLibrary(route: LibRoute = LibRoute.Home) {
        libFlow.value = route
        open(Overlay.Library)
    }

    fun libraryTo(route: LibRoute) {
        libFlow.value = route
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
