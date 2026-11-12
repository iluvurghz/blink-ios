package app.blink.player

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import app.blink.core.net.AuthLink
import app.blink.core.net.AuthException
import app.blink.core.net.BlinkApi
import app.blink.core.net.BlinkConfig
import app.blink.core.net.PlusTracker
import app.blink.core.net.SupabaseAuth
import app.blink.core.offline.BatchSummary
import app.blink.core.offline.Downloader
import app.blink.core.offline.FileStorage
import app.blink.core.offline.OfflineEvent
import app.blink.core.offline.OfflineManager
import app.blink.core.offline.ServerResolver
import app.blink.core.search.SearchModel
import app.blink.core.social.FriendsApi
import app.blink.core.social.FriendsModel
import app.blink.core.social.LocalPlayback
import app.blink.core.social.PlusApi
import app.blink.core.social.PresenceBeat
import app.blink.core.social.RoomApi
import app.blink.core.social.RoomSession
import app.blink.player.playback.RoomPort
import kotlinx.coroutines.delay
import app.blink.core.wave.LibraryStore
import app.blink.core.library.DeepLink
import app.blink.core.library.SharedApi
import app.blink.core.library.SharedTrack
import app.blink.core.model.Track
import app.blink.core.wave.LibrarySync
import app.blink.core.wave.WaveApi
import app.blink.core.wave.WaveEngine
import app.blink.core.wave.WaveMode
import app.blink.core.wave.WaveSettings
import app.blink.core.wave.WaveStore
import app.blink.player.data.PrefsBlob
import app.blink.player.flash.FlashController
import app.blink.player.data.AndroidNetwork
import app.blink.player.data.PrefsKeyValue
import app.blink.player.data.SecureSessionStore
import app.blink.player.data.Toasts
import app.blink.player.offline.DownloadService
import app.blink.player.playback.PlayerController
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import okhttp3.Dispatcher
import okhttp3.Interceptor
import okhttp3.OkHttpClient

/**
 * Всё, что живёт, пока жив процесс: сеть, вход, офлайн-менеджер, плеер. Собрано руками без DI-библиотек:
 * объектов немного, а порядок создания виден в одном месте.
 */
class Graph(val app: Application) {
    val prefs: SharedPreferences = app.getSharedPreferences("blink", Context.MODE_PRIVATE)
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val config = BlinkConfig(baseUrl = BuildConfig.BASE_URL, supabaseAnonKey = BuildConfig.SUPABASE_ANON_KEY)

    val http: OkHttpClient = OkHttpClient.Builder()
        .dispatcher(Dispatcher().apply { maxRequestsPerHost = 16 })
        .addInterceptor(
            Interceptor { chain ->
                chain.proceed(chain.request().newBuilder().header("User-Agent", "Blink-Android/${BuildConfig.VERSION_NAME}").build())
            },
        )
        .build()

    val toasts = Toasts()
    val nav = Nav()
    val network = AndroidNetwork(app)

    val auth = SupabaseAuth(http, config, SecureSessionStore(prefs))
    val api = BlinkApi(http, config, auth)
    val plus = PlusTracker({ api.plus() }, PrefsKeyValue(prefs))

    private val storage = FileStorage(File(app.filesDir, "offline"))
    val offline = OfflineManager(storage, Downloader(storage, ServerResolver(http, config, auth), http, network), network, scope)

    val search = SearchModel(scope, { q -> api.search(q) }, { api.latestLicensed(12) }, { api.chart(30) })
    val player = PlayerController(app, scope)
    val actions = Actions(this)

    // Социальное: комната «Слушать вместе», друзья, страница Blink+.
    val room = RoomSession(RoomApi(http, config, auth), scope, RoomPort(player), { auth.session.value?.userId }, { toasts.show(it) })
    val friends = FriendsModel(FriendsApi(http, config, auth), scope) { toasts.show(it) }
    val plusApi = PlusApi(http, config, auth, PrefsKeyValue(prefs))
    val shared = SharedApi(http, config, auth, { auth.session.value?.userId }, { auth.session.value?.name ?: auth.session.value?.email })
    /** Трек, для которого сейчас выбирают плейлист (окно «В плейлист»). */
    val pickTrack = kotlinx.coroutines.flow.MutableStateFlow<Track?>(null)
    private val presence = PresenceBeat(http, config, PrefsKeyValue(prefs), scope)

    // Вспышка и лайки: состояние на устройстве, лайки и история синхронизируются с аккаунтом.
    val library = LibraryStore(PrefsBlob(prefs, "library"))
    private val librarySync = LibrarySync(http, config, auth, library, { auth.session.value?.userId })
    private val waveSettings = MutableStateFlow(
        WaveSettings(mode = WaveMode.of(prefs.getString("wave_mode", null)), explore = prefs.getBoolean("wave_explore", true)),
    )
    private val waveEngine = WaveEngine(WaveApi(http, config), WaveStore(PrefsBlob(prefs, "wave")), library, { waveSettings.value })
    val flash = FlashController(this, waveEngine, library, waveSettings)

    /** Открыли ссылку на трек (`/t/<код>`, `/t/<id>`): узнаём, что это, и включаем. */
    suspend fun openSharedTrack(link: DeepLink.Track) {
        val ref = link.ref
        val track: Track? = try {
            when {
                SharedApi.SHORT.matches(ref) -> shared.resolveTrack(ref)?.toTrack()
                ref.matches(Regex("^\\d{1,15}$")) -> api.lookup(ref)
                link.title.isNotEmpty() -> SharedTrack(ref, link.title, link.artist, "").toTrack()
                ref.startsWith("b:") -> api.search(ref.removePrefix("b:")).firstOrNull()
                else -> null
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }
        if (track == null) toasts.show("Не получилось открыть трек по ссылке") else actions.play(listOf(track), 0)
    }

    /** Вернулись из браузера по blink://auth: заканчиваем вход Google или Telegram. */
    fun finishSignIn(url: String?) {
        val link = AuthLink.parse(url) ?: return
        scope.launch {
            try {
                auth.finish(link)
                toasts.show("Вы вошли")
            } catch (e: AuthException) {
                toasts.show(e.message ?: "Вход не получился")
            } catch (_: Exception) {
                toasts.show("Вход не получился, попробуйте ещё раз")
            }
        }
    }

    @OptIn(FlowPreview::class)
    fun start() {
        scope.launch(Dispatchers.IO) {
            // Сначала сессия, потом подписка: иначе стартовое «не вошёл» стёрло бы сохранённую дату Blink+.
            auth.restore()
            launch {
                auth.session.map { it?.userId }.distinctUntilChanged().collect { userId ->
                    if (userId == null) plus.clear() else plus.refresh()
                }
            }
            launch {
                auth.session.map { it?.userId }.distinctUntilChanged().collect { userId ->
                    if (userId != null) librarySync.pull()
                }
            }
            launch {
                library.state.debounce(3_000).collect { librarySync.push() }
            }
            launch {
                waveSettings.collect { prefs.edit().putString("wave_mode", it.mode.id).putBoolean("wave_explore", it.explore).apply() }
            }
            flash.attach()
            offline.start()
        }
        // Вошли: тянем друзей. Вышли: уходим из комнаты и чистим список.
        scope.launch {
            auth.session.map { it?.userId }.distinctUntilChanged().collect { userId ->
                if (userId == null) {
                    room.leave()
                    friends.clear()
                } else {
                    friends.refresh()
                }
            }
        }
        // Плеер сменил трек или состояние: сообщаем комнате (если это не мы его подогнали) и друзьям.
        scope.launch {
            player.state
                .map { LocalPlayback(it.track, it.playing, it.positionMs, it.buffering) }
                .distinctUntilChanged { a, b -> a.trackId == b.trackId && a.playing == b.playing && a.loading == b.loading }
                .collect { snap ->
                    room.onLocal(snap)
                    if (auth.session.value != null) friends.report(snap.playing, snap.track, room.room.value?.code)
                }
        }
        scope.launch {
            room.room.map { it?.code }.distinctUntilChanged().collect {
                val ui = player.state.value
                if (auth.session.value != null) friends.report(ui.playing, ui.track, it)
            }
        }
        friends.keepAlive {
            val ui = player.state.value
            Triple(ui.playing && auth.session.value != null, ui.track, room.room.value?.code)
        }
        // «Я здесь» для счётчика онлайна в админке.
        scope.launch {
            while (true) {
                val ui = player.state.value
                presence.beat(ui.playing, ui.track)
                delay(45_000)
            }
        }
        scope.launch {
            offline.events.collect { e ->
                if (e is OfflineEvent.BatchDone) {
                    val failed = e.failures.isNotEmpty()
                    toasts.show(BatchSummary.text(e), if (failed) "Повторить" else null) { offline.retryAll() }
                }
            }
        }
        // Пока есть что качать, держим сервис с уведомлением: система не убьёт процесс на экране блокировки.
        scope.launch {
            offline.state.map { it.active }.distinctUntilChanged().collect { active ->
                if (active) DownloadService.start(app)
            }
        }
        // Домашняя страница грузится при появлении сети, если в первый раз не вышло.
        scope.launch {
            network.online.collect { online ->
                val s = search.state.value
                if (online && s.newest.isEmpty() && s.chart.isEmpty()) search.refreshHome()
            }
        }
    }
}
