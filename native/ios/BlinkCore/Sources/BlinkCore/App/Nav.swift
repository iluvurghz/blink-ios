import Foundation

/// Вкладки приложения. Названо не `Tab`, чтобы не спорить с типом SwiftUI.
public enum AppTab: Equatable, Sendable {
    case flash
    case search
    case downloads
    case account
}

/// Экраны поверх вкладок: комната, друзья, Blink+.
public enum AppOverlay: Equatable, Sendable {
    case none
    case room
    case friends
    case plus
    case library
    case artist
}

/// Что открыто внутри экрана «Музыка»: список плейлистов, любимое, плейлист, чужой плейлист по ссылке, подборка редакции.
public enum LibRoute: Equatable, Sendable {
    case home
    case likes
    case mine(String)
    case shared(String)
    case editorial(String)
}

public struct NavState: Equatable, Sendable {
    public var tab: AppTab
    public var playerOpen: Bool
    public var overlay: AppOverlay
    public var libRoute: LibRoute
    /// Страница артиста Blink: id или имя ссылки.
    public var artistKey: String

    public init(tab: AppTab = .flash, playerOpen: Bool = false, overlay: AppOverlay = .none, libRoute: LibRoute = .home, artistKey: String = "") {
        self.libRoute = libRoute
        self.artistKey = artistKey
        self.tab = tab
        self.playerOpen = playerOpen
        self.overlay = overlay
    }
}

/// Куда смотрит приложение. Живёт отдельно от экранов, чтобы тосты и сервисы могли переключать вкладки.
public final class Nav: @unchecked Sendable {
    private let state = Observable(NavState())

    public init() {}

    public var current: NavState { return state.current }

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (NavState) -> Void) -> NetworkObservation {
        return state.observe(handler)
    }

    /// Переход на вкладку закрывает большой плеер.
    public func go(_ tab: AppTab) {
        state.update {
            $0.tab = tab
            $0.playerOpen = false
            $0.overlay = .none
        }
    }

    public func open(_ overlay: AppOverlay) {
        state.update {
            $0.overlay = overlay
            $0.playerOpen = false
        }
    }

    public func openLibrary(_ route: LibRoute = .home) {
        state.update {
            $0.libRoute = route
            $0.overlay = .library
            $0.playerOpen = false
        }
    }

    public func openArtist(_ key: String) {
        state.update {
            $0.artistKey = key
            $0.overlay = .artist
            $0.playerOpen = false
        }
    }

    public func libraryTo(_ route: LibRoute) {
        state.update { $0.libRoute = route }
    }

    public func close() {
        state.update { $0.overlay = .none }
    }

    public func openPlayer(_ open: Bool) {
        state.update { $0.playerOpen = open }
    }
}
