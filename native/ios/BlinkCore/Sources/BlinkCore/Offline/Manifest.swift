import Foundation

/// Запись манифеста schema:1. Существует ТОЛЬКО для полностью проверенного файла.
public struct ManifestEntry: Codable, Equatable, Sendable {
    public var schema: Int
    public var key: String
    public var source: String
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    public var cover: String
    public var duration: Int
    public var bytes: Int64
    public var mime: String?
    public var etag: String?
    public var status: String
    public var savedAt: Int64
    public var lastPlayedAt: Int64?
    public var offlineAllowed: Bool
    /// Под будущее шифрование файлов на диске.
    public var enc: String?
    /// Непрозрачная копия объекта трека приложения (форма как на сайте).
    public var track: JSONValue?

    public init(
        schema: Int = 1,
        key: String,
        source: String,
        id: String,
        title: String,
        artist: String,
        album: String = "",
        cover: String = "",
        duration: Int = 0,
        bytes: Int64,
        mime: String? = nil,
        etag: String? = nil,
        status: String = "saved",
        savedAt: Int64,
        lastPlayedAt: Int64? = nil,
        offlineAllowed: Bool = true,
        enc: String? = nil,
        track: JSONValue? = nil
    ) {
        self.schema = schema
        self.key = key
        self.source = source
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.cover = cover
        self.duration = duration
        self.bytes = bytes
        self.mime = mime
        self.etag = etag
        self.status = status
        self.savedAt = savedAt
        self.lastPlayedAt = lastPlayedAt
        self.offlineAllowed = offlineAllowed
        self.enc = enc
        self.track = track
    }

    private enum CodingKeys: String, CodingKey {
        case schema, key, source, id, title, artist, album, cover, duration, bytes, mime, etag
        case status, savedAt, lastPlayedAt, offlineAllowed, enc, track
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        key = try c.decode(String.self, forKey: .key)
        source = try c.decode(String.self, forKey: .source)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? ""
        duration = try c.decodeIfPresent(Int.self, forKey: .duration) ?? 0
        bytes = try c.decode(Int64.self, forKey: .bytes)
        mime = try c.decodeIfPresent(String.self, forKey: .mime)
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "saved"
        savedAt = try c.decode(Int64.self, forKey: .savedAt)
        lastPlayedAt = try c.decodeIfPresent(Int64.self, forKey: .lastPlayedAt)
        offlineAllowed = try c.decodeIfPresent(Bool.self, forKey: .offlineAllowed) ?? true
        enc = try c.decodeIfPresent(String.self, forKey: .enc)
        track = try c.decodeIfPresent(JSONValue.self, forKey: .track)
    }

    public func encode() -> String {
        return BlinkJSON.encode(self) ?? "{}"
    }

    public static func decode(_ text: String) -> ManifestEntry? {
        guard let e = BlinkJSON.decode(ManifestEntry.self, from: text) else { return nil }
        return (e.schema == 1 && e.status == "saved") ? e : nil
    }

    /// Сохранённый трек обратно в объект трека приложения: берём полную копию из манифеста,
    /// а если её нет, собираем из полей записи.
    public func toTrack() -> Track {
        if let t = Track.from(json: track) { return t }
        return Track(
            id: "b:" + id,
            title: title,
            artist: artist,
            album: album,
            artwork: cover,
            duration: duration,
            source: Track.sourceBlink,
            lic: id,
            offline: true
        )
    }
}

public enum Stage: String, Codable, Sendable {
    case queued = "QUEUED"
    case resolving = "RESOLVING"
    case downloading = "DOWNLOADING"
    case verifying = "VERIFYING"
    case committing = "COMMITTING"
    case failed = "FAILED"
}

/// Метаданные трека, нужные задаче и будущей записи манифеста.
public struct JobMeta: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var cover: String
    public var duration: Int
    public var offlineAllowed: Bool
    public var track: JSONValue?

    public init(
        title: String,
        artist: String,
        album: String = "",
        cover: String = "",
        duration: Int = 0,
        offlineAllowed: Bool = true,
        track: JSONValue? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.cover = cover
        self.duration = duration
        self.offlineAllowed = offlineAllowed
        self.track = track
    }

    private enum CodingKeys: String, CodingKey {
        case title, artist, album, cover, duration, offlineAllowed, track
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? ""
        duration = try c.decodeIfPresent(Int.self, forKey: .duration) ?? 0
        offlineAllowed = try c.decodeIfPresent(Bool.self, forKey: .offlineAllowed) ?? true
        track = try c.decodeIfPresent(JSONValue.self, forKey: .track)
    }
}

/// Файл `<fkey>.job.json`: очередь переживает перезапуск.
public struct OfflineJob: Codable, Equatable, Sendable {
    public var schema: Int
    public var key: String
    public var source: String
    public var id: String
    public var meta: JobMeta
    public var etag: String?
    public var total: Int64?
    public var mime: String?
    public var state: String
    public var attempts: Int
    public var code: String?
    public var reason: String?
    public var failedAt: Int64?
    public var createdAt: Int64

    public init(
        schema: Int = 1,
        key: String,
        source: String,
        id: String,
        meta: JobMeta,
        etag: String? = nil,
        total: Int64? = nil,
        mime: String? = nil,
        state: String = Stage.queued.rawValue,
        attempts: Int = 0,
        code: String? = nil,
        reason: String? = nil,
        failedAt: Int64? = nil,
        createdAt: Int64
    ) {
        self.schema = schema
        self.key = key
        self.source = source
        self.id = id
        self.meta = meta
        self.etag = etag
        self.total = total
        self.mime = mime
        self.state = state
        self.attempts = attempts
        self.code = code
        self.reason = reason
        self.failedAt = failedAt
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case schema, key, source, id, meta, etag, total, mime, state, attempts, code, reason, failedAt, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        key = try c.decode(String.self, forKey: .key)
        source = try c.decode(String.self, forKey: .source)
        id = try c.decode(String.self, forKey: .id)
        meta = try c.decode(JobMeta.self, forKey: .meta)
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        total = try c.decodeIfPresent(Int64.self, forKey: .total)
        mime = try c.decodeIfPresent(String.self, forKey: .mime)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? Stage.queued.rawValue
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        code = try c.decodeIfPresent(String.self, forKey: .code)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        failedAt = try c.decodeIfPresent(Int64.self, forKey: .failedAt)
        createdAt = try c.decode(Int64.self, forKey: .createdAt)
    }

    public var stage: Stage { return Stage(rawValue: state) ?? .queued }

    public var failure: OfflineCode? {
        guard let c = code else { return nil }
        return OfflineCode(rawValue: c)
    }

    public func encode() -> String {
        return BlinkJSON.encode(self) ?? "{}"
    }

    public static func decode(_ text: String) -> OfflineJob? {
        guard let j = BlinkJSON.decode(OfflineJob.self, from: text) else { return nil }
        return j.schema == 1 ? j : nil
    }
}
