import Foundation

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    /// Предел паузы без байтов и целого запроса, секунды.
    public var timeout: TimeInterval

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 20) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    /// Ключи в нижнем регистре.
    public let headers: [String: String]
    public let data: Data

    public init(status: Int, headers: [String: String] = [:], data: Data = Data()) {
        self.status = status
        var lower: [String: String] = [:]
        for (k, v) in headers { lower[k.lowercased()] = v }
        self.headers = lower
        self.data = data
    }

    public var text: String { return String(decoding: data, as: UTF8.self) }
    public var ok: Bool { return status >= 200 && status <= 299 }
}

/// Короткие запросы с телом в памяти (JSON). Сетевые сбои приходят как `TransportError`.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Токен для запросов к серверу Blink. nil значит «не вошёл».
public protocol TokenProvider: Sendable {
    func accessToken() async -> String?
}

/// Адреса сервисов. Ключ Supabase публичный, но в репозиторий его не кладём: он приходит при сборке.
public struct BlinkConfig: Sendable {
    public var baseURL: String
    public var supabaseURL: String
    public var supabaseAnonKey: String

    public init(
        baseURL: String = "https://blinkmusic.cc",
        supabaseURL: String = "https://wjyohhvpqvfhyhrrbhgc.supabase.co",
        supabaseAnonKey: String = ""
    ) {
        self.baseURL = baseURL
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
    }

    public var base: String { return BlinkConfig.trimSlash(baseURL) }
    public var supabase: String { return BlinkConfig.trimSlash(supabaseURL) }
    public var hasKey: Bool { return !supabaseAnonKey.trimmingCharacters(in: .whitespaces).isEmpty }

    private static func trimSlash(_ s: String) -> String {
        var t = s
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    /// Относительные ссылки сервера и утёкшие 127.0.0.1 приводим к адресу сайта (как `toAbsolute` в вебе).
    public func absolute(_ url: String?) -> String? {
        guard let url = url, !url.isEmpty else { return nil }
        for prefix in ["http://127.0.0.1", "https://127.0.0.1", "http://localhost", "https://localhost"] where url.hasPrefix(prefix) {
            var rest = Substring(url.dropFirst(prefix.count))
            if let first = rest.first, first != "/" && first != ":" && first != "?" { break }
            if rest.hasPrefix(":") {
                rest = rest.dropFirst()
                rest = rest.drop(while: { $0.isASCII && $0.isNumber })
            }
            return base + String(rest)
        }
        if url.hasPrefix("//") { return "https:" + url }
        if url.hasPrefix("/") { return base + url }
        return url
    }
}

/// Сборка адресов с правильным кодированием (плюс в запросе становится %2B, а не пробелом).
public enum URLBuilder {
    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    public static func encode(_ s: String) -> String {
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    public static func make(_ base: String, path: String, query: [(String, String)] = []) -> URL? {
        var text = base
        while text.hasSuffix("/") { text.removeLast() }
        for part in path.split(separator: "/") {
            text += "/" + encode(String(part))
        }
        if !query.isEmpty {
            text += "?" + query.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
        }
        return URL(string: text)
    }
}
