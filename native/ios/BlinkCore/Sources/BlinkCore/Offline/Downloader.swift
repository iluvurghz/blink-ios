import Foundation

/// Куда загрузчик сообщает о ходе работы.
public struct DownloadHooks: Sendable {
    public var onStage: @Sendable (Stage) -> Void
    public var onProgress: @Sendable (Int64, Int64?) -> Void
    /// Пора сохранить в job-файл etag/размер: они нужны для докачки после перезапуска.
    public var onMeta: @Sendable (String?, Int64?, String?) -> Void

    public init(
        onStage: @escaping @Sendable (Stage) -> Void = { _ in },
        onProgress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in },
        onMeta: @escaping @Sendable (String?, Int64?, String?) -> Void = { _, _, _ in }
    ) {
        self.onStage = onStage
        self.onProgress = onProgress
        self.onMeta = onMeta
    }
}

/// Скачивает один трек по контракту offline-cache v1:
/// резолв → циклом GET с Range до `total` (сервер режет открытый Range до 2 МиБ, один 206 не значит «готово»)
/// → проверка → атомарный commit. Манифест пишет вызывающий и только после этого.
public final class Downloader: @unchecked Sendable {
    public static let resolveTimeoutMs: Int64 = 15_000
    static let maxReResolves = 2
    static let maxRestarts = 3
    static let writeBatch = 256 * 1024
    static let progressStep: Int64 = 64 * 1024

    private final class Ctx {
        var url: String
        var etag: String?
        var total: Int64?
        var mime: String?
        /// Длина .part, как её сообщило хранилище (I4: по ней считается Range).
        var have: Int64
        /// Сколько байт загрузчик принял и передал хранилищу, считается отдельно от него (поправка 2).
        var accepted: Int64

        init(url: String, etag: String?, total: Int64?, mime: String?, have: Int64) {
            self.url = url
            self.etag = etag
            self.total = total
            self.mime = mime
            self.have = have
            self.accepted = have
        }
    }

    private enum Step {
        case more
        case done
        case expired
        case restart
    }

    private let storage: Storage
    private let resolver: TrackResolver
    private let transport: Transport
    private let network: NetworkMonitor
    private let now: @Sendable () -> Int64
    private let resolveTimeoutMs: Int64

    public init(
        storage: Storage,
        resolver: TrackResolver,
        transport: Transport,
        network: NetworkMonitor,
        resolveTimeoutMs: Int64 = Downloader.resolveTimeoutMs,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.storage = storage
        self.resolver = resolver
        self.transport = transport
        self.network = network
        self.resolveTimeoutMs = resolveTimeoutMs
        self.now = now
    }

    /// Бросает `OfflineError` (код из контракта) или `CancellationError`.
    public func download(_ job: OfflineJob, hooks: DownloadHooks = DownloadHooks()) async throws -> ManifestEntry {
        let key = job.key
        hooks.onStage(.resolving)
        var resolved = try await resolve(job)

        var have = storage.partSize(key)
        if have > 0 && changed(job.etag, job.total, resolved) {
            storage.truncatePart(key, size: 0)
            have = 0
        }
        let ctx = Ctx(
            url: resolved.url,
            etag: resolved.etag ?? (have > 0 ? job.etag : nil),
            total: resolved.bytes ?? (have > 0 ? job.total : nil),
            mime: resolved.mime ?? job.mime,
            have: have
        )
        hooks.onMeta(ctx.etag, ctx.total, ctx.mime)
        hooks.onStage(.downloading)
        hooks.onProgress(ctx.have, ctx.total)

        var reResolves = 0
        var restarts = 0
        loop: while true {
            try Task.checkCancellation()
            if let total = ctx.total {
                if ctx.have == total { break loop }
                if ctx.have > total { reset(key, ctx) }
            }

            let step = try await fetch(job, ctx, hooks)
            try checkAccepted(key, ctx)
            switch step {
            case .more:
                break
            case .done:
                break loop
            case .restart:
                restarts += 1
                if restarts > Downloader.maxRestarts { throw OfflineError(.sourceError, "restart_loop") }
            case .expired:
                // Ссылка просрочена (403 на файле): резолвим заново и продолжаем с того же места.
                reResolves += 1
                if reResolves > Downloader.maxReResolves { throw OfflineError(.sourceError, "expired") }
                resolved = try await resolve(job)
                if ctx.have > 0 && changed(ctx.etag, ctx.total, resolved) { reset(key, ctx) }
                ctx.url = resolved.url
                ctx.etag = resolved.etag ?? ctx.etag
                ctx.total = resolved.bytes ?? ctx.total
                hooks.onMeta(ctx.etag, ctx.total, ctx.mime)
            }
        }

        hooks.onStage(.verifying)
        let have2 = storage.partSize(key)
        do {
            try checkAccepted(key, ctx)
            try Content.verifyFinal(
                have: have2,
                total: ctx.total,
                resolvedBytes: resolved.bytes,
                durationSec: resolved.duration ?? job.meta.duration
            )
        } catch {
            storage.truncatePart(key, size: 0) // битые данные не докачиваем
            throw error
        }

        hooks.onStage(.committing)
        try storage.commit(key)
        return ManifestEntry(
            key: job.key,
            source: job.source,
            id: job.id,
            title: job.meta.title,
            artist: job.meta.artist,
            album: job.meta.album,
            cover: job.meta.cover,
            duration: resolved.duration ?? job.meta.duration,
            bytes: have2,
            mime: resolved.mime ?? ctx.mime,
            etag: ctx.etag,
            savedAt: now(),
            offlineAllowed: job.meta.offlineAllowed,
            track: job.meta.track
        )
    }

    // ---------- резолв ----------

    private func resolve(_ job: OfflineJob) async throws -> Resolved {
        let source = job.source
        let id = job.id
        let resolver = self.resolver
        do {
            let r: Resolved? = try await withTimeoutOrNil(ms: resolveTimeoutMs) {
                try await resolver.resolve(source: source, id: id)
            }
            guard let resolved = r else { throw OfflineError(.timeout, "resolve") }
            return resolved
        } catch {
            throw classify(error)
        }
    }

    /// Файл на сервере сменился с тех пор, как начали (etag или размер другие): .part выбрасываем.
    private func changed(_ etag: String?, _ total: Int64?, _ r: Resolved) -> Bool {
        if let a = etag, let b = r.etag, a != b { return true }
        if let a = total, let b = r.bytes, a != b { return true }
        return false
    }

    private func reset(_ key: String, _ ctx: Ctx) {
        storage.truncatePart(key, size: 0)
        ctx.have = 0
        ctx.accepted = 0
    }

    /// Поправка 2: длина .part в хранилище обязана равняться числу принятых байт. Если часть записи потерялась
    /// (файл тронули снаружи, диск соврал), докачивать нельзя: .part выбрасывается, ошибка BAD_CONTENT/truncated.
    private func checkAccepted(_ key: String, _ ctx: Ctx) throws {
        if storage.partSize(key) != ctx.accepted {
            storage.truncatePart(key, size: 0)
            throw OfflineError(.badContent, "truncated")
        }
    }

    // ---------- один запрос ----------

    private func fetch(_ job: OfflineJob, _ ctx: Ctx, _ hooks: DownloadHooks) async throws -> Step {
        guard let url = URL(string: ctx.url) else { throw OfflineError(.sourceError, "bad_response") }
        var headers: [String: String] = [
            "Accept": "audio/*,application/octet-stream;q=0.9",
            // Без сжатия: иначе система сама разожмёт ответ и арифметика Range поедет.
            "Accept-Encoding": "identity",
        ]
        if ctx.have > 0 {
            headers["Range"] = "bytes=\(ctx.have)-"
            if let etag = ctx.etag { headers["If-Range"] = etag } // дословно, вместе с W/ и кавычками
        }
        let response: TransportResponse
        do {
            response = try await transport.get(url, headers: headers)
        } catch {
            throw classify(error)
        }
        return try await consume(response, job.key, ctx, hooks)
    }

    private func consume(_ resp: TransportResponse, _ key: String, _ ctx: Ctx, _ hooks: DownloadHooks) async throws -> Step {
        switch resp.status {
        case 200:
            try requireAudio(resp)
            // 200 на запрос с Range: сервер отдаёт файл целиком, начинаем с нуля.
            if ctx.have > 0 { reset(key, ctx) }
            if let raw = resp.header("content-length"), let len = Int64(raw.trimmingCharacters(in: .whitespaces)) {
                if let t = ctx.total, t != len { throw OfflineError(.badContent, "size_mismatch") }
                ctx.total = len
            }
            try await readBody(resp, key, ctx, hooks)
            if ctx.total == nil { ctx.total = ctx.have } // чистый конец потока без длины: берём что пришло
            return .more
        case 206:
            try requireAudio(resp)
            guard let cr = ContentRange.parse(resp.header("content-range")) else {
                throw OfflineError(.sourceError, "bad_content_range")
            }
            if cr.start != ctx.have {
                // Сервер ответил с другого места: доверять нельзя, начинаем сначала.
                reset(key, ctx)
                return .restart
            }
            if let t = cr.total {
                if let ct = ctx.total, ct != t { throw OfflineError(.badContent, "size_mismatch") }
                ctx.total = t
            }
            try await readBody(resp, key, ctx, hooks)
            return .more
        case 416:
            if let t = ctx.total, ctx.have == t { return .done }
            reset(key, ctx)
            return .restart
        case 401, 403, 410:
            return .expired
        case 404:
            throw OfflineError(.notDownloadable, "missing")
        default:
            // 408/425/429/5xx и прочее: повтор
            throw OfflineError(.sourceError, "http_\(resp.status)")
        }
    }

    private func requireAudio(_ resp: TransportResponse) throws {
        if !Content.typeOk(resp.header("content-type")) { throw OfflineError(.badContent, "type") }
    }

    /// Читает тело и дописывает в `.part` порциями не меньше 256 КиБ строго подряд.
    /// Первые байты проверяются сразу, до записи на диск. Накопленное при обрыве сохраняется.
    private func readBody(_ resp: TransportResponse, _ key: String, _ ctx: Ctx, _ hooks: DownloadHooks) async throws {
        if ctx.mime == nil, let ct = resp.header("content-type") {
            let head = ct.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let m = head.trimmingCharacters(in: .whitespaces)
            if !m.isEmpty { ctx.mime = m }
        }
        var pending = Data()
        var sniffed = ctx.have > 0
        var received: Int64 = 0
        var shown = ctx.have

        func flush() throws {
            if pending.isEmpty { return }
            let part = pending
            try storage.appendPart(key, part)
            ctx.have += Int64(part.count)
            ctx.accepted += Int64(part.count)
            pending = Data()
        }

        do {
            for try await chunk in resp.body {
                try Task.checkCancellation()
                pending.append(chunk)
                received += Int64(chunk.count)
                if !sniffed && pending.count >= Content.sniffBytes {
                    if !Content.magicOk(Array(pending.prefix(Content.sniffBytes))) { throw OfflineError(.badContent, "magic") }
                    sniffed = true
                }
                if pending.count >= Downloader.writeBatch { try flush() }
                let seen = ctx.have + Int64(pending.count)
                if seen - shown >= Downloader.progressStep {
                    shown = seen
                    hooks.onProgress(seen, ctx.total)
                }
            }
            // Отмена задачи может закончить поток «чисто»: без этой проверки обрезанное сошло бы за целое.
            try Task.checkCancellation()
            if !sniffed {
                // Весь ответ короче 12 байт: пусто, "<", "{" и подобное
                if !Content.magicOk(Array(pending)) { throw OfflineError(.badContent, "magic") }
                sniffed = true
            }
        } catch {
            // Уже полученное и проверенное сохраняем: докачка пойдёт с этого места.
            if sniffed { try? flush() }
            throw classify(error)
        }
        try flush()
        // I4: длину берём после сброса на диск
        ctx.have = storage.partSize(key)
        hooks.onProgress(ctx.have, ctx.total)
        if received == 0 { throw OfflineError(.sourceError, "empty") } // ни байта: не зацикливаемся
    }

    /// Сбои транспорта в коды контракта. Отмену и наши собственные ошибки пропускаем как есть.
    private func classify(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if error is OfflineError { return error }
        if let t = error as? TransportError {
            switch t {
            case .timedOut:
                return OfflineError(.timeout)
            case .offline:
                return OfflineError(.noNetwork)
            case .failed(let message):
                return network.isOnline ? OfflineError(.sourceError, "io", detail: message) : OfflineError(.noNetwork)
            }
        }
        return network.isOnline ? OfflineError(.sourceError, "io", detail: String(describing: error)) : OfflineError(.noNetwork)
    }
}

/// Заголовок Content-Range вида `bytes 1000000-3097151/5000000`; вместо размера бывает звёздочка.
struct ContentRange: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64?

    static func parse(_ header: String?) -> ContentRange? {
        guard let raw = header else { return nil }
        let h = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard h.hasPrefix("bytes") else { return nil }
        let rest = h.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let slash = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard slash.count == 2 else { return nil }
        let range = slash[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard range.count == 2,
              let a = Int64(range[0].trimmingCharacters(in: .whitespaces)),
              let b = Int64(range[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        let t = slash[1].trimmingCharacters(in: .whitespaces)
        if t == "*" { return ContentRange(start: a, end: b, total: nil) }
        guard let total = Int64(t) else { return nil }
        return ContentRange(start: a, end: b, total: total)
    }
}
