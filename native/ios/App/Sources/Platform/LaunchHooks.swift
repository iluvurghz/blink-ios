import Foundation
import BlinkCore

/// Параметры запуска для проверки в симуляторе, где на экран нельзя нажимать: какую вкладку открыть,
/// какой запрос вписать в поиск и открыть ли плеер с первым треком. CI передаёт их переменными окружения
/// (`SIMCTL_CHILD_BLINK_START_TAB=downloads`). У пользователя этих переменных нет, и приложение ведёт себя как всегда.
enum LaunchHooks {
    private static let env = ProcessInfo.processInfo.environment

    static var startTab: AppTab? {
        switch env["BLINK_START_TAB"] {
        case "downloads": return .downloads
        case "account": return .account
        default: return nil
        }
    }

    static var startQuery: String {
        return env["BLINK_START_QUERY"] ?? ""
    }

    static var startPlayer: Bool {
        return env["BLINK_START_PLAYER"] == "1"
    }

    /// Вызывается один раз после старта приложения.
    static func run(search: SearchModel, actions: Actions, nav: Nav) {
        if let tab = startTab { nav.go(tab) }
        guard startPlayer else { return }
        // Ждём, пока на главной появятся треки, включаем первый и открываем большой плеер.
        Task {
            for _ in 0..<80 {
                let state = search.current
                if let first = state.newest.first ?? state.chart.first {
                    actions.play([first], at: 0)
                    nav.openPlayer(true)
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}
