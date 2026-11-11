import XCTest
@testable import BlinkCore

final class FakePlayer: PlayerControl, @unchecked Sendable {
    let plays = Log<String>()

    func play(_ tracks: [Track], at index: Int) {
        plays.add(tracks.map { $0.id }.joined(separator: ",") + "|" + String(index))
    }
}

final class FakePlatform: PlatformActions, @unchecked Sendable {
    let opened = Log<String>()
    let storageOpens = Box<Int>(0)
    let canOpenStorage = Box<Bool>(true)

    func open(_ url: URL) {
        opened.add(url.absoluteString)
    }

    func openStorageSettings() -> Bool {
        storageOpens.value += 1
        return canOpenStorage.value
    }
}

/// Действия по нажатиям вместе с настоящими менеджером очереди, входом и подпиской; сеть и сервер в памяти.
final class ActionsTests: XCTestCase {
    private var backend: FakeBackend!
    private var dir: URL!
    private var network: StaticNetwork!
    private var made: [OfflineManager] = []

    override func setUp() {
        super.setUp()
        backend = FakeBackend()
        dir = tempDir()
        network = StaticNetwork(true)
        made = []
    }

    override func tearDown() {
        for m in made { m.pause() }
        made = []
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private struct Rig {
        let actions: Actions
        let offline: OfflineManager
        let auth: SupabaseAuth
        let plus: PlusTracker
        let nav: Nav
        let seen: Log<Toast>
        let player: FakePlayer
        let platform: FakePlatform
        let plusAsked: Box<Int>
        let plusStatus: Box<PlusStatus?>
        let clock: Box<Int64>
    }

    private func rig(signedIn: Bool = true, plusActive: Bool = true) async -> Rig {
        let config = BlinkConfig(baseURL: backend.base, supabaseURL: backend.base, supabaseAnonKey: "anon")
        let store = MemSessionStore()
        let clock = Box<Int64>(Int64(Date().timeIntervalSince1970 * 1000))
        let auth = SupabaseAuth(http: backend, config: config, store: store, now: { clock.value })
        if signedIn {
            let session = AuthSession(accessToken: "tok", refreshToken: "ref", expiresAtMs: clock.value + 3_600_000, userId: "u1", email: "a@b.c")
            store.save(BlinkJSON.encode(session))
            auth.restore()
        }
        let plusAsked = Box<Int>(0)
        let plusStatus = Box<PlusStatus?>(PlusStatus(active: plusActive, untilMs: plusActive ? clock.value + 30 * 86_400_000 : nil))
        let plus = PlusTracker(
            fetch: {
                plusAsked.value += 1
                return plusStatus.value
            },
            store: MemoryKeyValue(),
            now: { clock.value }
        )
        if plusActive { _ = await plus.refresh() }
        plusAsked.value = 0

        let storage = FileStorage(root: dir)
        let dl = Downloader(storage: storage, resolver: backend.resolver(), transport: backend, network: network)
        let offline = OfflineManager(
            storage: storage,
            downloader: dl,
            network: network,
            config: OfflineManager.Config(retryDelaysMs: [20, 20, 20, 20], jitter: 0)
        )
        made.append(offline)
        await offline.start()

        let toasts = Toasts()
        let seen = Log<Toast>()
        toasts.observe { seen.add($0) }
        let nav = Nav()
        let player = FakePlayer()
        let platform = FakePlatform()
        let actions = Actions(
            auth: auth,
            plus: plus,
            offline: offline,
            network: network,
            toasts: toasts,
            nav: nav,
            player: player,
            config: config,
            platform: platform,
            now: { clock.value }
        )
        return Rig(
            actions: actions, offline: offline, auth: auth, plus: plus, nav: nav, seen: seen,
            player: player, platform: platform, plusAsked: plusAsked, plusStatus: plusStatus, clock: clock
        )
    }

    /// Трек каталога Blink: его можно сохранить.
    private func blink(_ id: String, offline: Bool? = true) -> Track {
        return Track(id: "b:" + id, title: "T" + id, artist: "A", duration: 60, source: "blink", lic: id, offline: offline)
    }

    private func toast(_ r: Rig, _ n: Int = 1) async -> Toast? {
        await waitUntil(10, "тост") { r.seen.count >= n }
        return r.seen.items.count >= n ? r.seen.items[n - 1] : nil
    }

    // ---------- сохранить ----------

    func testSavingSignedOutExplainsAndOffersSignIn() async throws {
        let r = await rig(signedIn: false)
        backend.add("a", 400_000)
        await r.actions.saveNow([blink("a")])
        let t = await toast(r)
        XCTAssertEqual(t?.message, "Войдите в аккаунт")
        XCTAssertEqual(t?.action, "Войти")
        XCTAssertTrue(r.offline.state.jobs.isEmpty)
        t?.onAction?()
        XCTAssertEqual(r.nav.current.tab, .account)
    }

    func testSavingWithoutPlusAsksTheServerAgainThenOffersBlinkPlus() async throws {
        let r = await rig(plusActive: false)
        backend.add("a", 400_000)
        await r.actions.saveNow([blink("a")])
        let t = await toast(r)
        XCTAssertEqual(r.plusAsked.value, 1, "перед отказом спросили сервер: подписку могли оформить на сайте")
        XCTAssertEqual(t?.message, "Сохранение для офлайна доступно с Blink+")
        XCTAssertEqual(t?.action, "Открыть Blink+")
        XCTAssertTrue(r.offline.state.jobs.isEmpty)
        t?.onAction?()
        XCTAssertEqual(r.platform.opened.items, [backend.base])
    }

    func testPlusBoughtOnTheSiteIsPickedUpBeforeRefusing() async throws {
        let r = await rig(plusActive: false)
        backend.add("a", 400_000)
        r.plusStatus.value = PlusStatus(active: true, untilMs: r.clock.value + 86_400_000)
        await r.actions.saveNow([blink("a")])
        await waitUntil(15, "сохранён") { r.offline.state.saved.count == 1 }
        XCTAssertTrue(r.seen.items.isEmpty, "отказа не было")
    }

    func testSavingWithPlusQueuesTheTrackAndItGetsSaved() async throws {
        let r = await rig()
        let f = backend.add("a", 400_000)
        await r.actions.saveNow([blink("a")])
        await waitUntil(15, "сохранён") { r.offline.state.saved.count == 1 }
        XCTAssertEqual(r.offline.state.saved.first?.id, "a")
        XCTAssertEqual(r.offline.audioPath(Key.of("blink", "a")).flatMap { FileManager.default.contents(atPath: $0) }.map { [UInt8]($0) }, f.bytes)
        XCTAssertTrue(r.seen.items.isEmpty)
    }

    func testAnAlreadySavedTrackSaysSo() async throws {
        let r = await rig()
        backend.add("a", 400_000)
        await r.actions.saveNow([blink("a")])
        await waitUntil(15, "сохранён") { r.offline.state.saved.count == 1 }
        await r.actions.saveNow([blink("a")])
        let t = await toast(r)
        XCTAssertEqual(t?.message, "Уже сохранён")
    }

    func testTracksFromOtherSourcesExplainOnlineOnly() async throws {
        let r = await rig()
        let itunes = Track(id: "123", title: "x", artist: "y", source: "itunes")
        await r.actions.saveNow([itunes])
        let t = await toast(r)
        XCTAssertEqual(t?.message, "Этот трек играет только онлайн")
        XCTAssertNil(t?.action)

        r.actions.explainOnlineOnly(blink("zz", offline: false))
        let t2 = await toast(r, 2)
        XCTAssertEqual(t2?.message, "Артист не разрешил сохранять этот трек")
    }

    func testABatchAsksSignInRatherThanOnlineOnly() async throws {
        let r = await rig(signedIn: false)
        let itunes = Track(id: "123", title: "x", artist: "y", source: "itunes")
        await r.actions.saveNow([itunes, blink("a")])
        let t = await toast(r)
        XCTAssertEqual(t?.message, "Войдите в аккаунт")
    }

    func testABatchSavesOnlyWhatIsAllowedWithoutAToast() async throws {
        let r = await rig()
        backend.add("a", 400_000)
        backend.add("b", 400_000)
        let itunes = Track(id: "123", title: "x", artist: "y", source: "itunes")
        await r.actions.saveNow([blink("a"), itunes, blink("b")])
        await waitUntil(15, "оба сохранены") { r.offline.state.saved.count == 2 }
        XCTAssertTrue(r.seen.items.isEmpty)
    }

    func testTappingTheSaveIconDependsOnWhatIsGoingOn() async throws {
        let r = await rig()
        backend.add("a", 3_000_000)
        backend.throttleChunk = 100_000
        let track = blink("a")
        r.actions.saveTapped(track) // доступен: ставит в очередь
        await waitUntil(15, "в очереди") { r.offline.state.job(Key.of("blink", "a")) != nil }
        r.actions.saveTapped(track) // качается: предлагает отменить
        let t = await toast(r)
        XCTAssertEqual(t?.message, "Сохраняется")
        XCTAssertEqual(t?.action, "Отменить")
        t?.onAction?()
        await waitUntil(15, "отменено") { r.offline.state.jobs.isEmpty }
    }

    // ---------- причины отказа ----------

    func testExplainPicksTheRightButton() async throws {
        let r = await rig()
        r.actions.explain(.noSpace, nil, "k")
        let t1 = await toast(r)
        XCTAssertEqual(t1?.action, "Освободить место")
        t1?.onAction?()
        XCTAssertEqual(r.platform.storageOpens.value, 1)

        r.platform.canOpenStorage.value = false
        t1?.onAction?()
        let t2 = await toast(r, 2)
        XCTAssertEqual(t2?.message, "Освободите место в настройках телефона и нажмите «Повторить»")

        r.actions.explain(.sourceError, nil, nil)
        let t3 = await toast(r, 3)
        XCTAssertEqual(t3?.message, "Сервер сейчас не отвечает")
        XCTAssertNil(t3?.action, "повторять без ключа нечего")

        r.actions.explain(.sourceError, nil, "k")
        let t4 = await toast(r, 4)
        XCTAssertEqual(t4?.action, "Повторить")
    }

    // ---------- играть ----------

    func testOnlinePlayGoesStraightToThePlayer() async throws {
        let r = await rig()
        let list = [Track(id: "1", title: "a", artist: "x"), Track(id: "2", title: "b", artist: "x")]
        r.actions.play(list, at: 1)
        XCTAssertEqual(r.player.plays.items, ["1,2|1"])
        r.actions.play(list, at: 99)
        XCTAssertEqual(r.player.plays.items.last, "1,2|1", "индекс прижимается к концу списка")
        r.actions.play([], at: 0)
        XCTAssertEqual(r.player.plays.count, 2)
    }

    func testOfflineWithoutPlusExplains() async throws {
        let r = await rig(plusActive: false)
        network.set(false)
        r.actions.play([blink("a")], at: 0)
        let t = await toast(r)
        XCTAssertEqual(t?.message, "Без интернета сохранённые играют с Blink+")
        XCTAssertEqual(t?.action, "Открыть Blink+")
        XCTAssertTrue(r.player.plays.items.isEmpty)
    }

    func testOfflinePlayKeepsOnlySavedTracksAndSaysHowManyWereSkipped() async throws {
        let r = await rig()
        backend.add("y", 400_000)
        await r.actions.saveNow([blink("y")])
        await waitUntil(15, "сохранён") { r.offline.state.saved.count == 1 }

        network.set(false)
        let x = Track(id: "x", title: "x", artist: "a")
        let z = Track(id: "z", title: "z", artist: "a")
        r.actions.play([x, blink("y"), z], at: 0)
        XCTAssertEqual(r.player.plays.items, ["b:y|0"])
        let t = await toast(r)
        XCTAssertEqual(t?.message, "Пропущено 2 трека: нужен интернет")
    }

    func testOfflineWithNothingSavedSaysSo() async throws {
        let r = await rig()
        network.set(false)
        r.actions.play([Track(id: "x", title: "x", artist: "a")], at: 0)
        let t = await toast(r)
        XCTAssertEqual(t?.message, "Нет интернета. Без него играют только сохранённые треки")
        XCTAssertTrue(r.player.plays.items.isEmpty)
    }

    func testPlaySavedUsesTheStoredTrackObjects() async throws {
        let r = await rig()
        let entry = ManifestEntry(key: Key.of("blink", "a"), source: "blink", id: "a", title: "Alpha", artist: "A", bytes: 1, savedAt: 1)
        r.actions.playSaved([entry], at: 0)
        XCTAssertEqual(r.player.plays.items, ["b:a|0"])
    }

    func testOpeningBlinkPlusOpensTheSite() async throws {
        let r = await rig()
        r.actions.openPlus()
        XCTAssertEqual(r.platform.opened.items, [backend.base])
    }
}
