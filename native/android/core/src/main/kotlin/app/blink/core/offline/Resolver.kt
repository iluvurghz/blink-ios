package app.blink.core.offline

import app.blink.core.net.BlinkConfig
import app.blink.core.net.TokenProvider
import app.blink.core.net.bool
import app.blink.core.net.int
import app.blink.core.net.long
import app.blink.core.net.parseObject
import app.blink.core.net.str
import app.blink.core.net.text
import app.blink.core.net.withCallTimeout
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request

/** Подписанная ссылка на файл и то, что про него известно заранее. */
data class Resolved(
    val url: String,
    val mime: String? = null,
    /** Точный размер. null только в обходе через /api/play: тогда берём из Content-Range. */
    val bytes: Long? = null,
    /** Слабый etag `W/"..."`: в If-Range уходит дословно. */
    val etag: String? = null,
    /** Мс от эпохи. */
    val expiresAt: Long = 0,
    val duration: Int? = null,
)

fun interface TrackResolver {
    /** Бросает OfflineException с кодом из контракта; сетевые сбои это обычный IOException. */
    suspend fun resolve(source: String, id: String): Resolved
}

/**
 * Резолвер сервера Blink: `GET /api/offline/resolve?source=blink&id=<uuid>` с Bearer.
 * К самой ссылке Authorization не добавляется: она подписана на пользователя и живёт час.
 *
 * Пока резолвер не выкачен на прод (ответ 404 без нашего JSON), идём в `GET /api/play/<uuid>` →
 * `{url}`: тогда bytes/etag/mime неизвестны, а Blink+ и offline_allowed проверяет клиент.
 */
class ServerResolver(
    private val http: OkHttpClient,
    private val config: BlinkConfig,
    private val tokens: TokenProvider,
    private val now: () -> Long = System::currentTimeMillis,
    private val legacyFallback: Boolean = true,
) : TrackResolver {
    private val client = http.withCallTimeout(RESOLVE_TIMEOUT_SECONDS)

    override suspend fun resolve(source: String, id: String): Resolved {
        val token = tokens.accessToken() ?: throw OfflineException(OfflineCode.NOT_ALLOWED, "auth")
        val url = config.base.toHttpUrl().newBuilder()
            .addPathSegments("api/offline/resolve")
            .addQueryParameter("source", source)
            .addQueryParameter("id", id)
            .build()
        val res = client.newCall(authorized(Request.Builder().url(url), token).build()).text()
        val json = parseObject(res.text)

        if (res.code == 200) {
            if (json == null || json.bool("ok") != true) throw OfflineException(OfflineCode.SOURCE_ERROR, "bad_response")
            val fileUrl = config.absolute(json.str("url")) ?: throw OfflineException(OfflineCode.SOURCE_ERROR, "bad_response")
            val bytes = json.long("bytes")
            if (bytes == null || bytes <= 0) throw OfflineException(OfflineCode.SOURCE_ERROR, "bad_response")
            return Resolved(
                url = fileUrl,
                mime = json.str("mime"),
                bytes = bytes,
                etag = json.str("etag"),
                expiresAt = json.long("expiresAt") ?: (now() + DEFAULT_TTL_MS),
                duration = json.int("duration"),
            )
        }

        val declared = json?.takeIf { it.bool("ok") == false }
        if (res.code == 404 && declared == null) {
            // Нашего JSON нет: эндпоинта на сервере ещё нет.
            if (legacyFallback && source == "blink") return legacy(id, token)
        }
        throw mapError(res.code, declared?.str("error"), declared?.str("reason"))
    }

    private suspend fun legacy(id: String, token: String): Resolved {
        val url = config.base.toHttpUrl().newBuilder().addPathSegments("api/play").addPathSegment(id).build()
        val res = client.newCall(authorized(Request.Builder().url(url), token).build()).text()
        val json = parseObject(res.text)
        if (res.code == 200) {
            val fileUrl = config.absolute(json?.str("url")) ?: throw OfflineException(OfflineCode.SOURCE_ERROR, "bad_response")
            return Resolved(url = fileUrl, expiresAt = now() + LEGACY_TTL_MS)
        }
        throw mapError(res.code, null, null)
    }

    private fun authorized(b: Request.Builder, token: String) =
        b.header("Authorization", "Bearer $token").header("Accept", "application/json")

    internal companion object {
        const val RESOLVE_TIMEOUT_SECONDS = 15L
        const val DEFAULT_TTL_MS = 55 * 60 * 1000L
        const val LEGACY_TTL_MS = 55 * 60 * 1000L

        fun mapError(status: Int, error: String?, reason: String?): OfflineException {
            val declared = error?.let { e -> OfflineCode.entries.firstOrNull { it.name == e } }
            if (declared != null && declared != OfflineCode.CANCELLED) {
                val r = when {
                    reason != null -> reason
                    declared == OfflineCode.NOT_ALLOWED && status == 401 -> "auth"
                    declared == OfflineCode.NOT_ALLOWED -> "source"
                    else -> null
                }
                return OfflineException(declared, r)
            }
            return when (status) {
                401 -> OfflineException(OfflineCode.NOT_ALLOWED, "auth")
                403 -> OfflineException(OfflineCode.NOT_ALLOWED, reason ?: "source")
                404 -> OfflineException(OfflineCode.NOT_DOWNLOADABLE, reason ?: "missing")
                else -> OfflineException(OfflineCode.SOURCE_ERROR, "http_$status")
            }
        }
    }
}
