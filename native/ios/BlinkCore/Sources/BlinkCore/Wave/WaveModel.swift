import Foundation

/// Режимы «Вспышки» (как на сайте).
public enum WaveMode: String, CaseIterable, Sendable {
    case mix, known, discover, fresh

    public var title: String {
        switch self {
        case .mix: return "Микс"
        case .known: return "Знакомое"
        case .discover: return "Открытия"
        case .fresh: return "Новое"
        }
    }

    public static func of(_ id: String?) -> WaveMode {
        return WaveMode(rawValue: id ?? "") ?? .mix
    }
}

public struct WaveSettings: Equatable, Sendable {
    public var mode: WaveMode
    public var explore: Bool

    public init(mode: WaveMode = .mix, explore: Bool = true) {
        self.mode = mode
        self.explore = explore
    }
}

/// Трек-кандидат из подборки сервера: откуда взялся, по какому сиду и у скольких сидов всплыл.
public struct WaveCandidate: Sendable {
    public let track: Track
    public let src: String?
    public let seed: String?
    public let hits: Int

    public init(track: Track, src: String?, seed: String?, hits: Int) {
        self.track = track
        self.src = src
        self.seed = seed
        self.hits = hits
    }
}

public struct SeedGenre: Equatable, Sendable {
    public let query: String
    public let genre: String
    public let id: String?

    public init(query: String, genre: String, id: String?) {
        self.query = query
        self.genre = genre
        self.id = id
    }
}

public struct PoolResult: Sendable {
    public let tracks: [WaveCandidate]
    public let seedGenre: [SeedGenre]

    public init(tracks: [WaveCandidate], seedGenre: [SeedGenre]) {
        self.tracks = tracks
        self.seedGenre = seedGenre
    }
}

public struct SimilarResult: Equatable, Sendable {
    public let ids: [String]
    public let genre: String

    public init(ids: [String], genre: String) {
        self.ids = ids
        self.genre = genre
    }
}

/// Откуда Вспышка берёт кандидатов: сервер Blink (Яндекс.Музыка, чарты). Сеть спрятана за протокол, чтобы ядро проверялось тестами.
public protocol WaveSource: Sendable {
    func pool(seeds: [String]) async throws -> PoolResult
    func genres(items: [String]) async throws -> [String: String]
    func similarIds(seed: String) async throws -> SimilarResult
    /// Чарт «Россия» (id `cr…`).
    func topChart() async throws -> [Track]
    /// Недельный и месячный чарты новинок: `weekly` или `monthly` (id `cp…`).
    func periodChart(kind: String) async throws -> [Track]
}

/// Лайки (новые первыми) и недавно сыгранное (новые первыми, до 60): из них строится вкус.
public protocol Library: AnyObject, Sendable {
    var likes: [Track] { get }
    var recent: [Track] { get }
}

/// Места в памяти приложения, где лежит JSON. На iOS это файл в Application Support.
public protocol BlobStore: AnyObject, Sendable {
    func load() -> String?
    func save(_ value: String?)
}

/// Случайные числа, которые можно задать зерном: в тестах результат повторяется.
public final class WaveRandom: @unchecked Sendable {
    private let lock = NSLock()
    private var state: UInt64
    private let seeded: Bool

    public init(seed: UInt64? = nil) {
        self.seeded = seed != nil
        self.state = seed ?? 0
    }

    private func nextBits() -> UInt64 {
        if !seeded {
            var g = SystemRandomNumberGenerator()
            return g.next()
        }
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0, 1)
    public func double() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(nextBits() >> 11) / Double(1 << 53)
    }

    /// [0, n)
    public func int(below n: Int) -> Int {
        if n <= 1 { return 0 }
        return min(n - 1, Int(double() * Double(n)))
    }

    public func shuffled<T>(_ items: [T]) -> [T] {
        var a = items
        var i = a.count - 1
        while i > 0 {
            let j = int(below: i + 1)
            a.swapAt(i, j)
            i -= 1
        }
        return a
    }
}
