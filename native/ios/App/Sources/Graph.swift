import SwiftUI
import UIKit
import BlinkCore

/// Держит `Actions` слабой ссылкой: плеер и действия знают друг друга, и без этого их не собрать по порядку.
private final class Late<T: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: T?

    func set(_ value: T) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Всё, что живёт, пока жив процесс: сеть, вход, офлайн-менеджер, плеер. Собрано руками, как `Graph` на Android:
/// объектов немного, а порядок создания виден в одном месте.
final class Graph: ObservableObject {
    static let baseURL = "https://blinkmusic.cc"

    /// «0.1.0 (5)»: версия и номер сборки из Info.plist.
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return version + " (" + build + ")"
    }

    let config: BlinkConfig
    let toasts = Toasts()
    let nav = Nav()
    let network = PathNetworkMonitor()
    let auth: SupabaseAuth
    let api: BlinkApi
    let plus: PlusTracker
    let offline: OfflineManager
    let search: SearchModel
    let player: PlayerController
    let actions: Actions
    private let nowPlaying: NowPlayingBridge

    let navStore: NavStore
    let playerStore: PlayerStore
    let offlineStore: OfflineStore
    let searchStore: SearchStore
    let authStore: AuthStore
    let plusStore: PlusStore
    let onlineStore: OnlineStore
    let currentIdStore: CurrentIdStore
    let hasTrackStore: HasTrackStore
    let downloadingStore: DownloadingStore
    let toastCenter: ToastCenter

    private let lock = NSLock()
    private var started = false
    private var seenUser = false
    private var lastUserId: String?
    private var tokens: [NetworkObservation] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        // Ключ входа публичный, но в репозиторий не кладётся: он приходит при сборке (BLINK_SUPABASE_ANON_KEY).
        let key = Bundle.main.object(forInfoDictionaryKey: "BlinkSupabaseAnonKey") as? String ?? ""
        let config = BlinkConfig(baseURL: Graph.baseURL, supabaseAnonKey: key.trimmingCharacters(in: .whitespaces))
        let agent = "Blink-iOS/" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
        let http = URLSessionHTTP(userAgent: agent)
        let transport = URLSessionTransport(userAgent: agent)
        let toasts = self.toasts
        let nav = self.nav
        let network = self.network

        let auth = SupabaseAuth(http: http, config: config, store: KeychainSessionStore())
        let api = BlinkApi(http: http, config: config, tokens: auth)
        let plus = PlusTracker(fetch: { try await api.plus() }, store: DefaultsKeyValue())

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var offlineRoot = support.appendingPathComponent("offline", isDirectory: true)
        // Сохранённые треки можно скачать заново, поэтому в резервную копию iCloud они не идут (так просит Apple).
        try? FileManager.default.createDirectory(at: offlineRoot, withIntermediateDirectories: true)
        var noBackup = URLResourceValues()
        noBackup.isExcludedFromBackup = true
        try? offlineRoot.setResourceValues(noBackup)
        let storage = FileStorage(root: offlineRoot)
        let resolver = ServerResolver(http: http, config: config, tokens: auth)
        let downloader = Downloader(storage: storage, resolver: resolver, transport: transport, network: network)
        let offline = OfflineManager(storage: storage, downloader: downloader, network: network)

        let search = SearchModel(
            search: { try await api.search($0) },
            newest: { try await api.latestLicensed(limit: 12) },
            chart: { try await api.chart(limit: 30) }
        )

        let late = Late<Actions>()
        let engine = AVPlayerEngine()
        let sources = PlaybackResolver(saved: offline, streams: api, plus: plus, network: network)
        let player = PlayerController(
            engine: engine,
            source: sources,
            saved: offline,
            toasts: toasts,
            nav: nav,
            openPlus: { late.get()?.openPlus() }
        )
        let actions = Actions(
            auth: auth,
            plus: plus,
            offline: offline,
            network: network,
            toasts: toasts,
            nav: nav,
            player: player,
            config: config,
            platform: IOSPlatformActions()
        )
        late.set(actions)

        self.config = config
        self.auth = auth
        self.api = api
        self.plus = plus
        self.offline = offline
        self.search = search
        self.player = player
        self.actions = actions
        self.nowPlaying = NowPlayingBridge(player: player)

        self.navStore = NavStore(nav.current) { nav.observe($0) }
        self.playerStore = PlayerStore(player.current) { player.observe($0) }
        self.offlineStore = OfflineStore(offline.state) { offline.observe($0) }
        self.searchStore = SearchStore(search.current) { search.observe($0) }
        self.authStore = AuthStore(auth.session) { auth.observe($0) }
        self.plusStore = PlusStore(plus.info) { plus.observe($0) }
        self.onlineStore = OnlineStore(network.isOnline) { network.observe($0) }
        self.currentIdStore = CurrentIdStore(player.current.track?.id) { handler in
            player.observe { handler($0.track?.id) }
        }
        self.hasTrackStore = HasTrackStore(player.current.track != nil) { handler in
            player.observe { handler($0.track != nil) }
        }
        self.downloadingStore = DownloadingStore(offline.state.active) { handler in
            offline.observe { handler($0.active) }
        }
        self.toastCenter = ToastCenter(toasts)
    }

    /// Запускается один раз при открытии приложения.
    func start() {
        lock.lock()
        let first = !started
        started = true
        lock.unlock()
        if !first { return }

        // Сначала сессия, потом подписка: иначе стартовое «не вошёл» стёрло бы сохранённую дату Blink+.
        auth.restore()
        tokens.append(auth.observe { [weak self] session in
            self?.sessionChanged(session?.userId)
        })

        let offline = self.offline
        let toasts = self.toasts
        Task { await offline.start() }
        tokens.append(offline.observeEvents { event in
            switch event {
            case .batchDone(_, _, let failures):
                let failed = !failures.isEmpty
                toasts.show(BatchSummary.text(event), action: failed ? "Повторить" : nil) { offline.retryAll() }
            }
        })
        tokens.append(offline.observe { [weak self] state in
            self?.downloadsChanged(active: state.active)
        })

        // Домашняя страница грузится при появлении сети, если в первый раз не вышло.
        let search = self.search
        tokens.append(network.observe { online in
            let current = search.current
            if online && current.newest.isEmpty && current.chart.isEmpty { search.refreshHome() }
        })
        search.refreshHome()
        LaunchHooks.run(search: search, actions: actions, nav: nav)
    }

    private func sessionChanged(_ userId: String?) {
        lock.lock()
        let same = seenUser && lastUserId == userId
        seenUser = true
        lastUserId = userId
        lock.unlock()
        if same { return }
        if userId == nil {
            plus.clear()
        } else {
            let plus = self.plus
            Task { _ = await plus.refresh() }
        }
    }

    /// Пока что-то качается, просим у системы время на работу в фоне (около 30 секунд после сворачивания).
    private func downloadsChanged(active: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if active {
                if self.backgroundTask == .invalid {
                    self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "blink-downloads") { [weak self] in
                        self?.endBackgroundTask()
                    }
                }
            } else {
                self.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
