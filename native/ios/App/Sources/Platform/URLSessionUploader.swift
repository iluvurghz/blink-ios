import Foundation
import BlinkCore

/// Отправка большого тела из файла (загрузка трека) с отчётом о ходе. Фоновых сессий не нужно: пользователь ждёт на экране.
final class URLSessionUploader: NSObject, UploadClient, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [Int: @Sendable (Double) -> Void] = [:]
    private var session: URLSession!

    init(userAgent: String) {
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = ["User-Agent": userAgent]
        cfg.timeoutIntervalForResource = 60 * 30
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func upload(_ request: HTTPRequest, bodyFile: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> HTTPResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        r.timeoutInterval = request.timeout
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HTTPResponse, Error>) in
            let task = session.uploadTask(with: r, fromFile: bodyFile) { [weak self] data, response, error in
                if let error = error {
                    let code = (error as? URLError)?.code
                    cont.resume(throwing: code == .notConnectedToInternet ? TransportError.offline : (code == .timedOut ? TransportError.timedOut : TransportError.failed(error.localizedDescription)))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    cont.resume(throwing: TransportError.failed("not an http response"))
                    return
                }
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    if let key = k as? String, let value = v as? String { headers[key] = value }
                }
                cont.resume(returning: HTTPResponse(status: http.statusCode, headers: headers, data: data ?? Data()))
            }
            lock.lock()
            reports[task.taskIdentifier] = onProgress
            lock.unlock()
            task.resume()
        }
    }


    private func forget(_ id: Int) {
        lock.lock()
        reports[id] = nil
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        lock.lock()
        let report = reports[task.taskIdentifier]
        lock.unlock()
        report?(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        forget(task.taskIdentifier)
    }
}
