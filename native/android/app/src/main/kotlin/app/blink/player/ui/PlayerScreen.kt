package app.blink.player.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.blink.core.lyrics.LyricsData
import app.blink.core.model.Track
import app.blink.core.offline.OfflinePolicy
import app.blink.core.offline.OfflineState
import app.blink.core.ui.ArtUrl
import app.blink.core.ui.Format
import app.blink.player.Graph
import app.blink.player.Overlay
import app.blink.player.playback.PlayerUi
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlinx.coroutines.launch
import androidx.compose.ui.composed

internal enum class StageTab { Cover, Lyrics, Queue, Comments }

/**
 * Большой плеер один в один с мобильным плеером сайта (Stage.jsx, ветка `narrow`, и .pstage в mobile.css):
 * фон из обложки, шапка «откуда играет», обложка или текст на стеклянной карточке, трек с фото артиста,
 * перемотка, управление и ряд «повтор / текст / перемешать». Развёрнутый текст занимает весь экран, внизу пилюля трека.
 */
@Composable
fun PlayerScreen(g: Graph, ui: PlayerUi, offline: OfflineState, onClose: () -> Unit) {
    val track = ui.track ?: return
    BackHandler(onBack = onClose)
    val palette by g.stage.palette.collectAsStateWithLifecycle()
    val lyrics by g.stage.lyrics.collectAsStateWithLifecycle()
    val photo by g.stage.photo.collectAsStateWithLifecycle()
    val wave by g.flash.active.collectAsStateWithLifecycle()
    val library by g.library.state.collectAsStateWithLifecycle()
    val liked = remember(library, track.id) { g.library.isLiked(track.id) }
    val accent by animateColorAsState(palette.accent.color(), tween(1200), label = "accent")
    val accentInk = palette.accentInk.color()
    val scope = rememberCoroutineScope()

    var tab by remember { mutableStateOf(LaunchHooks.stageTab()) }
    var full by remember { mutableStateOf(LaunchHooks.stageFull()) }
    var drag by remember { mutableStateOf(0f) }
    var menu by remember { mutableStateOf(false) }
    val has = g.stage.hasLyrics(lyrics)
    LaunchedEffect(track.id, has, lyrics) {
        if (tab == StageTab.Lyrics && lyrics !is LyricsState.Loading && !has) tab = StageTab.Cover
    }
    LaunchedEffect(track.id) { if (tab == StageTab.Comments) tab = StageTab.Cover }
    LaunchedEffect(wave) { if (wave && tab == StageTab.Queue) tab = StageTab.Cover }
    val textOn = tab == StageTab.Lyrics && has
    val big = full && textOn
    fun pick(t: StageTab) {
        full = false
        tab = if (tab == t) StageTab.Cover else t
    }
    fun openArtist() {
        val id = track.artistId ?: return
        onClose()
        g.nav.openArtist(id)
    }
    val closeDrag = Modifier.pointerInput(Unit) {
        detectVerticalDragGestures(
            onDragEnd = { if (drag > 300f) onClose() else drag = 0f },
            onDragCancel = { drag = 0f },
            onVerticalDrag = { _, dy -> drag = (drag + dy).coerceAtLeast(0f) },
        )
    }

    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .offset { IntOffset(0, drag.roundToInt()) }
            .pointerInput(Unit) { detectTapGestures { } },
    ) {
        val screenH = maxHeight
        BlurredCover(track.artwork)
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(bottom = 16.dp)) {
            // шапка
            Row(Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 8.dp).then(closeDrag), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) { StageIcon(LineIcons.Down, "Свернуть", onClose, dp = 24.dp) }
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Row(verticalAlignment = Alignment.Bottom) {
                        Tx("blink", style = TextStyle(fontFamily = Unbounded, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, letterSpacing = (-0.26).sp, color = Ink.bone.copy(alpha = 0.55f)))
                        Box(Modifier.padding(start = 2.dp, bottom = 3.dp).size(4.dp).clip(CircleShape).background(accent))
                    }
                    Tx(if (wave) "Вспышка" else "Сейчас играет", style = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.Bold, fontSize = 14.sp, color = Ink.bone.copy(alpha = 0.85f)), maxLines = 1)
                }
                Row(Modifier.weight(1f), horizontalArrangement = Arrangement.End) {
                    if (track.lic != null) StageIcon(LineIcons.Chat, "Комментарии", { pick(StageTab.Comments) }, dp = 20.dp, on = tab == StageTab.Comments, accent = accent)
                    if (!wave) StageIcon(LineIcons.Queue, "Очередь", { pick(StageTab.Queue) }, dp = 22.dp, on = tab == StageTab.Queue, accent = accent)
                }
            }

            // середина
            Box(Modifier.weight(1f).fillMaxWidth()) {
                when {
                    big -> Box(Modifier.fillMaxSize().padding(start = 22.dp, end = 22.dp, bottom = 12.dp)) {
                        LyricsPane(g, track, ui, full = true, accent = accent)
                        StageIcon(LineIcons.Min, "Свернуть текст", { full = false }, Modifier.align(Alignment.TopEnd), dp = 18.dp, box = 36.dp, color = Ink.bone.copy(alpha = 0.7f))
                    }
                    tab == StageTab.Queue || tab == StageTab.Comments || textOn -> {
                        val shape = RoundedCornerShape(28.dp)
                        Box(
                            Modifier
                                .fillMaxSize()
                                .padding(start = 18.dp, end = 18.dp, top = 4.dp, bottom = 18.dp)
                                .shadow(30.dp, shape, ambientColor = Color.Black, spotColor = Color.Black)
                                .clip(shape)
                                .background(Color(0x8C100E14))
                                .border(1.dp, Color(0x14FFFFFF), shape),
                        ) {
                            AnimatedContent(tab to track.id, transitionSpec = { fadeIn(tween(250)) togetherWith fadeOut(tween(200)) }, label = "card") { (t, _) ->
                                Box(Modifier.fillMaxSize().padding(horizontal = 18.dp, vertical = 22.dp)) {
                                    when (t) {
                                        StageTab.Queue -> QueuePane(g, ui, accent)
                                        StageTab.Comments -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = 30.dp)) { CommentsBlock(g, null, track.lic) }
                                        else -> LyricsPane(g, track, ui, full = false, accent = accent)
                                    }
                                }
                            }
                            if (textOn) StageIcon(LineIcons.Max, "Весь текст", { full = true }, Modifier.align(Alignment.TopEnd).padding(10.dp), dp = 18.dp, box = 36.dp, color = Ink.bone.copy(alpha = 0.7f))
                        }
                    }
                    else -> BoxWithConstraints(
                        Modifier.fillMaxSize().padding(start = 18.dp, end = 18.dp, top = 4.dp, bottom = 18.dp).pointerInput(Unit) {
                            var dx = 0f
                            var dy = 0f
                            detectDragGestures(
                                onDragStart = { dx = 0f; dy = 0f },
                                onDragEnd = {
                                    if (abs(dx) > abs(dy) && abs(dx) > 160f) {
                                        if (dx < 0) g.player.next() else g.player.previous()
                                        drag = 0f
                                    } else if (drag > 300f) onClose() else drag = 0f
                                },
                                onDragCancel = { drag = 0f },
                                onDrag = { _, d ->
                                    dx += d.x
                                    dy += d.y
                                    if (abs(dy) > abs(dx)) drag = (drag + d.y).coerceAtLeast(0f)
                                },
                            )
                        },
                        contentAlignment = Alignment.Center,
                    ) {
                        val side = minOf(maxWidth, maxHeight, screenH * 0.52f).coerceAtLeast(120.dp)
                        val shape = RoundedCornerShape(22.dp)
                        AnimatedContent(track.id, transitionSpec = { fadeIn(tween(400)) togetherWith fadeOut(tween(200)) }, label = "art") { _ ->
                            NetImage(
                                ArtUrl.scaled(track.artwork, 1000),
                                Modifier.size(side).shadow(40.dp, shape, spotColor = Color.Black).clip(shape).border(1.dp, Color(0x12FFFFFF), shape),
                            )
                        }
                    }
                }
            }

            if (big) {
                // пилюля трека под развёрнутым текстом
                val shape = RoundedCornerShape(18.dp)
                Row(
                    Modifier.padding(horizontal = 14.dp).fillMaxWidth().clip(shape).background(Color(0x14FFFFFF)).border(1.dp, Color(0x14FFFFFF), shape).tap { full = false }.padding(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    NetImage(ArtUrl.scaled(track.artwork, 100), Modifier.size(44.dp).clip(RoundedCornerShape(10.dp)))
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Tx(track.title, style = TextStyle(fontFamily = Unbounded, fontWeight = FontWeight.Bold, fontSize = 16.sp, letterSpacing = (-0.48).sp, color = Ink.bone), maxLines = 1)
                        Tx(track.artist, style = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = Ink.bone.copy(alpha = 0.6f)), maxLines = 1)
                    }
                    Spacer(Modifier.width(12.dp))
                    PlayIris(ui.playing, ui.buffering, 44.dp, accent, accentInk, glow = false) { g.player.toggle() }
                }
            } else {
                // трек: фото артиста, название, поделиться, ещё
                Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    NetImage(photo ?: ArtUrl.scaled(track.artwork, 100), Modifier.size(52.dp).clip(CircleShape).tap { openArtist() }.semantics { contentDescription = track.artist })
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Tx(track.title, style = TextStyle(fontFamily = Unbounded, fontWeight = FontWeight.Bold, fontSize = 20.sp, letterSpacing = (-0.6).sp, color = Ink.bone), maxLines = 1)
                        Spacer(Modifier.height(3.dp))
                        Tx(track.artist, Modifier.tap { openArtist() }, style = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = Ink.bone.copy(alpha = 0.6f)), maxLines = 1)
                    }
                    Spacer(Modifier.width(12.dp))
                    StageIcon(LineIcons.Share, "Поделиться ссылкой", { scope.launch { g.actions.share(g.shared.trackLink(track)) } }, dp = 20.dp, color = Ink.bone.copy(alpha = 0.85f))
                    StageIcon(LineIcons.More, "Ещё", { menu = true }, dp = 20.dp, color = Ink.bone.copy(alpha = 0.85f))
                }

                // перемотка
                Column(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 16.dp)) {
                    StageSeek(ui.positionMs, ui.durationMs, accent) { ms ->
                        g.player.seekTo(ms)
                        g.room.onUserSeek(ms)
                    }
                    Spacer(Modifier.height(6.dp))
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        val st = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.SemiBold, fontSize = 12.sp, color = Ink.mute, fontFeatureSettings = "tnum")
                        Tx(Format.duration((ui.positionMs / 1000).toInt()), style = st)
                        Tx(Format.duration((ui.durationMs / 1000).toInt()), style = st)
                    }
                }

                // управление
                Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 8.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    if (wave) {
                        StageIcon(LineIcons.ThumbDown, "Не моё: больше такое не ставить", { g.flash.dislike(track) }, dp = 22.dp, box = 54.dp)
                    } else {
                        Spacer(Modifier.size(54.dp))
                    }
                    StageIcon(LineIcons.Prev, "Назад", { g.player.previous() }, dp = 28.dp, box = 54.dp)
                    PlayIris(ui.playing, ui.buffering, 78.dp, accent, accentInk, glow = true) { g.player.toggle() }
                    StageIcon(LineIcons.Next, "Дальше", { g.player.next() }, dp = 28.dp, box = 54.dp, enabled = ui.hasNext)
                    StageIcon(if (liked) LineIcons.HeartFill else LineIcons.Heart, "Любимое", { g.flash.toggleLike(track) }, dp = 24.dp, box = 54.dp, on = liked, accent = accent)
                }

                // повтор / текст / перемешать
                Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 18.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    RowTile(if (ui.repeat == "one") LineIcons.RepeatOne else LineIcons.Repeat, "Повтор", ui.repeat != "off", Modifier.weight(1f)) { g.player.cycleRepeat() }
                    val hint = when {
                        !has -> if (lyrics is LyricsState.Loading) "Ищу текст…" else "У этого трека нет текста"
                        textOn -> "Убрать текст"
                        else -> "Показать текст"
                    }
                    RowTile(LineIcons.Lyrics, hint, textOn, Modifier.weight(1f), enabled = has) {
                        full = false
                        tab = if (textOn) StageTab.Cover else StageTab.Lyrics
                    }
                    RowTile(LineIcons.Shuffle, "Перемешать", ui.shuffle, Modifier.weight(1f)) { g.player.toggleShuffle() }
                }
            }
        }
        if (menu) {
            TrackSheet(track, onDismiss = { menu = false }, items = buildList<Pair<String, () -> Unit>> {
                add("В плейлист" to { g.pickTrack.value = track })
                add((if (g.room.inRoom) "Комната" else "Слушать вместе") to { g.nav.open(Overlay.Room) })
                if (OfflinePolicy.savable(track)) add("Сохранить для офлайна" to { onSaveTap(g, track, offline) })
                if (track.artistId != null) add("К артисту" to { openArtist() })
                add("О треке" to { g.infoTrack.value = track })
            })
        }
    }
}

@Composable
private fun Tx(text: String, modifier: Modifier = Modifier, style: TextStyle, maxLines: Int = Int.MAX_VALUE) {
    BasicText(text, modifier, style = style, overflow = TextOverflow.Ellipsis, maxLines = maxLines)
}

/** Меню «⋯» снизу листом, как на сайте на телефоне. */
@Composable
private fun TrackSheet(track: Track, onDismiss: () -> Unit, items: List<Pair<String, () -> Unit>>) {
    BackHandler(onBack = onDismiss)
    Box(Modifier.fillMaxSize().background(Color(0x99000000)).pointerInput(Unit) { detectTapGestures { onDismiss() } }, contentAlignment = Alignment.BottomCenter) {
        val shape = RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp)
        Column(
            Modifier.fillMaxWidth().clip(shape).background(Ink.ink2).border(1.dp, Ink.line, shape).pointerInput(Unit) { detectTapGestures { } }
                .navigationBarsPadding().padding(top = 10.dp, bottom = 12.dp),
        ) {
            Box(Modifier.align(Alignment.CenterHorizontally).width(40.dp).height(4.dp).clip(CircleShape).background(Ink.line2))
            Row(Modifier.padding(horizontal = 20.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                NetImage(ArtUrl.scaled(track.artwork, 100), Modifier.size(44.dp).clip(RoundedCornerShape(10.dp)))
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Tx(track.title, style = TextStyle(fontFamily = Unbounded, fontWeight = FontWeight.Bold, fontSize = 16.sp, color = Ink.bone), maxLines = 1)
                    Tx(track.artist, style = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = Ink.mute), maxLines = 1)
                }
            }
            for ((label, action) in items) {
                Tx(
                    label,
                    Modifier.fillMaxWidth().tap { onDismiss(); action() }.padding(horizontal = 20.dp, vertical = 15.dp),
                    style = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, color = Ink.bone),
                )
            }
        }
    }
}

/** Для снимков в CI: какой экран плеера открыть сразу (переменные запуска, см. MainActivity). */
internal object LaunchHooks {
    @Volatile var stage: String? = null

    fun stageTab(): StageTab = when (stage) {
        "lyrics", "full" -> StageTab.Lyrics
        "queue" -> StageTab.Queue
        else -> StageTab.Cover
    }

    fun stageFull(): Boolean = stage == "full"
}

/** Круглая кнопка-значок (.icon-btn). Включённая подсвечивается акцентом. */
@Composable
fun StageIcon(
    icon: LineIcons,
    description: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    dp: androidx.compose.ui.unit.Dp = 22.dp,
    box: androidx.compose.ui.unit.Dp = 44.dp,
    color: Color = Ink.bone,
    on: Boolean = false,
    enabled: Boolean = true,
    accent: Color = Ink.accent,
) {
    Box(
        modifier.size(box).semantics { contentDescription = description; selected = on }.pressTap(enabled, onClick),
        contentAlignment = Alignment.Center,
    ) {
        LineIcon(icon, color = if (on) accent else if (enabled) color else color.copy(alpha = 0.3f), dp = dp)
    }
}

/** Тап с лёгким сжатием, как :active { scale: .92 } на сайте. */
fun Modifier.pressTap(enabled: Boolean = true, onClick: () -> Unit): Modifier = composed {
    var pressed by remember { mutableStateOf(false) }
    val s by animateFloatAsState(if (pressed) 0.92f else 1f, tween(140), label = "press")
    this
        .graphicsLayer { scaleX = s; scaleY = s }
        .pointerInput(enabled) {
            if (!enabled) return@pointerInput
            detectTapGestures(
                onPress = {
                    pressed = true
                    tryAwaitRelease()
                    pressed = false
                },
                onTap = { onClick() },
            )
        }
}

/** Кнопка играть/пауза (.iris): круг цвета акцента, свечение под большой кнопкой, кольцо при загрузке. */
@Composable
fun PlayIris(playing: Boolean, buffering: Boolean, size: androidx.compose.ui.unit.Dp, accent: Color, ink: Color, glow: Boolean, onClick: () -> Unit) {
    val p by animateFloatAsState(if (playing) 1f else 0f, tween(200), label = "iris")
    Box(Modifier.size(size + 8.dp), contentAlignment = Alignment.Center) {
        if (buffering) Spinner(dp = size + 8.dp, color = accent)
        Box(
            Modifier
                .size(size)
                .then(if (glow) Modifier.shadow(24.dp, CircleShape, ambientColor = accent, spotColor = accent) else Modifier)
                .clip(CircleShape)
                .background(accent)
                .semantics { contentDescription = if (playing) "Пауза" else "Играть" }
                .pressTap(onClick = onClick),
            contentAlignment = Alignment.Center,
        ) {
            LineIcon(LineIcons.Play, Modifier.graphicsLayer { alpha = 1 - p; scaleX = 1 - 0.4f * p; scaleY = 1 - 0.4f * p; rotationZ = -30f * p }, color = ink, dp = size * 0.42f)
            LineIcon(LineIcons.Pause, Modifier.graphicsLayer { alpha = p; scaleX = 0.6f + 0.4f * p; scaleY = 0.6f + 0.4f * p; rotationZ = -30f * (1 - p) }, color = ink, dp = size * 0.42f)
        }
    }
}

/** Плитка ряда под управлением (.ps-row button): серая заливка; включённая прозрачная с рамкой цвета кости. */
@Composable
private fun RowTile(icon: LineIcons, description: String, on: Boolean, modifier: Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    val shape = RoundedCornerShape(16.dp)
    val bg by animateColorAsState(if (on) Color.Transparent else Color(0x0FFFFFFF), tween(200), label = "tile")
    val line by animateColorAsState(if (on) Ink.bone.copy(alpha = 0.9f) else Color.Transparent, tween(200), label = "tileLine")
    Box(
        modifier
            .height(48.dp)
            .alpha(if (enabled) 1f else 0.3f)
            .clip(shape)
            .background(bg)
            .border(1.5.dp, line, shape)
            .semantics { contentDescription = description; selected = on }
            .pressTap(enabled, onClick),
        contentAlignment = Alignment.Center,
    ) {
        LineIcon(icon, color = if (on) Ink.bone else Ink.bone.copy(alpha = 0.7f), dp = 20.dp)
    }
}

/** Перемотка (.stage-scrub .progress): тонкая дорожка, заливка акцентом, белая точка всегда видна. */
@Composable
fun StageSeek(positionMs: Long, durationMs: Long, accent: Color, onSeek: (Long) -> Unit) {
    var drag by remember { mutableStateOf<Float?>(null) }
    val fraction = drag ?: if (durationMs > 0) (positionMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f
    val rail by animateDpAsState(if (drag != null) 6.dp else 4.dp, tween(150), label = "rail")
    Box(
        Modifier
            .fillMaxWidth()
            .height(20.dp)
            .semantics { contentDescription = "Перемотка" }
            .pointerInput(durationMs) {
                detectTapGestures { o -> if (durationMs > 0) onSeek((o.x / size.width * durationMs).toLong().coerceIn(0, durationMs)) }
            }
            .pointerInput(durationMs) {
                detectHorizontalDragGestures(
                    onDragStart = { o -> drag = (o.x / size.width).coerceIn(0f, 1f) },
                    onDragEnd = {
                        val f = drag
                        if (f != null && durationMs > 0) onSeek((f * durationMs).toLong())
                        drag = null
                    },
                    onDragCancel = { drag = null },
                    onHorizontalDrag = { c, _ -> drag = (c.position.x / size.width).coerceIn(0f, 1f) },
                )
            },
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val h = rail.toPx()
            val y = (size.height - h) / 2
            val corner = CornerRadius(h / 2, h / 2)
            drawRoundRect(Ink.bone.copy(alpha = 0.1f), Offset(0f, y), Size(size.width, h), corner)
            drawRoundRect(accent, Offset(0f, y), Size(size.width * fraction, h), corner)
            drawCircle(Ink.bone, radius = 6.dp.toPx(), center = Offset(size.width * fraction, size.height / 2))
        }
    }
}

/** Полоса перемотки Вспышки (как раньше). */
@Composable
fun SeekBar(positionMs: Long, durationMs: Long, onSeek: (Long) -> Unit, modifier: Modifier = Modifier) {
    Box(modifier) { StageSeek(positionMs, durationMs, Ink.accent, onSeek) }
}

/** «Сейчас и дальше»: очередь с тремя прошедшими треками сверху, тап переключает трек. */
@Composable
private fun QueuePane(g: Graph, ui: PlayerUi, accent: Color) {
    val (tracks, index) = remember(ui.index, ui.queueLeft, ui.shuffle) { g.player.queue() }
    // при перемешивании порядок «дальше» берём у плеера
    val order = remember(tracks, index, ui.upcoming) {
        val past = (maxOf(0, index - 3) until index).toList()
        val next = if (ui.upcoming.isNotEmpty()) ui.upcoming else ((index + 1) until tracks.size).toList()
        past + listOf(index) + next
    }
    val list = rememberLazyListState(initialFirstVisibleItemIndex = maxOf(0, minOf(3, index) - 1))
    LazyColumn(
        Modifier.fillMaxSize().fadeEdges(0.06f, 0.1f),
        state = list,
        contentPadding = PaddingValues(bottom = 24.dp),
    ) {
        item {
            Tx("СЕЙЧАС И ДАЛЬШЕ", Modifier.padding(start = 10.dp, end = 10.dp, top = 6.dp, bottom = 8.dp), style = Type.label.copy(color = Ink.mute))
        }
        itemsIndexed(order, key = { _, i -> i }) { _, i ->
            val t = tracks.getOrNull(i) ?: return@itemsIndexed
            val current = i == index
            Row(
                Modifier
                    .fillMaxWidth()
                    .alpha(if (i < index) 0.45f else 1f)
                    .clip(RoundedCornerShape(12.dp))
                    .background(if (current) Color(0x0FFFFFFF) else Color.Transparent)
                    .tap { g.player.jump(i) }
                    .padding(horizontal = 10.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                NetImage(ArtUrl.scaled(t.artwork, 100), Modifier.size(44.dp).clip(RoundedCornerShape(8.dp)))
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Tx(t.title, style = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.Bold, fontSize = 15.sp, color = if (current) accent else Ink.bone), maxLines = 1)
                    Tx(t.artist, style = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.Medium, fontSize = 13.sp, color = Ink.mute), maxLines = 1)
                }
                Tx(Format.duration(t.duration), style = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.SemiBold, fontSize = 12.sp, color = Ink.faint, fontFeatureSettings = "tnum"))
            }
        }
        item {
            Tx(
                "Когда очередь закончится, Blink продолжит похожими треками этих артистов.",
                Modifier.padding(start = 10.dp, end = 10.dp, top = 24.dp),
                style = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.Medium, fontSize = 12.5.sp, color = Ink.faint),
            )
        }
    }
}

/** Мягкие края сверху и снизу (mask-image с градиентом на сайте). */
fun Modifier.fadeEdges(top: Float, bottom: Float): Modifier = this
    .graphicsLayer { compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.Offscreen }
    .drawWithContent {
        drawContent()
        drawRect(
            Brush.verticalGradient(0f to Color.Transparent, top to Color.Black, (1f - bottom) to Color.Black, 1f to Color.Transparent),
            blendMode = androidx.compose.ui.graphics.BlendMode.DstIn,
        )
    }
