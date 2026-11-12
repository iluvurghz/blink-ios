package app.blink.player.ui

import android.content.Context
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.ImageShader
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.res.ResourcesCompat
import app.blink.core.ui.ArtUrl
import app.blink.core.ui.Format
import app.blink.player.R
import coil3.request.allowHardware
import coil3.toBitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

// «Точка» и заставка с сайта (ui/dots.js, electron/screens/dotword.js): точки, кольца света, обложка из точек.

private val BONE = Color(0xFFEEE9E2)
private val HOT = Color(0xFFFFEED4)

private fun clamp01(x: Float) = x.coerceIn(0f, 1f)
private fun eo(x: Float): Float = 1f - (1f - clamp01(x)).pow(3)
private fun lerpF(a: Float, b: Float, k: Float) = a + (b - a) * k

/** Тот же шум, что на сайте: у каждой точки свой постоянный разброс размера и яркости. */
private fun hash(i: Int, j: Int): Float {
    var h = (i * 374761393 + j * 668265263) * 1274126177
    h = h xor (h ushr 13)
    h *= 1274126177
    return ((h xor (h ushr 16)).toLong() and 0xFFFFFFFFL).toFloat() / 4294967296f
}

/** Состояние Вспышки для «Точки»: спит, разгорается (собираем музыку), горит (играет). */
enum class DotPhase { Rest, Igniting, Flash }

/** Решётка: скруглённый квадрат точек, нечётное число, чтобы точка была ровно в середине; в центре значок «играть» из точек. */
private class Lattice(val s: Float, sizeDp: Float) {
    val n: Int
    val p: Float
    val xs: FloatArray
    val ys: FloatArray
    val noise: FloatArray
    val dm: FloatArray
    val icon: BooleanArray
    val ph: FloatArray
    val maxDm: Float

    init {
        val n0 = (sizeDp / 10f).roundToInt()
        n = (if (n0 % 2 == 1) n0 else n0 + 1).coerceIn(17, 49)
        p = s / n
        val c = s / 2
        val rho = s * 0.24f
        val x = ArrayList<Float>()
        val y = ArrayList<Float>()
        val nz = ArrayList<Float>()
        val d = ArrayList<Float>()
        var md = 1f
        for (j in 0 until n) for (i in 0 until n) {
            val px = (i + 0.5f) * p
            val py = (j + 0.5f) * p
            val dx = max(abs(px - c) - (s / 2 - rho), 0f)
            val dy = max(abs(py - c) - (s / 2 - rho), 0f)
            if (hypot(dx, dy) > rho - p * 0.35f) continue
            val m = abs(px - c) + abs(py - c)
            md = max(md, m)
            x += px; y += py; nz += hash(i, j); d += m
        }
        xs = x.toFloatArray(); ys = y.toFloatArray(); noise = nz.toFloatArray(); dm = d.toFloatArray()
        maxDm = md
        icon = BooleanArray(xs.size)
        ph = FloatArray(xs.size)
        val tri = arrayOf(floatArrayOf(-3.2f, -4.9f), floatArrayOf(-3.2f, 4.9f), floatArrayOf(5.1f, 0f))
        for (k in xs.indices) {
            val u = (xs[k] - c) / p - 0.47f
            val v = (ys[k] - c) / p
            var sum = 0
            for (e in 0 until 3) {
                val a = tri[e]
                val b = tri[(e + 1) % 3]
                val cr = (b[0] - a[0]) * (v - a[1]) - (b[1] - a[1]) * (u - a[0])
                sum += if (cr >= 0) 1 else -1
            }
            if (abs(sum) == 3) {
                icon[k] = true
                ph[k] = clamp01((u + 3.2f) / 8.3f)
            }
        }
    }
}

private const val REST = 0
private const val IGNITE = 1
private const val REVEAL = 2
private const val COVER = 3

/** Часы «Точки»: всё, что меняется от кадра к кадру, живёт здесь, а не в состоянии Compose. */
private class DotClock {
    var mode = REST
    var t0 = System.nanoTime()
    var fade = 1f
    var t = (Math.random() * 20).toFloat()
    var lit = false
    var phase = DotPhase.Rest
    var cover: ImageBitmap? = null
    var coverBrush: ShaderBrush? = null
    var imgReady = false
    var coverAt = 0L
    var cleared = false
    val tau: Float get() = (System.nanoTime() - t0) / 1e9f

    fun set(phase: DotPhase) {
        val lit = phase != DotPhase.Rest
        this.phase = phase
        if (lit && !this.lit) {
            mode = IGNITE
            t0 = System.nanoTime()
            imgReady = false
            cover = null
            coverBrush = null
        } else if (!lit && this.lit) {
            mode = REST
            fade = 0.1f
            t0 = System.nanoTime()
            cleared = false
        }
        this.lit = lit
    }

    /** Шаг времени; возвращает true, когда картинка собралась целиком. */
    fun step(dt: Float): Boolean {
        t += dt
        when (mode) {
            REST -> fade = min(1f, fade + dt * 4f)
            IGNITE -> if (phase == DotPhase.Flash && imgReady && tau > 0.5f) {
                mode = REVEAL
                t0 = System.nanoTime()
            }
            REVEAL -> if (tau >= 0.92f) {
                mode = COVER
                coverAt = System.nanoTime()
                return true
            }
        }
        return false
    }
}

/** Обложка квадратом ровно под размер «Точки»: через неё рисуются растущие точки. */
private suspend fun loadSquare(context: Context, url: String?, px: Int): ImageBitmap? {
    val u = Img.proxied(url?.let { ArtUrl.scaled(it, 600) }) ?: return null
    return try {
        val req = coil3.request.ImageRequest.Builder(context).data(u).size(px).allowHardware(false).build()
        val r = coil3.SingletonImageLoader.get(context).execute(req) as? coil3.request.SuccessResult ?: return null
        withContext(Dispatchers.Default) {
            val b = r.image.toBitmap()
            val side = min(b.width, b.height)
            val sq = android.graphics.Bitmap.createBitmap(b, (b.width - side) / 2, (b.height - side) / 2, side, side)
            android.graphics.Bitmap.createScaledBitmap(sq, px, px, true).asImageBitmap()
        }
    } catch (_: Exception) {
        null
    }
}

/**
 * «Точка»: квадрат из точек со значком «играть» из точек. Спит: по точкам бежит полоса света. Нажали:
 * значок вспыхивает, от него бегут кольца. Музыка пришла: точки растут от центра и сливаются в обложку.
 * Остановили: точки возвращаются. Как на сайте, 20 кадров в секунду в покое и 30 во время вспышки.
 */
@Composable
fun DotObject(
    phase: DotPhase,
    accent: Color,
    photo: String?,
    size: Dp,
    paused: Boolean,
    modifier: Modifier = Modifier,
    cover: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val density = LocalDensity.current
    val sPx = with(density) { size.toPx() }
    val lattice = remember(sPx) { Lattice(sPx, size.value) }
    val clock = remember { DotClock() }
    var frame by remember { mutableIntStateOf(0) }
    var revealed by remember { mutableStateOf(false) }
    val accentNow by rememberUpdatedState(accent)
    val coverAlpha = remember { Animatable(0f) }

    LaunchedEffect(phase) {
        clock.set(phase)
        if (phase == DotPhase.Rest) revealed = false
        frame++
    }
    val lit = phase != DotPhase.Rest
    LaunchedEffect(lit, if (lit) photo else null, sPx) {
        if (!lit) return@LaunchedEffect
        val img = loadSquare(context, photo, sPx.roundToInt().coerceAtLeast(1))
        clock.cover = img
        clock.coverBrush = img?.let { ShaderBrush(ImageShader(it, TileMode.Clamp, TileMode.Clamp)) }
        clock.imgReady = true
    }
    LaunchedEffect(revealed) {
        if (revealed) coverAlpha.animateTo(1f, tween(260)) else coverAlpha.snapTo(0f)
    }
    LaunchedEffect(paused) {
        if (paused) return@LaunchedEffect
        var last = System.nanoTime()
        while (true) {
            if (clock.mode == COVER) {
                if (!clock.cleared && System.nanoTime() - clock.coverAt > 300_000_000L) {
                    clock.cleared = true
                    frame++
                }
                delay(120)
                last = System.nanoTime()
                continue
            }
            val now = withFrameNanos { System.nanoTime() }
            val busy = clock.mode == IGNITE || clock.mode == REVEAL
            if (now - last < (if (busy) 33_000_000L else 50_000_000L)) continue
            val dt = min(0.1f, (now - last) / 1e9f)
            last = now
            if (clock.step(dt)) revealed = true
            frame++
        }
    }

    Box(modifier.size(size)) {
        Canvas(Modifier.fillMaxSize()) {
            frame.let { }
            drawDots(lattice, clock, accentNow)
        }
        if (revealed) {
            Box(
                Modifier
                    .fillMaxSize()
                    .graphicsLayer { alpha = coverAlpha.value }
                    .shadow(40.dp, RoundedCornerShape(24), ambientColor = accent, spotColor = accent)
                    .clip(RoundedCornerShape(24))
                    .background(Color(0xFF15131A))
                    .border(1.dp, Color(0x14EEE9E2), RoundedCornerShape(24)),
            ) { cover() }
        }
    }
}

private fun DrawScope.drawDots(g: Lattice, c: DotClock, accent: Color) {
    if (c.mode == COVER && c.cleared) return
    val p = g.p
    val s = g.s
    val center = Offset(s / 2, s / 2)
    // под точками мягкая тень: на сайте фон тёмный, а здесь под «Точкой» светится аура того же цвета
    drawCircle(Brush.radialGradient(listOf(Color(0x8C0B0A0D), Color(0x000B0A0D)), center, s * 0.78f), s * 0.78f, center)
    fun icon(scale: Float, heat: Float, glow: Float, alpha: Float) {
        drawCircle(
            Brush.radialGradient(listOf(accent.copy(alpha = (0.2f * glow).coerceAtMost(1f) * alpha), accent.copy(alpha = 0f)), center, s * 0.34f),
            radius = s * 0.34f,
            center = center,
        )
        for (k in g.xs.indices) {
            if (!g.icon[k]) continue
            val shimmer = 0.5f + 0.5f * sin(c.t * 2.6f - g.ph[k] * 3.4f)
            val r = p * (0.4f + 0.05f * shimmer) * scale
            drawCircle(lerp(accent, HOT, clamp01(0.3f + 0.16f * shimmer + heat)).copy(alpha = 0.96f * alpha), r, Offset(g.xs[k], g.ys[k]))
        }
    }
    when (c.mode) {
        REST -> {
            val band = ((c.t * 0.17f) % 1.7f) - 0.35f
            for (k in g.xs.indices) {
                if (g.icon[k]) continue
                val sd = (g.xs[k] + g.ys[k]) / (s * 2)
                val b = exp(-((sd - band) / 0.07f).pow(2))
                val n = g.noise[k]
                drawCircle(
                    lerp(BONE, accent, b * 0.5f).copy(alpha = ((0.2f + 0.1f * n + 0.55f * b) * c.fade).coerceIn(0f, 1f)),
                    (p / 10f) * (1.25f + 0.3f * n + 1.2f * b),
                    Offset(g.xs[k], g.ys[k]),
                )
            }
            icon(1f, 0f, 1f, c.fade)
        }
        IGNITE -> {
            val tau = c.tau
            val pop = exp(-((tau - 0.08f) / 0.09f).pow(2))
            val period = 1.1f
            val ringT = if (tau < 0.04f) -1f else (tau - 0.04f) % period
            val ringN = if (tau < 0.04f) 0 else floor((tau - 0.04f) / period).toInt()
            val R = if (ringT < 0) -1f else eo(ringT / 0.78f) * g.maxDm * 1.08f
            val w = g.maxDm * 0.085f
            val charge = if (ringN > 0) 1f else if (R < 0) 0f else clamp01(R / g.maxDm)
            for (k in g.xs.indices) {
                if (g.icon[k]) continue
                val d = g.dm[k]
                val ring = if (R < 0) 0f else exp(-((d - R) / w).pow(2)) * (1f - 0.45f * clamp01(R / g.maxDm))
                val swept = if (ringN > 0 || d < R) 1f else 0f
                val n = g.noise[k]
                val a = 0.2f + 0.1f * n + 0.2f * swept * charge + 0.7f * ring
                drawCircle(
                    lerp(lerp(BONE, accent, 0.55f * swept), HOT, ring * 0.8f).copy(alpha = min(1f, a)),
                    (p / 10f) * (1.25f + 0.3f * n + 0.4f * swept + 2.6f * ring),
                    Offset(g.xs[k], g.ys[k]),
                )
            }
            icon(1f + 0.9f * pop, pop * 0.8f, 1f + pop, 1f)
        }
        else -> {
            // точки растут от середины к краям, через них видно обложку, пока они малы, на ней свет
            val tr = if (c.mode == COVER) 2f else c.tau
            val rLit = p * 0.34f
            val rFull = p * 0.8f
            val brush = c.coverBrush
            val plain = lerp(accent, Color(0xFF141218), 0.55f)
            val light = lerp(accent, HOT, 0.25f)
            for (k in g.xs.indices) {
                val delay = (g.dm[k] / g.maxDm) * 0.46f
                val e = eo((tr - delay) / 0.44f)
                val r = lerpF(rLit, rFull, e)
                val o = Offset(g.xs[k], g.ys[k])
                if (brush != null) drawCircle(brush, r, o) else drawCircle(plain, r, o)
                val b = min(5f, floor(e * 5.999f))
                val la = 0.85f * (1f - (b + 0.5f) / 6f)
                drawCircle(light.copy(alpha = la), r, o)
            }
        }
    }
}

/** Ход трека точками, как на сайте: пройденные светлые, текущая точка Blink с ореолом. Нажать или вести пальцем: перемотка. */
@Composable
fun DotProgress(positionMs: Long, durationMs: Long, accent: Color, onSeek: (Long) -> Unit, modifier: Modifier = Modifier) {
    var drag by remember { mutableStateOf<Float?>(null) }
    val duration = durationMs.coerceAtLeast(0)
    val fraction = drag ?: if (duration > 0) (positionMs.toFloat() / duration).coerceIn(0f, 1f) else 0f
    val seek by rememberUpdatedState(onSeek)
    val dur by rememberUpdatedState(duration)
    val label = Type.small.copy(fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        T(Format.duration(((fraction * duration) / 1000).toInt()), Modifier.width(40.dp), label, BONE.copy(alpha = 0.6f), 1, TextAlign.Start)
        BoxWithConstraints(Modifier.weight(1f).height(22.dp)) {
            val wDp = maxWidth.value
            val count = floor(wDp / 7.2f).toInt().coerceIn(24, 90)
            Canvas(
                Modifier
                    .fillMaxSize()
                    .semantics { contentDescription = "Ход трека" }
                    .pointerInput(Unit) {
                        val pad = 6.dp.toPx()
                        fun at(x: Float): Float = ((x - pad) / max(1f, size.width - pad * 2)).coerceIn(0f, 1f)
                        detectTapGestures { o -> if (dur > 0) seek((at(o.x) * dur).toLong()) }
                    }
                    .pointerInput(Unit) {
                        val pad = 6.dp.toPx()
                        fun at(x: Float): Float = ((x - pad) / max(1f, size.width - pad * 2)).coerceIn(0f, 1f)
                        detectHorizontalDragGestures(
                            onDragStart = { o -> drag = at(o.x) },
                            onDragEnd = {
                                val f = drag
                                drag = null
                                if (f != null && dur > 0) seek((f * dur).toLong())
                            },
                            onDragCancel = { drag = null },
                        ) { change, _ -> drag = at(change.position.x) }
                    },
            ) {
                val pad = 6.dp.toPx()
                val step = (size.width - pad * 2) / (count - 1)
                val idx = (fraction * (count - 1)).roundToInt()
                val cy = size.height / 2
                for (i in 0 until count) {
                    if (i == idx) continue
                    val played = i < idx
                    drawCircle(BONE.copy(alpha = if (played) 0.92f else 0.24f), (if (played) 1.7f else 1.5f).dp.toPx(), Offset(pad + i * step, cy))
                }
                val x = pad + idx * step
                drawCircle(accent.copy(alpha = 0.22f), 8.dp.toPx(), Offset(x, cy))
                drawCircle(accent, 4.4.dp.toPx(), Offset(x, cy))
            }
        }
        T(Format.duration((duration / 1000).toInt()), Modifier.width(40.dp), label, BONE.copy(alpha = 0.6f), 1, TextAlign.End)
    }
}

/** Большая кнопка «играть» сайта (.iris.big на главной): круг цвета обложки, кольцо 8 dp и свечение снизу. */
@Composable
fun IrisButton(playing: Boolean, buffering: Boolean, accent: Color, ink: Color, size: Dp = 78.dp, onClick: () -> Unit) {
    Box(
        Modifier
            .size(size)
            .drawBehind {
                // свечение: 0 18px 44px -10px цветом обложки
                drawCircle(
                    Brush.radialGradient(listOf(accent.copy(alpha = 0.55f), accent.copy(alpha = 0f)), Offset(this.size.width / 2, this.size.height / 2 + 18.dp.toPx()), this.size.width * 0.78f),
                    radius = this.size.width * 0.78f,
                    center = Offset(this.size.width / 2, this.size.height / 2 + 18.dp.toPx()),
                )
                drawCircle(accent.copy(alpha = 0.18f), this.size.width / 2 + 8.dp.toPx())
            }
            .clip(CircleShape)
            .background(accent)
            .semantics { contentDescription = if (playing) "Пауза" else "Играть" }
            .pressTap(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        if (buffering) Spinner(color = ink, dp = size * 0.5f)
        else LineIcon(if (playing) LineIcons.Pause else LineIcons.Play, color = ink, dp = size * 0.36f, stroke = 2.2f)
    }
}

/** Круглая кнопка без фона (.hm-b): 50 dp, светлая, выбранная цвета обложки. */
@Composable
fun BareButton(icon: LineIcons, label: String, iconDp: Dp, on: Boolean = false, accent: Color = Ink.accent, onClick: () -> Unit) {
    Box(
        Modifier.size(50.dp).clip(CircleShape).semantics { contentDescription = label }.pressTap(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { LineIcon(icon, color = if (on) accent else BONE, dp = iconDp) }
}

// ---------------------------------------------------------------- заставка

/** Решётка заставки: поле точек на весь экран и слово «blink» из точек, точка Blink справа от слова. */
private class WordField(context: Context, val w: Float, val h: Float, val dens: Float) {
    val pitch: Float
    val px: Float
    val py: Float
    val dotR: Float
    val far: Float
    val wx: FloatArray
    val wy: FloatArray
    val wcov: FloatArray
    val wdm: FloatArray
    val dim: ImageBitmap
    val lit: ImageBitmap
    val hot: ImageBitmap

    init {
        val wDp = w / dens
        val hDp = h / dens
        pitch = max(5.5f, sqrt(wDp * hDp / 9000f)) * dens
        val cols = kotlin.math.ceil(w / pitch).toInt()
        val rows = kotlin.math.ceil(h / pitch).toInt()
        val fs = min(w * 0.78f / 3.2f, h * 0.3f)
        val cx = w / 2
        val cy = h * 0.46f
        val small = android.graphics.Bitmap.createBitmap(cols, rows, android.graphics.Bitmap.Config.ARGB_8888)
        val sc = android.graphics.Canvas(small)
        sc.drawColor(android.graphics.Color.BLACK)
        val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            color = android.graphics.Color.WHITE
            typeface = ResourcesCompat.getFont(context, R.font.unbounded_semibold) ?: android.graphics.Typeface.DEFAULT_BOLD
            textSize = fs / pitch
            letterSpacing = -0.04f
        }
        val m = paint.measureText("blink")
        dotR = fs * 0.1f
        val x0 = (cols - (m + dotR * 3.4f / pitch)) / 2
        val base = cy / pitch + fs * 0.36f / pitch
        sc.drawText("blink", x0, base, paint)
        val data = IntArray(cols * rows)
        small.getPixels(data, 0, cols, 0, 0, cols, rows)
        px = (x0 + m) * pitch + dotR * 1.9f
        py = (base - fs * 0.09f / pitch) * pitch
        far = max(px, w - px) + max(py, h - py)
        val wxs = ArrayList<Float>(); val wys = ArrayList<Float>(); val wc = ArrayList<Float>(); val wd = ArrayList<Float>()
        val lx = ArrayList<Float>(); val ly = ArrayList<Float>(); val ln = ArrayList<Float>(); val lv = ArrayList<Float>()
        val diag = hypot(w, h)
        for (j in 0 until rows) for (i in 0 until cols) {
            val x = (i + 0.5f) * pitch
            val y = (j + 0.5f) * pitch
            val cov = (data[j * cols + i] and 0xFF) / 255f
            val dm = abs(x - px) + abs(y - py)
            val n = hash(i, j)
            val vig = 1f - clamp01((hypot(x - cx, y - cy) / diag - 0.18f) / 0.32f)
            if (cov > 0.3f) { wxs += x; wys += y; wc += cov; wd += dm } else { lx += x; ly += y; ln += n; lv += vig }
        }
        wx = wxs.toFloatArray(); wy = wys.toFloatArray(); wcov = wc.toFloatArray(); wdm = wd.toFloatArray()
        // три неподвижных слоя (тусклый, зажжённый, раскалённый) рисуются один раз, кадр это несколько картинок
        val k = min(2f, dens) / dens
        val bw = (w * k).roundToInt().coerceAtLeast(1)
        val bh = (h * k).roundToInt().coerceAtLeast(1)
        fun layer(r: Float, color: Color, alphaOf: (Float, Float) -> Float): ImageBitmap {
            val bmp = android.graphics.Bitmap.createBitmap(bw, bh, android.graphics.Bitmap.Config.ARGB_8888)
            val cv = android.graphics.Canvas(bmp)
            cv.scale(k, k)
            val pt = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
            for (q in lx.indices) {
                val a = alphaOf(ln[q], lv[q])
                if (a < 0.01f) continue
                pt.color = android.graphics.Color.argb((a * 255).roundToInt().coerceIn(0, 255), (color.red * 255).roundToInt(), (color.green * 255).roundToInt(), (color.blue * 255).roundToInt())
                cv.drawCircle(lx[q], ly[q], r * (0.8f + 0.5f * ln[q]), pt)
            }
            return bmp.asImageBitmap()
        }
        dim = layer(pitch * 0.15f, BONE) { n, v -> (0.12f + 0.07f * n) * (0.15f + 0.85f * v) }
        lit = layer(pitch * 0.2f, lerp(BONE, Ink.accent, 0.6f)) { n, v -> (0.26f + 0.1f * n) * (0.15f + 0.85f * v) }
        hot = layer(pitch * 0.3f, HOT) { _, v -> 0.95f * (0.35f + 0.65f * v) }
    }

    fun diamond(path: Path, r: Float) {
        path.moveTo(px - r, py)
        path.lineTo(px, py - r)
        path.lineTo(px + r, py)
        path.lineTo(px, py + r)
        path.close()
    }
}

private fun DrawScope.drawWord(f: WordField, t: Float, flood: Float) {
    val full = IntSize(size.width.roundToInt(), size.height.roundToInt())
    drawImage(f.dim, dstSize = full)
    val ring = clamp01((t - 0.3f) / 0.62f)
    val R = eo(ring) * f.far * 1.12f
    if (t > 0.3f) {
        // внутри кольца точки горят, на самом кольце раскалены
        val inside = Path().also { f.diamond(it, R) }
        clipPath(inside) { drawImage(f.lit, dstSize = full, alpha = 0.9f) }
        if (ring < 1f) {
            val band = Path().also {
                it.fillType = PathFillType.EvenOdd
                f.diamond(it, R)
                f.diamond(it, max(0f, R - f.far * 0.07f))
            }
            clipPath(band) { drawImage(f.hot, dstSize = full, alpha = 1f - ring * 0.6f) }
        }
    }
    // буквы вырастают из точек, когда по ним проходит кольцо
    for (k in f.wx.indices) {
        val q = clamp01((R - f.wdm[k]) / (f.far * 0.1f))
        val e = eo(q)
        val r = f.pitch * 0.5f * (0.2f + 0.78f * e) * min(1f, f.wcov[k] * 1.2f) * (1f + 0.3f * flood)
        if (r < 0.3f) continue
        drawCircle(lerp(lerp(BONE, HOT, (1f - q) * 0.7f), HOT, flood).copy(alpha = 0.2f + 0.8f * e), r, Offset(f.wx[k], f.wy[k]))
    }
    // точка: сперва выскакивает, потом моргает, пока ждём
    val pop = eo(t / 0.3f)
    val bl = if (t > 1.1f) {
        val ph = ((t - 1.1f) % 2.4f) / 2.4f
        if (ph < 0.05f) 1f - 0.85f * sin(ph / 0.05f * Math.PI.toFloat()) else 1f
    } else 1f
    val r = f.dotR * (0.3f + 0.7f * pop) * (1f + 0.12f * flood)
    val o = Offset(f.px, f.py)
    drawCircle(Brush.radialGradient(listOf(Ink.accent.copy(alpha = 0.45f + 0.4f * flood), Ink.accent.copy(alpha = 0f)), o, r * 5), r * 5, o)
    drawOval(
        lerp(Ink.accent, HOT, flood * 0.8f),
        topLeft = Offset(f.px - r, f.py - max(0.5f, r * bl)),
        size = Size(r * 2, max(0.5f, r * bl) * 2),
    )
    if (flood > 0f) drawImage(f.hot, dstSize = full, alpha = flood * 0.9f)
}

/**
 * Заставка при запуске, как в приложении на сайте: из точки Blink бежит ромбическое кольцо света по полю точек,
 * буквы «blink» вырастают из точек, точка моргает; через 1,15 с всё вспыхивает светом и заставка уходит.
 * `freezeAt` держит один кадр (снимки экрана для отчёта).
 */
@Composable
fun DotIntro(onDone: () -> Unit, freezeAt: Float? = null) {
    val context = LocalContext.current
    val done by rememberUpdatedState(onDone)
    val fadeOut = remember { Animatable(1f) }
    var t by remember { mutableFloatStateOf(freezeAt ?: 0f) }
    var flood by remember { mutableFloatStateOf(0f) }
    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .graphicsLayer { alpha = fadeOut.value }
            .background(Ink.ink)
            .pointerInput(Unit) { detectTapGestures { } }
            .semantics { contentDescription = "Заставка Blink" },
    ) {
        val dens = LocalDensity.current.density
        val w = constraints.maxWidth.toFloat()
        val h = constraints.maxHeight.toFloat()
        var field by remember { mutableStateOf<WordField?>(null) }
        LaunchedEffect(w, h) {
            field = withContext(Dispatchers.Default) { WordField(context, w, h, dens) }
            if (freezeAt != null) return@LaunchedEffect
            val start = System.nanoTime()
            var floodAt = 0L
            while (true) {
                val now = withFrameNanos { System.nanoTime() }
                t = (now - start) / 1e9f
                if (floodAt == 0L && t >= 1.15f) floodAt = now
                if (floodAt != 0L) {
                    flood = eo((now - floodAt) / 220e6f)
                    if (now - floodAt >= 220_000_000L) break
                }
            }
            fadeOut.animateTo(0f, tween(320))
            done()
        }
        Canvas(Modifier.fillMaxSize()) {
            val f = field ?: return@Canvas
            drawWord(f, t, flood)
        }
    }
}
