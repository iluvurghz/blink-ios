import Foundation
import XCTest
@testable import BlinkCore

// ---------- общие помощники ----------

/// Потокобезопасный журнал для замыканий, которые зовёт ядро из других задач.
final class Log<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [T] = []

    func add(_ value: T) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var items: [T] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var count: Int { return items.count }
    var last: T? { return items.last }
}

struct DeadlineError: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { return "не дождались за \(seconds) с" }
}

/// Страховка от зависания теста: ждём не дольше `seconds`.
func withDeadline<T: Sendable>(_ seconds: Double = 60, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw DeadlineError(seconds: seconds)
        }
        guard let first = try await group.next() else { throw DeadlineError(seconds: seconds) }
        group.cancelAll()
        return first
    }
}

/// Ждёт, пока условие станет истинным (опрос раз в 10 мс).
func waitUntil(_ seconds: Double = 30, _ what: String = "условие", file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
    let end = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > end {
            XCTFail("не дождались: \(what)", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Выполняет операцию и возвращает ошибку офлайна (или роняет тест, если ошибки нет или она другая).
func offlineError(_ op: @Sendable () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> OfflineError? {
    do {
        try await op()
        XCTFail("ожидали ошибку", file: file, line: line)
        return nil
    } catch let e as OfflineError {
        return e
    } catch {
        XCTFail("ожидали OfflineError, пришло: \(error)", file: file, line: line)
        return nil
    }
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("blink-offline-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// ---------- данные ----------

enum Audio {
    /// Правдоподобный «mp3»: ID3-заголовок и детерминированный шум.
    static func bytes(_ size: Int, seed: UInt64 = 7) -> [UInt8] {
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        var out = [UInt8](repeating: 0, count: size)
        var i = 0
        while i < size {
            // SplitMix64: по одному числу на 8 байт
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            var k = 0
            while k < 8 && i < size {
                out[i] = UInt8(truncatingIfNeeded: z >> UInt64(8 * k))
                i += 1
                k += 1
            }
        }
        if size >= 4 {
            out[0] = 0x49
            out[1] = 0x44
            out[2] = 0x33
            out[3] = 4
        }
        return out
    }
}

final class Fixture: @unchecked Sendable {
    let id: String
    var bytes: [UInt8]
    var etag: String? = "W/\"e1\""
    var honorRange = true
    var cap: Int64 = 2 * 1024 * 1024
    var contentType = "audio/mpeg"
    var duration = 60
    var resolveBytes: Int64?
    private let lock = NSLock()
    private var hits = 0

    init(id: String, bytes: [UInt8]) {
        self.id = id
        self.bytes = bytes
        self.resolveBytes = Int64(bytes.count)
    }

    func nextHit() -> Int {
        lock.lock()
        defer { lock.unlock() }
        hits += 1
        return hits
    }
}

struct Recorded: Sendable {
    let url: URL
    let headers: [String: String]

    var path: String { return url.path }

    func header(_ name: String) -> String? {
        for (k, v) in headers where k.lowercased() == name.lowercased() { return v }
        return nil
    }
}

/// Ответ сервера-двойника: статус, заголовки, тело и как оно доходит (с обрывом, с паузами).
struct Reply: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body: [UInt8] = []
    /// Тело обрывается ошибкой после стольких байт.
    var cutAfter: Int?
    /// Вместо ответа бросаем ошибку транспорта.
    var failure: TransportError?
    var chunk = 64 * 1024
    var delayPerChunkMs: UInt64 = 0
}

/// Сервер-двойник в памяти: подписанные ссылки `/media/<id>` с поведением `streamController.js`
/// (Range, If-Range по etag, потолок 2 МиБ на открытый Range, 416) и резолвер.
final class FakeBackend: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: Fixture] = [:]
    private var recorded: [Recorded] = []
    private var inFlight = 0
    private var peak = 0

    private var resolveLog: [HTTPRequest] = []
    private var playLog: [HTTPRequest] = []

    /// Подмена ответа на файл: (запрос, номер запроса к этому id с 1) → ответ или nil (обычное поведение).
    var fileHook: (@Sendable (Recorded, Int) -> Reply?)?
    /// Подмена ответа резолвера.
    var resolveHook: (@Sendable (HTTPRequest) -> HTTPResponse?)?
    /// Резолвера на сервере ещё нет: `/api/offline/resolve` отвечает 404 без нашего JSON.
    var legacyOnly = false
    var throttleChunk = 0
    var throttleMs: UInt64 = 100

    let base = "http://backend.test"

    var resolveRequests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return resolveLog
    }

    var playRequests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return playLog
    }

    func logResolve(_ r: HTTPRequest) {
        lock.lock()
        resolveLog.append(r)
        lock.unlock()
    }

    func logPlay(_ r: HTTPRequest) {
        lock.lock()
        playLog.append(r)
        lock.unlock()
    }

    var fileRequests: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var maxInFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    @discardableResult
    func add(_ id: String, _ size: Int, seed: UInt64 = 7, duration: Int = 60, configure: (Fixture) -> Void = { _ in }) -> Fixture {
        let f = Fixture(id: id, bytes: Audio.bytes(size, seed: seed))
        f.duration = duration
        configure(f)
        set(f)
        return f
    }

    func set(_ f: Fixture) {
        lock.lock()
        fixtures[f.id] = f
        lock.unlock()
    }

    func fixture(_ id: String) -> Fixture? {
        lock.lock()
        defer { lock.unlock() }
        return fixtures[id]
    }

    // ---- Transport ----

    func get(_ url: URL, headers: [String: String]) async throws -> TransportResponse {
        let req = Recorded(url: url, headers: headers)
        guard req.path.hasPrefix("/media/") else {
            return stream(Reply(status: 404, body: Array("not found".utf8)))
        }
        let id = String(req.path.dropFirst("/media/".count))
        lock.lock()
        recorded.append(req)
        let f = fixtures[id]
        inFlight += 1
        peak = max(peak, inFlight)
        lock.unlock()
        defer {
            lock.lock()
            inFlight -= 1
            lock.unlock()
        }
        guard let fixture = f else { return stream(Reply(status: 404)) }
        let n = fixture.nextHit()
        var reply = fileHook?(req, n) ?? serve(fixture, req)
        if let failure = reply.failure { throw failure }
        if throttleChunk > 0 && reply.delayPerChunkMs == 0 {
            reply.chunk = throttleChunk
            reply.delayPerChunkMs = throttleMs
        }
        return stream(reply)
    }

    private func stream(_ reply: Reply) -> TransportResponse {
        var headers = reply.headers
        if reply.cutAfter == nil && headers["Content-Length"] == nil { headers["Content-Length"] = String(reply.body.count) }
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var offset = 0
                let limit = min(reply.cutAfter ?? reply.body.count, reply.body.count)
                while offset < limit {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    let n = min(max(1, reply.chunk), limit - offset)
                    continuation.yield(Data(reply.body[offset..<(offset + n)]))
                    offset += n
                    if reply.delayPerChunkMs > 0 {
                        try? await Task.sleep(nanoseconds: reply.delayPerChunkMs * 1_000_000)
                    }
                }
                if reply.cutAfter != nil {
                    continuation.finish(throwing: TransportError.failed("connection reset"))
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return TransportResponse(status: reply.status, headers: headers, body: body)
    }

    /// Обычное поведение сервера для запроса к файлу.
    func serve(_ f: Fixture, _ req: Recorded) -> Reply {
        let total = Int64(f.bytes.count)
        let range = req.header("Range")
        let ifRange = req.header("If-Range")
        let full = range == nil || !f.honorRange || (ifRange != nil && ifRange != f.etag)
        var headers: [String: String] = ["Content-Type": f.contentType, "Accept-Ranges": "bytes"]
        if let e = f.etag { headers["ETag"] = e }
        if full { return Reply(status: 200, headers: headers, body: f.bytes) }

        let unsatisfiable = Reply(status: 416, headers: ["Content-Range": "bytes */\(total)"])
        guard
            let raw = range,
            let re = try? NSRegularExpression(pattern: "bytes=(\\d+)-(\\d*)"),
            let m = re.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length))
        else { return unsatisfiable }
        let ns = raw as NSString
        guard let start = Int64(ns.substring(with: m.range(at: 1))) else { return unsatisfiable }
        if start >= total { return unsatisfiable }
        let askedText = ns.substring(with: m.range(at: 2))
        let asked: Int64? = askedText.isEmpty ? nil : Int64(askedText)
        let end = min(asked ?? Int64.max, start + f.cap - 1, total - 1)
        headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
        return Reply(status: 206, headers: headers, body: Array(f.bytes[Int(start)...Int(end)]))
    }

    /// Ответ, у которого заголовок обещает всё, а тело обрывается после `cut` байт.
    func cutAt(_ f: Fixture, _ req: Recorded, _ cut: Int) -> Reply {
        var r = serve(f, req)
        r.headers["Content-Length"] = String(r.body.count)
        r.cutAfter = cut
        return r
    }

    // ---- резолвер ----

    func resolver() -> TrackResolver {
        return BackendResolver(backend: self)
    }

    func resolved(_ id: String) throws -> Resolved {
        guard let f = fixture(id) else { throw OfflineError(.notDownloadable, "missing") }
        return Resolved(
            url: "\(base)/media/\(id)?sig=\(fileRequests.count)",
            mime: f.contentType,
            bytes: f.resolveBytes,
            etag: f.etag,
            expiresAt: Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000,
            duration: f.duration
        )
    }
}

struct BackendResolver: TrackResolver {
    let backend: FakeBackend

    func resolve(source: String, id: String) async throws -> Resolved {
        return try backend.resolved(id)
    }
}

// ---------- короткие запросы к серверу (резолвер) ----------

func jsonReply(_ status: Int, _ body: String) -> HTTPResponse {
    return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], data: Data(body.utf8))
}

func jsonObjectReply(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], data: data)
}

func queryValue(_ request: HTTPRequest, _ name: String) -> String? {
    return URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

extension FakeBackend: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path
        if path == "/api/offline/resolve" { return resolveReply(request) }
        if path.hasPrefix("/api/play/") { return playReply(request, String(path.dropFirst("/api/play/".count))) }
        return HTTPResponse(status: 404, data: Data("not found".utf8))
    }

    private func resolveReply(_ req: HTTPRequest) -> HTTPResponse {
        logResolve(req)
        if let hooked = resolveHook?(req) { return hooked }
        if legacyOnly { return HTTPResponse(status: 404, data: Data("Cannot GET /api/offline/resolve".utf8)) }
        if req.headers["Authorization"] == nil {
            return jsonObjectReply(401, ["ok": false, "error": "NOT_ALLOWED", "reason": "auth"])
        }
        let id = queryValue(req, "id") ?? ""
        guard let f = fixture(id) else {
            return jsonObjectReply(404, ["ok": false, "error": "NOT_DOWNLOADABLE", "reason": "missing"])
        }
        var body: [String: Any] = [
            "ok": true,
            "source": "blink",
            "id": id,
            "url": "\(base)/media/\(id)?sig=\(resolveRequests.count)",
            "mime": f.contentType,
            "duration": f.duration,
            "expiresAt": Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000,
        ]
        if let b = f.resolveBytes { body["bytes"] = b }
        if let e = f.etag { body["etag"] = e }
        return jsonObjectReply(200, body)
    }

    private func playReply(_ req: HTTPRequest, _ id: String) -> HTTPResponse {
        logPlay(req)
        if req.headers["Authorization"] == nil { return jsonObjectReply(401, ["error": "auth"]) }
        if fixture(id) == nil { return jsonObjectReply(404, ["error": "not_found"]) }
        return jsonObjectReply(200, ["url": "/media/\(id)?legacy=1"])
    }
}

struct ClosureResolver: TrackResolver {
    let body: @Sendable (String, String) async throws -> Resolved

    func resolve(source: String, id: String) async throws -> Resolved {
        return try await body(source, id)
    }
}

func job(_ id: String, duration: Int = 60, title: String? = nil) -> OfflineJob {
    return OfflineJob(
        key: Key.of("blink", id),
        source: "blink",
        id: id,
        meta: JobMeta(title: title ?? "Track \(id)", artist: "Artist", duration: duration),
        createdAt: Int64(Date().timeIntervalSince1970 * 1000)
    )
}

func candidate(_ id: String, duration: Int = 60, title: String? = nil) -> Candidate {
    return Candidate(key: Key.of("blink", id), source: "blink", id: id, meta: JobMeta(title: title ?? "Track \(id)", artist: "Artist", duration: duration))
}
