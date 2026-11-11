import Foundation

/// Почему трек не заиграл. Повторять такие отказы бессмысленно: сразу объясняем человеку или идём дальше.
public struct PlayFailure: Error, Equatable, Sendable {
    public enum Kind: Sendable {
        /// Нужен вход в аккаунт.
        case needSignIn
        /// Источник не нашёл звук (трек снят, нет потока).
        case notFound
        /// Источник сейчас недоступен.
        case unavailable
        /// Нет интернета, а трек не сохранён.
        case needsNetwork
        /// Без интернета сохранённые играют только с Blink+.
        case plusRequired
        /// Не дошли до сервера, хотя сеть вроде есть.
        case network
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Откуда брать звук: файл на телефоне (всегда первым) или поток с сервера.
public enum PlaySource: Equatable, Sendable {
    case file(path: String)
    case stream(url: String)
}

/// Что плеер знает про сохранённые треки. Реализует `OfflineManager`.
public protocol SavedAudio: AnyObject, Sendable {
    func isSaved(_ key: String) -> Bool
    func audioPath(_ key: String) -> String?
    func markPlayed(_ key: String)
}

extension OfflineManager: SavedAudio {}

/// Куда идти за потоком. Реализует `BlinkApi`.
public protocol StreamLookup: Sendable {
    func streamFor(_ track: Track) async throws -> StreamSource
}

extension BlinkApi: StreamLookup {}

/// Последнее известное про Blink+. Реализует `PlusTracker`.
public protocol PlusSource: Sendable {
    var info: PlusInfo { get }
}

extension PlusTracker: PlusSource {}

public protocol PlaySourceProvider: Sendable {
    func source(for track: Track) async throws -> PlaySource
}

/// Выбирает источник звука для трека: сохранённый файл с диска всегда первым, иначе поток с сервера.
/// Без сети сохранённое играет только с активным Blink+ (по последней известной дате).
public final class PlaybackResolver: PlaySourceProvider, @unchecked Sendable {
    private let saved: SavedAudio
    private let streams: StreamLookup
    private let plus: PlusSource
    private let network: NetworkMonitor
    private let now: @Sendable () -> Int64

    public init(
        saved: SavedAudio,
        streams: StreamLookup,
        plus: PlusSource,
        network: NetworkMonitor,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.saved = saved
        self.streams = streams
        self.plus = plus
        self.network = network
        self.now = now
    }

    public func source(for track: Track) async throws -> PlaySource {
        let online = network.isOnline
        if let key = OfflinePolicy.keyOf(track), let path = saved.audioPath(key) {
            if !OfflinePolicy.canPlaySaved(online: online, plusUntilMs: plus.info.offlineUntilMs(), nowMs: now()) {
                throw PlayFailure(.plusRequired, "Без интернета сохранённые играют с Blink+")
            }
            saved.markPlayed(key)
            return .file(path: path)
        }
        if !online { throw PlayFailure(.needsNetwork, "Нужен интернет: этот трек не сохранён") }
        do {
            let stream = try await streams.streamFor(track)
            return .stream(url: stream.url)
        } catch let e as StreamException {
            switch e.kind {
            case .needSignIn: throw PlayFailure(.needSignIn, e.message.isEmpty ? "Войдите в аккаунт" : e.message)
            case .notFound: throw PlayFailure(.notFound, e.message.isEmpty ? "Не нашли звук для этого трека" : e.message)
            case .unavailable: throw PlayFailure(.unavailable, e.message.isEmpty ? "Источник недоступен" : e.message)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PlayFailure(.network, "Нет связи с сервером. Попробуйте ещё раз")
        }
    }
}
