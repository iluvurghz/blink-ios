import Foundation

public struct SeenEntry: Codable, Equatable, Sendable {
    public var at: Int64
    public var artist: String
}

public struct ListenEntry: Codable, Equatable, Sendable {
    public var score: Double
    public var at: Int64
}

public struct GenreNeg: Codable, Equatable, Sendable {
    public var pen: Double
    public var at: Int64
}

/// Всё, что Вспышка помнит о слушателе на этом устройстве (на сайте это ключи `blink-wave-*` и `waveBan`).
public struct WaveData: Codable, Equatable, Sendable {
    /// Что уже показано: id → когда и чей артист.
    public var seen: [String: SeenEntry] = [:]
    /// Дослушивания по артистам (затухают с полураспадом 45 дней).
    public var listen: [String: ListenEntry] = [:]
    /// Жанры треков; «-» значит «жанра нет».
    public var genres: [String: String] = [:]
    /// «Не моё»: id треков, похожих на дизлайкнутые, и штрафы жанров (30 дней).
    public var negIds: [String: Int64] = [:]
    public var negGenres: [String: GenreNeg] = [:]
    public var banIds: [String] = []
    public var banArtists: [String: Int] = [:]
    public var skips: [String] = []
    public var skipArtists: [String: Int] = [:]
    /// Запас кандидатов для быстрого старта.
    public var spare: [Track] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case seen, listen, genres, negIds, negGenres, banIds, banArtists, skips, skipArtists, spare
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seen = (try? c.decodeIfPresent([String: SeenEntry].self, forKey: .seen)) ?? [:]
        listen = (try? c.decodeIfPresent([String: ListenEntry].self, forKey: .listen)) ?? [:]
        genres = (try? c.decodeIfPresent([String: String].self, forKey: .genres)) ?? [:]
        negIds = (try? c.decodeIfPresent([String: Int64].self, forKey: .negIds)) ?? [:]
        negGenres = (try? c.decodeIfPresent([String: GenreNeg].self, forKey: .negGenres)) ?? [:]
        banIds = (try? c.decodeIfPresent([String].self, forKey: .banIds)) ?? []
        banArtists = (try? c.decodeIfPresent([String: Int].self, forKey: .banArtists)) ?? [:]
        skips = (try? c.decodeIfPresent([String].self, forKey: .skips)) ?? []
        skipArtists = (try? c.decodeIfPresent([String: Int].self, forKey: .skipArtists)) ?? [:]
        spare = (try? c.decodeIfPresent([Track].self, forKey: .spare)) ?? []
    }
}

/// Хранит [WaveData] и пишет её на диск после каждого изменения.
public final class WaveStore: @unchecked Sendable {
    private let lock = NSLock()
    private let blob: BlobStore
    private var stored: WaveData

    public init(_ blob: BlobStore) {
        self.blob = blob
        if let text = blob.load(), let d = BlinkJSON.decode(WaveData.self, from: text) {
            stored = d
        } else {
            stored = WaveData()
        }
    }

    public var data: WaveData {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public func update(_ change: (inout WaveData) -> Void) {
        lock.lock()
        change(&stored)
        blob.save(BlinkJSON.encode(stored))
        lock.unlock()
    }
}
