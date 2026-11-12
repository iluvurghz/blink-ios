package app.blink.player.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/** Палитра Blink: тёмная бумага, тёплая кость и один коралловый акцент. Те же значения, что на сайте и в iOS. */
object Ink {
    val ink = Color(0xFF0D0C10)
    val ink2 = Color(0xFF15131A)
    val ink3 = Color(0xFF1D1A22)
    val bone = Color(0xFFEEE9E2)
    val mute = Color(0xFFA8A3B0)
    val faint = Color(0xFF857F90)
    val accent = Color(0xFFF8814F)
    val accentInk = Color(0xFF29130A)
    val danger = Color(0xFFFF6B6B)
    val good = Color(0xFF4FD08A)
    val warn = Color(0xFFF3BD5A)

    /** Тонкие линии: 8% и 14% кости. */
    val line = Color(0x14EEE9E2)
    val line2 = Color(0x24EEE9E2)
    val accentSoft = Color(0x29F8814F)
}

/** Текстовые стили. Заголовки Unbounded, остальное Manrope. */
object Type {
    val display = TextStyle(fontFamily = Unbounded, fontWeight = FontWeight.Bold, fontSize = 28.sp, lineHeight = 33.sp, letterSpacing = (-0.6).sp)
    val h1 = TextStyle(fontFamily = Unbounded, fontWeight = FontWeight.Bold, fontSize = 22.sp, lineHeight = 27.sp, letterSpacing = (-0.4).sp)
    val h2 = TextStyle(fontFamily = Unbounded, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, lineHeight = 21.sp, letterSpacing = (-0.2).sp)
    val title = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, lineHeight = 20.sp)
    val body = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.Medium, fontSize = 14.sp, lineHeight = 20.sp)
    val small = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.Medium, fontSize = 12.5.sp, lineHeight = 17.sp)
    val label = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.Bold, fontSize = 11.sp, lineHeight = 14.sp, letterSpacing = 0.6.sp)
    val button = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.ExtraBold, fontSize = 14.sp, lineHeight = 18.sp)
}
