package app.blink.player.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import app.blink.core.offline.OfflinePolicy
import app.blink.core.offline.OfflineState
import app.blink.core.offline.SaveUi
import app.blink.core.ui.Format
import app.blink.player.Graph
import app.blink.player.Overlay
import app.blink.player.playback.PlayerUi

/** Большой плеер: обложка, перемотка, управление и кнопка сохранения. Закрывается свайпом вниз кнопкой или «Назад». */
@Composable
fun PlayerScreen(g: Graph, ui: PlayerUi, offline: OfflineState, onClose: () -> Unit) {
    val track = ui.track ?: return
    BackHandler(onBack = onClose)

    BoxWithConstraints(Modifier.fillMaxSize().background(Ink.ink).pointerInput(Unit) { detectTapGestures { } }) {
        val side = minOf(maxWidth - 48.dp, maxHeight - 400.dp).coerceAtLeast(150.dp)
        Column(
            Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(Modifier.fillMaxWidth().height(56.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(Glyphs.ExpandMore, "Свернуть плеер", onClose)
                Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                    T("СЕЙЧАС ИГРАЕТ", style = Type.label, color = Ink.mute, maxLines = 1)
                }
                LikeButton(g, track)
            }
            Spacer(Modifier.weight(1f))
            Cover(track.artwork, Modifier.size(side), radius = 28.dp, noteDp = 72.dp)
            Spacer(Modifier.height(26.dp))

            Column(Modifier.fillMaxWidth()) {
                T(track.title, style = Type.h1, maxLines = 2)
                Spacer(Modifier.height(6.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (track.explicit) {
                        ExplicitBadge()
                        Spacer(Modifier.width(6.dp))
                    }
                    T(track.artist, style = Type.title, color = Ink.mute, maxLines = 1)
                }
            }
            Spacer(Modifier.height(18.dp))
            SeekBar(ui.positionMs, ui.durationMs) { ms ->
                g.player.seekTo(ms)
                g.room.onUserSeek(ms)
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                T(Format.duration((ui.positionMs / 1000).toInt()), style = Type.small, color = Ink.faint)
                T(Format.duration((ui.durationMs / 1000).toInt()), style = Type.small, color = Ink.faint)
            }
            Spacer(Modifier.height(14.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                IconButton(Glyphs.Previous, "Предыдущий", { g.player.previous() }, enabled = ui.hasPrevious || ui.positionMs > 3000, box = 60.dp, dp = 32.dp)
                Spacer(Modifier.width(14.dp))
                Box(Modifier.size(84.dp), contentAlignment = Alignment.Center) {
                    if (ui.buffering) Spinner(dp = 84.dp)
                    Box(
                        Modifier
                            .size(72.dp)
                            .clip(CircleShape)
                            .background(Ink.accent)
                            .semantics { contentDescription = if (ui.playing) "Пауза" else "Играть" }
                            .tap { g.player.toggle() },
                        contentAlignment = Alignment.Center,
                    ) {
                        Glyph(if (ui.playing) Glyphs.Pause else Glyphs.Play, color = Ink.accentInk, dp = 36.dp)
                    }
                }
                Spacer(Modifier.width(14.dp))
                IconButton(Glyphs.Next, "Следующий", { g.player.next() }, enabled = ui.hasNext, box = 60.dp, dp = 32.dp)
            }
            Spacer(Modifier.weight(1f))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                PillButton(if (g.room.inRoom) "Комната" else "Слушать вместе", { g.nav.open(Overlay.Room) }, primary = false)
            }
            Spacer(Modifier.height(12.dp))
            SaveChip(SaveUi.of(track, offline), OfflinePolicy.keyOf(track) in offline.savedKeys) { onSaveTap(g, track, offline) }
            Spacer(Modifier.height(18.dp))
        }
    }
}

/** Пилюля внизу плеера: сохранить, идёт сохранение, уже на телефоне или «только онлайн». */
@Composable
private fun SaveChip(ui: SaveUi, onPhone: Boolean, onClick: () -> Unit) {
    val (label, tint) = when (ui) {
        is SaveUi.OnlineOnly -> "Играет только онлайн" to Ink.faint
        SaveUi.Available -> "Сохранить для офлайна" to Ink.bone
        SaveUi.Queued -> "В очереди на сохранение" to Ink.mute
        is SaveUi.Progress -> "Сохраняется…" to Ink.accent
        SaveUi.Saved -> (if (onPhone) "На телефоне, играет без интернета" else "Сохранено") to Ink.accent
        is SaveUi.Failed -> "Не вышло. Повторить" to Ink.danger
    }
    Row(
        Modifier
            .clip(CircleShape)
            .background(Ink.ink2)
            .border(1.dp, Ink.line2, CircleShape)
            .tap(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SaveGlyph(ui, tint)
        Spacer(Modifier.width(8.dp))
        T(label, style = Type.button, color = tint, maxLines = 1, modifier = Modifier.padding(end = 4.dp))
    }
}

@Composable
private fun SaveGlyph(ui: SaveUi, tint: androidx.compose.ui.graphics.Color) {
    Box(Modifier.size(32.dp), contentAlignment = Alignment.Center) {
        when (ui) {
            is SaveUi.OnlineOnly -> Glyph(Glyphs.CloudOff, color = tint, dp = 20.dp)
            SaveUi.Available -> Glyph(Glyphs.Download, color = tint, dp = 20.dp)
            SaveUi.Queued -> Glyph(Glyphs.Download, color = tint, dp = 20.dp)
            is SaveUi.Progress -> if (ui.indeterminate) Spinner(dp = 24.dp) else Ring(ui.fraction, dp = 24.dp)
            SaveUi.Saved -> Glyph(Glyphs.CheckCircle, color = tint, dp = 22.dp)
            is SaveUi.Failed -> Glyph(Glyphs.Refresh, color = tint, dp = 20.dp)
        }
    }
}

/** Полоса перемотки: тап и перетаскивание. Пока тянем, показываем палец, а не позицию плеера. */
@Composable
fun SeekBar(positionMs: Long, durationMs: Long, onSeek: (Long) -> Unit, modifier: Modifier = Modifier) {
    var drag by remember { mutableStateOf<Float?>(null) }
    val fraction = drag ?: if (durationMs > 0) (positionMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f
    Box(
        modifier
            .fillMaxWidth()
            .height(32.dp)
            .pointerInput(durationMs) {
                detectTapGestures { offset ->
                    if (durationMs > 0) onSeek((offset.x / size.width * durationMs).toLong().coerceIn(0, durationMs))
                }
            }
            .pointerInput(durationMs) {
                detectHorizontalDragGestures(
                    onDragStart = { offset -> drag = (offset.x / size.width).coerceIn(0f, 1f) },
                    onDragEnd = {
                        val f = drag
                        if (f != null && durationMs > 0) onSeek((f * durationMs).toLong())
                        drag = null
                    },
                    onDragCancel = { drag = null },
                    onHorizontalDrag = { change, _ -> drag = (change.position.x / size.width).coerceIn(0f, 1f) },
                )
            },
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val h = 4.dp.toPx()
            val y = (size.height - h) / 2
            val corner = CornerRadius(h / 2, h / 2)
            drawRoundRect(Ink.line2, Offset(0f, y), Size(size.width, h), corner)
            drawRoundRect(Ink.accent, Offset(0f, y), Size(size.width * fraction, h), corner)
            drawCircle(Ink.bone, radius = 7.dp.toPx(), center = Offset(size.width * fraction, size.height / 2))
        }
    }
}
