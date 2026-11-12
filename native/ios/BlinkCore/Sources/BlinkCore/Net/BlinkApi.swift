import Foundation

/// Как найти звук для проигрывания; к офлайну это отношения не имеет (скачивание идёт через `ServerResolver`).
public struct StreamException: Error, Equatable, Sendable {
    public enum Kind: Sendable {
        case needSignIn
        case notFound
        case unavailable
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Сервер ответил, но не успехом (аналог IOException("catalog 500") в Android-ядре).
public struct ServerError: Error, Equatable, Sendable {
    public let what: String
    public let status: Int

    public init(_ what: String, _ status: Int) {
        self.what = what
        self.status = status
    }
}

public struct StreamSource: Equatable, Sendable {
    public let url: String

    public init(url: String) {
        self.url = url
    }
}

public struct PlusStatus: Equatable, Sendable {
    public let active: Bool
    public let untilMs: Int64?

    public init(active: Bool, untilMs: Int64?) {
        self.active = active
        self.untilMs = untilMs
    }
}

/// Запросы к серверу Blink и каталогу. Формы ответов сняты с `server.js` и веб-клиента (см. docs/api-map.md).
public final class BlinkApi: Sendable {
    public static let licFields = "id,artist_id,title,artist_name,release_title,duration,explicit,year,genre,lrc,lyrics,cover_path,offline_allowed,status"
    static let callTimeout: TimeInterval = 20

    private let http: HTTPClient
    private let config: BlinkConfig
    private let tokens: TokenProvider?
    private let now: @Sendable () -> Int64

    public init(
        http: HTTPClient,
        config: BlinkConfig,
        tokens: TokenProvider? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.http = http
        self.config = config
        self.tokens = tokens
        self.now = now
    }

    // ---------- поиск ----------

    /// Лицензионный каталог Blink первым (его можно сохранять офлайн), затем iTunes и Яндекс без дублей.
    /// Если отвечает хоть один источник, это результат; если ни один и причина в сети, бросает ошибку сети.
    public func search(_ term: String, country: String = "ru") async throws -> [Track] {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return [] }
        async let licensedResult = attempt { try await self.licensed(q) }
        async let itunesResult = attempt { try await self.itunes(q, country) }
        async let yandexResult = attempt { try await self.yandex(q, 30) }
        let results = [await licensedResult, await itunesResult, await yandexResult]
        try Task.checkCancellation()

        var lists: [[Track]] = []
        var firstNetworkError: Error?
        var failures = 0
        for r in results {
            switch r {
            case .success(let list):
                lists.append(list)
            case .failure(let e):
                failures += 1
                lists.append([])
                if firstNetworkError == nil && BlinkApi.isNetwork(e) { firstNetworkError = e }
            }
        }
        if failures == results.count, let e = firstNetworkError { throw e }
        return BlinkApi.merge(lists)
    }

    private func attempt(_ op: @Sendable () async throws -> [Track]) async -> Result<[Track], Error> {
        do {
            return .success(try await op())
        } catch {
            return .failure(error)
        }
    }

    static func isNetwork(_ e: Error) -> Bool {
        return e is TransportError || e is ServerError
    }

    public func latestLicensed(limit: Int = 12) async throws -> [Track] {
        guard config.hasKey else { return [] }
        guard let url = URLBuilder.make(config.supabase, path: "rest/v1/lic_tracks", query: [
            ("select", BlinkApi.licFields),
            ("status", "eq.live"),
            ("order", "created_at.desc"),
            ("limit", String(limit)),
        ]) else { return [] }
        return try await restTracks(url)
    }

    private func licensed(_ q: String) async throws -> [Track] {
        guard config.hasKey else { return [] }
        let cleaned = String(q.map { "%_,()*:".contains($0) ? " " : $0 })
        let like = "*" + cleaned.trimmingCharacters(in: .whitespacesAndNewlines) + "*"
        guard let url = URLBuilder.make(config.supabase, path: "rest/v1/lic_tracks", query: [
            ("select", BlinkApi.licFields),
            ("status", "eq.live"),
            ("or", "(title.ilike.\(like),artist_name.ilike.\(like),release_title.ilike.\(like))"),
            ("limit", "20"),
        ]) else { return [] }
        return try await restTracks(url)
    }

    private func restTracks(_ url: URL) async throws -> [Track] {
        let token = await tokens?.accessToken() ?? config.supabaseAnonKey
        let res = try await http.send(HTTPRequest(
            url: url,
            headers: ["apikey": config.supabaseAnonKey, "Authorization": "Bearer " + token, "Accept": "application/json"],
            timeout: BlinkApi.callTimeout
        ))
        if !res.ok { throw ServerError("catalog", res.status) }
        guard let arr = BlinkJSON.array(res.text) else { return [] }
        return arr.compactMap { ($0 as? [String: Any]).flatMap { fromLicRow($0) } }
    }

    func fromLicRow(_ r: [String: Any]) -> Track? {
        guard let id = JSONField.string(r, "id"), let title = JSONField.string(r, "title") else { return nil }
        let cover = JSONField.string(r, "cover_path") ?? ""
        return Track(
            id: "b:" + id,
            title: title,
            artist: JSONField.string(r, "artist_name") ?? "",
            album: JSONField.string(r, "release_title") ?? "",
            artwork: cover.isEmpty ? "" : "\(config.base)/covers/\(id).jpg",
            duration: JSONField.int(r, "duration") ?? 0,
            explicit: JSONField.bool(r, "explicit") == true,
            year: JSONField.string(r, "year") ?? "",
            genre: JSONField.string(r, "genre") ?? "",
            source: Track.sourceBlink,
            lic: id,
            lrc: JSONField.string(r, "lrc"),
            lyrics: JSONField.string(r, "lyrics"),
            offline: JSONField.bool(r, "offline_allowed") == true
        )
    }

    /// Трек Apple по числовому id (из ссылки `/t/<id>`); nil, если не нашли.
    public func lookup(_ id: String) async throws -> Track? {
        guard let url = URLBuilder.make(config.base, path: "api/itunes/lookup", query: [("id", id), ("country", "ru"), ("entity", "song")]) else { return nil }
        return try await songs(url).first
    }

    private func itunes(_ q: String, _ country: String) async throws -> [Track] {
        guard let url = URLBuilder.make(config.base, path: "api/itunes/search", query: [
            ("term", q), ("country", country), ("media", "music"), ("entity", "song"), ("limit", "50"),
        ]) else { return [] }
        return try await songs(url)
    }

    private func yandex(_ q: String, _ limit: Int) async throws -> [Track] {
        guard let url = URLBuilder.make(config.base, path: "api/yandex/search", query: [
            ("q", q), ("type", "track"), ("limit", String(limit)),
        ]) else { return [] }
        return try await songs(url)
    }

    private func songs(_ url: URL) async throws -> [Track] {
        let res = try await http.send(HTTPRequest(url: url, headers: ["Accept": "application/json"], timeout: BlinkApi.callTimeout))
        if !res.ok { throw ServerError("search", res.status) }
        guard let results = BlinkJSON.object(res.text).flatMap({ JSONField.array($0, "results") }) else { return [] }
        return results.compactMap { e -> Track? in
            guard let o = e as? [String: Any], JSONField.string(o, "kind") == "song" else { return nil }
            return fromItunes(o)
        }
    }

    func fromItunes(_ r: [String: Any]) -> Track? {
        guard let id = JSONField.string(r, "trackId"), let title = JSONField.string(r, "trackName") else { return nil }
        let a600 = JSONField.string(r, "artworkUrl600") ?? ""
        let a100 = JSONField.string(r, "artworkUrl100") ?? ""
        let artwork: String
        if !a600.isEmpty {
            artwork = a600.replacingOccurrences(of: "/\\d+x\\d+$", with: "/1000x1000", options: .regularExpression)
        } else if !a100.isEmpty {
            artwork = BlinkApi.scaleArt(a100, 600)
        } else {
            artwork = ""
        }
        let album = (JSONField.string(r, "collectionName") ?? "")
            .replacingOccurrences(of: "\\s*-\\s*(Single|EP)$", with: "", options: [.regularExpression, .caseInsensitive])
        return Track(
            id: id,
            title: title,
            artist: JSONField.string(r, "artistName") ?? "",
            artistId: JSONField.string(r, "artistId"),
            album: album,
            albumId: JSONField.string(r, "collectionId"),
            artwork: artwork,
            duration: JSONField.int64(r, "trackTimeMillis").map { BlinkApi.secondsFromMs($0) } ?? 0,
            explicit: JSONField.string(r, "trackExplicitness") == "explicit",
            year: String((JSONField.string(r, "releaseDate") ?? "").prefix(4)),
            genre: JSONField.string(r, "primaryGenreName") ?? ""
        )
    }

    static func secondsFromMs(_ ms: Int64) -> Int {
        return Int((Double(ms) / 1000.0).rounded())
    }

    // ---------- чарт ----------

    public func chart(limit: Int = 30) async throws -> [Track] {
        guard let url = URLBuilder.make(config.base, path: "api/charts/top") else { return [] }
        let res = try await http.send(HTTPRequest(url: url, headers: ["Accept": "application/json"], timeout: BlinkApi.callTimeout))
        if !res.ok { throw ServerError("charts", res.status) }
        guard let items = BlinkJSON.object(res.text).flatMap({ JSONField.array($0, "items") }) else { return [] }
        let tracks = items.compactMap { e -> Track? in
            guard let o = e as? [String: Any], let t = JSONField.object(o, "track") else { return nil }
            return fromChart(t)
        }
        return Array(tracks.prefix(limit))
    }

    func fromChart(_ t: [String: Any]) -> Track? {
        guard let id = JSONField.string(t, "id"), let title = JSONField.string(t, "title") else { return nil }
        let artists = (JSONField.array(t, "artists") ?? []).compactMap { ($0 as? [String: Any]).flatMap { JSONField.string($0, "name") } }
        if artists.isEmpty { return nil }
        let album = (JSONField.array(t, "albums") ?? []).first as? [String: Any]
        let version = JSONField.string(t, "version") ?? ""
        let cover = JSONField.string(t, "coverUri") ?? ""
        return Track(
            id: "cr" + id,
            title: version.isEmpty ? title : "\(title) (\(version))",
            artist: artists.joined(separator: ", "),
            album: album.flatMap { JSONField.string($0, "title") } ?? "",
            artwork: cover.isEmpty ? "" : "https://" + cover.replacingOccurrences(of: "%%", with: "600x600"),
            duration: JSONField.int64(t, "durationMs").map { BlinkApi.secondsFromMs($0) } ?? 0,
            explicit: JSONField.string(t, "contentWarning") == "explicit",
            year: album.flatMap { JSONField.string($0, "year") } ?? "",
            genre: album.flatMap { JSONField.string($0, "genre") } ?? "",
            source: "chart"
        )
    }

    // ---------- проигрывание (стрим, не скачивание) ----------

    /// Куда идти за звуком. Лицензионный трек: `/api/play/<lic>` (нужен вход). Остальные: APIBlink,
    /// как в вебе (`/api/apiblink/play?artist&title` → `streamUrl`, с Range). Скачивать этим путём нельзя.
    public func streamFor(_ track: Track) async throws -> StreamSource {
        if let s = track.stream, !s.isEmpty { return StreamSource(url: s) }
        if track.isLicensed, let lic = track.lic {
            guard let token = await tokens?.accessToken() else {
                throw StreamException(.needSignIn, "Войдите, чтобы слушать треки Blink")
            }
            guard let url = URLBuilder.make(config.base, path: "api/play/" + lic) else {
                throw StreamException(.unavailable, "Сервер не отдал ссылку")
            }
            let res = try await http.send(HTTPRequest(url: url, headers: ["Authorization": "Bearer " + token], timeout: BlinkApi.callTimeout))
            if res.status == 401 { throw StreamException(.needSignIn, "Войдите в аккаунт") }
            if res.status == 404 { throw StreamException(.notFound, "Трек снят или ещё не вышел") }
            if !res.ok { throw StreamException(.unavailable, "Сервер не отдал трек (\(res.status))") }
            guard let link = config.absolute(BlinkJSON.object(res.text).flatMap { JSONField.string($0, "url") }) else {
                throw StreamException(.unavailable, "Сервер не отдал ссылку")
            }
            return StreamSource(url: link)
        }
        guard let url = URLBuilder.make(config.base, path: "api/apiblink/play", query: [("artist", track.artist), ("title", track.title)]) else {
            throw StreamException(.notFound, "Не нашли поток для этого трека")
        }
        let res = try await http.send(HTTPRequest(url: url, headers: ["Accept": "application/json"], timeout: 25))
        if res.status == 503 { throw StreamException(.unavailable, "Источник сейчас недоступен") }
        if !res.ok { throw StreamException(.notFound, "Не нашли поток для этого трека") }
        let raw = BlinkJSON.object(res.text).flatMap { JSONField.object($0, "track") }.flatMap { JSONField.string($0, "streamUrl") }
        guard let stream = config.absolute(raw) else {
            throw StreamException(.notFound, "Не нашли поток для этого трека")
        }
        return StreamSource(url: stream)
    }

    // ---------- подписка ----------

    /// Статус Blink+. nil без входа или без ответа сервера: тогда остаётся последняя известная дата.
    public func plus() async throws -> PlusStatus? {
        guard let token = await tokens?.accessToken() else { return nil }
        guard let url = URLBuilder.make(config.base, path: "api/plus/me") else { return nil }
        let res = try await http.send(HTTPRequest(url: url, headers: ["Authorization": "Bearer " + token], timeout: BlinkApi.callTimeout))
        if !res.ok { return nil }
        guard let o = BlinkJSON.object(res.text) else { return nil }
        let until = JSONField.string(o, "plus_until").flatMap { ISODate.parseMs($0) }
        let flagged = JSONField.bool(o, "active") == true
        let active = flagged && (until == nil || until! > now())
        return PlusStatus(active: active, untilMs: flagged ? until : nil)
    }

    // ---------- общее ----------

    /// iTunes: …/100x100bb.jpg → …/600x600bb.jpg, Яндекс: …/100x100 → …/600x600.
    public static func scaleArt(_ url: String, _ size: Int) -> String {
        if url.isEmpty { return "" }
        if url.range(of: "/\\d+x\\d+bb\\.jpg$", options: .regularExpression) != nil {
            return url.replacingOccurrences(of: "/\\d+x\\d+bb\\.jpg$", with: "/\(size)x\(size)bb.jpg", options: .regularExpression)
        }
        if url.range(of: "/\\d+x\\d+$", options: .regularExpression) != nil {
            return url.replacingOccurrences(of: "/\\d+x\\d+$", with: "/\(size)x\(size)", options: .regularExpression)
        }
        return url
    }

    /// Ключ дубля как на сайте: `название|артист` без знаков и регистра.
    public static func dedupeKey(_ t: Track) -> String {
        return (t.title + "|" + t.artist).lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N}|]+", with: "", options: .regularExpression)
    }

    /// Склеивает списки по порядку источников, убирая повторы по `название|артист`.
    public static func merge(_ lists: [[Track]]) -> [Track] {
        var seenIds = Set<String>()
        var seen = Set<String>()
        var out: [Track] = []
        for list in lists {
            for t in list {
                if !seenIds.insert(t.id).inserted { continue }
                if !seen.insert(dedupeKey(t)).inserted { continue }
                out.append(t)
            }
        }
        return out
    }
}
