import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Крошечный HTTP-сервер на 127.0.0.1 для проверки настоящего сетевого слоя (URLSession) без интернета.
/// Один запрос на соединение, ответ с `Connection: close`. Умеет рвать соединение посреди тела и молчать.
final class LoopbackServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        /// Имена заголовков в нижнем регистре.
        let headers: [String: String]
        var body: [UInt8] = []
    }

    struct Response: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: [UInt8] = []
        /// Закрыть соединение после стольких байт тела (обещанную длину заголовок при этом сохраняет).
        var cutAfter: Int?
        /// Замолчать после стольких байт тела, не закрывая соединения.
        var hangAfter: Int?
        var chunk = 16 * 1024
        var delayMs: UInt32 = 0
        /// Принять запрос и ничего не ответить.
        var stall = false
    }

    private let listener: Int32
    private let handler: @Sendable (Request) -> Response
    private let lock = NSLock()
    private var running = true
    private var requests: [Request] = []
    private var broken = 0
    /// Сигнал «слушающий сокет закрыт»: после него порт точно отвечает отказом.
    private let closed = DispatchSemaphore(value: 0)

    let port: UInt16

    var base: String { return "http://127.0.0.1:\(port)" }

    var received: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    /// Сколько раз запись в клиента упала (клиент закрыл соединение).
    var brokenWrites: Int {
        lock.lock()
        defer { lock.unlock() }
        return broken
    }

    init(handler: @escaping @Sendable (Request) -> Response) throws {
        signal(SIGPIPE, SIG_IGN)
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        if fd < 0 { throw NSError(domain: "loopback", code: 1) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        if bound != 0 || listen(fd, 16) != 0 {
            close(fd)
            throw NSError(domain: "loopback", code: 2)
        }
        var out = sockaddr_in()
        var len = size
        _ = withUnsafeMutablePointer(to: &out) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.listener = fd
        self.port = UInt16(bigEndian: out.sin_port)
        self.handler = handler
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    /// Останавливает сервер и ждёт, пока порт закроется (до двух секунд).
    func stop() {
        lock.lock()
        let already = !running
        running = false
        lock.unlock()
        if already { return }
        _ = closed.wait(timeout: .now() + 2)
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func acceptLoop() {
        while isRunning {
            var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 100)
            if ready <= 0 { continue }
            let conn = accept(listener, nil, nil)
            if conn < 0 { continue }
            Thread.detachNewThread { [self] in
                serve(conn)
                close(conn)
            }
        }
        close(listener)
        closed.signal()
    }

    private func readRequest(_ conn: Int32) -> Request? {
        var data = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < 64 * 1024 {
            let n = recv(conn, &buf, buf.count, 0)
            if n <= 0 { return nil }
            data.append(contentsOf: buf[0..<n])
            guard let end = findEnd(data) else { continue }
            let head = String(decoding: data[0..<end], as: UTF8.self)
            guard var request = parse(head) else { return nil }
            // Тело запроса дочитываем до конца: закрыть сокет с непрочитанным входом значит отправить RST и потерять ответ.
            let want = Int(request.headers["content-length"] ?? "") ?? 0
            var body = Array(data[(end + 4)...])
            while body.count < want && body.count < 1024 * 1024 {
                let m = recv(conn, &buf, buf.count, 0)
                if m <= 0 { break }
                body.append(contentsOf: buf[0..<m])
            }
            request.body = body
            return request
        }
        return nil
    }

    private func findEnd(_ d: [UInt8]) -> Int? {
        var i = 0
        while i + 3 < d.count {
            if d[i] == 13 && d[i + 1] == 10 && d[i + 2] == 13 && d[i + 3] == 10 { return i }
            i += 1
        }
        return nil
    }

    private func parse(_ head: String) -> Request? {
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        if parts.count < 2 { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath
        return Request(method: String(parts[0]), path: path, headers: headers)
    }

    @discardableResult
    private func writeAll(_ conn: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { p -> Int in
                return send(conn, p.baseAddress! + sent, bytes.count - sent, 0)
            }
            if n <= 0 {
                lock.lock()
                broken += 1
                lock.unlock()
                return false
            }
            sent += n
        }
        return true
    }

    private func serve(_ conn: Int32) {
        guard let req = readRequest(conn) else { return }
        lock.lock()
        requests.append(req)
        lock.unlock()
        let res = handler(req)
        if res.stall {
            // держим соединение открытым, пока тест не остановит сервер
            while isRunning { usleep(20_000) }
            return
        }
        var head = "HTTP/1.1 \(res.status) \(reason(res.status))\r\n"
        var headers = res.headers
        if headers["Content-Length"] == nil { headers["Content-Length"] = String(res.body.count) }
        headers["Connection"] = "close"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        if !writeAll(conn, Array(head.utf8)) { return }
        let limit = min(res.cutAfter ?? res.hangAfter ?? res.body.count, res.body.count)
        var offset = 0
        while offset < limit {
            let n = min(max(1, res.chunk), limit - offset)
            if !writeAll(conn, Array(res.body[offset..<(offset + n)])) { return }
            offset += n
            if res.delayMs > 0 { usleep(res.delayMs * 1000) }
        }
        if res.hangAfter != nil {
            while isRunning { usleep(20_000) }
        }
    }

    private func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}
