package app.blink.core.net

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

/** Единый разбор JSON: сервер может добавить поля, старые приложения их не ломают. */
val BlinkJson: Json = Json {
    ignoreUnknownKeys = true
    isLenient = true
    coerceInputValues = true
    explicitNulls = false
    encodeDefaults = true
}

internal fun JsonElement?.obj(): JsonObject? = this as? JsonObject
internal fun JsonElement?.arr(): JsonArray? = this as? JsonArray

internal fun JsonObject.str(name: String): String? {
    val p = this[name] as? JsonPrimitive ?: return null
    return if (p.isString) p.content else p.contentOrNull?.takeIf { it != "null" }
}

internal fun JsonObject.long(name: String): Long? {
    val p = this[name] as? JsonPrimitive ?: return null
    return p.longOrNull ?: p.doubleOrNull?.toLong()
}

internal fun JsonObject.int(name: String): Int? = long(name)?.toInt()

internal fun JsonObject.bool(name: String): Boolean? = (this[name] as? JsonPrimitive)?.booleanOrNull

internal fun parseObject(text: String): JsonObject? =
    try {
        BlinkJson.parseToJsonElement(text) as? JsonObject
    } catch (_: Exception) {
        null
    }
