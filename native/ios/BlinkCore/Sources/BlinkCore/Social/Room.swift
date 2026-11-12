import Foundation

/// Комната «Слушать вместе». Форма снята с `server/together.js` (поле `view`), как и на Android.
public struct RoomMember: Equatable, Sendable {
    public var id: String
    public var name: String
    public var host: Bool
    public init(id: String, name: String, host: Bool) {
        self.id = id
        self.name = name
        self.host = host
    }
}

public struct RoomChat: Equatable, Sendable {
    public var id: String
    public var by: String
    public var name: String
    public var text: String
    public var at: Int64
    public init(id: String, by: String, name: String, text: String, at: Int64) {
        self.id = id
        self.by = by
        self.name = name
        self.text = text
        self.at = at
    }
}

public struct RoomReaction: Equatable, Sendable {
    public var id: String
    public var by: String
    public var name: String
    public var emoji: String
    public var at: Int64
    public init(id: String, by: String, name: String, emoji: String, at: Int64) {
        self.id = id
        self.by = by
        self.name = name
        self.emoji = emoji
        self.at = at
    }
}

public struct RoomState: Equatable, Sendable {
    public var code: String
    /// Меняется от всего: люди, чат, плеер. По нему ждёт long poll.
    public var rev: Int64
    /// Меняется только от плеера: чат не делает чужую паузу «устаревшей».
    public var v: Int64
    public var chat: [RoomChat]
    public var track: Track?
    public var queue: [Track]
    public var index: Int
    public var playing: Bool
    /// Позиция в секундах на серверное время `at`.
    public var pos: Double
    public var at: Int64
    public var by: String?
    public var host: String?
    /// `all`: управляют все, `host`: только хост.
    public var mode: String
    public var skips: [String]
    public var reactions: [RoomReaction]
    public var members: [RoomMember]
    public var now: Int64

    public init(
        code: String, rev: Int64 = 0, v: Int64 = 0, chat: [RoomChat] = [], track: Track? = nil, queue: [Track] = [],
        index: Int = 0, playing: Bool = false, pos: Double = 0, at: Int64 = 0, by: String? = nil, host: String? = nil,
        mode: String = "all", skips: [String] = [], reactions: [RoomReaction] = [], members: [RoomMember] = [], now: Int64 = 0
    ) {
        self.code = code
        self.rev = rev
        self.v = v
        self.chat = chat
        self.track = track
        self.queue = queue
        self.index = index
        self.playing = playing
        self.pos = pos
        self.at = at
        self.by = by
        self.host = host
        self.mode = mode
        self.skips = skips
        self.reactions = reactions
        self.members = members
        self.now = now
    }

    /// Где сейчас должна быть позиция (мс) при расхождении часов `offsetMs` (серверные минус наши).
    public func targetMs(localNowMs: Int64, offsetMs: Int64) -> Int64 {
        let base = pos * 1000.0
        let moved = playing ? max(0, localNowMs + offsetMs - at) : 0
        return max(0, Int64(base + Double(moved)))
    }

    public func isHost(_ userId: String?) -> Bool {
        guard let u = userId else { return false }
        return u == host
    }

    public static func parse(_ o: [String: Any]) -> RoomState? {
        guard let code = JSONField.string(o, "code") else { return nil }
        var chat: [RoomChat] = []
        for e in JSONField.array(o, "chat") ?? [] {
            guard let c = e as? [String: Any], let id = JSONField.string(c, "id") else { continue }
            chat.append(RoomChat(id: id, by: JSONField.string(c, "by") ?? "", name: JSONField.string(c, "name") ?? "", text: JSONField.string(c, "text") ?? "", at: JSONField.int64(c, "at") ?? 0))
        }
        var reactions: [RoomReaction] = []
        for e in JSONField.array(o, "reactions") ?? [] {
            guard let r = e as? [String: Any], let id = JSONField.string(r, "id") else { continue }
            reactions.append(RoomReaction(id: id, by: JSONField.string(r, "by") ?? "", name: JSONField.string(r, "name") ?? "", emoji: JSONField.string(r, "emoji") ?? "", at: JSONField.int64(r, "at") ?? 0))
        }
        var members: [RoomMember] = []
        for e in JSONField.array(o, "members") ?? [] {
            guard let m = e as? [String: Any], let id = JSONField.string(m, "id") else { continue }
            members.append(RoomMember(id: id, name: JSONField.string(m, "name") ?? "", host: JSONField.bool(m, "host") == true))
        }
        let queue = (JSONField.array(o, "queue") ?? []).compactMap { roomTrack($0) }
        var pos = 0.0
        if let v = o["pos"] as? Double { pos = v } else if let v = o["pos"] as? Int { pos = Double(v) } else if let v = o["pos"] as? NSNumber { pos = v.doubleValue }
        return RoomState(
            code: code,
            rev: JSONField.int64(o, "rev") ?? 0,
            v: JSONField.int64(o, "v") ?? 0,
            chat: chat,
            track: roomTrack(o["track"] as Any),
            queue: queue,
            index: JSONField.int(o, "index") ?? 0,
            playing: JSONField.bool(o, "playing") == true,
            pos: pos,
            at: JSONField.int64(o, "at") ?? 0,
            by: JSONField.string(o, "by"),
            host: JSONField.string(o, "host"),
            mode: JSONField.string(o, "mode") == "host" ? "host" : "all",
            skips: (JSONField.array(o, "skips") ?? []).compactMap { $0 as? String },
            reactions: reactions,
            members: members,
            now: JSONField.int64(o, "now") ?? 0
        )
    }

    public static func parse(_ text: String) -> RoomState? {
        guard let o = BlinkJSON.object(text) else { return nil }
        return parse(o)
    }

    private static func roomTrack(_ any: Any) -> Track? {
        guard let dict = any as? [String: Any], JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(Track.self, from: data)
    }

    static func trackObject(_ t: Track) -> Any? {
        guard let data = try? JSONEncoder().encode(t) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

/// Ответ комнаты: код HTTP, состояние (если сервер его приложил) и текст ошибки.
public struct RoomReply: Sendable {
    public var status: Int
    public var room: RoomState?
    public var error: String?
    public init(status: Int, room: RoomState? = nil, error: String? = nil) {
        self.status = status
        self.room = room
        self.error = error
    }
    public var ok: Bool { return status >= 200 && status <= 299 }
    /// Комнаты нет или в неё не пускают: ждать дальше бессмысленно.
    public var gone: Bool { return status == 404 || status == 401 || (status == 403 && room == nil) }
}

public enum StreamEnd: Equatable, Sendable {
    /// Соединение оборвалось, можно переподключиться.
    case dropped
    /// Комнаты больше нет или не пускают.
    case gone(String)
    /// Сервер без потока: работаем long poll-ом.
    case unsupported
}

/// Что умеет сервер комнат. Протокол, чтобы логику сессии проверять без сети.
public protocol RoomService: Sendable {
    func create() async -> RoomReply
    func serverTime() async -> Int64?
    func post(code: String, base: Int64, playing: Bool, posSec: Double, track: Track?, queue: [Track]?, index: Int) async -> RoomReply
    func chat(code: String, text: String) async -> RoomReply
    func react(code: String, emoji: String) async -> RoomReply
    func mode(code: String, mode: String) async -> RoomReply
    func enqueue(code: String, track: Track) async -> RoomReply
    func skip(code: String) async -> RoomReply
    func leave(code: String) async
    /// Долгое соединение: зовёт `onRoom` на каждое событие, пока оно живо.
    func stream(code: String, onRoom: @escaping @Sendable (RoomState) -> Void) async -> StreamEnd
    func poll(code: String, rev: Int64) async -> RoomReply
}

/// Потоковое чтение событий (SSE). На iOS его делает `URLSession.bytes`, в тестах двойник. Возвращает код HTTP.
public protocol EventStreamer: Sendable {
    func stream(url: URL, headers: [String: String], onLine: @escaping @Sendable (String) -> Void) async throws -> Int
}

public final class RoomApi: RoomService, @unchecked Sendable {
    private let http: HTTPClient
    private let config: BlinkConfig
    private let tokens: TokenProvider?
    private let streamer: EventStreamer?

    public init(http: HTTPClient, config: BlinkConfig, tokens: TokenProvider?, streamer: EventStreamer? = nil) {
        self.http = http
        self.config = config
        self.tokens = tokens
        self.streamer = streamer
    }

    private func request(_ path: String, body: [String: Any]?, query: [(String, String)] = [], timeout: TimeInterval = 25) async -> RoomReply {
        guard let url = URLBuilder.make(config.base, path: path, query: query) else { return RoomReply(status: 0, error: "Не получилось") }
        var headers = ["Accept": "application/json"]
        if let t = await tokens?.accessToken() { headers["Authorization"] = "Bearer " + t }
        var data: Data?
        if let b = body {
            headers["Content-Type"] = "application/json"
            data = try? JSONSerialization.data(withJSONObject: b)
        }
        do {
            let res = try await http.send(HTTPRequest(url: url, method: body == nil ? "GET" : "POST", headers: headers, body: data, timeout: timeout))
            let o = BlinkJSON.object(res.text)
            return RoomReply(status: res.status, room: o.flatMap { RoomState.parse($0) }, error: o.flatMap { JSONField.string($0, "error") })
        } catch {
            return RoomReply(status: 0, error: "Нет связи с сервером")
        }
    }

    public func create() async -> RoomReply { return await request("api/together", body: [:]) }

    public func serverTime() async -> Int64? {
        guard let url = URLBuilder.make(config.base, path: "api/together/time"),
              let res = try? await http.send(HTTPRequest(url: url, timeout: 10)),
              let o = BlinkJSON.object(res.text) else { return nil }
        return JSONField.int64(o, "now")
    }

    public func post(code: String, base: Int64, playing: Bool, posSec: Double, track: Track?, queue: [Track]?, index: Int) async -> RoomReply {
        var body: [String: Any] = ["base": base, "playing": playing, "pos": posSec]
        if let t = track, let obj = RoomState.trackObject(t) {
            body["track"] = obj
            body["queue"] = (queue ?? [t]).prefix(100).compactMap { RoomState.trackObject($0) }
            body["index"] = index
        }
        return await request("api/together/" + code, body: body)
    }

    public func chat(code: String, text: String) async -> RoomReply { return await request("api/together/" + code + "/chat", body: ["text": text]) }
    public func react(code: String, emoji: String) async -> RoomReply { return await request("api/together/" + code + "/react", body: ["emoji": emoji]) }
    public func mode(code: String, mode: String) async -> RoomReply { return await request("api/together/" + code + "/mode", body: ["mode": mode]) }
    public func skip(code: String) async -> RoomReply { return await request("api/together/" + code + "/skip", body: [:]) }

    public func enqueue(code: String, track: Track) async -> RoomReply {
        guard let obj = RoomState.trackObject(track) else { return RoomReply(status: 400, error: "Нет трека") }
        return await request("api/together/" + code + "/queue", body: ["track": obj])
    }

    public func leave(code: String) async { _ = await request("api/together/" + code + "/leave", body: [:], timeout: 8) }

    public func poll(code: String, rev: Int64) async -> RoomReply {
        return await request("api/together/" + code, body: nil, query: [("r", String(rev))], timeout: 40)
    }

    public func stream(code: String, onRoom: @escaping @Sendable (RoomState) -> Void) async -> StreamEnd {
        guard let streamer = streamer else { return .unsupported }
        guard let url = URLBuilder.make(config.base, path: "api/together/" + code + "/stream") else { return .unsupported }
        var headers = ["Accept": "text/event-stream"]
        if let t = await tokens?.accessToken() { headers["Authorization"] = "Bearer " + t }
        do {
            let status = try await streamer.stream(url: url, headers: headers) { line in
                if line.hasPrefix("data: "), let r = RoomState.parse(String(line.dropFirst(6))) { onRoom(r) }
            }
            if status == 404 || status == 403 || status == 401 { return .gone("Комната закрыта") }
            if status < 200 || status > 299 { return .unsupported }
            return .dropped
        } catch {
            return .dropped
        }
    }
}
