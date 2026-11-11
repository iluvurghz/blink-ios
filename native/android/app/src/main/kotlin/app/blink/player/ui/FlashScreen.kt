package app.blink.player.ui

import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.blink.core.model.Track
import app.blink.core.wave.WaveMode
import app.blink.player.Graph

/** Вспышка: одна большая кнопка, режимы, «не моё» и сердечко. Ниже понравившееся. */
@Composable
fun FlashScreen(g: Graph) {
    val active by g.flash.active.collectAsStateWithLifecycle()
    val loading by g.flash.loading.collectAsStateWithLifecycle()
    val mode by g.flash.mode.collectAsStateWithLifecycle()
    val player by g.player.state.collectAsStateWithLifecycle()
    val library by g.library.state.collectAsStateWithLifecycle()
    val liked = remember(library) { g.library.likes }
    val track = player.track

    LazyColumn(
        Modifier.fillMaxSize().statusBarsPadding(),
        contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 14.dp, bottom = 190.dp),
    ) {
        item(key = "head") {
            T("Вспышка", style = Type.display)
            Spacer(Modifier.height(6.dp))
            T("Бесконечный поток под ваш вкус. Чем больше слушаете и лайкаете, тем точнее.", style = Type.body, color = Ink.mute)
            Spacer(Modifier.height(22.dp))
        }
        item(key = "modes") {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (m in WaveMode.entries) {
                    Chip(m.title, m == mode) { g.flash.setMode(m) }
                }
            }
            Spacer(Modifier.height(22.dp))
        }
        item(key = "stage") {
            if (!active || track == null) {
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                    Box(
                        Modifier
                            .size(150.dp)
                            .clip(CircleShape)
                            .background(Ink.accent)
                            .semantics { contentDescription = "Включить Вспышку" }
                            .tap(!loading) { g.flash.start() },
                        contentAlignment = Alignment.Center,
                    ) {
                        if (loading) Spinner(color = Ink.accentInk, dp = 56.dp) else Glyph(Glyphs.Bolt, color = Ink.accentInk, dp = 72.dp)
                    }
                    Spacer(Modifier.height(14.dp))
                    T(if (loading) "Собираю поток…" else "Включить Вспышку", style = Type.h2)
                }
            } else {
                Column(Modifier.fillMaxWidth()) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Cover(track.artwork, Modifier.size(88.dp), radius = 20.dp, noteDp = 36.dp)
                        Spacer(Modifier.width(14.dp))
                        Column(Modifier.weight(1f)) {
                            T(track.title, style = Type.h2, maxLines = 2)
                            Spacer(Modifier.height(4.dp))
                            T(track.artist, style = Type.body, color = Ink.mute, maxLines = 1)
                        }
                    }
                    Spacer(Modifier.height(12.dp))
                    SeekBar(player.positionMs, player.durationMs, g.player::seekTo)
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
                        IconButton(Glyphs.ThumbDown, "Не моё", { g.flash.dislike(track) }, box = 52.dp, dp = 26.dp, color = Ink.mute)
                        IconButton(Glyphs.Previous, "Предыдущий", { g.player.previous() }, enabled = player.hasPrevious || player.positionMs > 3000, box = 52.dp, dp = 28.dp)
                        Box(
                            Modifier
                                .size(64.dp)
                                .clip(CircleShape)
                                .background(Ink.accent)
                                .semantics { contentDescription = if (player.playing) "Пауза" else "Играть" }
                                .tap { g.player.toggle() },
                            contentAlignment = Alignment.Center,
                        ) {
                            Glyph(if (player.playing) Glyphs.Pause else Glyphs.Play, color = Ink.accentInk, dp = 32.dp)
                        }
                        IconButton(Glyphs.Next, "Следующий", { g.player.next() }, box = 52.dp, dp = 28.dp)
                        LikeButton(g, track)
                    }
                    Spacer(Modifier.height(6.dp))
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                        PillButton("Остановить Вспышку", { g.flash.stop() }, primary = false)
                    }
                }
            }
            Spacer(Modifier.height(28.dp))
        }
        if (liked.isNotEmpty()) {
            item(key = "likes-head") { SectionHeader("Понравившееся", Modifier.padding(bottom = 6.dp)) }
            items(liked.size, key = { liked[it].id }) { i ->
                LikedRow(liked[i], current = liked[i].id == track?.id) { g.actions.play(liked, i) }
            }
        } else {
            item(key = "likes-empty") {
                T("Нажимайте сердечко у треков, и они соберутся здесь и на вашем аккаунте на сайте.", style = Type.small, color = Ink.faint)
            }
        }
    }
}

@Composable
private fun Chip(label: String, selected: Boolean, onClick: () -> Unit) {
    Box(
        Modifier
            .clip(CircleShape)
            .background(if (selected) Ink.accentSoft else Ink.ink3)
            .tap(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 9.dp),
    ) {
        T(label, style = Type.button.copy(fontSize = 13.sp), color = if (selected) Ink.accent else Ink.mute, maxLines = 1)
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

@Composable
private fun LikedRow(track: Track, current: Boolean, onPlay: () -> Unit) {
    Row(Modifier.fillMaxWidth().tap(onClick = onPlay).padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Cover(track.artwork, Modifier.size(52.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            T(track.title, style = Type.title, color = if (current) Ink.accent else Ink.bone, maxLines = 1)
            Spacer(Modifier.height(2.dp))
            T(track.artist, style = Type.small, color = Ink.mute, maxLines = 1)
        }
    }
}
