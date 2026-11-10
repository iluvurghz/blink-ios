package app.blink.player.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.blink.core.model.Track
import app.blink.core.offline.OfflinePolicy
import app.blink.core.offline.SaveUi
import app.blink.core.ui.Format
import coil3.compose.AsyncImage

/** Текст в стиле Blink. Короткая запись, потому что встречается на каждом экране. */
@Composable
fun T(
    text: String,
    modifier: Modifier = Modifier,
    style: TextStyle = Type.body,
    color: Color = Ink.bone,
    maxLines: Int = Int.MAX_VALUE,
    align: TextAlign = TextAlign.Unspecified,
) {
    BasicText(
        text = text,
        modifier = modifier,
        style = style.copy(color = color, textAlign = align),
        overflow = TextOverflow.Ellipsis,
        maxLines = maxLines,
    )
}

/** Нажатие без ряби Material: на секунду темнеем. Один и тот же отклик везде в приложении. */
fun Modifier.tap(enabled: Boolean = true, onClick: () -> Unit): Modifier = composed {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    this
        .graphicsLayer { alpha = if (pressed) 0.55f else 1f }
        .clickable(interactionSource = source, indication = null, enabled = enabled, onClick = onClick)
}

@Composable
fun PillButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    primary: Boolean = true,
    enabled: Boolean = true,
    danger: Boolean = false,
) {
    val bg = when {
        danger -> Ink.danger.copy(alpha = 0.16f)
        primary -> Ink.accent
        else -> Ink.ink3
    }
    val fg = when {
        danger -> Ink.danger
        primary -> Ink.accentInk
        else -> Ink.bone
    }
    Box(
        modifier
            .clip(CircleShape)
            .background(if (enabled) bg else bg.copy(alpha = 0.4f))
            .tap(enabled, onClick)
            .padding(horizontal = 18.dp, vertical = 11.dp),
        contentAlignment = Alignment.Center,
    ) {
        T(label, style = Type.button, color = fg, maxLines = 1)
    }
}

@Composable
fun IconButton(
    glyph: Glyphs,
    description: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    color: Color = Ink.bone,
    enabled: Boolean = true,
    box: Dp = 44.dp,
    dp: Dp = 24.dp,
) {
    Box(
        modifier
            .size(box)
            .semantics { contentDescription = description }
            .tap(enabled, onClick),
        contentAlignment = Alignment.Center,
    ) {
        Glyph(glyph, color = if (enabled) color else color.copy(alpha = 0.3f), dp = dp)
    }
}

/** Обложка. Пока грузится или обложки нет, видна тёмная плашка с нотой. */
@Composable
fun Cover(url: String, modifier: Modifier = Modifier, radius: Dp = 10.dp, noteDp: Dp = 22.dp) {
    Box(modifier.clip(RoundedCornerShape(radius)).background(Ink.ink3), contentAlignment = Alignment.Center) {
        if (url.isEmpty()) {
            Glyph(Glyphs.Note, color = Ink.faint, dp = noteDp)
        } else {
            AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
    }
}

/** Кольцо прогресса вокруг значка загрузки. */
@Composable
fun Ring(fraction: Float, modifier: Modifier = Modifier, color: Color = Ink.accent, dp: Dp = 28.dp) {
    Canvas(modifier.size(dp)) {
        val stroke = 2.5.dp.toPx()
        val box = Size(size.width - stroke, size.height - stroke)
        val corner = Offset(stroke / 2, stroke / 2)
        drawArc(Ink.line2, 0f, 360f, false, topLeft = corner, size = box, style = Stroke(stroke))
        if (fraction > 0f) {
            drawArc(color, -90f, 360f * fraction.coerceIn(0f, 1f), false, topLeft = corner, size = box, style = Stroke(stroke, cap = StrokeCap.Round))
        }
    }
}

/** Крутилка, когда размер ещё неизвестен. */
@Composable
fun Spinner(modifier: Modifier = Modifier, color: Color = Ink.accent, dp: Dp = 28.dp) {
    val transition = rememberInfiniteTransition(label = "spinner")
    val angle by transition.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(tween(durationMillis = 900, easing = LinearEasing)),
        label = "angle",
    )
    Canvas(modifier.size(dp)) {
        val stroke = 2.5.dp.toPx()
        val box = Size(size.width - stroke, size.height - stroke)
        val corner = Offset(stroke / 2, stroke / 2)
        drawArc(Ink.line2, 0f, 360f, false, topLeft = corner, size = box, style = Stroke(stroke))
        drawArc(color, angle - 90f, 100f, false, topLeft = corner, size = box, style = Stroke(stroke, cap = StrokeCap.Round))
    }
}

/** Кнопка «Сохранить» у трека. Рисует то, что решило ядро (SaveUi); что делать по нажатию, решает вызывающий. */
@Composable
fun SaveButton(ui: SaveUi, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val description = when (ui) {
        is SaveUi.OnlineOnly -> "Играет только онлайн"
        SaveUi.Available -> "Сохранить для офлайна"
        SaveUi.Queued -> "В очереди на сохранение"
        is SaveUi.Progress -> "Сохраняется"
        SaveUi.Saved -> "Сохранено"
        is SaveUi.Failed -> "Не вышло, повторить"
    }
    Box(modifier.size(44.dp).semantics { contentDescription = description }.tap(onClick = onClick), contentAlignment = Alignment.Center) {
        when (ui) {
            is SaveUi.OnlineOnly -> Glyph(Glyphs.CloudOff, color = Ink.faint, dp = 20.dp)
            SaveUi.Available -> Glyph(Glyphs.Download, color = Ink.mute, dp = 22.dp)
            SaveUi.Queued -> {
                Ring(0f)
                Glyph(Glyphs.Download, color = Ink.faint, dp = 14.dp)
            }
            is SaveUi.Progress -> {
                if (ui.indeterminate) Spinner() else Ring(ui.fraction)
                Glyph(Glyphs.Download, color = Ink.accent, dp = 14.dp)
            }
            SaveUi.Saved ->
                Box(Modifier.size(26.dp).clip(CircleShape).background(Ink.accent), contentAlignment = Alignment.Center) {
                    Glyph(Glyphs.Check, color = Ink.accentInk, dp = 16.dp)
                }
            is SaveUi.Failed -> Glyph(Glyphs.Refresh, color = Ink.danger, dp = 22.dp)
        }
    }
}

@Composable
fun ExplicitBadge() {
    Box(Modifier.size(14.dp).clip(RoundedCornerShape(3.dp)).background(Ink.faint), contentAlignment = Alignment.Center) {
        T("E", style = Type.label.copy(fontSize = 9.sp, lineHeight = 11.sp, letterSpacing = 0.sp), color = Ink.ink)
    }
}

/** Метка у треков из каталога Blink: их можно сохранить. */
@Composable
fun BlinkTag() {
    Box(Modifier.clip(RoundedCornerShape(4.dp)).background(Ink.accentSoft).padding(horizontal = 5.dp, vertical = 1.dp)) {
        T("BLINK", style = Type.label.copy(fontSize = 9.sp, lineHeight = 12.sp, letterSpacing = 0.5.sp), color = Ink.accent, maxLines = 1)
    }
}

@Composable
fun TrackRow(
    track: Track,
    current: Boolean,
    save: SaveUi,
    onPlay: () -> Unit,
    onSave: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier.fillMaxWidth().tap(onClick = onPlay).padding(start = 16.dp, end = 6.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Cover(track.artwork, Modifier.size(52.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            T(track.title, style = Type.title, color = if (current) Ink.accent else Ink.bone, maxLines = 1)
            Spacer(Modifier.height(2.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (track.explicit) {
                    ExplicitBadge()
                    Spacer(Modifier.width(6.dp))
                }
                T(track.artist, Modifier.weight(1f, fill = false), Type.small, Ink.mute, maxLines = 1)
                if (OfflinePolicy.savable(track)) {
                    Spacer(Modifier.width(8.dp))
                    BlinkTag()
                }
            }
        }
        SaveButton(save, onSave)
    }
}

/** Ряд со статусом без обложки-трека: для очереди загрузок. */
@Composable
fun SectionHeader(title: String, modifier: Modifier = Modifier, action: String? = null, onAction: () -> Unit = {}) {
    Row(
        modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 22.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        T(title, style = Type.h2, maxLines = 1, modifier = Modifier.weight(1f))
        if (action != null) {
            T(action, modifier = Modifier.tap(onClick = onAction).padding(8.dp), style = Type.button, color = Ink.accent, maxLines = 1)
        }
    }
}

@Composable
fun Banner(glyph: Glyphs, text: String, modifier: Modifier = Modifier) {
    Row(
        modifier
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Ink.ink2)
            .border(1.dp, Ink.line, RoundedCornerShape(16.dp))
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Glyph(glyph, color = Ink.warn, dp = 22.dp)
        Spacer(Modifier.width(12.dp))
        T(text, style = Type.small, color = Ink.mute, modifier = Modifier.weight(1f))
    }
}

@Composable
fun EmptyState(glyph: Glyphs, title: String, text: String, modifier: Modifier = Modifier, button: String? = null, onButton: () -> Unit = {}) {
    Column(
        modifier.fillMaxWidth().padding(horizontal = 32.dp, vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.size(72.dp).clip(CircleShape).background(Ink.ink2).border(1.dp, Ink.line, CircleShape), contentAlignment = Alignment.Center) {
            Glyph(glyph, color = Ink.mute, dp = 30.dp)
        }
        Spacer(Modifier.height(18.dp))
        T(title, style = Type.h2, align = TextAlign.Center)
        Spacer(Modifier.height(8.dp))
        T(text, style = Type.body, color = Ink.mute, align = TextAlign.Center)
        if (button != null) {
            Spacer(Modifier.height(18.dp))
            PillButton(button, onButton)
        }
    }
}

/** Серая заглушка трека, пока грузится список. */
@Composable
fun SkeletonRow() {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(52.dp).clip(RoundedCornerShape(10.dp)).background(Ink.ink2))
        Spacer(Modifier.width(12.dp))
        Column {
            Box(Modifier.width(160.dp).height(12.dp).clip(RoundedCornerShape(6.dp)).background(Ink.ink2))
            Spacer(Modifier.height(8.dp))
            Box(Modifier.width(100.dp).height(10.dp).clip(RoundedCornerShape(5.dp)).background(Ink.ink2))
        }
    }
}

/** Тонкая полоса прогресса в строке очереди. */
@Composable
fun BarProgress(fraction: Float, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(4.dp).clip(CircleShape).background(Ink.line2)) {
        Box(Modifier.fillMaxSize().graphicsLayer { scaleX = fraction.coerceIn(0f, 1f); transformOrigin = androidx.compose.ui.graphics.TransformOrigin(0f, 0.5f) }.background(Ink.accent))
    }
}

/** «12 треков · 84 МБ». */
fun summary(count: Int, bytes: Long): String = "${Format.tracks(count)} · ${Format.bytes(bytes)}"

/** Поле ввода в стиле Blink: таблетка с подсказкой. */
@Composable
fun TextBox(
    value: String,
    onChange: (String) -> Unit,
    hint: String,
    modifier: Modifier = Modifier,
    keyboardType: androidx.compose.ui.text.input.KeyboardType = androidx.compose.ui.text.input.KeyboardType.Text,
    imeAction: androidx.compose.ui.text.input.ImeAction = androidx.compose.ui.text.input.ImeAction.Next,
    password: Boolean = false,
    onDone: () -> Unit = {},
) {
    androidx.compose.foundation.text.BasicTextField(
        value = value,
        onValueChange = onChange,
        singleLine = true,
        textStyle = Type.body.copy(color = Ink.bone),
        cursorBrush = androidx.compose.ui.graphics.SolidColor(Ink.accent),
        keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = keyboardType, imeAction = imeAction),
        keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { onDone() }, onGo = { onDone() }),
        visualTransformation = if (password) androidx.compose.ui.text.input.PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        modifier = modifier.fillMaxWidth(),
        decorationBox = { inner ->
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(52.dp)
                    .clip(CircleShape)
                    .background(Ink.ink2)
                    .border(1.dp, Ink.line2, CircleShape)
                    .padding(horizontal = 20.dp),
                contentAlignment = Alignment.CenterStart,
            ) {
                if (value.isEmpty()) T(hint, style = Type.body, color = Ink.faint, maxLines = 1)
                inner()
            }
        },
    )
}
