package app.blink.player.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.blink.core.offline.JobView
import app.blink.core.offline.ManifestEntry
import app.blink.core.offline.OfflineText
import app.blink.core.offline.Stage
import app.blink.core.ui.Format
import app.blink.player.Graph
import app.blink.player.Tab
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** «Скачанное»: что качается, что уже на телефоне, сколько места занято. Всё это играет без интернета. */
@Composable
fun DownloadsScreen(g: Graph, listState: LazyListState) {
    val st by g.offline.state.collectAsStateWithLifecycle()
    val player by g.player.state.collectAsStateWithLifecycle()
    val online by g.network.online.collectAsStateWithLifecycle()
    val free by produceState(0L, st.saved.size) { value = withContext(Dispatchers.IO) { g.offline.usage().free } }
    var confirmKey by remember { mutableStateOf<String?>(null) }
    var confirmClear by remember { mutableStateOf(false) }

    LaunchedEffect(confirmKey) { if (confirmKey != null) { delay(3500); confirmKey = null } }
    LaunchedEffect(confirmClear) { if (confirmClear) { delay(3500); confirmClear = false } }

    val failedCount = st.jobs.count { it.failed }
    val running = st.jobs.any { !it.failed }

    LazyColumn(state = listState, modifier = Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 190.dp)) {
        item(key = "head") {
            Column(Modifier.statusBarsPadding().padding(start = 20.dp, end = 20.dp, top = 14.dp, bottom = 4.dp)) {
                T("Скачанное", style = Type.display)
                Spacer(Modifier.height(6.dp))
                T(
                    if (st.saved.isEmpty()) "Треки, которые играют без интернета" else summary(st.saved.size, st.usedBytes) + " · свободно " + Format.bytes(free),
                    style = Type.small,
                    color = Ink.mute,
                )
            }
        }
        if (!online && st.saved.isNotEmpty()) {
            item(key = "offline") { Banner(Glyphs.CloudOff, "Нет интернета. Сохранённые треки играют с телефона (нужен активный Blink+).") }
        }
        if (running || failedCount > 0) {
            item(key = "controls") {
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (running) {
                        PillButton(if (st.paused) "Продолжить" else "Пауза", { if (st.paused) g.offline.resume() else g.offline.pause() }, primary = false)
                    }
                    if (failedCount > 0) {
                        PillButton("Повторить всё", { g.scope.launch(Dispatchers.IO) { g.offline.retryAll() } }, primary = false)
                    }
                }
            }
        }
        if (st.jobs.isNotEmpty()) {
            item(key = "queue-title") { SectionHeader("В очереди") }
            items(st.jobs, key = { "j:${it.key}" }) { job -> JobRow(g, job, online) }
        }
        if (st.saved.isNotEmpty()) {
            item(key = "saved-title") { SectionHeader("На телефоне") }
            itemsIndexed(st.saved, key = { _, e -> "s:${e.key}" }) { index, entry ->
                SavedRow(
                    entry = entry,
                    current = player.track?.lic == entry.id,
                    confirming = confirmKey == entry.key,
                    onPlay = { g.actions.playSaved(st.saved, index) },
                    onDelete = {
                        if (confirmKey == entry.key) {
                            confirmKey = null
                            g.actions.removeSaved(entry.key)
                        } else {
                            confirmKey = entry.key
                        }
                    },
                )
            }
            item(key = "clear") {
                Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.Center) {
                    PillButton(
                        if (confirmClear) "Точно удалить всё?" else "Очистить всё",
                        {
                            if (confirmClear) {
                                confirmClear = false
                                g.scope.launch(Dispatchers.IO) { g.offline.clearAll() }
                            } else {
                                confirmClear = true
                            }
                        },
                        primary = false,
                        danger = true,
                    )
                }
            }
        } else if (st.jobs.isEmpty()) {
            item(key = "empty") {
                EmptyState(
                    Glyphs.Download,
                    "Пока ничего не сохранено",
                    "Нажмите на стрелку у трека с меткой BLINK, и он будет играть без интернета. Нужен Blink+. Остальные треки играют только онлайн.",
                    button = "Найти треки",
                    onButton = { g.nav.go(Tab.Search) },
                )
            }
        }
    }
}

private fun stageLine(job: JobView, online: Boolean): String {
    val total = job.total
    return when (job.stage) {
        Stage.QUEUED -> if (!online) "Ждём интернет" else if (job.attempt > 0) "Повтор ${job.attempt}…" else "В очереди"
        Stage.RESOLVING -> "Готовим ссылку"
        Stage.DOWNLOADING -> if (total != null) "${Format.bytes(job.have)} из ${Format.bytes(total)}" else Format.bytes(job.have)
        Stage.VERIFYING -> "Проверяем файл"
        Stage.COMMITTING -> "Сохраняем"
        Stage.FAILED -> job.text?.message ?: "Не вышло"
    }
}

@Composable
private fun JobRow(g: Graph, job: JobView, online: Boolean) {
    Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 6.dp, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Cover(job.cover, Modifier.size(52.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            T(job.title, style = Type.title, maxLines = 1)
            T(job.artist, style = Type.small, color = Ink.mute, maxLines = 1)
            Spacer(Modifier.height(4.dp))
            T(stageLine(job, online), style = Type.small, color = if (job.failed) Ink.danger else Ink.faint, maxLines = 2)
            if (!job.failed && job.total != null) {
                Spacer(Modifier.height(6.dp))
                BarProgress(job.fraction)
            }
        }
        if (job.failed) {
            val action = job.text?.action
            if (action != null) {
                T(
                    action.label,
                    modifier = Modifier.tap {
                        when (action) {
                            OfflineText.Action.RETRY -> g.actions.retry(job.key)
                            OfflineText.Action.OPEN_PLUS -> g.actions.openPlus()
                            OfflineText.Action.SIGN_IN -> g.nav.go(Tab.Account)
                            OfflineText.Action.FREE_SPACE -> g.actions.openStorageSettings()
                        }
                    }.padding(horizontal = 8.dp, vertical = 12.dp),
                    style = Type.button,
                    color = Ink.accent,
                    maxLines = 1,
                )
            }
        }
        IconButton(Glyphs.Close, "Убрать из очереди", { g.actions.cancel(job.key) }, color = Ink.mute, dp = 20.dp)
    }
}

@Composable
private fun SavedRow(entry: ManifestEntry, current: Boolean, confirming: Boolean, onPlay: () -> Unit, onDelete: () -> Unit) {
    Row(Modifier.fillMaxWidth().tap(onClick = onPlay).padding(start = 16.dp, end = 6.dp, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Cover(entry.cover, Modifier.size(52.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            T(entry.title, style = Type.title, color = if (current) Ink.accent else Ink.bone, maxLines = 1)
            T(entry.artist, style = Type.small, color = Ink.mute, maxLines = 1)
            Spacer(Modifier.height(2.dp))
            T(Format.bytes(entry.bytes) + (if (entry.duration > 0) " · " + Format.duration(entry.duration) else ""), style = Type.small, color = Ink.faint, maxLines = 1)
        }
        if (confirming) {
            T("Удалить?", modifier = Modifier.tap(onClick = onDelete).padding(horizontal = 10.dp, vertical = 14.dp), style = Type.button, color = Ink.danger, maxLines = 1)
        } else {
            IconButton(Glyphs.Delete, "Удалить с телефона", onDelete, color = Ink.mute, dp = 22.dp)
        }
    }
}
