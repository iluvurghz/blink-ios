import Foundation
import BlinkCore

/// Параметры запуска для проверки в симуляторе, где на экран нельзя нажимать: какую вкладку открыть,
/// какой запрос вписать в поиск и какой трек включить в большом плеере. CI передаёт их переменными окружения
/// (`SIMCTL_CHILD_BLINK_START_TAB=downloads`). У пользователя этих переменных нет, и приложение ведёт себя как всегда.
enum LaunchHooks {
    private static let env = ProcessInfo.processInfo.environment

    static var startTab: AppTab? {
        switch env["BLINK_START_TAB"] {
        case "flash": return .flash
        case "search": return .search
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

    /// Что показать в большом плеере: `lyrics` (текст на карточке), `full` (текст во весь экран), `queue`.
    static var startStage: String? {
        return env["BLINK_START_STAGE"]
    }

    /// `1`: включить трек, но плеер не открывать (виден мини-плеер).
    static var startMini: Bool {
        return env["BLINK_START_MINI"] == "1"
    }

    /// `likes` или `home`: открыть «Музыку» на этой странице.
    static var startLibrary: LibRoute? {
        switch env["BLINK_START_LIBRARY"] {
        case "likes": return .likes
        case "home": return .home
        default: return nil
        }
    }

    /// `collection`: главная прокручена к «Коллекции».
    static var startScroll: String? {
        return env["BLINK_START_SCROLL"]
    }

    /// Секунда заставки, на которой её остановить (снимки экрана). Без переменной заставка идёт как обычно.
    static var introAt: Double? {
        return Double(env["BLINK_INTRO_AT"] ?? "")
    }

    /// Вызывается один раз после старта приложения.
    static func run(search: SearchModel, actions: Actions, nav: Nav, player: PlayerController, flash: FlashController) {
        if let tab = startTab { nav.go(tab) }
        // `N`: отметить сердечком первые N треков чарта, чтобы на снимках была живая коллекция.
        if let n = Int(env["BLINK_START_LIKES"] ?? ""), n > 0 {
            Task { @MainActor in
                for _ in 0..<80 {
                    let chart = search.current.chart
                    if !chart.isEmpty {
                        for t in chart.prefix(n) where !flash.isLiked(t) { flash.toggleLike(t) }
                        return
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        if let route = startLibrary { nav.openLibrary(route) }
        // `1`: сразу включить Вспышку (главная в режиме «играет»).
        if env["BLINK_START_FLASH"] == "1" {
            flash.start()
            return
        }
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
                    if !startMini { nav.openPlayer(true) }
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
