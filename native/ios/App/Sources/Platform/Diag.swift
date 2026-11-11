import Foundation
import os

/// Короткий журнал событий плеера для проверки в симуляторе и на устройстве (Консоль на Mac, `log show`).
/// Пишем только состояния и коды ошибок: ссылок на потоки и данных аккаунта здесь нет.
enum Diag {
    private static let logger = Logger(subsystem: "app.blink.player", category: "app")

    static func note(_ text: String) {
        logger.notice("\(text, privacy: .public)")
    }

    /// Ошибка одной строкой: домен, код, описание и код вложенной ошибки.
    static func describe(_ error: Error?) -> String {
        guard let error = error else { return "-" }
        let ns = error as NSError
        var text = ns.domain + " " + String(ns.code) + " " + ns.localizedDescription
        if let inner = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " / " + inner.domain + " " + String(inner.code)
        }
        return text
    }
}
