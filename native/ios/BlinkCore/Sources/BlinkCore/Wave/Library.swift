import Foundation

/// Что лежит на диске: лайки и история как исходные JSON-объекты (чтобы при записи обратно не потерять поля,
/// которые знает только сайт), и остальное содержимое `data` таблицы `library` (плейлисты, nowPlaying).
public struct LibraryData: Codable, Equatable, Sendable {
    public var likes: [JSONValue] = []
    public var recent: [JSONValue] = []
    public var extra: [String: JSONValue] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey { case likes, recent, extra }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        likes = (try? c.decodeIfPresent([JSONValue].self, forKey: .likes)) ?? []
        recent = (try? c.decodeIfPresent([JSONValue].self, forKey: .recent)) ?? []
        extra = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .extra)) ?? [:]
    }
}

private func jsonId(_ v: JSONValue) -> String? {
    guard let o = v.objectValue, let id = o["id"] else { return nil }
    switch id {
    case let .string(s): return s
    case let .number(d): return d == d.rounded() ? String(Int64(d)) : String(d)
    default: return nil
    }
}

/// Плейлист пользователя.
public struct Playlist: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var created: Int64
    public var tracks: [Track]
    public var cover: String?
    public init(id: String, name: String, created: Int64, tracks: [Track], cover: String? = nil) {
        self.id = id
        self.name = name
        self.created = created
        self.tracks = tracks
        self.cover = cover
    }
}

/// Лайки и недавнее на устройстве. Основа вкуса Вспышки и синка с сайтом. Новые треки первыми, как на сайте.
public final class LibraryStore: Library, @unchecked Sendable {
    public static let recentMax = 60

    private let lock = NSLock()
    private let blob: BlobStore
    private var data: LibraryData
    private var cached: (likes: [Track], recent: [Track])?
    private let version = Observable<Int>(0)

    public init(_ blob: BlobStore) {
        self.blob = blob
        if let text = blob.load(), let d = BlinkJSON.decode(LibraryData.self, from: text) {
            data = d
        } else {
            data = LibraryData()
        }
    }

    public var state: LibraryData {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    private func tracks() -> (likes: [Track], recent: [Track]) {
        lock.lock()
        defer { lock.unlock() }
        if let c = cached { return c }
        let c = (data.likes.compactMap { Track.from(json: $0) }, data.recent.compactMap { Track.from(json: $0) })
        cached = c
        return c
    }

    public var likes: [Track] { return tracks().likes }
    public var recent: [Track] { return tracks().recent }

    public func isLiked(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return data.likes.contains { jsonId($0) == id }
    }

    /// Меняется при каждом изменении лайков и истории: для обновления экранов.
    @discardableResult
    public func observe(_ handler: @escaping @Sendable (Int) -> Void) -> NetworkObservation {
        return version.observe(handler)
    }

    private func commitLocked() {
        cached = nil
        blob.save(BlinkJSON.encode(data))
    }

    private func changed() {
        version.update { $0 += 1 }
    }

    /// Сердечко: ставит или снимает лайк. Возвращает «теперь лайкнут».
    @discardableResult
    public func toggleLike(_ track: Track) -> Bool {
        lock.lock()
        let liked: Bool
        if data.likes.contains(where: { jsonId($0) == track.id }) {
            data.likes.removeAll { jsonId($0) == track.id }
            liked = false
        } else if let raw = track.asJSON() {
            data.likes.insert(raw, at: 0)
            liked = true
        } else {
            lock.unlock()
            return false
        }
        commitLocked()
        lock.unlock()
        changed()
        return liked
    }

    /// Добавляет в «Любимое» треки, которых там ещё нет (перенос музыки). Возвращает, сколько добавилось.
    @discardableResult
    public func addLikes(_ tracks: [Track]) -> Int {
        lock.lock()
        var have = Set(data.likes.compactMap { jsonId($0) })
        var fresh: [JSONValue] = []
        for t in tracks where have.insert(t.id).inserted {
            if let raw = t.asJSON() { fresh.append(raw) }
        }
        if fresh.isEmpty {
            lock.unlock()
            return 0
        }
        data.likes = fresh + data.likes
        commitLocked()
        lock.unlock()
        changed()
        return fresh.count
    }

    /// Трек начал играть: наверх истории, без дублей, до 60.
    public func noteRecent(_ track: Track) {
        guard let raw = track.asJSON() else { return }
        lock.lock()
        data.recent.removeAll { jsonId($0) == track.id }
        data.recent.insert(raw, at: 0)
        if data.recent.count > LibraryStore.recentMax { data.recent = Array(data.recent.prefix(LibraryStore.recentMax)) }
        commitLocked()
        lock.unlock()
        changed()
    }

    // ---------- плейлисты (лежат в `extra.playlists`, как у сайта: {id, name, tracks, created, cover?}) ----------

    private func rawPlaylistsLocked() -> [[String: JSONValue]] {
        if case let .array(a)? = data.extra["playlists"] { return a.compactMap { $0.objectValue } }
        return []
    }

    private func setPlaylistsLocked(_ list: [[String: JSONValue]]) {
        data.extra["playlists"] = .array(list.map { JSONValue.object($0) })
    }

    private static func playlist(_ o: [String: JSONValue]) -> Playlist? {
        guard let id = jsonId(.object(o)) else { return nil }
        var tracks: [Track] = []
        if case let .array(a)? = o["tracks"] { tracks = a.compactMap { Track.from(json: $0) } }
        var created: Int64 = 0
        if case let .number(d)? = o["created"] { created = Int64(d) }
        return Playlist(id: id, name: o["name"]?.stringValue ?? "", created: created, tracks: tracks, cover: o["cover"]?.stringValue)
    }

    /// Мои плейлисты, новые первыми.
    public var playlists: [Playlist] {
        lock.lock()
        defer { lock.unlock() }
        return rawPlaylistsLocked().compactMap { LibraryStore.playlist($0) }
    }

    public func playlist(_ id: String) -> Playlist? {
        return playlists.first { $0.id == id }
    }

    @discardableResult
    public func createPlaylist(_ name: String, tracks: [Track] = [], now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Playlist {
        let id = "p" + String(now, radix: 36)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Новый плейлист" : trimmed
        let obj: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(title),
            "tracks": .array(tracks.compactMap { $0.asJSON() }),
            "created": .number(Double(now)),
        ]
        lock.lock()
        setPlaylistsLocked([obj] + rawPlaylistsLocked())
        commitLocked()
        lock.unlock()
        changed()
        return Playlist(id: id, name: title, created: now, tracks: tracks)
    }

    /// false, если такой трек в плейлисте уже есть.
    @discardableResult
    public func addToPlaylist(_ pid: String, _ track: Track) -> Bool {
        guard let raw = track.asJSON() else { return false }
        lock.lock()
        var added = false
        var list = rawPlaylistsLocked()
        for i in list.indices where jsonId(.object(list[i])) == pid {
            var tr: [JSONValue] = []
            if case let .array(a)? = list[i]["tracks"] { tr = a }
            if tr.contains(where: { jsonId($0) == track.id }) { break }
            tr.append(raw)
            list[i]["tracks"] = .array(tr)
            added = true
        }
        if added {
            setPlaylistsLocked(list)
            commitLocked()
        }
        lock.unlock()
        if added { changed() }
        return added
    }

    public func removeFromPlaylist(_ pid: String, _ trackId: String) {
        lock.lock()
        var list = rawPlaylistsLocked()
        for i in list.indices where jsonId(.object(list[i])) == pid {
            if case let .array(a)? = list[i]["tracks"] { list[i]["tracks"] = .array(a.filter { jsonId($0) != trackId }) }
        }
        setPlaylistsLocked(list)
        commitLocked()
        lock.unlock()
        changed()
    }

    public func renamePlaylist(_ pid: String, _ name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return }
        lock.lock()
        var list = rawPlaylistsLocked()
        for i in list.indices where jsonId(.object(list[i])) == pid { list[i]["name"] = .string(title) }
        setPlaylistsLocked(list)
        commitLocked()
        lock.unlock()
        changed()
    }

    public func deletePlaylist(_ pid: String) {
        lock.lock()
        setPlaylistsLocked(rawPlaylistsLocked().filter { jsonId(.object($0)) != pid })
        commitLocked()
        lock.unlock()
        changed()
    }

    /// Как `mergePlaylists` сайта: свои поля побеждают, треки без повторов, новые первыми.
    static func mergePlaylists(_ local: [[String: JSONValue]], _ remote: [[String: JSONValue]]) -> [[String: JSONValue]] {
        var order: [String] = []
        var map: [String: [String: JSONValue]] = [:]
        for r in remote {
            guard let id = jsonId(.object(r)) else { continue }
            if map[id] == nil { order.append(id) }
            map[id] = r
        }
        for p in local {
            guard let id = jsonId(.object(p)) else { continue }
            if var r = map[id] {
                var lt: [JSONValue] = []
                var rt: [JSONValue] = []
                if case let .array(a)? = p["tracks"] { lt = a }
                if case let .array(a)? = r["tracks"] { rt = a }
                for (k, v) in p { r[k] = v }
                r["tracks"] = .array(mergeById(lt, rt))
                map[id] = r
            } else {
                order.append(id)
                map[id] = p
            }
        }
        func created(_ o: [String: JSONValue]) -> Double {
            if case let .number(d)? = o["created"] { return d }
            return 0
        }
        return order.compactMap { map[$0] }.sorted { created($0) > created($1) }
    }

    static func mergeById(_ a: [JSONValue], _ b: [JSONValue]) -> [JSONValue] {
        var seen = Set<String>()
        var out: [JSONValue] = []
        for x in a + b {
            guard let id = jsonId(x) else { continue }
            if seen.insert(id).inserted { out.append(x) }
        }
        return out
    }

    /// Слияние с копией с сервера (как `pull` на сайте): локальное первым, затем чужое без повторов по id.
    public func mergeRemote(_ remote: [String: JSONValue]) {
        lock.lock()
        var rl: [JSONValue] = []
        var rr: [JSONValue] = []
        if case let .array(a)? = remote["likes"] { rl = a }
        if case let .array(a)? = remote["recent"] { rr = a }
        var extra = remote
        extra.removeValue(forKey: "likes")
        extra.removeValue(forKey: "recent")
        data.likes = LibraryStore.mergeById(data.likes, rl)
        data.recent = Array(LibraryStore.mergeById(data.recent, rr).prefix(LibraryStore.recentMax))
        var remotePlaylists: [[String: JSONValue]] = []
        if case let .array(a)? = remote["playlists"] { remotePlaylists = a.compactMap { $0.objectValue } }
        let merged = LibraryStore.mergePlaylists(rawPlaylistsLocked(), remotePlaylists)
        data.extra = extra
        if !merged.isEmpty { setPlaylistsLocked(merged) }
        commitLocked()
        lock.unlock()
        changed()
    }

    /// Что записать в `data` строки `library`: наши лайки и история поверх остального, что прислал сервер.
    public func snapshot(device: String) -> [String: JSONValue] {
        let d = state
        var out = d.extra
        out["likes"] = .array(d.likes)
        out["recent"] = .array(d.recent)
        out["device"] = .string(device)
        return out
    }
}

/// Обмен лайками и историей с таблицей `library` в Supabase (одна строка на пользователя, `data` jsonb целиком).
public actor LibrarySync {
    private let http: HTTPClient
    private let config: BlinkConfig
    private let tokens: TokenProvider
    private let library: LibraryStore
    private let userId: @Sendable () -> String?
    private let device: String
    private var useMirror = false
    private var lastPushed = ""

    public init(http: HTTPClient, config: BlinkConfig, tokens: TokenProvider, library: LibraryStore, userId: @escaping @Sendable () -> String?, device: String? = nil) {
        self.http = http
        self.config = config
        self.tokens = tokens
        self.library = library
        self.userId = userId
        self.device = device ?? "native-" + String(UUID().uuidString.prefix(8)).lowercased()
    }

    private func roots() -> [String] {
        if config.supabaseMirror == config.supabase { return [config.supabase] }
        return useMirror ? [config.supabaseMirror, config.supabase] : [config.supabase, config.supabaseMirror]
    }

    private func request(_ build: (URL) -> HTTPRequest?) async -> HTTPResponse? {
        for root in roots() {
            guard let base = URL(string: root), let req = build(base) else { continue }
            do {
                let res = try await http.send(req)
                if config.supabaseMirror != config.supabase { useMirror = root == config.supabaseMirror }
                return res
            } catch {
                continue
            }
        }
        return nil
    }

    private func endpoint(_ root: URL, _ query: [(String, String)]) -> URL? {
        return URLBuilder.make(root.absoluteString, path: "rest/v1/library", query: query)
    }

    /// Забирает серверную копию, сливает с локальной и сразу пишет результат обратно. false, если не вошли или сервер молчит.
    public func pull() async -> Bool {
        guard let uid = userId(), let token = await tokens.accessToken() else { return false }
        let anon = config.supabaseAnonKey
        guard let res = await request({ root in
            guard let url = self.endpoint(root, [("select", "data"), ("user_id", "eq." + uid)]) else { return nil }
            return HTTPRequest(url: url, headers: ["apikey": anon, "Authorization": "Bearer " + token, "Accept": "application/json"], timeout: 25)
        }), res.ok else { return false }
        guard let rows = try? JSONDecoder().decode([JSONValue].self, from: res.data) else { return false }
        var remote: [String: JSONValue] = [:]
        if let first = rows.first?.objectValue, case let .object(d)? = first["data"] { remote = d }
        library.mergeRemote(remote)
        return await push(force: true)
    }

    /// Пишет лайки и историю в `library`. Без изменений с прошлой записи ничего не шлёт.
    public func push(force: Bool = false) async -> Bool {
        guard let uid = userId(), let token = await tokens.accessToken() else { return false }
        let data = library.snapshot(device: device)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var stable = data
        stable.removeValue(forKey: "device")
        let key = (try? enc.encode(JSONValue.object(stable))).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if !force && key == lastPushed { return true }
        let row: JSONValue = .object([
            "user_id": .string(uid),
            "data": .object(data),
            "updated_at": .string(ISO8601DateFormatter().string(from: Date())),
        ])
        guard let body = try? enc.encode(row) else { return false }
        let anon = config.supabaseAnonKey
        guard let res = await request({ root in
            guard let url = self.endpoint(root, []) else { return nil }
            return HTTPRequest(
                url: url,
                method: "POST",
                headers: ["apikey": anon, "Authorization": "Bearer " + token, "Content-Type": "application/json", "Prefer": "resolution=merge-duplicates,return=minimal"],
                body: body,
                timeout: 25
            )
        }), res.ok else { return false }
        lastPushed = key
        return true
    }
}
