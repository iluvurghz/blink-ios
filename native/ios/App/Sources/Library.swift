import SwiftUI
import BlinkCore

// «Музыка»: любимое, мои плейлисты, подборки Blink и плейлисты по ссылке. Порт ui/Library.kt.

struct LibraryOverlay: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var nav: NavStore
    @EnvironmentObject private var version: LibraryVersion
    let bottomInset: CGFloat

    private var route: LibRoute { return nav.value.libRoute }

    private var title: String {
        switch route {
        case .home: return "Музыка"
        case .likes: return "Любимое"
        case .mine(let id): return graph.library.playlist(id)?.name ?? "Плейлист"
        case .shared: return "Плейлист по ссылке"
        case .editorial: return "Подборка Blink"
        }
    }

    var body: some View {
        _ = version.value
        return Sheet(title: title, onBack: route == .home ? nil : { graph.nav.libraryTo(.home) }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch route {
                    case .home: LibraryHome()
                    case .likes: TrackList(tracks: graph.library.likes, empty: "Нажмите сердечко у трека, и он появится здесь.", onRemove: { t in graph.library.toggleLike(t) })
                    case .mine(let id): MyPlaylist(id: id)
                    case .shared(let code): RemotePlaylist(key: "s" + code, load: { try await graph.shared.fetchShared(code) })
                    case .editorial(let id): RemotePlaylist(key: "e" + id, load: { try await graph.shared.editorialOne(id) })
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, bottomInset)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
        }
    }
}

private struct LibraryHome: View {
    @EnvironmentObject private var graph: Graph
    @State private var name = ""
    @State private var editorial: [EditorialItem] = []
    @FocusState private var focused: Bool

    var body: some View {
        let playlists = graph.library.playlists
        Button { graph.nav.libraryTo(.likes) } label: {
            HStack(spacing: 14) {
                GlyphView(.heart, color: Ink.accent, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    T("Любимое", .title)
                    T(Format.tracks(graph.library.likes.count), .small, color: Ink.mute)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Ink.ink2))
        }
        .buttonStyle(TapStyle())
        T("МОИ ПЛЕЙЛИСТЫ", .label, color: Ink.faint)
            .padding(.top, 18)
        HStack(spacing: 8) {
            TextBox("Название нового плейлиста", text: $name, focus: $focused, submit: .done) { create() }
            IconButton(.add, "Создать плейлист", color: Ink.accent) { create() }
        }
        .padding(.top, 8)
        if playlists.isEmpty {
            T("Плейлистов пока нет. Создайте первый или добавьте трек из плеера.", .small, color: Ink.mute)
                .padding(.top, 10)
        }
        ForEach(playlists) { p in
            Button { graph.nav.libraryTo(.mine(p.id)) } label: {
                HStack(spacing: 12) {
                    Cover(p.cover ?? p.tracks.first?.artwork ?? "", size: 52)
                    VStack(alignment: .leading, spacing: 0) {
                        T(p.name, .title, lines: 1)
                        T(Format.tracks(p.tracks.count), .small, color: Ink.mute)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(TapStyle())
        }
        if !editorial.isEmpty {
            T("ПОДБОРКИ BLINK", .label, color: Ink.faint)
                .padding(.top, 18)
            ForEach(editorial) { e in
                Button { graph.nav.libraryTo(.editorial(e.id)) } label: {
                    HStack(spacing: 12) {
                        Cover(e.cover, size: 52)
                        VStack(alignment: .leading, spacing: 0) {
                            T(e.title, .title, lines: 1)
                            if !e.description.isEmpty { T(e.description, .small, color: Ink.mute, lines: 1) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TapStyle())
            }
        }
        Color.clear.frame(height: 0)
            .task { editorial = (try? await graph.shared.editorial()) ?? [] }
    }

    private func create() {
        let p = graph.library.createPlaylist(name)
        name = ""
        focused = false
        graph.nav.libraryTo(.mine(p.id))
    }
}

private struct MyPlaylist: View {
    @EnvironmentObject private var graph: Graph
    let id: String
    @State private var renaming = false
    @State private var name = ""
    @State private var confirmDelete = false
    @State private var sharing = false
    @FocusState private var focused: Bool

    var body: some View {
        if let p = graph.library.playlist(id) {
            HStack(spacing: 8) {
                PillButton("Играть", enabled: !p.tracks.isEmpty) { graph.actions.play(p.tracks, at: 0) }
                PillButton("Сохранить офлайн", primary: false, enabled: !p.tracks.isEmpty) { graph.actions.saveAll(p.tracks) }
            }
            HStack(spacing: 8) {
                PillButton(sharing ? "Секунду…" : "Поделиться", primary: false, enabled: !p.tracks.isEmpty && !sharing) { share(p) }
                PillButton("Имя", primary: false) {
                    name = p.name
                    renaming.toggle()
                }
                PillButton(confirmDelete ? "Точно удалить?" : "Удалить", primary: false, danger: true) {
                    if confirmDelete {
                        graph.library.deletePlaylist(p.id)
                        let shared = graph.shared
                        Task { try? await shared.unshare(p) }
                        graph.nav.libraryTo(.home)
                    } else {
                        confirmDelete = true
                    }
                }
            }
            .padding(.top, 8)
            if renaming {
                TextBox("Название", text: $name, focus: $focused, submit: .done) {
                    graph.library.renamePlaylist(p.id, name)
                    renaming = false
                }
                .padding(.top, 10)
            }
            TrackList(tracks: p.tracks, empty: "Пока пусто. Добавляйте треки кнопкой «В плейлист» в плеере.", onRemove: { t in graph.library.removeFromPlaylist(p.id, t.id) })
                .padding(.top, 14)
        } else {
            T("Такого плейлиста нет.", .body, color: Ink.mute)
        }
    }

    private func share(_ p: Playlist) {
        sharing = true
        Task { @MainActor in
            defer { sharing = false }
            do {
                let link = try await graph.shared.share(p)
                graph.presentShare(link)
            } catch let e as SharedError {
                graph.toasts.show(e.message)
            } catch {
                graph.toasts.show("Нет связи с сервером")
            }
        }
    }
}

private struct RemotePlaylist: View {
    @EnvironmentObject private var graph: Graph
    let key: String
    let load: () async throws -> SharedPlaylist?

    private enum Phase {
        case loading, missing, failed
        case ready(SharedPlaylist)
    }

    @State private var phase = Phase.loading

    var body: some View {
        Group {
            switch phase {
            case .loading:
                T("Загружаем…", .body, color: Ink.mute)
            case .missing:
                T("Плейлист закрыт или ссылка устарела.", .body, color: Ink.mute)
            case .failed:
                T("Не получилось загрузить. Проверьте интернет.", .body, color: Ink.mute)
            case .ready(let s):
                T(s.name, .h1, lines: 2)
                if !s.owner.isEmpty { T("от " + s.owner, .small, color: Ink.mute) }
                HStack(spacing: 8) {
                    PillButton("Играть", enabled: !s.tracks.isEmpty) { graph.actions.play(s.tracks, at: 0) }
                    PillButton("Сохранить себе", primary: false, enabled: !s.tracks.isEmpty) {
                        graph.library.createPlaylist(s.name, tracks: s.tracks)
                        graph.toasts.show("Плейлист добавлен в ваши")
                    }
                }
                .padding(.top, 12)
                TrackList(tracks: s.tracks, empty: "В плейлисте нет треков.", onRemove: nil)
                    .padding(.top, 14)
            }
        }
        .task(id: key) {
            phase = .loading
            do {
                if let s = try await load() { phase = .ready(s) } else { phase = .missing }
            } catch {
                phase = .failed
            }
        }
    }
}

private struct TrackList: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var currentId: CurrentIdStore
    let tracks: [Track]
    let empty: String
    let onRemove: ((Track) -> Void)?

    var body: some View {
        if tracks.isEmpty {
            T(empty, .body, color: Ink.mute)
        } else {
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                HStack(spacing: 12) {
                    Button { graph.actions.play(tracks, at: i) } label: {
                        HStack(spacing: 12) {
                            Cover(t.artwork, size: 48)
                            VStack(alignment: .leading, spacing: 0) {
                                T(t.title, .title, color: currentId.value == t.id ? Ink.accent : Ink.bone, lines: 1)
                                T(t.artist, .small, color: Ink.mute, lines: 1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(TapStyle())
                    if let remove = onRemove {
                        IconButton(.delete, "Убрать из списка", color: Ink.faint) { remove(t) }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

/// Окно «В плейлист» поверх всего: выбрать плейлист или создать новый и положить в него трек.
struct PlaylistPicker: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var pick: PickState
    @EnvironmentObject private var version: LibraryVersion
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        if let t = pick.track {
            let _ = version.value
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.6).ignoresSafeArea()
                    .onTapGesture { pick.track = nil }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        T("В плейлист", .h2)
                        T(t.title + " · " + t.artist, .small, color: Ink.mute, lines: 1)
                            .padding(.bottom, 12)
                        ForEach(graph.library.playlists) { p in
                            Button {
                                let added = graph.library.addToPlaylist(p.id, t)
                                graph.toasts.show(added ? "Добавлено в «\(p.name)»" : "Трек уже в этом плейлисте")
                                pick.track = nil
                            } label: {
                                HStack(spacing: 12) {
                                    GlyphView(.queue, color: Ink.mute, size: 22)
                                    T(p.name, .title, lines: 1)
                                    Spacer(minLength: 0)
                                    T(Format.tracks(p.tracks.count), .small, color: Ink.faint)
                                }
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(TapStyle())
                        }
                        HStack(spacing: 8) {
                            TextBox("Новый плейлист", text: $name, focus: $focused, submit: .done) { addToNew(t) }
                            IconButton(.add, "Создать и добавить", color: Ink.accent) { addToNew(t) }
                        }
                        .padding(.top, 8)
                    }
                    .padding(20)
                }
                .frame(maxHeight: 460)
                .background(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28).fill(Ink.ink2).ignoresSafeArea(edges: .bottom))
            }
            .accessibilityAddTraits(.isModal)
            .zIndex(2)
        }
    }

    private func addToNew(_ t: Track) {
        let p = graph.library.createPlaylist(name, tracks: [t])
        graph.toasts.show("Добавлено в «\(p.name)»")
        name = ""
        pick.track = nil
    }
}
