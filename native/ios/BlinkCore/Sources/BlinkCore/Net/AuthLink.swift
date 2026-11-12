import Foundation

/// Ссылка, которой сайт возвращает пользователя в приложение после входа в системном браузере:
/// `blink://auth?id_token=…&nonce=…` (Google) или `blink://auth?tg_hash=…` (Telegram).
/// Параметры могут прийти и в части после `#`.
public enum AuthLink: Equatable, Sendable {
    case idToken(token: String, nonce: String)
    case telegramHash(String)
    case failed(String?)

    public enum Provider: Sendable { case google, telegram }

    public static let scheme = "blink"
    public static let host = "auth"

    /// Адрес страницы сайта, с которой начинается вход выбранным способом.
    public static func startURL(base: String, provider: Provider) -> String {
        var text = base
        while text.hasSuffix("/") { text.removeLast() }
        return text + "/?" + (provider == .google ? "gsignin" : "tgsignin") + "=desktop"
    }

    /// Разбирает ссылку возврата; чужие ссылки и ссылки без нужных параметров дают nil.
    public static func parse(_ url: String?) -> AuthLink? {
        guard let url = url, url.lowercased().hasPrefix(scheme + "://" + host) else { return nil }
        var params: [String: String] = [:]
        let afterQuery = url.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let query = afterQuery.count > 1 ? String(afterQuery[1].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]) : ""
        let fragmentParts = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let fragment = fragmentParts.count > 1 ? String(fragmentParts[1]) : ""
        for part in (query + "&" + fragment).split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let k = kv.first, !k.isEmpty else { continue }
            let raw = kv.count > 1 ? String(kv[1]) : ""
            params[String(k)] = raw.removingPercentEncoding ?? raw
        }
        if let token = params["id_token"], !token.isEmpty, let nonce = params["nonce"], !nonce.isEmpty {
            return .idToken(token: token, nonce: nonce)
        }
        if let hash = params["tg_hash"], !hash.isEmpty { return .telegramHash(hash) }
        if params["error"] != nil || params["error_description"] != nil {
            return .failed(params["error_description"] ?? params["error"])
        }
        return nil
    }
}
