import Foundation

/// Коды ошибок офлайна. Одинаковые на всех платформах (контракт offline-cache v1).
public enum OfflineCode: String, Codable, CaseIterable, Sendable {
    case noNetwork = "NO_NETWORK"
    case noMatch = "NO_MATCH"
    case notDownloadable = "NOT_DOWNLOADABLE"
    case notAllowed = "NOT_ALLOWED"
    case sourceError = "SOURCE_ERROR"
    case badContent = "BAD_CONTENT"
    case noSpace = "NO_SPACE"
    case timeout = "TIMEOUT"
    case cancelled = "CANCELLED"

    /// Автоповтор имеет смысл только для сетевых сбоев.
    public var retryable: Bool { self == .timeout || self == .sourceError }

    /// Отказы по сути трека: запоминаем на 24 часа и не дёргаем источник.
    public var isRefusal: Bool {
        self == .notAllowed || self == .notDownloadable || self == .noMatch || self == .badContent
    }
}

public struct OfflineError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: OfflineCode
    public let reason: String?
    public let detail: String?

    public init(_ code: OfflineCode, _ reason: String? = nil, detail: String? = nil) {
        self.code = code
        self.reason = reason
        self.detail = detail
    }

    public var description: String {
        var s = code.rawValue
        if let r = reason { s += "/" + r }
        if let d = detail { s += " (" + d + ")" }
        return s
    }
}

/// Что показать человеку: понятный текст и подпись кнопки.
public struct OfflineText: Equatable, Sendable {
    public enum Action: String, Sendable {
        case retry
        case openPlus
        case signIn
        case freeSpace

        public var label: String {
            switch self {
            case .retry: return "Повторить"
            case .openPlus: return "Открыть Blink+"
            case .signIn: return "Войти"
            case .freeSpace: return "Освободить место"
            }
        }
    }

    public let message: String
    public let action: Action?

    public init(_ message: String, _ action: Action?) {
        self.message = message
        self.action = action
    }
}

public enum OfflineTexts {
    public static func of(_ code: OfflineCode, _ reason: String? = nil) -> OfflineText {
        switch code {
        case .noNetwork: return OfflineText("Нет интернета", .retry)
        case .noMatch: return OfflineText("Не нашли нужную версию трека", .retry)
        case .notDownloadable: return OfflineText("Для этого трека нет файла", nil)
        case .notAllowed:
            switch reason {
            case "plus": return OfflineText("Сохранение для офлайна доступно с Blink+", .openPlus)
            case "artist": return OfflineText("Артист не разрешил сохранять этот трек", nil)
            case "auth": return OfflineText("Войдите в аккаунт", .signIn)
            default: return OfflineText("Этот трек играет только онлайн", nil)
            }
        case .sourceError: return OfflineText("Сервер сейчас не отвечает", .retry)
        case .badContent: return OfflineText("Файл пришёл повреждённым", .retry)
        case .noSpace: return OfflineText("Не хватает места на устройстве", .freeSpace)
        case .timeout: return OfflineText("Сервер долго не отвечает", .retry)
        case .cancelled: return OfflineText("", nil)
        }
    }
}
