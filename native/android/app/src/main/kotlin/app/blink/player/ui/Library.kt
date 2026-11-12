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
    }
    Sheet(g, title) {
        when (val r = route) {
            LibRoute.Home -> LibraryHome(g)
            LibRoute.Likes -> TrackList(g, remember(lib) { g.library.likes }, emptyText = "Нажмите сердечко у трека, и он появится здесь.", onRemove = { t -> g.library.toggleLike(t) })
            is LibRoute.Mine -> MyPlaylist(g, r.id)
            is LibRoute.Shared -> RemotePlaylist(g, key = "s" + r.code, load = { g.shared.fetchShared(r.code) }, mine = false)
            is LibRoute.Editorial -> RemotePlaylist(g, key = "e" + r.id, load = { g.shared.editorialOne(r.id) }, mine = false)
        }
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
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        PillButton("Играть", { g.actions.play(p.tracks, 0) }, enabled = p.tracks.isNotEmpty())
        PillButton("Сохранить офлайн", { g.actions.saveAll(p.tracks) }, primary = false, enabled = p.tracks.isNotEmpty())
    }
    Spacer(Modifier.height(8.dp))
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
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
            T(s.name, style = Type.h1, maxLines = 2)
            if (s.owner.isNotEmpty()) T("от " + s.owner, style = Type.small, color = Ink.mute)
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PillButton("Играть", { g.actions.play(s.tracks, 0) }, enabled = s.tracks.isNotEmpty())
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
                Spacer(Modifier.height(14.dp))
                TrackList(g, p.tracks, emptyText = "Пока нет треков.", onRemove = null)
            }
        }
    }
}
