package app.blink.player.ui

import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.platform.Font
import java.io.File

private val dir = File(System.getProperty("blink.fonts") ?: "../../design/res/font")

val Manrope = FontFamily(
    Font(File(dir, "manrope_regular.ttf"), FontWeight.Normal),
    Font(File(dir, "manrope_medium.ttf"), FontWeight.Medium),
    Font(File(dir, "manrope_semibold.ttf"), FontWeight.SemiBold),
    Font(File(dir, "manrope_bold.ttf"), FontWeight.Bold),
    Font(File(dir, "manrope_extrabold.ttf"), FontWeight.ExtraBold),
)

val Unbounded = FontFamily(
    Font(File(dir, "unbounded_light.ttf"), FontWeight.Light),
    Font(File(dir, "unbounded_medium.ttf"), FontWeight.Medium),
    Font(File(dir, "unbounded_semibold.ttf"), FontWeight.SemiBold),
    Font(File(dir, "unbounded_bold.ttf"), FontWeight.Bold),
)
