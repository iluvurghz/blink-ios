package app.blink.player.data

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/** Короткое сообщение внизу экрана. Кнопка в нём нужна для «Войти», «Открыть Blink+», «Повторить». */
data class Toast(val message: String, val action: String? = null, val onAction: (() -> Unit)? = null)

/** Общая шина тостов: их шлют и экраны, и сервисы (плеер, загрузки). */
class Toasts {
    private val flow = MutableSharedFlow<Toast>(extraBufferCapacity = 8)
    val events: SharedFlow<Toast> = flow.asSharedFlow()

    fun show(message: String, action: String? = null, onAction: (() -> Unit)? = null) {
        flow.tryEmit(Toast(message, action, onAction))
    }
}
