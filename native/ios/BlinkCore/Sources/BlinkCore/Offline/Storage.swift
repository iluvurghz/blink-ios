import Foundation

public enum MetaKind: Sendable {
    case job
    case entry

    public var suffix: String {
        switch self {
        case .job: return ".job.json"
        case .entry: return ".json"
        }
    }
}

public struct Usage: Equatable, Sendable {
    public let bytes: Int64
    public let free: Int64

    public init(bytes: Int64, free: Int64) {
        self.bytes = bytes
        self.free = free
    }
}

/// Хранилище офлайна: то, что платформа реализует под контракт.
/// Все ключи здесь это `key` (например `blink:<uuid>`), имена файлов выводит сама реализация.
public protocol Storage: AnyObject, Sendable {
    func open() throws

    /// Запись метаданных атомарна: целиком новая версия или целиком старая.
    func putMeta(_ kind: MetaKind, _ key: String, _ json: String) throws
    func getMeta(_ kind: MetaKind, _ key: String) -> String?
    func delMeta(_ kind: MetaKind, _ key: String)
    func listMeta(_ kind: MetaKind) -> [String]

    /// Длина `.part` после сброса на диск: это и есть смещение для Range.
    func partSize(_ key: String) -> Int64
    func appendPart(_ key: String, _ data: Data) throws
    func truncatePart(_ key: String, size: Int64)
    func listParts() -> [String]
    func deletePart(_ key: String)

    /// Атомарно превращает `.part` в готовый файл. NO_SPACE при нехватке места.
    func commit(_ key: String) throws
    func hasAudio(_ key: String) -> Bool
    func audioSize(_ key: String) -> Int64
    func listAudio() -> [String]

    /// Путь для плеера (seekable) или nil, если файла нет.
    func audioPath(_ key: String) -> String?

    /// Удаляет только готовый файл (сироту без записи манифеста).
    func deleteAudio(_ key: String)
    func remove(_ key: String)
    func usage() -> Usage
    func clear()
}

/// Файловая реализация. Раскладка в корне:
///  - `<fkey>`            готовый файл (появляется только через commit)
///  - `<fkey>.part`       дозапись, длина = смещение Range
///  - `<fkey>.job.json`   задача (очередь переживает перезапуск)
///  - `<fkey>.json`       запись манифеста (пишется последней)
open class FileStorage: Storage, @unchecked Sendable {
    private let root: URL
    private let lock = NSRecursiveLock()
    private var writers: [String: FileHandle] = [:]
    private let fm = FileManager.default

    public init(root: URL) {
        self.root = root
    }

    public func open() throws {
        var isDir: ObjCBool = false
        if !(fm.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue) {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        // хвосты от упавшей записи метаданных
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasSuffix(".tmp") {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
        #if os(iOS)
        // Скачанное не должно уезжать в резервную копию iCloud.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = root
        try? dir.setResourceValues(values)
        #endif
    }

    private func url(_ key: String, _ suffix: String = "") -> URL {
        return root.appendingPathComponent(Key.fkey(key) + suffix)
    }

    // ---------- метаданные ----------

    public func putMeta(_ kind: MetaKind, _ key: String, _ json: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let dst = url(key, kind.suffix)
        let tmp = root.appendingPathComponent(dst.lastPathComponent + ".tmp")
        do {
            if !fm.createFile(atPath: tmp.path, contents: nil) {
                throw NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: nil)
            }
            let h = try FileHandle(forWritingTo: tmp)
            do {
                try h.write(contentsOf: Data(json.utf8))
                try h.synchronize()
                try h.close()
            } catch {
                try? h.close()
                throw error
            }
            try moveAtomic(tmp, dst)
        } catch {
            try? fm.removeItem(at: tmp)
            throw FileStorage.mapIo(error)
        }
    }

    public func getMeta(_ kind: MetaKind, _ key: String) -> String? {
        let u = url(key, kind.suffix)
        guard fm.fileExists(atPath: u.path) else { return nil }
        return try? String(contentsOf: u, encoding: .utf8)
    }

    public func delMeta(_ kind: MetaKind, _ key: String) {
        lock.lock()
        defer { lock.unlock() }
        try? fm.removeItem(at: url(key, kind.suffix))
    }

    public func listMeta(_ kind: MetaKind) -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        var out: [String] = []
        for n in names {
            if !n.hasSuffix(kind.suffix) { continue }
            // ".json" заканчивает и ".job.json": различаем по полному суффиксу
            if kind == .entry && n.hasSuffix(MetaKind.job.suffix) { continue }
            let stem = String(n.dropLast(kind.suffix.count))
            if let key = Key.fromFkey(stem) { out.append(key) }
        }
        return out.sorted()
    }

    // ---------- .part ----------

    private func writer(_ key: String) throws -> FileHandle {
        if let w = writers[key] { return w }
        let u = url(key, ".part")
        if !fm.fileExists(atPath: u.path) {
            if !fm.createFile(atPath: u.path, contents: nil) {
                throw NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: nil)
            }
        }
        let h = try FileHandle(forWritingTo: u)
        _ = try h.seekToEnd()
        writers[key] = h
        return h
    }

    private func closeWriter(_ key: String) throws {
        guard let h = writers.removeValue(forKey: key) else { return }
        do {
            try h.synchronize()
        } catch {
            try? h.close()
            throw error
        }
        try h.close()
    }

    private func closeQuietly(_ key: String) {
        try? closeWriter(key)
    }

    private func fileSize(_ u: URL) -> Int64 {
        guard fm.fileExists(atPath: u.path), let h = try? FileHandle(forReadingFrom: u) else { return 0 }
        defer { try? h.close() }
        guard let end = try? h.seekToEnd() else { return 0 }
        return Int64(end)
    }

    public func partSize(_ key: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        closeQuietly(key) // I4: перед чтением длины сброс на диск
        return fileSize(url(key, ".part"))
    }

    open func appendPart(_ key: String, _ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            let h = try writer(key)
            try h.write(contentsOf: data)
        } catch {
            closeQuietly(key)
            throw FileStorage.mapIo(error)
        }
    }

    public func truncatePart(_ key: String, size: Int64) {
        lock.lock()
        defer { lock.unlock() }
        closeQuietly(key)
        let u = url(key, ".part")
        guard fm.fileExists(atPath: u.path) else { return }
        if size <= 0 {
            try? fm.removeItem(at: u)
        } else if let h = try? FileHandle(forUpdating: u) {
            try? h.truncate(atOffset: UInt64(size))
            try? h.close()
        }
    }

    /// Только для проверок в тестах: контракт v1 (поправка 2) убрал чтение .part из адаптера.
    public func readPart(_ key: String, start: Int64, end: Int64) -> Data {
        lock.lock()
        defer { lock.unlock() }
        closeQuietly(key)
        let u = url(key, ".part")
        guard end > start, fm.fileExists(atPath: u.path), let h = try? FileHandle(forReadingFrom: u) else { return Data() }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: UInt64(max(0, start)))
            return try h.read(upToCount: Int(end - start)) ?? Data()
        } catch {
            return Data()
        }
    }

    public func listParts() -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return names
            .filter { $0.hasSuffix(".part") }
            .compactMap { Key.fromFkey(String($0.dropLast(".part".count))) }
            .sorted()
    }

    public func deletePart(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        closeQuietly(key)
        try? fm.removeItem(at: url(key, ".part"))
    }

    // ---------- готовые файлы ----------

    public func commit(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try closeWriter(key)
        } catch {
            throw FileStorage.mapIo(error)
        }
        let part = url(key, ".part")
        let dst = url(key)
        guard fm.fileExists(atPath: part.path) else { throw OfflineError(.sourceError, "no_part") }
        do {
            try moveAtomic(part, dst)
        } catch {
            throw FileStorage.mapIo(error)
        }
    }

    public func hasAudio(_ key: String) -> Bool {
        return fm.fileExists(atPath: url(key).path)
    }

    public func audioSize(_ key: String) -> Int64 {
        return fileSize(url(key))
    }

    public func listAudio() -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { !$0.contains(".") }.compactMap { Key.fromFkey($0) }.sorted()
    }

    public func audioPath(_ key: String) -> String? {
        let u = url(key)
        return fm.fileExists(atPath: u.path) ? u.path : nil
    }

    public func deleteAudio(_ key: String) {
        try? fm.removeItem(at: url(key))
    }

    public func remove(_ key: String) {
        // I2: сначала запись, потом звук. Упавшее посередине оставит сироту, а не битую запись.
        lock.lock()
        defer { lock.unlock() }
        closeQuietly(key)
        try? fm.removeItem(at: url(key, MetaKind.entry.suffix))
        try? fm.removeItem(at: url(key, MetaKind.job.suffix))
        try? fm.removeItem(at: url(key, ".part"))
        try? fm.removeItem(at: url(key))
    }

    public func usage() -> Usage {
        var sum: Int64 = 0
        for n in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !n.contains(".") {
            sum += fileSize(root.appendingPathComponent(n))
        }
        var free: Int64 = 0
        if let attrs = try? fm.attributesOfFileSystem(forPath: root.path) {
            if let n = attrs[.systemFreeSize] as? NSNumber {
                free = n.int64Value
            } else if let u = attrs[.systemFreeSize] as? UInt64 {
                free = Int64(clamping: u)
            }
        }
        return Usage(bytes: sum, free: free)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        for key in Array(writers.keys) { closeQuietly(key) }
        for n in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            try? fm.removeItem(at: root.appendingPathComponent(n))
        }
    }

    private func moveAtomic(_ from: URL, _ to: URL) throws {
        if rename(from.path, to.path) != 0 {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
            )
        }
    }

    /// Нехватку места ОС отдаёт обычной ошибкой; определяем по коду и по тексту.
    public static func mapIo(_ error: Error) -> OfflineError {
        if let e = error as? OfflineError { return e }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == 640 { return OfflineError(.noSpace) }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return OfflineError(.noSpace) }
        let msg = (ns.localizedDescription + " " + String(describing: error)).lowercased()
        if msg.contains("no space") || msg.contains("enospc") || msg.contains("quota") || msg.contains("disk full") || msg.contains("out of space") {
            return OfflineError(.noSpace)
        }
        return OfflineError(.sourceError, "io", detail: ns.localizedDescription)
    }
}
