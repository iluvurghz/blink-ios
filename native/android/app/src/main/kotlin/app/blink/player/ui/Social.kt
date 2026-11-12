package app.blink.player.ui

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.blink.core.social.FriendsApi
import app.blink.core.social.PlusException
import app.blink.core.social.PlusMe
import app.blink.core.social.PromoResult
import app.blink.core.social.RoomSession
import app.blink.core.ui.Format
import app.blink.player.Graph
import app.blink.player.Overlay
import app.blink.player.Tab
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** Общая рамка экрана поверх вкладок: заголовок, «назад», прокрутка. */
@Composable
private fun Sheet(g: Graph, title: String, content: @Composable () -> Unit) {
    BackHandler { g.nav.close() }
    Column(
        Modifier
            .fillMaxSize()
            .background(Ink.ink)
            .imePadding()
            .statusBarsPadding()
            .verticalScroll(rememberScrollState())
            .padding(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 200.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(Glyphs.ExpandMore, "Назад", { g.nav.close() }, modifier = Modifier.padding(end = 4.dp))
            T(title, style = Type.display.copy(fontSize = 24.sp, lineHeight = 29.sp), maxLines = 1)
        }
        Spacer(Modifier.height(14.dp))
        content()
    }
}

@Composable
private fun Panel(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(24.dp))
            .background(Ink.ink2)
            .border(1.dp, Ink.line, RoundedCornerShape(24.dp))
            .padding(18.dp),
    ) { content() }
}

@Composable
private fun Chip(text: String, active: Boolean = false, onClick: (() -> Unit)? = null) {
    Box(
        Modifier
            .clip(CircleShape)
            .background(if (active) Ink.accentSoft else Ink.ink3)
            .then(if (onClick != null) Modifier.tap(onClick = onClick) else Modifier)
            .padding(horizontal = 12.dp, vertical = 7.dp),
    ) { T(text, style = Type.small, color = if (active) Ink.accent else Ink.bone, maxLines = 1) }
}

@Composable
private fun NeedSignIn(g: Graph, what: String) {
    EmptyState(Glyphs.Person, "Нужен аккаунт", what, button = "Войти") { g.nav.go(Tab.Account) }
}

// ---------------------------------------------------------------- комната

@Composable
fun RoomScreen(g: Graph) {
    val session by g.auth.session.collectAsStateWithLifecycle()
    val room by g.room.room.collectAsStateWithLifecycle()
    val player by g.player.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf("") }
    var chat by remember { mutableStateOf("") }

    Sheet(g, "Слушать вместе") {
        val r = room
        val me = session?.userId
        if (session == null) {
            NeedSignIn(g, "Чтобы слушать вместе, войдите в аккаунт.")
            return@Sheet
        }
        if (r == null) {
            Panel {
                T("Одна музыка на всех", style = Type.h2)
                Spacer(Modifier.height(6.dp))
                T(
                    "Комната до ${RoomSession.MAX_MEMBERS} человек. Кто сменил трек, поставил на паузу или перемотал, тот делает это для всех. Внутри есть чат и реакции.",
                    style = Type.body,
                    color = Ink.mute,
                )
                Spacer(Modifier.height(14.dp))
                PillButton("Создать комнату", {
                    scope.launch {
                        val c = g.room.create()
                        if (c != null) g.actions.share(RoomSession.link(c))
                    }
                })
            }
            Spacer(Modifier.height(14.dp))
            Panel {
                T("Есть ссылка или код?", style = Type.h2)
                Spacer(Modifier.height(10.dp))
                TextBox(code, { code = it }, "Ссылка на комнату или код", imeAction = ImeAction.Go, onDone = {
                    val c = RoomSession.codeFrom(code) ?: code.trim()
                    if (c.isNotEmpty()) g.room.join(c)
                })
                Spacer(Modifier.height(12.dp))
                PillButton("Войти в комнату", {
                    val c = RoomSession.codeFrom(code) ?: code.trim()
                    if (c.isNotEmpty()) g.room.join(c)
                }, primary = false, enabled = code.isNotBlank())
            }
            return@Sheet
        }

        val isHost = r.isHost(me)
        Panel {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    T("Комната ${r.code}", style = Type.h2, maxLines = 1)
                    T("${r.members.size} из ${RoomSession.MAX_MEMBERS} в комнате", style = Type.small, color = Ink.mute)
                }
                IconButton(Glyphs.Share, "Поделиться ссылкой", { g.actions.share(RoomSession.link(r.code)) })
            }
            Spacer(Modifier.height(10.dp))
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                r.members.forEach { Chip(if (it.host) "★ ${it.name}" else it.name, active = it.id == me) }
            }
            if (isHost) {
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Chip("Управляют все", active = r.mode == "all") { scope.launch { g.room.setMode("all") } }
                    Chip("Только хост", active = r.mode == "host") { scope.launch { g.room.setMode("host") } }
                }
            } else if (r.mode == "host") {
                Spacer(Modifier.height(8.dp))
                T("Управляет хост комнаты", style = Type.small, color = Ink.faint)
            }
        }

        Spacer(Modifier.height(14.dp))
        val t = r.track
        Panel {
            if (t == null) {
                T("Пока ничего не играет", style = Type.h2)
                Spacer(Modifier.height(4.dp))
                T(
                    if (player.track != null) "Включите трек или отправьте тот, что играет сейчас." else "Найдите трек и включите его: он зазвучит у всех.",
                    style = Type.small,
                    color = Ink.mute,
                )
                if (player.track != null) {
                    Spacer(Modifier.height(10.dp))
                    PillButton("Поставить «${player.track?.title.orEmpty().take(24)}»", {
                        val tr = player.track
                        if (tr != null) scope.launch { g.room.addToQueue(tr) }
                    }, primary = false)
                }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Cover(t.artwork, Modifier.size(56.dp), radius = 16.dp)
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        T(t.title, style = Type.title, maxLines = 1)
                        T(t.artist, style = Type.small, color = Ink.mute, maxLines = 1)
                        T(if (r.playing) "играет" else "на паузе", style = Type.label, color = if (r.playing) Ink.accent else Ink.faint)
                    }
                }
                Spacer(Modifier.height(12.dp))
                val need = r.members.size / 2 + 1
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PillButton(
                        if (isHost) "Пропустить" else "Пропустить ${r.skips.size}/$need",
                        { scope.launch { g.room.voteSkip() } },
                        primary = false,
                    )
                    if (player.track != null && player.track?.id != t.id) {
                        PillButton("В очередь комнаты", { player.track?.let { tr -> scope.launch { g.room.addToQueue(tr) } } }, primary = false)
                    }
                }
            }
        }

        val upcoming = if (r.track != null) r.queue.drop(r.index + 1) else emptyList()
        if (upcoming.isNotEmpty()) {
            Spacer(Modifier.height(14.dp))
            Panel {
                T("Дальше в комнате", style = Type.h2)
                Spacer(Modifier.height(8.dp))
                upcoming.take(8).forEach { q ->
                    Row(Modifier.padding(vertical = 5.dp), verticalAlignment = Alignment.CenterVertically) {
                        Cover(q.artwork, Modifier.size(36.dp), radius = 10.dp, noteDp = 16.dp)
                        Spacer(Modifier.width(10.dp))
                        Column {
                            T(q.title, style = Type.body, maxLines = 1)
                            T(q.artist, style = Type.small, color = Ink.mute, maxLines = 1)
                        }
                    }
                }
                if (upcoming.size > 8) T("и ещё ${upcoming.size - 8}", style = Type.small, color = Ink.faint)
            }
        }

        Spacer(Modifier.height(14.dp))
        Panel {
            val fresh = r.reactions.takeLast(4)
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                RoomSession.EMOJI.forEach { e ->
                    Box(Modifier.clip(CircleShape).background(Ink.ink3).tap { scope.launch { g.room.react(e) } }.padding(horizontal = 12.dp, vertical = 8.dp)) {
                        T(e, style = Type.title)
                    }
                }
            }
            if (fresh.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                T(fresh.joinToString("   ") { "${it.emoji} ${it.name}" }, style = Type.small, color = Ink.mute, maxLines = 2)
            }
        }

        Spacer(Modifier.height(14.dp))
        Panel {
            T("Чат", style = Type.h2)
            Spacer(Modifier.height(10.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) {
                    TextBox(chat, { chat = it }, "Написать в комнату", imeAction = ImeAction.Send, onDone = {
                        val text = chat
                        if (text.isNotBlank()) scope.launch { if (g.room.sendChat(text)) chat = "" }
                    })
                }
                IconButton(Glyphs.Send, "Отправить", {
                    val text = chat
                    if (text.isNotBlank()) scope.launch { if (g.room.sendChat(text)) chat = "" }
                }, color = Ink.accent, enabled = chat.isNotBlank())
            }
            Spacer(Modifier.height(10.dp))
            if (r.chat.isEmpty()) T("Пока тихо.", style = Type.small, color = Ink.faint)
            r.chat.takeLast(40).reversed().forEach { c ->
                Column(Modifier.padding(vertical = 4.dp)) {
                    T(c.name, style = Type.label, color = if (c.by == me) Ink.accent else Ink.mute, maxLines = 1)
                    T(c.text, style = Type.body)
                }
            }
        }

        Spacer(Modifier.height(18.dp))
        PillButton("Выйти из комнаты", { g.room.leave() }, primary = false, danger = true)
    }
}

// ---------------------------------------------------------------- друзья

@Composable
fun FriendsScreen(g: Graph) {
    val session by g.auth.session.collectAsStateWithLifecycle()
    val ui by g.friends.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf<String?>(null) }

    // Список освежаем, пока экран открыт: кто-то начал слушать.
    LaunchedEffect(session?.userId) {
        if (session != null) {
            while (true) {
                g.friends.refresh()
                kotlinx.coroutines.delay(20_000)
            }
        }
    }

    Sheet(g, "Друзья") {
        if (session == null) {
            NeedSignIn(g, "Друзья привязаны к аккаунту. Войдите, чтобы приглашать и видеть, что они слушают.")
            return@Sheet
        }
        Panel {
            T("Пригласить друга", style = Type.h2)
            Spacer(Modifier.height(4.dp))
            T("Дружба взаимная и начинается только со ссылки, которую друг открыл. Ссылка живёт неделю.", style = Type.small, color = Ink.mute)
            Spacer(Modifier.height(12.dp))
            PillButton("Отправить ссылку", { scope.launch { g.friends.invite()?.let { g.actions.share(it) } } })
            Spacer(Modifier.height(16.dp))
            TextBox(code, { code = it }, "Код или ссылка от друга", imeAction = ImeAction.Go, onDone = {})
            Spacer(Modifier.height(10.dp))
            PillButton("Добавить", {
                val c = FriendsApi.codeFrom(code) ?: code.trim()
                scope.launch { if (g.friends.accept(c)) code = "" }
            }, primary = false, enabled = code.isNotBlank())
        }
        Spacer(Modifier.height(14.dp))
        if (ui.friends.isEmpty()) {
            if (ui.loading && !ui.loaded) Spinner() else T(if (ui.offline) "Нет связи с сервером." else "Друзей пока нет.", style = Type.body, color = Ink.mute)
        }
        ui.friends.forEach { f ->
            Panel(Modifier.padding(bottom = 10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Cover(f.avatar, Modifier.size(46.dp), radius = 23.dp, noteDp = 18.dp)
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        T(f.name, style = Type.title, maxLines = 1)
                        val t = f.track
                        if (t != null) T("слушает: ${t.title} · ${t.artist}", style = Type.small, color = Ink.accent, maxLines = 2) else T("не в сети", style = Type.small, color = Ink.faint)
                    }
                }
                Spacer(Modifier.height(10.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    val room = f.room
                    if (room != null) PillButton("Присоединиться", {
                        g.room.join(room)
                        g.nav.open(Overlay.Room)
                    })
                    if (confirm == f.id) {
                        PillButton("Точно убрать", { scope.launch { g.friends.remove(f.id) }; confirm = null }, primary = false, danger = true)
                    } else {
                        PillButton("Убрать", { confirm = f.id }, primary = false)
                    }
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        Panel {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    T("Скрывать, что я слушаю", style = Type.title)
                    T("Друзья не увидят ваш трек и комнату.", style = Type.small, color = Ink.mute)
                }
                Chip(if (ui.hidden) "Скрыто" else "Видно", active = ui.hidden) { scope.launch { g.friends.setHidden(!ui.hidden) } }
            }
        }
    }
}

// ---------------------------------------------------------------- Blink+

@Composable
fun PlusScreen(g: Graph) {
    val session by g.auth.session.collectAsStateWithLifecycle()
    val plus by g.plus.info.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var cfg by remember { mutableStateOf(g.plusApi.cached()) }
    var me by remember { mutableStateOf<PlusMe?>(null) }
    var promo by remember { mutableStateOf("") }
    var applied by remember { mutableStateOf<PromoResult.Discount?>(null) }
    var amount by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    val active = plus.activeAt(System.currentTimeMillis())

    LaunchedEffect(session?.userId) {
        try {
            g.plusApi.config()?.let { cfg = it }
        } catch (_: Exception) {
        }
        if (session != null) {
            try {
                me = g.plusApi.me()
                g.plus.refresh()
            } catch (_: Exception) {
            }
        }
    }

    fun fail(e: Exception) {
        if (e is CancellationException) throw e
        g.toasts.show(if (e is PlusException) e.message.orEmpty() else "Нет связи с сервером")
    }

    Sheet(g, cfg.title) {
        T(cfg.lead, style = Type.body, color = Ink.mute)
        Spacer(Modifier.height(14.dp))
        Panel {
            Row(verticalAlignment = Alignment.CenterVertically) {
                T("Статус", style = Type.h2, modifier = Modifier.weight(1f))
                Chip(if (active) "активен" else "не активен", active = active)
            }
            Spacer(Modifier.height(6.dp))
            val until = plus.untilMs
            T(
                if (active) (if (until != null) "Подписка действует до ${Format.date(until)}." else "Подписка действует.") else "С Blink+ треки каталога сохраняются на телефон и играют без интернета.",
                style = Type.body,
                color = Ink.mute,
            )
            val m = me
            if (m != null && m.keeperTier > 0) {
                Spacer(Modifier.height(8.dp))
                T("${cfg.tiers.getOrNull(m.keeperTier - 1)?.name ?: "Хранитель"} · спасибо, что держите Blink", style = Type.small, color = Ink.accent)
            }
        }

        if (session == null) {
            Spacer(Modifier.height(14.dp))
            NeedSignIn(g, "Оформить Blink+ можно после входа в аккаунт.")
        } else {
            Spacer(Modifier.height(14.dp))
            cfg.plans.forEach { p ->
                val pct = applied?.percent ?: 0
                val price = if (pct > 0) Math.max(1, Math.round(p.price * (100 - pct) / 100.0).toInt()) else p.price
                Panel(Modifier.padding(bottom = 10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                T(p.label, style = Type.h2)
                                if (p.tag.isNotEmpty()) {
                                    Spacer(Modifier.width(8.dp))
                                    Chip(p.tag, active = true)
                                }
                            }
                            T(if (p.days >= 365) "${p.monthly} ₽ в месяц при оплате за год" else "на ${p.days} дней", style = Type.small, color = Ink.mute)
                        }
                        Column(horizontalAlignment = Alignment.End) {
                            T("$price ₽", style = Type.h2)
                            if (p.old > 0 || price != p.price) T("${if (price != p.price) p.price else p.old} ₽", style = Type.small.copy(textDecoration = androidx.compose.ui.text.style.TextDecoration.LineThrough), color = Ink.faint)
                        }
                    }
                    Spacer(Modifier.height(12.dp))
                    PillButton(if (active) "Продлить" else "Оформить", {
                        if (busy) return@PillButton
                        busy = true
                        scope.launch {
                            try {
                                g.actions.openUrl(g.plusApi.checkout(p.id, applied?.code))
                            } catch (e: Exception) {
                                fail(e)
                            } finally {
                                busy = false
                            }
                        }
                    }, enabled = !busy)
                }
            }
            Panel {
                T("Промокод", style = Type.h2)
                Spacer(Modifier.height(10.dp))
                TextBox(promo, { promo = it }, "Введите код", imeAction = ImeAction.Go, onDone = {})
                Spacer(Modifier.height(10.dp))
                val a = applied
                if (a != null) T("Скидка ${a.percent}% применится при оплате (код ${a.code})", style = Type.small, color = Ink.good)
                Spacer(Modifier.height(6.dp))
                PillButton("Применить", {
                    scope.launch {
                        try {
                            when (val r = g.plusApi.promo(promo)) {
                                is PromoResult.Discount -> applied = r
                                is PromoResult.Days -> {
                                    g.toasts.show("Blink+ продлён на ${r.days} дн.")
                                    g.plus.refresh()
                                    promo = ""
                                }
                            }
                        } catch (e: Exception) {
                            fail(e)
                        }
                    }
                }, primary = false, enabled = promo.isNotBlank())
            }
        }

        Spacer(Modifier.height(14.dp))
        Panel {
            T("Что даёт Blink+", style = Type.h2)
            cfg.perks.forEach {
                Spacer(Modifier.height(10.dp))
                T(it.title, style = Type.title)
                T(it.text, style = Type.small, color = Ink.mute)
            }
        }
        Spacer(Modifier.height(14.dp))
        Panel {
            Row {
                T("", Modifier.weight(1f))
                T("Free", style = Type.label, color = Ink.faint, modifier = Modifier.width(48.dp))
                T("Blink+", style = Type.label, color = Ink.accent, modifier = Modifier.width(54.dp))
            }
            cfg.compare.forEach { row ->
                Row(Modifier.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    T(row.label, style = Type.body, modifier = Modifier.weight(1f))
                    T(if (row.free) "✓" else "–", style = Type.body, color = if (row.free) Ink.good else Ink.faint, modifier = Modifier.width(48.dp))
                    T(if (row.plus) "✓" else "–", style = Type.body, color = if (row.plus) Ink.accent else Ink.faint, modifier = Modifier.width(54.dp))
                }
            }
        }
        if (session != null) {
            Spacer(Modifier.height(14.dp))
            Panel {
                T("Поддержать Blink", style = Type.h2)
                Spacer(Modifier.height(4.dp))
                T("Разовая сумма на развитие. Копите на ступени: ${cfg.tiers.joinToString(", ") { "${it.name} от ${it.from} ₽" }}.", style = Type.small, color = Ink.mute)
                Spacer(Modifier.height(10.dp))
                TextBox(amount, { amount = it.filter(Char::isDigit).take(5) }, "Сумма в рублях", keyboardType = KeyboardType.Number, imeAction = ImeAction.Go, onDone = {})
                Spacer(Modifier.height(10.dp))
                PillButton("Поддержать", {
                    val n = amount.toIntOrNull() ?: return@PillButton
                    scope.launch {
                        try {
                            g.actions.openUrl(g.plusApi.donate(n))
                        } catch (e: Exception) {
                            fail(e)
                        }
                    }
                }, primary = false, enabled = amount.isNotBlank())
            }
            Spacer(Modifier.height(10.dp))
            PillButton("Обновить статус", {
                scope.launch {
                    val ok = g.plus.refresh()
                    me = try { g.plusApi.me() } catch (_: Exception) { me }
                    g.toasts.show(if (ok) "Статус обновлён" else "Не удалось связаться с сервером")
                }
            }, primary = false)
        }
    }
}
