package app.blink.player.ui

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.blink.core.library.ArtistMe
import app.blink.core.library.Comment
import app.blink.core.library.FaqItem
import app.blink.core.library.MyTrack
import app.blink.core.library.Post
import app.blink.core.library.SimilarArtist
import app.blink.core.library.SimilarTrack
import app.blink.core.library.SupportApi
import app.blink.core.library.TicketRow
import app.blink.core.library.TicketView
import app.blink.core.library.UploadDraft
import app.blink.core.library.UploadFile
import app.blink.core.model.Track
import app.blink.player.Graph
import app.blink.player.Tab
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Многострочное поле в стиле Blink. */
@Composable
fun TextArea(value: String, onChange: (String) -> Unit, hint: String, modifier: Modifier = Modifier, minHeight: Int = 96) {
    BasicTextField(
        value = value,
        onValueChange = onChange,
        textStyle = Type.body.copy(color = Ink.bone),
        cursorBrush = SolidColor(Ink.accent),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text),
        modifier = modifier.fillMaxWidth(),
        decorationBox = { inner ->
            Box(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = minHeight.dp)
                    .clip(RoundedCornerShape(22.dp))
                    .background(Ink.ink2)
                    .border(1.dp, Ink.line2, RoundedCornerShape(22.dp))
                    .padding(horizontal = 18.dp, vertical = 14.dp),
            ) {
                if (value.isEmpty()) T(hint, style = Type.body, color = Ink.faint)
                inner()
            }
        },
    )
}

@Composable
private fun Head(title: String) {
    Spacer(Modifier.height(4.dp))
    T(title, style = Type.h2, maxLines = 1)
    Spacer(Modifier.height(8.dp))
}

private fun compactNum(n: Long): String = when {
    n >= 1_000_000 -> String.format(java.util.Locale.ROOT, "%.1f", n / 1_000_000.0).replace('.', ',') + " млн"
    n >= 10_000 -> (n / 1000).toString() + " тыс."
    else -> n.toString()
}

/** «2026-11-01T10:00:00Z» → «01.11.2026». */
internal fun dateRu(iso: String): String {
    val d = iso.take(10).split('-')
    return if (d.size == 3) "${d[2]}.${d[1]}.${d[0]}" else iso
}

private fun clean(e: Exception): String = e.message?.takeIf { it.isNotBlank() && e !is java.io.IOException } ?: "Не получилось, проверьте интернет"

// ---------------------------------------------------------------- анонсы и комментарии

/** Анонсы артиста с лайками и комментариями. У владельца сверху поле нового анонса. */
@Composable
internal fun PostsSection(g: Graph, artistId: String, own: Boolean, tracks: List<Track>) {
    val scope = rememberCoroutineScope()
    val session by g.auth.session.collectAsStateWithLifecycle()
    var list by remember(artistId) { mutableStateOf<List<Post>?>(null) }
    var failed by remember(artistId) { mutableStateOf(false) }
    var attempt by remember(artistId) { mutableStateOf(0) }
    LaunchedEffect(artistId, attempt, session?.userId) {
        failed = false
        try {
            list = g.posts.posts(artistId)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            failed = true
            if (list == null) list = emptyList()
        }
    }
    Head("Анонсы")
    if (own) {
        var text by remember { mutableStateOf("") }
        var attach by remember { mutableStateOf<Track?>(null) }
        var busy by remember { mutableStateOf(false) }
        TextArea(text, { text = it.take(1000) }, "Что нового? Расскажите подписчикам", minHeight = 80)
        if (tracks.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                tracks.take(20).forEach { t -> Chip(t.title, active = attach?.id == t.id) { attach = if (attach?.id == t.id) null else t } }
            }
        }
        Spacer(Modifier.height(10.dp))
        PillButton(if (busy) "Публикуем…" else "Опубликовать", {
            busy = true
            scope.launch {
                try {
                    g.posts.createPost(artistId, text.trim(), attach?.id?.removePrefix("b:"))
                    text = ""
                    attach = null
                    attempt++
                    g.toasts.show("Анонс опубликован")
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    g.toasts.show(clean(e))
                }
                busy = false
            }
        }, enabled = !busy && text.isNotBlank())
        Spacer(Modifier.height(14.dp))
    }
    val posts = list
    when {
        posts == null -> T("Загружаем…", style = Type.body, color = Ink.mute)
        failed && posts.isEmpty() -> {
            T("Не получилось загрузить анонсы.", style = Type.body, color = Ink.mute)
            Spacer(Modifier.height(8.dp))
            PillButton("Повторить", { attempt++ }, primary = false)
        }
        posts.isEmpty() -> if (!own) T("Анонсов пока нет.", style = Type.body, color = Ink.mute)
        else -> posts.forEach { p ->
            PostCard(g, p, own, onChanged = { attempt++ })
            Spacer(Modifier.height(10.dp))
        }
    }
}

@Composable
private fun PostCard(g: Graph, p0: Post, own: Boolean, onChanged: () -> Unit) {
    val scope = rememberCoroutineScope()
    val session by g.auth.session.collectAsStateWithLifecycle()
    var p by remember(p0) { mutableStateOf(p0) }
    var open by remember(p0.id) { mutableStateOf(false) }
    Panel {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Cover(p.avatar.orEmpty(), Modifier.size(36.dp), radius = 18.dp)
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                T(p.artistName, style = Type.title, maxLines = 1)
                T(dateRu(p.createdAt), style = Type.small, color = Ink.faint)
            }
        }
        Spacer(Modifier.height(10.dp))
        T(p.body, style = Type.body)
        val t = p.track
        if (t != null) {
            Spacer(Modifier.height(10.dp))
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Ink.ink3).tap { g.actions.play(listOf(t), 0) }.padding(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Cover(t.artwork, Modifier.size(44.dp))
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    T(t.title, style = Type.title, maxLines = 1)
                    T(t.artist, style = Type.small, color = Ink.mute, maxLines = 1)
                }
                Glyph(Glyphs.Play, color = Ink.accent, dp = 22.dp)
            }
        }
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(
                Modifier.clip(CircleShape).tap {
                    if (session == null) {
                        g.toasts.show("Войдите, чтобы ставить лайки")
                        return@tap
                    }
                    val on = !p.liked
                    p = p.copy(liked = on, likes = p.likes + if (on) 1 else -1)
                    scope.launch { if (!g.posts.setPostLike(p.id, on)) p = p.copy(liked = !on, likes = p.likes + if (on) -1 else 1) }
                }.padding(horizontal = 10.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Glyph(if (p.liked) Glyphs.Heart else Glyphs.HeartOutline, color = if (p.liked) Ink.accent else Ink.mute, dp = 20.dp)
                Spacer(Modifier.width(6.dp))
                T(p.likes.toString(), style = Type.small, color = Ink.mute)
            }
            Chip(if (open) "Скрыть комментарии" else "Комментарии", active = open) { open = !open }
            Spacer(Modifier.weight(1f))
            if (own) {
                IconButton(Glyphs.Delete, "Удалить анонс", {
                    scope.launch {
                        try {
                            g.posts.deletePost(p.id)
                            onChanged()
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            g.toasts.show(clean(e))
                        }
                    }
                }, color = Ink.faint, box = 36.dp, dp = 20.dp)
            } else {
                Chip("Пожаловаться") { reportTo(g, scope, "post", p.id) }
            }
        }
        if (open) {
            Spacer(Modifier.height(8.dp))
            CommentsBlock(g, postId = p.id, trackId = null)
        }
    }
}

private fun reportTo(g: Graph, scope: kotlinx.coroutines.CoroutineScope, kind: String, id: String) {
    if (g.auth.session.value == null) {
        g.toasts.show("Войдите, чтобы пожаловаться")
        return
    }
    scope.launch {
        try {
            g.posts.report(kind, id)
            g.toasts.show("Жалоба отправлена, спасибо")
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            g.toasts.show(clean(e))
        }
    }
}

@Composable
internal fun CommentsBlock(g: Graph, postId: String?, trackId: String?) {
    val scope = rememberCoroutineScope()
    val session by g.auth.session.collectAsStateWithLifecycle()
    var list by remember(postId, trackId) { mutableStateOf<List<Comment>?>(null) }
    var attempt by remember(postId, trackId) { mutableStateOf(0) }
    var failed by remember(postId, trackId) { mutableStateOf(false) }
    var text by remember(postId, trackId) { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    LaunchedEffect(postId, trackId, attempt) {
        failed = false
        try {
            list = g.posts.comments(postId, trackId)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            failed = true
            if (list == null) list = emptyList()
        }
    }
    val items = list
    when {
        items == null -> T("Загружаем…", style = Type.small, color = Ink.mute)
        failed && items.isEmpty() -> T("Не получилось загрузить комментарии.", style = Type.small, color = Ink.mute)
        items.isEmpty() -> T("Комментариев пока нет. Будьте первым.", style = Type.small, color = Ink.mute)
        else -> items.forEach { c ->
            Row(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                Cover(c.avatar.orEmpty(), Modifier.size(30.dp), radius = 15.dp)
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        T(c.name, style = Type.small.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Bold), maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                        Spacer(Modifier.width(8.dp))
                        T(dateRu(c.createdAt), style = Type.small, color = Ink.faint)
                    }
                    T(c.body, style = Type.body)
                    if (session != null) {
                        Spacer(Modifier.height(2.dp))
                        if (c.userId == session?.userId) {
                            T("Удалить", style = Type.small, color = Ink.faint, modifier = Modifier.tap {
                                scope.launch {
                                    try {
                                        g.posts.deleteComment(c.id)
                                        attempt++
                                    } catch (e: CancellationException) {
                                        throw e
                                    } catch (e: Exception) {
                                        g.toasts.show(clean(e))
                                    }
                                }
                            })
                        } else {
                            T("Пожаловаться", style = Type.small, color = Ink.faint, modifier = Modifier.tap { reportTo(g, scope, "comment", c.id) })
                        }
                    }
                }
            }
        }
    }
    Spacer(Modifier.height(8.dp))
    if (session == null) {
        T("Войдите, чтобы написать комментарий.", style = Type.small, color = Ink.mute, modifier = Modifier.tap { g.nav.go(Tab.Account) })
        return
    }
    TextBox(text, { text = it.take(1000) }, "Ваш комментарий", imeAction = androidx.compose.ui.text.input.ImeAction.Send)
    Spacer(Modifier.height(8.dp))
    PillButton(if (busy) "Отправляем…" else "Отправить", {
        busy = true
        scope.launch {
            try {
                g.posts.addComment(text, postId, trackId)
                text = ""
                attempt++
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                g.toasts.show(clean(e))
            }
            busy = false
        }
    }, primary = false, enabled = !busy && text.isNotBlank())
}

// ---------------------------------------------------------------- похожее (Last.fm)

/** Слушатели и похожие артисты. Если Last.fm недоступен, блок просто не показывается. */
@Composable
internal fun SimilarArtists(g: Graph, name: String) {
    var listeners by remember(name) { mutableStateOf<Long?>(null) }
    var similar by remember(name) { mutableStateOf<List<SimilarArtist>>(emptyList()) }
    LaunchedEffect(name) {
        listeners = runCatching { g.lastfm.listeners(name) }.getOrNull()
        similar = runCatching { g.lastfm.similarArtists(name) }.getOrDefault(emptyList())
    }
    val l = listeners
    if (l != null) T("${compactNum(l)} слушателей в Last.fm", style = Type.small, color = Ink.faint)
    if (similar.isNotEmpty()) {
        Spacer(Modifier.height(10.dp))
        T("ПОХОЖИЕ АРТИСТЫ", style = Type.label, color = Ink.mute)
        Spacer(Modifier.height(6.dp))
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            similar.take(12).forEach { a -> Chip(a.name) { searchFor(g, a.name) } }
        }
    }
}

private fun searchFor(g: Graph, q: String) {
    g.search.setQuery(q)
    g.nav.go(Tab.Search)
}

/** Окно «О треке» поверх плеера: похожие треки (Last.fm) и комментарии к трекам Blink. */
@Composable
fun TrackInfoSheet(g: Graph) {
    val track by g.infoTrack.collectAsStateWithLifecycle()
    val t = track ?: return
    var similar by remember(t.id) { mutableStateOf<List<SimilarTrack>?>(null) }
    LaunchedEffect(t.id) { similar = runCatching { g.lastfm.similarTracks(t.artist, t.title) }.getOrDefault(emptyList()) }
    BackHandler { g.infoTrack.value = null }
    Box(Modifier.fillMaxSize().background(Ink.ink.copy(alpha = 0.72f)).tap { g.infoTrack.value = null }, contentAlignment = Alignment.BottomCenter) {
        Column(
            Modifier
                .fillMaxWidth()
                .heightIn(max = 640.dp)
                .clip(RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp))
                .background(Ink.ink2)
                .tap { }
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
        ) {
            T("О треке", style = Type.h2)
            T(t.title + " · " + t.artist, style = Type.small, color = Ink.mute, maxLines = 1)
            Spacer(Modifier.height(14.dp))
            SimilarArtists(g, t.artist)
            val s = similar
            if (s != null && s.isNotEmpty()) {
                Spacer(Modifier.height(14.dp))
                T("ПОХОЖИЕ ТРЕКИ", style = Type.label, color = Ink.mute)
                Spacer(Modifier.height(4.dp))
                s.take(10).forEach { x ->
                    Column(Modifier.fillMaxWidth().tap { g.infoTrack.value = null; searchFor(g, x.artist + " " + x.title) }.padding(vertical = 7.dp)) {
                        T(x.title, style = Type.title, maxLines = 1)
                        T(x.artist, style = Type.small, color = Ink.mute, maxLines = 1)
                    }
                }
            }
            if (t.id.startsWith("b:")) {
                Spacer(Modifier.height(14.dp))
                T("КОММЕНТАРИИ", style = Type.label, color = Ink.mute)
                Spacer(Modifier.height(6.dp))
                CommentsBlock(g, postId = null, trackId = t.id.removePrefix("b:"))
            }
            Spacer(Modifier.height(12.dp))
            PillButton("Закрыть", { g.infoTrack.value = null }, primary = false)
        }
    }
}

// ---------------------------------------------------------------- поддержка

private sealed interface SupportView {
    data object Home : SupportView
    data class Ticket(val id: String) : SupportView
}

@Composable
fun SupportScreen(g: Graph) {
    var view by remember { mutableStateOf<SupportView>(SupportView.Home) }
    when (val v = view) {
        SupportView.Home -> SupportHome(g) { view = SupportView.Ticket(it) }
        is SupportView.Ticket -> TicketScreen(g, v.id) { view = SupportView.Home }
    }
}

@Composable
private fun SupportHome(g: Graph, onOpen: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    val session by g.auth.session.collectAsStateWithLifecycle()
    var faq by remember { mutableStateOf<List<FaqItem>>(emptyList()) }
    var opened by remember { mutableStateOf<String?>(null) }
    var text by remember { mutableStateOf("") }
    var contact by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var auto by remember { mutableStateOf<Pair<String, String>?>(null) }
    var tickets by remember { mutableStateOf<List<TicketRow>>(emptyList()) }
    var refresh by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) { faq = runCatching { g.support.faq() }.getOrDefault(emptyList()) }
    LaunchedEffect(session?.userId, refresh) { tickets = if (session == null) emptyList() else runCatching { g.support.mine() }.getOrDefault(emptyList()) }
    Sheet(g, "Помощь") {
        T("Ответы на частые вопросы. Если не нашли своё, напишите нам.", style = Type.body, color = Ink.mute)
        Spacer(Modifier.height(14.dp))
        faq.forEach { f ->
            Panel(Modifier.tap { opened = if (opened == f.id) null else f.id }) {
                T(f.question, style = Type.title)
                if (opened == f.id) {
                    Spacer(Modifier.height(6.dp))
                    T(f.answer, style = Type.body, color = Ink.mute)
                }
            }
            Spacer(Modifier.height(8.dp))
        }
        Spacer(Modifier.height(10.dp))
        Head("Написать в поддержку")
        TextArea(text, { text = it.take(4000); auto = null }, "Что случилось?")
        val hint = if (text.length > 8) SupportApi.bestAnswer(faq, text) else null
        if (hint != null) {
            Spacer(Modifier.height(8.dp))
            Panel {
                T("Возможно, это поможет", style = Type.label, color = Ink.accent)
                Spacer(Modifier.height(4.dp))
                T(hint.question, style = Type.title)
                T(hint.answer, style = Type.body, color = Ink.mute)
            }
        }
        if (session == null) {
            Spacer(Modifier.height(8.dp))
            TextBox(contact, { contact = it.take(200) }, "Как с вами связаться (почта или Telegram)")
        }
        Spacer(Modifier.height(10.dp))
        PillButton(if (busy) "Отправляем…" else "Отправить", {
            busy = true
            scope.launch {
                try {
                    val r = g.support.send(text.trim(), contact.trim().ifEmpty { null })
                    text = ""
                    auto = if (r.autoQuestion != null && r.autoAnswer != null) r.autoQuestion!! to r.autoAnswer!! else null
                    g.toasts.show("Отправили. Ответ придёт сюда")
                    refresh++
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    g.toasts.show(clean(e))
                }
                busy = false
            }
        }, enabled = !busy && text.isNotBlank())
        val a = auto
        if (a != null) {
            Spacer(Modifier.height(10.dp))
            Panel {
                T("Пока вы ждёте ответ команды", style = Type.label, color = Ink.accent)
                Spacer(Modifier.height(4.dp))
                T(a.first, style = Type.title)
                T(a.second, style = Type.body, color = Ink.mute)
            }
        }
        if (tickets.isNotEmpty()) {
            Spacer(Modifier.height(20.dp))
            Head("Ваши обращения")
            tickets.forEach { t ->
                Panel(Modifier.tap { onOpen(t.id) }) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        T(t.message.ifBlank { "(картинка)" }, style = Type.body, maxLines = 2, modifier = Modifier.weight(1f))
                        Spacer(Modifier.width(8.dp))
                        Chip(statusRu(t.status), active = t.status == "answered")
                    }
                    T(dateRu(t.updatedAt), style = Type.small, color = Ink.faint)
                }
                Spacer(Modifier.height(8.dp))
            }
        }
    }
}

private fun statusRu(s: String) = when (s) {
    "answered" -> "Есть ответ"
    "closed" -> "Закрыто"
    else -> "Ждёт ответа"
}

@Composable
private fun TicketScreen(g: Graph, id: String, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var t by remember(id) { mutableStateOf<TicketView?>(null) }
    var error by remember(id) { mutableStateOf<String?>(null) }
    var reply by remember(id) { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var attempt by remember { mutableStateOf(0) }
    LaunchedEffect(id, attempt) {
        try {
            t = g.support.open(id)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = clean(e)
        }
    }
    Sheet(g, "Обращение") {
        BackHandler(onBack = onBack)
        val v = t
        if (v == null) {
            T(error ?: "Загружаем…", style = Type.body, color = Ink.mute)
            Spacer(Modifier.height(10.dp))
            PillButton("Назад", onBack, primary = false)
            return@Sheet
        }
        Chip(statusRu(v.status), active = v.status == "answered")
        Spacer(Modifier.height(10.dp))
        Bubble("Вы", v.message, mine = true)
        v.messages.forEach { m -> Bubble(if (m.author == "user") "Вы" else "Команда Blink", m.body, mine = m.author == "user") }
        Spacer(Modifier.height(12.dp))
        if (v.status != "closed") {
            TextArea(reply, { reply = it.take(4000) }, "Ваш ответ", minHeight = 70)
            Spacer(Modifier.height(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PillButton(if (busy) "Отправляем…" else "Ответить", {
                    busy = true
                    scope.launch {
                        try {
                            g.support.reply(id, reply.trim())
                            reply = ""
                            attempt++
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            g.toasts.show(clean(e))
                        }
                        busy = false
                    }
                }, enabled = !busy && reply.isNotBlank())
                PillButton("Закрыть обращение", {
                    scope.launch {
                        runCatching { g.support.close(id) }.onFailure { g.toasts.show(clean(it as Exception)) }
                        attempt++
                    }
                }, primary = false)
            }
        }
        Spacer(Modifier.height(10.dp))
        PillButton("К списку", onBack, primary = false)
    }
}

@Composable
private fun Bubble(who: String, text: String, mine: Boolean) {
    Column(Modifier.fillMaxWidth().padding(vertical = 5.dp), horizontalAlignment = if (mine) Alignment.End else Alignment.Start) {
        T(who, style = Type.label, color = Ink.faint)
        Spacer(Modifier.height(3.dp))
        Box(
            Modifier.clip(RoundedCornerShape(18.dp)).background(if (mine) Ink.accentSoft else Ink.ink3).padding(horizontal = 14.dp, vertical = 10.dp),
        ) { T(text.ifBlank { "(картинка)" }, style = Type.body) }
    }
}

// ---------------------------------------------------------------- кабинет артиста

private fun copyPicked(ctx: Context, uri: Uri, fallback: String): UploadFile? {
    val cr = ctx.contentResolver
    val name = cr.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else null } ?: fallback
    val mime = cr.getType(uri) ?: "application/octet-stream"
    val f = File(ctx.cacheDir, "upload-" + System.nanoTime() + "-" + name.filter { it.isLetterOrDigit() || it == '.' })
    cr.openInputStream(uri)?.use { i -> f.outputStream().use { o -> i.copyTo(o) } } ?: return null
    return UploadFile(name, mime, f)
}

@Composable
fun CabinetScreen(g: Graph) {
    val session by g.auth.session.collectAsStateWithLifecycle()
    var me by remember { mutableStateOf<ArtistMe?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableStateOf(0) }
    LaunchedEffect(session?.userId, attempt) {
        if (session == null) return@LaunchedEffect
        error = null
        try {
            me = g.cabinet.me()
            loaded = true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = clean(e)
        }
    }
    Sheet(g, "Кабинет артиста") {
        val m = me
        when {
            session == null -> EmptyState(Glyphs.Person, "Нужен аккаунт", "Войдите, чтобы загружать музыку и вести страницу артиста.", button = "Войти") { g.nav.go(Tab.Account) }
            error != null -> {
                T(error!!, style = Type.body, color = Ink.mute)
                Spacer(Modifier.height(10.dp))
                PillButton("Повторить", { attempt++ }, primary = false)
            }
            !loaded -> T("Загружаем…", style = Type.body, color = Ink.mute)
            m == null || !m.offerAccepted -> OfferCard(g, m) { me = it }
            else -> CabinetBody(g, m) { me = it }
        }
    }
}

@Composable
private fun OfferCard(g: Graph, existing: ArtistMe?, onDone: (ArtistMe) -> Unit) {
    val scope = rememberCoroutineScope()
    val uri = LocalUriHandler.current
    var name by remember { mutableStateOf(existing?.name ?: g.auth.session.value?.name.orEmpty()) }
    var agree by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    Panel {
        T("Стать артистом Blink", style = Type.h2)
        Spacer(Modifier.height(6.dp))
        T("Выкладывайте свою музыку, ведите страницу и публикуйте анонсы для подписчиков. Нужно принять оферту.", style = Type.body, color = Ink.mute)
        Spacer(Modifier.height(12.dp))
        TextBox(name, { name = it.take(120) }, "Имя артиста")
        Spacer(Modifier.height(10.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Chip(if (agree) "Принимаю условия" else "Принять условия оферты", active = agree) { agree = !agree }
            Spacer(Modifier.width(8.dp))
            T("Читать оферту", style = Type.small, color = Ink.accent, modifier = Modifier.tap { uri.openUri("https://blinkmusic.cc/offer.html") })
        }
        Spacer(Modifier.height(12.dp))
        PillButton(if (busy) "Сохраняем…" else "Продолжить", {
            busy = true
            scope.launch {
                try {
                    onDone(g.cabinet.acceptOffer(name))
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    g.toasts.show(clean(e))
                }
                busy = false
            }
        }, enabled = !busy && agree && name.isNotBlank())
    }
}

@Composable
private fun CabinetBody(g: Graph, me: ArtistMe, onMe: (ArtistMe) -> Unit) {
    val scope = rememberCoroutineScope()
    var bio by remember(me.id) { mutableStateOf(me.bio.orEmpty()) }
    var savingBio by remember { mutableStateOf(false) }
    var mine by remember { mutableStateOf<List<MyTrack>?>(null) }
    var attempt by remember { mutableStateOf(0) }
    var confirm by remember { mutableStateOf<String?>(null) }
    var uploading by remember { mutableStateOf(false) }
    LaunchedEffect(attempt) { mine = runCatching { g.cabinet.mine() }.getOrDefault(emptyList()) }
    T(me.name, style = Type.h1, maxLines = 2)
    Spacer(Modifier.height(10.dp))
    PillButton("Открыть мою страницу", { g.nav.openArtist(me.id) }, primary = false)
    Spacer(Modifier.height(18.dp))
    Head("О себе")
    TextArea(bio, { bio = it.take(500) }, "Пара слов для слушателей", minHeight = 80)
    Spacer(Modifier.height(8.dp))
    PillButton(if (savingBio) "Сохраняем…" else "Сохранить", {
        savingBio = true
        scope.launch {
            try {
                g.posts.saveBio(me.id, bio)
                onMe(me.copy(bio = bio.trim().ifEmpty { null }))
                g.toasts.show("Сохранили")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                g.toasts.show(clean(e))
            }
            savingBio = false
        }
    }, primary = false, enabled = !savingBio && bio.trim() != me.bio.orEmpty())
    Spacer(Modifier.height(22.dp))
    Head("Новый трек")
    if (!uploading) {
        PillButton("Загрузить трек", { uploading = true })
    } else {
        UploadForm(g, me, onClose = { uploading = false }, onDone = { uploading = false; attempt++ })
    }
    Spacer(Modifier.height(22.dp))
    Head("Мои релизы")
    val list = mine
    when {
        list == null -> T("Загружаем…", style = Type.body, color = Ink.mute)
        list.isEmpty() -> T("Пока ни одного релиза.", style = Type.body, color = Ink.mute)
        else -> list.forEach { t ->
            Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Cover(t.cover.orEmpty(), Modifier.size(48.dp))
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    T(t.title, style = Type.title, maxLines = 1)
                    T("${t.releaseTitle} · ${dateRu(t.releaseDate)}", style = Type.small, color = Ink.mute, maxLines = 1)
                    T("${t.streamsTotal} прослушиваний, ${t.streamsMonth} за месяц" + if (t.status != "live") " · ${t.status}" else "", style = Type.small, color = Ink.faint, maxLines = 1)
                }
                if (confirm == t.id) {
                    PillButton("Снять", {
                        confirm = null
                        scope.launch {
                            try {
                                g.cabinet.takedown(t.id)
                                attempt++
                                g.toasts.show("Трек снят")
                            } catch (e: CancellationException) {
                                throw e
                            } catch (e: Exception) {
                                g.toasts.show(clean(e))
                            }
                        }
                    }, danger = true)
                } else {
                    IconButton(Glyphs.Delete, "Снять трек", { confirm = t.id }, color = Ink.faint)
                }
            }
        }
    }
    Spacer(Modifier.height(22.dp))
    PostsSection(g, me.id, own = true, tracks = emptyList())
}

@Composable
private fun UploadForm(g: Graph, me: ArtistMe, onClose: () -> Unit, onDone: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val today = remember { java.time.LocalDate.now().toString() }
    var d by remember { mutableStateOf(UploadDraft(phonogramMaker = me.name, year = today.take(4), releaseDate = today)) }
    var audio by remember { mutableStateOf<UploadFile?>(null) }
    var cover by remember { mutableStateOf<UploadFile?>(null) }
    var progress by remember { mutableStateOf<Double?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val pickAudio = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch { audio = withContext(Dispatchers.IO) { runCatching { copyPicked(ctx, uri, "track.mp3") }.getOrNull() } }
    }
    val pickCover = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch { cover = withContext(Dispatchers.IO) { runCatching { copyPicked(ctx, uri, "cover.jpg") }.getOrNull() } }
    }
    Panel {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            PillButton(audio?.name ?: "Аудио: WAV, FLAC, MP3", { pickAudio.launch(arrayOf("audio/*")) }, primary = audio == null)
        }
        Spacer(Modifier.height(8.dp))
        PillButton(cover?.name ?: "Обложка: JPEG или PNG", { pickCover.launch(arrayOf("image/jpeg", "image/png", "image/webp")) }, primary = cover == null)
        Spacer(Modifier.height(12.dp))
        TextBox(d.title, { d = d.copy(title = it) }, "Название трека")
        Spacer(Modifier.height(8.dp))
        TextBox(d.releaseTitle, { d = d.copy(releaseTitle = it) }, "Альбом или сингл")
        Spacer(Modifier.height(8.dp))
        TextBox(d.authors, { d = d.copy(authors = it) }, "Авторы музыки и текста, через запятую")
        Spacer(Modifier.height(8.dp))
        TextBox(d.phonogramMaker, { d = d.copy(phonogramMaker = it) }, "Кто записал (изготовитель фонограммы)")
        Spacer(Modifier.height(8.dp))
        TextBox(d.genre, { d = d.copy(genre = it) }, "Жанр")
        Spacer(Modifier.height(8.dp))
        TextBox(d.language, { d = d.copy(language = it) }, "Язык")
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.weight(1f)) { TextBox(d.year, { d = d.copy(year = it.filter(Char::isDigit).take(4)) }, "Год", keyboardType = KeyboardType.Number) }
            Box(Modifier.weight(2f)) { TextBox(d.releaseDate, { d = d.copy(releaseDate = it.take(10)) }, "Дата релиза ГГГГ-ММ-ДД") }
        }
        Spacer(Modifier.height(8.dp))
        TextBox(d.samples, { d = d.copy(samples = it) }, "Сэмплы и чужие фрагменты, если есть")
        Spacer(Modifier.height(8.dp))
        TextArea(d.lyrics, { d = d.copy(lyrics = it) }, "Текст песни (необязательно)", minHeight = 80)
        Spacer(Modifier.height(10.dp))
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Chip("Есть мат", active = d.explicit) { d = d.copy(explicit = !d.explicit) }
            Chip("Использовался ИИ", active = d.aiUsed) { d = d.copy(aiUsed = !d.aiUsed) }
            Chip("У меня есть все права", active = d.rights) { d = d.copy(rights = !d.rights) }
        }
        val e = error
        if (e != null) {
            Spacer(Modifier.height(8.dp))
            T(e, style = Type.small, color = Ink.danger)
        }
        val p = progress
        if (p != null) {
            Spacer(Modifier.height(10.dp))
            BarProgress(p.toFloat())
            T("Загрузка ${(p * 100).toInt()}%", style = Type.small, color = Ink.mute)
        }
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            PillButton(if (p != null) "Загружаем…" else "Опубликовать", {
                error = g.cabinet.check(d, audio, cover)
                val a = audio
                val c = cover
                if (error != null || a == null || c == null) return@PillButton
                progress = 0.0
                scope.launch {
                    try {
                        g.cabinet.upload(d, a, c) { progress = it }
                        g.toasts.show("Трек опубликован")
                        onDone()
                    } catch (ex: CancellationException) {
                        throw ex
                    } catch (ex: Exception) {
                        error = clean(ex)
                    }
                    progress = null
                    withContext(Dispatchers.IO) { runCatching { a.file.delete(); c.file.delete() } }
                }
            }, enabled = p == null)
            PillButton("Отмена", onClose, primary = false, enabled = p == null)
        }
    }
}
