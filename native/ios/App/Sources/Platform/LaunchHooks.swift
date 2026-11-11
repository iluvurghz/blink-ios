import Foundation
import BlinkCore

/// Параметры запуска для проверки в симуляторе, где на экран нельзя нажимать: какую вкладку открыть,
/// какой запрос вписать в поиск и какой трек включить в большом плеере. CI передаёт их переменными окружения
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

    /// `1`: первый трек из чарта (его можно играть без входа). `blink`: первый свежий трек Blink
    /// (без входа плеер ответит «Войдите в аккаунт»).
    static var startPlayer: String? {
        let value = env["BLINK_START_PLAYER"]
        return value == "1" || value == "blink" ? value : nil
    }

    /// Вызывается один раз после старта приложения.
    static func run(search: SearchModel, actions: Actions, nav: Nav, player: PlayerController) {
        if let tab = startTab { nav.go(tab) }
        guard let mode = startPlayer else { return }
        // Ждём, пока на главной появятся треки, включаем нужный и открываем большой плеер.
        Task {
            for _ in 0..<80 {
                let state = search.current
                let pick: Track?
                if mode == "blink" {
                    pick = state.newest.first(where: { OfflinePolicy.savable($0) }) ?? state.newest.first
                } else {
                    pick = state.chart.first
                }
                if let first = pick {
                    actions.play([first], at: 0)
                    nav.openPlayer(true)
                    // Состояние плеера в журнал каждые три секунды: по нему видно, пошёл ли звук (см. Diag).
                    for step in 1...6 {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        let ui = player.current
                        Diag.note("player +" + String(step * 3) + "s playing=" + String(ui.playing) + " buffering=" + String(ui.buffering) + " position=" + String(ui.positionMs) + "ms")
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}
