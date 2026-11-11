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
    }

    var body: some View {
        let isOnline = online.value
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                field
                if !isOnline {
                    Banner(.cloudOff, "Нет интернета. Поиск не работает, а сохранённые треки ждут во вкладке «Скачанное».")
                }
                content(search.value, online: isOnline)
            }
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .contentMargins(.bottom, bottomInset, for: .scrollContent)
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

    @ViewBuilder
    private func content(_ s: SearchState, online isOnline: Bool) -> some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            home(s, online: isOnline)
        } else if s.loading && s.results.isEmpty {
            skeletons(4)
        } else if s.error {
            EmptyState(
                .cloudOff,
                "Не получилось найти",
                "Проверьте интернет и попробуйте ещё раз.",
                button: "Повторить",
                onButton: { graph.search.retry() }
            )
        } else if s.searched && s.results.isEmpty {
            EmptyState(.search, "Ничего не нашли", "Попробуйте другое название или имя исполнителя.")
        } else {
            rows(s.results)
        }
    }

    @ViewBuilder
    private func home(_ s: SearchState, online isOnline: Bool) -> some View {
        if s.homeLoading && s.newest.isEmpty && s.chart.isEmpty {
            skeletons(5)
        } else if s.homeError && s.newest.isEmpty && s.chart.isEmpty {
            EmptyState(
                .cloudOff,
                isOnline ? "Не загрузилось" : "Нет интернета",
                isOnline ? "Сервер не ответил." : "Сохранённые треки ждут во вкладке «Скачанное».",
                button: isOnline ? "Повторить" : nil,
                onButton: { graph.search.refreshHome() }
            )
        } else {
            if !s.newest.isEmpty {
                SectionHeader(
                    "Новое в Blink",
                    action: s.newest.contains(where: { OfflinePolicy.savable($0) }) ? "Сохранить все" : nil,
                    onAction: { graph.actions.saveAll(s.newest) }
                )
                rows(s.newest)
            }
            if !s.chart.isEmpty {
                SectionHeader("Чарт")
                rows(s.chart)
            }
        }
    }

    private func skeletons(_ count: Int) -> some View {
        ForEach(0..<count, id: \.self) { _ in SkeletonRow() }
    }

    /// Строки треков. Индекс служит ключом: один и тот же трек может быть и в «Новом», и в чарте.
    private func rows(_ list: [Track]) -> some View {
        let state = offline.value
        let playing = currentId.value
        return ForEach(Array(list.enumerated()), id: \.offset) { item in
            TrackRow(
                track: item.element,
                current: playing == item.element.id,
                save: SaveUi.of(item.element, state),
                onPlay: { graph.actions.play(list, at: item.offset) },
                onSave: { graph.actions.saveTapped(item.element) }
            )
        }
    }
}
