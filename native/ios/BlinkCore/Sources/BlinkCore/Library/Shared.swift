import Foundation

/// Плейлист по ссылке `blinkmusic.cc/p/<код>` или подборка редакции.
public struct SharedPlaylist: Equatable, Sendable {
    public var code: String
    public var owner: String
    public var name: String
    public var cover: String?
    public var tracks: [Track]
    public init(code: String, owner: String, name: String, cover: String?, tracks: [Track]) {
        self.code = code
        self.owner = owner
        self.name = name
        self.cover = cover
        self.tracks = tracks
    }
}

public struct EditorialItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var description: String
    public var cover: String
}

/// Что скрывается за короткой ссылкой на трек.
public struct SharedTrack: Equatable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var artwork: String
    public init(id: String, title: String, artist: String, artwork: String) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artwork = artwork
    }

    /// Трек в форме плеера: лицензионные `b:<uuid>` играют из каталога Blink, остальные ищутся по названию.
    public func toTrack() -> Track {
        if id.hasPrefix("b:") {
            return Track(id: id, title: title, artist: artist, artwork: artwork, source: Track.sourceBlink, lic: String(id.dropFirst(2)))
        }
        return Track(id: id, title: title, artist: artist, artwork: artwork)
    }
}

public struct SharedError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Запросы к PostgREST Supabase с зеркалом на сайте (supabase.co режут операторы). Анонимный ключ или токен пользователя.
final class SupabaseRest: @unchecked Sendable {
    private let http: HTTPClient
    private let config: BlinkConfig
    private let tokens: TokenProvider?

    init(http: HTTPClient, config: BlinkConfig, tokens: TokenProvider?) {
        self.http = http
        self.config = config
        self.tokens = tokens
    }

    private func roots() -> [String] {
        return config.supabaseMirror == config.supabase ? [config.supabase] : [config.supabaseMirror, config.supabase]
    }

    func call(_ path: String, _ query: [(String, String)], method: String = "GET", body: Data? = nil, prefer: String? = nil, auth: Bool = false) async throws -> HTTPResponse {
        var last: Error = SharedError("нет адреса")
        let token = auth ? await tokens?.accessToken() : nil
        for root in roots() {
            guard let url = URLBuilder.make(root, path: "rest/v1/" + path, query: query) else { continue }
            var headers = ["apikey": config.supabaseAnonKey, "Accept": "application/json", "Authorization": "Bearer " + (token ?? config.supabaseAnonKey)]
            if body != nil { headers["Content-Type"] = "application/json" }
            if let p = prefer { headers["Prefer"] = p }
            do {
                return try await http.send(HTTPRequest(url: url, method: method, headers: headers, body: body, timeout: 20))
            } catch {
                last = error
            }
        }
        throw last
    }

}

/// Общие плейлисты (таблицы `shared_playlists`, `editorial_playlists`) и короткие ссылки на треки (`/api/share/track`).
public final class SharedApi: @unchecked Sendable {
    private let http: HTTPClient
    private let config: BlinkConfig
    private let tokens: TokenProvider?
    private let userId: @Sendable () -> String?
    private let userName: @Sendable () -> String?
    private let db: SupabaseRest

    public init(http: HTTPClient, config: BlinkConfig, tokens: TokenProvider?, userId: @escaping @Sendable () -> String?, userName: @escaping @Sendable () -> String?) {
        self.http = http
        self.config = config
        self.tokens = tokens
        self.userId = userId
        self.userName = userName
        self.db = SupabaseRest(http: http, config: config, tokens: tokens)
    }

    private func rest(_ path: String, _ query: [(String, String)], method: String = "GET", body: Data? = nil, prefer: String? = nil, auth: Bool = false) async throws -> HTTPResponse {
        return try await db.call(path, query, method: method, body: body, prefer: prefer, auth: auth)
    }

    private func tracks(_ v: Any?) -> [Track] {
        guard let arr = v as? [Any], let data = try? JSONSerialization.data(withJSONObject: arr),
              let list = try? JSONDecoder().decode([LossyTrack].self, from: data) else { return [] }
        return list.compactMap { $0.track }
    }

    public func fetchShared(_ code: String) async throws -> SharedPlaylist? {
        let res = try await rest("shared_playlists", [("select", "code,owner_name,data"), ("code", "eq." + code)])
        if !res.ok { throw ServerError("shared", res.status) }
        guard let row = (BlinkJSON.array(res.text)?.first) as? [String: Any], let d = row["data"] as? [String: Any] else { return nil }
        return SharedPlaylist(code: code, owner: JSONField.string(row, "owner_name") ?? "", name: JSONField.string(d, "name") ?? "", cover: JSONField.string(d, "cover"), tracks: tracks(d["tracks"]))
    }

    public func editorial() async throws -> [EditorialItem] {
        let res = try await rest("editorial_playlists", [("select", "id,title,description,cover_url,art:tracks->0->>artwork"), ("published", "eq.true"), ("order", "position,created_at.desc"), ("limit", "24")])
        if !res.ok { throw ServerError("editorial", res.status) }
        var out: [EditorialItem] = []
        for e in BlinkJSON.array(res.text) ?? [] {
            guard let o = e as? [String: Any], let id = JSONField.string(o, "id") else { continue }
            out.append(EditorialItem(id: id, title: JSONField.string(o, "title") ?? "", description: JSONField.string(o, "description") ?? "", cover: JSONField.string(o, "cover_url") ?? JSONField.string(o, "art") ?? ""))
        }
        return out
    }

    public func editorialOne(_ id: String) async throws -> SharedPlaylist? {
        let res = try await rest("editorial_playlists", [("select", "id,title,description,cover_url,tracks"), ("id", "eq." + id), ("published", "eq.true")])
        if !res.ok { throw ServerError("editorial", res.status) }
        guard let o = (BlinkJSON.array(res.text)?.first) as? [String: Any] else { return nil }
        return SharedPlaylist(code: id, owner: "Blink", name: JSONField.string(o, "title") ?? "", cover: JSONField.string(o, "cover_url"), tracks: tracks(o["tracks"]))
    }

    /// Поделиться своим плейлистом: возвращает ссылку `blinkmusic.cc/p/<код>`. Повторный вызов обновляет те же данные.
    public func share(_ p: Playlist, code: () -> String = SharedApi.newCode) async throws -> String {
        guard let uid = userId() else { throw SharedError("Войдите в аккаунт") }
        let found = try await rest("shared_playlists", [("select", "code"), ("owner_id", "eq." + uid), ("playlist_id", "eq." + p.id)], auth: true)
        let existing = found.ok ? ((BlinkJSON.array(found.text)?.first) as? [String: Any]).flatMap { JSONField.string($0, "code") } : nil
        let c = existing ?? code()
        let data: JSONValue = .object([
            "name": .string(p.name),
            "cover": p.cover.map { JSONValue.string($0) } ?? .null,
            "tracks": .array(p.tracks.prefix(500).compactMap { $0.asJSON() }),
        ])
        let row: JSONValue = .object([
            "code": .string(c),
            "owner_id": .string(uid),
            "owner_name": .string(userName() ?? ""),
            "playlist_id": .string(p.id),
            "data": data,
            "updated_at": .string(ISO8601DateFormatter().string(from: Date())),
        ])
        guard let body = try? JSONEncoder().encode(row) else { throw SharedError("Не получилось поделиться") }
        let res: HTTPResponse
        if existing != nil {
            res = try await rest("shared_playlists", [("code", "eq." + c)], method: "PATCH", body: body, prefer: "return=minimal", auth: true)
        } else {
            res = try await rest("shared_playlists", [], method: "POST", body: body, prefer: "return=minimal", auth: true)
        }
        if !res.ok { throw SharedError("Не получилось поделиться") }
        return SharedApi.link(c)
    }

    public func unshare(_ p: Playlist) async throws {
        guard let uid = userId() else { throw SharedError("Войдите в аккаунт") }
        let res = try await rest("shared_playlists", [("owner_id", "eq." + uid), ("playlist_id", "eq." + p.id)], method: "DELETE", auth: true)
        if !res.ok { throw SharedError("Не получилось закрыть доступ") }
    }

    /// Короткая ссылка на трек (`blinkmusic.cc/t/<7 символов>`); без сети или со старым сервером длинная ссылка.
    public func trackLink(_ t: Track) async -> String {
        if SharedApi.isDigits(t.id) { return longTrackLink(t) }
        let body: [String: Any] = ["id": t.id, "title": t.title, "artist": t.artist, "artwork": t.artwork]
        if let url = URLBuilder.make(config.base, path: "api/share/track"), let data = try? JSONSerialization.data(withJSONObject: body),
           let res = try? await http.send(HTTPRequest(url: url, method: "POST", headers: ["Content-Type": "application/json"], body: data, timeout: 5)),
           res.status == 200, let o = BlinkJSON.object(res.text), let code = JSONField.string(o, "code"), SharedApi.isShortCode(code) {
            return config.base + "/t/" + code
        }
        return longTrackLink(t)
    }

    public func longTrackLink(_ t: Track) -> String {
        let id = URLBuilder.encode(t.id)
        if SharedApi.isDigits(t.id) || SharedApi.isLicensedId(t.id) { return config.base + "/t/" + id }
        return config.base + "/t/" + id + "?n=" + URLBuilder.encode(t.title) + "&a=" + URLBuilder.encode(t.artist)
    }

    /// Что играет по короткому коду (`/t/Xk3p9aQ`); nil, если код не найден.
    public func resolveTrack(_ code: String) async -> SharedTrack? {
        guard let url = URLBuilder.make(config.base, path: "api/share/track/" + code),
              let res = try? await http.send(HTTPRequest(url: url, headers: ["Accept": "application/json"], timeout: 10)),
              res.status == 200, let o = BlinkJSON.object(res.text), let id = JSONField.string(o, "id") else { return nil }
        return SharedTrack(id: id, title: JSONField.string(o, "title") ?? "", artist: JSONField.string(o, "artist") ?? "", artwork: JSONField.string(o, "artwork") ?? "")
    }

    static func isDigits(_ s: String) -> Bool {
        return !s.isEmpty && s.count <= 15 && s.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    static func isLicensedId(_ s: String) -> Bool {
        guard s.hasPrefix("b:") else { return false }
        let rest = s.dropFirst(2)
        return rest.count == 36 && rest.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    static let shortAlphabet = Set("23456789abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ")

    public static func isShortCode(_ s: String) -> Bool {
        return s.count == 7 && s.allSatisfy { shortAlphabet.contains($0) }
    }

    public static func newCode() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<10).map { _ in letters[Int.random(in: 0..<letters.count)] })
    }

    public static func link(_ code: String) -> String { return "https://blinkmusic.cc/p/" + code }
}

/// Декодер, который не падает на одном битом треке из плейлиста.
private struct LossyTrack: Decodable {
    let track: Track?
    init(from decoder: Decoder) throws {
        track = try? Track(from: decoder)
    }
}

/// Ссылки, которые открывают приложение: что внутри и какой код.
public enum DeepLink: Equatable, Sendable {
    case room(String)
    case friend(String)
    case playlist(String)
    /// `ref` — короткий код или id; у длинных ссылок рядом название и исполнитель.
    case track(ref: String, title: String, artist: String)
    case artist(String)

    static func query(_ url: String, _ key: String) -> String? {
        guard let q = url.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first else { return nil }
        let body = q.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        for part in body.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.count == 2, kv[0] == key {
                let v = String(kv[1]).replacingOccurrences(of: "+", with: "%20").removingPercentEncoding ?? String(kv[1])
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    /// Разбирает ссылку из браузера, мессенджера или `blink://`. nil, если это не наша ссылка.
    public static func parse(_ url: String?) -> DeepLink? {
        guard let url = url, !url.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let v = query(url, "together") { return .room(v) }
        if let v = query(url, "friend") { return .friend(v) }
        if let v = query(url, "playlist") { return .playlist(v) }
        if let v = query(url, "artist") { return .artist(v.lowercased()) }
        if let v = query(url, "track") { return .track(ref: v, title: query(url, "n") ?? "", artist: query(url, "a") ?? "") }
        let lower = url.lowercased()
        guard let hostRange = lower.range(of: "^https?://(www\\.|t\\.)?blinkmusic\\.cc", options: .regularExpression) else { return nil }
        let host = String(lower[lower.range(of: "://")!.upperBound..<hostRange.upperBound])
        var rest = String(url.dropFirst(lower.distance(from: lower.startIndex, to: hostRange.upperBound)))
        if let i = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = String(rest[..<i]) }
        let seg = rest.split(separator: "/").map(String.init)
        func dec(_ s: String) -> String { return s.removingPercentEncoding ?? s }
        if host == "t.blinkmusic.cc", seg.count == 1 { return .track(ref: dec(seg[0]), title: "", artist: "") }
        guard seg.count >= 2 else { return nil }
        let v = dec(seg[1])
        switch seg[0] {
        case "r": return matches(v, "^[A-Za-z0-9_-]{4,40}$") ? .room(v) : nil
        case "p": return matches(v, "^[A-Za-z0-9]+$") ? .playlist(v) : nil
        case "u": return matches(v, "^[A-Za-z0-9_.-]+$") ? .artist(v.lowercased()) : nil
        case "t": return .track(ref: v, title: query(url, "n") ?? "", artist: query(url, "a") ?? "")
        default: return nil
        }
    }
}
