import Foundation

/// Подписанная ссылка на файл и то, что про него известно заранее.
public struct Resolved: Equatable, Sendable {
    public var url: String
    public var mime: String?
    /// Точный размер. nil только в обходе через /api/play: тогда берём из Content-Range.
    public var bytes: Int64?
    /// Слабый etag `W/"..."`: в If-Range уходит дословно.
    public var etag: String?
    /// Мс от эпохи.
    public var expiresAt: Int64
    public var duration: Int?

    public init(url: String, mime: String? = nil, bytes: Int64? = nil, etag: String? = nil, expiresAt: Int64 = 0, duration: Int? = nil) {
        self.url = url
        self.mime = mime
        self.bytes = bytes
        self.etag = etag
        self.expiresAt = expiresAt
        self.duration = duration
    }
}

public protocol TrackResolver: Sendable {
    /// Бросает `OfflineError` с кодом из контракта; сетевые сбои приходят как `TransportError`.
    func resolve(source: String, id: String) async throws -> Resolved
}

/// Резолвер сервера Blink: `GET /api/offline/resolve?source=blink&id=<uuid>` с Bearer.
/// К самой ссылке Authorization не добавляется: она подписана на пользователя и живёт час.
///
/// Пока резолвер не выкачен на прод (ответ 404 без нашего JSON), идём в `GET /api/play/<uuid>` →
/// `{url}`: тогда bytes/etag/mime неизвестны, а Blink+ и offline_allowed проверяет клиент.
public final class ServerResolver: TrackResolver, @unchecked Sendable {
    public static let resolveTimeoutSeconds: TimeInterval = 15
    static let defaultTTLms: Int64 = 55 * 60 * 1000
    static let legacyTTLms: Int64 = 55 * 60 * 1000

    private let http: HTTPClient
    private let config: BlinkConfig
    private let tokens: TokenProvider
    private let now: @Sendable () -> Int64
    private let legacyFallback: Bool

    public init(
        http: HTTPClient,
        config: BlinkConfig,
        tokens: TokenProvider,
        legacyFallback: Bool = true,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.http = http
        self.config = config
        self.tokens = tokens
        self.legacyFallback = legacyFallback
        self.now = now
    }

    public func resolve(source: String, id: String) async throws -> Resolved {
        guard let token = await tokens.accessToken() else { throw OfflineError(.notAllowed, "auth") }
        guard let url = URLBuilder.make(config.base, path: "api/offline/resolve", query: [("source", source), ("id", id)]) else {
            throw OfflineError(.sourceError, "bad_request")
        }
        let res = try await http.send(authorized(url, token))
        let json = BlinkJSON.object(res.text)

        if res.status == 200 {
            guard let json = json, JSONField.bool(json, "ok") == true else { throw OfflineError(.sourceError, "bad_response") }
            guard let fileUrl = config.absolute(JSONField.string(json, "url")) else { throw OfflineError(.sourceError, "bad_response") }
            guard let bytes = JSONField.int64(json, "bytes"), bytes > 0 else { throw OfflineError(.sourceError, "bad_response") }
            return Resolved(
                url: fileUrl,
                mime: JSONField.string(json, "mime"),
                bytes: bytes,
                etag: JSONField.string(json, "etag"),
                expiresAt: JSONField.int64(json, "expiresAt") ?? (now() + ServerResolver.defaultTTLms),
                duration: JSONField.int(json, "duration")
            )
        }

        var declared: [String: Any]?
        if let j = json, JSONField.bool(j, "ok") == false { declared = j }
        if res.status == 404 && declared == nil {
            // Нашего JSON нет: эндпоинта на сервере ещё нет.
            if legacyFallback && source == "blink" { return try await legacy(id, token) }
        }
        throw ServerResolver.mapError(
            status: res.status,
            error: declared.flatMap { JSONField.string($0, "error") },
            reason: declared.flatMap { JSONField.string($0, "reason") }
        )
    }

    private func legacy(_ id: String, _ token: String) async throws -> Resolved {
        guard let url = URLBuilder.make(config.base, path: "api/play/" + id) else { throw OfflineError(.sourceError, "bad_request") }
        let res = try await http.send(authorized(url, token))
        if res.status == 200 {
            let json = BlinkJSON.object(res.text)
            guard let fileUrl = config.absolute(json.flatMap { JSONField.string($0, "url") }) else {
                throw OfflineError(.sourceError, "bad_response")
            }
            return Resolved(url: fileUrl, expiresAt: now() + ServerResolver.legacyTTLms)
        }
        throw ServerResolver.mapError(status: res.status, error: nil, reason: nil)
    }

    private func authorized(_ url: URL, _ token: String) -> HTTPRequest {
        return HTTPRequest(
            url: url,
            headers: ["Authorization": "Bearer " + token, "Accept": "application/json"],
            timeout: ServerResolver.resolveTimeoutSeconds
        )
    }

    static func mapError(status: Int, error: String?, reason: String?) -> OfflineError {
        if let e = error, let declared = OfflineCode(rawValue: e), declared != .cancelled {
            var r: String? = reason
            if r == nil {
                if declared == .notAllowed && status == 401 {
                    r = "auth"
                } else if declared == .notAllowed {
                    r = "source"
                }
            }
            return OfflineError(declared, r)
        }
        switch status {
        case 401: return OfflineError(.notAllowed, "auth")
        case 403: return OfflineError(.notAllowed, reason ?? "source")
        case 404: return OfflineError(.notDownloadable, reason ?? "missing")
        default: return OfflineError(.sourceError, "http_\(status)")
        }
    }
}

/// Ждёт операцию не дольше `ms` миллисекунд. nil значит «не дождались»; ошибки операции пробрасываются.
func withTimeoutOrNil<T: Sendable>(ms: Int64, _ operation: @escaping @Sendable () async throws -> T) async throws -> T? {
    return try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { () async throws -> T? in
            let value: T = try await operation()
            return value
        }
        group.addTask { () async throws -> T? in
            try await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { return nil }
        return first
    }
}
