package app.blink.player.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.blink.core.model.Track
import app.blink.core.ui.ArtUrl
import app.blink.core.ui.Format
import app.blink.core.wave.WaveMode
import app.blink.player.Graph
import app.blink.player.LibRoute
import app.blink.player.Tab

/**
 * Главная: сверху большая Вспышка (фон из обложки, кнопка, режимы), ниже «Коллекция»:
 * «Мне нравится», скачанное, плейлисты, любимые артисты и последние лайки.
 */
@Composable
fun FlashScreen(g: Graph) {
    val library by g.library.state.collectAsStateWithLifecycle()
    val player by g.player.state.collectAsStateWithLifecycle()
    val liked = remember(library) { g.library.likes }
    val playlists = remember(library) { g.library.playlists }
    val artists = remember(liked) { favouriteArtists(liked) }
    val track = player.track

    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = 190.dp),
    ) {
        item(key = "hero") { FlashHero(g) }
        item(key = "collection") {
            Spacer(Modifier.height(26.dp))
            Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp), verticalAlignment = Alignment.Bottom) {
                T("Коллекция", Modifier.weight(1f), Type.h1)
                T("Всё", Modifier.tap { g.nav.openLibrary() }.padding(6.dp), Type.button, Ink.mute)
            }
            Spacer(Modifier.height(14.dp))
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                LikesTile(g, liked.size, Modifier.weight(1f)) { g.nav.openLibrary(LibRoute.Likes) }
                CollectionTile(LineIcons.Download, "Скачанное", "Без интернета", Modifier.weight(1f)) { g.nav.go(Tab.Downloads) }
            }
        }
        item(key = "playlists") {
            Spacer(Modifier.height(22.dp))
            Shelf("Плейлисты", "Все") { g.nav.openLibrary() }
            LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                items(playlists, key = { it.id }) { p ->
                    PlaylistCard(p.cover ?: p.tracks.firstOrNull()?.artwork.orEmpty(), p.name, Format.tracks(p.tracks.size)) {
                        g.nav.openLibrary(LibRoute.Mine(p.id))
                    }
                }
                item(key = "import") {
                    ActionCard(LineIcons.Plus, "Перенести музыку", "Яндекс, Spotify") { g.nav.openLibrary(LibRoute.Import) }
                }
            }
        }
        if (artists.isNotEmpty()) {
            item(key = "artists") {
                Spacer(Modifier.height(22.dp))
                Shelf("Любимые артисты", null) {}
                LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    items(artists, key = { it.first }) { (name, tracks) ->
                        ArtistBubble(g, name, tracks) {
                            val id = tracks.first().artistId
                            if (id != null) g.nav.openArtist(id) else g.actions.play(tracks, 0)
                        }
                    }
                }
            }
        }
        item(key = "likes-head") {
            Spacer(Modifier.height(22.dp))
            Shelf("Понравившееся", if (liked.size > 6) "Все ${liked.size}" else null) { g.nav.openLibrary(LibRoute.Likes) }
        }
        if (liked.isEmpty()) {
            item(key = "likes-empty") {
                T(
                    "Нажимайте сердечко у треков, и они соберутся здесь и на вашем аккаунте на сайте.",
                    Modifier.padding(horizontal = 20.dp),
                    Type.small,
                    Ink.faint,
                )
            }
        } else {
            val top = liked.take(6)
            items(top.size, key = { "like-" + top[it].id }) { i ->
                LikedRow(top[i], current = top[i].id == track?.id) { g.actions.play(liked, i) }
            }
        }
    }
}

/** Артисты из лайков: у кого больше всего понравившихся треков. */
private fun favouriteArtists(liked: List<Track>): List<Pair<String, List<Track>>> =
    liked.groupBy { it.artist.split(",", "&", " feat").first().trim() }
        .filterKeys { it.isNotEmpty() }
        .entries
        .sortedByDescending { it.value.size }
        .take(12)
        .map { it.key to it.value }

/** Большая карточка Вспышки, как «Моя волна», но в стиле Blink: фон из обложки, светящаяся кнопка. */
@Composable
private fun FlashHero(g: Graph) {
    val active by g.flash.active.collectAsStateWithLifecycle()
    val loading by g.flash.loading.collectAsStateWithLifecycle()
    val mode by g.flash.mode.collectAsStateWithLifecycle()
    val player by g.player.state.collectAsStateWithLifecycle()
    val palette by g.stage.palette.collectAsStateWithLifecycle()
    val accent by animateColorAsState(palette.accent.color(), tween(1200), label = "heroAccent")
    val ink = palette.accentInk.color()
    val track = player.track.takeIf { active }
    val shape = RoundedCornerShape(30.dp)
    val drift = rememberInfiniteTransition(label = "drift")
    val phase by drift.animateFloat(0f, 1f, infiniteRepeatable(tween(9000), RepeatMode.Reverse), label = "phase")

    Box(
        Modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(start = 12.dp, end = 12.dp, top = 8.dp)
            .aspectRatio(0.78f)
            .clip(shape)
            .background(Ink.ink2)
            .border(1.dp, Color(0x14FFFFFF), shape),
    ) {
        if (track != null) {
            BlurredCover(track.artwork)
        } else {
            // Без трека: живые пятна цвета акцента (ps-bg на сайте до первого трека)
            val a = palette.glowA.color(0.55f)
            val b = palette.glowB.color(0.45f)
            val c = palette.glowC.color(0.35f)
            Canvas(Modifier.fillMaxSize()) {
                val w = size.width
                val h = size.height
                drawRect(Brush.radialGradient(listOf(a, Color.Transparent), Offset(w * (0.2f + 0.2f * phase), h * 0.3f), w * 0.8f))
                drawRect(Brush.radialGradient(listOf(b, Color.Transparent), Offset(w * (0.85f - 0.2f * phase), h * (0.55f + 0.1f * phase)), w * 0.75f))
                drawRect(Brush.radialGradient(listOf(c, Color.Transparent), Offset(w * 0.5f, h * (0.95f - 0.1f * phase)), w * 0.7f))
                drawRect(Brush.verticalGradient(0f to Color(0x3308070A), 0.6f to Color(0x0008070A), 1f to Color(0xCC08070A)))
            }
        }

        Column(Modifier.fillMaxSize().padding(22.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                LineIcon(LineIcons.Bolt, color = accent, dp = 22.dp)
                Spacer(Modifier.width(8.dp))
                T("Вспышка", style = Type.h2.copy(fontSize = 18.sp), color = Ink.bone)
                Spacer(Modifier.weight(1f))
                if (active) {
                    T("Стоп", Modifier.clip(CircleShape).background(Color(0x26FFFFFF)).tap { g.flash.stop() }.padding(horizontal = 14.dp, vertical = 7.dp), Type.button.copy(fontSize = 13.sp), Ink.bone)
                }
            }
            Spacer(Modifier.weight(1f))
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                if (track == null) {
                    Box(
                        Modifier
                            .size(124.dp)
                            .shadow(40.dp, CircleShape, ambientColor = accent, spotColor = accent)
                            .clip(CircleShape)
                            .background(accent)
                            .semantics { contentDescription = "Включить Вспышку" }
                            .pressTap(!loading) { g.flash.start() },
                        contentAlignment = Alignment.Center,
                    ) {
                        if (loading) Spinner(color = ink, dp = 52.dp) else LineIcon(LineIcons.Play, color = ink, dp = 50.dp)
                    }
                    Spacer(Modifier.height(22.dp))
                    T(
                        if (loading) "Собираю поток…" else "Включить Вспышку",
                        style = Type.display.copy(fontSize = 26.sp, lineHeight = 30.sp),
                        align = TextAlign.Center,
                    )
                    Spacer(Modifier.height(8.dp))
                    T(
                        "Бесконечный поток под ваш вкус. Чем больше слушаете и лайкаете, тем точнее.",
                        Modifier.padding(horizontal = 12.dp),
                        Type.body,
                        Ink.bone.copy(alpha = 0.6f),
                        align = TextAlign.Center,
                    )
                } else {
                    Box(Modifier.size(150.dp).clip(RoundedCornerShape(24.dp)).tap { g.nav.openPlayer(true) }) {
                        NetImage(ArtUrl.scaled(track.artwork, 400), Modifier.fillMaxSize())
                    }
                    Spacer(Modifier.height(18.dp))
                    T(track.title, style = Type.display.copy(fontSize = 24.sp, lineHeight = 28.sp), maxLines = 2, align = TextAlign.Center)
                    Spacer(Modifier.height(4.dp))
                    T(track.artist, style = Type.title.copy(fontWeight = FontWeight.SemiBold), color = Ink.bone.copy(alpha = 0.62f), maxLines = 1, align = TextAlign.Center)
                    Spacer(Modifier.height(18.dp))
                    val library by g.library.state.collectAsStateWithLifecycle()
                    val liked = remember(library, track.id) { g.library.isLiked(track.id) }
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        StageIcon(LineIcons.ThumbDown, "Не моё", { g.flash.dislike(track) }, dp = 24.dp, box = 52.dp, color = Ink.bone.copy(alpha = 0.8f))
                        PlayIris(player.playing, player.buffering, 72.dp, accent, ink, glow = true) { g.player.toggle() }
                        StageIcon(LineIcons.Next, "Следующий", { g.player.next() }, dp = 26.dp, box = 52.dp)
                        StageIcon(if (liked) LineIcons.HeartFill else LineIcons.Heart, "Любимое", { g.flash.toggleLike(track) }, dp = 24.dp, box = 52.dp, on = liked, accent = accent)
                    }
                }
            }
            Spacer(Modifier.weight(1f))
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (m in WaveMode.entries) ModeChip(m.title, m == mode, accent) { g.flash.setMode(m) }
            }
        }
    }
}

@Composable
private fun ModeChip(label: String, selected: Boolean, accent: Color, onClick: () -> Unit) {
    Box(
        Modifier
            .clip(CircleShape)
            .background(if (selected) accent.copy(alpha = 0.22f) else Color(0x1FFFFFFF))
            .border(1.dp, if (selected) accent.copy(alpha = 0.5f) else Color.Transparent, CircleShape)
            .semantics { contentDescription = "Режим $label" }
            .tap(onClick = onClick)
            .padding(horizontal = 15.dp, vertical = 9.dp),
    ) {
        T(label, style = Type.button.copy(fontSize = 13.sp), color = if (selected) accent else Ink.bone.copy(alpha = 0.75f), maxLines = 1)
    }
}

@Composable
private fun Shelf(title: String, action: String?, onAction: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 14.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        T(title, Modifier.weight(1f), Type.h2)
        if (action != null) T(action, Modifier.tap(onClick = onAction).padding(6.dp), Type.button.copy(fontSize = 13.sp), Ink.mute)
    }
}

/** «Мне нравится»: плитка цвета акцента с сердцем и числом треков. */
@Composable
private fun LikesTile(g: Graph, count: Int, modifier: Modifier, onClick: () -> Unit) {
    val palette by g.stage.palette.collectAsStateWithLifecycle()
    val accent by animateColorAsState(palette.accent.color(), tween(1200), label = "likesAccent")
    val shape = RoundedCornerShape(22.dp)
    Column(
        modifier
            .height(132.dp)
            .clip(shape)
            .background(Brush.linearGradient(listOf(accent.copy(alpha = 0.95f), palette.glowB.color(0.85f), Ink.ink3)))
            .semantics { contentDescription = "Мне нравится" }
            .pressTap(onClick = onClick)
            .padding(16.dp),
    ) {
        Box(Modifier.size(40.dp).clip(CircleShape).background(Color(0x33000000)), contentAlignment = Alignment.Center) {
            LineIcon(LineIcons.HeartFill, color = Ink.bone, dp = 22.dp)
        }
        Spacer(Modifier.weight(1f))
        T("Мне нравится", style = Type.h2, color = Ink.bone, maxLines = 1)
        T(Format.tracks(count), style = Type.small, color = Ink.bone.copy(alpha = 0.75f), maxLines = 1)
    }
}

@Composable
private fun CollectionTile(icon: LineIcons, title: String, subtitle: String, modifier: Modifier, onClick: () -> Unit) {
    val shape = RoundedCornerShape(22.dp)
    Column(
        modifier
            .height(132.dp)
            .clip(shape)
            .background(Ink.ink2)
            .border(1.dp, Color(0x12FFFFFF), shape)
            .semantics { contentDescription = title }
            .pressTap(onClick = onClick)
            .padding(16.dp),
    ) {
        Box(Modifier.size(40.dp).clip(CircleShape).background(Color(0x14FFFFFF)), contentAlignment = Alignment.Center) {
            LineIcon(icon, color = Ink.bone, dp = 22.dp)
        }
        Spacer(Modifier.weight(1f))
        T(title, style = Type.h2, maxLines = 1)
        T(subtitle, style = Type.small, color = Ink.mute, maxLines = 1)
    }
}

@Composable
private fun PlaylistCard(cover: String, name: String, sub: String, onClick: () -> Unit) {
    Column(Modifier.width(140.dp).pressTap(onClick = onClick)) {
        NetImage(ArtUrl.scaled(cover, 300), Modifier.size(140.dp).clip(RoundedCornerShape(20.dp)))
        Spacer(Modifier.height(8.dp))
        T(name, style = Type.title, maxLines = 1)
        T(sub, style = Type.small, color = Ink.mute, maxLines = 1)
    }
}

@Composable
private fun ActionCard(icon: LineIcons, name: String, sub: String, onClick: () -> Unit) {
    Column(Modifier.width(140.dp).pressTap(onClick = onClick)) {
        Box(
            Modifier.size(140.dp).clip(RoundedCornerShape(20.dp)).background(Ink.ink2).border(1.dp, Color(0x14FFFFFF), RoundedCornerShape(20.dp)),
            contentAlignment = Alignment.Center,
        ) {
            LineIcon(icon, color = Ink.bone.copy(alpha = 0.7f), dp = 34.dp)
        }
        Spacer(Modifier.height(8.dp))
        T(name, style = Type.title, maxLines = 1)
        T(sub, style = Type.small, color = Ink.mute, maxLines = 1)
    }
}

@Composable
private fun ArtistBubble(g: Graph, name: String, tracks: List<Track>, onClick: () -> Unit) {
    var photo by remember(name) { mutableStateOf<String?>(null) }
    LaunchedEffect(name) { photo = g.stage.artistPhoto(tracks.first()) }
    Column(Modifier.width(88.dp).pressTap(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally) {
        NetImage(photo ?: ArtUrl.scaled(tracks.first().artwork, 200), Modifier.size(88.dp).clip(CircleShape))
        Spacer(Modifier.height(8.dp))
        T(name, style = Type.small.copy(fontWeight = FontWeight.SemiBold), maxLines = 1, align = TextAlign.Center)
    }
}

@Composable
private fun LikedRow(track: Track, current: Boolean, onPlay: () -> Unit) {
    Row(Modifier.fillMaxWidth().tap(onClick = onPlay).padding(horizontal = 20.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Cover(track.artwork, Modifier.size(52.dp), radius = 12.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            T(track.title, style = Type.title, color = if (current) Ink.accent else Ink.bone, maxLines = 1)
            Spacer(Modifier.height(2.dp))
            T(track.artist, style = Type.small, color = Ink.mute, maxLines = 1)
        }
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
