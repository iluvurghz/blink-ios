package app.blink.core.net

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Response

/** Откуда берём токен для запросов к серверу Blink. `null` значит «не вошёл». */
fun interface TokenProvider {
    suspend fun accessToken(): String?
}

/** Адреса сервисов. Ключ Supabase публичный, но в репозиторий его не кладём: он приходит при сборке. */
data class BlinkConfig(
    val baseUrl: String = "https://blinkmusic.cc",
    val supabaseUrl: String = "https://wjyohhvpqvfhyhrrbhgc.supabase.co",
    val supabaseAnonKey: String = "",
) {
    val base: String get() = baseUrl.trimEnd('/')
    val supabase: String get() = supabaseUrl.trimEnd('/')

    /** Зеркало Supabase на сайте (nginx в РФ): supabase.co режут операторы. */
    val supabaseMirror: String get() = "$base/sb"

    /** Относительные ссылки сервера и утёкшие 127.0.0.1 приводим к адресу сайта (как `toAbsolute` в вебе). */
    fun absolute(url: String?): String? {
        if (url.isNullOrEmpty()) return null
        LOCAL.find(url)?.let { return base + url.substring(it.value.length) }
        if (url.startsWith("//")) return "https:$url"
        if (url.startsWith("/")) return base + url
        return url
    }

    private companion object {
        val LOCAL = Regex("^https?://(127\\.0\\.0\\.1|localhost)(:\\d+)?")
    }
}

data class HttpText(val code: Int, val text: String, val headers: Map<String, String>)

/**
 * Выполняет запрос на IO-потоке и отменяет сетевой вызов, когда отменяют корутину.
 * Тело ответа читает `block` до закрытия ответа.
 */
suspend fun <T> Call.run(block: (Response) -> T): T =
    withContext(Dispatchers.IO) {
        coroutineScope {
            val call = this@run
            val watcher = launch(start = CoroutineStart.UNDISPATCHED) {
                try {
                    awaitCancellation()
                } finally {
                    call.cancel()
                }
            }
            try {
                call.execute().use(block)
            } finally {
                watcher.cancel()
            }
        }
    }

/** Короткий запрос с текстовым ответом (JSON). Сетевые сбои приходят как IOException. */
suspend fun Call.text(): HttpText =
    run { r ->
        val headers = HashMap<String, String>()
        for (i in 0 until r.headers.size) headers[r.headers.name(i).lowercase()] = r.headers.value(i)
        HttpText(r.code, r.body?.string() ?: "", headers)
    }

fun OkHttpClient.withCallTimeout(seconds: Long): OkHttpClient = newBuilder().callTimeout(seconds, TimeUnit.SECONDS).build()

internal fun IOException.isTimeout(): Boolean =
    this is java.net.SocketTimeoutException || (this is java.io.InterruptedIOException && (message ?: "").contains("timeout", ignoreCase = true))
