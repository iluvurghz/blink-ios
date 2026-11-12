package preview

import java.io.File
import org.jetbrains.skia.Color
import org.jetbrains.skia.EncodedImageFormat
import org.jetbrains.skia.Paint
import org.jetbrains.skia.Shader
import org.jetbrains.skia.Surface

/** Условные обложки для скриншотов: тёплые двухцветные композиции в палитре Blink. Настоящих обложек в репозитории нет. */
object Covers {
    private val pairs = listOf(
        0xFFF8814F.toInt() to 0xFF29130A.toInt(),
        0xFFEEE9E2.toInt() to 0xFF3A2A22.toInt(),
        0xFF4FD08A.toInt() to 0xFF0F2A1D.toInt(),
        0xFFF3BD5A.toInt() to 0xFF3A2A0C.toInt(),
        0xFFFF6B6B.toInt() to 0xFF2E1114.toInt(),
        0xFF8FB8DE.toInt() to 0xFF14212E.toInt(),
        0xFFD9A441.toInt() to 0xFF1D1A22.toInt(),
        0xFFE2725B.toInt() to 0xFF1F1613.toInt(),
        0xFFB9C4A0.toInt() to 0xFF1A2118.toInt(),
    )

    fun generate(dir: File): List<String> {
        dir.mkdirs()
        return pairs.mapIndexed { i, (light, dark) ->
            val file = File(dir, "cover-$i.png")
            val size = 600
            val surface = Surface.makeRasterN32Premul(size, size)
            val canvas = surface.canvas
            val bg = Paint().apply { shader = Shader.makeLinearGradient(0f, 0f, size.toFloat(), size.toFloat(), intArrayOf(dark, Color.makeRGB(0, 0, 0)), null) }
            canvas.drawRect(org.jetbrains.skia.Rect.makeWH(size.toFloat(), size.toFloat()), bg)
            val sun = Paint().apply { color = light }
            when (i % 3) {
                0 -> canvas.drawCircle(size * 0.62f, size * 0.42f, size * 0.26f, sun)
                1 -> canvas.drawRect(org.jetbrains.skia.Rect.makeXYWH(size * 0.18f, size * 0.22f, size * 0.64f, size * 0.12f), sun).also {
                    canvas.drawRect(org.jetbrains.skia.Rect.makeXYWH(size * 0.18f, size * 0.42f, size * 0.44f, size * 0.12f), sun)
                    canvas.drawRect(org.jetbrains.skia.Rect.makeXYWH(size * 0.18f, size * 0.62f, size * 0.54f, size * 0.12f), sun)
                }
                else -> {
                    canvas.drawCircle(size * 0.34f, size * 0.64f, size * 0.2f, sun)
                    canvas.drawCircle(size * 0.66f, size * 0.36f, size * 0.12f, sun)
                }
            }
            file.writeBytes(surface.makeImageSnapshot().encodeToData(EncodedImageFormat.PNG)!!.bytes)
            surface.close()
            file.toURI().toString()
        }
    }
}
