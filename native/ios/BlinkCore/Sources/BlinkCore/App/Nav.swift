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
}

public struct NavState: Equatable, Sendable {
    public var tab: AppTab
    public var playerOpen: Bool
    public var overlay: AppOverlay

    public init(tab: AppTab = .flash, playerOpen: Bool = false, overlay: AppOverlay = .none) {
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

    public func close() {
        state.update { $0.overlay = .none }
    }

    public func openPlayer(_ open: Bool) {
        state.update { $0.playerOpen = open }
    }
}
