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

    Box(Modifier.fillMaxSize()) {
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = 190.dp),
    ) {
        item(key = "hero") { FlashHero(g, Modifier.fillParentMaxHeight()) }
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
 * Главный экран Вспышки на всю высоту, как «Моя волна», но в стиле Blink: живой свет цветов обложки,
 * большое «Вспышка.», светящаяся кнопка. Когда играет: артист крупно, обложка, пауза, плашка трека с ходом и сердце.
 * Внизу режимы потока пузырями.
 */
@Composable
private fun FlashHero(g: Graph, modifier: Modifier) {
    val active by g.flash.active.collectAsStateWithLifecycle()
    val loading by g.flash.loading.collectAsStateWithLifecycle()
    val mode by g.flash.mode.collectAsStateWithLifecycle()
    val player by g.player.state.collectAsStateWithLifecycle()
    val palette by g.stage.palette.collectAsStateWithLifecycle()
    val library by g.library.state.collectAsStateWithLifecycle()
    val accent by animateColorAsState(palette.accent.color(), tween(1200), label = "heroAccent")
    val ink = palette.accentInk.color()
    val track = player.track
    val flashing = active && track != null
    val liked = remember(library, track?.id) { track != null && g.library.isLiked(track.id) }
    val hint = remember(library) {
        val names = favouriteArtists(g.library.likes).take(3).map { it.first }
        if (names.isEmpty()) "Слушайте и ставьте лайки, и поток подстроится под вас" else names.joinToString(", ") + " и похожее на них"
    }

    Box(modifier.fillMaxWidth()) {
        val playerOpen by g.nav.playerOpen.collectAsStateWithLifecycle()
        FlashAura(palette, if (player.playing) 1f else 0.35f, paused = playerOpen)
        Column(
            Modifier.fillMaxSize().statusBarsPadding().padding(top = 10.dp, bottom = 96.dp).navigationBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // сверху: знак Blink, а пока играет Вспышка: плашка режима с крестиком
            Box(Modifier.height(48.dp), contentAlignment = Alignment.Center) {
                if (flashing) {
                    Row(
                        Modifier.height(44.dp).clip(CircleShape).background(Color(0x40000000)).border(1.dp, Color(0x1CFFFFFF), CircleShape).padding(start = 18.dp, end = 5.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        T("Вспышка · " + mode.title, style = Type.button.copy(fontSize = 15.sp), color = accent, maxLines = 1)
                        Spacer(Modifier.width(8.dp))
                        Box(
                            Modifier.size(34.dp).clip(CircleShape).background(accent).semantics { contentDescription = "Остановить Вспышку" }.pressTap { g.flash.stop() },
                            contentAlignment = Alignment.Center,
                        ) { LineIcon(LineIcons.Close, color = ink, dp = 16.dp, stroke = 2.4f) }
                    }
                } else {
                    Row(verticalAlignment = Alignment.Bottom) {
                        T("blink", style = Type.h2.copy(fontSize = 20.sp, letterSpacing = (-0.6).sp), color = Ink.bone)
                        Box(Modifier.padding(start = 2.dp, bottom = 5.dp).size(6.dp).clip(CircleShape).background(accent))
                    }
                }
            }
            Spacer(Modifier.weight(1f))
            if (flashing && track != null) {
                T(
                    track.artist,
                    Modifier.padding(horizontal = 20.dp),
                    Type.display.copy(fontSize = 40.sp, lineHeight = 42.sp, letterSpacing = (-1.8).sp),
                    maxLines = 2,
                    align = TextAlign.Center,
                )
                Spacer(Modifier.height(26.dp))
                var dx by remember { mutableStateOf(0f) }
                Box(
                    Modifier
                        .size(148.dp)
                        .graphicsLayer { translationX = dx * 0.35f }
                        .shadow(36.dp, RoundedCornerShape(26.dp), ambientColor = accent, spotColor = accent)
                        .clip(RoundedCornerShape(26.dp))
                        .pointerInput(track.id) {
                            detectHorizontalDragGestures(
                                onDragEnd = {
                                    if (dx < -90f) g.player.next() else if (dx > 90f) g.player.previous()
                                    dx = 0f
                                },
                                onDragCancel = { dx = 0f },
                            ) { _, d -> dx += d }
                        }
                        .semantics { contentDescription = "Открыть плеер" }
                        .tap { g.nav.openPlayer(true) },
                ) { NetImage(ArtUrl.scaled(track.artwork, 400), Modifier.fillMaxSize()) }
                Spacer(Modifier.height(26.dp))
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                    RoundGlass(if (player.playing) LineIcons.Pause else LineIcons.Play, if (player.playing) "Пауза" else "Играть") { g.player.toggle() }
                    Spacer(Modifier.width(8.dp))
                    val fraction = if (player.durationMs > 0) (player.positionMs.toFloat() / player.durationMs).coerceIn(0f, 1f) else 0f
                    Box(
                        Modifier
                            .weight(1f)
                            .height(64.dp)
                            .clip(CircleShape)
                            .background(Color(0x33000000))
                            .drawBehind { drawRect(accent.copy(alpha = 0.3f), size = androidx.compose.ui.geometry.Size(size.width * fraction, size.height)) }
                            .border(1.dp, Color(0x1AFFFFFF), CircleShape)
                            .tap { g.nav.openPlayer(true) }
                            .padding(horizontal = 18.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        T(track.title, style = Type.title.copy(fontSize = 17.sp, fontWeight = FontWeight.Bold), maxLines = 1, align = TextAlign.Center)
                    }
                    Spacer(Modifier.width(8.dp))
                    RoundGlass(if (liked) LineIcons.HeartFill else LineIcons.Heart, "Любимое", on = liked, accent = accent) { g.flash.toggleLike(track) }
                }
                Spacer(Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                    QuietAction(LineIcons.ThumbDown, "Не моё") { g.flash.dislike(track) }
                    QuietAction(LineIcons.Next, "Дальше") { g.player.next() }
                }
            } else {
                Row(verticalAlignment = Alignment.Bottom) {
                    T("Вспышка", style = Type.display.copy(fontSize = 56.sp, lineHeight = 56.sp, letterSpacing = (-3).sp), color = Ink.bone, maxLines = 1)
                    Box(Modifier.padding(start = 4.dp, bottom = 9.dp).size(10.dp).clip(CircleShape).background(accent))
                }
                Spacer(Modifier.height(26.dp))
                Box(
                    Modifier
                        .size(112.dp)
                        .shadow(44.dp, CircleShape, ambientColor = accent, spotColor = accent)
                        .clip(CircleShape)
                        .background(accent)
                        .semantics { contentDescription = "Включить Вспышку" }
                        .pressTap(!loading) { g.flash.start() },
                    contentAlignment = Alignment.Center,
                ) {
                    if (loading) Spinner(color = ink, dp = 48.dp) else LineIcon(LineIcons.Play, color = ink, dp = 46.dp, stroke = 2.2f)
                }
                Spacer(Modifier.height(26.dp))
                if (track != null) {
                    Row(
                        Modifier.padding(horizontal = 24.dp).fillMaxWidth().height(60.dp).clip(CircleShape).background(Color(0x40000000)).border(1.dp, Color(0x1AFFFFFF), CircleShape)
                            .tap { g.nav.openPlayer(true) }.padding(start = 22.dp, end = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        T("${track.artist} — ${track.title}", Modifier.weight(1f), Type.title.copy(fontWeight = FontWeight.Bold, fontSize = 16.sp), maxLines = 1, align = TextAlign.Center)
                        StageIcon(if (liked) LineIcons.HeartFill else LineIcons.Heart, "Любимое", { g.flash.toggleLike(track) }, dp = 24.dp, box = 48.dp, on = liked, accent = accent)
                    }
                    Spacer(Modifier.height(18.dp))
                }
                T(
                    if (loading) "Подбираю музыку…" else hint,
                    Modifier.padding(horizontal = 36.dp),
                    Type.body.copy(fontSize = 16.sp, lineHeight = 21.sp, fontWeight = FontWeight.SemiBold),
                    Ink.bone.copy(alpha = 0.85f),
                    maxLines = 2,
                    align = TextAlign.Center,
                )
            }
            Spacer(Modifier.weight(1f))
            ModeBubbles(palette, mode) { m ->
                g.flash.setMode(m)
                if (!active && !loading) g.flash.start()
            }
        }
    }
}

@Composable
private fun RoundGlass(icon: LineIcons, label: String, on: Boolean = false, accent: Color = Ink.accent, onClick: () -> Unit) {
    Box(
        Modifier.size(64.dp).clip(CircleShape).background(Color(0x33000000)).border(1.dp, Color(0x1AFFFFFF), CircleShape)
            .semantics { contentDescription = label }.pressTap(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { LineIcon(icon, color = if (on) accent else Ink.bone, dp = 26.dp) }
}

@Composable
private fun QuietAction(icon: LineIcons, label: String, onClick: () -> Unit) {
    Row(
        Modifier.clip(CircleShape).semantics { contentDescription = label }.pressTap(onClick = onClick).padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        LineIcon(icon, color = Ink.bone.copy(alpha = 0.7f), dp = 18.dp)
        Spacer(Modifier.width(6.dp))
        T(label, style = Type.button.copy(fontSize = 13.sp), color = Ink.bone.copy(alpha = 0.7f), maxLines = 1)
    }
}

/** Режимы потока пузырями внизу экрана: у каждого свой цвет из палитры, выбранный ярче и с точкой. */
@Composable
private fun ModeBubbles(palette: app.blink.core.ui.Palette, mode: WaveMode, onPick: (WaveMode) -> Unit) {
    val hues = listOf(palette.accent, palette.glowB, palette.glowA, palette.glowC)
    val icons = listOf(LineIcons.Bolt, LineIcons.Heart, LineIcons.Search, LineIcons.Plus)
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        WaveMode.entries.forEachIndexed { i, m ->
            val on = m == mode
            val c = hues[i % hues.size].vivid(0.5).color()
            val shape = RoundedCornerShape(topStartPercent = 50, topEndPercent = 50, bottomStartPercent = 22, bottomEndPercent = 22)
            Column(
                Modifier
                    .width(118.dp)
                    .height(112.dp)
                    .clip(shape)
                    .background(Brush.verticalGradient(listOf(c.copy(alpha = if (on) 0.95f else 0.55f), c.copy(alpha = if (on) 0.35f else 0.12f))))
                    .border(if (on) 1.5.dp else 1.dp, if (on) Color(0x66FFFFFF) else Color(0x14FFFFFF), shape)
                    .semantics { contentDescription = "Режим ${m.title}"; selected = on }
                    .pressTap { onPick(m) }
                    .padding(top = 24.dp, bottom = 14.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                LineIcon(icons[i % icons.size], color = Ink.bone.copy(alpha = if (on) 1f else 0.75f), dp = 24.dp)
                Spacer(Modifier.weight(1f))
                T(m.title, style = Type.button.copy(fontSize = 14.sp), color = Ink.bone.copy(alpha = if (on) 1f else 0.8f), maxLines = 1)
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
