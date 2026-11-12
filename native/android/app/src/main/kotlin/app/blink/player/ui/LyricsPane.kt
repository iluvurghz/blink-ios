package app.blink.player.ui

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.blink.core.lyrics.Karaoke
import app.blink.core.lyrics.KaraokeRow
import app.blink.core.lyrics.LyricsData
import app.blink.core.model.Track
import app.blink.player.Graph
import app.blink.player.playback.PlayerUi
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

private val EASE_OUT = CubicBezierEasing(0.23f, 1f, 0.32f, 1f)

/**
 * Текст песни как на сайте (Stage.jsx `Lyrics` + `Synced`): караоке со словами, которые заливаются по одному,
 * «• • •» и отсчёт 3·2·1 на паузах, перевод под строкой. На карточке строки по центру, во весь экран слева.
 */
@Composable
fun LyricsPane(g: Graph, track: Track, ui: PlayerUi, full: Boolean, accent: Color) {
    val state by g.stage.lyrics.collectAsStateWithLifecycle()
    val tr by g.stage.tr.collectAsStateWithLifecycle()
    val translate by g.stage.translate.collectAsStateWithLifecycle()
    val center = !full
    val map = (tr as? TrState.On)?.map
    when (val s = state) {
        LyricsState.Loading -> Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = if (center) Alignment.CenterHorizontally else Alignment.Start) {
            listOf(0.72f, 0.54f, 0.64f).forEachIndexed { i, w ->
                Box(Modifier.fillMaxWidth(w).height(36.dp).alpha(1f - i * 0.25f).clip(RoundedCornerShape(10.dp)).background(Color(0x0FFFFFFF)))
                Spacer(Modifier.height(18.dp))
            }
        }
        LyricsState.Failed -> Empty("Тексты сейчас недоступны", "Сервис с текстами не отвечает. Обычно это ненадолго.", center) { g.stage.retry() }
        LyricsState.None -> Empty("Текста для этого трека пока нет", "Просто слушайте. Тексты берутся из открытой базы LRCLIB, она пополняется каждый день.", center)
        is LyricsState.Data -> when (val d = s.data) {
            LyricsData.Instrumental -> Empty("Инструментал", "В этом треке нет слов.", center)
            is LyricsData.Plain -> Box(Modifier.fillMaxSize()) {
                Column(Modifier.fillMaxSize().fadeEdges(0.1f, 0.15f).verticalScroll(rememberScrollState()).padding(vertical = 60.dp), horizontalAlignment = if (center) Alignment.CenterHorizontally else Alignment.Start) {
                    for (l in d.lines) {
                        BasicText(l.ifEmpty { " " }, style = TextStyle(fontFamily = Unbounded, fontWeight = FontWeight.Medium, fontSize = 19.sp, lineHeight = 25.sp, letterSpacing = (-0.38).sp, color = Ink.bone.copy(alpha = 0.75f), textAlign = if (center) TextAlign.Center else TextAlign.Start), modifier = Modifier.fillMaxWidth())
                        map?.get(l.trim())?.let { BasicText(it, style = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = Ink.bone.copy(alpha = 0.38f), textAlign = if (center) TextAlign.Center else TextAlign.Start), modifier = Modifier.fillMaxWidth()) }
                        Spacer(Modifier.height(6.dp))
                    }
                }
                Tools(g, track, d, tr, translate, full)
            }
            is LyricsData.Synced -> Box(Modifier.fillMaxSize()) {
                val rows = remember(d) { Karaoke.build(d.lines) }
                Synced(rows, ui, map, center, accent) { g.player.seekTo(it) }
                Tools(g, track, d, tr, translate, full)
            }
        }
    }
}

@Composable
private fun Empty(big: String, small: String, center: Boolean, retry: (() -> Unit)? = null) {
    val align = if (center) TextAlign.Center else TextAlign.Start
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = if (center) Alignment.CenterHorizontally else Alignment.Start) {
        BasicText(big, style = TextStyle(fontFamily = Unbounded, fontWeight = FontWeight.Medium, fontSize = 20.sp, color = Ink.bone, textAlign = align))
        Spacer(Modifier.height(8.dp))
        BasicText(small, style = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.Medium, fontSize = 14.sp, lineHeight = 20.sp, color = Ink.mute, textAlign = align))
        if (retry != null) {
            Spacer(Modifier.height(18.dp))
            PillButton("Повторить", primary = false, onClick = retry)
        }
    }
}

/** Пилюля над текстом (.lyr-tools): «Перевод» и «Поделиться». */
@Composable
private fun Tools(g: Graph, track: Track, d: LyricsData, tr: TrState, translate: Boolean, full: Boolean) {
    val scope = rememberCoroutineScope()
    val disabled = d.isRussian || tr == TrState.Native || tr == TrState.Error
    val on = translate && !disabled
    Row(
        Modifier
            .offset(x = if (full) 0.dp else (-8).dp, y = if (full) 0.dp else (-12).dp)
            .alpha(if (on) 1f else 0.55f)
            .clip(CircleShape)
            .background(Color(0x800D0C10))
            .border(1.dp, Ink.line, CircleShape)
            .padding(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            Modifier
                .height(28.dp)
                .clip(CircleShape)
                .background(if (on) Ink.bone.copy(alpha = 0.08f) else Color.Transparent)
                .semantics { contentDescription = if (disabled) "Перевод не нужен" else "Перевод" }
                .tap(!disabled) { g.stage.toggleTranslate() }
                .padding(horizontal = 10.dp)
                .alpha(if (disabled) 0.5f else 1f),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            LineIcon(LineIcons.Translate, color = if (on) Ink.bone else Ink.mute, dp = 15.dp)
            Spacer(Modifier.width(6.dp))
            BasicText(if (tr == TrState.Loading) "Перевожу…" else "Перевод", style = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.Bold, fontSize = 12.sp, color = if (on) Ink.bone else Ink.mute))
        }
        Box(
            Modifier.width(34.dp).height(28.dp).semantics { contentDescription = "Поделиться" }.tap { scope.launch { g.actions.share(g.shared.trackLink(track)) } },
            contentAlignment = Alignment.Center,
        ) { LineIcon(LineIcons.Share, color = Ink.mute, dp = 15.dp) }
    }
}

/** Строки со временем. Активная строка стоит на 36% высоты, лента едет за песней. */
@Composable
private fun Synced(rows: List<KaraokeRow>, ui: PlayerUi, tr: Map<String, String>?, center: Boolean, accent: Color, onSeek: (Long) -> Unit) {
    // Плавные часы: позиция плеера приходит раз в полсекунды, между ними досчитываем сами.
    var anchorMs by remember { mutableLongStateOf(ui.positionMs) }
    var anchorAt by remember { mutableLongStateOf(System.nanoTime()) }
    LaunchedEffect(ui.positionMs, ui.playing) {
        anchorMs = ui.positionMs
        anchorAt = System.nanoTime()
    }
    var now by remember { mutableStateOf(ui.positionMs / 1000.0) }
    LaunchedEffect(ui.playing) {
        if (!ui.playing) {
            now = ui.positionMs / 1000.0
            return@LaunchedEffect
        }
        while (true) {
            withFrameMillis { }
            val t = anchorMs / 1000.0 + (System.nanoTime() - anchorAt) / 1e9
            now = minOf(t, ui.positionMs / 1000.0 + 1.0)
        }
    }
    val t = if (ui.playing) now else ui.positionMs / 1000.0
    val active = Karaoke.active(rows, t)
    val count = Karaoke.countdown(rows, active, t)
    val mids = remember(rows) { mutableStateMapOf<Int, Float>() }
    val vw = LocalConfiguration.current.screenWidthDp.toFloat()
    val base = if (center) (vw * 0.06f).coerceIn(21f, 26f) else (vw * 0.07f).coerceIn(24f, 30f)
    val big = if (center) (vw * 0.084f).coerceIn(28f, 36f) else (vw * 0.09f).coerceIn(30f, 40f)
    val density = LocalDensity.current
    val breathe by rememberInfiniteTransition(label = "breathe").animateFloat(1f, 0.35f, infiniteRepeatable(tween(800, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "b")

    BoxWithConstraints(Modifier.fillMaxSize().fadeEdges(0.18f, 0.28f)) {
        val h = with(density) { maxHeight.toPx() }
        val target = h * 0.36f - (mids[maxOf(0, active)] ?: 0f)
        val y by animateFloatAsState(target, tween(700, easing = EASE_OUT), label = "scroll")
        Column(
            Modifier.fillMaxWidth().wrapContentHeight(unbounded = true, align = Alignment.Top).offset { IntOffset(0, y.roundToInt()) },
            horizontalAlignment = if (center) Alignment.CenterHorizontally else Alignment.Start,
        ) {
            rows.forEachIndexed { i, r ->
                val on = i == active
                val m = Modifier.fillMaxWidth().onGloballyPositioned { c -> mids[i] = c.positionInParent().y + c.size.height / 2f }
                if (r.gap) {
                    Box(m.padding(vertical = 10.dp), contentAlignment = if (center) Alignment.Center else Alignment.CenterStart) {
                        val hide = on && count > 0
                        BasicText(
                            "• • •",
                            Modifier.graphicsLayer {
                                alpha = if (hide) 0f else if (on) breathe else 1f
                                scaleX = if (hide) 0.6f else 1f
                                scaleY = if (hide) 0.6f else 1f
                            },
                            style = TextStyle(fontFamily = Unbounded, fontWeight = FontWeight.SemiBold, fontSize = base.sp, letterSpacing = (base * 0.3f).sp, color = if (on) accent else Ink.bone.copy(alpha = 0.3f)),
                        )
                        if (hide) {
                            BasicText(
                                "$count",
                                style = TextStyle(fontFamily = Unbounded, fontWeight = FontWeight.Bold, fontSize = 40.sp, letterSpacing = (-1.6).sp, color = accent, shadow = Shadow(accent.copy(alpha = 0.5f), blurRadius = 24f)),
                            )
                        }
                    }
                } else {
                    val past = i < active
                    val far = if (active >= 0) abs(i - active) > 3 else i > 3
                    val scale by animateFloatAsState(if (on) 1f else 0.94f, tween(600, easing = EASE_OUT), label = "s$i")
                    val size = if (on) big else base
                    val clean = r.text.trim()
                    val translated = tr?.get(clean)?.takeIf { it.lowercase() != clean.lowercase() }
                    Column(
                        m
                            .tap { onSeek(((r.t + 0.05).coerceAtLeast(0.0) * 1000).toLong()) }
                            .padding(vertical = 10.dp)
                            .graphicsLayer {
                                scaleX = scale
                                scaleY = scale
                                transformOrigin = if (center) TransformOrigin.Center else TransformOrigin(0f, 0.5f)
                            }
                            .then(if (far) Modifier.blur(1.5.dp) else Modifier),
                        horizontalAlignment = if (center) Alignment.CenterHorizontally else Alignment.Start,
                    ) {
                        val style = TextStyle(
                            fontFamily = Unbounded,
                            fontWeight = if (on) FontWeight.Bold else FontWeight.Medium,
                            fontSize = size.sp,
                            lineHeight = (size * 1.18f).sp,
                            letterSpacing = (-size * 0.03f).sp,
                            textAlign = if (center) TextAlign.Center else TextAlign.Start,
                        )
                        if (on) {
                            val text = buildAnnotatedString {
                                for (seg in r.segs) {
                                    val p = if (seg.t == null) 1.0 else seg.progress(t)
                                    val lit = (p * 1.4).coerceIn(0.0, 1.0).toFloat()
                                    withStyle(SpanStyle(color = Ink.bone.copy(alpha = 0.72f + 0.28f * lit))) { append(seg.text) }
                                }
                            }
                            BasicText(text, style = style)
                        } else {
                            BasicText(r.text, style = style.copy(color = Ink.bone.copy(alpha = if (past) 0.22f else 0.3f)))
                        }
                        if (translated != null) {
                            Spacer(Modifier.height(6.dp))
                            BasicText(
                                translated,
                                style = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.SemiBold, fontSize = (size * 0.46f).sp, textAlign = if (center) TextAlign.Center else TextAlign.Start, color = Ink.bone.copy(alpha = if (on) 0.7f else if (past) 0.2f else 0.38f)),
                            )
                        }
                    }
                }
            }
        }
    }
}
