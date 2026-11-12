import Foundation

private let wDay: Int64 = 86_400_000
private let coreShare = 0.85
private let genreMinShare = 0.06
private let negDays = 30.0
private let listenHalfDays = 45.0
private let noGenre = "-"
private let poolTtlMs: Int64 = 20 * 60 * 1000

private let artistSplit = try! NSRegularExpression(pattern: "\\s*(?:,|&|×|\\sx\\s|\\sи\\s|\\sfeat\\.?\\s|\\sft\\.?\\s)\\s*", options: [.caseInsensitive])

/// Артисты трека по соавторам: «A, B feat. C» → A, B, C.
public func splitArtists(_ artist: String) -> [String] {
    let range = NSRange(location: 0, length: (artist as NSString).length)
    let replaced = artistSplit.stringByReplacingMatches(in: artist, options: [], range: range, withTemplate: "\u{1}")
    return replaced.split(separator: "\u{1}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

private func lc(_ s: String) -> String { return s.trimmingCharacters(in: .whitespaces).lowercased() }

private func artistKeys(_ t: Track) -> [String] { return splitArtists(t.artist).map(lc) }

private func firstKey(_ t: Track) -> String { return artistKeys(t).first ?? lc(t.artist) }

private func isYandexId(_ id: String) -> Bool {
    return id.count > 2 && id.hasPrefix("cr") && id.dropFirst(2).allSatisfy { $0.isASCII && $0.isNumber }
}

private func seedQuery(_ t: Track) -> String {
    let first = splitArtists(t.artist).first ?? t.artist
    return "\(first) \(t.title)".replacingOccurrences(of: "|", with: " ").trimmingCharacters(in: .whitespaces)
}

/// Как трека называют серверу, когда нужен жанр или похожие: id Яндекса или «Артист Название».
func waveToken(_ t: Track) -> String { return isYandexId(t.id) ? t.id : seedQuery(t) }

public final class ArtistW: @unchecked Sendable {
    public let key: String
    public let name: String
    public var likes = 0
    public var plays = 0
    public var w = 0.0
    public var rep = 0.0
    public var liked: [Track] = []
    public var tracks: [Track] = []

    init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

public final class WaveProfile: @unchecked Sendable {
    public let artists: [String: ArtistW]
    public let core: [ArtistW]
    public let periph: [ArtistW]
    public let share: [String: Double]
    public let top: Set<String>
    public let active: Bool
    /// Треки с неизвестным жанром: (токен для сервера, id трека), до 16, ядро первым.
    public let unresolved: [(token: String, id: String)]

    init(artists: [String: ArtistW], core: [ArtistW], periph: [ArtistW], share: [String: Double], top: Set<String>, active: Bool, unresolved: [(token: String, id: String)]) {
        self.artists = artists
        self.core = core
        self.periph = periph
        self.share = share
        self.top = top
        self.active = active
        self.unresolved = unresolved
    }

    public func aff(_ t: Track) -> Double {
        var best = 0.0
        for k in artistKeys(t) { best = max(best, min(1, max(0, (artists[k]?.w ?? 0) / 4))) }
        return best
    }
}

public struct WaveSeeds: Sendable {
    public let core: [Track]
    public let periph: [Track]
}

private final class Cand: @unchecked Sendable {
    let track: Track
    var score: Double
    let bucket: String
    var hits: Int
    var total = 0.0
    var tier: Character = "A"

    init(_ track: Track, _ score: Double, _ bucket: String, _ hits: Int) {
        self.track = track
        self.score = score
        self.bucket = bucket
        self.hits = hits
    }
}

private final class PoolCache: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(key: String, at: Int64, value: PoolResult)] = []

    func get(_ key: String, _ now: Int64) -> PoolResult? {
        lock.lock()
        defer { lock.unlock() }
        if let i = items.firstIndex(where: { $0.key == key }), now - items[i].at < poolTtlMs { return items[i].value }
        return nil
    }

    func put(_ key: String, _ now: Int64, _ value: PoolResult) {
        lock.lock()
        items.removeAll { $0.key == key }
        items.append((key, now, value))
        while items.count > 20 { items.removeFirst() }
        lock.unlock()
    }
}

private struct Fetched: Sendable {
    let core: PoolResult
    let periph: PoolResult
    let top: [Track]
    let weekly: [Track]
    let monthly: [Track]
    let genres: [String: String]
}

/// Вспышка: личный поток. Порт `wave.js` сайта: ядро вкуса из лайков и истории, сиды, кандидаты от сервера,
/// фильтр по жанрам, «не моё», усталость артистов, режимы. Всё состояние живёт на устройстве (`WaveStore`).
public actor WaveEngine {
    private let source: WaveSource
    private let store: WaveStore
    private let library: Library
    private let settings: @Sendable () -> WaveSettings
    private let now: @Sendable () -> Int64
    private let rng: WaveRandom
    private let cache = PoolCache()

    public init(
        source: WaveSource,
        store: WaveStore,
        library: Library,
        settings: @escaping @Sendable () -> WaveSettings = { WaveSettings() },
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        rng: WaveRandom = WaveRandom()
    ) {
        self.source = source
        self.store = store
        self.library = library
        self.settings = settings
        self.now = now
        self.rng = rng
    }

    // ---------- память: штрафы, затухания ----------

    private func negIds(_ t: Int64) -> [String: Int64] {
        return store.data.negIds.filter { t - $0.value < Int64(negDays * Double(wDay)) }
    }

    private func genrePenalty(_ g: String?, _ t: Int64) -> Double {
        guard let g = g, let v = store.data.negGenres[g] else { return 0 }
        return v.pen * max(0, 1 - Double(t - v.at) / (negDays * Double(wDay)))
    }

    private func listenScores(_ t: Int64) -> [String: Double] {
        var out: [String: Double] = [:]
        for (k, e) in store.data.listen {
            let s = e.score * pow(0.5, Double(t - e.at) / (listenHalfDays * Double(wDay)))
            if s >= 0.05 { out[k] = s }
        }
        return out
    }

    func seenPenalty(_ id: String, _ t: Int64) -> Double {
        guard let e = store.data.seen[id] else { return 0 }
        let age = Double(t - e.at)
        return age < 1.5 * Double(wDay) ? Double.infinity : 2.5 * exp(-age / (5.0 * Double(wDay)))
    }

    private func fatigue(_ t: Int64) -> [String: Int] {
        var out: [String: Int] = [:]
        for e in store.data.seen.values where !e.artist.isEmpty && t - e.at < 3 * wDay { out[e.artist, default: 0] += 1 }
        return out
    }

    private func genreFor(_ t: Track) -> String? {
        if let cached = store.data.genres[t.id] { return (cached == noGenre || cached.isEmpty) ? nil : cached }
        return (isYandexId(t.id) && !t.genre.isEmpty) ? t.genre : nil
    }

    // ---------- профиль вкуса ----------

    public func buildProfile(_ t: Int64? = nil) -> WaveProfile {
        let t = t ?? now()
        let d = store.data
        let skipped = Set(d.skips)
        let listen = listenScores(t)
        var map: [String: ArtistW] = [:]
        var order: [String] = []
        func get(_ name: String) -> ArtistW {
            let k = lc(name)
            if let a = map[k] { return a }
            let a = ArtistW(key: k, name: name)
            map[k] = a
            order.append(k)
            return a
        }
        for (i, tr) in library.likes.enumerated() {
            if tr.title.isEmpty || tr.artist.isEmpty { continue }
            let r = 1.0 / (1 + Double(i) / 150.0)
            for n in splitArtists(tr.artist) {
                let a = get(n)
                a.likes += 1
                a.w += r
                a.liked.append(tr)
                a.tracks.append(tr)
            }
        }
        for (i, tr) in library.recent.enumerated() {
            if tr.title.isEmpty || tr.artist.isEmpty || skipped.contains(tr.id) { continue }
            for n in splitArtists(tr.artist) {
                let a = get(n)
                a.plays += 1
                a.w += 0.6 / (1 + Double(i) / 20.0)
                a.tracks.append(tr)
            }
        }
        for k in order {
            guard let a = map[k] else { continue }
            a.rep = listen[a.key] ?? 0
            a.w += min(4.0, a.rep) * 0.8
            a.w -= 1.5 * Double(min(4, d.skipArtists[a.key] ?? 0)) + 3.0 * Double(d.banArtists[a.key] ?? 0)
            if (d.banArtists[a.key] ?? 0) >= 2 { a.w = 0 }
            a.w = max(0, a.w)
        }
        let all = order.compactMap { map[$0] }.filter { $0.w > 0.05 && !$0.tracks.isEmpty }
        var core = all.filter { ($0.likes >= 2 || $0.plays >= 2 || $0.rep >= 1.5) && $0.w >= 0.3 }
        if core.isEmpty { core = all }
        let coreKeys = Set(core.map { $0.key })
        let periph = all.filter { !coreKeys.contains($0.key) }
        core.sort { $0.w > $1.w }

        var gw: [String: Double] = [:]
        var totalW = 0.0
        var knownW = 0.0
        var knownN = 0
        for a in all {
            totalW += a.w
            var counts: [String: Int] = [:]
            for tr in a.tracks { if let g = genreFor(tr) { counts[g, default: 0] += 1 } }
            let n = counts.values.reduce(0, +)
            if n == 0 { continue }
            knownW += a.w
            knownN += 1
            for (g, v) in counts { gw[g, default: 0] += a.w * Double(v) / Double(n) }
        }
        let avgW = knownN > 0 ? knownW / Double(knownN) : 0
        for g in Array(gw.keys) { gw[g] = max(0, (gw[g] ?? 0) - 2 * avgW * genrePenalty(g, t)) }
        let gTotal = gw.values.reduce(0, +)
        var share: [String: Double] = [:]
        var top = Set<String>()
        if gTotal > 0 {
            for (g, v) in gw {
                share[g] = v / gTotal
                if v / gTotal >= genreMinShare { top.insert(g) }
            }
        }
        let active = totalW > 0 && knownW / totalW >= 0.35 && knownN >= 4 && !top.isEmpty

        var unresolved: [(token: String, id: String)] = []
        var tokens = Set<String>()
        outer: for a in core + periph {
            for tr in a.tracks {
                if unresolved.count >= 16 { break outer }
                if d.genres[tr.id] != nil || genreFor(tr) != nil { continue }
                let token = waveToken(tr)
                if tokens.insert(token).inserted { unresolved.append((token, tr.id)) }
            }
        }
        return WaveProfile(artists: map, core: core, periph: periph, share: share, top: top, active: active, unresolved: unresolved)
    }

    private func weightedOrder<T>(_ items: [(T, Double)]) -> [T] {
        var pool = items
        var out: [T] = []
        while !pool.isEmpty {
            var r = rng.double() * pool.reduce(0) { $0 + $1.1 }
            var pick = pool.count - 1
            for (i, it) in pool.enumerated() {
                r -= it.1
                if r <= 0 { pick = i; break }
            }
            out.append(pool.remove(at: pick).0)
        }
        return out
    }

    public func pickSeeds(_ profile: WaveProfile, _ n: Int = 6) -> WaveSeeds {
        let nCore = min(profile.core.count, profile.periph.isEmpty ? n : max(1, Int((Double(n) * coreShare).rounded())))
        let nPer = min(profile.periph.count, n - nCore)
        var used = Set<String>()
        func grab(_ list: [ArtistW], _ k: Int, _ weight: (ArtistW) -> Double) -> [Track] {
            var out: [Track] = []
            for a in weightedOrder(list.map { ($0, weight($0)) }) {
                if out.count >= k { break }
                let src = a.liked.isEmpty ? a.tracks : a.liked
                if src.isEmpty { continue }
                let t = src[rng.int(below: src.count)]
                if !used.insert(t.id).inserted { continue }
                out.append(t)
            }
            return out
        }
        return WaveSeeds(core: grab(profile.core, nCore) { pow($0.w, 0.8) }, periph: grab(profile.periph, nPer) { 1 + $0.w.squareRoot() })
    }

    private func favorites() -> Set<String> {
        var w: [String: Double] = [:]
        let skipped = Set(store.data.skips)
        for t in library.likes {
            let l = splitArtists(t.artist)
            for a in l { w[lc(a), default: 0] += 3.0 / Double(l.count) }
        }
        for t in library.recent where !skipped.contains(t.id) {
            let l = splitArtists(t.artist)
            for a in l { w[lc(a), default: 0] += 1.0 / Double(l.count) }
        }
        let sorted = w.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        return Set(sorted.prefix(40).map { $0.key })
    }

    // ---------- сеть ----------

    nonisolated private func pooled(_ seeds: [Track]) async -> PoolResult {
        let empty = PoolResult(tracks: [], seedGenre: [])
        let queries = seeds.map(seedQuery).filter { !$0.isEmpty }
        if queries.isEmpty { return empty }
        let key = queries.joined(separator: "|")
        let t = now()
        if let hit = cache.get(key, t) { return hit }
        guard let res = try? await source.pool(seeds: queries) else { return empty }
        cache.put(key, t, res)
        return res
    }

    nonisolated private func fetchTop() async -> [Track] { return (try? await source.topChart()) ?? [] }

    nonisolated private func fetchPeriod(_ kind: String) async -> [Track] { return (try? await source.periodChart(kind: kind)) ?? [] }

    nonisolated private func fetchGenres(_ tokens: [String]) async -> [String: String] {
        if tokens.isEmpty { return [:] }
        return (try? await source.genres(items: tokens)) ?? [:]
    }

    private func releasedMs(_ t: Track) -> Int64? {
        guard let r = t.released else { return nil }
        return ISODate.parseMs(r)
    }

    private func currentYear(_ t: Int64) -> Int {
        let days = Int(t / wDay)
        // год по числу дней от 1970 (алгоритм Хиннанта наоборот, достаточно приближения до года)
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        var y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let m = mp < 10 ? mp + 3 : mp - 9
        if m <= 2 { y += 1 }
        return y
    }

    // ---------- батч ----------

    /// Собирает до `size` треков. Пустой список значит «сервер не ответил»: звать запасной вариант (чарт и лайки).
    public func batch(_ size: Int = 16, exclude: Set<String> = []) async -> [Track] {
        let t0 = now()
        let st = settings()
        var prof = buildProfile(t0)
        let seeds = pickSeeds(prof, 6)
        let tokens = prof.unresolved
        let wantMonthly = rng.double() < 0.5
        async let corePool = pooled(seeds.core)
        async let periphPool = pooled(seeds.periph)
        async let topList = fetchTop()
        async let weeklyList = fetchPeriod("weekly")
        async let monthlyList: [Track] = wantMonthly ? fetchPeriod("monthly") : []
        async let genreMap = fetchGenres(tokens.map { $0.token })
        let f = Fetched(core: await corePool, periph: await periphPool, top: await topList, weekly: await weeklyList, monthly: await monthlyList, genres: await genreMap)
        if f.core.tracks.isEmpty && f.periph.tracks.isEmpty && f.top.isEmpty && f.weekly.isEmpty && f.monthly.isEmpty { return [] }

        learnGenres(seeds, f, tokens)
        prof = buildProfile(t0)

        let freshW = st.mode == .fresh ? 2.0 : 1.0
        var cands: [String: Cand] = [:]
        var order: [String] = []
        func add(_ t: Track, _ base: Double, _ bucket: String, _ hits: Int) {
            if let c = cands[t.id] {
                c.score += base * 0.5
                c.hits = max(c.hits, hits)
            } else {
                cands[t.id] = Cand(t, base, bucket, hits)
                order.append(t.id)
            }
        }
        func addPool(_ p: PoolResult, _ countHits: Bool) {
            for c in p.tracks {
                let h = countHits ? c.hits : 0
                switch c.src {
                case "popular": add(c.track, 1.4, "pop", h)
                case "simArtist": add(c.track, 0.9, "pop", h)
                default: add(c.track, 1.2 + 0.6 * Double(min(3, max(1, c.hits))), "similar", h)
                }
            }
        }
        addPool(f.core, true)
        addPool(f.periph, false)
        for (i, t) in f.top.enumerated() { add(t, 1.6 - Double(i) / Double(f.top.count) * 1.2, "chart", 0) }
        for (i, t) in f.weekly.prefix(60).enumerated() { add(t, 1.4 - Double(i) / 60.0 * 1.0 + 0.5 * freshW, "chart", 0) }
        for (i, t) in f.monthly.prefix(60).enumerated() { add(t, 1.0 - Double(i) / 60.0 * 0.8 + 0.3 * freshW, "chart", 0) }

        let d = store.data
        let neg = negIds(t0)
        let banned = Set(d.banIds)
        let skipped = Set(d.skips)
        let recent30 = Set(library.recent.prefix(30).map { $0.id })
        let likedIds = Set(library.likes.map { $0.id })
        let fav = favorites()
        let tired = fatigue(t0)
        let year = currentYear(t0)
        var survivors: [Cand] = []
        for id in order {
            guard let c = cands[id] else { continue }
            let t = c.track
            let keys = artistKeys(t)
            if exclude.contains(t.id) || recent30.contains(t.id) || banned.contains(t.id) || skipped.contains(t.id) || neg[t.id] != nil { continue }
            if keys.contains(where: { (d.banArtists[$0] ?? 0) >= 2 || (d.skipArtists[$0] ?? 0) >= 3 }) { continue }
            if st.mode == .discover && keys.contains(where: { fav.contains($0) }) { continue }
            let seenP = seenPenalty(t.id, t0)
            if seenP.isInfinite { continue }
            let g = genreFor(t)
            let gPen = genrePenalty(g, t0)
            if gPen >= 3 { continue }
            var sc = c.score - seenP
            if let g = g, prof.top.contains(g) { sc += 0.2 + 0.5 * min(1.0, (prof.share[g] ?? 0) / 0.3) }
            sc -= 0.6 * gPen
            let y = Int(t.year)
            if let rel = releasedMs(t), t0 - rel < 90 * wDay {
                sc += 1.0 * freshW
            } else if let y = y, y >= year {
                sc += 0.6 * freshW
            } else if let y = y, y == year - 1 {
                sc += 0.2 * freshW
            }
            if st.mode != .discover { sc += 0.9 * prof.aff(t) }
            sc -= 0.5 * Double(min(3, tired[firstKey(t)] ?? 0))
            sc -= 1.2 * Double(keys.reduce(0) { $0 + (d.banArtists[$1] ?? 0) })
            if likedIds.contains(t.id) { sc -= 3.0 }
            if st.mode == .known && keys.contains(where: { fav.contains($0) }) { sc += 1.0 }
            c.total = sc
            if !prof.active || (g != nil && prof.top.contains(g!)) || c.hits >= 2 {
                c.tier = "A"
            } else if g == nil {
                c.tier = "U"
            } else {
                c.tier = "E"
            }
            survivors.append(c)
        }

        let hasTaste = !prof.core.isEmpty
        let nExplore = (prof.active && st.explore) ? max(1, Int((Double(size) * 0.1).rounded())) : 0
        let mainSize = size - nExplore
        let quotas: [(String, Double)] = hasTaste ? [("similar", 0.45), ("pop", 0.25), ("chart", 0.3)] : [("chart", 1.0)]
        var chosen: [Cand] = []
        var chosenIds = Set<String>()
        var perArtist: [String: Int] = [:]
        func take(_ pool: [Cand], _ n: Int, _ limit: Int) {
            if n <= 0 { return }
            var got = 0
            for c in sample(pool.filter { !chosenIds.contains($0.track.id) }, n * 3) {
                if got >= n || chosen.count >= limit { break }
                let k = firstKey(c.track)
                if (perArtist[k] ?? 0) >= 2 { continue }
                chosen.append(c)
                chosenIds.insert(c.track.id)
                perArtist[k, default: 0] += 1
                got += 1
            }
        }
        let a = survivors.filter { $0.tier == "A" }
        let u = survivors.filter { $0.tier == "U" }
        let e = survivors.filter { $0.tier == "E" }
        for (bucket, share) in quotas { take(a.filter { $0.bucket == bucket }, Int((Double(mainSize) * share).rounded()), mainSize) }
        take(a, mainSize - chosen.count, mainSize)
        take(u, mainSize - chosen.count, mainSize)
        take(e, nExplore, size)
        take(a, size - chosen.count, size)
        take(u, size - chosen.count, size)
        take(e, size - chosen.count, size)

        let out = chosen.map { $0.track }
        let rest = (a + u).filter { !chosenIds.contains($0.track.id) }
        let spare = sample(rest, 24).map { $0.track }
        store.update { $0.spare = spare }
        markSeen(out, t0)
        return rng.shuffled(out)
    }

    private func learnGenres(_ seeds: WaveSeeds, _ f: Fetched, _ tokens: [(token: String, id: String)]) {
        var byQuery: [String: String] = [:]
        for t in seeds.core + seeds.periph { byQuery[seedQuery(t)] = t.id }
        var learned: [String: String] = [:]
        for sg in f.core.seedGenre + f.periph.seedGenre {
            guard let id = byQuery[sg.query] else { continue }
            if !sg.genre.isEmpty { learned[id] = sg.genre }
        }
        if !tokens.isEmpty && !f.genres.isEmpty {
            for (token, id) in tokens where learned[id] == nil {
                let g = f.genres[token] ?? ""
                learned[id] = g.isEmpty ? noGenre : g
            }
        }
        if learned.isEmpty { return }
        store.update { d in
            for (k, v) in learned { d.genres[k] = v }
            if d.genres.count > 2500 {
                let keep = Array(d.genres.keys.sorted().suffix(2000))
                var next: [String: String] = [:]
                for k in keep { next[k] = d.genres[k] }
                d.genres = next
            }
        }
    }

    private func sample(_ items: [Cand], _ n: Int) -> [Cand] {
        var pool = items.map { ($0, exp(max(-6.0, min(8.0, $0.total)) / 1.2)) }
        var out: [Cand] = []
        while !pool.isEmpty && out.count < n {
            var r = rng.double() * pool.reduce(0) { $0 + $1.1 }
            var pick = pool.count - 1
            for (i, it) in pool.enumerated() {
                r -= it.1
                if r <= 0 { pick = i; break }
            }
            out.append(pool.remove(at: pick).0)
        }
        return out
    }

    private func markSeen(_ tracks: [Track], _ t: Int64) {
        store.update { d in
            for tr in tracks { d.seen[tr.id] = SeenEntry(at: t, artist: firstKey(tr)) }
            if d.seen.count > 900 {
                let keep = d.seen.sorted { $0.value.at > $1.value.at }.prefix(700)
                var next: [String: SeenEntry] = [:]
                for (k, v) in keep { next[k] = v }
                d.seen = next
            }
        }
    }

    // ---------- быстрый старт, обратная связь ----------

    /// Несколько треков для мгновенного старта без сети: из запаса прошлого батча или из истории.
    public func quickStart() -> [Track] {
        let t = now()
        let d = store.data
        let banned = Set(d.banIds).union(d.skips)
        let neg = negIds(t)
        let recent30 = Set(library.recent.prefix(30).map { $0.id })
        let liked = Set(library.likes.map { $0.id })
        let spare = d.spare.filter { !banned.contains($0.id) && neg[$0.id] == nil && !recent30.contains($0.id) && !liked.contains($0.id) && !seenPenalty($0.id, t).isInfinite }
        if spare.count >= 3 { return Array(rng.shuffled(spare).prefix(4)) }
        let history = library.recent.isEmpty ? library.likes + library.recent : library.recent
        return Array(rng.shuffled(history.filter { !banned.contains($0.id) }).prefix(3))
    }

    /// Дослушал до конца или почти (доля трека, 0..1): плюс артисту.
    public func noteListen(_ track: Track, fraction: Double) {
        if fraction < 0.7 { return }
        let t = now()
        let cur = listenScores(t)
        store.update { d in
            for k in artistKeys(track) { d.listen[k] = ListenEntry(score: (cur[k] ?? 0) + 1, at: t) }
            if d.listen.count > 400 {
                let keep = d.listen.sorted { $0.value.score > $1.value.score }.prefix(300)
                var next: [String: ListenEntry] = [:]
                for (k, v) in keep { next[k] = v }
                d.listen = next
            }
        }
    }

    /// Ручной пропуск в первые секунды: трек в чёрный список пропусков, артисту минус; три пропуска и артист исключён.
    public func noteSkip(_ track: Track) {
        store.update { d in
            for k in artistKeys(track) { d.skipArtists[k, default: 0] += 1 }
            d.skips.append(track.id)
            if d.skips.count > 500 { d.skips = Array(d.skips.suffix(500)) }
        }
    }

    /// «Не моё»: трек уходит навсегда, артист и жанр получают штраф, похожие на него идут в чёрный список на 30 дней.
    public func dislike(_ track: Track) async {
        let t = now()
        let known = genreFor(track)
        let bump = known.map { genrePenalty($0, t) + 1 }
        store.update { d in
            for k in artistKeys(track) { d.banArtists[k, default: 0] += 1 }
            if !d.banIds.contains(track.id) { d.banIds.append(track.id) }
            if d.banIds.count > 500 { d.banIds = Array(d.banIds.suffix(500)) }
            d.negIds[track.id] = t
            WaveEngine.trimNeg(&d.negIds)
            if let g = known, let b = bump { d.negGenres[g] = GenreNeg(pen: b, at: t) }
        }
        guard let similar = try? await source.similarIds(seed: waveToken(track)) else { return }
        store.update { d in
            if known == nil && !similar.genre.isEmpty {
                d.negGenres[similar.genre] = GenreNeg(pen: max(0, d.negGenres[similar.genre]?.pen ?? 0) + 1, at: t)
                d.genres[track.id] = similar.genre
            }
            for id in similar.ids { d.negIds[id] = t }
            WaveEngine.trimNeg(&d.negIds)
        }
    }

    private static func trimNeg(_ m: inout [String: Int64]) {
        if m.count <= 600 { return }
        let keep = m.sorted { $0.value > $1.value }.prefix(600)
        var next: [String: Int64] = [:]
        for (k, v) in keep { next[k] = v }
        m = next
    }
}
