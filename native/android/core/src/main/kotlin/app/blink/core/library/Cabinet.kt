package app.blink.core.library

import app.blink.core.net.BlinkConfig
import app.blink.core.net.BlinkJson
import app.blink.core.net.TokenProvider
import app.blink.core.net.arr
import app.blink.core.net.bool
import app.blink.core.net.long
import app.blink.core.net.obj
import app.blink.core.net.str
import app.blink.core.net.text
import app.blink.core.net.withCallTimeout
import java.io.File
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okio.BufferedSink
import okio.buffer
import okio.source

data class ArtistMe(val id: String, val name: String, val handle: String?, val bio: String?, val offerAccepted: Boolean)

data class MyTrack(
    val id: String,
    val title: String,
    val releaseTitle: String,
    val status: String,
    val cover: String?,
    val releaseDate: String,
    val explicit: Boolean,
    val streamsTotal: Long,
    val streamsMonth: Long,
)

/** Поля формы «Новый трек», как на сайте (ui/Profile.jsx, UploadForm). */
data class UploadDraft(
    val title: String = "",
    val releaseTitle: String = "",
    val authors: String = "",
    val phonogramMaker: String = "",
    val year: String = "",
    val genre: String = "",
    val language: String = "",
    val releaseDate: String = "",
    val samples: String = "",
    val lyrics: String = "",
    val explicit: Boolean = false,
    val aiUsed: Boolean = false,
    val rights: Boolean = false,
)

class UploadFile(val name: String, val mime: String, val file: File)

/** Кабинет артиста: профиль, оферта, свои релизы и загрузка нового трека. */
class CabinetApi(http: OkHttpClient, private val config: BlinkConfig, private val tokens: TokenProvider?) {
    private val client = http.withCallTimeout(25)
    // Загрузка идёт долго: общий таймаут не ставим, только на простой.
    private val uploader = http.newBuilder().callTimeout(0, java.util.concurrent.TimeUnit.SECONDS).readTimeout(120, java.util.concurrent.TimeUnit.SECONDS).writeTimeout(120, java.util.concurrent.TimeUnit.SECONDS).build()
    private val jsonType = "application/json".toMediaType()

    private suspend fun send(c: OkHttpClient, b: Request.Builder): Pair<Int, JsonObject?> {
        tokens?.accessToken()?.let { b.header("Authorization", "Bearer $it") }
        val res = c.newCall(b.header("Accept", "application/json").build()).text()
        val o = try {
            BlinkJson.parseToJsonElement(res.text).obj()
        } catch (_: Exception) {
            null
        }
        return res.code to o
    }

    private fun fail(code: Int, o: JsonObject?, fallback: String): Nothing = throw SharedError(o?.str("error") ?: if (code == 401) "Войдите в аккаунт" else fallback)

    /** Профиль артиста или null, если оферту ещё не принимали. */
    suspend fun me(): ArtistMe? {
        val (code, o) = send(client, Request.Builder().url("${config.base}/api/artist/me").get())
        if (code !in 200..299) fail(code, o, "Не получилось открыть кабинет")
        val a = o?.get("artist").obj() ?: return null
        return ArtistMe(a.str("id") ?: return null, a.str("name").orEmpty(), a.str("handle"), a.str("bio"), !a.str("offer_accepted_at").isNullOrEmpty())
    }

    suspend fun acceptOffer(name: String): ArtistMe {
        val body = buildJsonObject {
            put("name", JsonPrimitive(name.trim()))
            put("accept", JsonPrimitive(true))
        }
        val (code, o) = send(client, Request.Builder().url("${config.base}/api/artist/accept").post(BlinkJson.encodeToString(JsonObject.serializer(), body).toRequestBody(jsonType)))
        if (code !in 200..299) fail(code, o, "Не получилось сохранить профиль")
        val a = o?.get("artist").obj() ?: throw SharedError("Не получилось сохранить профиль")
        return ArtistMe(a.str("id").orEmpty(), a.str("name").orEmpty(), a.str("handle"), a.str("bio"), true)
    }

    suspend fun mine(): List<MyTrack> {
        val (code, o) = send(client, Request.Builder().url("${config.base}/api/tracks/mine").get())
        if (code !in 200..299) fail(code, o, "Не получилось загрузить релизы")
        return o?.get("tracks").arr().orEmpty().mapNotNull { e ->
            val t = e.obj() ?: return@mapNotNull null
            val s = t["streams"].obj()
            MyTrack(
                id = t.str("id") ?: return@mapNotNull null,
                title = t.str("title").orEmpty(),
                releaseTitle = t.str("release_title").orEmpty(),
                status = t.str("status").orEmpty(),
                cover = t.str("cover_url"),
                releaseDate = t.str("release_date").orEmpty(),
                explicit = t.bool("explicit") == true,
                streamsTotal = s?.long("total") ?: 0,
                streamsMonth = s?.long("this_month") ?: 0,
            )
        }
    }

    suspend fun takedown(id: String) {
        val (code, o) = send(client, Request.Builder().url("${config.base}/api/tracks/$id").delete())
        if (code !in 200..299) fail(code, o, "Не получилось снять трек")
    }

    /** Что не заполнено, по-русски; null, если можно отправлять. Те же поля, что проверяет сервер. */
    fun check(d: UploadDraft, audio: UploadFile?, cover: UploadFile?): String? {
        if (audio == null) return "Прикрепите аудиофайл"
        if (cover == null) return "Прикрепите обложку"
        val required = listOf(
            "Название трека" to d.title, "Альбом или сингл" to d.releaseTitle, "Кто записал" to d.phonogramMaker,
            "Год" to d.year, "Жанр" to d.genre, "Язык" to d.language, "Дата релиза" to d.releaseDate,
        )
        for ((label, v) in required) if (v.isBlank()) return "Не заполнено поле «$label»"
        if (authorList(d.authors).isEmpty()) return "Укажите авторов музыки и текста"
        if (!d.rights) return "Подтвердите права на трек"
        return null
    }

    private fun authorList(s: String) = s.split(',').map { it.trim() }.filter { it.isNotEmpty() }

    /** Загрузить трек. [onProgress] получает долю от 0 до 1. Возвращает id нового релиза. */
    suspend fun upload(d: UploadDraft, audio: UploadFile, cover: UploadFile, onProgress: (Double) -> Unit = {}): String {
        check(d, audio, cover)?.let { throw SharedError(it) }
        val authors = JsonArray(authorList(d.authors).map { n ->
            buildJsonObject {
                put("name", JsonPrimitive(n))
                put("role", JsonPrimitive("музыка и текст"))
            }
        })
        val form = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("title", d.title.trim())
            .addFormDataPart("release_title", d.releaseTitle.trim())
            .addFormDataPart("authors", BlinkJson.encodeToString(JsonArray.serializer(), authors))
            .addFormDataPart("phonogram_maker", d.phonogramMaker.trim())
            .addFormDataPart("year", d.year.trim())
            .addFormDataPart("genre", d.genre.trim())
            .addFormDataPart("language", d.language.trim())
            .addFormDataPart("release_date", d.releaseDate.trim())
            .addFormDataPart("samples", d.samples)
            .addFormDataPart("lyrics", d.lyrics)
            .addFormDataPart("explicit", d.explicit.toString())
            .addFormDataPart("ai_used", d.aiUsed.toString())
            .addFormDataPart("rights", d.rights.toString())
            .addFormDataPart("audio", audio.name, ProgressBody(audio.file, audio.mime))
            .addFormDataPart("cover", cover.name, ProgressBody(cover.file, cover.mime))
            .build()
        val total = form.contentLength().coerceAtLeast(1)
        val body = object : RequestBody() {
            override fun contentType() = form.contentType()
            override fun contentLength() = total
            override fun writeTo(sink: BufferedSink) {
                val counting = object : okio.ForwardingSink(sink) {
                    var written = 0L
                    override fun write(source: okio.Buffer, byteCount: Long) {
                        super.write(source, byteCount)
                        written += byteCount
                        onProgress((written.toDouble() / total).coerceIn(0.0, 1.0))
                    }
                }
                val buffered = counting.buffer()
                form.writeTo(buffered)
                buffered.flush()
            }
        }
        val (code, o) = send(uploader, Request.Builder().url("${config.base}/api/tracks").post(body))
        if (code !in 200..299) fail(code, o, "Не получилось загрузить")
        onProgress(1.0)
        return o?.get("track").obj()?.str("id").orEmpty()
    }

    private class ProgressBody(private val file: File, private val mime: String) : RequestBody() {
        override fun contentType() = mime.toMediaType()
        override fun contentLength() = file.length()
        override fun writeTo(sink: BufferedSink) {
            file.inputStream().use { sink.writeAll(it.source()) }
        }
    }
}
