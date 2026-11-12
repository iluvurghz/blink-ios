package app.blink.player.ui

import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.blink.core.lyrics.ArtistPhotos
import app.blink.core.lyrics.LyricsApi
import app.blink.core.lyrics.LyricsData
import app.blink.core.model.Track
import app.blink.core.net.BlinkConfig
import app.blink.core.ui.ArtUrl
import app.blink.core.ui.Hsl
import app.blink.core.ui.Palette
import coil3.compose.AsyncImage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request

/** Значок сайта (ui/Icon.jsx): обводка 1.75 при размере 24, круглые концы, местами заливка. */
@Composable
fun LineIcon(icon: LineIcons, modifier: Modifier = Modifier, color: Color = Ink.bone, dp: Dp = 24.dp, stroke: Float = 1.75f) {
    val paths = remember(icon) { icon.parts.map { PathParser().parsePathString(it.d).toPath() to it.fill } }
    Canvas(modifier.size(dp)) {
        val k = size.minDimension / 24f
        scale(k, Offset.Zero) {
            for ((p, fill) in paths) {
                if (fill) {
                    drawPath(p, color)
                } else {
                    drawPath(p, color, style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round))
                }
            }
        }
    }
}

fun Hsl.color(alpha: Float = 1f): Color = Color(argb(alpha.toDouble()))

/** `color-mix(in srgb, this pct%, other)`, как в CSS, с учётом прозрачности второго цвета. */
fun Hsl.mix(pct: Float, other: Color): Color {
    val c = Color(argb())
    val a = pct + other.alpha * (1 - pct)
    if (a <= 0f) return Color.Transparent
    fun ch(x: Float, y: Float) = (x * pct + y * other.alpha * (1 - pct)) / a
    return Color(ch(c.red, other.red), ch(c.green, other.green), ch(c.blue, other.blue), a)
}

/** Обложки с медленных хостов идут через сервер Blink (lib/img.js `proxied`). */
object Img {
    private val VIA = Regex("""^https://(lh\d\.googleusercontent\.com|([a-z0-9-]+\.)?mzstatic\.com|([a-z0-9-]+\.)?dzcdn\.net|([a-z0-9-]+\.)?sndcdn\.com|avatars\.yandex\.net)/""", RegexOption.IGNORE_CASE)
    var base = "https://blinkmusic.cc"

    fun proxied(url: String?): String? {
        if (url.isNullOrEmpty() || !VIA.containsMatchIn(url)) return url
        return "$base/api/img?u=" + java.net.URLEncoder.encode(url, "UTF-8")
    }
}

sealed class LyricsState {
    object Loading : LyricsState()
    object Failed : LyricsState()
    object None : LyricsState()
    data class Data(val data: LyricsData) : LyricsState()
}

sealed class TrState {
    object Off : TrState()
    object Loading : TrState()
    data class On(val map: Map<String, String>) : TrState()
    object Native : TrState()
    object Error : TrState()
}

/** Всё, что плеер берёт от текущего трека: палитра из обложки, текст песни, перевод, фото артиста. */
class StageModel(
    private val http: OkHttpClient,
    config: BlinkConfig,
    tokens: app.blink.core.net.TokenProvider?,
    private val prefs: SharedPreferences,
    private val scope: CoroutineScope,
) {
    private val api = LyricsApi(http, config, tokens)
    private val photos = ArtistPhotos(http, config)
    private val paletteFlow = MutableStateFlow(Palette.FALLBACK)
    val palette: StateFlow<Palette> = paletteFlow.asStateFlow()
    private val lyricsFlow = MutableStateFlow<LyricsState>(LyricsState.Loading)
    val lyrics: StateFlow<LyricsState> = lyricsFlow.asStateFlow()
    private val photoFlow = MutableStateFlow<String?>(null)
    val photo: StateFlow<String?> = photoFlow.asStateFlow()
    private val trFlow = MutableStateFlow<TrState>(TrState.Off)
    val tr: StateFlow<TrState> = trFlow.asStateFlow()
    private val translateFlow = MutableStateFlow(prefs.getBoolean("lyrics_tr", false))
    val translate: StateFlow<Boolean> = translateFlow.asStateFlow()

    private var track: Track? = null
    private val jobs = ArrayList<Job>()
    private val paletteCache = HashMap<String, Palette>()

    init {
        Img.base = config.base
    }

    fun hasLyrics(s: LyricsState = lyricsFlow.value): Boolean = s is LyricsState.Data && s.data != LyricsData.Instrumental

    @Synchronized
    fun trackChanged(next: Track?) {
        if (next?.id == track?.id) return
        track = next
        jobs.forEach { it.cancel() }
        jobs.clear()
        photoFlow.value = null
        trFlow.value = TrState.Off
        val t = next ?: run {
            lyricsFlow.value = LyricsState.Loading
            return
        }
        loadLyrics(t)
        val art = t.artwork
        val hit = synchronized(paletteCache) { paletteCache[art] }
        if (hit != null) {
            paletteFlow.value = hit
        } else {
            jobs += scope.launch(Dispatchers.IO) {
                val p = palette(art)
                synchronized(paletteCache) { paletteCache[art] = p }
                if (track?.id == t.id) paletteFlow.value = p
            }
        }
        jobs += scope.launch(Dispatchers.IO) {
            val u = photos.photo(t)
            if (track?.id == t.id) photoFlow.value = u
        }
    }

    private val artistPhotos = HashMap<String, String?>()

    /** Фото артиста для полки «Любимые артисты»: Deezer по имени, с кэшем на сеанс. */
    suspend fun artistPhoto(t: Track): String? {
        synchronized(artistPhotos) { if (artistPhotos.containsKey(t.artist)) return artistPhotos[t.artist] }
        val u = withContext(Dispatchers.IO) {
            try {
                photos.photo(t)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                null
            }
        }
        synchronized(artistPhotos) { artistPhotos[t.artist] = u }
        return u
    }

    fun retry() {
        track?.let { loadLyrics(it) }
    }

    fun toggleTranslate() {
        translateFlow.value = !translateFlow.value
        prefs.edit().putBoolean("lyrics_tr", translateFlow.value).apply()
        refreshTranslation()
    }

    private fun loadLyrics(t: Track) {
        val (known, data) = api.cachedOrNull(t.id)
        if (known) {
            lyricsFlow.value = data?.let { LyricsState.Data(it) } ?: LyricsState.None
            refreshTranslation()
            return
        }
        lyricsFlow.value = LyricsState.Loading
        jobs += scope.launch(Dispatchers.IO) {
            val result = try {
                api.load(t)?.let { LyricsState.Data(it) } ?: LyricsState.None
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                LyricsState.Failed
            }
            if (track?.id == t.id) {
                lyricsFlow.value = result
                refreshTranslation()
            }
        }
    }

    private fun refreshTranslation() {
        val t = track
        val s = lyricsFlow.value
        if (!translateFlow.value || t == null || s !is LyricsState.Data || s.data == LyricsData.Instrumental) {
            trFlow.value = TrState.Off
            return
        }
        if (s.data.isRussian) {
            trFlow.value = TrState.Native
            return
        }
        trFlow.value = TrState.Loading
        jobs += scope.launch(Dispatchers.IO) {
            val next = try {
                val map = api.translate(t.id, s.data.texts)
                if (map.isEmpty()) TrState.Native else TrState.On(map)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                TrState.Error
            }
            if (track?.id == t.id && translateFlow.value) trFlow.value = next
        }
    }

    /** Обложка 24×24 → палитра, как canvas на сайте. */
    private suspend fun palette(url: String): Palette = withContext(Dispatchers.IO) {
        if (url.isEmpty()) return@withContext Palette.FALLBACK
        val small = ArtUrl.scaled(url, 100)
        for (candidate in listOfNotNull(Img.proxied(small), small).distinct()) {
            try {
                val res = http.newCall(Request.Builder().url(candidate).build()).execute()
                val bytes = res.use { if (it.isSuccessful) it.body?.bytes() else null } ?: continue
                val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: continue
                val s = Bitmap.createScaledBitmap(bmp, 24, 24, true)
                val px = IntArray(24 * 24)
                s.getPixels(px, 0, 24, 0, 0, 24, 24)
                return@withContext Palette.fromArgb(px)
            } catch (_: Exception) {
            }
        }
        Palette.FALLBACK
    }
}

/** Фон из обложки во весь экран: размыто, притемнено, чуть ярче цвета (.ps-bg на сайте). */
@Composable
fun BlurredCover(url: String, modifier: Modifier = Modifier) {
    val filter = remember {
        val m = ColorMatrix().apply { setToSaturation(1.25f) }
        val dim = ColorMatrix(floatArrayOf(0.42f, 0f, 0f, 0f, 0f, 0f, 0.42f, 0f, 0f, 0f, 0f, 0f, 0.42f, 0f, 0f, 0f, 0f, 0f, 1f, 0f))
        m.timesAssign(dim)
        ColorFilter.colorMatrix(m)
    }
    Box(modifier.fillMaxSize().background(Color(0xFF0B0A0D)).clipToBounds()) {
        if (url.isNotEmpty()) {
            AsyncImage(
                model = Img.proxied(ArtUrl.scaled(url, 600)),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                colorFilter = filter,
                modifier = Modifier.fillMaxSize().graphicsLayer { scaleX = 1.15f; scaleY = 1.15f }.blur(30.dp),
            )
        }
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0f to Color(0x9908070A),
                    0.18f to Color(0x0D08070A),
                    0.42f to Color(0x0008070A),
                    0.64f to Color(0xC708070A),
                    1f to Color(0xF508070A),
                ),
            ),
        )
    }
}

/** Картинка по адресу с заглушкой. */
@Composable
fun NetImage(url: String?, modifier: Modifier = Modifier) {
    Box(modifier.background(Color(0x0FFFFFFF))) {
        if (!url.isNullOrEmpty()) {
            AsyncImage(model = Img.proxied(url), contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
    }
}
