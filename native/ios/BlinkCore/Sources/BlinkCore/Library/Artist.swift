import Foundation

/// Публичная страница артиста Blink: `blinkmusic.cc/u/<имя>`.
public struct ArtistProfile: Equatable, Sendable {
    public var id: String
    public var userId: String?
    public var name: String
    public var handle: String?
    public var bio: String?
    public var avatar: String?
    public var verified: Bool
    public var tracks: [Track]
    public var followers: Int64
    public var likes: Int64
}

public final class ArtistApi: @unchecked Sendable {
    private let db: SupabaseRest
    private let api: BlinkApi
    private let userId: @Sendable () -> String?

    public init(http: HTTPClient, config: BlinkConfig, tokens: TokenProvider?, api: BlinkApi, userId: @escaping @Sendable () -> String?) {
        self.db = SupabaseRest(http: http, config: config, tokens: tokens)
        self.api = api
        self.userId = userId
    }

    private static func isUUID(_ s: String) -> Bool {
        return s.count == 36 && s.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    public static func today() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Страница по id или имени ссылки; nil, если такой нет. Сетевой сбой бросает ошибку.
    public func profile(_ key: String, today: String = ArtistApi.today()) async throws -> ArtistProfile? {
        let res = try await db.call("artists", [("select", "id,user_id,name,handle,bio,avatar_url,verified"), (ArtistApi.isUUID(key) ? "id" : "handle", "eq." + key)])
        if !res.ok { throw ServerError("artist", res.status) }
        guard let a = (BlinkJSON.array(res.text)?.first) as? [String: Any], let id = JSONField.string(a, "id") else { return nil }
        let name = JSONField.string(a, "name") ?? ""
        let verified = JSONField.bool(a, "verified") == true
        let own = try await tracks([("artist_id", "eq." + id)], today)
        var label: [Track] = []
        if verified {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            label = try await tracks([("source", "eq.partner"), ("artist_name", "ilike." + escaped)], today)
        }
        var followers: Int64 = 0
        var likes: Int64 = 0
        if let stats = try? await db.call("rpc/artist_stats", [], method: "POST", body: try? JSONSerialization.data(withJSONObject: ["aid": id])), stats.ok,
           let row = (BlinkJSON.array(stats.text)?.first) as? [String: Any] {
            followers = JSONField.int64(row, "followers") ?? 0
            likes = JSONField.int64(row, "likes") ?? 0
        }
        var seen = Set<String>()
        let all = (own + label).filter { seen.insert($0.id).inserted }
        return ArtistProfile(id: id, userId: JSONField.string(a, "user_id"), name: name, handle: JSONField.string(a, "handle"), bio: JSONField.string(a, "bio"), avatar: JSONField.string(a, "avatar_url"), verified: verified, tracks: all, followers: followers, likes: likes)
    }

    private func tracks(_ filter: [(String, String)], _ today: String) async throws -> [Track] {
        let q: [(String, String)] = [("select", BlinkApi.licFields), ("status", "eq.live"), ("release_date", "lte." + today), ("order", "release_date.desc"), ("limit", "200")] + filter
        let res = try await db.call("lic_tracks", q)
        if !res.ok { return [] }
        return (BlinkJSON.array(res.text) ?? []).compactMap { ($0 as? [String: Any]).flatMap { api.fromLicRow($0) } }
    }

    public func isFollowing(_ artistId: String) async -> Bool {
        guard let uid = userId(), let res = try? await db.call("follows", [("select", "artist_id"), ("user_id", "eq." + uid), ("artist_id", "eq." + artistId)], auth: true), res.ok else { return false }
        return !(BlinkJSON.array(res.text) ?? []).isEmpty
    }

    /// Подписаться или отписаться. false, если не вышло.
    public func setFollow(_ artistId: String, _ on: Bool) async -> Bool {
        guard let uid = userId() else { return false }
        let res: HTTPResponse?
        if on {
            let body = try? JSONSerialization.data(withJSONObject: ["user_id": uid, "artist_id": artistId])
            res = try? await db.call("follows", [], method: "POST", body: body, prefer: "return=minimal", auth: true)
        } else {
            res = try? await db.call("follows", [("user_id", "eq." + uid), ("artist_id", "eq." + artistId)], method: "DELETE", auth: true)
        }
        guard let r = res else { return false }
        return r.ok || r.status == 409
    }
}
