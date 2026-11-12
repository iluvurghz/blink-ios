import XCTest
@testable import BlinkCore

private let roomJSON = """
{"code":"abc123","rev":5,"v":3,"chat":[{"id":"m1","by":"u2","name":"Аня","text":"привет","at":1000}],
 "track":{"id":"111","title":"Alive","artist":"Band","year":2024,"duration":200,"artwork":"https://x/y.jpg"},
 "queue":[{"id":"111","title":"Alive","artist":"Band"},{"id":"222","title":"Next","artist":"Band"}],
 "index":0,"playing":true,"pos":12.5,"at":100000,"by":"u1","host":"u1","mode":"host","skips":["u2"],
 "reactions":[{"id":"r1","by":"u2","name":"Аня","emoji":"🔥","at":99000}],
 "members":[{"id":"u1","name":"Я","host":true},{"id":"u2","name":"Аня","host":false}],"now":100500}
"""

final class RoomModelTests: XCTestCase {
    func testRoomParsesWithNumericYearAndComputesTarget() throws {
        let r = try XCTUnwrap(RoomState.parse(roomJSON))
        XCTAssertEqual(r.code, "abc123")
        XCTAssertEqual(r.rev, 5)
        XCTAssertEqual(r.v, 3)
        XCTAssertEqual(r.track?.year, "2024")
        XCTAssertEqual(r.queue.count, 2)
        XCTAssertEqual(r.mode, "host")
        XCTAssertEqual(r.skips, ["u2"])
        XCTAssertEqual(r.members.count, 2)
        XCTAssertTrue(r.isHost("u1"))
        XCTAssertEqual(r.targetMs(localNowMs: 101_500, offsetMs: 0), 14_000)
        XCTAssertEqual(r.targetMs(localNowMs: 102_500, offsetMs: -1000), 14_000)
        var paused = r
        paused.playing = false
        XCTAssertEqual(paused.targetMs(localNowMs: 101_500, offsetMs: 0), 12_500)
    }

    func testCodesComeFromLinks() {
        XCTAssertEqual(RoomSession.codeFrom("https://blinkmusic.cc/r/abc123"), "abc123")
        XCTAssertEqual(RoomSession.codeFrom("https://blinkmusic.cc/?together=abc123"), "abc123")
        XCTAssertNil(RoomSession.codeFrom("https://example.com/"))
        XCTAssertEqual(RoomSession.link("zz99"), "https://blinkmusic.cc/r/zz99")
        XCTAssertEqual(FriendsApi.link("abc12345"), "https://blinkmusic.cc/?friend=abc12345")
        XCTAssertEqual(FriendsApi.codeFrom("https://blinkmusic.cc/?friend=abc12345"), "abc12345")
        XCTAssertNil(FriendsApi.codeFrom("https://blinkmusic.cc/"))
    }
}

private final class FakePort: RoomPlayerPort, @unchecked Sendable {
    private let lock = NSLock()
    private var _playback = LocalPlayback(track: nil, playing: false, positionMs: 0)
    private var _queue: ([Track], Int) = ([], 0)
    private var _calls: [String] = []

    var playback: LocalPlayback {
        get { lock.lock(); defer { lock.unlock() }; return _playback }
        set { lock.lock(); _playback = newValue; lock.unlock() }
    }
    var queueValue: ([Track], Int) {
        get { lock.lock(); defer { lock.unlock() }; return _queue }
        set { lock.lock(); _queue = newValue; lock.unlock() }
    }
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    func clear() { lock.lock(); _calls = []; lock.unlock() }
    private func note(_ s: String) { lock.lock(); _calls.append(s); lock.unlock() }

    func local() -> LocalPlayback { return playback }
    func playQueue(_ queue: [Track], index: Int, positionMs: Int64, playing: Bool) {
        note("play \(queue.count) \(index) \(positionMs) \(playing)")
        queueValue = (queue, index)
        playback = LocalPlayback(track: queue[index], playing: playing, positionMs: positionMs)
    }
    func setPlaying(_ playing: Bool, positionMs: Int64) {
        note("set \(playing) \(positionMs)")
        var p = playback
        p.playing = playing
        p.positionMs = positionMs
        playback = p
    }
    func seekTo(_ positionMs: Int64) {
        note("seek \(positionMs)")
        var p = playback
        p.positionMs = positionMs
        playback = p
    }
    func appendToQueue(_ tracks: [Track]) {
        note("append \(tracks.count)")
        let q = queueValue
        queueValue = (q.0 + tracks, q.1)
    }
    func queue() -> (tracks: [Track], index: Int) { let q = queueValue; return (q.0, q.1) }
}

private final class FakeRoomService: RoomService, @unchecked Sendable {
    private let lock = NSLock()
    private var _posts: [String] = []
    private var _reply = RoomReply(status: 200)
    var posts: [String] { lock.lock(); defer { lock.unlock() }; return _posts }
    var reply: RoomReply {
        get { lock.lock(); defer { lock.unlock() }; return _reply }
        set { lock.lock(); _reply = newValue; lock.unlock() }
    }
    func create() async -> RoomReply { return reply }
    func serverTime() async -> Int64? { return 100_000 }
    func post(code: String, base: Int64, playing: Bool, posSec: Double, track: Track?, queue: [Track]?, index: Int) async -> RoomReply {
        lock.lock()
        _posts.append("post base=\(base) playing=\(playing) pos=\(posSec) track=\(track?.id ?? "nil")")
        lock.unlock()
        return reply
    }
    func chat(code: String, text: String) async -> RoomReply { return reply }
    func react(code: String, emoji: String) async -> RoomReply { return reply }
    func mode(code: String, mode: String) async -> RoomReply { return reply }
    func enqueue(code: String, track: Track) async -> RoomReply { return reply }
    func skip(code: String) async -> RoomReply { return reply }
    func leave(code: String) async {}
    func stream(code: String, onRoom: @escaping @Sendable (RoomState) -> Void) async -> StreamEnd {
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        return .dropped
    }
    func poll(code: String, rev: Int64) async -> RoomReply { return reply }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Int64 = 101_500
    var now: Int64 { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ ms: Int64) { lock.lock(); t += ms; lock.unlock() }
}

private final class Said: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
}

private final class Chats: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
}

final class RoomSessionTests: XCTestCase {
    private var room: RoomState!

    override func setUp() {
        super.setUp()
        room = RoomState.parse(roomJSON)
    }

    private func make(port: FakePort, service: FakeRoomService, clock: Clock, said: Said, chats: Chats = Chats()) -> RoomSession {
        return RoomSession(
            service: service, port: port, userId: { "u9" }, say: { said.add($0) }, onChat: { chats.add($0.text) },
            nowMs: { clock.now }, nanos: { 0 }
        )
    }

    private func eventually(_ cond: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("условие не выполнилось", file: file, line: line)
    }

    func testJoiningFollowsTheRoomsTrackFromTheRightMoment() {
        let port = FakePort()
        let s = make(port: port, service: FakeRoomService(), clock: Clock(), said: Said())
        s.join("abc123")
        s.update(room)
        XCTAssertEqual(port.calls.count, 1)
        XCTAssertTrue(port.calls[0].hasPrefix("play 2 0 "), port.calls[0])
        XCTAssertTrue(port.calls[0].hasSuffix(" true"))
        XCTAssertEqual(s.room?.code, "abc123")
        s.leave()
    }

    func testAPauseInTheRoomPausesUsAndIsNotSentBack() async {
        let port = FakePort()
        let service = FakeRoomService()
        let clock = Clock()
        let s = make(port: port, service: service, clock: clock, said: Said())
        s.join("abc123")
        s.update(room)
        port.clear()
        var p = port.playback
        p.positionMs = 14_500
        port.playback = p
        clock.advance(3000)
        var paused = room!
        paused.rev = 6
        paused.v = 4
        paused.playing = false
        paused.pos = 20.0
        paused.at = 104_000
        s.update(paused)
        XCTAssertEqual(port.calls, ["set false 20000"])
        s.onLocal(port.local())
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(service.posts.isEmpty, "\(service.posts)")
        s.leave()
    }

    func testAManualPauseIsSentToTheRoomWithItsVersion() async {
        let port = FakePort()
        let service = FakeRoomService()
        let clock = Clock()
        let s = make(port: port, service: service, clock: clock, said: Said())
        s.join("abc123")
        s.update(room)
        clock.advance(3000)
        var p = port.local()
        p.playing = false
        p.positionMs = 30_000
        port.playback = p
        s.onLocal(p)
        await eventually { service.posts.count == 1 }
        XCTAssertEqual(service.posts, ["post base=3 playing=false pos=30.0 track=nil"])
        s.leave()
    }

    func testANewTrackPickedByHandGoesToTheRoomAndChatFromOthersSurfaces() async {
        let port = FakePort()
        let service = FakeRoomService()
        let clock = Clock()
        let chats = Chats()
        let s = make(port: port, service: service, clock: clock, said: Said(), chats: chats)
        s.join("abc123")
        s.update(room)
        clock.advance(3000)
        let mine = Track(id: "333", title: "Mine", artist: "Me")
        port.queueValue = ([mine], 0)
        port.playback = LocalPlayback(track: mine, playing: true, positionMs: 0)
        s.onLocal(port.local())
        await eventually { service.posts.count == 1 }
        XCTAssertEqual(service.posts, ["post base=3 playing=true pos=0.0 track=333"])

        var next = room!
        next.rev = 9
        next.chat.append(RoomChat(id: "m2", by: "u2", name: "Аня", text: "новое", at: 2000))
        s.update(next)
        XCTAssertEqual(chats.all, ["новое"])
        s.leave()
    }

    func testHostOnlyRoomThatRefusesUsSnapsBackAndSaysWhy() async {
        let said = Said()
        let port = FakePort()
        let service = FakeRoomService()
        let clock = Clock()
        let s = make(port: port, service: service, clock: clock, said: said)
        s.join("abc123")
        s.update(room)
        clock.advance(3000)
        var refused = room!
        refused.rev = 7
        service.reply = RoomReply(status: 403, room: refused, error: "Управляет хост комнаты")
        var p = port.local()
        p.playing = false
        port.playback = p
        s.onLocal(p)
        await eventually { said.all.count == 1 }
        XCTAssertEqual(said.all, ["Управляет хост комнаты"])
        s.leave()
    }

    func testQueueGrowthInTheRoomIsAppendedToTheLocalQueue() {
        let port = FakePort()
        let s = make(port: port, service: FakeRoomService(), clock: Clock(), said: Said())
        s.join("abc123")
        s.update(room)
        port.clear()
        var grown = room!
        grown.rev = 8
        grown.queue.append(Track(id: "333", title: "Third", artist: "X"))
        s.update(grown)
        XCTAssertTrue(port.calls.contains("append 1"), "\(port.calls)")
        s.leave()
    }
}

final class FriendsPlusTests: XCTestCase {
    private var http: RouteHTTP!
    private let base = "http://127.0.0.1:9"

    override func setUp() {
        super.setUp()
        http = RouteHTTP()
    }

    private var config: BlinkConfig { return BlinkConfig(baseURL: base, supabaseURL: base, supabaseAnonKey: "anon") }

    private func json(_ body: String, _ code: Int = 200) -> HTTPResponse {
        return HTTPResponse(status: code, headers: ["content-type": "application/json"], data: Data(body.utf8))
    }

    func testFriendsListParsesListeningState() async throws {
        http.route("/api/friends") { _ in
            self.json("""
            {"friends":[{"id":"a","name":"Аня","avatar":"https://x/a.jpg","listening":{"track":{"id":"1","title":"T","artist":"A","artwork":""},"room":"r1"}},
              {"id":"b","name":"Боря","avatar":"","listening":null}],"hidden":true}
            """)
        }
        let api = FriendsApi(http: http, config: config, tokens: FixedToken(value: "tok"))
        let l = try await api.list()
        let list = try XCTUnwrap(l)
        XCTAssertTrue(list.hidden)
        XCTAssertEqual(list.friends[0].room, "r1")
        XCTAssertTrue(list.friends[0].listening)
        XCTAssertFalse(list.friends[1].listening)
        XCTAssertEqual(http.requests("/api/friends").first?.headers["Authorization"], "Bearer tok")
    }

    func testAcceptingAStaleInviteThrowsTheServerText() async {
        http.route("/api/friends/accept") { _ in self.json("{\"error\":\"Ссылка устарела или не работает\"}", 404) }
        let api = FriendsApi(http: http, config: config, tokens: FixedToken(value: "tok"))
        do {
            _ = try await api.accept("zzz")
            XCTFail("должно было бросить")
        } catch let e as FriendsError {
            XCTAssertEqual(e.message, "Ссылка устарела или не работает")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testPlusConfigIsParsedCachedAndFallsBack() async throws {
        let mem = MemoryKeyValue()
        let api = PlusApi(http: http, config: config, tokens: FixedToken(value: "tok"), cache: mem)
        XCTAssertEqual(api.cached(), PlusConfig.fallback)
        http.route("/api/plus/config") { _ in
            self.json("""
            {"title":"Blink+","lead":"L","plans":[{"id":"month","label":"Месяц","price":199,"days":30,"tag":"хит"},{"id":"year","label":"Год","price":1200,"days":365,"old":2388}],
             "perks":[{"icon":"bolt","title":"P","text":"t"}],"compare":[{"label":"X","free":false,"plus":true}],"tiers":[{"name":"Хранитель","from":50},{"name":"II","from":1000}]}
            """)
        }
        let c = try await XCTUnwrapAsync(try await api.config())
        XCTAssertEqual(c.plans[0].price, 199)
        XCTAssertEqual(c.plans[1].monthly, 100)
        XCTAssertEqual(c.tiers.count, 2)
        XCTAssertEqual(c.tierFor(10), 0)
        XCTAssertEqual(c.tierFor(50), 1)
        XCTAssertEqual(c.tierFor(5000), 2)
        XCTAssertEqual(api.cached(), c)
    }

    func testMePromoAndCheckout() async throws {
        let api = PlusApi(http: http, config: config, tokens: FixedToken(value: "tok"))
        http.route("/api/plus/me") { _ in self.json("{\"active\":true,\"plus_until\":\"2027-01-01T00:00:00+00:00\",\"donated\":120,\"keeper_tier\":1}") }
        let me = try await XCTUnwrapAsync(try await api.me())
        XCTAssertTrue(me.active)
        XCTAssertEqual(me.untilMs, 1_798_761_600_000)
        XCTAssertEqual(me.keeperTier, 1)

        http.route("/api/plus/promo") { _ in self.json("{\"kind\":\"discount\",\"code\":\"HI\",\"percent\":20}") }
        let r = try await api.promo("hi")
        XCTAssertEqual(r, .discount(code: "HI", percent: 20))
        http.route("/api/plus/promo") { _ in self.json("{\"error\":\"Такого промокода нет\"}", 400) }
        do {
            _ = try await api.promo("x")
            XCTFail("должно было бросить")
        } catch let e as PlusError {
            XCTAssertEqual(e.message, "Такого промокода нет")
        }

        http.route("/api/plus/checkout") { _ in self.json("{\"pay_url\":\"https://pay.example/1\",\"amount\":149}") }
        let url = try await api.checkout(plan: "month", promo: nil)
        XCTAssertEqual(url, "https://pay.example/1")
    }
}

private func XCTUnwrapAsync<T>(_ expr: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let v = try await expr()
    return try XCTUnwrap(v, file: file, line: line)
}
