package app.blink.core.offline

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

enum class MetaKind(val suffix: String) {
    JOB(".job.json"),
    ENTRY(".json"),
}

data class Usage(val bytes: Long, val free: Long)

/**
 * Хранилище офлайна: то, что платформа реализует под контракт.
 * Все ключи здесь это `key` (например `blink:<uuid>`), имена файлов выводит сама реализация.
 */
interface Storage {
    fun open()

    /** Запись метаданных атомарна: целиком новая версия или целиком старая. */
    fun putMeta(kind: MetaKind, key: String, json: String)
    fun getMeta(kind: MetaKind, key: String): String?
    fun delMeta(kind: MetaKind, key: String)
    fun listMeta(kind: MetaKind): List<String>

    /** Длина `.part` после сброса на диск: это и есть смещение для Range. */
    fun partSize(key: String): Long
    fun appendPart(key: String, bytes: ByteArray, off: Int, len: Int)
    fun truncatePart(key: String, size: Long)
    fun listParts(): List<String>
    fun deletePart(key: String)

    /** Атомарно превращает `.part` в готовый файл. NO_SPACE при нехватке места. */
    fun commit(key: String)
    fun hasAudio(key: String): Boolean
    fun audioSize(key: String): Long
    fun listAudio(): List<String>

    /** Путь для плеера (seekable) или null, если файла нет. */
    fun audioPath(key: String): String?

    /** Удаляет только готовый файл (сироту без записи манифеста). */
    fun deleteAudio(key: String)
    fun remove(key: String)
    fun usage(): Usage
    fun clear()
}

/**
 * Файловая реализация. Раскладка в корне:
 *  - `<fkey>`            готовый файл (появляется только через commit)
 *  - `<fkey>.part`       дозапись, длина = смещение Range
 *  - `<fkey>.job.json`   задача (очередь переживает перезапуск)
 *  - `<fkey>.json`       запись манифеста (пишется последней)
 */
class FileStorage(private val root: File) : Storage {
    private val writers = HashMap<String, FileOutputStream>()

    override fun open() {
        if (!root.isDirectory && !root.mkdirs() && !root.isDirectory) throw IOException("cannot create ${root.path}")
        // хвосты от упавшей записи метаданных
        root.listFiles()?.forEach { if (it.name.endsWith(".tmp")) it.delete() }
    }

    private fun f(key: String, suffix: String = ""): File = File(root, Key.fkey(key) + suffix)

    // ---------- метаданные ----------

    @Synchronized
    override fun putMeta(kind: MetaKind, key: String, json: String) {
        val dst = f(key, kind.suffix)
        val tmp = File(root, dst.name + ".tmp")
        FileOutputStream(tmp).use { out ->
            out.write(json.toByteArray(Charsets.UTF_8))
            out.fd.sync()
        }
        moveAtomic(tmp, dst)
    }

    override fun getMeta(kind: MetaKind, key: String): String? {
        val file = f(key, kind.suffix)
        return try {
            if (file.isFile) file.readText(Charsets.UTF_8) else null
        } catch (_: IOException) {
            null
        }
    }

    @Synchronized
    override fun delMeta(kind: MetaKind, key: String) {
        f(key, kind.suffix).delete()
    }

    override fun listMeta(kind: MetaKind): List<String> {
        val names = root.list() ?: return emptyList()
        val out = ArrayList<String>()
        for (n in names) {
            if (!n.endsWith(kind.suffix)) continue
            // ".json" заканчивает и ".job.json": различаем по полному суффиксу
            if (kind == MetaKind.ENTRY && n.endsWith(MetaKind.JOB.suffix)) continue
            val key = Key.fromFkey(n.removeSuffix(kind.suffix)) ?: continue
            out.add(key)
        }
        return out.sorted()
    }

    // ---------- .part ----------

    private fun writer(key: String): FileOutputStream =
        writers.getOrPut(key) { FileOutputStream(f(key, ".part"), true) }

    @Synchronized
    private fun closeWriter(key: String) {
        writers.remove(key)?.let {
            try {
                it.flush()
                it.fd.sync()
            } finally {
                it.close()
            }
        }
    }

    @Synchronized
    override fun partSize(key: String): Long {
        closeWriter(key) // I4: перед чтением длины сброс на диск
        val file = f(key, ".part")
        return if (file.isFile) file.length() else 0L
    }

    @Synchronized
    override fun appendPart(key: String, bytes: ByteArray, off: Int, len: Int) {
        try {
            writer(key).write(bytes, off, len)
        } catch (e: IOException) {
            closeQuietly(key)
            throw mapIo(e)
        }
    }

    @Synchronized
    override fun truncatePart(key: String, size: Long) {
        closeQuietly(key)
        val file = f(key, ".part")
        if (!file.isFile) return
        if (size <= 0L) {
            file.delete()
        } else {
            RandomAccessFile(file, "rw").use { it.setLength(size) }
        }
    }

    @Synchronized
    /** Только для проверок в тестах: контракт v1 (поправка 2) убрал чтение .part из адаптера. */
    fun readPart(key: String, start: Long, end: Long): ByteArray {
        closeWriter(key)
        val file = f(key, ".part")
        if (!file.isFile || end <= start) return ByteArray(0)
        val len = (minOf(end, file.length()) - start).coerceAtLeast(0).toInt()
        val buf = ByteArray(len)
        RandomAccessFile(file, "r").use { raf ->
            raf.seek(start)
            raf.readFully(buf)
        }
        return buf
    }

    override fun listParts(): List<String> =
        (root.list() ?: emptyArray()).filter { it.endsWith(".part") }.mapNotNull { Key.fromFkey(it.removeSuffix(".part")) }.sorted()

    @Synchronized
    override fun deletePart(key: String) {
        closeQuietly(key)
        f(key, ".part").delete()
    }

    private fun closeQuietly(key: String) {
        try {
            closeWriter(key)
        } catch (_: IOException) {
        }
    }

    // ---------- готовые файлы ----------

    @Synchronized
    override fun commit(key: String) {
        closeWriter(key)
        val part = f(key, ".part")
        val dst = f(key)
        if (!part.isFile) throw OfflineException(OfflineCode.SOURCE_ERROR, "no_part")
        try {
            moveAtomic(part, dst)
        } catch (e: IOException) {
            throw mapIo(e)
        }
    }

    override fun hasAudio(key: String): Boolean = f(key).isFile

    override fun audioSize(key: String): Long = f(key).let { if (it.isFile) it.length() else 0L }

    override fun listAudio(): List<String> =
        (root.list() ?: emptyArray())
            .filter { !it.contains('.') }
            .mapNotNull { Key.fromFkey(it) }
            .sorted()

    override fun audioPath(key: String): String? = f(key).takeIf { it.isFile }?.absolutePath

    override fun deleteAudio(key: String) {
        f(key).delete()
    }

    @Synchronized
    override fun remove(key: String) {
        // I2: сначала запись, потом звук. Упавшее посередине оставит сироту, а не битую запись.
        closeQuietly(key)
        f(key, MetaKind.ENTRY.suffix).delete()
        f(key, MetaKind.JOB.suffix).delete()
        f(key, ".part").delete()
        f(key).delete()
    }

    override fun usage(): Usage {
        var sum = 0L
        root.listFiles()?.forEach { if (it.isFile && !it.name.contains('.')) sum += it.length() }
        return Usage(sum, root.usableSpace)
    }

    @Synchronized
    override fun clear() {
        writers.keys.toList().forEach { closeQuietly(it) }
        root.listFiles()?.forEach { if (it.isFile) it.delete() }
    }

    private fun moveAtomic(from: File, to: File) {
        try {
            Files.move(from.toPath(), to.toPath(), StandardCopyOption.ATOMIC_MOVE)
        } catch (_: AtomicMoveNotSupportedException) {
            Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }

    companion object {
        /** Нехватку места ОС отдаёт обычным IOException с текстом; определяем по нему. */
        fun mapIo(e: IOException): OfflineException {
            val m = (e.message ?: "").lowercase()
            return if ("no space" in m || "enospc" in m || "quota" in m || "disk full" in m) {
                OfflineException(OfflineCode.NO_SPACE, cause = e)
            } else {
                OfflineException(OfflineCode.SOURCE_ERROR, "io", e.message, e)
            }
        }
    }
}
