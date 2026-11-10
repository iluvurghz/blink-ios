package app.blink.player.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.blink.core.model.Track
import app.blink.core.offline.OfflinePolicy
import app.blink.core.offline.OfflineState
import app.blink.core.offline.SaveUi
import app.blink.player.Graph

/** Поиск и стартовая страница: «Новое в Blink» (их можно сохранять) и чарт. */
@Composable
fun SearchScreen(g: Graph, listState: LazyListState, initialQuery: String = "") {
    val s by g.search.state.collectAsStateWithLifecycle()
    val offline by g.offline.state.collectAsStateWithLifecycle()
    val player by g.player.state.collectAsStateWithLifecycle()
    val online by g.network.online.collectAsStateWithLifecycle()
    var query by rememberSaveable { mutableStateOf(initialQuery) }
    val focus = LocalFocusManager.current
    val currentId = player.track?.id

    LaunchedEffect(query) { g.search.setQuery(query) }

    LazyColumn(
        state = listState,
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = 190.dp),
    ) {
        item(key = "head") {
            Box(Modifier.statusBarsPadding().padding(start = 20.dp, end = 20.dp, top = 14.dp, bottom = 4.dp)) {
                BasicText(
                    text = buildAnnotatedString {
                        append("blink")
                        withStyle(SpanStyle(color = Ink.accent)) { append(".") }
                    },
                    style = Type.display.copy(color = Ink.bone),
                )
            }
        }
        item(key = "field") {
            SearchField(
                value = query,
                onChange = { query = it },
                onSubmit = { focus.clearFocus() },
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
            )
        }
        if (!online) {
            item(key = "offline") {
                Banner(Glyphs.CloudOff, "Нет интернета. Поиск не работает, а сохранённые треки ждут во вкладке «Скачанное».")
            }
        }

        if (query.isBlank()) {
            if (s.homeLoading && s.newest.isEmpty() && s.chart.isEmpty()) {
                items(5) { SkeletonRow() }
            } else if (s.homeError && s.newest.isEmpty() && s.chart.isEmpty()) {
                item(key = "home-error") {
                    EmptyState(
                        Glyphs.CloudOff,
                        if (online) "Не загрузилось" else "Нет интернета",
                        if (online) "Сервер не ответил." else "Сохранённые треки ждут во вкладке «Скачанное».",
                        button = if (online) "Повторить" else null,
                        onButton = { g.search.refreshHome() },
                    )
                }
            } else {
                if (s.newest.isNotEmpty()) {
                    item(key = "new-title") {
                        SectionHeader(
                            "Новое в Blink",
                            action = if (s.newest.any { OfflinePolicy.savable(it) }) "Сохранить все" else null,
                            onAction = { g.actions.saveAll(s.newest) },
                        )
                    }
                    trackItems("n", s.newest, g, offline, currentId)
                }
                if (s.chart.isNotEmpty()) {
                    item(key = "chart-title") { SectionHeader("Чарт") }
                    trackItems("c", s.chart, g, offline, currentId)
                }
            }
        } else if (s.loading && s.results.isEmpty()) {
            items(4) { SkeletonRow() }
        } else if (s.error) {
            item(key = "error") {
                EmptyState(
                    Glyphs.CloudOff,
                    "Не получилось найти",
                    "Проверьте интернет и попробуйте ещё раз.",
                    button = "Повторить",
                    onButton = { g.search.retry() },
                )
            }
        } else if (s.searched && s.results.isEmpty()) {
            item(key = "nothing") {
                EmptyState(Glyphs.Search, "Ничего не нашли", "Попробуйте другое название или имя исполнителя.")
            }
        } else {
            trackItems("r", s.results, g, offline, currentId)
        }
    }
}

/** Строки треков списка. Ключ с префиксом: один и тот же трек может быть и в «Новом», и в чарте. */
internal fun LazyListScope.trackItems(prefix: String, list: List<Track>, g: Graph, offline: OfflineState, currentId: String?) {
    itemsIndexed(list, key = { _, t -> "$prefix:${t.id}" }) { index, track ->
        TrackRow(
            track = track,
            current = currentId == track.id,
            save = SaveUi.of(track, offline),
            onPlay = { g.actions.play(list, index) },
            onSave = { onSaveTap(g, track, offline) },
        )
    }
}

/** Что делает нажатие на значок у трека: объясняет «только онлайн», повторяет неудачу или ставит в очередь. */
internal fun onSaveTap(g: Graph, track: Track, offline: OfflineState) {
    when (SaveUi.of(track, offline)) {
        is SaveUi.OnlineOnly -> g.actions.explainOnlineOnly(track)
        SaveUi.Saved -> g.toasts.show("Уже сохранён")
        SaveUi.Available, is SaveUi.Failed -> g.actions.save(track)
        SaveUi.Queued, is SaveUi.Progress -> {
            val key = OfflinePolicy.keyOf(track)
            if (key != null) g.toasts.show("Сохраняется", "Отменить") { g.actions.cancel(key) }
        }
    }
}

@Composable
private fun SearchField(value: String, onChange: (String) -> Unit, onSubmit: () -> Unit, modifier: Modifier = Modifier) {
    BasicTextField(
        value = value,
        onValueChange = onChange,
        singleLine = true,
        textStyle = Type.body.copy(color = Ink.bone),
        cursorBrush = SolidColor(Ink.accent),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        keyboardActions = KeyboardActions(onSearch = { onSubmit() }),
        modifier = modifier.fillMaxWidth(),
        decorationBox = { inner ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(52.dp)
                    .clip(CircleShape)
                    .background(Ink.ink2)
                    .border(1.dp, Ink.line2, CircleShape)
                    .padding(start = 16.dp, end = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Glyph(Glyphs.Search, color = Ink.mute, dp = 22.dp)
                Spacer(Modifier.width(10.dp))
                Box(Modifier.weight(1f)) {
                    if (value.isEmpty()) T("Треки, артисты, альбомы", style = Type.body, color = Ink.faint, maxLines = 1)
                    inner()
                }
                if (value.isNotEmpty()) {
                    IconButton(Glyphs.Close, "Очистить", { onChange("") }, color = Ink.mute, box = 40.dp, dp = 20.dp)
                }
            }
        },
    )
}
