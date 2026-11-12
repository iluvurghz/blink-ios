package app.blink.core.social

import app.blink.core.net.BlinkConfig
import app.blink.core.net.BlinkJson
import app.blink.core.net.KeyValue
import app.blink.core.net.TokenProvider
import app.blink.core.net.arr
import app.blink.core.net.bool
import app.blink.core.net.int
import app.blink.core.net.long
import app.blink.core.net.obj
import app.blink.core.net.parseObject
import app.blink.core.net.str
import app.blink.core.net.text
import app.blink.core.net.withCallTimeout
import java.time.OffsetDateTime
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

data class PlusPlan(val id: String, val label: String, val price: Int, val days: Int, val old: Int = 0, val tag: String = "") {
    /** Цена за месяц для сравнения: год делим на 12. */
    val monthly: Int get() = if (days >= 365) Math.round(price / 12.0).toInt() else price
}

data class PlusPerk(val icon: String, val title: String, val text: String)

data class PlusRow(val label: String, val free: Boolean, val plus: Boolean)

data class PlusTier(val id: Int, val name: String, val from: Int)

/** Что рассказывает страница Blink+: цены, плюсы, сравнение, лесенка «Хранителя». Админка правит это на сервере. */
data class PlusConfig(
    val title: String,
    val lead: String,
    val plans: List<PlusPlan>,
    val perks: List<PlusPerk>,
    val compare: List<PlusRow>,
    val tiers: List<PlusTier>,
) {
    /** Высшая ступень, до которой дотягивает сумма; 0, если ниже первой. */
    fun tierFor(total: Int): Int = tiers.fold(0) { t, x -> if (total >= x.from) x.id else t }

    companion object {
        /** Показывается сразу и без сети; версия сервера заменяет её, когда придёт. Совпадает с `PLUS_FALLBACK` сайта. */
        val FALLBACK = PlusConfig(
            title = "Blink+",
            lead = "Музыка в Blink остаётся бесплатной. Blink+ добавляет то, что нужно каждый день, и отмечает вас в профиле.",
            plans = listOf(PlusPlan("month", "Месяц", 149, 30), PlusPlan("year", "Год", 1290, 365)),
            perks = listOf(
                PlusPerk("download", "Музыка без интернета", "Сохраняйте треки и плейлисты на устройство. Играют в метро, самолёте и без сети."),
                PlusPerk("user", "Орбита у аватарки", "Тонкий световой круг у вашей аватарки и значок Blink+ рядом с ником. Его видят все."),
                PlusPerk("bolt", "Ранний доступ", "Новые функции приходят к подписчикам первыми, пока мы их дорабатываем."),
                PlusPerk("heart", "Вы держите Blink", "Подписка оплачивает серверы и помогает выпускать обновления быстрее."),
            ),
            compare = listOf(
                PlusRow("Вся музыка и Вспышка", true, true),
                PlusRow("Плейлисты и перенос музыки", true, true),
                PlusRow("Сохранение треков без интернета", false, true),
                PlusRow("Орбита у аватарки и значок", false, true),
                PlusRow("Ранний доступ к новому", false, true),
            ),
            tiers = listOf(PlusTier(1, "Хранитель", 50), PlusTier(2, "Хранитель II", 1000), PlusTier(3, "Хранитель III", 5000)),
        )

        fun parse(o: JsonObject): PlusConfig? {
            val plans = o["plans"].arr().orEmpty().mapNotNull { e ->
                val p = e.obj() ?: return@mapNotNull null
                PlusPlan(p.str("id") ?: return@mapNotNull null, p.str("label").orEmpty(), p.int("price") ?: return@mapNotNull null, p.int("days") ?: 30, p.int("old") ?: 0, p.str("tag").orEmpty())
            }
            val tiers = o["tiers"].arr().orEmpty().mapIndexedNotNull { i, e ->
                val t = e.obj() ?: return@mapIndexedNotNull null
                PlusTier(i + 1, t.str("name") ?: return@mapIndexedNotNull null, t.int("from") ?: return@mapIndexedNotNull null)
            }
            if (plans.isEmpty() || tiers.isEmpty()) return null
            return PlusConfig(
                title = o.str("title") ?: "Blink+",
                lead = o.str("lead").orEmpty(),
                plans = plans,
                perks = o["perks"].arr().orEmpty().mapNotNull { e ->
                    val p = e.obj() ?: return@mapNotNull null
                    PlusPerk(p.str("icon") ?: "heart", p.str("title") ?: return@mapNotNull null, p.str("text").orEmpty())
                },
                compare = o["compare"].arr().orEmpty().mapNotNull { e ->
                    val r = e.obj() ?: return@mapNotNull null
                    PlusRow(r.str("label") ?: return@mapNotNull null, r.bool("free") == true, r.bool("plus") != false)
                },
                tiers = tiers,
            )
        }
    }
}

/** Ответ `/api/plus/me`. */
data class PlusMe(val active: Boolean, val untilMs: Long?, val supporterSince: String?, val keeperTier: Int, val donated: Int)

sealed interface PromoResult {
    /** Код на скидку: покажем процент, применится при оплате. */
    data class Discount(val code: String, val percent: Int) : PromoResult

    /** Код на дни Blink+: сработал сразу. */
    data class Days(val code: String, val days: Int, val untilMs: Long?) : PromoResult
}

class PlusException(message: String) : Exception(message)

interface PlusService {
    suspend fun config(): PlusConfig?

    suspend fun me(): PlusMe?

    suspend fun promo(code: String): PromoResult

    /** Ссылка на оплату тарифа (страница платёжки открывается в браузере). */
    suspend fun checkout(plan: String, promo: String?): String

    suspend fun donate(amountRub: Int): String
}

class PlusApi(http: OkHttpClient, private val config: BlinkConfig, private val tokens: TokenProvider?, private val cache: KeyValue? = null) : PlusService {
    private val client = http.withCallTimeout(20)
    private val jsonType = "application/json".toMediaType()

    /** Последние настройки с сервера или запасные: страница открывается сразу и без сети. */
    fun cached(): PlusConfig = cache?.get(CACHE_KEY)?.let { parseObject(it) }?.let(PlusConfig::parse) ?: PlusConfig.FALLBACK

    private suspend fun call(path: String, body: JsonObject?): Pair<Int, JsonObject?> {
        val b = Request.Builder().url("${config.base}/api/plus/$path").header("Accept", "application/json")
        tokens?.accessToken()?.let { b.header("Authorization", "Bearer $it") }
        if (body != null) b.post(BlinkJson.encodeToString(JsonObject.serializer(), body).toRequestBody(jsonType)) else b.get()
        val res = client.newCall(b.build()).text()
        return res.code to parseObject(res.text)
    }

    override suspend fun config(): PlusConfig? {
        val (code, o) = call("config", null)
        val parsed = if (code == 200 && o != null) PlusConfig.parse(o) else null
        if (parsed != null) cache?.put(CACHE_KEY, BlinkJson.encodeToString(JsonObject.serializer(), o!!))
        return parsed
    }

    override suspend fun me(): PlusMe? {
        val (code, o) = call("me", null)
        if (code != 200 || o == null) return null
        val until = o.str("plus_until")
        return PlusMe(
            active = o.bool("active") == true,
            untilMs = until?.let { runCatching { OffsetDateTime.parse(it).toInstant().toEpochMilli() }.getOrNull() },
            supporterSince = o.str("supporter_since"),
            keeperTier = o.int("keeper_tier") ?: 0,
            donated = (o.long("donated") ?: 0).toInt(),
        )
    }

    override suspend fun promo(code: String): PromoResult {
        val (status, o) = call("promo", buildJsonObject { put("code", code) })
        if (status != 200 || o == null) throw PlusException(o?.str("error") ?: "Не получилось, попробуйте ещё раз")
        val c = o.str("code").orEmpty()
        return if (o.str("kind") == "discount") {
            PromoResult.Discount(c, o.int("percent") ?: 0)
        } else {
            PromoResult.Days(c, o.int("days") ?: 0, o.str("plus_until")?.let { runCatching { OffsetDateTime.parse(it).toInstant().toEpochMilli() }.getOrNull() })
        }
    }

    override suspend fun checkout(plan: String, promo: String?): String {
        val (status, o) = call(
            "checkout",
            buildJsonObject {
                put("plan", plan)
                if (!promo.isNullOrBlank()) put("code", promo)
            },
        )
        return payUrl(status, o)
    }

    override suspend fun donate(amountRub: Int): String {
        val (status, o) = call("donate", buildJsonObject { put("amount", amountRub) })
        return payUrl(status, o)
    }

    private fun payUrl(status: Int, o: JsonObject?): String {
        val url = o?.str("pay_url")
        if (status == 200 && !url.isNullOrEmpty()) return url
        throw PlusException(o?.str("error") ?: "Не получилось, попробуйте ещё раз")
    }

    private companion object {
        const val CACHE_KEY = "plus.cfg"
    }
}
