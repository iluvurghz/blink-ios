package app.blink.player.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.selected
import androidx.compose.foundation.border
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
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.blink.player.Graph
import app.blink.player.Overlay
import app.blink.player.Tab
import app.blink.player.data.Toast
import app.blink.player.playback.PlayerUi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest

/** Корень интерфейса. `onDownloadsStarted` зовётся, когда началась первая загрузка: платформа может спросить разрешение на уведомления. */
@Composable
fun BlinkRoot(g: Graph, onDownloadsStarted: () -> Unit = {}, initialQuery: String = "") {
    val tab by g.nav.tab.collectAsStateWithLifecycle()
    val overlay by g.nav.overlay.collectAsStateWithLifecycle()
    val playerOpen by g.nav.playerOpen.collectAsStateWithLifecycle()
    val player by g.player.state.collectAsStateWithLifecycle()
    val offline by g.offline.state.collectAsStateWithLifecycle()
    val searchList = rememberLazyListState()
    val downloadsList = rememberLazyListState()

    val downloading = offline.active
    LaunchedEffect(downloading) { if (downloading) onDownloadsStarted() }

    Box(Modifier.fillMaxSize().background(Ink.ink)) {
        when (tab) {
            Tab.Flash -> FlashScreen(g)
            Tab.Search -> SearchScreen(g, searchList, initialQuery)
            Tab.Downloads -> DownloadsScreen(g, downloadsList)
            Tab.Account -> AccountScreen(g)
        }

        when (overlay) {
            Overlay.Room -> RoomScreen(g)
            Overlay.Friends -> FriendsScreen(g)
            Overlay.Plus -> PlusScreen(g)
            Overlay.Library -> LibraryScreen(g)
            Overlay.Artist -> ArtistScreen(g)
            Overlay.Support -> SupportScreen(g)
            Overlay.Cabinet -> CabinetScreen(g)
            Overlay.None -> Unit
        }

        // Как на сайте в узком окне: снизу затемнение, над ним капсула мини-плеера и плавающий док.
        Chrome(g, tab, downloading, player, hidden = playerOpen && player.track != null)

        AnimatedVisibility(
            visible = playerOpen && player.track != null,
            enter = slideInVertically(animationSpec = tween(260), initialOffsetY = { it }) + fadeIn(tween(200)),
            exit = slideOutVertically(animationSpec = tween(220), targetOffsetY = { it }) + fadeOut(tween(160)),
        ) {
            PlayerScreen(g, player, offline) { g.nav.openPlayer(false) }
        }

        PlaylistPicker(g)
        TrackInfoSheet(g)

        ToastHost(g, bottomPadding = if (player.track != null && !playerOpen && tab != Tab.Flash) 170 else 90)
    }
}

@Composable
private fun BoxScope.Chrome(g: Graph, tab: Tab, downloading: Boolean, ui: PlayerUi, hidden: Boolean) {
    val palette by g.stage.palette.collectAsStateWithLifecycle()
    val accent by androidx.compose.animation.animateColorAsState(palette.accent.color(), tween(1200), label = "chromeAccent")
    val glowA = palette.glowA
    Box(
        Modifier
            .align(Alignment.BottomCenter)
            .fillMaxWidth()
            .graphicsLayer { alpha = if (hidden) 0f else 1f },
    ) {
        // Затемнение под доком, чтобы список не спорил с панелью (.m-dock::before).
        Box(
            Modifier
                .matchParentSize()
                .background(
                    androidx.compose.ui.graphics.Brush.verticalGradient(
                        0f to Color(0x0008070A),
                        0.3f to Color(0xC208070A),
                        0.6f to Color(0xF508070A),
                        1f to Color(0xFF08070A),
                    ),
                ),
        )
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(start = 12.dp, end = 12.dp, top = 18.dp, bottom = 10.dp)) {
            // на главной плеер уже есть (большая Вспышка), капсула там не нужна, как на сайте
            if (ui.track != null && tab != Tab.Flash) {
                MiniCapsule(g, ui, accent, palette.accentInk.color(), glowA.mix(0.34f, Color(16, 14, 19, 209)))
                Spacer(Modifier.height(10.dp))
            }
            Dock(tab, downloading, accent, glowA.mix(0.16f, Color(18, 16, 22, 240))) { g.nav.go(it) }
        }
    }
}

/** Плавающий док: четыре значка без подписей, выбранный в мягкой светящейся капсуле цвета акцента. */
@Composable
private fun Dock(tab: Tab, downloading: Boolean, accent: Color, bg: Color, onTab: (Tab) -> Unit) {
    val shape = RoundedCornerShape(26.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .height(64.dp)
            .shadow(18.dp, shape, ambientColor = Color.Black, spotColor = Color.Black)
            .clip(shape)
            .background(bg)
            .border(1.dp, Color(0x14FFFFFF), shape)
            .padding(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        DockItem(LineIcons.Bolt, "Вспышка", tab == Tab.Flash, false, accent, Modifier.weight(1f)) { onTab(Tab.Flash) }
        DockItem(LineIcons.Search, "Поиск", tab == Tab.Search, false, accent, Modifier.weight(1f)) { onTab(Tab.Search) }
        DockItem(LineIcons.Download, "Скачанное", tab == Tab.Downloads, downloading, accent, Modifier.weight(1f)) { onTab(Tab.Downloads) }
        DockItem(LineIcons.User, "Профиль", tab == Tab.Account, false, accent, Modifier.weight(1f)) { onTab(Tab.Account) }
    }
}

@Composable
private fun DockItem(icon: LineIcons, label: String, active: Boolean, dot: Boolean, accent: Color, modifier: Modifier, onClick: () -> Unit) {
    val fill by androidx.compose.animation.core.animateFloatAsState(if (active) 1f else 0f, tween(220), label = "dock")
    val shape = RoundedCornerShape(20.dp)
    Box(
        modifier
            .fillMaxHeight()
            .semantics { contentDescription = label; selected = active }
            .pressTap(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .padding(horizontal = 4.dp)
                .graphicsLayer { alpha = fill }
                .shadow(14.dp * fill, shape, ambientColor = accent, spotColor = accent)
                .clip(shape)
                .background(accent.copy(alpha = 0.2f)),
        )
        LineIcon(icon, color = if (active) accent else Ink.bone.copy(alpha = 0.55f), dp = 26.dp)
        if (dot) {
            Box(Modifier.align(Alignment.TopEnd).padding(top = 8.dp, end = 18.dp).size(7.dp).clip(CircleShape).background(accent))
        }
    }
}

/** Капсула мини-плеера (.m-mini): обложка, название и артист, сердце, кнопка играть; ход трека заливкой фона. Свайп в стороны листает треки. */
@Composable
private fun MiniCapsule(g: Graph, ui: PlayerUi, accent: Color, accentInk: Color, bg: Color) {
    val track = ui.track ?: return
    val library by g.library.state.collectAsStateWithLifecycle()
    val liked = remember(library, track.id) { g.library.isLiked(track.id) }
    val shape = RoundedCornerShape(22.dp)
    var dx by remember { mutableStateOf(0f) }
    val fraction = if (ui.durationMs > 0) (ui.positionMs.toFloat() / ui.durationMs).coerceIn(0f, 1f) else 0f
    Box(
        Modifier
            .fillMaxWidth()
            .height(72.dp)
            .graphicsLayer { translationX = dx * 0.4f }
            .shadow(16.dp, shape, ambientColor = Color.Black, spotColor = Color.Black)
            .clip(shape)
            .background(bg)
            .drawBehind { drawRect(accent.copy(alpha = 0.26f), size = androidx.compose.ui.geometry.Size(size.width * fraction, size.height)) }
            .border(1.dp, Color(0x14FFFFFF), shape)
            .pointerInput(track.id) {
                detectHorizontalDragGestures(
                    onDragEnd = {
                        if (dx < -80f) g.player.next() else if (dx > 80f) g.player.previous()
                        dx = 0f
                    },
                    onDragCancel = { dx = 0f },
                ) { _, d -> dx += d }
            }
            .semantics { contentDescription = "Открыть плеер" }
            .tap { g.nav.openPlayer(true) },
    ) {
        Row(Modifier.fillMaxSize().padding(start = 10.dp, end = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            NetImage(app.blink.core.ui.ArtUrl.scaled(track.artwork, 160), Modifier.size(52.dp).clip(RoundedCornerShape(14.dp)))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                T(track.title, style = Type.title.copy(fontFamily = Unbounded, fontWeight = androidx.compose.ui.text.font.FontWeight.Medium, fontSize = 17.sp, letterSpacing = (-0.2).sp), maxLines = 1)
                Spacer(Modifier.height(2.dp))
                T(track.artist, style = Type.small, color = Ink.bone.copy(alpha = 0.6f), maxLines = 1)
            }
            StageIcon(if (liked) LineIcons.HeartFill else LineIcons.Heart, "Любимое", { g.flash.toggleLike(track) }, dp = 22.dp, box = 44.dp, on = liked, accent = accent)
            PlayIris(ui.playing, ui.buffering, 48.dp, accent, accentInk, glow = false) { g.player.toggle() }
        }
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
