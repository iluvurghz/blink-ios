package app.blink.core.social

import app.blink.core.model.Track
import app.blink.core.net.BlinkConfig
import app.blink.core.net.BlinkJson
import app.blink.core.net.TokenProvider
import app.blink.core.net.arr
import app.blink.core.net.bool
import app.blink.core.net.long
import app.blink.core.net.obj
import app.blink.core.net.parseObject
import app.blink.core.net.run
import app.blink.core.net.str
import app.blink.core.net.text
import app.blink.core.net.withCallTimeout
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** Комната «Слушать вместе». Форма снята с `server/together.js` (поле `view`). */
data class RoomMember(val id: String, val name: String, val host: Boolean)

data class RoomChat(val id: String, val by: String, val name: String, val text: String, val at: Long)

data class RoomReaction(val id: String, val by: String, val name: String, val emoji: String, val at: Long)

data class RoomState(
    val code: String,
    /** Меняется от всего: люди, чат, плеер. По нему ждёт long poll. */
    val rev: Long,
    /** Меняется только от плеера: чат не делает чужую паузу «устаревшей». */
    val v: Long,
    val chat: List<RoomChat> = emptyList(),
    val track: Track? = null,
    val queue: List<Track> = emptyList(),
    val index: Int = 0,
    val playing: Boolean = false,
    /** Позиция в секундах на серверное время [at]. */
    val pos: Double = 0.0,
    val at: Long = 0,
    val by: String? = null,
    val host: String? = null,
    /** `all`: управляют все, `host`: только хост. */
    val mode: String = "all",
    val skips: List<String> = emptyList(),
    val reactions: List<RoomReaction> = emptyList(),
    val members: List<RoomMember> = emptyList(),
    val now: Long = 0,
) {
    /** Где сейчас должна быть позиция (мс) при расхождении часов [offsetMs] (серверные минус наши). */
    fun targetMs(localNowMs: Long, offsetMs: Long): Long {
        val base = pos * 1000.0
        val moved = if (playing) (localNowMs + offsetMs - at).coerceAtLeast(0) else 0
        return (base + moved).toLong().coerceAtLeast(0)
    }

    fun isHost(userId: String?): Boolean = userId != null && userId == host

    companion object {
        fun parse(o: JsonObject): RoomState? {
            val code = o.str("code") ?: return null
            return RoomState(
                code = code,
                rev = o.long("rev") ?: 0,
                v = o.long("v") ?: 0,
                chat = o["chat"].arr().orEmpty().mapNotNull { e ->
                    val c = e.obj() ?: return@mapNotNull null
                    RoomChat(c.str("id") ?: return@mapNotNull null, c.str("by").orEmpty(), c.str("name").orEmpty(), c.str("text").orEmpty(), c.long("at") ?: 0)
                },
                track = roomTrack(o["track"]),
                queue = o["queue"].arr().orEmpty().mapNotNull { roomTrack(it) },
                index = (o.long("index") ?: 0).toInt(),
                playing = o.bool("playing") == true,
                pos = (o["pos"] as? JsonPrimitive)?.content?.toDoubleOrNull() ?: 0.0,
                at = o.long("at") ?: 0,
                by = o.str("by"),
                host = o.str("host"),
                mode = if (o.str("mode") == "host") "host" else "all",
                skips = o["skips"].arr().orEmpty().mapNotNull { (it as? JsonPrimitive)?.content },
                reactions = o["reactions"].arr().orEmpty().mapNotNull { e ->
                    val r = e.obj() ?: return@mapNotNull null
                    RoomReaction(r.str("id") ?: return@mapNotNull null, r.str("by").orEmpty(), r.str("name").orEmpty(), r.str("emoji").orEmpty(), r.long("at") ?: 0)
                },
                members = o["members"].arr().orEmpty().mapNotNull { e ->
                    val m = e.obj() ?: return@mapNotNull null
                    RoomMember(m.str("id") ?: return@mapNotNull null, m.str("name").orEmpty(), m.bool("host") == true)
                },
                now = o.long("now") ?: 0,
            )
        }

        fun parse(text: String): RoomState? = parseObject(text)?.let(::parse)

        /** Сервер хранит только короткие плоские значения; `year` у него может оказаться числом. */
        private fun roomTrack(e: JsonElement?): Track? {
            val o = e.obj() ?: return null
            val fixed = JsonObject(o.mapValues { (k, v) -> if (k == "year" && v is JsonPrimitive && !v.isString) JsonPrimitive(v.content) else v })
            return try {
                BlinkJson.decodeFromJsonElement(Track.serializer(), fixed)
            } catch (_: Exception) {
                null
            }
        }

        fun trackJson(t: Track): JsonElement = BlinkJson.encodeToJsonElement(Track.serializer(), t)
    }
}

/** Ответ комнаты: код HTTP, состояние (если сервер его приложил) и текст ошибки. */
data class RoomReply(val status: Int, val room: RoomState?, val error: String?) {
    val ok: Boolean get() = status in 200..299

    /** Комнаты нет или в неё не пускают: ждать дальше бессмысленно. */
    val gone: Boolean get() = status == 404 || status == 401 || (status == 403 && room == null)
}

/** Что умеет сервер комнат. Интерфейс, чтобы логику сессии проверять без сети. */
interface RoomService {
    suspend fun create(): RoomReply

    suspend fun serverTime(): Long?

    /** Отправить состояние плеера; `patch` дополняет `base`. */
    suspend fun post(code: String, base: Long, playing: Boolean, posSec: Double, track: Track? = null, queue: List<Track>? = null, index: Int = 0): RoomReply

    suspend fun chat(code: String, text: String): RoomReply

    suspend fun react(code: String, emoji: String): RoomReply

    suspend fun mode(code: String, mode: String): RoomReply

    suspend fun enqueue(code: String, track: Track): RoomReply

    suspend fun skip(code: String): RoomReply

    suspend fun leave(code: String)

    /** Долгий запрос: вызывает [onRoom] на каждое событие, пока соединение живо. Возвращает причину конца. */
    suspend fun stream(code: String, onRoom: (RoomState) -> Unit): StreamEnd

    suspend fun poll(code: String, rev: Long): RoomReply
}

sealed interface StreamEnd {
    /** Соединение оборвалось, можно переподключиться. */
    data object Dropped : StreamEnd

    /** Комнаты больше нет или не пускают. */
    data class Gone(val message: String) : StreamEnd

    /** Сервер без потока (старый): работаем long poll-ом. */
    data object Unsupported : StreamEnd
}

class RoomApi(http: OkHttpClient, private val config: BlinkConfig, private val tokens: TokenProvider?) : RoomService {
    private val client = http.withCallTimeout(25)
    private val streamClient = http.newBuilder().callTimeout(0, TimeUnit.SECONDS).readTimeout(50, TimeUnit.SECONDS).build()
    private val jsonType = "application/json".toMediaType()

    private suspend fun request(path: String, body: JsonObject?, query: Map<String, String> = emptyMap(), longPoll: Boolean = false): RoomReply {
        val url = config.base.toHttpUrl().newBuilder().addPathSegments(path).apply { query.forEach { (k, v) -> addQueryParameter(k, v) } }.build()
        val b = Request.Builder().url(url).header("Accept", "application/json")
        tokens?.accessToken()?.let { b.header("Authorization", "Bearer $it") }
        if (body != null) b.post(BlinkJson.encodeToString(JsonObject.serializer(), body).toRequestBody(jsonType)) else b.get()
        val c = if (longPoll) streamClient else client
        val res = c.newCall(b.build()).text()
        val o = parseObject(res.text)
        return RoomReply(res.code, o?.let(RoomState::parse), o?.str("error"))
    }

    override suspend fun create(): RoomReply = request("api/together", buildJsonObject { })

    override suspend fun serverTime(): Long? =
        try {
            parseObject(client.newCall(Request.Builder().url("${config.base}/api/together/time").build()).text().text)?.long("now")
        } catch (_: IOException) {
            null
        }

    override suspend fun post(code: String, base: Long, playing: Boolean, posSec: Double, track: Track?, queue: List<Track>?, index: Int): RoomReply =
        request(
            "api/together/$code",
            buildJsonObject {
                put("base", base)
                put("playing", playing)
                put("pos", posSec)
                if (track != null) {
                    put("track", RoomState.trackJson(track))
                    put("queue", JsonArray((queue ?: listOf(track)).take(100).map(RoomState::trackJson)))
                    put("index", index)
                }
            },
        )

    override suspend fun chat(code: String, text: String): RoomReply = request("api/together/$code/chat", buildJsonObject { put("text", text) })

    override suspend fun react(code: String, emoji: String): RoomReply = request("api/together/$code/react", buildJsonObject { put("emoji", emoji) })

    override suspend fun mode(code: String, mode: String): RoomReply = request("api/together/$code/mode", buildJsonObject { put("mode", mode) })

    override suspend fun enqueue(code: String, track: Track): RoomReply = request("api/together/$code/queue", buildJsonObject { put("track", RoomState.trackJson(track)) })

    override suspend fun skip(code: String): RoomReply = request("api/together/$code/skip", buildJsonObject { })

    override suspend fun leave(code: String) {
        try {
            request("api/together/$code/leave", buildJsonObject { })
        } catch (_: IOException) {
        }
    }

    override suspend fun poll(code: String, rev: Long): RoomReply = request("api/together/$code", null, mapOf("r" to rev.toString()), longPoll = true)

    override suspend fun stream(code: String, onRoom: (RoomState) -> Unit): StreamEnd {
        val b = Request.Builder().url("${config.base}/api/together/$code/stream").header("Accept", "text/event-stream")
        tokens?.accessToken()?.let { b.header("Authorization", "Bearer $it") }
        return try {
            streamClient.newCall(b.build()).run { r ->
                val src = r.body?.source()
                when {
                    r.code == 404 || r.code == 403 || r.code == 401 ->
                        StreamEnd.Gone(parseObject(r.body?.string().orEmpty())?.str("error") ?: "Комната закрыта")
                    !r.isSuccessful || src == null -> StreamEnd.Unsupported
                    else -> {
                        while (true) {
                            val line = src.readUtf8Line() ?: break
                            if (line.startsWith("data: ")) RoomState.parse(line.substring(6))?.let(onRoom)
                        }
                        StreamEnd.Dropped
                    }
                }
            }
        } catch (_: IOException) {
            StreamEnd.Dropped
        }
    }
}
