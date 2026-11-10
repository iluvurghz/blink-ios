package app.blink.core.net

import java.io.IOException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

@Serializable
data class AuthSession(
    val accessToken: String,
    val refreshToken: String,
    /** Мс от эпохи. */
    val expiresAtMs: Long,
    val userId: String,
    val email: String? = null,
    val name: String? = null,
)

/** Где живёт сессия между запусками. На Android это приватные SharedPreferences. */
interface SessionStore {
    fun load(): String?
    fun save(value: String?)
}

class AuthException(val kind: Kind, message: String) : Exception(message) {
    enum class Kind { BAD_CREDENTIALS, NETWORK, SERVER, NOT_CONFIGURED }
}

/**
 * Вход в Supabase (GoTrue) по почте и паролю и обновление токена. Telegram и Google придут в M1.
 * Токен нужен серверу Blink (Bearer): `/api/offline/resolve`, `/api/play/:id`, `/api/plus/me`.
 */
class SupabaseAuth(
    private val http: OkHttpClient,
    private val config: BlinkConfig,
    private val store: SessionStore,
    private val now: () -> Long = System::currentTimeMillis,
) : TokenProvider {
    private val flow = MutableStateFlow<AuthSession?>(null)
    val session: StateFlow<AuthSession?> = flow.asStateFlow()
    private val refreshLock = Mutex()
    private val json = "application/json".toMediaType()

    val configured: Boolean get() = config.supabaseAnonKey.isNotBlank()

    /** Достаёт сохранённую сессию. Сети не нужно: сохранённое играет и без входа. */
    fun restore() {
        val text = store.load() ?: return
        flow.value = try {
            BlinkJson.decodeFromString(AuthSession.serializer(), text)
        } catch (_: Exception) {
            null
        }
    }

    suspend fun signIn(email: String, password: String): AuthSession {
        if (!configured) throw AuthException(AuthException.Kind.NOT_CONFIGURED, "В этой сборке нет ключа входа")
        val body = buildJsonObject {
            put("email", JsonPrimitive(email.trim()))
            put("password", JsonPrimitive(password))
        }
        val res = call("password", body)
        if (res.code in 200..299) return adopt(res.text)
        throw failure(res)
    }

    override suspend fun accessToken(): String? {
        val s = flow.value ?: return null
        if (s.expiresAtMs - now() > REFRESH_SKEW_MS) return s.accessToken
        return refresh(s)?.accessToken ?: s.accessToken.takeIf { s.expiresAtMs > now() }
    }

    private suspend fun refresh(old: AuthSession): AuthSession? =
        refreshLock.withLock {
            val cur = flow.value ?: return null
            if (cur.refreshToken != old.refreshToken) return cur // уже обновили, пока ждали
            if (!configured) return null
            try {
                val body = buildJsonObject { put("refresh_token", JsonPrimitive(cur.refreshToken)) }
                val res = call("refresh_token", body)
                when {
                    res.code in 200..299 -> adopt(res.text)
                    res.code == 400 || res.code == 401 || res.code == 403 -> {
                        signOutLocal() // refresh-токен отозван: пользователь вошёл заново, сессия не жива
                        null
                    }
                    else -> null
                }
            } catch (_: AuthException) {
                null // сети нет или сервер молчит: сессию не трогаем
            }
        }

    suspend fun signOut() {
        val s = flow.value
        signOutLocal()
        if (s != null && configured) {
            try {
                val url = config.supabase.toHttpUrl().newBuilder().addPathSegments("auth/v1/logout").build()
                val req = Request.Builder().url(url)
                    .header("apikey", config.supabaseAnonKey)
                    .header("Authorization", "Bearer ${s.accessToken}")
                    .post("{}".toRequestBody(json))
                    .build()
                http.withCallTimeout(8).newCall(req).text()
            } catch (_: Exception) {
            }
        }
    }

    private fun signOutLocal() {
        flow.value = null
        store.save(null)
    }

    private suspend fun call(grant: String, body: JsonObject): HttpText {
        val url = config.supabase.toHttpUrl().newBuilder()
            .addPathSegments("auth/v1/token")
            .addQueryParameter("grant_type", grant)
            .build()
        val req = Request.Builder().url(url)
            .header("apikey", config.supabaseAnonKey)
            .header("Accept", "application/json")
            .post(BlinkJson.encodeToString(JsonObject.serializer(), body).toRequestBody(json))
            .build()
        return try {
            http.withCallTimeout(20).newCall(req).text()
        } catch (e: IOException) {
            throw AuthException(AuthException.Kind.NETWORK, "Нет связи с сервером входа")
        }
    }

    private fun adopt(text: String): AuthSession {
        val o = parseObject(text) ?: throw AuthException(AuthException.Kind.SERVER, "Сервер входа ответил непонятно")
        val access = o.str("access_token")
        val refresh = o.str("refresh_token")
        val user = o["user"].obj() ?: throw AuthException(AuthException.Kind.SERVER, "Сервер входа ответил непонятно")
        val id = user.str("id")
        if (access == null || refresh == null || id == null) throw AuthException(AuthException.Kind.SERVER, "Сервер входа ответил непонятно")
        val expiresAt = o.long("expires_at")?.times(1000) ?: (now() + (o.long("expires_in") ?: 3600L) * 1000)
        val meta = user["user_metadata"].obj()
        val s = AuthSession(
            accessToken = access,
            refreshToken = refresh,
            expiresAtMs = expiresAt,
            userId = id,
            email = user.str("email"),
            name = meta?.str("full_name") ?: meta?.str("name"),
        )
        flow.value = s
        store.save(BlinkJson.encodeToString(AuthSession.serializer(), s))
        return s
    }

    private fun failure(res: HttpText): AuthException {
        val o = parseObject(res.text)
        val code = o?.str("error_code") ?: o?.str("error")
        return when {
            res.code == 400 || res.code == 401 || code == "invalid_credentials" || code == "invalid_grant" ->
                AuthException(AuthException.Kind.BAD_CREDENTIALS, "Неверная почта или пароль")
            res.code == 429 -> AuthException(AuthException.Kind.SERVER, "Слишком много попыток, подождите минуту")
            else -> AuthException(AuthException.Kind.SERVER, "Сервер входа не отвечает (${res.code})")
        }
    }

    private companion object {
        const val REFRESH_SKEW_MS = 60_000L
    }
}
