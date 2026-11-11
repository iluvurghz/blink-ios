import XCTest
@testable import BlinkCore

// Настоящий сетевой слой (URLSession) против сервера на 127.0.0.1.
// Тесты с двойником в памяти этого не покажут: куски тела, обрыв посреди файла, молчание, отмену и закрытие соединения.

/// Сервер-двойник FakeBackend (Range, If-Range, потолок 2 МиБ на открытый Range, 416) по настоящему сокету.
enum Loop {
    static func response(
        _ backend: FakeBackend,
        _ request: LoopbackServer.Request,
        cutFirst: Int? = nil,
        slowFirst: Bool = false
    ) -> LoopbackServer.Response {
        let prefix = "/media/"
        guard request.path.hasPrefix(prefix), let f = backend.fixture(String(request.path.dropFirst(prefix.count))) else {
            return LoopbackServer.Response(status: 404, body: Array("not found".utf8))
        }
        let hit = f.nextHit()
        let recorded = Recorded(url: URL(string: "http://loopback.test" + request.path)!, headers: request.headers)
        let reply = backend.serve(f, recorded)
        var out = LoopbackServer.Response(status: reply.status, headers: reply.headers, body: reply.body)
        // Обрыв: заголовок обещает весь файл, а соединение закрывается после `cutFirst` байт.
        if hit == 1, let cut = cutFirst { out.cutAfter = cut }
        if hit == 1 && slowFirst {
            out.chunk = 16 * 1024
            out.delayMs = 5
        }
        return out
    }
}

struct Drained: Sendable {
    var pieces = 0
    var data = Data()
    var error: Error?
}

/// Основа тестов на сокете: поднятые серверы и транспорты закрываются в конце теста.
class LoopbackTestCase: XCTestCase {
    private var servers: [LoopbackServer] = []
    private var transports: [URLSessionTransport] = []

    override func tearDown() {
        for t in transports { t.invalidate() }
        transports = []
        for s in servers { s.stop() }
        servers = []
        super.tearDown()
    }

    func serve(_ handler: @escaping @Sendable (LoopbackServer.Request) -> LoopbackServer.Response) throws -> LoopbackServer {
        let s = try LoopbackServer(handler: handler)
        servers.append(s)
        return s
    }

    func transport(idle: TimeInterval = 20, userAgent: String? = nil) -> URLSessionTransport {
        let t = URLSessionTransport(idleTimeout: idle, userAgent: userAgent)
        transports.append(t)
        return t
    }

    func url(_ s: LoopbackServer, _ path: String) -> URL {
        return URL(string: s.base + path)!
    }

    /// GET со страховкой от зависания теста.
    func fetch(_ t: URLSessionTransport, _ u: URL, _ headers: [String: String] = [:], seconds: Double = 30) async throws -> TransportResponse {
        return try await withDeadline(seconds) { try await t.get(u, headers: headers) }
    }

    /// Читает тело до конца: сколько пришло кусков, что в них и чем закончился поток.
    func drain(_ response: TransportResponse, seconds: Double = 30) async -> Drained {
        let body = response.body
        do {
            return try await withDeadline(seconds) { () async throws -> Drained in
                var out = Drained()
                do {
                    for try await piece in body {
                        out.pieces += 1
                        out.data.append(piece)
                    }
                } catch {
                    out.error = error
                }
                return out
            }
        } catch {
            XCTFail("тело не закончилось за \(seconds) с")
            return Drained(error: error)
        }
    }
}

// ---------- URLSessionTransport: потоковый GET для скачивания ----------

final class TransportTests: LoopbackTestCase {
    func testStreamsTheBodyInPiecesWithLowercaseHeaders() async throws {
        let body = Audio.bytes(300_000)
        let s = try serve { _ in
            LoopbackServer.Response(status: 200, headers: ["Content-Type": "audio/mpeg", "X-Blink-Test": "Yes"], body: body)
        }
        let r = try await fetch(transport(), url(s, "/media/a"))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.header("Content-Type"), "audio/mpeg")
        XCTAssertEqual(r.header("x-blink-test"), "Yes")
        XCTAssertTrue(r.headers.keys.allSatisfy { $0 == $0.lowercased() }, "ключи заголовков в нижнем регистре")
        let got = await drain(r)
        XCTAssertNil(got.error)
        XCTAssertEqual([UInt8](got.data), body)
        XCTAssertGreaterThan(got.pieces, 1, "тело приходит кусками, а не одним буфером")
    }

    func testSendsTheRequestHeadersAsGiven() async throws {
        let s = try serve { _ in LoopbackServer.Response(status: 200, body: Audio.bytes(2000)) }
        let t = transport(userAgent: "BlinkTest/1.0")
        let r = try await fetch(t, url(s, "/media/x?sig=abc"), [
            "Range": "bytes=100-",
            "If-Range": "W/\"e1\"",
            "Accept-Encoding": "identity",
        ])
        _ = await drain(r)
        let seen = s.received
        XCTAssertEqual(seen.count, 1)
        guard let req = seen.first else { return }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/media/x")
        XCTAssertEqual(req.headers["range"], "bytes=100-")
        XCTAssertEqual(req.headers["if-range"], "W/\"e1\"", "etag дословно, вместе с W/ и кавычками")
        XCTAssertEqual(req.headers["accept-encoding"], "identity")
        XCTAssertEqual(req.headers["user-agent"], "BlinkTest/1.0")
        XCTAssertNil(req.headers["authorization"], "к ссылке на файл Bearer не добавляем")
    }

    func testRangeAnswersComeBackAs206WithContentRange() async throws {
        let backend = FakeBackend()
        let f = backend.add("a", 1_000_000)
        let s = try serve { Loop.response(backend, $0) }
        let t = transport()

        let tail = try await fetch(t, url(s, "/media/a"), ["Range": "bytes=900000-"])
        XCTAssertEqual(tail.status, 206)
        XCTAssertEqual(tail.header("content-range"), "bytes 900000-999999/1000000")
        let got = await drain(tail)
        XCTAssertNil(got.error)
        XCTAssertEqual([UInt8](got.data), Array(f.bytes[900_000...]))

        // Другой etag в If-Range: сервер обязан отдать файл целиком, 200.
        let whole = try await fetch(t, url(s, "/media/a"), ["Range": "bytes=10-", "If-Range": "W/\"other\""])
        XCTAssertEqual(whole.status, 200)
        let all = await drain(whole)
        XCTAssertEqual(all.data.count, 1_000_000)

        // Смещение за концом файла: 416 с размером в Content-Range и пустым телом.
        let gone = try await fetch(t, url(s, "/media/a"), ["Range": "bytes=2000000-"])
        XCTAssertEqual(gone.status, 416)
        XCTAssertEqual(gone.header("content-range"), "bytes */1000000")
        let empty = await drain(gone)
        XCTAssertNil(empty.error)
        XCTAssertEqual(empty.data.count, 0)
    }

    func testErrorStatusesAreReturnedNotThrown() async throws {
        let s = try serve { req in
            if req.path == "/busy" {
                return LoopbackServer.Response(status: 503, headers: ["Retry-After": "7"], body: Array("later".utf8))
            }
            return LoopbackServer.Response(status: 404, body: Array("not found".utf8))
        }
        let t = transport()
        let missing = try await fetch(t, url(s, "/media/none"))
        XCTAssertEqual(missing.status, 404)
        let text = await drain(missing)
        XCTAssertEqual(String(decoding: text.data, as: UTF8.self), "not found")

        let busy = try await fetch(t, url(s, "/busy"))
        XCTAssertEqual(busy.status, 503)
        XCTAssertEqual(busy.header("retry-after"), "7")
    }

    func testALongErrorBodyIsNotReadToTheEnd() async throws {
        let big = Audio.bytes(1024 * 1024)
        let s = try serve { _ in LoopbackServer.Response(status: 500, body: big, chunk: 16 * 1024, delayMs: 2) }
        let r = try await fetch(transport(), url(s, "/media/a"))
        XCTAssertEqual(r.status, 500)
        let got = await drain(r)
        XCTAssertNil(got.error)
        XCTAssertLessThan(got.data.count, 200_000, "тело ошибки режется на 64 КиБ")
        await waitUntil(10, "сервер заметил, что клиент ушёл") { s.brokenWrites >= 1 }
    }

    func testRefusedConnectionIsATransportFailure() async throws {
        let s = try serve { _ in LoopbackServer.Response() }
        let dead = url(s, "/media/a")
        s.stop()
        do {
            _ = try await fetch(transport(), dead, seconds: 20)
            XCTFail("ожидали ошибку")
        } catch let e as TransportError {
            if case .failed = e { return }
            XCTFail("ожидали .failed, пришло \(e)")
        }
    }

    func testSilenceBeforeTheAnswerIsATimeout() async throws {
        let s = try serve { _ in LoopbackServer.Response(stall: true) }
        let started = Date()
        do {
            _ = try await fetch(transport(idle: 1), url(s, "/media/a"), seconds: 20)
            XCTFail("ожидали таймаут")
        } catch let e as TransportError {
            XCTAssertEqual(e, TransportError.timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testSilenceMidBodyEndsTheStreamWithATimeout() async throws {
        let body = Audio.bytes(500_000)
        let s = try serve { _ in LoopbackServer.Response(status: 200, body: body, hangAfter: 100_000) }
        let r = try await fetch(transport(idle: 1), url(s, "/media/a"))
        XCTAssertEqual(r.status, 200)
        let got = await drain(r)
        XCTAssertEqual(got.data.count, 100_000, "всё, что успело прийти до молчания, получено")
        XCTAssertEqual(got.error as? TransportError, TransportError.timedOut)
    }

    func testCancellingWhileWaitingForTheAnswer() async throws {
        let s = try serve { _ in LoopbackServer.Response(stall: true) }
        let t = transport()
        let u = url(s, "/media/a")
        let task = Task { try await t.get(u, headers: [:]) }
        await waitUntil(10, "запрос дошёл до сервера") { s.received.count == 1 }
        task.cancel()
        switch await task.result {
        case .success:
            XCTFail("ожидали отмену")
        case .failure(let e):
            XCTAssertTrue(e is CancellationError, "пришло: \(e)")
        }
    }

    func testCancellingTheReaderClosesTheConnection() async throws {
        let big = Audio.bytes(2 * 1024 * 1024)
        let s = try serve { _ in LoopbackServer.Response(status: 200, body: big, chunk: 16 * 1024, delayMs: 5) }
        let t = transport()
        let u = url(s, "/media/a")
        let seen = Log<Int>()
        let task = Task {
            let r = try await t.get(u, headers: [:])
            for try await piece in r.body { seen.add(piece.count) }
        }
        await waitUntil(10, "пошли байты") { seen.items.reduce(0, +) >= 64 * 1024 }
        task.cancel()
        _ = await task.result
        await waitUntil(10, "сервер заметил обрыв") { s.brokenWrites >= 1 }
        XCTAssertLessThan(seen.items.reduce(0, +), big.count, "после отмены байты больше не качаются")
    }

    func testConnectionCutMidBodyEndsTheStreamWithAnError() async throws {
        let body = Audio.bytes(500_000)
        let s = try serve { _ in LoopbackServer.Response(status: 200, body: body, cutAfter: 100_000) }
        let r = try await fetch(transport(), url(s, "/media/a"))
        let got = await drain(r)
        XCTAssertNotNil(got.error, "обрыв не должен сойти за конец файла")
        if let e = got.error { XCTAssertTrue(e is TransportError, "пришло: \(e)") }
        XCTAssertEqual(got.data.count, 100_000, "до обрыва всё получено")
    }
}

// ---------- URLSessionHTTP: короткие запросы (JSON) ----------

final class URLSessionHTTPTests: LoopbackTestCase {
    func testGetReturnsStatusHeadersAndBody() async throws {
        let s = try serve { _ in
            LoopbackServer.Response(status: 200, headers: ["Content-Type": "application/json"], body: Array(#"{"ok":true}"#.utf8))
        }
        let http = URLSessionHTTP(userAgent: "BlinkTest/1.0")
        let res = try await http.send(HTTPRequest(url: url(s, "/api/plus/me?x=1"), headers: ["Authorization": "Bearer t0k"], timeout: 10))
        XCTAssertEqual(res.status, 200)
        XCTAssertTrue(res.ok)
        XCTAssertEqual(res.headers["content-type"], "application/json")
        XCTAssertEqual(res.text, #"{"ok":true}"#)
        guard let req = s.received.first else { return XCTFail("запрос не дошёл") }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/api/plus/me")
        XCTAssertEqual(req.headers["authorization"], "Bearer t0k")
        XCTAssertEqual(req.headers["user-agent"], "BlinkTest/1.0")
    }

    func testPostSendsTheMethodBodyAndHeaders() async throws {
        let s = try serve { req in LoopbackServer.Response(status: 200, body: req.body) }
        let payload = Data(#"{"email":"a@b.c","password":"p"}"#.utf8)
        let res = try await URLSessionHTTP().send(HTTPRequest(
            url: url(s, "/auth/v1/token?grant_type=password"),
            method: "POST",
            headers: ["Content-Type": "application/json", "apikey": "k"],
            body: payload,
            timeout: 10
        ))
        XCTAssertEqual(res.status, 200)
        XCTAssertEqual(res.data, payload, "сервер получил тело целиком")
        guard let req = s.received.first else { return XCTFail("запрос не дошёл") }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.headers["content-type"], "application/json")
        XCTAssertEqual(req.headers["apikey"], "k")
        XCTAssertEqual(req.body, [UInt8](payload))
    }

    func testErrorStatusIsAnAnswerNotAnError() async throws {
        let s = try serve { _ in
            LoopbackServer.Response(status: 401, headers: ["Content-Type": "application/json"], body: Array(#"{"error":"auth"}"#.utf8))
        }
        let res = try await URLSessionHTTP().send(HTTPRequest(url: url(s, "/api/offline/resolve"), timeout: 10))
        XCTAssertEqual(res.status, 401)
        XCTAssertFalse(res.ok)
        XCTAssertEqual(res.text, #"{"error":"auth"}"#)
    }

    func testRefusedConnectionIsATransportFailure() async throws {
        let s = try serve { _ in LoopbackServer.Response() }
        let dead = url(s, "/api/x")
        s.stop()
        do {
            _ = try await URLSessionHTTP().send(HTTPRequest(url: dead, timeout: 10))
            XCTFail("ожидали ошибку")
        } catch let e as TransportError {
            if case .failed = e { return }
            XCTFail("ожидали .failed, пришло \(e)")
        }
    }

    func testSilenceLongerThanTheTimeoutIsATimeout() async throws {
        let s = try serve { _ in LoopbackServer.Response(stall: true) }
        let http = URLSessionHTTP()
        let u = url(s, "/api/x")
        let started = Date()
        do {
            _ = try await withDeadline(20) { try await http.send(HTTPRequest(url: u, timeout: 1)) }
            XCTFail("ожидали таймаут")
        } catch let e as TransportError {
            XCTAssertEqual(e, TransportError.timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testCancellingTheTaskEndsTheRequest() async throws {
        let s = try serve { _ in LoopbackServer.Response(stall: true) }
        let http = URLSessionHTTP()
        let u = url(s, "/api/x")
        let task = Task { try await http.send(HTTPRequest(url: u, timeout: 30)) }
        await waitUntil(10, "запрос дошёл до сервера") { s.received.count == 1 }
        task.cancel()
        switch await task.result {
        case .success:
            XCTFail("ожидали отмену")
        case .failure(let e):
            XCTAssertTrue(e is CancellationError, "пришло: \(e)")
        }
    }
}

// ---------- загрузчик и очередь сохранений поверх настоящей сети ----------

final class OverTheWireTests: LoopbackTestCase {
    private var backend: FakeBackend!
    private var dir: URL!
    private var storage: FileStorage!
    private var network: StaticNetwork!
    private var made: [OfflineManager] = []

    override func setUp() {
        super.setUp()
        backend = FakeBackend()
        dir = tempDir()
        storage = FileStorage(root: dir)
        try? storage.open()
        network = StaticNetwork(true)
        made = []
    }

    override func tearDown() {
        for m in made { m.pause() }
        made = []
        super.tearDown()
        try? FileManager.default.removeItem(at: dir)
    }

    /// Загрузчик с настоящим URLSession; резолвер отдаёт ссылки на тот же локальный сервер.
    private func downloader(_ s: LoopbackServer, idle: TimeInterval = 20) -> Downloader {
        let b = backend!
        let base = s.base
        let resolver = ClosureResolver { _, id in
            guard let f = b.fixture(id) else { throw OfflineError(.notDownloadable, "missing") }
            return Resolved(
                url: "\(base)/media/\(id)?sig=1",
                mime: f.contentType,
                bytes: f.resolveBytes,
                etag: f.etag,
                expiresAt: Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000,
                duration: f.duration
            )
        }
        return Downloader(storage: storage, resolver: resolver, transport: transport(idle: idle), network: network)
    }

    private func audio(_ id: String) -> [UInt8] {
        guard let path = storage.audioPath(Key.of("blink", id)), let data = FileManager.default.contents(atPath: path) else {
            XCTFail("нет готового файла \(id)")
            return []
        }
        return [UInt8](data)
    }

    func testContractVectorOverRealHTTP() async throws {
        let f = backend.add("big", 5_000_000, duration: 213)
        let b = backend!
        let s = try serve { Loop.response(b, $0, cutFirst: 1_000_000) }
        let d = downloader(s)

        let first = await offlineError { _ = try await d.download(job("big", duration: 213)) }
        XCTAssertEqual(first?.code, .sourceError, "обрыв при живой сети это SOURCE_ERROR, не NO_NETWORK")
        XCTAssertEqual(storage.partSize(Key.of("blink", "big")), 1_000_000, "накопленное сохранено, это и есть смещение Range")

        let entry = try await withDeadline(60) { try await d.download(job("big", duration: 213)) }
        XCTAssertEqual(entry.bytes, 5_000_000)
        XCTAssertEqual(audio("big"), f.bytes)
        XCTAssertEqual(s.received.map { $0.headers["range"] }, [nil, "bytes=1000000-", "bytes=3097152-"])
        XCTAssertEqual(s.received.map { $0.headers["if-range"] }, [nil, "W/\"e1\"", "W/\"e1\""])
    }

    func testPausingMidDownloadKeepsThePartAndResumesWithRange() async throws {
        let f = backend.add("a", 3_000_000)
        let b = backend!
        let s = try serve { Loop.response(b, $0, slowFirst: true) }
        let d = downloader(s)
        let key = Key.of("blink", "a")

        let task = Task { try await d.download(job("a", duration: 100)) }
        await waitUntil(15, "в .part легло больше батча") { self.storage.partSize(key) > 0 }
        task.cancel()
        switch await task.result {
        case .success:
            XCTFail("ожидали отмену")
        case .failure(let e):
            XCTAssertTrue(e is CancellationError, "пришло: \(e)")
        }
        let kept = storage.partSize(key)
        XCTAssertGreaterThan(kept, 0, "накопленное при паузе не теряется")
        XCTAssertLessThan(kept, 3_000_000)
        await waitUntil(10, "сервер заметил, что клиент закрыл соединение") { s.brokenWrites >= 1 }

        let entry = try await withDeadline(60) { try await d.download(job("a", duration: 100)) }
        XCTAssertEqual(entry.bytes, 3_000_000)
        XCTAssertEqual(audio("a"), f.bytes)
        let requests = s.received
        XCTAssertGreaterThanOrEqual(requests.count, 2)
        if requests.count >= 2 {
            XCTAssertEqual(requests[1].headers["range"], "bytes=\(kept)-")
            XCTAssertEqual(requests[1].headers["if-range"], "W/\"e1\"")
        }
    }

    func testSilenceMidBodyIsATimeoutAndTheBytesAreKept() async throws {
        let f = backend.add("a", 600_000)
        let b = backend!
        // Первый ответ замолкает после 300 000 байт; докачка по Range отвечает как обычно.
        let s = try serve { req in
            var r = Loop.response(b, req)
            if req.headers["range"] == nil { r.hangAfter = 300_000 }
            return r
        }
        let d = downloader(s, idle: 1)

        let e = await offlineError { _ = try await d.download(job("a", duration: 30)) }
        XCTAssertEqual(e?.code, .timeout)
        XCTAssertEqual(storage.partSize(Key.of("blink", "a")), 300_000)

        let entry = try await withDeadline(60) { try await d.download(job("a", duration: 30)) }
        XCTAssertEqual(entry.bytes, 600_000)
        XCTAssertEqual(audio("a"), f.bytes)
    }

    func testRefusedConnectionIsSourceErrorWhileOnlineAndNoNetworkWhileOffline() async throws {
        backend.add("a", 100_000)
        let b = backend!
        let s = try serve { Loop.response(b, $0) }
        let d = downloader(s)
        s.stop()

        let online = await offlineError { _ = try await d.download(job("a", duration: 10)) }
        XCTAssertEqual(online?.code, .sourceError)

        network.set(false)
        let offline = await offlineError { _ = try await d.download(job("a", duration: 10)) }
        XCTAssertEqual(offline?.code, .noNetwork, "без сети попытка не тратится")
        XCTAssertEqual(storage.partSize(Key.of("blink", "a")), 0)
    }

    func testManagerSavesTracksOverRealHTTPAndPlaysFromDisk() async throws {
        let a = backend.add("a", 400_000, seed: 1)
        let c = backend.add("c", 500_000, seed: 2)
        let b = backend!
        let s = try serve { Loop.response(b, $0) }
        let m = OfflineManager(
            storage: storage,
            downloader: downloader(s),
            network: network,
            config: OfflineManager.Config(retryDelaysMs: [20, 20, 20, 20], jitter: 0)
        )
        made.append(m)
        await m.start()

        _ = m.enqueue([candidate("a", duration: 10, title: "Alpha"), candidate("c", duration: 10, title: "Gamma")])
        await waitUntil(30, "оба трека сохранены") { m.state.saved.count == 2 && m.state.jobs.isEmpty }

        XCTAssertEqual(audio("a"), a.bytes)
        XCTAssertEqual(audio("c"), c.bytes)
        XCTAssertNotNil(m.audioPath(Key.of("blink", "a")))
        let titles = m.state.saved.map { $0.title }
        XCTAssertTrue(titles.contains("Alpha") && titles.contains("Gamma"), "\(titles)")
    }
}
