package app.blink.core.offline

/** Коды ошибок офлайна. Одинаковые на всех платформах (контракт offline-cache v1). */
enum class OfflineCode {
    NO_NETWORK,
    NO_MATCH,
    NOT_DOWNLOADABLE,
    NOT_ALLOWED,
    SOURCE_ERROR,
    BAD_CONTENT,
    NO_SPACE,
    TIMEOUT,
    CANCELLED,
    ;

    /** Автоповтор имеет смысл только для сетевых сбоев. */
    val retryable: Boolean get() = this == TIMEOUT || this == SOURCE_ERROR

    /** Отказы по сути трека: запоминаем на 24 часа и не дёргаем источник. */
    val isRefusal: Boolean
        get() = this == NOT_ALLOWED || this == NOT_DOWNLOADABLE || this == NO_MATCH || this == BAD_CONTENT
}

class OfflineException(
    val code: OfflineCode,
    val reason: String? = null,
    message: String? = null,
    cause: Throwable? = null,
) : Exception(message ?: "$code${reason?.let { "/$it" } ?: ""}", cause)

/** Что показать человеку: понятный текст и подпись кнопки. */
data class OfflineText(val message: String, val action: Action?) {
    enum class Action(val label: String) {
        RETRY("Повторить"),
        OPEN_PLUS("Открыть Blink+"),
        SIGN_IN("Войти"),
        FREE_SPACE("Освободить место"),
    }
}

object OfflineTexts {
    fun of(code: OfflineCode, reason: String? = null): OfflineText =
        when (code) {
            OfflineCode.NO_NETWORK -> OfflineText("Нет интернета", OfflineText.Action.RETRY)
            OfflineCode.NO_MATCH -> OfflineText("Не нашли нужную версию трека", OfflineText.Action.RETRY)
            OfflineCode.NOT_DOWNLOADABLE -> OfflineText("Для этого трека нет файла", null)
            OfflineCode.NOT_ALLOWED ->
                when (reason) {
                    "plus" -> OfflineText("Сохранение для офлайна доступно с Blink+", OfflineText.Action.OPEN_PLUS)
                    "artist" -> OfflineText("Артист не разрешил сохранять этот трек", null)
                    "auth" -> OfflineText("Войдите в аккаунт", OfflineText.Action.SIGN_IN)
                    else -> OfflineText("Этот трек играет только онлайн", null)
                }
            OfflineCode.SOURCE_ERROR -> OfflineText("Сервер сейчас не отвечает", OfflineText.Action.RETRY)
            OfflineCode.BAD_CONTENT -> OfflineText("Файл пришёл повреждённым", OfflineText.Action.RETRY)
            OfflineCode.NO_SPACE -> OfflineText("Не хватает места на устройстве", OfflineText.Action.FREE_SPACE)
            OfflineCode.TIMEOUT -> OfflineText("Сервер долго не отвечает", OfflineText.Action.RETRY)
            OfflineCode.CANCELLED -> OfflineText("", null)
        }
}
