package app.blink.player.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
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
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.blink.core.net.AuthException
import app.blink.core.net.AuthLink
import app.blink.core.ui.Format
import app.blink.player.BuildConfig
import app.blink.player.Graph
import app.blink.player.Overlay
import app.blink.player.Tab
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** Профиль: вход, статус Blink+, место на телефоне. Вход по почте и паролю, через Google или Telegram. */
@Composable
fun AccountScreen(g: Graph) {
    val session by g.auth.session.collectAsStateWithLifecycle()
    val plus by g.plus.info.collectAsStateWithLifecycle()
    val offline by g.offline.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()

    Column(
        Modifier
            .fillMaxSize()
            .imePadding()
            .verticalScroll(rememberScrollState())
            .statusBarsPadding()
            .padding(start = 20.dp, end = 20.dp, top = 14.dp, bottom = 190.dp),
    ) {
        T("Профиль", style = Type.display)
        Spacer(Modifier.height(18.dp))

        val current = session
        if (current == null) {
            SignIn(g)
        } else {
            Card {
                T(current.name ?: current.email ?: "Вы вошли", style = Type.h2, maxLines = 1)
                if (current.email != null && current.name != null) {
                    Spacer(Modifier.height(2.dp))
                    T(current.email.orEmpty(), style = Type.small, color = Ink.mute, maxLines = 1)
                }
                Spacer(Modifier.height(14.dp))
                PillButton("Выйти", { scope.launch { g.auth.signOut() } }, primary = false)
            }
            Spacer(Modifier.height(14.dp))
            Card {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    T("Blink+", style = Type.h2, modifier = Modifier.weight(1f))
                    val active = plus.activeAt(System.currentTimeMillis())
                    Box(Modifier.clip(RoundedCornerShape(50)).background(if (active) Ink.accentSoft else Ink.ink3).padding(horizontal = 10.dp, vertical = 4.dp)) {
                        T(if (active) "активен" else "не активен", style = Type.label, color = if (active) Ink.accent else Ink.mute, maxLines = 1)
                    }
                }
                Spacer(Modifier.height(8.dp))
                val until = plus.untilMs
                T(
                    if (plus.activeAt(System.currentTimeMillis())) {
                        if (until != null) "Подписка действует до ${Format.date(until)}. Сохранённые треки играют и без интернета." else "Подписка действует. Сохранённые треки играют и без интернета."
                    } else {
                        "С Blink+ треки каталога сохраняются на телефон и играют без интернета."
                    },
                    style = Type.body,
                    color = Ink.mute,
                )
                Spacer(Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (!plus.activeAt(System.currentTimeMillis())) PillButton("Открыть Blink+", { g.actions.openPlus() })
                    PillButton(
                        "Обновить",
                        {
                            scope.launch {
                                val ok = g.plus.refresh()
                                g.toasts.show(if (ok) "Статус обновлён" else "Не удалось связаться с сервером")
                            }
                        },
                        primary = false,
                    )
                }
            }
        }

        Spacer(Modifier.height(14.dp))
        Card {
            T("Музыка", style = Type.h2)
            Spacer(Modifier.height(6.dp))
            T("Любимое, ваши плейлисты и подборки Blink. Всё это синхронизируется с сайтом.", style = Type.body, color = Ink.mute)
            Spacer(Modifier.height(14.dp))
            PillButton("Открыть", { g.nav.openLibrary() })
        }

        Spacer(Modifier.height(14.dp))
        Card {
            T("Для артистов", style = Type.h2)
            Spacer(Modifier.height(6.dp))
            T("Загружайте свою музыку, ведите страницу и пишите анонсам подписчикам.", style = Type.body, color = Ink.mute)
            Spacer(Modifier.height(14.dp))
            PillButton("Кабинет артиста", { g.nav.open(Overlay.Cabinet) }, primary = false)
        }

        Spacer(Modifier.height(14.dp))
        Card {
            T("Помощь", style = Type.h2)
            Spacer(Modifier.height(6.dp))
            T("Ответы на частые вопросы и связь с командой Blink.", style = Type.body, color = Ink.mute)
            Spacer(Modifier.height(14.dp))
            PillButton("Открыть помощь", { g.nav.open(Overlay.Support) }, primary = false)
        }

        Spacer(Modifier.height(14.dp))
        Card {
            T("Вместе", style = Type.h2)
            Spacer(Modifier.height(6.dp))
            T("Комната, где музыка одна на всех, и друзья, которые видят, что вы слушаете.", style = Type.body, color = Ink.mute)
            Spacer(Modifier.height(14.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                PillButton("Слушать вместе", { g.nav.open(Overlay.Room) })
                PillButton("Друзья", { g.nav.open(Overlay.Friends) }, primary = false)
            }
        }

        Spacer(Modifier.height(14.dp))
        Card {
            T("Офлайн", style = Type.h2)
            Spacer(Modifier.height(6.dp))
            T(
                if (offline.saved.isEmpty()) "Пока ничего не сохранено." else summary(offline.saved.size, offline.usedBytes) + " на телефоне.",
                style = Type.body,
                color = Ink.mute,
            )
            Spacer(Modifier.height(6.dp))
            T("Сохранять можно треки каталога Blink (с меткой BLINK), если артист разрешил. Остальные играют только онлайн.", style = Type.small, color = Ink.faint)
            Spacer(Modifier.height(14.dp))
            PillButton("Открыть «Скачанное»", { g.nav.go(Tab.Downloads) }, primary = false)
        }

        Spacer(Modifier.height(22.dp))
        T("Blink ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}) · ${BuildConfig.BUILD_TYPE}", style = Type.small, color = Ink.faint)
    }
}

@Composable
private fun Card(content: @Composable () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(24.dp))
            .background(Ink.ink2)
            .border(1.dp, Ink.line, RoundedCornerShape(24.dp))
            .padding(18.dp),
    ) {
        content()
    }
}

@Composable
private fun SignIn(g: Graph) {
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    fun submit() {
        if (busy) return
        if (email.isBlank() || password.isEmpty()) {
            error = "Введите почту и пароль"
            return
        }
        busy = true
        error = null
        scope.launch {
            try {
                g.auth.signIn(email, password)
                password = ""
            } catch (e: CancellationException) {
                throw e
            } catch (e: AuthException) {
                error = when (e.kind) {
                    AuthException.Kind.BAD_CREDENTIALS -> "Неверная почта или пароль"
                    AuthException.Kind.NETWORK -> "Нет связи с сервером. Проверьте интернет"
                    AuthException.Kind.SERVER -> "Сервер сейчас не отвечает. Попробуйте позже"
                    AuthException.Kind.NOT_CONFIGURED -> "В этой сборке вход выключен"
                }
            } catch (_: Exception) {
                error = "Не получилось войти. Попробуйте ещё раз"
            } finally {
                busy = false
            }
        }
    }

    if (!g.auth.configured) {
        Banner(Glyphs.Person, "В этой сборке вход выключен: ей не передали ключ сервера. Музыка из внешних источников играет и так.")
        return
    }
    Card {
        T("Войти в Blink", style = Type.h2)
        Spacer(Modifier.height(4.dp))
        T("Аккаунт нужен для треков каталога, подписки Blink+ и сохранения офлайн.", style = Type.small, color = Ink.mute)
        Spacer(Modifier.height(16.dp))
        TextBox(email, { email = it }, "Почта", keyboardType = KeyboardType.Email)
        Spacer(Modifier.height(10.dp))
        TextBox(password, { password = it }, "Пароль", keyboardType = KeyboardType.Password, imeAction = ImeAction.Go, password = true, onDone = { submit() })
        val message = error
        if (message != null) {
            Spacer(Modifier.height(10.dp))
            T(message, style = Type.small, color = Ink.danger)
        }
        Spacer(Modifier.height(16.dp))
        PillButton(if (busy) "Входим…" else "Войти", { submit() }, enabled = !busy)
        Spacer(Modifier.height(18.dp))
        T("или через сайт", style = Type.small, color = Ink.faint)
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            PillButton("Google", { g.actions.startProviderSignIn(AuthLink.Provider.GOOGLE) }, primary = false)
            PillButton("Telegram", { g.actions.startProviderSignIn(AuthLink.Provider.TELEGRAM) }, primary = false)
        }
    }
}
