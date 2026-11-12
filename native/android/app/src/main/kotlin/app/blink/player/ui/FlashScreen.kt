package app.blink.player.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsTopHeight
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.selected
import app.blink.core.ui.Hsl
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.animation.core.animateFloat
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
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
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.blink.core.model.Track
import app.blink.core.ui.ArtUrl
import app.blink.core.ui.Format
import app.blink.core.wave.WaveMode
import app.blink.player.Graph
import app.blink.player.LibRoute
import app.blink.player.Tab

/**
 * Главная: сверху большая Вспышка (фон из обложки, кнопка, режимы), ниже «Коллекция»:
 * «Мне нравится», скачанное, плейлисты, любимые артисты и последние лайки.
 */
@Composable
fun FlashScreen(g: Graph) {
    val library by g.library.state.collectAsStateWithLifecycle()
    val player by g.player.state.collectAsStateWithLifecycle()
    val liked = remember(library) { g.library.likes }
    val playlists = remember(library) { g.library.playlists }
    val artists = remember(liked) { favouriteArtists(liked) }
    val track = player.track

    androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize()) {
    val screenH = maxHeight
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = 190.dp),
    ) {
        item(key = "hero") { FlashHero(g, Modifier.height(screenH)) }
        item(key = "collection") {
            Spacer(Modifier.height(26.dp))
            Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp), verticalAlignment = Alignment.Bottom) {
                T("Коллекция", Modifier.weight(1f), Type.h1)
                T("Всё", Modifier.tap { g.nav.openLibrary() }.padding(6.dp), Type.button, Ink.mute)
            }
            Spacer(Modifier.height(14.dp))
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                LikesTile(g, liked.size, Modifier.weight(1f)) { g.nav.openLibrary(LibRoute.Likes) }
                CollectionTile(LineIcons.Download, "Скачанное", "Без интернета", Modifier.weight(1f)) { g.nav.go(Tab.Downloads) }
            }
        }
        item(key = "playlists") {
            Spacer(Modifier.height(22.dp))
            Shelf("Плейлисты", "Все") { g.nav.openLibrary() }
            LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                items(playlists, key = { it.id }) { p ->
                    PlaylistCard(p.cover ?: p.tracks.firstOrNull()?.artwork.orEmpty(), p.name, Format.tracks(p.tracks.size)) {
                        g.nav.openLibrary(LibRoute.Mine(p.id))
                    }
                }
                item(key = "import") {
                    ActionCard(LineIcons.Plus, "Перенести музыку", "Яндекс, Spotify") { g.nav.openLibrary(LibRoute.Import) }
                }
            }
        }
        if (artists.isNotEmpty()) {
            item(key = "artists") {
                Spacer(Modifier.height(22.dp))
                Shelf("Любимые артисты", null) {}
                LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    items(artists, key = { it.first }) { (name, tracks) ->
                        ArtistBubble(g, name, tracks) {
                            val id = tracks.first().artistId
                            if (id != null) g.nav.openArtist(id) else g.actions.play(tracks, 0)
                        }
                    }
                }
            }
        }
        item(key = "likes-head") {
            Spacer(Modifier.height(22.dp))
            Shelf("Понравившееся", if (liked.size > 6) "Все ${liked.size}" else null) { g.nav.openLibrary(LibRoute.Likes) }
        }
        if (liked.isEmpty()) {
            item(key = "likes-empty") {
                T(
                    "Нажимайте сердечко у треков, и они соберутся здесь и на вашем аккаунте на сайте.",
                    Modifier.padding(horizontal = 20.dp),
                    Type.small,
                    Ink.faint,
                )
            }
        } else {
            val top = liked.take(6)
            items(top.size, key = { "like-" + top[it].id }) { i ->
                LikedRow(top[i], current = top[i].id == track?.id) { g.actions.play(liked, i) }
            }
        }
    }
    // под строкой состояния, когда главная прокручена вниз
    Box(
        Modifier.fillMaxWidth().background(Brush.verticalGradient(listOf(Color(0xFF0B0A0D), Color(0x000B0A0D))))
            .windowInsetsTopHeight(androidx.compose.foundation.layout.WindowInsets.statusBars),
    )
    }
}

/** Артисты из лайков: у кого больше всего понравившихся треков. */
private fun favouriteArtists(liked: List<Track>): List<Pair<String, List<Track>>> =
    liked.groupBy { it.artist.split(",", "&", " feat").first().trim() }
        .filterKeys { it.isNotEmpty() }
        .entries
        .sortedByDescending { it.value.size }
        .take(12)
        .map { it.key to it.value }

/** Яркий вариант цвета палитры для свечения: светлее и насыщеннее, но в том же тоне. */
private fun Hsl.vivid(l: Double = 0.56, s: Double = 0.85): Hsl = Hsl(h, maxOf(this.s, s).coerceAtMost(1.0), maxOf(this.l, l))

/**
 * Живой свет за Вспышкой (порт шейдера ui/AuraGL.jsx): три больших мягких пятна цветов обложки плывут,
 * тёплое ядро дышит в такт, к низу и к краям темнеет. Как на сайте, считается в маленькой картинке
 * (54×120 точек, 20 кадров в секунду, в фоновом потоке) и растягивается на экран: свет мягкий, так что
 * разницы не видно, а телефон не греется. Пока открыт большой плеер, стоит.
 */
@Composable
fun FlashAura(palette: app.blink.core.ui.Palette, energy: Float, modifier: Modifier = Modifier, paused: Boolean = false) {
    val c0 by animateColorAsState(palette.accent.vivid(0.58).color(), tween(1500), label = "aura0")
    val c1 by animateColorAsState(palette.glowB.vivid(0.5).color(), tween(1500), label = "aura1")
    val c2 by animateColorAsState(palette.glowA.vivid(0.52).color(), tween(1500), label = "aura2")
    val c3 by animateColorAsState(palette.accent.vivid(0.66, 0.9).color(), tween(1500), label = "aura3")
    val e by androidx.compose.animation.core.animateFloatAsState(energy, tween(900), label = "energy")
    val colors by androidx.compose.runtime.rememberUpdatedState(listOf(c0, c1, c2, c3))
    val en by androidx.compose.runtime.rememberUpdatedState(e)
    val bmp = remember { android.graphics.Bitmap.createBitmap(AURA_W, AURA_H, android.graphics.Bitmap.Config.ARGB_8888) }
    val image = remember(bmp) { bmp.asImageBitmap() }
    var frame by remember { mutableStateOf(0) }
    LaunchedEffect(paused) {
        val px = IntArray(AURA_W * AURA_H)
        val start = System.nanoTime()
        while (true) {
            val t = (System.nanoTime() - start) / 1e9f + 7f
            val cs = colors
            val energyNow = en
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) { auraFrame(px, t, cs, energyNow) }
            bmp.setPixels(px, 0, AURA_W, 0, 0, AURA_W, AURA_H)
            frame++
            if (paused) break
            kotlinx.coroutines.delay(50)
        }
    }
    Canvas(modifier.fillMaxSize()) {
        frame.let { }
        drawImage(
            image,
            dstSize = androidx.compose.ui.unit.IntSize(size.width.toInt(), size.height.toInt()),
            filterQuality = androidx.compose.ui.graphics.FilterQuality.Low,
        )
    }
}

private const val AURA_W = 54
private const val AURA_H = 120

/** Один кадр света: то же, что фрагментный шейдер сайта, по точкам маленькой картинки. */
private fun auraFrame(px: IntArray, t: Float, cs: List<Color>, energy: Float) {
    val r = FloatArray(4) { cs[it].red }
    val g = FloatArray(4) { cs[it].green }
    val b = FloatArray(4) { cs[it].blue }
    val s = t * 0.16f
    val pax = 0.22f + 0.12f * kotlin.math.sin(s * 0.9f)
    val pay = 0.78f + 0.08f * kotlin.math.cos(s * 0.7f)
    val pbx = 0.80f + 0.10f * kotlin.math.cos(s * 0.8f + 1f)
    val pby = 0.46f + 0.12f * kotlin.math.sin(s * 0.6f)
    val pcx = 0.46f + 0.14f * kotlin.math.sin(s * 0.5f + 2f)
    val pcy = 0.16f + 0.08f * kotlin.math.cos(s * 0.9f + 2f)
    val beat = Math.pow(0.5 + 0.5 * kotlin.math.sin(t * 0.9), 3.0).toFloat()
    val coreAmp = 0.30f + 0.18f * energy + 0.18f * beat * energy
    fun ss(e0: Float, e1: Float, x: Float): Float {
        val k = ((x - e0) / (e1 - e0)).coerceIn(0f, 1f)
        return k * k * (3 - 2 * k)
    }
    var i = 0
    for (y in 0 until AURA_H) {
        val uy = 1f - (y + 0.5f) / AURA_H
        val dark = 0.30f + 0.70f * ss(0f, 0.6f, uy)
        for (x in 0 until AURA_W) {
            val ux = (x + 0.5f) / AURA_W
            fun gau(cx: Float, cy: Float, k: Float): Float {
                val dx = ux - cx
                val dy = uy - cy
                return kotlin.math.exp(-k * (dx * dx + dy * dy))
            }
            val ga = gau(pax, pay, 6f) * 0.62f
            val gb = gau(pbx, pby, 6.5f) * 0.50f
            val gc = gau(pcx, pcy, 7f) * 0.42f
            val core = gau(0.5f, 0.60f, 7f) * coreAmp
            val halo = gau(0.5f, 0.60f, 3f) * 0.10f
            val vx = (ux - 0.5f) * 0.9f
            val vy = (uy - 0.5f) * 1.1f
            val vig = 1f - 0.55f * ss(0.45f, 1.1f, kotlin.math.sqrt(vx * vx + vy * vy))
            var cr = (r[0] + (r[1] - r[0]) * uy) * 0.07f + r[0] * ga + r[1] * gb + r[2] * gc + (r[3] * 0.92f + 0.08f) * core + r[3] * halo
            var cg = (g[0] + (g[1] - g[0]) * uy) * 0.07f + g[0] * ga + g[1] * gb + g[2] * gc + (g[3] * 0.92f + 0.08f) * core + g[3] * halo
            var cb = (b[0] + (b[1] - b[0]) * uy) * 0.07f + b[0] * ga + b[1] * gb + b[2] * gc + (b[3] * 0.92f + 0.08f) * core + b[3] * halo
            val m = dark * vig * 1.3f
            cr = 1f - kotlin.math.exp(-cr * m)
            cg = 1f - kotlin.math.exp(-cg * m)
            cb = 1f - kotlin.math.exp(-cb * m)
            px[i++] = (0xFF shl 24) or ((cr * 255f).toInt().coerceIn(0, 255) shl 16) or ((cg * 255f).toInt().coerceIn(0, 255) shl 8) or (cb * 255f).toInt().coerceIn(0, 255)
        }
    }
}

/**
 * Главный экран Вспышки на всю высоту, как на сайте (FlashHome.jsx) поверх живого света: сверху плашка «Играет …»
 * с крестиком, в середине «Точка» из точек (нажать: вспыхивает и собирается в обложку), под ней «Вспышка.» с подсказкой,
 * а когда играет: название, ход трека точками, кнопки сайта и режимы словами с точкой под выбранным.
 */
@Composable
private fun FlashHero(g: Graph, modifier: Modifier) {
    val active by g.flash.active.collectAsStateWithLifecycle()
    val loading by g.flash.loading.collectAsStateWithLifecycle()
    val mode by g.flash.mode.collectAsStateWithLifecycle()
    val player by g.player.state.collectAsStateWithLifecycle()
    val palette by g.stage.palette.collectAsStateWithLifecycle()
    val library by g.library.state.collectAsStateWithLifecycle()
    val playerOpen by g.nav.playerOpen.collectAsStateWithLifecycle()
    val accent by animateColorAsState(palette.accent.color(), tween(1200), label = "heroAccent")
    val ink = palette.accentInk.color()
    val track = player.track
    // Вспышка «горит», когда заиграл её трек; до того (и если до нажатия играло своё) точки разгораются
    var startId by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(active) { startId = if (active) g.player.state.value.track?.id else null }
    val phase = when {
        active && track != null && (track.id != startId || !loading) -> DotPhase.Flash
        active || loading -> DotPhase.Igniting
        else -> DotPhase.Rest
    }
    val flashing = phase == DotPhase.Flash && track != null
    val liked = remember(library, track?.id) { track != null && g.library.isLiked(track.id) }
    val hint = remember(library) {
        val names = favouriteArtists(g.library.likes).take(3).map { it.first }
        if (names.isEmpty()) "Слушайте и ставьте лайки, и поток подстроится под вас" else names.joinToString(", ") + " и похожее на них"
    }

    androidx.compose.foundation.layout.BoxWithConstraints(modifier.fillMaxWidth()) {
        val w = maxWidth
        val side = (maxHeight - 540.dp).coerceAtLeast(176.dp).coerceAtMost(minOf(318.dp, w - 44.dp)).coerceAtLeast(120.dp)
        FlashAura(palette, if (player.playing) 1f else 0.35f, paused = playerOpen)
        Column(
            Modifier.fillMaxSize().statusBarsPadding().padding(top = 10.dp, bottom = 96.dp).navigationBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(Modifier.height(48.dp).fillMaxWidth(), contentAlignment = Alignment.Center) {
                if (track != null) {
                    HomePill(
                        big = flashing,
                        on = player.playing,
                        title = if (flashing || active) "Играет Вспышка" else "Играет ваша музыка",
                        sub = if (flashing || active) mode.title else "${track.title} · ${track.artist}",
                        accent = accent,
                        onOpen = { g.nav.openPlayer(true) },
                        onClose = {
                            g.flash.stop()
                            g.player.stop()
                        },
                    )
                } else {
                    Row(verticalAlignment = Alignment.Bottom) {
                        T("blink", style = Type.h2.copy(fontSize = 20.sp, letterSpacing = (-0.8).sp), color = Ink.bone)
                        Box(Modifier.padding(start = 2.dp, bottom = 5.dp).size(6.dp).clip(CircleShape).background(accent))
                    }
                }
            }
            Spacer(Modifier.weight(1f))
            var dx by remember { mutableStateOf(0f) }
            DotObject(
                phase = phase,
                accent = accent,
                photo = track?.artwork,
                size = side,
                paused = playerOpen,
                modifier = Modifier
                    .graphicsLayer { translationX = dx * 0.3f }
                    .semantics { contentDescription = if (flashing) "Открыть плеер" else "Включить Вспышку" }
                    .pointerInput(flashing) {
                        if (!flashing) return@pointerInput
                        detectHorizontalDragGestures(
                            onDragEnd = {
                                if (dx < -120f) g.player.next() else if (dx > 120f) g.player.previous()
                                dx = 0f
                            },
                            onDragCancel = { dx = 0f },
                        ) { _, d -> dx += d }
                    }
                    .pressTap(enabled = flashing || phase == DotPhase.Rest) {
                        if (flashing) g.nav.openPlayer(true) else g.flash.start()
                    },
            ) {
                if (track != null) NetImage(ArtUrl.scaled(track.artwork, 600), Modifier.fillMaxSize())
            }
            Spacer(Modifier.height(22.dp))
            if (flashing && track != null) {
                val titleSp = (w.value * 0.068f).coerceIn(22f, 30f)
                T(
                    track.title,
                    Modifier.padding(horizontal = 28.dp),
                    Type.display.copy(fontSize = titleSp.sp, lineHeight = (titleSp * 1.08f).sp, letterSpacing = (-0.045f * titleSp).sp),
                    maxLines = 2,
                    align = TextAlign.Center,
                )
                Spacer(Modifier.height(7.dp))
                T(
                    track.artist,
                    Modifier.padding(horizontal = 28.dp),
                    Type.body.copy(fontSize = 16.sp, fontWeight = FontWeight.SemiBold),
                    Ink.bone.copy(alpha = 0.62f),
                    maxLines = 1,
                    align = TextAlign.Center,
                )
                Spacer(Modifier.height(14.dp))
                DotProgress(player.positionMs, player.durationMs, accent, { g.player.seekTo(it) }, Modifier.padding(horizontal = 22.dp))
                Spacer(Modifier.height(14.dp))
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 22.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    BareButton(LineIcons.ThumbDown, "Не моё", 22.dp) { g.flash.dislike(track) }
                    BareButton(LineIcons.Prev, "Назад", 24.dp) { g.player.previous() }
                    IrisButton(player.playing, player.buffering, accent, ink) { g.player.toggle() }
                    BareButton(LineIcons.Next, "Дальше", 24.dp) { g.player.next() }
                    BareButton(if (liked) LineIcons.HeartFill else LineIcons.Heart, "Любимое", 22.dp, on = liked, accent = accent) { g.flash.toggleLike(track) }
                }
            } else {
                T(
                    "ВАШ ЛИЧНЫЙ ПОТОК",
                    style = Type.label.copy(fontSize = 12.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.9.sp),
                    color = Ink.bone.copy(alpha = 0.72f),
                    maxLines = 1,
                )
                Spacer(Modifier.height(10.dp))
                val heroSp = (w.value * 0.15f).coerceIn(40f, 58f)
                Row(verticalAlignment = Alignment.Bottom) {
                    T("Вспышка", style = Type.display.copy(fontSize = heroSp.sp, lineHeight = (heroSp * 0.95f).sp, letterSpacing = (-0.055f * heroSp).sp), color = Ink.bone, maxLines = 1)
                    Box(Modifier.padding(start = (heroSp * 0.06f).dp, bottom = (heroSp * 0.16f).dp).size((heroSp * 0.18f).dp).clip(CircleShape).background(accent))
                }
                Spacer(Modifier.height(12.dp))
                T(
                    if (phase == DotPhase.Igniting) "Подбираю музыку…" else hint,
                    Modifier.padding(horizontal = 36.dp).heightIn(min = 42.dp),
                    Type.body.copy(fontSize = 16.sp, lineHeight = 21.sp, fontWeight = FontWeight.Bold),
                    Ink.bone,
                    maxLines = 2,
                    align = TextAlign.Center,
                )
            }
            Spacer(Modifier.weight(1f))
            ModeWords(mode, accent) { m ->
                g.flash.setMode(m)
                if (!active && !loading) g.flash.start()
            }
        }
    }
}

/** Плашка сверху, как на сайте (.hm-pill): точка Blink с кольцом (моргает, пока играет), что играет, и крестик. */
@Composable
private fun HomePill(big: Boolean, on: Boolean, title: String, sub: String, accent: Color, onOpen: () -> Unit, onClose: () -> Unit) {
    val blink = androidx.compose.animation.core.rememberInfiniteTransition(label = "pillBlink")
    val sy by blink.animateFloat(
        initialValue = 1f,
        targetValue = 1f,
        animationSpec = androidx.compose.animation.core.infiniteRepeatable(
            androidx.compose.animation.core.keyframes {
                durationMillis = 4600
                1f at 4232
                0.15f at 4416
                1f at 4600
            },
        ),
        label = "pillBlinkY",
    )
    Row(
        Modifier
            .padding(horizontal = 16.dp)
            .height(48.dp)
            .clip(CircleShape)
            .background(Ink.bone.copy(alpha = 0.075f))
            .border(1.dp, Ink.bone.copy(alpha = 0.11f), CircleShape)
            .padding(start = 6.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            Modifier.weight(1f, fill = false).semantics { contentDescription = "Открыть плеер" }.tap(onClick = onOpen).padding(end = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val d = if (big) 14.dp else 11.dp
            val ring = if (big) 6.dp else 5.dp
            Box(Modifier.size(34.dp), contentAlignment = Alignment.Center) {
                Box(
                    Modifier
                        .size(d)
                        .graphicsLayer { scaleY = if (on) sy else 1f }
                        .drawBehind {
                            drawCircle(
                                Brush.radialGradient(listOf(accent.copy(alpha = 0.7f), accent.copy(alpha = 0f)), center, size.width / 2 + (if (big) 22 else 16).dp.toPx()),
                                size.width / 2 + (if (big) 22 else 16).dp.toPx(),
                            )
                            drawCircle(accent.copy(alpha = if (big) 0.22f else 0.2f), size.width / 2 + ring.toPx())
                            drawCircle(accent)
                        },
                )
            }
            Spacer(Modifier.width(8.dp))
            Column {
                T(title, style = Type.button.copy(fontSize = 14.sp, fontWeight = FontWeight.Bold), color = Ink.bone, maxLines = 1)
                T(sub, Modifier.widthIn(max = 200.dp), Type.small.copy(fontSize = 12.sp, fontWeight = FontWeight.SemiBold), Ink.bone.copy(alpha = 0.62f), maxLines = 1)
            }
        }
        Box(
            Modifier.size(40.dp).clip(CircleShape).semantics { contentDescription = "Остановить и закрыть" }.pressTap(onClick = onClose),
            contentAlignment = Alignment.Center,
        ) { LineIcon(LineIcons.Close, color = Ink.bone.copy(alpha = 0.85f), dp = 16.dp, stroke = 2.2f) }
    }
}

/** Режимы словами, как на сайте (.hm-modes): выбранный светлый, под ним точка Blink, она переезжает к новому. */
@Composable
private fun ModeWords(mode: WaveMode, accent: Color, onPick: (WaveMode) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), horizontalArrangement = Arrangement.Center) {
        WaveMode.entries.forEach { m ->
            val on = m == mode
            val c by animateColorAsState(if (on) Ink.bone else Ink.bone.copy(alpha = 0.55f), tween(200), label = "mode")
            Box(
                Modifier
                    .height(38.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .semantics { contentDescription = "Режим ${m.title}"; selected = on }
                    .tap { onPick(m) }
                    .padding(start = 12.dp, end = 12.dp, bottom = 8.dp),
                contentAlignment = Alignment.Center,
            ) {
                T(m.title, style = Type.button.copy(fontSize = 13.sp, fontWeight = FontWeight.Bold), color = c, maxLines = 1)
                androidx.compose.animation.AnimatedVisibility(
                    on,
                    Modifier.align(Alignment.BottomCenter).offset(y = 5.dp),
                    enter = androidx.compose.animation.scaleIn(tween(260)) + androidx.compose.animation.fadeIn(tween(200)),
                    exit = androidx.compose.animation.scaleOut(tween(160)) + androidx.compose.animation.fadeOut(tween(160)),
                ) { Box(Modifier.size(5.dp).clip(CircleShape).background(accent)) }
            }
        }
    }
}

@Composable
private fun Shelf(title: String, action: String?, onAction: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 14.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        T(title, Modifier.weight(1f), Type.h2)
        if (action != null) T(action, Modifier.tap(onClick = onAction).padding(6.dp), Type.button.copy(fontSize = 13.sp), Ink.mute)
    }
}

/** «Мне нравится»: плитка цвета акцента с сердцем и числом треков. */
@Composable
private fun LikesTile(g: Graph, count: Int, modifier: Modifier, onClick: () -> Unit) {
    val palette by g.stage.palette.collectAsStateWithLifecycle()
    val accent by animateColorAsState(palette.accent.color(), tween(1200), label = "likesAccent")
    val shape = RoundedCornerShape(22.dp)
    Column(
        modifier
            .height(132.dp)
            .clip(shape)
            .background(Brush.linearGradient(listOf(accent.copy(alpha = 0.95f), palette.glowB.color(0.85f), Ink.ink3)))
            .semantics { contentDescription = "Мне нравится" }
            .pressTap(onClick = onClick)
            .padding(16.dp),
    ) {
        Box(Modifier.size(40.dp).clip(CircleShape).background(Color(0x33000000)), contentAlignment = Alignment.Center) {
            LineIcon(LineIcons.HeartFill, color = Ink.bone, dp = 22.dp)
        }
        Spacer(Modifier.weight(1f))
        T("Мне нравится", style = Type.h2, color = Ink.bone, maxLines = 1)
        T(Format.tracks(count), style = Type.small, color = Ink.bone.copy(alpha = 0.75f), maxLines = 1)
    }
}

@Composable
private fun CollectionTile(icon: LineIcons, title: String, subtitle: String, modifier: Modifier, onClick: () -> Unit) {
    val shape = RoundedCornerShape(22.dp)
    Column(
        modifier
            .height(132.dp)
            .clip(shape)
            .background(Ink.ink2)
            .border(1.dp, Color(0x12FFFFFF), shape)
            .semantics { contentDescription = title }
            .pressTap(onClick = onClick)
            .padding(16.dp),
    ) {
        Box(Modifier.size(40.dp).clip(CircleShape).background(Color(0x14FFFFFF)), contentAlignment = Alignment.Center) {
            LineIcon(icon, color = Ink.bone, dp = 22.dp)
        }
        Spacer(Modifier.weight(1f))
        T(title, style = Type.h2, maxLines = 1)
        T(subtitle, style = Type.small, color = Ink.mute, maxLines = 1)
    }
}

@Composable
private fun PlaylistCard(cover: String, name: String, sub: String, onClick: () -> Unit) {
    Column(Modifier.width(140.dp).pressTap(onClick = onClick)) {
        NetImage(ArtUrl.scaled(cover, 300), Modifier.size(140.dp).clip(RoundedCornerShape(20.dp)))
        Spacer(Modifier.height(8.dp))
        T(name, style = Type.title, maxLines = 1)
        T(sub, style = Type.small, color = Ink.mute, maxLines = 1)
    }
}

@Composable
private fun ActionCard(icon: LineIcons, name: String, sub: String, onClick: () -> Unit) {
    Column(Modifier.width(140.dp).pressTap(onClick = onClick)) {
        Box(
            Modifier.size(140.dp).clip(RoundedCornerShape(20.dp)).background(Ink.ink2).border(1.dp, Color(0x14FFFFFF), RoundedCornerShape(20.dp)),
            contentAlignment = Alignment.Center,
        ) {
            LineIcon(icon, color = Ink.bone.copy(alpha = 0.7f), dp = 34.dp)
        }
        Spacer(Modifier.height(8.dp))
        T(name, style = Type.title, maxLines = 1)
        T(sub, style = Type.small, color = Ink.mute, maxLines = 1)
    }
}

@Composable
private fun ArtistBubble(g: Graph, name: String, tracks: List<Track>, onClick: () -> Unit) {
    var photo by remember(name) { mutableStateOf<String?>(null) }
    LaunchedEffect(name) { photo = g.stage.artistPhoto(tracks.first()) }
    Column(Modifier.width(88.dp).pressTap(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally) {
        NetImage(photo ?: ArtUrl.scaled(tracks.first().artwork, 200), Modifier.size(88.dp).clip(CircleShape))
        Spacer(Modifier.height(8.dp))
        T(name, style = Type.small.copy(fontWeight = FontWeight.SemiBold), maxLines = 1, align = TextAlign.Center)
    }
}

@Composable
private fun LikedRow(track: Track, current: Boolean, onPlay: () -> Unit) {
    Row(Modifier.fillMaxWidth().tap(onClick = onPlay).padding(horizontal = 20.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Cover(track.artwork, Modifier.size(52.dp), radius = 12.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            T(track.title, style = Type.title, color = if (current) Ink.accent else Ink.bone, maxLines = 1)
            Spacer(Modifier.height(2.dp))
            T(track.artist, style = Type.small, color = Ink.mute, maxLines = 1)
        }
    }
}

/** Сердечко: лайк трека. Лайки уходят в аккаунт и видны на сайте. */
@Composable
fun LikeButton(g: Graph, track: Track, modifier: Modifier = Modifier) {
    val library by g.library.state.collectAsStateWithLifecycle()
    val liked = remember(library, track.id) { g.library.isLiked(track.id) }
    IconButton(
        if (liked) Glyphs.Heart else Glyphs.HeartOutline,
        if (liked) "Убрать из понравившегося" else "В понравившееся",
        { g.flash.toggleLike(track) },
        modifier,
        color = if (liked) Ink.accent else Ink.bone,
        box = 52.dp,
        dp = 26.dp,
    )
}
