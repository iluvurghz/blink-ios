import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Короткие запросы к серверу (JSON): ответ целиком в памяти. Сетевые сбои приходят как `TransportError`.
public final class URLSessionHTTP: HTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init(userAgent: String? = nil) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 16
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let ua = userAgent { cfg.httpAdditionalHeaders = ["User-Agent": ua] }
        session = URLSession(configuration: cfg)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        r.timeoutInterval = request.timeout
        r.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = request.body
        let holder = TaskHolder()
        let session = self.session
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HTTPResponse, Error>) in
                let task = session.dataTask(with: r) { data, response, error in
                    if let error = error {
                        cont.resume(throwing: URLErrorMapper.map(error))
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
                task.resume()
                // Если отмену уже успели позвать, `set` отменит запущенную задачу сам.
                holder.set(task)
            }
        } onCancel: {
            holder.cancel()
        }
    }
}
