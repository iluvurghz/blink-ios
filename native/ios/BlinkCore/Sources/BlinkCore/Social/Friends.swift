import Foundation

public struct FriendTrack: Equatable, Sendable {
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
}

public struct Friend: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var avatar: String
    public var track: FriendTrack?
    public var room: String?
    public init(id: String, name: String, avatar: String, track: FriendTrack?, room: String?) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.track = track
        self.room = room
    }
    public var listening: Bool { return track != nil }
}

public struct FriendsList: Equatable, Sendable {
    public var friends: [Friend]
    public var hidden: Bool
    public init(friends: [Friend], hidden: Bool) {
        self.friends = friends
        self.hidden = hidden
    }
}

public struct FriendsError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Друзья: приглашение по ссылке и «слушает сейчас». Форма снята с `server/friendsRoute.js`.
public protocol FriendsService: Sendable {
    func list() async throws -> FriendsList?
    /// Код моего приглашения (живёт 7 дней).
    func invite() async throws -> String?
    /// Принять приглашение; вернёт имя друга или бросит `FriendsError` с текстом сервера.
    func accept(_ code: String) async throws -> String
    func remove(_ id: String) async throws -> Bool
    func setHidden(_ hidden: Bool) async throws -> Bool
    func activity(track: FriendTrack?, room: String) async
}

public final class FriendsApi: FriendsService, @unchecked Sendable {
    private let http: HTTPClient
    private let config: BlinkConfig
    private let tokens: TokenProvider?

    public init(http: HTTPClient, config: BlinkConfig, tokens: TokenProvider?) {
        self.http = http
        self.config = config
        self.tokens = tokens
    }

    private func call(_ path: String, body: [String: Any]?) async throws -> (Int, [String: Any]?) {
        guard let url = URLBuilder.make(config.base, path: path) else { throw FriendsError("Не получилось") }
        var headers = ["Accept": "application/json"]
        if let t = await tokens?.accessToken() { headers["Authorization"] = "Bearer " + t }
        var data: Data?
        if let b = body {
            headers["Content-Type"] = "application/json"
            data = try? JSONSerialization.data(withJSONObject: b)
        }
        let res = try await http.send(HTTPRequest(url: url, method: body == nil ? "GET" : "POST", headers: headers, body: data, timeout: 10))
        return (res.status, BlinkJSON.object(res.text))
    }

    public func list() async throws -> FriendsList? {
        let (code, o) = try await call("api/friends", body: nil)
        guard code == 200, let obj = o else { return nil }
        var friends: [Friend] = []
        for e in JSONField.array(obj, "friends") ?? [] {
            guard let f = e as? [String: Any], let id = JSONField.string(f, "id") else { continue }
            let l = JSONField.object(f, "listening")
            let t = l.flatMap { JSONField.object($0, "track") }
            let track = t.map {
                FriendTrack(id: JSONField.string($0, "id") ?? "", title: JSONField.string($0, "title") ?? "", artist: JSONField.string($0, "artist") ?? "", artwork: JSONField.string($0, "artwork") ?? "")
            }
            let room = l.flatMap { JSONField.string($0, "room") }.flatMap { $0.isEmpty ? nil : $0 }
            friends.append(Friend(id: id, name: JSONField.string(f, "name") ?? "", avatar: JSONField.string(f, "avatar") ?? "", track: track, room: room))
        }
        return FriendsList(friends: friends, hidden: JSONField.bool(obj, "hidden") == true)
    }

    public func invite() async throws -> String? {
        let (code, o) = try await call("api/friends/link", body: [:])
        return code == 200 ? o.flatMap { JSONField.string($0, "code") } : nil
    }

    public func accept(_ code: String) async throws -> String {
        let (status, o) = try await call("api/friends/accept", body: ["code": code])
        if status == 200 { return o.flatMap { JSONField.object($0, "friend") }.flatMap { JSONField.string($0, "name") } ?? "Друг" }
        throw FriendsError(o.flatMap { JSONField.string($0, "error") } ?? "Не получилось добавить")
    }

    public func remove(_ id: String) async throws -> Bool {
        return try await call("api/friends/remove", body: ["id": id]).0 == 200
    }

    public func setHidden(_ hidden: Bool) async throws -> Bool {
        return try await call("api/friends/hidden", body: ["hidden": hidden]).0 == 200
    }

    public func activity(track: FriendTrack?, room: String) async {
        var body: [String: Any] = ["room": room]
        if let t = track { body["track"] = ["id": t.id, "title": t.title, "artist": t.artist, "artwork": t.artwork] }
        _ = try? await call("api/friends/activity", body: body)
    }

    /// Код приглашения из ссылки (`?friend=<код>`) или nil.
    public static func codeFrom(_ url: String?) -> String? {
        guard let url = url, !url.isEmpty, let re = try? NSRegularExpression(pattern: "[?&]friend=([A-Za-z0-9_-]{4,64})") else { return nil }
        let ns = url as NSString
        guard let m = re.firstMatch(in: url, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    public static func link(_ code: String) -> String { return "https://blinkmusic.cc/?friend=" + code }
}

public struct FriendsUi: Equatable, Sendable {
    public var friends: [Friend] = []
    public var hidden = false
    public var loading = false
    public var loaded = false
    public var offline = false
    public init() {}
}

/// Список друзей на экране и то, что мы сами показываем друзьям.
public final class FriendsModel: @unchecked Sendable {
    private let service: FriendsService
    private let say: @Sendable (String) -> Void
    private let state = Observable(FriendsUi())
    private let lock = NSLock()
    private var lastKey = ""

    public init(service: FriendsService, say: @escaping @Sendable (String) -> Void) {
        self.service = service
        self.say = say
    }

    public var current: FriendsUi { return state.current }

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (FriendsUi) -> Void) -> NetworkObservation {
        return state.observe(handler)
    }

    public func refresh() async {
        state.update { $0.loading = true }
        let list = try? await service.list()
        if let l = list {
            state.update {
                $0.friends = l.friends
                $0.hidden = l.hidden
                $0.loading = false
                $0.loaded = true
                $0.offline = false
            }
        } else {
            state.update {
                $0.loading = false
                $0.offline = true
            }
        }
    }

    public func clear() { state.update { $0 = FriendsUi() } }

    public func invite() async -> String? {
        do {
            if let code = try await service.invite() { return FriendsApi.link(code) }
            say("Не получилось создать ссылку")
        } catch {
            say("Нет связи с сервером")
        }
        return nil
    }

    @discardableResult
    public func accept(_ code: String) async -> Bool {
        do {
            let name = try await service.accept(code)
            say("Теперь вы друзья с " + name)
            await refresh()
            return true
        } catch let e as FriendsError {
            say(e.message)
        } catch {
            say("Нет связи с сервером")
        }
        return false
    }

    public func remove(_ id: String) async {
        let ok = (try? await service.remove(id)) ?? false
        if ok { state.update { $0.friends.removeAll { $0.id == id } } } else { say("Не получилось удалить") }
    }

    public func setHidden(_ hidden: Bool) async {
        state.update { $0.hidden = hidden }
        let ok = (try? await service.setHidden(hidden)) ?? false
        if !ok {
            state.update { $0.hidden = !hidden }
            say("Не получилось сохранить")
        }
    }

    /// Зовём на каждое изменение плеера или комнаты. Шлём, когда сменился трек или комната, и раз в 45 секунд, пока играем.
    public func report(playing: Bool, track: Track?, room: String?, force: Bool = false) {
        if state.current.hidden { return }
        let t = playing ? track : nil
        let code = room ?? ""
        let key = t.map { $0.id + "|" + code } ?? ""
        lock.lock()
        if !force && key == lastKey {
            lock.unlock()
            return
        }
        lastKey = key
        lock.unlock()
        let ft = t.map { FriendTrack(id: $0.id, title: $0.title, artist: $0.artist, artwork: $0.artwork) }
        let service = self.service
        Task { await service.activity(track: ft, room: code) }
    }
}

/// «Я здесь» для счётчика онлайна в админке: случайный id устройства, больше ничего об аккаунте.
public final class PresenceBeat: @unchecked Sendable {
    private let http: HTTPClient
    private let config: BlinkConfig
    private let store: KeyValue

    public init(http: HTTPClient, config: BlinkConfig, store: KeyValue) {
        self.http = http
        self.config = config
        self.store = store
    }

    private func deviceId() -> String {
        if let id = store.get("presence.device") { return id }
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
        store.put("presence.device", id)
        return id
    }

    public func beat(playing: Bool, track: Track?) {
        var body: [String: Any] = ["device": deviceId(), "platform": "app", "playing": playing && track != nil]
        if let t = track {
            body["track"] = ["id": t.id, "title": t.title, "artist": t.artist, "source": (t.source == "blink" || t.source == "jamendo") ? t.source! : "youtube"]
        }
        guard let url = URLBuilder.make(config.base, path: "api/presence"), let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let http = self.http
        Task { _ = try? await http.send(HTTPRequest(url: url, method: "POST", headers: ["Content-Type": "application/json"], body: data, timeout: 10)) }
    }
}
