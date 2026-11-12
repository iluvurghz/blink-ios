package app.blink.core.offline

import app.blink.core.net.BlinkJson
import app.blink.core.net.parseObject
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonObject

/** Запись манифеста schema:1. Существует ТОЛЬКО для полностью проверенного файла. */
@Serializable
data class ManifestEntry(
    val schema: Int = 1,
    val key: String,
    val source: String,
    val id: String,
    val title: String,
    val artist: String,
    val album: String = "",
    val cover: String = "",
    val duration: Int = 0,
    val bytes: Long,
    val mime: String? = null,
    val etag: String? = null,
    val status: String = "saved",
    val savedAt: Long,
    val lastPlayedAt: Long? = null,
    val offlineAllowed: Boolean = true,
    /** Под будущее шифрование файлов на диске. */
    val enc: String? = null,
    /** Непрозрачная копия объекта трека приложения (форма как на сайте). */
    val track: JsonObject? = null,
) {
    fun encode(): String = BlinkJson.encodeToString(this)

    companion object {
        fun decode(text: String): ManifestEntry? =
            try {
                BlinkJson.decodeFromString<ManifestEntry>(text).takeIf { it.schema == 1 && it.status == "saved" }
            } catch (_: Exception) {
                null
            }
    }
}

enum class Stage { QUEUED, RESOLVING, DOWNLOADING, VERIFYING, COMMITTING, FAILED }

/** Метаданные трека, нужные задаче и будущей записи манифеста. */
@Serializable
data class JobMeta(
    val title: String,
    val artist: String,
    val album: String = "",
    val cover: String = "",
    val duration: Int = 0,
    val offlineAllowed: Boolean = true,
    val track: JsonObject? = null,
)

/** Файл `<fkey>.job.json`: очередь переживает перезапуск. */
@Serializable
data class OfflineJob(
    val schema: Int = 1,
    val key: String,
    val source: String,
    val id: String,
    val meta: JobMeta,
    val etag: String? = null,
    val total: Long? = null,
    val mime: String? = null,
    val state: String = Stage.QUEUED.name,
    val attempts: Int = 0,
    val code: String? = null,
    val reason: String? = null,
    val failedAt: Long? = null,
    val createdAt: Long,
) {
    val stage: Stage get() = runCatching { Stage.valueOf(state) }.getOrDefault(Stage.QUEUED)
    val failure: OfflineCode? get() = code?.let { c -> runCatching { OfflineCode.valueOf(c) }.getOrNull() }

    fun encode(): String = BlinkJson.encodeToString(this)

    companion object {
        fun decode(text: String): OfflineJob? =
            try {
                BlinkJson.decodeFromString<OfflineJob>(text).takeIf { it.schema == 1 }
            } catch (_: Exception) {
                null
            }
    }
}

internal fun jsonObjectOrNull(text: String?): JsonObject? = text?.let { parseObject(it) }
