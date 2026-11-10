package app.blink.player.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.blink.player.Graph
import app.blink.player.Tab
import app.blink.player.data.Toast
import app.blink.player.playback.PlayerUi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest

/** Корень интерфейса. `onDownloadsStarted` зовётся, когда началась первая загрузка: платформа может спросить разрешение на уведомления. */
@Composable
fun BlinkRoot(g: Graph, onDownloadsStarted: () -> Unit = {}, initialQuery: String = "") {
    val tab by g.nav.tab.collectAsStateWithLifecycle()
    val playerOpen by g.nav.playerOpen.collectAsStateWithLifecycle()
    val player by g.player.state.collectAsStateWithLifecycle()
    val offline by g.offline.state.collectAsStateWithLifecycle()
    val searchList = rememberLazyListState()
    val downloadsList = rememberLazyListState()

    val downloading = offline.active
    LaunchedEffect(downloading) { if (downloading) onDownloadsStarted() }

    Box(Modifier.fillMaxSize().background(Ink.ink)) {
        when (tab) {
            Tab.Search -> SearchScreen(g, searchList, initialQuery)
            Tab.Downloads -> DownloadsScreen(g, downloadsList)
            Tab.Account -> AccountScreen(g)
        }

        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding().padding(bottom = 10.dp)) {
            if (player.track != null) {
                MiniPlayer(g, player)
                Spacer(Modifier.height(8.dp))
            }
            BottomBar(tab, downloading) { g.nav.go(it) }
        }

        AnimatedVisibility(
            visible = playerOpen && player.track != null,
            enter = slideInVertically(animationSpec = tween(260), initialOffsetY = { it }) + fadeIn(tween(200)),
            exit = slideOutVertically(animationSpec = tween(220), targetOffsetY = { it }) + fadeOut(tween(160)),
        ) {
            PlayerScreen(g, player, offline) { g.nav.openPlayer(false) }
        }

        ToastHost(g, bottomPadding = if (player.track != null && !playerOpen) 150 else 90)
    }
}

@Composable
private fun BottomBar(tab: Tab, downloading: Boolean, onTab: (Tab) -> Unit) {
    Row(
        Modifier
            .padding(horizontal = 16.dp)
            .fillMaxWidth()
            .height(62.dp)
            .clip(CircleShape)
            .background(Ink.ink2)
            .border(1.dp, Ink.line, CircleShape)
            .padding(6.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TabItem(Glyphs.Search, "Поиск", tab == Tab.Search, false, Modifier.weight(1f)) { onTab(Tab.Search) }
        TabItem(Glyphs.Download, "Скачанное", tab == Tab.Downloads, downloading, Modifier.weight(1f)) { onTab(Tab.Downloads) }
        TabItem(Glyphs.Person, "Профиль", tab == Tab.Account, false, Modifier.weight(1f)) { onTab(Tab.Account) }
    }
}

@Composable
private fun TabItem(glyph: Glyphs, label: String, active: Boolean, dot: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Box(
        modifier
            .height(50.dp)
            .clip(CircleShape)
            .background(if (active) Ink.accentSoft else Color.Transparent)
            .semantics { contentDescription = label }
            .tap(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box {
                Glyph(glyph, color = if (active) Ink.accent else Ink.mute, dp = 22.dp)
                if (dot) {
                    Box(Modifier.size(8.dp).align(Alignment.TopEnd).clip(CircleShape).background(Ink.accent))
                }
            }
            if (active) {
                Spacer(Modifier.width(7.dp))
                T(label, style = Type.button.copy(fontSize = 13.sp), color = Ink.accent, maxLines = 1)
            }
        }
    }
}

@Composable
private fun MiniPlayer(g: Graph, ui: PlayerUi) {
    val track = ui.track ?: return
    val shape = RoundedCornerShape(24.dp)
    Box(
        Modifier
            .padding(horizontal = 12.dp)
            .fillMaxWidth()
            .clip(shape)
            .background(Ink.ink3)
            .border(1.dp, Ink.line, shape)
            .tap { g.nav.openPlayer(true) },
    ) {
        Row(Modifier.padding(start = 8.dp, end = 4.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Cover(track.artwork, Modifier.size(44.dp), radius = 14.dp, noteDp = 20.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                T(track.title, style = Type.title.copy(fontSize = 14.sp), maxLines = 1)
                T(track.artist, style = Type.small, color = Ink.mute, maxLines = 1)
            }
            IconButton(if (ui.playing) Glyphs.Pause else Glyphs.Play, if (ui.playing) "Пауза" else "Играть", { g.player.toggle() })
            IconButton(Glyphs.Next, "Следующий", { g.player.next() }, enabled = ui.hasNext)
        }
        val fraction = if (ui.durationMs > 0) (ui.positionMs.toFloat() / ui.durationMs).coerceIn(0f, 1f) else 0f
        Box(
            Modifier
                .align(Alignment.BottomStart)
                .fillMaxWidth()
                .height(2.dp)
                .graphicsLayer { scaleX = fraction; transformOrigin = androidx.compose.ui.graphics.TransformOrigin(0f, 0.5f) }
                .background(Ink.accent),
        )
    }
}

/** Всплывающая подсказка внизу. Новая заменяет старую; с кнопкой висит дольше. */
@Composable
private fun BoxScope.ToastHost(g: Graph, bottomPadding: Int) {
    var shown by remember { mutableStateOf<Toast?>(null) }
    var visible by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        g.toasts.events.collectLatest { t ->
            shown = t
            visible = true
            delay(if (t.action != null) 5200L else 3400L)
            visible = false
        }
    }
    AnimatedVisibility(
        visible = visible,
        modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(start = 16.dp, end = 16.dp, bottom = bottomPadding.dp),
        enter = fadeIn(tween(160)) + slideInVertically(animationSpec = tween(220), initialOffsetY = { it / 2 }),
        exit = fadeOut(tween(160)),
    ) {
        val toast = shown
        if (toast != null) ToastPill(toast) { visible = false }
    }
}

@Composable
private fun ToastPill(toast: Toast, onDismiss: () -> Unit) {
    val shape = RoundedCornerShape(22.dp)
    Row(
        Modifier
            .clip(shape)
            .background(Ink.ink3)
            .border(1.dp, Ink.line2, shape)
            .tap(onClick = onDismiss)
            .padding(start = 18.dp, end = if (toast.action != null) 6.dp else 18.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        T(toast.message, Modifier.weight(1f, fill = false).padding(vertical = 10.dp), Type.body, Ink.bone, maxLines = 4)
        val label = toast.action
        if (label != null) {
            Spacer(Modifier.width(8.dp))
            T(
                label,
                modifier = Modifier.tap {
                    onDismiss()
                    toast.onAction?.invoke()
                }.padding(horizontal = 12.dp, vertical = 12.dp),
                style = Type.button,
                color = Ink.accent,
                maxLines = 1,
            )
        }
    }
}
