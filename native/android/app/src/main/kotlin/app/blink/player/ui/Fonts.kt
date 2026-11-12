package app.blink.player.ui

import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import app.blink.player.R

/** Шрифты лежат в native/design/res/font и общие с iOS. На Android берём их из ресурсов. */
val Manrope = FontFamily(
    Font(R.font.manrope_regular, FontWeight.Normal),
    Font(R.font.manrope_medium, FontWeight.Medium),
    Font(R.font.manrope_semibold, FontWeight.SemiBold),
    Font(R.font.manrope_bold, FontWeight.Bold),
    Font(R.font.manrope_extrabold, FontWeight.ExtraBold),
)

val Unbounded = FontFamily(
    Font(R.font.unbounded_light, FontWeight.Light),
    Font(R.font.unbounded_medium, FontWeight.Medium),
    Font(R.font.unbounded_semibold, FontWeight.SemiBold),
    Font(R.font.unbounded_bold, FontWeight.Bold),
)
