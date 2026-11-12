import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Переводит ошибку URLSession в то, что понимает ядро.
enum URLErrorMapper {
    static func map(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let e = error as? URLError {
            switch e.code {
            case .cancelled:
                return CancellationError()
            case .timedOut:
                return TransportError.timedOut
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return TransportError.offline
            default:
                return TransportError.failed(e.localizedDescription)
            }
        }
        return TransportError.failed(String(describing: error))
    }
}

/// Держит задачу, чтобы отмена до старта и после старта работала одинаково.
final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ t: URLSessionTask) {
        lock.lock()
        task = t
        let already = cancelled
        lock.unlock()
        if already { t.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}

/// Потоковый GET для скачивания: заголовки приходят сразу, тело отдаётся кусками по мере поступления.
/// Пауза без байтов дольше `idleTimeout` секунд это `TransportError.timedOut`; отмена задачи рвёт соединение.
/// Работает на переднем плане; фоновая докачка системой (background URLSession) придёт позже.
public final class URLSessionTransport: NSObject, Transport, URLSessionDataDelegate, @unchecked Sendable {
    private final class Pending {
        var waiting: CheckedContinuation<TransportResponse, Error>?
        var stream: AsyncThrowingStream<Data, Error>.Continuation?
        var received = 0
        var status = 0
    }

    /// Ответ с ошибкой читать целиком незачем: тело больше этого предела отбрасываем.
    private static let errorBodyLimit = 64 * 1024

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession?
    private let idleTimeout: TimeInterval

    public init(idleTimeout: TimeInterval = 20, userAgent: String? = nil) {
        self.idleTimeout = idleTimeout
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = idleTimeout
        cfg.timeoutIntervalForResource = 6 * 3600
        #if !canImport(FoundationNetworking)
        cfg.waitsForConnectivity = false // нет сети: сразу ошибка, а не ожидание (на Linux свойство только для чтения)
        #endif
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let ua = userAgent { cfg.httpAdditionalHeaders = ["User-Agent": ua] }
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    /// Закрывает сессию (она держит делегата, пока жива).
    public func invalidate() {
        session?.invalidateAndCancel()
        session = nil
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> TransportResponse {
        try Task.checkCancellation()
        guard let session = session else { throw TransportError.failed("session closed") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Предел паузы без байтов: и на сессии, и на самом запросе (Linux читает только запрос).
        request.timeoutInterval = idleTimeout
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<TransportResponse, Error>) in
                let task = session.dataTask(with: request)
                let p = Pending()
                p.waiting = cont
                lock.lock()
                pending[task.taskIdentifier] = p
                lock.unlock()
                task.resume()
                // Если отмену уже успели позвать, `set` отменит запущенную задачу сам.
                holder.set(task)
            }
        } onCancel: {
            holder.cancel()
        }
    }

    // ---------- URLSessionDataDelegate ----------

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let p = pending[dataTask.taskIdentifier]
        lock.unlock()
        guard let p = p, let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let key = k as? String, let value = v as? String { headers[key] = value }
        }
        var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        let stream = AsyncThrowingStream<Data, Error>(Data.self, bufferingPolicy: .unbounded) { c in
            continuation = c
        }
        continuation?.onTermination = { _ in dataTask.cancel() }
        p.stream = continuation
        p.status = http.statusCode
        let waiting = p.waiting
        p.waiting = nil
        waiting?.resume(returning: TransportResponse(status: http.statusCode, headers: headers, body: stream))
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let p = pending[dataTask.taskIdentifier]
        lock.unlock()
        guard let p = p else { return }
        p.received += data.count
        if p.status >= 300 && p.received > URLSessionTransport.errorBodyLimit {
            p.stream?.finish()
            dataTask.cancel()
            return
        }
        p.stream?.yield(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let p = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let p = p else { return }
        if let waiting = p.waiting {
            p.waiting = nil
            waiting.resume(throwing: error.map { URLErrorMapper.map($0) } ?? TransportError.failed("no response"))
            return
        }
        if let error = error {
            p.stream?.finish(throwing: URLErrorMapper.map(error))
        } else {
            p.stream?.finish()
        }
    }
}
