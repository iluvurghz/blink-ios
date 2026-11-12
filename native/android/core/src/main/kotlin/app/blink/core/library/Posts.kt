package app.blink.core.library

import app.blink.core.model.Track
import app.blink.core.net.BlinkApi
import app.blink.core.net.BlinkConfig
import app.blink.core.net.BlinkJson
import app.blink.core.net.TokenProvider
import app.blink.core.net.arr
import app.blink.core.net.bool
import app.blink.core.net.long
import app.blink.core.net.obj
import app.blink.core.net.str
import java.io.IOException
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody

/** Анонс артиста (таблица `posts`, ответ `post_list`). */
data class Post(
    val id: String,
    val artistId: String,
    val artistName: String,
    val avatar: String?,
    val body: String,
    val trackId: String?,
    val createdAt: String,
    val likes: Long,
    val liked: Boolean,
    val track: Track?,
)

/** Комментарий к анонсу или треку (ответ `comment_list`). */
data class Comment(
    val id: String,
    val userId: String,
    val artistId: String?,
    val name: String,
    val avatar: String?,
    val body: String,
    val createdAt: String,
)

/** Анонсы, комментарии, жалобы и правка описания артиста: то же, что делает сайт в lib/catalog.js. */
class PostsApi(http: OkHttpClient, config: BlinkConfig, tokens: TokenProvider?, private val api: BlinkApi, private val userId: () -> String?) {
    private val db = SupabaseRest(http, config, tokens)
    private val json = "application/json".toMediaType()

    private fun body(build: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit): okhttp3.RequestBody =
        BlinkJson.encodeToString(JsonObject.serializer(), buildJsonObject(build)).toRequestBody(json)

    /** Анонсы одного артиста или, без id, лента тех, на кого подписан. Сетевой сбой бросает IOException. */
    suspend fun posts(artistId: String? = null, today: String = ""): List<Post> {
        val (s, text) = db.call("rpc/post_list", emptyMap(), {
            it.post(body { put("aid", if (artistId == null) JsonNull else JsonPrimitive(artistId)) })
        }, auth = true)
        if (s !in 200..299) throw IOException("post_list $s")
        val rows = BlinkJson.parseToJsonElement(text).arr().orEmpty().mapNotNull { it.obj() }
        val ids = rows.mapNotNull { it.str("track_id") }.distinct()
        val tracks = if (ids.isEmpty()) emptyMap() else loadTracks(ids)
        return rows.mapNotNull { o ->
            Post(
                id = o.str("id") ?: return@mapNotNull null,
                artistId = o.str("artist_id").orEmpty(),
                artistName = o.str("artist_name").orEmpty(),
                avatar = o.str("avatar_url"),
                body = o.str("body").orEmpty(),
                trackId = o.str("track_id"),
                createdAt = o.str("created_at").orEmpty(),
                likes = o.long("likes") ?: 0,
                liked = o.bool("liked") == true,
                track = o.str("track_id")?.let { tracks[it] },
            )
        }
    }

    private suspend fun loadTracks(ids: List<String>): Map<String, Track> {
        val (s, text) = db.call("lic_tracks", mapOf("select" to BlinkApi.LIC_FIELDS, "id" to "in.(${ids.joinToString(",")})"))
        if (s !in 200..299) return emptyMap()
        val out = HashMap<String, Track>()
        for (e in BlinkJson.parseToJsonElement(text).arr().orEmpty()) {
            val o = e.obj() ?: continue
            val id = o.str("id") ?: continue
            api.fromLicRow(o)?.let { out[id] = it }
        }
        return out
    }

    /** Опубликовать анонс. Сообщение ошибки уже по-русски. */
    suspend fun createPost(artistId: String, text: String, trackId: String?) {
        val (s, resp) = db.call("posts", emptyMap(), {
            it.header("Prefer", "return=minimal").post(body {
                put("artist_id", JsonPrimitive(artistId))
                put("body", JsonPrimitive(text))
                put("track_id", if (trackId == null) JsonNull else JsonPrimitive(trackId))
            })
        }, auth = true)
        if (s !in 200..299) throw SharedError(if (resp.contains("too_often")) "Анонс можно публиковать раз в 10 минут" else "Не получилось опубликовать")
    }

    suspend fun deletePost(id: String) {
        val (s, _) = db.call("posts", mapOf("id" to "eq.$id"), { it.delete() }, auth = true)
        if (s !in 200..299) throw SharedError("Не получилось удалить")
    }

    /** Лайк анонса. Повтор (409) не считается ошибкой. */
    suspend fun setPostLike(postId: String, on: Boolean): Boolean {
        val uid = userId() ?: return false
        val (s, _) = if (on) {
            db.call("post_likes", emptyMap(), { it.header("Prefer", "return=minimal").post(body {
                put("user_id", JsonPrimitive(uid))
                put("post_id", JsonPrimitive(postId))
            }) }, auth = true)
        } else {
            db.call("post_likes", mapOf("user_id" to "eq.$uid", "post_id" to "eq.$postId"), { it.delete() }, auth = true)
        }
        return s in 200..299 || s == 409
    }

    suspend fun comments(postId: String? = null, trackId: String? = null): List<Comment> {
        val (s, text) = db.call("rpc/comment_list", emptyMap(), {
            it.post(body {
                put("pid", if (postId == null) JsonNull else JsonPrimitive(postId))
                put("tid", if (trackId == null) JsonNull else JsonPrimitive(trackId))
            })
        })
        if (s !in 200..299) throw IOException("comment_list $s")
        return BlinkJson.parseToJsonElement(text).arr().orEmpty().mapNotNull { e ->
            val o = e.obj() ?: return@mapNotNull null
            Comment(
                id = o.str("id") ?: return@mapNotNull null,
                userId = o.str("user_id").orEmpty(),
                artistId = o.str("artist_id"),
                name = o.str("name") ?: "Слушатель",
                avatar = o.str("avatar"),
                body = o.str("body").orEmpty(),
                createdAt = o.str("created_at").orEmpty(),
            )
        }
    }

    suspend fun addComment(text: String, postId: String? = null, trackId: String? = null) {
        val uid = userId() ?: throw SharedError("Войдите в аккаунт")
        val clean = text.trim().take(1000)
        if (clean.isEmpty()) throw SharedError("Напишите комментарий")
        val (s, resp) = db.call("comments", emptyMap(), {
            it.header("Prefer", "return=minimal").post(body {
                put("user_id", JsonPrimitive(uid))
                put("post_id", if (postId == null) JsonNull else JsonPrimitive(postId))
                put("track_id", if (trackId == null) JsonNull else JsonPrimitive(trackId))
                put("body", JsonPrimitive(clean))
            })
        }, auth = true)
        if (s !in 200..299) throw SharedError(if (resp.contains("too_often")) "Слишком много комментариев, попробуйте через час" else "Не получилось отправить")
    }

    suspend fun deleteComment(id: String) {
        val (s, _) = db.call("comments", mapOf("id" to "eq.$id"), { it.delete() }, auth = true)
        if (s !in 200..299) throw SharedError("Не получилось удалить")
    }

    /** Жалоба на анонс, комментарий или трек. Повтор той же жалобы (409) считается принятой. */
    suspend fun report(kind: String, targetId: String) {
        val uid = userId() ?: throw SharedError("Войдите в аккаунт")
        val (s, _) = db.call("reports", emptyMap(), {
            it.header("Prefer", "return=minimal").post(body {
                put("reporter_id", JsonPrimitive(uid))
                put("kind", JsonPrimitive(kind))
                put("target_id", JsonPrimitive(targetId))
            })
        }, auth = true)
        if (s !in 200..299 && s != 409) throw SharedError("Не получилось отправить жалобу")
    }

    suspend fun saveBio(artistId: String, bio: String) {
        val clean = bio.trim()
        val (s, _) = db.call("artists", mapOf("id" to "eq.$artistId"), {
            it.header("Prefer", "return=minimal").patch(body { put("bio", if (clean.isEmpty()) JsonNull else JsonPrimitive(clean)) })
        }, auth = true)
        if (s !in 200..299) throw SharedError("Не получилось сохранить")
    }
}
