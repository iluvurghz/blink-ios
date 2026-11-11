package app.blink.core.net

import java.net.URLDecoder

/**
 * Ссылка, которой сайт возвращает пользователя в приложение после входа в системном браузере:
 * `blink://auth?id_token=…&nonce=…` (Google) или `blink://auth?tg_hash=…` (Telegram).
 * Параметры могут прийти и в части после `#`.
 */
sealed interface AuthLink {
    data class IdToken(val token: String, val nonce: String) : AuthLink
    data class TelegramHash(val hash: String) : AuthLink
    data class Failed(val reason: String?) : AuthLink

    companion object {
        const val SCHEME = "blink"
        const val HOST = "auth"

        /** Адрес страницы сайта, с которой начинается вход выбранным способом. */
        fun startUrl(base: String, provider: Provider): String =
            base.trimEnd('/') + "/?" + (if (provider == Provider.GOOGLE) "gsignin" else "tgsignin") + "=desktop"

        /** Разбирает ссылку возврата; чужие ссылки и ссылки без нужных параметров дают null. */
        fun parse(url: String?): AuthLink? {
            if (url == null) return null
            val lower = url.lowercase()
            if (!lower.startsWith("$SCHEME://$HOST")) return null
            val params = HashMap<String, String>()
            for (part in url.substringAfter('?', "").substringBefore('#').split('&') + url.substringAfter('#', "").split('&')) {
                val k = part.substringBefore('=', "")
                if (k.isEmpty()) continue
                val v = part.substringAfter('=', "")
                params[k] = try {
                    URLDecoder.decode(v.replace("+", "%2B"), "UTF-8")
                } catch (_: IllegalArgumentException) {
                    v
                }
            }
            val idToken = params["id_token"]
            val nonce = params["nonce"]
            val tg = params["tg_hash"]
            return when {
                !idToken.isNullOrEmpty() && !nonce.isNullOrEmpty() -> IdToken(idToken, nonce)
                !tg.isNullOrEmpty() -> TelegramHash(tg)
                params.containsKey("error") || params.containsKey("error_description") -> Failed(params["error_description"] ?: params["error"])
                else -> null
            }
        }
    }

    enum class Provider { GOOGLE, TELEGRAM }
}
