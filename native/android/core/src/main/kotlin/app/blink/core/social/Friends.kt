package app.blink.core.social

import app.blink.core.model.Track
import app.blink.core.net.BlinkConfig
import app.blink.core.net.BlinkJson
import app.blink.core.net.KeyValue
import app.blink.core.net.TokenProvider
import app.blink.core.net.arr
import app.blink.core.net.bool
import app.blink.core.net.obj
import app.blink.core.net.parseObject
import app.blink.core.net.str
import app.blink.core.net.text
import app.blink.core.net.withCallTimeout
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

data class FriendTrack(val id: String, val title: String, val artist: String, val artwork: String)

data class Friend(val id: String, val name: String, val avatar: String, val track: FriendTrack?, val room: String?) {
    val listening: Boolean get() = track != null
}

data class FriendsList(val friends: List<Friend>, val hidden: Boolean)

/** Друзья: приглашение по ссылке и «слушает сейчас». Форма снята с `server/friendsRoute.js`. */
interface FriendsService {
    suspend fun list(): FriendsList?

    /** Код моего приглашения (живёт 7 дней). */
    suspend fun invite(): String?

    /** Принять приглашение; вернёт имя друга или бросит [FriendsException] с текстом сервера. */
    suspend fun accept(code: String): String

    suspend fun remove(id: String): Boolean

    suspend fun setHidden(hidden: Boolean): Boolean

    suspend fun activity(track: FriendTrack?, room: String)
}

class FriendsException(message: String) : Exception(message)

class FriendsApi(http: OkHttpClient, private val config: BlinkConfig, private val tokens: TokenProvider?) : FriendsService {
    private val client = http.withCallTimeout(10)
    private val jsonType = "application/json".toMediaType()

    private suspend fun call(path: String, body: JsonObject?): Pair<Int, JsonObject?> {
        val b = Request.Builder().url("${config.base}/$path").header("Accept", "application/json")
        tokens?.accessToken()?.let { b.header("Authorization", "Bearer $it") }
        if (body != null) b.post(BlinkJson.encodeToString(JsonObject.serializer(), body).toRequestBody(jsonType)) else b.get()
        val res = client.newCall(b.build()).text()
        return res.code to parseObject(res.text)
    }

    override suspend fun list(): FriendsList? {
        val (code, o) = call("api/friends", null)
        if (code != 200 || o == null) return null
        val friends = o["friends"].arr().orEmpty().mapNotNull { e ->
            val f = e.obj() ?: return@mapNotNull null
            val l = f["listening"].obj()
            val t = l?.get("track").obj()
            Friend(
                id = f.str("id") ?: return@mapNotNull null,
                name = f.str("name").orEmpty(),
                avatar = f.str("avatar").orEmpty(),
                track = t?.let { FriendTrack(it.str("id").orEmpty(), it.str("title").orEmpty(), it.str("artist").orEmpty(), it.str("artwork").orEmpty()) },
                room = l?.str("room")?.takeIf { it.isNotEmpty() },
            )
        }
        return FriendsList(friends, o.bool("hidden") == true)
    }

    override suspend fun invite(): String? {
        val (code, o) = call("api/friends/link", buildJsonObject { })
        return if (code == 200) o?.str("code") else null
    }

    override suspend fun accept(code: String): String {
        val (status, o) = call("api/friends/accept", buildJsonObject { put("code", code) })
        if (status == 200) return o?.get("friend").obj()?.str("name") ?: "Друг"
        throw FriendsException(o?.str("error") ?: "Не получилось добавить")
    }

    override suspend fun remove(id: String): Boolean = call("api/friends/remove", buildJsonObject { put("id", id) }).first == 200

    override suspend fun setHidden(hidden: Boolean): Boolean = call("api/friends/hidden", buildJsonObject { put("hidden", hidden) }).first == 200

    override suspend fun activity(track: FriendTrack?, room: String) {
        call(
            "api/friends/activity",
            buildJsonObject {
                if (track != null) {
                    put(
                        "track",
                        buildJsonObject {
                            put("id", track.id)
                            put("title", track.title)
                            put("artist", track.artist)
                            put("artwork", track.artwork)
                        },
                    )
                }
                put("room", room)
            },
        )
    }

    companion object {
        /** Код приглашения из ссылки (`?friend=<код>`) или null. */
        fun codeFrom(url: String?): String? {
            if (url.isNullOrBlank()) return null
            return Regex("""[?&]friend=([A-Za-z0-9_-]{4,64})""").find(url)?.groupValues?.get(1)
        }

        fun link(code: String): String = "https://blinkmusic.cc/?friend=$code"
    }
}

/** Список друзей на экране и то, что мы сами показываем друзьям. */
class FriendsModel(
    private val service: FriendsService,
    private val scope: CoroutineScope,
    private val say: (String) -> Unit,
) {
    data class Ui(val friends: List<Friend> = emptyList(), val hidden: Boolean = false, val loading: Boolean = false, val loaded: Boolean = false, val offline: Boolean = false)

    private val flow = MutableStateFlow(Ui())
    val state: StateFlow<Ui> = flow.asStateFlow()

    suspend fun refresh() {
        flow.update { it.copy(loading = true) }
        val list = try {
            service.list()
        } catch (e: CancellationException) {
            throw e
        } catch (_: IOException) {
            null
        }
        if (list == null) flow.update { it.copy(loading = false, offline = true) } else flow.value = Ui(list.friends, list.hidden, loading = false, loaded = true)
    }

    fun clear() {
        flow.value = Ui()
    }

    suspend fun invite(): String? =
        try {
            service.invite()?.let(FriendsApi::link) ?: run {
                say("Не получилось создать ссылку")
                null
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: IOException) {
            say("Нет связи с сервером")
            null
        }

    suspend fun accept(code: String): Boolean =
        try {
            val name = service.accept(code)
            say("Теперь вы друзья с $name")
            refresh()
            true
        } catch (e: FriendsException) {
            say(e.message ?: "Не получилось добавить")
            false
        } catch (e: CancellationException) {
            throw e
        } catch (_: IOException) {
            say("Нет связи с сервером")
            false
        }

    suspend fun remove(id: String) {
        val ok = try {
            service.remove(id)
        } catch (e: CancellationException) {
            throw e
        } catch (_: IOException) {
            false
        }
        if (ok) flow.update { s -> s.copy(friends = s.friends.filter { it.id != id }) } else say("Не получилось удалить")
    }

    suspend fun setHidden(hidden: Boolean) {
        flow.update { it.copy(hidden = hidden) }
        val ok = try {
            service.setHidden(hidden)
        } catch (e: CancellationException) {
            throw e
        } catch (_: IOException) {
            false
        }
        if (!ok) {
            flow.update { it.copy(hidden = !hidden) }
            say("Не получилось сохранить")
        }
    }

    // ---------- что мы показываем друзьям ----------

    private var lastKey = ""
    private var ticker: Job? = null

    /** Зовём на каждое изменение плеера или комнаты. Шлём, когда сменился трек или комната, и раз в 45 секунд, пока играем. */
    fun report(playing: Boolean, track: Track?, room: String?, force: Boolean = false) {
        if (flow.value.hidden) return
        val t = if (playing) track else null
        val code = room.orEmpty()
        val key = if (t != null) "${t.id}|$code" else ""
        if (!force && key == lastKey) return
        lastKey = key
        scope.launch {
            try {
                service.activity(t?.let { FriendTrack(it.id, it.title, it.artist, it.artwork) }, code)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            }
        }
    }

    /** Раз в 45 секунд повторяем «слушаю», пока играем: сервер забывает через 90. */
    fun keepAlive(current: () -> Triple<Boolean, Track?, String?>) {
        ticker?.cancel()
        ticker = scope.launch {
            while (isActive) {
                delay(45_000)
                val (playing, track, room) = current()
                if (playing && track != null) report(true, track, room, force = true)
            }
        }
    }
}

/** «Я здесь» для счётчика онлайна в админке: случайный id устройства, больше ничего об аккаунте. */
class PresenceBeat(
    http: OkHttpClient,
    private val config: BlinkConfig,
    private val store: KeyValue,
    private val scope: CoroutineScope,
    private val platform: String = "app",
) {
    private val client = http.withCallTimeout(10)
    private val jsonType = "application/json".toMediaType()

    private fun deviceId(): String {
        store.get("presence.device")?.let { return it }
        val id = UUID.randomUUID().toString().replace("-", "").take(24)
        store.put("presence.device", id)
        return id
    }

    fun beat(playing: Boolean, track: Track?) {
        val body = buildJsonObject {
            put("device", deviceId())
            put("platform", platform)
            put("playing", playing && track != null)
            if (track != null) {
                put(
                    "track",
                    buildJsonObject {
                        put("id", track.id)
                        put("title", track.title)
                        put("artist", track.artist)
                        put("source", if (track.source == "blink" || track.source == "jamendo") track.source else "youtube")
                    },
                )
            }
        }
        scope.launch {
            try {
                val req = Request.Builder().url("${config.base}/api/presence").post(BlinkJson.encodeToString(JsonObject.serializer(), body).toRequestBody(jsonType)).build()
                client.newCall(req).text()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            }
        }
    }
}
