package app.blink.player

import app.blink.core.model.Track
import app.blink.core.net.AuthSession
import app.blink.core.net.BlinkConfig
import app.blink.core.net.KeyValue
import app.blink.core.net.PlusStatus
import app.blink.core.net.PlusTracker
import app.blink.core.net.SessionStore
import app.blink.core.net.SupabaseAuth
import app.blink.core.offline.ManifestEntry
import app.blink.core.offline.OfflineCode
import app.blink.core.offline.OfflineState
import app.blink.core.offline.StaticNetwork
import app.blink.core.offline.Usage
import app.blink.core.search.SearchModel
import app.blink.player.data.Toasts
import app.blink.player.playback.PlayerUi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import okhttp3.OkHttpClient

// Заглушки вместо Android-кода приложения. Названия и сигнатуры те же, что у настоящих классов, поэтому
// файлы экранов собираются без изменений.

object BuildConfig {
    const val VERSION_NAME = "0.1.0"
    const val VERSION_CODE = 1
    const val BUILD_TYPE = "preview"
}

class MemoryKeyValue : KeyValue {
    private val map = HashMap<String, String>()
    override fun get(key: String): String? = map[key]
    override fun put(key: String, value: String?) {
        if (value == null) map.remove(key) else map[key] = value
    }
}

class FakeOffline {
    val flow = MutableStateFlow(OfflineState(ready = true))
    val state: StateFlow<OfflineState> = flow.asStateFlow()
    var freeBytes: Long = 14L * 1024 * 1024 * 1024
    fun usage(): Usage = Usage(flow.value.usedBytes, freeBytes)
    fun pause() { flow.value = flow.value.copy(paused = true) }
    fun resume() { flow.value = flow.value.copy(paused = false) }
    fun retryAll() {}
    fun clearAll() {}
    fun isSaved(key: String): Boolean = key in flow.value.savedKeys
}

class FakePlayer {
    val flow = MutableStateFlow(PlayerUi())
    val state: StateFlow<PlayerUi> = flow.asStateFlow()
    fun play(tracks: List<Track>, index: Int) { flow.value = PlayerUi(track = tracks[index], playing = true, durationMs = tracks[index].duration * 1000L, hasNext = index < tracks.lastIndex, connected = true) }
    fun toggle() { flow.value = flow.value.copy(playing = !flow.value.playing) }
    fun seekTo(positionMs: Long) { flow.value = flow.value.copy(positionMs = positionMs) }
    fun next() {}
    fun previous() {}
}

class Actions(@Suppress("unused") private val g: Graph) {
    val log = ArrayList<String>()
    fun save(track: Track) { log += "save ${track.id}" }
    fun saveAll(tracks: List<Track>) { log += "saveAll ${tracks.size}" }
    fun explain(code: OfflineCode, reason: String?, key: String?) { log += "explain $code/$reason/$key" }
    fun explainOnlineOnly(track: Track) { log += "onlineOnly ${track.id}" }
    fun removeSaved(key: String) { log += "remove $key" }
    fun retry(key: String) { log += "retry $key" }
    fun cancel(key: String) { log += "cancel $key" }
    fun play(tracks: List<Track>, index: Int) { log += "play ${tracks[index].id}" }
    fun playSaved(entries: List<ManifestEntry>, index: Int) { log += "playSaved ${entries[index].key}" }
    fun openPlus() { log += "openPlus" }
    fun openStorageSettings() { log += "storage" }
}

class MemorySessionStore(var value: String? = null) : SessionStore {
    override fun load(): String? = value
    override fun save(value: String?) { this.value = value }
}

class Graph(
    signedIn: Boolean = true,
    plusUntilMs: Long? = null,
    val search: SearchModel = SearchModel(CoroutineScope(SupervisorJob() + Dispatchers.Unconfined), { emptyList() }, { emptyList() }, { emptyList() }),
) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    val config = BlinkConfig(supabaseAnonKey = "preview")
    val toasts = Toasts()
    val nav = Nav()
    val network = StaticNetwork(true)
    val offline = FakeOffline()
    val player = FakePlayer()
    val actions = Actions(this)
    private val store = MemorySessionStore(
        if (signedIn) app.blink.core.net.BlinkJson.encodeToString(AuthSession.serializer(), AuthSession("a", "r", Long.MAX_VALUE, "u1", "ayo@blinkmusic.cc", "Ayo")) else null,
    )
    val auth = SupabaseAuth(OkHttpClient(), config, store).also { it.restore() }
    val plus = PlusTracker({ plusUntilMs?.let { PlusStatus(true, it) } ?: PlusStatus(false, null) }, MemoryKeyValue())
}
