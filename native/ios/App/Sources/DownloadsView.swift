import SwiftUI
import BlinkCore

/// «Скачанное»: что качается, что уже на телефоне, сколько места занято. Всё это играет без интернета.
/// Порт ui/DownloadsScreen.kt.
struct DownloadsView: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var currentId: CurrentIdStore
    @EnvironmentObject private var online: OnlineStore

    let bottomInset: CGFloat

    @State private var free: Int64 = 0
    @State private var confirmKey: String? = nil
    @State private var confirmClear = false

    init(bottomInset: CGFloat) {
        self.bottomInset = bottomInset
    }

    var body: some View {
        let st = offline.value
        let isOnline = online.value
        let failedCount = st.jobs.filter { $0.failed }.count
        let running = st.jobs.contains { !$0.failed }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header(st)
                if !isOnline && !st.saved.isEmpty {
                    Banner(.cloudOff, "Нет интернета. Сохранённые треки играют с телефона (нужен активный Blink+).")
                }
                if running || failedCount > 0 {
                    controls(st, running: running, failedCount: failedCount)
                }
                if !st.jobs.isEmpty {
                    SectionHeader("В очереди")
                    ForEach(st.jobs, id: \.key) { job in
                        JobRow(job: job, online: isOnline)
                    }
                }
                if !st.saved.isEmpty {
                    SectionHeader("На телефоне")
                    saved(st)
                    clearAll
                } else if st.jobs.isEmpty {
                    EmptyState(
                        .download,
                        "Пока ничего не сохранено",
                        "Нажмите на стрелку у трека с меткой BLINK, и он будет играть без интернета. Нужен Blink+. Остальные треки играют только онлайн.",
                        button: "Найти треки",
                        onButton: { graph.nav.go(.search) }
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.bottom, bottomInset, for: .scrollContent)
        // Свободное место считаем не на главном потоке и только когда список сохранённого поменялся.
        .task(id: st.saved.count) {
            let manager = graph.offline
            free = await Task.detached(priority: .utility) { manager.usage().free }.value
        }
        // Вопрос «Удалить?» гаснет сам, чтобы случайное нажатие не оставило кнопку «взведённой».
        .task(id: confirmKey) {
            guard confirmKey != nil else { return }
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled { confirmKey = nil }
        }
        .task(id: confirmClear) {
            guard confirmClear else { return }
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled { confirmClear = false }
        }
    }

    private func header(_ st: OfflineState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            T("Скачанное", .display)
                .accessibilityAddTraits(.isHeader)
            T(
                st.saved.isEmpty
                    ? "Треки, которые играют без интернета"
                    : summary(st.saved.count, st.usedBytes) + " · свободно " + Format.bytes(free),
                .small,
                color: Ink.mute
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private func controls(_ st: OfflineState, running: Bool, failedCount: Int) -> some View {
        let manager = graph.offline
        let paused = st.paused
        return HStack(spacing: 10) {
            if running {
                PillButton(paused ? "Продолжить" : "Пауза", primary: false) {
                    Task.detached { if paused { manager.resume() } else { manager.pause() } }
                }
            }
            if failedCount > 0 {
                PillButton("Повторить всё", primary: false) { graph.actions.retryAll() }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func saved(_ st: OfflineState) -> some View {
        let playing = currentId.value
        return ForEach(Array(st.saved.enumerated()), id: \.element.key) { item in
            SavedRow(
                entry: item.element,
                current: playing == item.element.toTrack().id,
                confirming: confirmKey == item.element.key,
                onPlay: { graph.actions.playSaved(st.saved, at: item.offset) },
                onDelete: {
                    if confirmKey == item.element.key {
                        confirmKey = nil
                        graph.actions.removeSaved(item.element.key)
                    } else {
                        confirmKey = item.element.key
                    }
                }
            )
        }
    }

    private var clearAll: some View {
        HStack {
            Spacer(minLength: 0)
            PillButton(confirmClear ? "Точно удалить всё?" : "Очистить всё", primary: false, danger: true) {
                if confirmClear {
                    confirmClear = false
                    graph.actions.clearAll()
                } else {
                    confirmClear = true
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

// ---------- строки ----------

private func stageLine(_ job: JobView, online: Bool) -> String {
    switch job.stage {
    case .queued:
        if !online { return "Ждём интернет" }
        return job.attempt > 0 ? "Повтор \(job.attempt)…" : "В очереди"
    case .resolving:
        return "Готовим ссылку"
    case .downloading:
        if let total = job.total { return Format.bytes(job.have) + " из " + Format.bytes(total) }
        return Format.bytes(job.have)
    case .verifying:
        return "Проверяем файл"
    case .committing:
        return "Сохраняем"
    case .failed:
        return job.text?.message ?? "Не вышло"
    }
}

private struct JobRow: View {
    @EnvironmentObject private var graph: Graph
    let job: JobView
    let online: Bool

    var body: some View {
        HStack(spacing: 12) {
            Cover(job.cover, size: 52)
            VStack(alignment: .leading, spacing: 0) {
                T(job.title, .title, lines: 1)
                T(job.artist, .small, color: Ink.mute, lines: 1)
                T(stageLine(job, online: online), .small, color: job.failed ? Ink.danger : Ink.faint, lines: 2)
                    .padding(.top, 4)
                if !job.failed && job.total != nil {
                    BarProgress(fraction: job.fraction)
                        .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
            if job.failed, let action = job.text?.action {
                Button(action: { run(action) }) {
                    T(action.label, .button, color: Ink.accent, lines: 1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TapStyle())
            }
            IconButton(.close, "Убрать из очереди", color: Ink.mute, size: 20) { graph.actions.cancel(job.key) }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
    }

    private func run(_ action: OfflineText.Action) {
        switch action {
        case .retry: graph.actions.retry(job.key)
        case .openPlus: graph.actions.openPlus()
        case .signIn: graph.nav.go(.account)
        case .freeSpace: graph.actions.openStorageSettings()
        }
    }
}

private struct SavedRow: View {
    let entry: ManifestEntry
    let current: Bool
    let confirming: Bool
    let onPlay: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    Cover(entry.cover, size: 52)
                    VStack(alignment: .leading, spacing: 0) {
                        T(entry.title, .title, color: current ? Ink.accent : Ink.bone, lines: 1)
                        T(entry.artist, .small, color: Ink.mute, lines: 1)
                        T(details, .small, color: Ink.faint, lines: 1)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(TapStyle())
            if confirming {
                Button(action: onDelete) {
                    T("Удалить?", .button, color: Ink.danger, lines: 1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TapStyle())
            } else {
                IconButton(.delete, "Удалить с телефона", color: Ink.mute, size: 22, action: onDelete)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
    }

    private var details: String {
        let size = Format.bytes(entry.bytes)
        return entry.duration > 0 ? size + " · " + Format.duration(entry.duration) : size
    }
}
