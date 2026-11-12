import Foundation

/// Анонс артиста (таблица `posts`, ответ `post_list`).
public struct Post: Equatable, Sendable {
    public var id: String
    public var artistId: String
    public var artistName: String
    public var avatar: String?
    public var body: String
    public var trackId: String?
    public var createdAt: String
    public var likes: Int64
    public var liked: Bool
    public var track: Track?
}

/// Комментарий к анонсу или треку (ответ `comment_list`).
public struct Comment: Equatable, Sendable {
    public var id: String
    public var userId: String
    public var artistId: String?
    public var name: String
    public var avatar: String?
    public var body: String
    public var createdAt: String
}

/// «2026-11-01T10:00:00Z» → «01.11.2026».
public func dateRu(_ iso: String) -> String {
    let d = iso.prefix(10).split(separator: "-")
    return d.count == 3 ? "\(d[2]).\(d[1]).\(d[0])" : iso
}

/// Анонсы, комментарии, жалобы и правка описания артиста: то же, что делает сайт в lib/catalog.js.
public final class PostsApi: @unchecked Sendable {
    private let db: SupabaseRest
    private let api: BlinkApi
    private let userId: @Sendable () -> String?

    public init(http: HTTPClient, config: BlinkConfig, tokens: TokenProvider?, api: BlinkApi, userId: @escaping @Sendable () -> String?) {
        self.db = SupabaseRest(http: http, config: config, tokens: tokens)
        self.api = api
        self.userId = userId
    }

    private func json(_ o: [String: Any]) -> Data? { return try? JSONSerialization.data(withJSONObject: o) }
    private func orNull(_ s: String?) -> Any { return s ?? NSNull() }

    /// Анонсы одного артиста или, без id, лента тех, на кого подписан. Сетевой сбой бросает ошибку.
    public func posts(artistId: String? = nil) async throws -> [Post] {
        let res = try await db.call("rpc/post_list", [], method: "POST", body: json(["aid": orNull(artistId)]), auth: true)
        if !res.ok { throw ServerError("post_list", res.status) }
        let rows = (BlinkJSON.array(res.text) ?? []).compactMap { $0 as? [String: Any] }
        let ids = Array(Set(rows.compactMap { JSONField.string($0, "track_id") }))
        let tracks = ids.isEmpty ? [:] : await loadTracks(ids)
        return rows.compactMap { o in
            guard let id = JSONField.string(o, "id") else { return nil }
            let tid = JSONField.string(o, "track_id")
            return Post(id: id, artistId: JSONField.string(o, "artist_id") ?? "", artistName: JSONField.string(o, "artist_name") ?? "", avatar: JSONField.string(o, "avatar_url"), body: JSONField.string(o, "body") ?? "", trackId: tid, createdAt: JSONField.string(o, "created_at") ?? "", likes: JSONField.int64(o, "likes") ?? 0, liked: JSONField.bool(o, "liked") == true, track: tid.flatMap { tracks[$0] })
        }
    }

    private func loadTracks(_ ids: [String]) async -> [String: Track] {
        guard let res = try? await db.call("lic_tracks", [("select", BlinkApi.licFields), ("id", "in.(" + ids.joined(separator: ",") + ")")]), res.ok else { return [:] }
        var out: [String: Track] = [:]
        for e in BlinkJSON.array(res.text) ?? [] {
            guard let o = e as? [String: Any], let id = JSONField.string(o, "id"), let t = api.fromLicRow(o) else { continue }
            out[id] = t
        }
        return out
    }

    /// Опубликовать анонс. Сообщение ошибки уже по-русски.
    public func createPost(artistId: String, text: String, trackId: String?) async throws {
        let res = try await db.call("posts", [], method: "POST", body: json(["artist_id": artistId, "body": text, "track_id": orNull(trackId)]), prefer: "return=minimal", auth: true)
        if !res.ok { throw SharedError(res.text.contains("too_often") ? "Анонс можно публиковать раз в 10 минут" : "Не получилось опубликовать") }
    }

    public func deletePost(_ id: String) async throws {
        let res = try await db.call("posts", [("id", "eq." + id)], method: "DELETE", auth: true)
        if !res.ok { throw SharedError("Не получилось удалить") }
    }

    /// Лайк анонса. Повтор (409) не считается ошибкой.
    public func setPostLike(_ postId: String, _ on: Bool) async -> Bool {
        guard let uid = userId() else { return false }
        let res: HTTPResponse?
        if on {
            res = try? await db.call("post_likes", [], method: "POST", body: json(["user_id": uid, "post_id": postId]), prefer: "return=minimal", auth: true)
        } else {
            res = try? await db.call("post_likes", [("user_id", "eq." + uid), ("post_id", "eq." + postId)], method: "DELETE", auth: true)
        }
        guard let r = res else { return false }
        return r.ok || r.status == 409
    }

    public func comments(postId: String? = nil, trackId: String? = nil) async throws -> [Comment] {
        let res = try await db.call("rpc/comment_list", [], method: "POST", body: json(["pid": orNull(postId), "tid": orNull(trackId)]))
        if !res.ok { throw ServerError("comment_list", res.status) }
        return (BlinkJSON.array(res.text) ?? []).compactMap { e in
            guard let o = e as? [String: Any], let id = JSONField.string(o, "id") else { return nil }
            return Comment(id: id, userId: JSONField.string(o, "user_id") ?? "", artistId: JSONField.string(o, "artist_id"), name: JSONField.string(o, "name") ?? "Слушатель", avatar: JSONField.string(o, "avatar"), body: JSONField.string(o, "body") ?? "", createdAt: JSONField.string(o, "created_at") ?? "")
        }
    }

    public func addComment(_ text: String, postId: String? = nil, trackId: String? = nil) async throws {
        guard let uid = userId() else { throw SharedError("Войдите в аккаунт") }
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        if clean.isEmpty { throw SharedError("Напишите комментарий") }
        let res = try await db.call("comments", [], method: "POST", body: json(["user_id": uid, "post_id": orNull(postId), "track_id": orNull(trackId), "body": clean]), prefer: "return=minimal", auth: true)
        if !res.ok { throw SharedError(res.text.contains("too_often") ? "Слишком много комментариев, попробуйте через час" : "Не получилось отправить") }
    }

    public func deleteComment(_ id: String) async throws {
        let res = try await db.call("comments", [("id", "eq." + id)], method: "DELETE", auth: true)
        if !res.ok { throw SharedError("Не получилось удалить") }
    }

    /// Жалоба на анонс, комментарий или трек. Повтор той же жалобы (409) считается принятой.
    public func report(_ kind: String, _ targetId: String) async throws {
        guard let uid = userId() else { throw SharedError("Войдите в аккаунт") }
        let res = try await db.call("reports", [], method: "POST", body: json(["reporter_id": uid, "kind": kind, "target_id": targetId]), prefer: "return=minimal", auth: true)
        if !res.ok && res.status != 409 { throw SharedError("Не получилось отправить жалобу") }
    }

    public func saveBio(artistId: String, bio: String) async throws {
        let clean = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        let res = try await db.call("artists", [("id", "eq." + artistId)], method: "PATCH", body: json(["bio": clean.isEmpty ? (NSNull() as Any) : (clean as Any)]), prefer: "return=minimal", auth: true)
        if !res.ok { throw SharedError("Не получилось сохранить") }
    }
}
