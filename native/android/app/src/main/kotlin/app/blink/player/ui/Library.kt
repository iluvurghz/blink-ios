package app.blink.player.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.blink.core.library.EditorialItem
import app.blink.core.library.SharedPlaylist
import app.blink.core.model.Track
import app.blink.core.ui.Format
import app.blink.player.Graph
import app.blink.player.LibRoute
import app.blink.player.Overlay
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** «Музыка»: любимое, мои плейлисты, подборки Blink и плейлисты по ссылке. Порт страниц плейлистов сайта. */
@Composable
fun LibraryScreen(g: Graph) {
    val route by g.nav.library.collectAsStateWithLifecycle()
    val lib by g.library.state.collectAsStateWithLifecycle()
    BackHandler { if (route == LibRoute.Home) g.nav.close() else g.nav.libraryTo(LibRoute.Home) }
    val title = when (val r = route) {
        LibRoute.Home -> "Музыка"
        LibRoute.Likes -> "Любимое"
        is LibRoute.Mine -> remember(lib, r.id) { g.library.playlist(r.id)?.name ?: "Плейлист" }
        is LibRoute.Shared -> "Плейлист по ссылке"
        is LibRoute.Editorial -> "Подборка Blink"
        LibRoute.Import -> "Перенос музыки"
    }
    Sheet(g, title) {
        when (val r = route) {
            LibRoute.Home -> LibraryHome(g)
            LibRoute.Likes -> LikesPage(g)
            is LibRoute.Mine -> MyPlaylist(g, r.id)
            is LibRoute.Shared -> RemotePlaylist(g, key = "s" + r.code, load = { g.shared.fetchShared(r.code) }, mine = false)
            is LibRoute.Editorial -> RemotePlaylist(g, key = "e" + r.id, load = { g.shared.editorialOne(r.id) }, mine = false)
            LibRoute.Import -> ImportPanel(g)
        }
    }
}

@Composable
private fun LikesPage(g: Graph) {
    val lib by g.library.state.collectAsStateWithLifecycle()
    val likes = remember(lib) { g.library.likes }
    PlaylistHeader(g, likes, "Мне нравится", Format.tracks(likes.size), cover = null)
    TrackList(g, likes, emptyText = "Нажмите сердечко у трека, и он появится здесь.", onRemove = { t -> g.library.toggleLike(t) })
}

/**
 * Шапка плейлиста: большая обложка (у «Мне нравится» сердце на цвете акцента), название,
 * число треков и две главные кнопки: «Слушать» и «Скачать».
 */
@Composable
private fun PlaylistHeader(g: Graph, tracks: List<Track>, name: String, sub: String, cover: String?, owner: String = "") {
    val palette by g.stage.palette.collectAsStateWithLifecycle()
    val accent = palette.accent.color()
    val ink = palette.accentInk.color()
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        val shape = RoundedCornerShape(26.dp)
        Box(
            Modifier
                .size(208.dp)
                .shadow(30.dp, shape, ambientColor = accent, spotColor = accent)
                .clip(shape)
                .background(androidx.compose.ui.graphics.Brush.linearGradient(listOf(accent, palette.glowB.color(), Ink.ink3))),
            contentAlignment = Alignment.Center,
        ) {
            if (cover == null) {
                LineIcon(LineIcons.HeartFill, color = Ink.bone, dp = 84.dp)
            } else {
                NetImage(app.blink.core.ui.ArtUrl.scaled(cover, 500), Modifier.fillMaxSize())
            }
        }
        Spacer(Modifier.height(18.dp))
        T(name, style = Type.display, maxLines = 2, align = androidx.compose.ui.text.style.TextAlign.Center)
        Spacer(Modifier.height(4.dp))
        T(if (owner.isNotEmpty()) "$sub · от $owner" else sub, style = Type.body, color = Ink.mute, maxLines = 1)
        Spacer(Modifier.height(18.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            HeaderButton(LineIcons.Download, "Скачать", Color(0x1AFFFFFF), Ink.bone, tracks.isNotEmpty()) { g.actions.saveAll(tracks) }
            HeaderButton(LineIcons.Play, "Слушать", accent, ink, tracks.isNotEmpty()) { g.actions.play(tracks, 0) }
            StageIcon(LineIcons.Shuffle, "Вперемешку", { g.actions.play(tracks.shuffled(), 0) }, Modifier.clip(CircleShape).background(Color(0x1AFFFFFF)), dp = 20.dp, box = 48.dp, enabled = tracks.size > 1)
        }
        Spacer(Modifier.height(18.dp))
    }
}

@Composable
private fun HeaderButton(icon: LineIcons, label: String, bg: Color, fg: Color, enabled: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .height(48.dp)
            .clip(CircleShape)
            .background(bg)
            .semantics { contentDescription = label }
            .pressTap(enabled, onClick)
            .padding(horizontal = 18.dp)
            .graphicsLayer { alpha = if (enabled) 1f else 0.4f },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        LineIcon(icon, color = fg, dp = 20.dp)
        Spacer(Modifier.width(8.dp))
        T(label, style = Type.button, color = fg, maxLines = 1)
    }
}

@Composable
private fun LibraryHome(g: Graph) {
    val lib by g.library.state.collectAsStateWithLifecycle()
    val playlists = remember(lib) { g.library.playlists }
    val likes = remember(lib) { g.library.likes }
    var name by remember { mutableStateOf("") }
    var editorial by remember { mutableStateOf<List<EditorialItem>>(emptyList()) }
    LaunchedEffect(Unit) { editorial = try { g.shared.editorial() } catch (e: CancellationException) { throw e } catch (_: Exception) { emptyList() } }

    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(Ink.ink2).tap { g.nav.libraryTo(LibRoute.Likes) }.padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Glyph(Glyphs.Heart, color = Ink.accent, dp = 26.dp)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            T("Любимое", style = Type.title)
            T(Format.tracks(likes.size), style = Type.small, color = Ink.mute)
        }
    }
    Spacer(Modifier.height(10.dp))
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(Ink.ink2).tap { g.nav.libraryTo(LibRoute.Import) }.padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Glyph(Glyphs.Download, color = Ink.accent, dp = 26.dp)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            T("Перенос музыки", style = Type.title)
            T("Из Яндекс Музыки, Spotify или списка", style = Type.small, color = Ink.mute)
        }
    }
    Spacer(Modifier.height(18.dp))
    T("МОИ ПЛЕЙЛИСТЫ", style = Type.label, color = Ink.faint)
    Spacer(Modifier.height(8.dp))
    Row(verticalAlignment = Alignment.CenterVertically) {
        TextBox(name, { name = it }, "Название нового плейлиста", Modifier.weight(1f), imeAction = ImeAction.Done, onDone = { createFrom(g, name) { name = "" } })
        Spacer(Modifier.width(8.dp))
        IconButton(Glyphs.Add, "Создать плейлист", { createFrom(g, name) { name = "" } }, color = Ink.accent)
    }
    Spacer(Modifier.height(8.dp))
    if (playlists.isEmpty()) {
        T("Плейлистов пока нет. Создайте первый или добавьте трек из плеера.", style = Type.small, color = Ink.mute)
    }
    for (p in playlists) {
        Row(
            Modifier.fillMaxWidth().tap { g.nav.libraryTo(LibRoute.Mine(p.id)) }.padding(vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Cover(p.cover ?: p.tracks.firstOrNull()?.artwork.orEmpty(), Modifier.size(52.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                T(p.name, style = Type.title, maxLines = 1)
                T(Format.tracks(p.tracks.size), style = Type.small, color = Ink.mute)
            }
        }
    }
    if (editorial.isNotEmpty()) {
        Spacer(Modifier.height(18.dp))
        T("ПОДБОРКИ BLINK", style = Type.label, color = Ink.faint)
        Spacer(Modifier.height(8.dp))
        for (e in editorial) {
            Row(Modifier.fillMaxWidth().tap { g.nav.libraryTo(LibRoute.Editorial(e.id)) }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Cover(e.cover, Modifier.size(52.dp))
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    T(e.title, style = Type.title, maxLines = 1)
                    if (e.description.isNotEmpty()) T(e.description, style = Type.small, color = Ink.mute, maxLines = 1)
                }
            }
        }
    }
}

private fun createFrom(g: Graph, name: String, done: () -> Unit) {
    val p = g.library.createPlaylist(name)
    done()
    g.nav.libraryTo(LibRoute.Mine(p.id))
}

@Composable
private fun MyPlaylist(g: Graph, id: String) {
    val lib by g.library.state.collectAsStateWithLifecycle()
    val p = remember(lib, id) { g.library.playlist(id) }
    val scope = rememberCoroutineScope()
    var renaming by remember { mutableStateOf(false) }
    var name by remember(p?.name) { mutableStateOf(p?.name.orEmpty()) }
    var confirmDelete by remember { mutableStateOf(false) }
    if (p == null) {
        T("Такого плейлиста нет.", style = Type.body, color = Ink.mute)
        return
    }
    PlaylistHeader(g, p.tracks, p.name, Format.tracks(p.tracks.size), cover = p.cover ?: p.tracks.firstOrNull()?.artwork.orEmpty())
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)) {
        PillButton("Поделиться", {
            scope.launch {
                try {
                    g.actions.share(g.shared.share(p))
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    g.toasts.show(e.message ?: "Нет связи с сервером")
                }
            }
        }, primary = false, enabled = p.tracks.isNotEmpty())
        PillButton("Имя", { renaming = !renaming }, primary = false)
        PillButton(if (confirmDelete) "Точно удалить?" else "Удалить", {
            if (confirmDelete) {
                g.library.deletePlaylist(p.id)
                scope.launch { runCatching { g.shared.unshare(p) } }
                g.nav.libraryTo(LibRoute.Home)
            } else confirmDelete = true
        }, primary = false, danger = true)
    }
    if (renaming) {
        Spacer(Modifier.height(10.dp))
        TextBox(name, { name = it }, "Название", imeAction = ImeAction.Done, onDone = { g.library.renamePlaylist(p.id, name); renaming = false })
    }
    Spacer(Modifier.height(14.dp))
    TrackList(g, p.tracks, emptyText = "Пока пусто. Добавляйте треки кнопкой «В плейлист» в плеере.", onRemove = { t -> g.library.removeFromPlaylist(p.id, t.id) })
}

@Composable
private fun RemotePlaylist(g: Graph, key: String, load: suspend () -> SharedPlaylist?, mine: Boolean) {
    var state by remember(key) { mutableStateOf<Any?>(Loading) }
    LaunchedEffect(key) {
        state = try { load() ?: Missing } catch (e: CancellationException) { throw e } catch (_: Exception) { Failed }
    }
    when (val s = state) {
        Loading -> T("Загружаем…", style = Type.body, color = Ink.mute)
        Missing -> T("Плейлист закрыт или ссылка устарела.", style = Type.body, color = Ink.mute)
        Failed -> T("Не получилось загрузить. Проверьте интернет.", style = Type.body, color = Ink.mute)
        is SharedPlaylist -> {
            PlaylistHeader(g, s.tracks, s.name, Format.tracks(s.tracks.size), cover = s.tracks.firstOrNull()?.artwork.orEmpty(), owner = s.owner)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                PillButton("Сохранить себе", {
                    g.library.createPlaylist(s.name, s.tracks)
                    g.toasts.show("Плейлист добавлен в ваши")
                }, primary = false, enabled = s.tracks.isNotEmpty() && !mine)
            }
            Spacer(Modifier.height(14.dp))
            TrackList(g, s.tracks, emptyText = "В плейлисте нет треков.", onRemove = null)
        }
    }
}

private object Loading
private object Missing
private object Failed

@Composable
private fun TrackList(g: Graph, tracks: List<Track>, emptyText: String, onRemove: ((Track) -> Unit)?) {
    val player by g.player.state.collectAsStateWithLifecycle()
    if (tracks.isEmpty()) {
        T(emptyText, style = Type.body, color = Ink.mute)
        return
    }
    tracks.forEachIndexed { i, t ->
        Row(Modifier.fillMaxWidth().tap { g.actions.play(tracks, i) }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Cover(t.artwork, Modifier.size(48.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                T(t.title, style = Type.title, color = if (player.track?.id == t.id) Ink.accent else Ink.bone, maxLines = 1)
                T(t.artist, style = Type.small, color = Ink.mute, maxLines = 1)
            }
            if (onRemove != null) IconButton(Glyphs.Delete, "Убрать из списка", { onRemove(t) }, color = Ink.faint)
        }
    }
}

/** Окно «В плейлист» поверх всего: выбрать плейлист или создать новый и положить в него трек. */
@Composable
fun PlaylistPicker(g: Graph) {
    val track by g.pickTrack.collectAsStateWithLifecycle()
    val t = track ?: return
    val lib by g.library.state.collectAsStateWithLifecycle()
    val playlists = remember(lib) { g.library.playlists }
    var name by remember { mutableStateOf("") }
    BackHandler { g.pickTrack.value = null }
    Box(Modifier.fillMaxSize().background(Ink.ink.copy(alpha = 0.72f)).tap { g.pickTrack.value = null }, contentAlignment = Alignment.BottomCenter) {
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp))
                .background(Ink.ink2)
                .tap { }
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
        ) {
            T("В плейлист", style = Type.h2)
            T(t.title + " · " + t.artist, style = Type.small, color = Ink.mute, maxLines = 1)
            Spacer(Modifier.height(12.dp))
            for (p in playlists) {
                Row(Modifier.fillMaxWidth().tap {
                    val added = g.library.addToPlaylist(p.id, t)
                    g.toasts.show(if (added) "Добавлено в «${p.name}»" else "Трек уже в этом плейлисте")
                    g.pickTrack.value = null
                }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Glyph(Glyphs.Queue, color = Ink.mute, dp = 22.dp)
                    Spacer(Modifier.width(12.dp))
                    T(p.name, style = Type.title, maxLines = 1, modifier = Modifier.weight(1f))
                    T(Format.tracks(p.tracks.size), style = Type.small, color = Ink.faint)
                }
            }
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextBox(name, { name = it }, "Новый плейлист", Modifier.weight(1f), imeAction = ImeAction.Done, onDone = { addToNew(g, name, t) })
                Spacer(Modifier.width(8.dp))
                IconButton(Glyphs.Add, "Создать и добавить", { addToNew(g, name, t) }, color = Ink.accent)
            }
        }
    }
}

private fun addToNew(g: Graph, name: String, t: Track) {
    val p = g.library.createPlaylist(name, listOf(t))
    g.toasts.show("Добавлено в «${p.name}»")
    g.pickTrack.value = null
}

/** Страница артиста Blink: обложка, подписчики, «Слушать», подписка и треки. Порт ProfilePage сайта (без загрузки треков и постов). */
@Composable
fun ArtistScreen(g: Graph) {
    val key by g.nav.artistKey.collectAsStateWithLifecycle()
    val session by g.auth.session.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var phase by remember(key) { mutableStateOf<Any?>(Loading) }
    var following by remember(key) { mutableStateOf(false) }
    var followers by remember(key) { mutableStateOf(0L) }
    var attempt by remember(key) { mutableStateOf(0) }
    LaunchedEffect(key, attempt) {
        phase = Loading
        phase = try {
            g.artists.profile(key)?.also { followers = it.followers } ?: Missing
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            Failed
        }
    }
    val profile = phase as? app.blink.core.library.ArtistProfile
    LaunchedEffect(profile?.id, session?.userId) {
        following = if (profile != null && session != null && profile.userId != session?.userId) runCatching { g.artists.isFollowing(profile.id) }.getOrDefault(false) else false
    }
    Sheet(g, profile?.name ?: "Артист") {
        when (val p = phase) {
            Loading -> T("Загружаем…", style = Type.body, color = Ink.mute)
            Missing -> T("Такой страницы нет.", style = Type.body, color = Ink.mute)
            Failed -> {
                T("Не получилось загрузить. Проверьте интернет.", style = Type.body, color = Ink.mute)
                Spacer(Modifier.height(10.dp))
                PillButton("Повторить", { attempt++ }, primary = false)
            }
            is app.blink.core.library.ArtistProfile -> {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Cover(p.avatar.orEmpty(), Modifier.size(84.dp), radius = 42.dp)
                    Spacer(Modifier.width(16.dp))
                    Column {
                        T(p.name + if (p.verified) " ✓" else "", style = Type.h1, maxLines = 2)
                        T(listOf("$followers подп.", Format.tracks(p.tracks.size), if (p.likes > 0) "${p.likes} лайков" else null).filterNotNull().joinToString(" · "), style = Type.small, color = Ink.mute)
                    }
                }
                if (!p.bio.isNullOrBlank()) {
                    Spacer(Modifier.height(12.dp))
                    T(p.bio!!, style = Type.body, color = Ink.mute)
                }
                Spacer(Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PillButton("Слушать", { g.actions.play(p.tracks, 0) }, enabled = p.tracks.isNotEmpty())
                    if (session?.userId != p.userId) {
                        PillButton(if (following) "Вы подписаны" else "Подписаться", {
                            if (session == null) {
                                g.toasts.show("Войдите, чтобы подписаться")
                                g.nav.go(app.blink.player.Tab.Account)
                            } else {
                                val on = !following
                                following = on
                                followers += if (on) 1 else -1
                                scope.launch {
                                    if (!g.artists.setFollow(p.id, on)) {
                                        following = !on
                                        followers += if (on) -1 else 1
                                        g.toasts.show("Не получилось, попробуйте ещё раз")
                                    }
                                }
                            }
                        }, primary = false)
                    }
                }
                Spacer(Modifier.height(10.dp))
                SimilarArtists(g, p.name)
                Spacer(Modifier.height(14.dp))
                TrackList(g, p.tracks, emptyText = "Пока нет треков.", onRemove = null)
                Spacer(Modifier.height(22.dp))
                PostsSection(g, p.id, own = session?.userId != null && session?.userId == p.userId, tracks = p.tracks)
            }
        }
    }
}


/** Перенос музыки: ссылка, CSV или список «Артист — Название» в «Любимое» или в новый плейлист. */
@Composable
private fun ImportPanel(g: Graph) {
    val scope = rememberCoroutineScope()
    val ctx = androidx.compose.ui.platform.LocalContext.current
    var text by remember { mutableStateOf("") }
    var toLikes by remember { mutableStateOf(true) }
    var progress by remember { mutableStateOf<Pair<Int, Int>?>(null) }
    var reading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var result by remember { mutableStateOf<app.blink.core.library.ImportRun?>(null) }
    var resultToLikes by remember { mutableStateOf(true) }
    val picker = androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) runCatching { ctx.contentResolver.openInputStream(uri)?.use { text = it.readBytes().toString(Charsets.UTF_8) } }
    }
    val r = result
    if (r != null) {
        T("Готово", style = Type.h1)
        Spacer(Modifier.height(8.dp))
        T("Перенесено ${Format.tracks(r.found.size)} из ${r.total} " + if (resultToLikes) "в «Любимое»." else "в плейлист «${r.title}».", style = Type.body, color = Ink.mute)
        if (r.missed.isNotEmpty()) {
            Spacer(Modifier.height(14.dp))
            T("НЕ НАШЛИСЬ (${r.missed.size})", style = Type.label, color = Ink.faint)
            Spacer(Modifier.height(6.dp))
            for (m in r.missed.take(50)) T((if (m.artist.isNotEmpty()) m.artist + " — " else "") + m.title, style = Type.small, color = Ink.mute, maxLines = 1)
        }
        Spacer(Modifier.height(16.dp))
        PillButton("Отлично", { result = null; text = ""; g.nav.libraryTo(LibRoute.Home) })
        return
    }
    T("Скопируйте ссылку на плейлист или альбом (Яндекс Музыка, Spotify), загрузите CSV из TuneMyMusic или вставьте список: по треку в строке, «Артист — Название». Плейлист должен быть публичным.", style = Type.body, color = Ink.mute)
    Spacer(Modifier.height(12.dp))
    androidx.compose.foundation.text.BasicTextField(
        value = text,
        onValueChange = { text = it },
        textStyle = Type.body.copy(color = Ink.bone),
        cursorBrush = androidx.compose.ui.graphics.SolidColor(Ink.accent),
        modifier = Modifier.fillMaxWidth().height(160.dp),
        decorationBox = { inner ->
            Box(Modifier.fillMaxSize().clip(RoundedCornerShape(20.dp)).background(Ink.ink2).padding(16.dp)) {
                if (text.isEmpty()) T("https://music.yandex.ru/users/…/playlists/…\n\nили списком:\nMiyagi & Andy Panda — Kosandra", style = Type.body, color = Ink.faint)
                inner()
            }
        },
    )
    Spacer(Modifier.height(10.dp))
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        PillButton("Выбрать файл", { picker.launch(arrayOf("text/*", "application/vnd.ms-excel", "application/octet-stream")) }, primary = false)
        Chip("В «Любимое»", active = toLikes) { toLikes = true }
        Chip("В новый плейлист", active = !toLikes) { toLikes = false }
    }
    Spacer(Modifier.height(14.dp))
    val p = progress
    if (reading || p != null) {
        T(if (reading) "Читаю плейлист…" else "Ищу треки… ${p?.first} из ${p?.second}", style = Type.small, color = Ink.mute)
        Spacer(Modifier.height(6.dp))
        BarProgress(if (reading || p == null || p.second == 0) 0f else p.first.toFloat() / p.second)
    } else {
        val src = app.blink.core.library.Importer.sourceOf(text)
        PillButton(if (src != null) "Перенести из ${src.title}" else "Перенести", {
            if (g.auth.session.value == null) {
                g.toasts.show("Войдите, чтобы переносить музыку")
                g.nav.go(app.blink.player.Tab.Account)
                return@PillButton
            }
            error = null
            reading = src != null
            val saveToLikes = toLikes
            scope.launch {
                try {
                    val run = g.importer.run(text) { d, t ->
                        reading = false
                        progress = d to t
                    }
                    if (saveToLikes) g.library.addLikes(run.found) else g.library.createPlaylist(run.title, run.found)
                    resultToLikes = saveToLikes
                    result = run
                } catch (e: CancellationException) {
                    throw e
                } catch (e: app.blink.core.library.ImportException) {
                    error = e.message
                } catch (_: Exception) {
                    error = "Не получилось, попробуйте ещё раз"
                } finally {
                    reading = false
                    progress = null
                }
            }
        }, enabled = text.isNotBlank())
        error?.let {
            Spacer(Modifier.height(8.dp))
            T(it, style = Type.small, color = Ink.danger)
        }
    }
}
