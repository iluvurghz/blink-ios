import Foundation
import BlinkCore

/// Рука комнаты на плеере устройства.
final class PlayerRoomPort: RoomPlayerPort, @unchecked Sendable {
    private let player: PlayerController

    init(player: PlayerController) {
        self.player = player
    }

    func local() -> LocalPlayback {
        let s = player.current
        return LocalPlayback(track: s.track, playing: s.playing, positionMs: s.positionMs, loading: s.buffering)
    }

    func playQueue(_ queue: [Track], index: Int, positionMs: Int64, playing: Bool) {
        player.play(queue, at: index, positionMs: positionMs, autoplay: playing)
    }

    func setPlaying(_ playing: Bool, positionMs: Int64) {
        player.setPlaying(playing, atMs: positionMs)
    }

    func seekTo(_ positionMs: Int64) {
        player.seek(toMs: positionMs)
    }

    func appendToQueue(_ tracks: [Track]) {
        player.append(tracks)
    }

    func queue() -> (tracks: [Track], index: Int) {
        return player.queueSnapshot()
    }
}

/// Поток событий комнаты (SSE) через `URLSession.bytes`: заголовок с токеном работает, соединение живёт, пока идут пульсы сервера.
final class URLSessionEventStreamer: EventStreamer, @unchecked Sendable {
    private let session: URLSession

    init(userAgent: String) {
        let cfg = URLSessionConfiguration.ephemeral
        // Сервер шлёт пульс каждые 15 секунд: тишина дольше 50 секунд значит обрыв.
        cfg.timeoutIntervalForRequest = 50
        cfg.timeoutIntervalForResource = 24 * 3600
        cfg.httpAdditionalHeaders = ["User-Agent": userAgent]
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    func stream(url: URL, headers: [String: String], onLine: @escaping @Sendable (String) -> Void) async throws -> Int {
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status < 200 || status > 299 { return status }
        for try await line in bytes.lines { onLine(line) }
        return status
    }
}
