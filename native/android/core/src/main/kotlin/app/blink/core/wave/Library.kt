package app.blink.core.wave

import app.blink.core.model.Track
import app.blink.core.net.BlinkConfig
import app.blink.core.net.BlinkJson
import app.blink.core.net.TokenProvider
import app.blink.core.net.arr
import app.blink.core.net.obj
import app.blink.core.net.parseObject
import app.blink.core.net.str
import app.blink.core.net.text
import app.blink.core.net.withCallTimeout
import java.io.IOException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * Что лежит на диске: лайки и история как исходные JSON-объекты (чтобы при записи обратно не потерять поля,
 * которые знает только сайт), и остальное содержимое `data` таблицы `library` (плейлисты, nowPlaying).
 */
@Serializable
data class LibraryData(
    val likes: List<JsonObject> = emptyList(),
    val recent: List<JsonObject> = emptyList(),
    val extra: JsonObject = JsonObject(emptyMap()),
)

/** Лайки и недавнее на устройстве. Основа вкуса Вспышки и синка с сайтом. Новые треки первыми, как на сайте. */
class LibraryStore(private val blob: BlobStore) : Library {
    private val flow = MutableStateFlow(load())
    val state: StateFlow<LibraryData> = flow.asStateFlow()

    @Volatile
    private var parsed: Pair<LibraryData, Pair<List<Track>, List<Track>>>? = null

    private fun load(): LibraryData {
        val text = blob.load() ?: return LibraryData()
        return try {
            BlinkJson.decodeFromString(LibraryData.serializer(), text)
        } catch (_: Exception) {
            LibraryData()
        }
    }

    private fun decode(list: List<JsonObject>): List<Track> =
        list.mapNotNull {
            try {
                BlinkJson.decodeFromJsonElement(Track.serializer(), it)
            } catch (_: Exception) {
                null
            }
        }

    private fun tracks(): Pair<List<Track>, List<Track>> {
        val cur = flow.value
        parsed?.let { if (it.first === cur) return it.second }
        val p = decode(cur.likes) to decode(cur.recent)
        parsed = cur to p
        return p
    }

    override val likes: List<Track> get() = tracks().first
    override val recent: List<Track> get() = tracks().second

    fun isLiked(id: String): Boolean = flow.value.likes.any { it.str("id") == id }

    private fun raw(t: Track): JsonObject = BlinkJson.encodeToJsonElement(Track.serializer(), t) as JsonObject

    private fun commit(next: LibraryData) {
        flow.value = next
        blob.save(BlinkJson.encodeToString(LibraryData.serializer(), next))
    }

    /** Сердечко: ставит или снимает лайк. Возвращает «теперь лайкнут». */
    @Synchronized
    fun toggleLike(track: Track): Boolean {
        val cur = flow.value
        return if (cur.likes.any { it.str("id") == track.id }) {
            commit(cur.copy(likes = cur.likes.filter { it.str("id") != track.id }))
            false
        } else {
            commit(cur.copy(likes = listOf(raw(track)) + cur.likes))
            true
        }
    }

    /** Трек начал играть: наверх истории, без дублей, до 60. */
    @Synchronized
    fun noteRecent(track: Track) {
        val cur = flow.value
        commit(cur.copy(recent = (listOf(raw(track)) + cur.recent.filter { it.str("id") != track.id }).take(RECENT_MAX)))
    }

    /** Слияние с копией с сервера (как `pull` на сайте): локальное первым, затем чужое без повторов по id. */
    @Synchronized
    fun mergeRemote(data: JsonObject) {
        val cur = flow.value
        val remoteLikes = data["likes"].arr().orEmpty().mapNotNull { it.obj() }
        val remoteRecent = data["recent"].arr().orEmpty().mapNotNull { it.obj() }
        val extra = JsonObject(data.filterKeys { it != "likes" && it != "recent" })
        commit(LibraryData(mergeById(cur.likes, remoteLikes), mergeById(cur.recent, remoteRecent).take(RECENT_MAX), extra))
    }

    /** Что записать в `data` строки `library`: наши лайки и история поверх остального, что прислал сервер. */
    fun snapshot(device: String): JsonObject {
        val cur = flow.value
        return JsonObject(cur.extra + mapOf("likes" to JsonArray(cur.likes), "recent" to JsonArray(cur.recent), "device" to JsonPrimitive(device)))
    }

    companion object {
        const val RECENT_MAX = 60

        fun mergeById(a: List<JsonObject>, b: List<JsonObject>): List<JsonObject> {
            val seen = HashSet<String>()
            val out = ArrayList<JsonObject>()
            for (x in a + b) {
                val id = x.str("id") ?: continue
                if (seen.add(id)) out.add(x)
            }
            return out
        }
    }
}

/** Обмен лайками и историей с таблицей `library` в Supabase (одна строка на пользователя, `data` jsonb целиком). */
class LibrarySync(
    http: OkHttpClient,
    private val config: BlinkConfig,
    private val tokens: TokenProvider,
    private val library: LibraryStore,
    private val userId: () -> String?,
    private val device: String = "native-" + java.util.UUID.randomUUID().toString().take(8),
) {
    private val client = http.withCallTimeout(25)
    private val json = "application/json".toMediaType()

    @Volatile
    private var useMirror = false

    @Volatile
    private var lastPushed = ""

    private fun roots(): List<String> =
        if (config.supabaseMirror == config.supabase) listOf(config.supabase) else if (useMirror) listOf(config.supabaseMirror, config.supabase) else listOf(config.supabase, config.supabaseMirror)

    private suspend fun request(build: (String) -> Request): app.blink.core.net.HttpText {
        var last: IOException? = null
        for (root in roots()) {
            try {
                val res = client.newCall(build(root)).text()
                if (config.supabaseMirror != config.supabase) useMirror = root == config.supabaseMirror
                return res
            } catch (e: IOException) {
                last = e
            }
        }
        throw last ?: IOException("library: нет адреса")
    }

    /** Забирает серверную копию, сливает с локальной и сразу пишет результат обратно. false, если не вошли или сервер молчит. */
    suspend fun pull(): Boolean {
        val uid = userId() ?: return false
        val token = tokens.accessToken() ?: return false
        val res = try {
            request { root ->
                val url = root.toHttpUrl().newBuilder().addPathSegments("rest/v1/library")
                    .addQueryParameter("select", "data").addQueryParameter("user_id", "eq.$uid").build()
                Request.Builder().url(url).header("apikey", config.supabaseAnonKey).header("Authorization", "Bearer $token").header("Accept", "application/json").build()
            }
        } catch (_: IOException) {
            return false
        }
        if (res.code !in 200..299) return false
        val rows = try {
            BlinkJson.parseToJsonElement(res.text).arr()
        } catch (_: Exception) {
            null
        } ?: return false
        library.mergeRemote(rows.firstOrNull().obj()?.get("data").obj() ?: JsonObject(emptyMap()))
        return push(force = true)
    }

    /** Пишет лайки и историю в `library`. Без изменений с прошлой записи ничего не шлёт. */
    suspend fun push(force: Boolean = false): Boolean {
        val uid = userId() ?: return false
        val token = tokens.accessToken() ?: return false
        val data = library.snapshot(device)
        val key = BlinkJson.encodeToString(JsonObject.serializer(), JsonObject(data.filterKeys { it != "device" }))
        if (!force && key == lastPushed) return true
        val body = BlinkJson.encodeToString(
            JsonObject.serializer(),
            buildJsonObject {
                put("user_id", JsonPrimitive(uid))
                put("data", data)
                put("updated_at", JsonPrimitive(java.time.Instant.now().toString()))
            },
        )
        val res = try {
            request { root ->
                val url = root.toHttpUrl().newBuilder().addPathSegments("rest/v1/library").build()
                Request.Builder().url(url).header("apikey", config.supabaseAnonKey).header("Authorization", "Bearer $token")
                    .header("Prefer", "resolution=merge-duplicates,return=minimal").post(body.toRequestBody(json)).build()
            }
        } catch (_: IOException) {
            return false
        }
        if (res.code !in 200..299) return false
        lastPushed = key
        return true
    }
}
