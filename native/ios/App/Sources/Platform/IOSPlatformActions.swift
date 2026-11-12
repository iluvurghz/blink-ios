import UIKit
import BlinkCore

/// То, что умеет только iOS: открыть ссылку и настройки приложения.
final class IOSPlatformActions: PlatformActions, @unchecked Sendable {
    func open(_ url: URL) {
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
    }

    /// У iOS нет прямой ссылки на экран хранилища, открываем настройки Blink: оттуда один шаг назад до раздела «Основные».
    func openStorageSettings() -> Bool {
        DispatchQueue.main.async {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
        return true
    }
}
