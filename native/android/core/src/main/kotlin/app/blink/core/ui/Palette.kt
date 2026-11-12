package app.blink.core.ui

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/** Цвет в HSL: оттенок 0…360, насыщенность и светлота 0…1. */
data class Hsl(val h: Double, val s: Double, val l: Double) {
    /** ARGB, как CSS `hsl()`. */
    fun argb(alpha: Double = 1.0): Int {
        val c = (1 - abs(2 * l - 1)) * s
        val hh = ((h % 360) + 360) % 360 / 60
        val x = c * (1 - abs(hh % 2 - 1))
        val m = l - c / 2
        val (r, g, b) = when {
            hh < 1 -> Triple(c, x, 0.0)
            hh < 2 -> Triple(x, c, 0.0)
            hh < 3 -> Triple(0.0, c, x)
            hh < 4 -> Triple(0.0, x, c)
            hh < 5 -> Triple(x, 0.0, c)
            else -> Triple(c, 0.0, x)
        }
        fun ch(v: Double) = ((v + m) * 255).roundToInt().coerceIn(0, 255)
        return ((alpha * 255).roundToInt().coerceIn(0, 255) shl 24) or (ch(r) shl 16) or (ch(g) shl 8) or ch(b)
    }
}

/** Палитра из обложки: акцент и три свечения (lib/color.js `paletteFor`). Всё окно берёт свет от трека. */
data class Palette(val accent: Hsl, val accentInk: Hsl, val glowA: Hsl, val glowB: Hsl, val glowC: Hsl) {
    companion object {
        val FALLBACK = Palette(Hsl(18.0, 0.92, 0.64), Hsl(18.0, 0.6, 0.1), Hsl(18.0, 0.7, 0.38), Hsl(352.0, 0.48, 0.28), Hsl(24.0, 0.42, 0.19))

        internal fun toHsl(r0: Int, g0: Int, b0: Int): Hsl {
            val r = r0 / 255.0
            val g = g0 / 255.0
            val b = b0 / 255.0
            val mx = max(r, max(g, b))
            val mn = min(r, min(g, b))
            var h = 0.0
            var s = 0.0
            val l = (mx + mn) / 2
            if (mx != mn) {
                val d = mx - mn
                s = if (l > 0.5) d / (2 - mx - mn) else d / (mx + mn)
                h = when (mx) {
                    r -> (g - b) / d + (if (g < b) 6 else 0)
                    g -> (b - r) / d + 2
                    else -> (r - g) / d + 4
                }
                h *= 60
            }
            return Hsl(h, s, l)
        }

        private class B {
            var n = 0
            var hx = 0.0
            var hy = 0.0
            var s = 0.0
            var l = 0.0
        }

        private data class G(val neutral: Boolean, val n: Int, val h: Double, val s: Double, val l: Double)

        /** Пиксели ARGB (обложка, уменьшенная до 24×24) → палитра. */
        fun fromArgb(px: IntArray): Palette {
            if (px.isEmpty()) return FALLBACK
            val buckets = LinkedHashMap<String, B>()
            for (p in px) {
                val c = toHsl((p shr 16) and 0xff, (p shr 8) and 0xff, p and 0xff)
                // Math.round в JS округляет .5 вверх: так же и здесь.
                val key = if (c.s < 0.12) "n" + Math.floor(c.l * 4 + 0.5).toInt() else (Math.floor(c.h / 24 + 0.5).toInt() % 15).toString()
                val b = buckets.getOrPut(key) { B() }
                b.n++
                b.hx += cos(c.h * Math.PI / 180)
                b.hy += sin(c.h * Math.PI / 180)
                b.s += c.s
                b.l += c.l
            }
            val groups = buckets.map { (k, b) ->
                var h = atan2(b.hy, b.hx) * 180 / Math.PI
                if (h < 0) h += 360
                G(k.startsWith("n"), b.n, h, b.s / b.n, b.l / b.n)
            }
            val chroma = groups.filter { !it.neutral }.sortedByDescending { it.n * (0.3 + it.s) }
            if (chroma.isEmpty() || chroma[0].n < 8) {
                val top = groups.maxByOrNull { it.n }
                return Palette(
                    Hsl(36.0, 0.2, 0.82),
                    Hsl(36.0, 0.1, 0.1),
                    Hsl(30.0, 0.08, min(0.32, 0.12 + (top?.l?.times(0.2) ?: 0.1))),
                    Hsl(250.0, 0.08, 0.2),
                    Hsl(30.0, 0.06, 0.16),
                )
            }
            val a = chroma[0]
            val b = chroma.getOrNull(1) ?: a.copy(h = (a.h + 40) % 360)
            val c = chroma.getOrNull(2) ?: a.copy(h = (a.h + 300) % 360)
            return Palette(
                Hsl(a.h, max(0.55, min(0.95, a.s + 0.25)), 0.66),
                Hsl(a.h, 0.6, 0.1),
                Hsl(a.h, min(0.75, a.s + 0.15), 0.36),
                Hsl(b.h, min(0.7, b.s + 0.1), 0.3),
                Hsl(c.h, min(0.6, c.s + 0.05), 0.24),
            )
        }
    }
}

/** Размер обложки в адресе: iTunes `/NNNxNNNbb.jpg`, Яндекс `/NNNxNNN`, SoundCloud `-large`/`-t500x500`. */
object ArtUrl {
    private val ITUNES = Regex("""/\d+x\d+bb\.jpg$""")
    private val YANDEX = Regex("""/\d+x\d+$""")
    private val SC = Regex("""-(?:large|badge|small|tiny|mini|crop|original|t\d+x\d+)\.(jpe?g|png|webp)(?=$|[?#])""", RegexOption.IGNORE_CASE)

    fun scaled(url: String, size: Int): String = when {
        url.isEmpty() -> url
        ITUNES.containsMatchIn(url) -> ITUNES.replace(url, "/${size}x${size}bb.jpg")
        YANDEX.containsMatchIn(url) -> YANDEX.replace(url, "/${size}x$size")
        SC.containsMatchIn(url) -> SC.replace(url) { m -> (if (size <= 150) "-t300x300." else "-t500x500.") + m.groupValues[1] }
        else -> url
    }
}
