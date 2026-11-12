import SwiftUI
import BlinkCore

/// Поиск и стартовая страница: «Новое в Blink» (их можно сохранять) и чарт. Порт ui/SearchScreen.kt.
struct SearchView: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var search: SearchStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var currentId: CurrentIdStore
    @EnvironmentObject private var online: OnlineStore

    let active: Bool
    let bottomInset: CGFloat

    @State private var query = ""
    @FocusState private var focused: Bool

    init(active: Bool, bottomInset: CGFloat) {
        self.active = active
        self.bottomInset = bottomInset
        _query = State(initialValue: LaunchHooks.startQuery)
    }

    var body: some View {
        let isOnline = online.value
        let saved = offline.value
        let playing = currentId.value
        let list = items(search.value, online: isOnline)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                field
                if !isOnline {
                    Banner(.cloudOff, "Нет интернета. Поиск не работает, а сохранённые треки ждут во вкладке «Скачанное».")
                }
                ForEach(list) { item in
                    row(item, saved: saved, playing: playing)
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .contentMargins(.bottom, bottomInset, for: .scrollContent)
        // Поле не пустое только при проверочном запуске в симуляторе (см. LaunchHooks); у пользователя тут ничего не происходит.
        .task { if !query.isEmpty { graph.search.setQuery(query) } }
        .onChange(of: query) { _, text in graph.search.setQuery(text) }
        .onChange(of: active) { _, isActive in
            if !isActive { focused = false }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            T("blink", .display)
            T(".", .display, color: Ink.accent)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Blink")
        .accessibilityAddTraits(.isHeader)
    }

    private var field: some View {
        HStack(spacing: 10) {
            GlyphView(.search, color: Ink.mute, size: 22)
            TextField("", text: $query, prompt: Text("Треки, артисты, альбомы").foregroundColor(Ink.faint))
                .font(BType.body.font)
                .foregroundColor(Ink.bone)
                .tint(Ink.accent)
                .focused($focused)
                .submitLabel(.search)
                .onSubmit { focused = false }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Поиск")
            if !query.isEmpty {
                IconButton(.close, "Очистить", color: Ink.mute, box: 40, size: 20) { query = "" }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 52)
        .background(Capsule().fill(Ink.ink2))
        .overlay(Capsule().stroke(Ink.line2, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // ---------- что показать под полем ----------

    /// Одна строка списка под полем. Весь список идёт одним `ForEach`, а ключ уникален по всему списку:
    /// у каждого вида свой префикс. Раньше у заглушек и строк были общие числовые ключи (0, 1, 2...), и в симуляторе
    /// первые строки так и оставались серыми заглушками: самые свежие треки Blink оказывались спрятаны.
    private enum Item: Identifiable {
        case skeleton(key: String)
        case section(key: String, title: String, saveAll: [Track])
        case track(key: String, track: Track, list: [Track], index: Int)
        case message(key: String, glyph: Glyphs, title: String, text: String, button: String?, action: (() -> Void)?)

        var id: String {
            switch self {
            case .skeleton(let key): return key
            case .section(let key, _, _): return key
            case .track(let key, _, _, _): return key
            case .message(let key, _, _, _, _, _): return key
            }
        }
    }

    // ---------- что показать под полем ----------

    private func items(_ s: SearchState, online isOnline: Bool) -> [Item] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return homeItems(s, online: isOnline)
        }
        if s.loading && s.results.isEmpty {
            return skeletons("find", 4)
        }
        if s.error {
            let retry: () -> Void = { graph.search.retry() }
            return [Item.message(
                key: "find-error",
                glyph: .cloudOff,
                title: "Не получилось найти",
                text: "Проверьте интернет и попробуйте ещё раз.",
                button: "Повторить",
                action: retry
            )]
        }
        if s.searched && s.results.isEmpty {
            return [Item.message(
                key: "find-empty",
                glyph: .search,
                title: "Ничего не нашли",
                text: "Попробуйте другое название или имя исполнителя.",
                button: nil,
                action: nil
            )]
        }
        return tracks("find", s.results)
    }

    private func homeItems(_ s: SearchState, online isOnline: Bool) -> [Item] {
        if s.homeLoading && s.newest.isEmpty && s.chart.isEmpty {
            return skeletons("home", 5)
        }
        if s.homeError && s.newest.isEmpty && s.chart.isEmpty {
            var retry: (() -> Void)?
            if isOnline { retry = { graph.search.refreshHome() } }
            return [Item.message(
                key: "home-error",
                glyph: .cloudOff,
                title: isOnline ? "Не загрузилось" : "Нет интернета",
                text: isOnline ? "Сервер не ответил." : "Сохранённые треки ждут во вкладке «Скачанное».",
                button: isOnline ? "Повторить" : nil,
                action: retry
            )]
        }
        var list: [Item] = []
        if !s.newest.isEmpty {
            let canSave = s.newest.contains(where: { OfflinePolicy.savable($0) })
            list.append(Item.section(key: "new-head", title: "Новое в Blink", saveAll: canSave ? s.newest : []))
            list.append(contentsOf: tracks("new", s.newest))
        }
        if !s.chart.isEmpty {
            list.append(Item.section(key: "chart-head", title: "Чарт", saveAll: []))
            list.append(contentsOf: tracks("chart", s.chart))
        }
        return list
    }

    private func skeletons(_ prefix: String, _ count: Int) -> [Item] {
        return (0..<count).map { Item.skeleton(key: prefix + "-skeleton-" + String($0)) }
    }

    /// Строки треков. Ключ: раздел и место в списке, потому что один и тот же трек может быть и в «Новом», и в чарте.
    private func tracks(_ prefix: String, _ list: [Track]) -> [Item] {
        return list.enumerated().map { entry in
            Item.track(key: prefix + "-" + String(entry.offset), track: entry.element, list: list, index: entry.offset)
        }
    }

    @ViewBuilder
    private func row(_ item: Item, saved: OfflineState, playing: String?) -> some View {
        switch item {
        case .skeleton:
            SkeletonRow()
        case .section(_, let title, let saveAll):
            SectionHeader(
                title,
                action: saveAll.isEmpty ? nil : "Сохранить все",
                onAction: { graph.actions.saveAll(saveAll) }
            )
        case .track(_, let track, let list, let index):
            TrackRow(
                track: track,
                current: playing == track.id,
                save: SaveUi.of(track, saved),
                onPlay: { graph.actions.play(list, at: index) },
                onSave: { graph.actions.saveTapped(track) }
            )
        case .message(_, let glyph, let title, let text, let button, let action):
            EmptyState(glyph, title, text, button: button, onButton: action ?? {})
        }
    }
}
