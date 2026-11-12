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
        case .importMusic: return "Перенос музыки"
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
                    case .importMusic: ImportPanel()
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
        Button { graph.nav.libraryTo(.importMusic) } label: {
            HStack(spacing: 14) {
                GlyphView(.download, color: Ink.accent, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    T("Перенос музыки", .title)
                    T("Из Яндекс Музыки, Spotify или списка", .small, color: Ink.mute)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Ink.ink2))
        }
        .buttonStyle(TapStyle())
        .padding(.top, 10)
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

/// Страница артиста Blink: обложка, подписчики, «Слушать», подписка и треки. Порт ProfilePage сайта (без загрузки треков и постов).
struct ArtistOverlay: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var nav: NavStore
    @EnvironmentObject private var auth: AuthStore
    let bottomInset: CGFloat

    private enum Phase {
        case loading, missing, failed
        case ready(ArtistProfile)
    }

    @State private var phase = Phase.loading
    @State private var following = false
    @State private var followers: Int64 = 0
    @State private var attempt = 0

    private var key: String { return nav.value.artistKey }

    private var title: String {
        if case .ready(let p) = phase { return p.name }
        return "Артист"
    }

    var body: some View {
        Sheet(title: title) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.horizontal, 20)
                .padding(.bottom, bottomInset)
            }
            .scrollIndicators(.hidden)
        }
        .task(id: key + "#\(attempt)") {
            phase = .loading
            do {
                if let p = try await graph.artists.profile(key) {
                    followers = p.followers
                    phase = .ready(p)
                    if let me = auth.value?.userId, me != p.userId { following = await graph.artists.isFollowing(p.id) } else { following = false }
                } else {
                    phase = .missing
                }
            } catch {
                phase = .failed
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            T("Загружаем…", .body, color: Ink.mute)
        case .missing:
            T("Такой страницы нет.", .body, color: Ink.mute)
        case .failed:
            T("Не получилось загрузить. Проверьте интернет.", .body, color: Ink.mute)
            PillButton("Повторить", primary: false) { attempt += 1 }
                .padding(.top, 10)
        case .ready(let p):
            HStack(spacing: 16) {
                Cover(p.avatar ?? "", size: 84, radius: 42)
                VStack(alignment: .leading, spacing: 2) {
                    T(p.name + (p.verified ? " ✓" : ""), .h1, lines: 2)
                    T(([String(followers) + " подп.", Format.tracks(p.tracks.count)] + (p.likes > 0 ? [String(p.likes) + " лайков"] : [])).joined(separator: " · "), .small, color: Ink.mute)
                }
            }
            if let bio = p.bio, !bio.trimmingCharacters(in: .whitespaces).isEmpty {
                T(bio, .body, color: Ink.mute)
                    .padding(.top, 12)
            }
            HStack(spacing: 8) {
                PillButton("Слушать", enabled: !p.tracks.isEmpty) { graph.actions.play(p.tracks, at: 0) }
                if auth.value?.userId != p.userId {
                    PillButton(following ? "Вы подписаны" : "Подписаться", primary: false) { toggle(p) }
                }
            }
            .padding(.top, 14)
            ArtistTracks(tracks: p.tracks)
                .padding(.top, 14)
        }
    }

    private func toggle(_ p: ArtistProfile) {
        if auth.value == nil {
            graph.toasts.show("Войдите, чтобы подписаться")
            graph.nav.go(.account)
            return
        }
        let on = !following
        following = on
        followers += on ? 1 : -1
        Task { @MainActor in
            if await !graph.artists.setFollow(p.id, on) {
                following = !on
                followers += on ? -1 : 1
                graph.toasts.show("Не получилось, попробуйте ещё раз")
            }
        }
    }
}

private struct ArtistTracks: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var currentId: CurrentIdStore
    let tracks: [Track]

    var body: some View {
        if tracks.isEmpty {
            T("Пока нет треков.", .body, color: Ink.mute)
        } else {
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                Button { graph.actions.play(tracks, at: i) } label: {
                    HStack(spacing: 12) {
                        Cover(t.artwork, size: 48)
                        VStack(alignment: .leading, spacing: 0) {
                            T(t.title, .title, color: currentId.value == t.id ? Ink.accent : Ink.bone, lines: 1)
                            T(t.artist, .small, color: Ink.mute, lines: 1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TapStyle())
            }
        }
    }
}


/// Перенос музыки: ссылка, CSV или список «Артист — Название» в «Любимое» или в новый плейлист.
private struct ImportPanel: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var auth: AuthStore
    @State private var text = ""
    @State private var toLikes = true
    @State private var reading = false
    @State private var progress: (Int, Int)? = nil
    @State private var failure: String? = nil
    @State private var result: ImportRun? = nil
    @State private var resultToLikes = true
    @State private var picking = false

    var body: some View {
        if let r = result {
            T("Готово", .h1)
            T("Перенесено \(Format.tracks(r.found.count)) из \(r.total) " + (resultToLikes ? "в «Любимое»." : "в плейлист «\(r.title)»."), .body, color: Ink.mute)
                .padding(.top, 8)
            if !r.missed.isEmpty {
                T("НЕ НАШЛИСЬ (\(r.missed.count))", .label, color: Ink.faint)
                    .padding(.top, 14)
                ForEach(Array(r.missed.prefix(50).enumerated()), id: \.offset) { _, m in
                    T((m.artist.isEmpty ? "" : m.artist + " — ") + m.title, .small, color: Ink.mute, lines: 1)
                }
            }
            PillButton("Отлично") {
                result = nil
                text = ""
                graph.nav.libraryTo(.home)
            }
            .padding(.top, 16)
        } else {
            T("Скопируйте ссылку на плейлист или альбом (Яндекс Музыка, Spotify), загрузите CSV из TuneMyMusic или вставьте список: по треку в строке, «Артист — Название». Плейлист должен быть публичным.", .body, color: Ink.mute)
            TextEditor(text: $text)
                .font(BType.body.font)
                .foregroundColor(Ink.bone)
                .tint(Ink.accent)
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(height: 160)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Ink.ink2))
                .padding(.top, 12)
            HStack(spacing: 8) {
                PillButton("Выбрать файл", primary: false) { picking = true }
                Chip(text: "В «Любимое»", selected: toLikes) { toLikes = true }
                Chip(text: "В новый плейлист", selected: !toLikes) { toLikes = false }
            }
            .padding(.top, 10)
            if reading || progress != nil {
                T(reading ? "Читаю плейлист…" : "Ищу треки… \(progress?.0 ?? 0) из \(progress?.1 ?? 0)", .small, color: Ink.mute)
                    .padding(.top, 14)
                ProgressView(value: reading ? 0 : Double(progress?.0 ?? 0), total: Double(max(1, progress?.1 ?? 1)))
                    .tint(Ink.accent)
            } else {
                let src = Importer.sourceOf(text)
                PillButton(src.map { "Перенести из " + $0.title } ?? "Перенести", enabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { start(src != nil) }
                    .padding(.top, 14)
                if let e = failure {
                    T(e, .small, color: Ink.danger)
                        .padding(.top, 8)
                }
            }
        }
        Color.clear.frame(height: 0)
            .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { res in
                guard case .success(let url) = res else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { text = String(decoding: data, as: UTF8.self) }
            }
    }

    private func start(_ isLink: Bool) {
        if auth.value == nil {
            graph.toasts.show("Войдите, чтобы переносить музыку")
            graph.nav.go(.account)
            return
        }
        failure = nil
        reading = isLink
        let saveToLikes = toLikes
        let input = text
        Task { @MainActor in
            do {
                let run = try await graph.importer.run(input) { d, t in
                    DispatchQueue.main.async {
                        reading = false
                        progress = (d, t)
                    }
                }
                if saveToLikes { graph.library.addLikes(run.found) } else { graph.library.createPlaylist(run.title, tracks: run.found) }
                resultToLikes = saveToLikes
                result = run
            } catch let e as ImportError {
                failure = e.message
            } catch {
                failure = "Не получилось, попробуйте ещё раз"
            }
            reading = false
            progress = nil
        }
    }
}
