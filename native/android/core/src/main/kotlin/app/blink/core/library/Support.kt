package app.blink.core.library

import app.blink.core.net.BlinkConfig
import app.blink.core.net.BlinkJson
import app.blink.core.net.TokenProvider
import app.blink.core.net.arr
import app.blink.core.net.obj
import app.blink.core.net.str
import app.blink.core.net.text
import app.blink.core.net.withCallTimeout
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

data class FaqItem(val id: String, val question: String, val answer: String, val keywords: String)

data class TicketRow(val id: String, val kind: String, val message: String, val status: String, val lastAuthor: String, val updatedAt: String)

data class TicketMessage(val id: String, val author: String, val body: String, val images: List<String>, val createdAt: String)

data class TicketView(val id: String, val kind: String, val message: String, val status: String, val images: List<String>, val autoQuestion: String?, val autoAnswer: String?, val messages: List<TicketMessage>)

data class TicketSent(val id: String, val autoQuestion: String?, val autoAnswer: String?)

/** Поддержка: частые вопросы, обращения и переписка (server/supportRoute.js). */
class SupportApi(http: OkHttpClient, private val config: BlinkConfig, private val tokens: TokenProvider?) {
    private val client = http.withCallTimeout(25)
    private val jsonType = "application/json".toMediaType()

    private suspend fun call(path: String, body: JsonObject?): JsonObject {
        val b = Request.Builder().url("${config.base}/api/support/$path").header("Accept", "application/json")
        tokens?.accessToken()?.let { b.header("Authorization", "Bearer $it") }
        if (body != null) b.post(BlinkJson.encodeToString(JsonObject.serializer(), body).toRequestBody(jsonType)) else b.get()
        val res = client.newCall(b.build()).text()
        val o = try {
            BlinkJson.parseToJsonElement(res.text).obj()
        } catch (_: Exception) {
            null
        }
        if (res.code !in 200..299) {
            throw SharedError(o?.str("error") ?: if (res.code == 404) "Поддержка на сервере ещё не обновлена" else "Сервер поддержки не ответил (${res.code}), попробуйте позже")
        }
        return o ?: JsonObject(emptyMap())
    }

    suspend fun faq(): List<FaqItem> =
        call("faq", null)["faq"].arr().orEmpty().mapNotNull { e ->
            val o = e.obj() ?: return@mapNotNull null
            FaqItem(o.str("id") ?: return@mapNotNull null, o.str("question").orEmpty(), o.str("answer").orEmpty(), o.str("keywords").orEmpty())
        }

    /** Новое обращение. Картинки идут как data URL (jpeg, до 1600 px). */
    suspend fun send(message: String, contact: String?, images: List<String> = emptyList()): TicketSent {
        val o = call("ticket", buildJsonObject {
            put("kind", JsonPrimitive("question"))
            put("message", JsonPrimitive(message))
            put("contact", if (contact.isNullOrBlank()) JsonNull else JsonPrimitive(contact))
            if (images.isNotEmpty()) put("images", JsonArray(images.map { JsonPrimitive(it) }))
        })
        val auto = o["auto"].obj()
        return TicketSent(o.str("id").orEmpty(), auto?.str("question"), auto?.str("answer"))
    }

    suspend fun mine(): List<TicketRow> =
        call("mine", null)["tickets"].arr().orEmpty().mapNotNull { e ->
            val o = e.obj() ?: return@mapNotNull null
            TicketRow(o.str("id") ?: return@mapNotNull null, o.str("kind").orEmpty(), o.str("message").orEmpty(), o.str("status").orEmpty(), o.str("last_author").orEmpty(), o.str("updated_at").orEmpty())
        }

    suspend fun open(id: String): TicketView {
        val o = call("ticket/$id", null)
        val t = o["ticket"].obj() ?: throw SharedError("Обращение не найдено")
        val auto = o["auto"].obj()
        return TicketView(
            id = t.str("id").orEmpty(),
            kind = t.str("kind").orEmpty(),
            message = t.str("message").orEmpty(),
            status = t.str("status").orEmpty(),
            images = urls(t["attachments"]),
            autoQuestion = auto?.str("question"),
            autoAnswer = auto?.str("answer"),
            messages = o["messages"].arr().orEmpty().mapNotNull { message(it.obj()) },
        )
    }

    suspend fun reply(id: String, body: String, images: List<String> = emptyList()): TicketMessage {
        val o = call("ticket/$id/message", buildJsonObject {
            put("body", JsonPrimitive(body))
            if (images.isNotEmpty()) put("images", JsonArray(images.map { JsonPrimitive(it) }))
        })
        return message(o["message"].obj()) ?: throw SharedError("Не получилось отправить")
    }

    suspend fun close(id: String) {
        call("ticket/$id/close", JsonObject(emptyMap()))
    }

    private fun message(o: JsonObject?): TicketMessage? {
        o ?: return null
        return TicketMessage(o.str("id") ?: return null, o.str("author").orEmpty(), o.str("body").orEmpty(), urls(o["attachments"]), o.str("created_at").orEmpty())
    }

    /** Вложения приходят то строками, то объектами с `url`. */
    private fun urls(e: kotlinx.serialization.json.JsonElement?): List<String> =
        e.arr().orEmpty().mapNotNull { x -> (x as? JsonPrimitive)?.takeIf { it.isString }?.content ?: x.obj()?.str("url") }

    companion object {
        private fun norm(s: String) = s.lowercase().replace('ё', 'е')

        /** Как на сервере: ответ, чьих ключевых слов в тексте больше всего. */
        fun bestAnswer(faq: List<FaqItem>, q: String): FaqItem? {
            val t = norm(q)
            var best: FaqItem? = null
            var score = 0
            for (f in faq) {
                val n = norm(f.keywords).split(',').map { it.trim() }.count { it.length > 1 && t.contains(it) }
                if (n > score) {
                    best = f
                    score = n
                }
            }
            return best
        }
    }
}
