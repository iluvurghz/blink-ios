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
    let flash: FlashController
    let room: RoomSession
    let friends: FriendsModel
    let plusApi: PlusApi
    private let presence: PresenceBeat
    let roomStore: RoomStore
    let friendsStore: FriendsStore
    private let library: LibraryStore
    private let librarySync: LibrarySync
    private let webAuth = WebAuth()
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
    private var pushWork: DispatchWorkItem?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lastLocal: LocalPlayback?
    private var timer: Timer?

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

        // Вспышка и лайки: состояние на устройстве, лайки и история синхронизируются с аккаунтом.
        let library = LibraryStore(FileBlob(name: "library.json"))
        let settings = WaveSettingsBox()
        let waveEngine = WaveEngine(
            source: WaveApi(http: http, config: config),
            store: WaveStore(FileBlob(name: "wave.json")),
            library: library,
            settings: { settings.value }
        )
        self.library = library
        self.librarySync = LibrarySync(http: http, config: config, tokens: auth, library: library, userId: { auth.session?.userId })
        self.flash = FlashController(
            engine: waveEngine,
            library: library,
            player: player,
            actions: actions,
            api: api,
            toasts: toasts,
            network: network,
            settings: settings
        )

        // Социальное: комната «Слушать вместе», друзья, страница Blink+.
        let streamer = URLSessionEventStreamer(userAgent: agent)
        let roomService = RoomApi(http: http, config: config, tokens: auth, streamer: streamer)
        let room = RoomSession(
            service: roomService,
            port: PlayerRoomPort(player: player),
            userId: { auth.session?.userId },
            say: { toasts.show($0) },
            onChat: { chat in
                // Сообщения других, пока окно комнаты закрыто, показываем всплывашкой.
                if nav.current.overlay != .room { toasts.show(chat.name + ": " + chat.text) }
            }
        )
        let friends = FriendsModel(service: FriendsApi(http: http, config: config, tokens: auth), say: { toasts.show($0) })
        self.room = room
        self.friends = friends
        self.plusApi = PlusApi(http: http, config: config, tokens: auth, cache: DefaultsKeyValue())
        self.presence = PresenceBeat(http: http, config: config, store: DefaultsKeyValue())
        self.roomStore = RoomStore(room.room) { room.observe($0) }
        self.friendsStore = FriendsStore(friends.current) { friends.observe($0) }

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
        // Плеер сменил трек или состояние: сообщаем комнате (если это не мы его подогнали) и друзьям.
        tokens.append(player.observe { [weak self] ui in self?.playerChanged(ui) })
        tokens.append(room.observe { [weak self] r in self?.roomChanged(r?.code) })
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Раз в 45 секунд: «я здесь» для счётчика онлайна и повтор «слушаю» (сервер забывает через 90).
            self.timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in self?.heartbeat() }
            self.heartbeat()
        }
        flash.attach()
        tokens.append(library.observe { [weak self] _ in self?.libraryChanged() })
        search.refreshHome()
        LaunchHooks.run(search: search, actions: actions, nav: nav, player: player)
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
            room.leave()
            friends.clear()
        } else {
            let friends = self.friends
            Task { await friends.refresh() }
            let plus = self.plus
            let sync = librarySync
            Task {
                _ = await plus.refresh()
                _ = await sync.pull()
            }
        }
    }

    private func playerChanged(_ ui: PlayerUi) {
        let snap = LocalPlayback(track: ui.track, playing: ui.playing, positionMs: ui.positionMs, loading: ui.buffering)
        lock.lock()
        let prev = lastLocal
        let same = prev?.trackId == snap.trackId && prev?.playing == snap.playing && prev?.loading == snap.loading
        if !same { lastLocal = snap }
        lock.unlock()
        if same { return }
        room.onLocal(snap)
        if auth.session != nil { friends.report(playing: snap.playing, track: snap.track, room: room.room?.code) }
    }

    private func roomChanged(_ code: String?) {
        let ui = player.current
        if auth.session != nil { friends.report(playing: ui.playing, track: ui.track, room: code) }
    }

    private func heartbeat() {
        let ui = player.current
        presence.beat(playing: ui.playing, track: ui.track)
        if ui.playing && auth.session != nil { friends.report(playing: true, track: ui.track, room: room.room?.code, force: true) }
    }

    /// Ссылки: приглашение в комнату или к другу (открыли по blink:// или вставили).
    func handleLink(_ url: String) {
        if url.hasPrefix("blink://auth") { finishSignIn(url); return }
        if let code = RoomSession.codeFrom(url) {
            if auth.session == nil {
                toasts.show("Войдите, чтобы слушать вместе")
                nav.go(.account)
            } else {
                room.join(code)
                nav.open(.room)
            }
            return
        }
        if let code = FriendsApi.codeFrom(url) {
            nav.open(.friends)
            let friends = self.friends
            Task { await friends.accept(code) }
        }
    }

    /// Лайки меняются пачками: отправляем на сервер через три секунды после последнего изменения.
    private func libraryChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pushWork?.cancel()
            let sync = self.librarySync
            let work = DispatchWorkItem { Task { _ = await sync.push() } }
            self.pushWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    /// Вход через сайт: Google или Telegram в окне браузера, потом возврат по blink://auth.
    func signIn(with provider: AuthLink.Provider) {
        guard let url = URL(string: AuthLink.startURL(base: config.base, provider: provider)) else { return }
        webAuth.start(url) { [weak self] callback in
            guard let self = self, let callback = callback else { return }
            self.finishSignIn(callback)
        }
    }

    private func finishSignIn(_ url: String) {
        guard let link = AuthLink.parse(url) else { return }
        let auth = self.auth
        let toasts = self.toasts
        Task {
            do {
                _ = try await auth.finish(link)
                toasts.show("Вы вошли")
            } catch let failure as AuthException {
                toasts.show(failure.message)
            } catch {
                toasts.show("Вход не получился, попробуйте ещё раз")
            }
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
