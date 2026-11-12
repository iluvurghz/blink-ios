package preview

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import app.blink.core.model.Track
import app.blink.core.net.BlinkJson
import app.blink.core.net.PlusStatus
import app.blink.core.offline.JobView
import app.blink.core.offline.ManifestEntry
import app.blink.core.offline.OfflineCode
import app.blink.core.offline.OfflineState
import app.blink.core.offline.Stage
import app.blink.core.search.SearchModel
import app.blink.player.Graph
import app.blink.player.Tab
import app.blink.player.playback.PlayerUi
import app.blink.player.ui.BlinkRoot
import app.blink.player.ui.Ink
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.jetbrains.skia.EncodedImageFormat

private val out = File(System.getProperty("blink.out") ?: "build/screens").also { it.mkdirs() }
private val covers = Covers.generate(File(out, "covers"))
private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)

private fun lic(n: Int, title: String, artist: String, duration: Int, cover: Int, explicit: Boolean = false, offline: Boolean = true) =
    Track(id = "b:u$n", title = title, artist = artist, album = "Single", artwork = covers[cover % covers.size], duration = duration, explicit = explicit, source = "blink", lic = "u$n", offline = offline)

private fun ext(n: Int, title: String, artist: String, duration: Int, cover: Int) =
    Track(id = "cr$n", title = title, artist = artist, album = "Album", artwork = covers[cover % covers.size], duration = duration)

private val newest = listOf(
    lic(1, "Стекло и дождь", "Нора Вейл", 213, 0),
    lic(2, "Ночной автобус", "Лис и Ветер", 187, 1, explicit = true),
    lic(3, "Тёплый шум", "Kitchen Radio", 241, 2),
    lic(4, "Холодный кофе", "Нора Вейл", 198, 3, offline = false),
    lic(5, "Поезд в июле", "Дальний Свет", 266, 4),
)
private val chart = listOf(
    ext(1, "Midnight Drive", "Orla Fenn", 204, 5),
    ext(2, "Серебро", "Мэйви", 176, 6),
    ext(3, "Back to Zero", "Hale & Moor", 232, 7),
    ext(4, "Окна напротив", "Тихий Двор", 219, 8),
)

private fun entry(t: Track, bytes: Long, savedAt: Long) =
    ManifestEntry(
        key = "blink:${t.lic}", source = "blink", id = t.lic!!, title = t.title, artist = t.artist, album = t.album, cover = t.artwork,
        duration = t.duration, bytes = bytes, savedAt = savedAt, offlineAllowed = true,
        track = BlinkJson.encodeToJsonElement(Track.serializer(), t) as kotlinx.serialization.json.JsonObject,
    )

private fun job(t: Track, stage: Stage, have: Long = 0, total: Long? = null, attempt: Int = 0, code: OfflineCode? = null, reason: String? = null) =
    JobView("blink:${t.lic}", t.title, t.artist, t.artwork, stage, have, total, attempt, code, reason, null)

private fun search(): SearchModel =
    SearchModel(
        scope,
        search = { q -> (newest + chart).filter { it.title.contains(q, true) || it.artist.contains(q, true) } },
        newest = { newest },
        chart = { chart },
    ).also { it.refreshHome() }

private const val UNTIL = 1_797_076_800_000L // 12 декабря 2026

private fun graph(signedIn: Boolean = true, plus: Boolean = true): Graph {
    val g = Graph(signedIn = signedIn, plusUntilMs = if (plus) UNTIL else null, search = search())
    runBlocking { g.plus.refresh() }
    return g
}

@OptIn(ExperimentalComposeUiApi::class)
private fun shoot(name: String, g: Graph, query: String = "") {
    val scene = ImageComposeScene(1080, 2340, Density(3f)) {
        // На телефоне сверху строка состояния, снизу жесты: рисуем со своими отступами.
        Box(Modifier.fillMaxSize().background(Ink.ink).padding(top = 28.dp, bottom = 14.dp)) { BlinkRoot(g, initialQuery = query) }
    }
    var time = 0L
    repeat(40) {
        scene.render(time)
        time += 50_000_000L
        Thread.sleep(25)
    }
    val image = scene.render(time)
    File(out, "$name.png").writeBytes(image.encodeToData(EncodedImageFormat.PNG)!!.bytes)
    scene.close()
    println("screen $name -> ${File(out, "$name.png").length() / 1024} KB; actions=${g.actions.log}")
}

fun main() {
    // 1. Главная: новое в Blink и чарт, одна песня уже скачана, одна качается.
    graph().apply {
        offline.flow.value = OfflineState(
            ready = true,
            jobs = listOf(job(newest[2], Stage.DOWNLOADING, 4_200_000, 9_000_000)),
            saved = listOf(entry(newest[0], 5_100_000, 3)),
        )
        shoot("01-search-home", this)
    }
    // 2. Результаты поиска.
    graph().apply {
        offline.flow.value = OfflineState(ready = true, saved = listOf(entry(newest[0], 5_100_000, 3)))
        shoot("02-search-results", this, query = "нора")
    }
    // 3. Нет интернета.
    graph().apply {
        network.set(false)
        shoot("03-search-offline", this)
    }
    // 4. «Скачанное»: очередь с ошибкой и сохранённые.
    graph().apply {
        nav.go(Tab.Downloads)
        offline.flow.value = OfflineState(
            ready = true,
            jobs = listOf(
                job(newest[1], Stage.DOWNLOADING, 3_100_000, 7_200_000),
                job(newest[2], Stage.QUEUED),
                job(newest[4], Stage.FAILED, code = OfflineCode.TIMEOUT, attempt = 4),
            ),
            saved = listOf(entry(newest[0], 5_100_000, 3), entry(newest[3], 4_600_000, 2), entry(newest[4], 6_300_000, 1)),
        )
        shoot("04-downloads", this)
    }
    // 5. «Скачанное» пусто.
    graph().apply {
        nav.go(Tab.Downloads)
        shoot("05-downloads-empty", this)
    }
    // 6. Профиль: вошли, Blink+ активен.
    graph().apply {
        nav.go(Tab.Account)
        offline.flow.value = OfflineState(ready = true, saved = listOf(entry(newest[0], 5_100_000, 3), entry(newest[3], 4_600_000, 2)))
        shoot("06-account", this)
    }
    // 7. Профиль: не вошли.
    graph(signedIn = false, plus = false).apply {
        nav.go(Tab.Account)
        shoot("07-account-signed-out", this)
    }
    // 8. Мини-плеер над меню.
    graph().apply {
        player.flow.value = PlayerUi(track = newest[0], playing = true, positionMs = 72_000, durationMs = 213_000, hasNext = true, connected = true)
        offline.flow.value = OfflineState(ready = true, saved = listOf(entry(newest[0], 5_100_000, 3)))
        shoot("08-miniplayer", this)
    }
    // 9. Большой плеер, трек лежит на телефоне.
    graph().apply {
        player.flow.value = PlayerUi(track = newest[0], playing = true, positionMs = 72_000, durationMs = 213_000, hasNext = true, hasPrevious = true, connected = true)
        offline.flow.value = OfflineState(ready = true, saved = listOf(entry(newest[0], 5_100_000, 3)))
        nav.openPlayer(true)
        shoot("09-player-saved", this)
    }
    // 10. Большой плеер, трек из внешнего источника.
    graph().apply {
        player.flow.value = PlayerUi(track = chart[0], playing = false, positionMs = 12_000, durationMs = 204_000, hasNext = true, connected = true)
        nav.openPlayer(true)
        shoot("10-player-online-only", this)
    }
    // 11. Подсказка с кнопкой.
    graph().apply {
        toasts.show("Сохранение для офлайна доступно с Blink+", "Открыть Blink+") {}
        Thread.sleep(50)
        shoot("11-toast", this)
    }
}
