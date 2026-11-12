package app.blink.core.library

import app.blink.core.model.Track
import app.blink.core.net.BlinkApi
import app.blink.core.net.BlinkConfig
import app.blink.core.net.BlinkJson
import app.blink.core.net.TokenProvider
import app.blink.core.net.arr
import app.blink.core.net.long
import app.blink.core.net.obj
import app.blink.core.net.str
import app.blink.core.net.bool
import java.io.IOException
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody

/** Публичная страница артиста Blink: `blinkmusic.cc/u/<имя>`. */
data class ArtistProfile(
    val id: String,
    val userId: String?,
    val name: String,
    val handle: String?,
    val bio: String?,
    val avatar: String?,
    val verified: Boolean,
    val tracks: List<Track>,
    val followers: Long,
    val likes: Long,
)

class ArtistApi(http: OkHttpClient, private val config: BlinkConfig, tokens: TokenProvider?, private val api: BlinkApi, private val userId: () -> String?) {
    private val db = SupabaseRest(http, config, tokens)
    private val json = "application/json".toMediaType()

    /** Страница по id или имени ссылки; null, если такой нет. Сетевой сбой бросает IOException. */
    suspend fun profile(key: String, today: String = java.time.LocalDate.now().toString()): ArtistProfile? {
        val byId = Regex("^[0-9a-f-]{36}$").matches(key)
        val (s, text) = db.call("artists", mapOf("select" to "id,user_id,name,handle,bio,avatar_url,verified", (if (byId) "id" else "handle") to "eq.$key"))
        if (s !in 200..299) throw IOException("artist $s")
        val a = BlinkJson.parseToJsonElement(text).arr()?.firstOrNull().obj() ?: return null
        val id = a.str("id") ?: return null
        val name = a.str("name").orEmpty()
        val verified = a.bool("verified") == true
        val own = tracks(mapOf("artist_id" to "eq.$id"), today)
        val label = if (verified) tracks(mapOf("source" to "eq.partner", "artist_name" to "ilike." + name.replace(Regex("[\\\\%_]")) { "\\" + it.value }), today) else emptyList()
        val st = try {
            val (ss, t) = db.call("rpc/artist_stats", emptyMap(), { it.post("""{"aid":"$id"}""".toRequestBody(json)) })
            if (ss in 200..299) BlinkJson.parseToJsonElement(t).arr()?.firstOrNull().obj() else null
        } catch (_: IOException) {
            null
        }
        return ArtistProfile(id, a.str("user_id"), name, a.str("handle"), a.str("bio"), a.str("avatar_url"), verified, (own + label).distinctBy { it.id }, st?.long("followers") ?: 0, st?.long("likes") ?: 0)
    }

    private suspend fun tracks(filter: Map<String, String>, today: String): List<Track> {
        val q = linkedMapOf("select" to BlinkApi.LIC_FIELDS, "status" to "eq.live", "release_date" to "lte.$today", "order" to "release_date.desc", "limit" to "200") + filter
        val (s, text) = db.call("lic_tracks", q)
        if (s !in 200..299) return emptyList()
        return BlinkJson.parseToJsonElement(text).arr().orEmpty().mapNotNull { api.fromLicRow(it.obj() ?: return@mapNotNull null) }
    }

    suspend fun isFollowing(artistId: String): Boolean {
        val uid = userId() ?: return false
        val (s, text) = db.call("follows", mapOf("select" to "artist_id", "user_id" to "eq.$uid", "artist_id" to "eq.$artistId"), auth = true)
        return s in 200..299 && BlinkJson.parseToJsonElement(text).arr()?.isNotEmpty() == true
    }

    /** Подписаться или отписаться. false, если не вышло. */
    suspend fun setFollow(artistId: String, on: Boolean): Boolean {
        val uid = userId() ?: return false
        val (s, _) = if (on) {
            val body = buildJsonObject {
                put("user_id", JsonPrimitive(uid))
                put("artist_id", JsonPrimitive(artistId))
            }
            db.call("follows", emptyMap(), { it.header("Prefer", "return=minimal").post(BlinkJson.encodeToString(JsonObject.serializer(), body).toRequestBody(json)) }, auth = true)
        } else {
            db.call("follows", mapOf("user_id" to "eq.$uid", "artist_id" to "eq.$artistId"), { it.delete() }, auth = true)
        }
        return s in 200..299 || s == 409
    }
}
