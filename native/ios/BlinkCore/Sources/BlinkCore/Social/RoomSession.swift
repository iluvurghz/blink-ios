import Foundation

/// Что сейчас играет у нас.
public struct LocalPlayback: Equatable, Sendable {
    public var track: Track?
    public var playing: Bool
    public var positionMs: Int64
    public var loading: Bool

    public init(track: Track?, playing: Bool, positionMs: Int64, loading: Bool = false) {
        self.track = track
        self.playing = playing
        self.positionMs = positionMs
        self.loading = loading
    }

    public var trackId: String? { return track?.id }
}

/// Рука сессии на плеере устройства. На iOS это `PlayerController`, в тестах двойник.
public protocol RoomPlayerPort: AnyObject, Sendable {
    func local() -> LocalPlayback
    /// Очередь целиком и что в ней играть (`index`), с места `positionMs`.
    func playQueue(_ queue: [Track], index: Int, positionMs: Int64, playing: Bool)
    /// Тот же трек: встать на `positionMs` и играть или встать на паузу.
    func setPlaying(_ playing: Bool, positionMs: Int64)
    func seekTo(_ positionMs: Int64)
    func appendToQueue(_ tracks: [Track])
    func queue() -> (tracks: [Track], index: Int)
}

/// Логика комнаты «Слушать вместе»: слушаем сервер (поток или long poll), подгоняем плеер под комнату и
/// отправляем в комнату то, что человек сделал руками. Порт `RoomSession.kt` с Android; числа те же.
public final class RoomSession: @unchecked Sendable {
    public static let emoji = ["🔥", "❤️", "😂", "🥹", "🤯", "👏", "💃", "🎧"]
    public static let maxMembers = 8

    private let service: RoomService
    private let port: RoomPlayerPort
    private let userId: @Sendable () -> String?
    private let say: @Sendable (String) -> Void
    private let nowMs: @Sendable () -> Int64
    private let nanos: @Sendable () -> UInt64
    private let onChat: @Sendable (RoomChat) -> Void

    private let lock = NSLock()
    private let state = Observable<RoomState?>(nil)
    private var current: RoomState?
    private var task: Task<Void, Never>?
    private var chain: Task<Void, Never>?
    private var offset: Int64 = 0
    private var clockOffset: Int64?
    private var applyingUntil: Int64 = 0
    private var lastTrackId: String?
    private var seenChat = Set<String>()

    public init(
        service: RoomService,
        port: RoomPlayerPort,
        userId: @escaping @Sendable () -> String?,
        say: @escaping @Sendable (String) -> Void,
        onChat: @escaping @Sendable (RoomChat) -> Void = { _ in },
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        nanos: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.service = service
        self.port = port
        self.userId = userId
        self.say = say
        self.onChat = onChat
        self.nowMs = nowMs
        self.nanos = nanos
    }

    public var room: RoomState? { return state.current }

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (RoomState?) -> Void) -> NetworkObservation {
        return state.observe(handler)
    }

    public var inRoom: Bool {
        lock.lock()
        defer { lock.unlock() }
        return current != nil
    }

    public func isHost() -> Bool { return state.current?.isHost(userId()) == true }

    // ---------- вход и выход ----------

    /// Создать комнату; то, что играет сейчас, становится треком комнаты. Возвращает код или nil.
    @discardableResult
    public func create() async -> String? {
        if inRoom { leave() }
        let reply = await service.create()
        guard reply.ok, let r = reply.room else {
            say(reply.error ?? "Не получилось создать комнату")
            return nil
        }
        lock.lock()
        current = r
        seenChat = Set(r.chat.map { $0.id })
        lock.unlock()
        state.update { $0 = r }
        let local = port.local()
        lock.lock()
        lastTrackId = local.trackId
        lock.unlock()
        start(r.code)
        if let t = local.track {
            let q = port.queue()
            await post(playing: local.playing, posSec: Double(local.positionMs) / 1000.0, track: t, queue: q.tracks.isEmpty ? [t] : q.tracks, index: q.index)
        }
        return r.code
    }

    public func join(_ code: String) {
        let c = code.trimmingCharacters(in: .whitespaces)
        if c.isEmpty { return }
        lock.lock()
        let same = current?.code == c
        lock.unlock()
        if same { return }
        if inRoom { leave() }
        let placeholder = RoomState(code: c)
        let local = port.local()
        lock.lock()
        current = placeholder
        seenChat = []
        lastTrackId = local.trackId
        lock.unlock()
        state.update { $0 = placeholder }
        start(c)
    }

    public func leave() {
        lock.lock()
        let code = current?.code
        lock.unlock()
        guard let c = code else { return }
        let service = self.service
        Task { await service.leave(code: c) }
        end(nil)
    }

    private func end(_ message: String?) {
        lock.lock()
        task?.cancel()
        task = nil
        current = nil
        lock.unlock()
        state.update { $0 = nil }
        if let m = message { say(m) }
    }

    // ---------- слушаем комнату ----------

    private func start(_ code: String) {
        lock.lock()
        task?.cancel()
        let t = Task { [weak self] in
            guard let self = self else { return }
            async let clock: Void = self.syncClock()
            async let drift: Void = self.catchUpLoop(code)
            await self.listen(code)
            await clock
            await drift
        }
        task = t
        lock.unlock()
    }

    private func stillIn(_ code: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return current?.code == code && !Task.isCancelled
    }

    private func listen(_ code: String) async {
        var fails = 0
        while stillIn(code) && fails < 3 {
            let counter = Counter()
            let end = await service.stream(code: code) { [weak self] r in
                counter.bump()
                self?.update(r)
            }
            switch end {
            case .gone(let message):
                self.end(message)
                return
            case .unsupported:
                await poll(code)
                return
            case .dropped:
                let got = counter.value
                fails = got > 0 ? 0 : fails + 1
                try? await Task.sleep(nanoseconds: got > 0 ? 500_000_000 : 1_500_000_000)
            }
        }
        await poll(code)
    }

    /// Запасной путь: сервер без потока или поток заблокирован.
    private func poll(_ code: String) async {
        while stillIn(code) {
            lock.lock()
            let rev = current?.rev ?? 0
            lock.unlock()
            let reply = await service.poll(code: code, rev: rev)
            if reply.ok, let r = reply.room {
                update(r)
            } else if reply.gone {
                end(reply.error ?? "Комната закрыта")
                return
            } else {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// Серверные часы минус наши по самому быстрому из нескольких обращений: задержка сети сокращается.
    private func syncClock() async {
        var bestRtt = UInt64.max
        var best: Int64?
        for _ in 0..<4 {
            let a = nanos()
            let server = await service.serverTime()
            let rtt = (nanos() &- a) / 1_000_000
            if let s = server, rtt < bestRtt {
                bestRtt = rtt
                best = s + Int64(rtt / 2) - nowMs()
            }
        }
        if let b = best {
            lock.lock()
            clockOffset = b
            offset = b
            lock.unlock()
        }
    }

    private func catchUpLoop(_ code: String) async {
        while stillIn(code) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            lock.lock()
            let r = current
            let off = offset
            lock.unlock()
            guard let room = r, let t = room.track else { continue }
            let local = port.local()
            if local.trackId == t.id && local.playing && room.playing {
                let target = room.targetMs(localNowMs: nowMs(), offsetMs: off)
                if abs(local.positionMs - target) > 3000 {
                    quiet()
                    port.seekTo(target)
                }
            }
        }
    }

    // ---------- комната пришла ----------

    public func update(_ r: RoomState) {
        let mine = userId()
        var fresh: [RoomChat] = []
        lock.lock()
        guard let cur = current, r.code == cur.code, r.rev >= cur.rev else {
            lock.unlock()
            return
        }
        let first = cur.rev == 0
        for c in r.chat where seenChat.insert(c.id).inserted {
            if !first && c.by != mine { fresh.append(c) }
        }
        current = r
        offset = clockOffset ?? (r.now - nowMs())
        lock.unlock()
        state.update { $0 = r }
        for c in fresh { onChat(c) }
        follow(r)
    }

    private func follow(_ r: RoomState) {
        guard let t = r.track else { return }
        let local = port.local()
        lock.lock()
        let off = offset
        lock.unlock()
        let target = r.targetMs(localNowMs: nowMs(), offsetMs: off)
        if local.trackId != t.id {
            quiet()
            lock.lock()
            lastTrackId = t.id
            lock.unlock()
            port.playQueue(r.queue.isEmpty ? [t] : r.queue, index: r.index, positionMs: target, playing: r.playing)
            return
        }
        // Другие добавили треки в очередь комнаты: у нас они появляются в очереди плеера.
        let have = port.queue().tracks
        if r.queue.count > have.count && r.queue.prefix(have.count).map({ $0.id }) == have.map({ $0.id }) {
            port.appendToQueue(Array(r.queue.dropFirst(have.count)))
        }
        if local.loading { return }
        if r.playing != local.playing {
            quiet()
            port.setPlaying(r.playing, positionMs: target)
            return
        }
        if abs(local.positionMs - target) > 2500 {
            quiet()
            port.seekTo(target)
        }
    }

    /// Следующие полторы секунды всё, что делает плеер, считаем своим, а не действием человека.
    private func quiet() {
        lock.lock()
        applyingUntil = nowMs() + 1500
        lock.unlock()
    }

    // ---------- человек сделал руками ----------

    /// Плеер сменил трек или состояние: если это не мы его подогнали, сообщаем комнате.
    public func onLocal(_ snap: LocalPlayback) {
        lock.lock()
        let r = current
        let blocked = nowMs() < applyingUntil
        let last = lastTrackId
        lock.unlock()
        guard let room = r, room.rev != 0, !blocked else { return }
        if let id = snap.trackId, id != room.track?.id {
            if id == last { return }
            lock.lock()
            lastTrackId = id
            lock.unlock()
            let q = port.queue()
            let tracks = q.tracks.isEmpty ? (snap.track.map { [$0] } ?? []) : q.tracks
            enqueuePost { [weak self] in
                await self?.post(playing: true, posSec: 0, track: snap.track, queue: tracks, index: q.index)
            }
            return
        }
        if let id = snap.trackId, id == room.track?.id, !snap.loading, snap.playing != room.playing {
            enqueuePost { [weak self] in
                await self?.post(playing: snap.playing, posSec: Double(snap.positionMs) / 1000.0, track: nil, queue: nil, index: 0)
            }
        }
    }

    /// Человек перемотал.
    public func onUserSeek(_ positionMs: Int64) {
        if !inRoom { return }
        let playing = port.local().playing
        enqueuePost { [weak self] in
            await self?.post(playing: playing, posSec: Double(positionMs) / 1000.0, track: nil, queue: nil, index: 0)
        }
    }

    /// Отправки идут по одной, в порядке нажатий.
    private func enqueuePost(_ work: @escaping @Sendable () async -> Void) {
        lock.lock()
        let prev = chain
        chain = Task {
            await prev?.value
            await work()
        }
        lock.unlock()
    }

    private func post(playing: Bool, posSec: Double, track: Track?, queue: [Track]?, index: Int) async {
        lock.lock()
        let r = current
        lock.unlock()
        guard let room = r else { return }
        let reply = await service.post(code: room.code, base: room.v, playing: playing, posSec: posSec, track: track, queue: queue, index: index)
        handle(reply)
    }

    private func handle(_ reply: RoomReply) {
        if reply.ok || reply.status == 409 {
            if let r = reply.room { update(r) }
            if reply.status == 409, let e = reply.error { say(e) }
        } else if reply.status == 403, let r = reply.room {
            update(r) // комната под управлением хоста: возвращаем то, что играет в ней
            say(reply.error ?? "Управляет хост комнаты")
        } else if reply.gone {
            end(reply.error ?? "Комната закрыта")
        } else if let e = reply.error {
            say(e)
        }
    }

    // ---------- команды ----------

    private func code() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return current?.code
    }

    @discardableResult
    public func sendChat(_ text: String) async -> Bool {
        guard let c = code() else { return false }
        let reply = await service.chat(code: c, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        if reply.ok {
            if let r = reply.room { update(r) }
            return true
        }
        say(reply.error ?? "Сообщение не отправилось")
        return false
    }

    public func react(_ emoji: String) async {
        guard let c = code() else { return }
        let reply = await service.react(code: c, emoji: emoji)
        if reply.ok, let r = reply.room { update(r) }
    }

    public func setMode(_ mode: String) async {
        guard let c = code() else { return }
        let reply = await service.mode(code: c, mode: mode)
        if reply.ok, let r = reply.room { update(r) } else if !reply.ok { say(reply.error ?? "Не получилось") }
    }

    @discardableResult
    public func addToQueue(_ track: Track) async -> Bool {
        guard let c = code() else { return false }
        let reply = await service.enqueue(code: c, track: track)
        if reply.ok {
            if let r = reply.room { update(r) }
            say("Добавлено в очередь комнаты")
            return true
        }
        say(reply.error ?? "Не получилось добавить")
        return false
    }

    public func voteSkip() async {
        guard let c = code() else { return }
        let reply = await service.skip(code: c)
        if let r = reply.room, reply.ok || reply.status == 409 { update(r) }
        if !reply.ok { say(reply.error ?? "Не получилось") }
    }

    // ---------- ссылки ----------

    /// Ссылка-приглашение, как на сайте.
    public static func link(_ code: String) -> String { return "https://blinkmusic.cc/r/" + code }

    /// Код комнаты из ссылки (`/r/<код>` или `?together=<код>`) или nil.
    public static func codeFrom(_ url: String?) -> String? {
        guard let url = url, !url.isEmpty else { return nil }
        for pattern in ["blinkmusic\\.cc/r/([A-Za-z0-9_-]{4,40})", "[?&]together=([A-Za-z0-9_-]{4,40})"] {
            if let re = try? NSRegularExpression(pattern: pattern) {
                let ns = url as NSString
                if let m = re.firstMatch(in: url, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 {
                    return ns.substring(with: m.range(at: 1))
                }
            }
        }
        return nil
    }
}

/// Счётчик событий потока, доступный из замыкания.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() {
        lock.lock()
        n += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return n
    }
}
