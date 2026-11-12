import Foundation

/// То, что умеет только платформа: открыть ссылку и настройки телефона.
public protocol PlatformActions: Sendable {
    func open(_ url: URL)
    /// Открывает настройки хранилища телефона. false, если открыть нечем.
    func openStorageSettings() -> Bool
}

/// Что происходит по нажатиям: сохранить, играть, объяснить отказ. Правила сохранения берутся из ядра
/// (`OfflinePolicy`), здесь только склейка с экраном: тосты, переходы, очередь плеера.
public final class Actions: @unchecked Sendable {
    private let auth: SupabaseAuth
    private let plus: PlusTracker
    private let offline: OfflineManager
    private let network: NetworkMonitor
    private let toasts: Toasts
    private let nav: Nav
    private let player: PlayerControl
    private let config: BlinkConfig
    private let platform: PlatformActions
    private let now: @Sendable () -> Int64

    public init(
        auth: SupabaseAuth,
        plus: PlusTracker,
        offline: OfflineManager,
        network: NetworkMonitor,
        toasts: Toasts,
        nav: Nav,
        player: PlayerControl,
        config: BlinkConfig,
        platform: PlatformActions,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.auth = auth
        self.plus = plus
        self.offline = offline
        self.network = network
        self.toasts = toasts
        self.nav = nav
        self.player = player
        self.config = config
        self.platform = platform
        self.now = now
    }

    private func decide(_ track: Track) -> OfflinePolicy.Decision {
        return OfflinePolicy.check(track, signedIn: auth.session != nil, plusActive: plus.info.activeAt(now()))
    }

    // ---------- сохранить ----------

    public func save(_ track: Track) {
        Task { [self] in await saveNow([track]) }
    }

    public func saveAll(_ tracks: [Track]) {
        Task { [self] in await saveNow(tracks) }
    }

    func saveNow(_ tracks: [Track]) async {
        var verdicts = tracks.map { ($0, decide($0)) }
        // Подписку могли оформить на сайте: перед отказом «нужен Blink+» спрашиваем сервер ещё раз.
        let needsPlusCheck = verdicts.contains { v in
            if case .denied(_, let reason) = v.1 { return reason == "plus" }
            return false
        }
        if needsPlusCheck {
            _ = await plus.refresh()
            verdicts = tracks.map { ($0, decide($0)) }
        }
        let allowed = verdicts.filter { $0.1 == .allowed }.map { $0.0 }
        if allowed.isEmpty {
            var denials: [(OfflineCode, String?)] = []
            for v in verdicts {
                if case .denied(let code, let reason) = v.1 { denials.append((code, reason)) }
            }
            // Для пакета важнее причина «войдите» или «нужен Blink+», чем «этот трек только онлайн».
            let best = denials.first { $0.1 == "auth" || $0.1 == "plus" } ?? denials.first
            guard let b = best else { return }
            explain(b.0, b.1, nil)
            return
        }
        let candidates = allowed.compactMap { OfflinePolicy.candidate($0) }
        let results = offline.enqueue(candidates)
        if candidates.count == 1 {
            let key = candidates[0].key
            switch results[key] {
            case .some(.alreadySaved):
                toasts.show("Уже сохранён")
            case .some(.remembered(let code, let reason)):
                explain(code, reason, key)
            case .some(.rejected(let code, let reason)):
                explain(code, reason, key)
            default:
                break
            }
        }
    }

    /// Человеческая причина отказа и кнопка, которая это чинит (войти, открыть Blink+, повторить).
    public func explain(_ code: OfflineCode, _ reason: String?, _ key: String?) {
        let text = OfflineTexts.of(code, reason)
        let label = text.action?.label
        guard let action = text.action else {
            toasts.show(text.message)
            return
        }
        switch action {
        case .signIn:
            let nav = self.nav
            toasts.show(text.message, action: label) { nav.go(.account) }
        case .openPlus:
            toasts.show(text.message, action: label) { [self] in openPlus() }
        case .freeSpace:
            toasts.show(text.message, action: label) { [self] in openStorageSettings() }
        case .retry:
            if let key = key {
                toasts.show(text.message, action: label) { [self] in retry(key) }
            } else {
                toasts.show(text.message)
            }
        }
    }

    /// Нажали на значок «играет только онлайн».
    public func explainOnlineOnly(_ track: Track) {
        let reason = (track.offline == false && !(track.lic ?? "").isEmpty) ? "artist" : "source"
        explain(.notAllowed, reason, nil)
    }

    /// Что делает нажатие на значок у трека: объясняет «только онлайн», повторяет неудачу или ставит в очередь.
    public func saveTapped(_ track: Track) {
        let state = offline.state
        switch SaveUi.of(track, state) {
        case .onlineOnly:
            explainOnlineOnly(track)
        case .saved:
            toasts.show("Уже сохранён")
        case .available, .failed:
            save(track)
        case .queued, .progress:
            if let key = OfflinePolicy.keyOf(track) {
                toasts.show("Сохраняется", action: "Отменить") { [self] in cancel(key) }
            }
        }
    }

    public func removeSaved(_ key: String) {
        let offline = self.offline
        Task.detached { offline.remove(key) }
    }

    public func retry(_ key: String) {
        let offline = self.offline
        Task.detached { offline.retry(key) }
    }

    public func retryAll() {
        let offline = self.offline
        Task.detached { offline.retryAll() }
    }

    public func cancel(_ key: String) {
        let offline = self.offline
        Task.detached { offline.cancel(key) }
    }

    public func clearAll() {
        let offline = self.offline
        Task.detached { offline.clearAll() }
    }

    // ---------- играть ----------

    public func play(_ tracks: [Track], at index: Int) {
        if tracks.isEmpty { return }
        let start = min(max(0, index), tracks.count - 1)
        if network.isOnline {
            player.play(tracks, at: start)
            return
        }
        // Без сети играют только сохранённые, и только с активным Blink+ (по последней известной дате).
        if !OfflinePolicy.canPlaySaved(online: false, plusUntilMs: plus.info.offlineUntilMs(), nowMs: now()) {
            toasts.show("Без интернета сохранённые играют с Blink+", action: "Открыть Blink+") { [self] in openPlus() }
            return
        }
        let saved = offline
        let queue = QueueFilter.offline(tracks, startIndex: start) { t in
            guard let key = OfflinePolicy.keyOf(t) else { return false }
            return saved.isSaved(key)
        }
        if queue.tracks.isEmpty {
            toasts.show("Нет интернета. Без него играют только сохранённые треки")
            return
        }
        if queue.skipped > 0 { toasts.show(QueueFilter.skippedText(queue.skipped)) }
        player.play(queue.tracks, at: queue.startIndex)
    }

    public func playSaved(_ entries: [ManifestEntry], at index: Int) {
        play(entries.map { $0.toTrack() }, at: index)
    }

    // ---------- прочее ----------

    public func openStorageSettings() {
        if !platform.openStorageSettings() {
            toasts.show("Освободите место в настройках телефона и нажмите «Повторить»")
        }
    }

    /// Страница Blink+ в приложении: тарифы, промокод, поддержка.
    public func openPlus() {
        nav.open(.plus)
    }

    /// Открыть ссылку (оплата, сайт) в браузере.
    public func openURL(_ url: URL) {
        platform.open(url)
    }
}
