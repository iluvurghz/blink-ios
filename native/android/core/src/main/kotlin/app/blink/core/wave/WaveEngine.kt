package app.blink.core.wave

import app.blink.core.model.Track
import java.time.OffsetDateTime
import java.time.ZoneOffset
import kotlin.coroutines.cancellation.CancellationException
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sqrt
import kotlin.random.Random
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope

private const val DAY = 86_400_000L
private const val CORE_SHARE = 0.85
private const val GENRE_MIN_SHARE = 0.06
private const val NEG_DAYS = 30.0
private const val LISTEN_HALF_DAYS = 45.0
private const val NO_GENRE = "-"
private const val POOL_TTL_MS = 20 * 60 * 1000L

private val ARTIST_SPLIT = Regex("\\s*(?:,|&|×|\\sx\\s|\\sи\\s|\\sfeat\\.?\\s|\\sft\\.?\\s)\\s*", RegexOption.IGNORE_CASE)
private val YANDEX_ID = Regex("^cr\\d+$")

/** Артисты трека по соавторам: «A, B feat. C» → A, B, C. */
fun splitArtists(artist: String): List<String> = artist.split(ARTIST_SPLIT).map { it.trim() }.filter { it.isNotEmpty() }

private fun lc(s: String) = s.trim().lowercase()

private fun artistKeys(t: Track): List<String> = splitArtists(t.artist).map(::lc)

private fun firstKey(t: Track): String = artistKeys(t).firstOrNull() ?: lc(t.artist)

/** Как трек называют серверу, когда нужен жанр или похожие: id Яндекса или «Артист Название». */
internal fun waveToken(t: Track): String = if (YANDEX_ID.matches(t.id)) t.id else "${splitArtists(t.artist).firstOrNull() ?: t.artist} ${t.title}".replace("|", " ").trim()

/**
 * Вспышка: личный поток. Порт `wave.js` сайта: ядро вкуса из лайков и истории, сиды, кандидаты от сервера,
 * фильтр по жанрам, «не моё», усталость артистов, режимы. Всё состояние живёт на устройстве ([WaveStore]).
 */
class WaveEngine(
    private val source: WaveSource,
    private val store: WaveStore,
    private val library: Library,
    private val settings: () -> WaveSettings = { WaveSettings() },
    private val now: () -> Long = System::currentTimeMillis,
    private val rng: Random = Random.Default,
) {
    class ArtistW(val key: String, val name: String) {
        var likes = 0
        var plays = 0
        var w = 0.0
        var rep = 0.0
        val liked = ArrayList<Track>()
        val tracks = ArrayList<Track>()
    }

    class Profile(
        val artists: Map<String, ArtistW>,
        val core: List<ArtistW>,
        val periph: List<ArtistW>,
        val share: Map<String, Double>,
        val top: Set<String>,
        val active: Boolean,
        /** Треки с неизвестным жанром: (токен для сервера, id трека), до 16, ядро первым. */
        val unresolved: List<Pair<String, String>>,
    ) {
        fun aff(t: Track): Double = artistKeys(t).maxOfOrNull { min(1.0, max(0.0, (artists[it]?.w ?: 0.0) / 4)) } ?: 0.0
    }

    class Seeds(val core: List<Track>, val periph: List<Track>)

    private class Cand(val track: Track, var score: Double, val bucket: String, var hits: Int) {
        var total = 0.0
        var tier = 'A'
    }

    private class PoolCache(val at: Long, val value: PoolResult)

    private val poolCache = LinkedHashMap<String, PoolCache>()

    // ---------- память: штрафы, затухания ----------

    private fun negIds(t: Long): Map<String, Long> = store.data.negIds.filterValues { t - it < NEG_DAYS * DAY }

    private fun genrePenalty(g: String?, t: Long): Double {
        val v = g?.let { store.data.negGenres[it] } ?: return 0.0
        return v.pen * max(0.0, 1 - (t - v.at) / (NEG_DAYS * DAY))
    }

    private fun listenScores(t: Long): Map<String, Double> {
        val out = HashMap<String, Double>()
        for ((k, e) in store.data.listen) {
            val s = e.score * 0.5.pow((t - e.at) / (LISTEN_HALF_DAYS * DAY))
            if (s >= 0.05) out[k] = s
        }
        return out
    }

    internal fun seenPenalty(id: String, t: Long): Double {
        val e = store.data.seen[id] ?: return 0.0
        val age = t - e.at
        return if (age < 1.5 * DAY) Double.POSITIVE_INFINITY else 2.5 * exp(-age / (5.0 * DAY))
    }

    private fun fatigue(t: Long): Map<String, Int> {
        val out = HashMap<String, Int>()
        for (e in store.data.seen.values) if (e.artist.isNotEmpty() && t - e.at < 3 * DAY) out[e.artist] = (out[e.artist] ?: 0) + 1
        return out
    }

    private fun genreFor(t: Track): String? {
        val cached = store.data.genres[t.id]
        if (cached != null) return cached.takeIf { it != NO_GENRE && it.isNotEmpty() }
        return if (YANDEX_ID.matches(t.id) && t.genre.isNotEmpty()) t.genre else null
    }

    // ---------- профиль вкуса ----------

    fun buildProfile(t: Long = now()): Profile {
        val d = store.data
        val skipped = d.skips.toHashSet()
        val listen = listenScores(t)
        val map = LinkedHashMap<String, ArtistW>()
        fun get(name: String) = map.getOrPut(lc(name)) { ArtistW(lc(name), name) }
        library.likes.forEachIndexed { i, tr ->
            if (tr.title.isEmpty() || tr.artist.isEmpty()) return@forEachIndexed
            val r = 1.0 / (1 + i / 150.0)
            for (n in splitArtists(tr.artist)) get(n).let { a -> a.likes++; a.w += r; a.liked.add(tr); a.tracks.add(tr) }
        }
        library.recent.forEachIndexed { i, tr ->
            if (tr.title.isEmpty() || tr.artist.isEmpty() || tr.id in skipped) return@forEachIndexed
            for (n in splitArtists(tr.artist)) get(n).let { a -> a.plays++; a.w += 0.6 / (1 + i / 20.0); a.tracks.add(tr) }
        }
        for (a in map.values) {
            a.rep = listen[a.key] ?: 0.0
            a.w += min(4.0, a.rep) * 0.8
            a.w -= 1.5 * min(4, d.skipArtists[a.key] ?: 0) + 3.0 * (d.banArtists[a.key] ?: 0)
            if ((d.banArtists[a.key] ?: 0) >= 2) a.w = 0.0
            a.w = max(0.0, a.w)
        }
        val all = map.values.filter { it.w > 0.05 && it.tracks.isNotEmpty() }
        var core = all.filter { (it.likes >= 2 || it.plays >= 2 || it.rep >= 1.5) && it.w >= 0.3 }
        if (core.isEmpty()) core = all
        val coreKeys = core.map { it.key }.toHashSet()
        val periph = all.filter { it.key !in coreKeys }
        core = core.sortedByDescending { it.w }

        val gw = HashMap<String, Double>()
        var totalW = 0.0
        var knownW = 0.0
        var knownN = 0
        for (a in all) {
            totalW += a.w
            val counts = HashMap<String, Int>()
            for (tr in a.tracks) genreFor(tr)?.let { g -> counts[g] = (counts[g] ?: 0) + 1 }
            val n = counts.values.sum()
            if (n == 0) continue
            knownW += a.w
            knownN++
            for ((g, v) in counts) gw[g] = (gw[g] ?: 0.0) + a.w * v / n
        }
        val avgW = if (knownN > 0) knownW / knownN else 0.0
        for (g in gw.keys.toList()) gw[g] = max(0.0, gw.getValue(g) - 2 * avgW * genrePenalty(g, t))
        val gTotal = gw.values.sum()
        val share = HashMap<String, Double>()
        val top = HashSet<String>()
        if (gTotal > 0) for ((g, v) in gw) {
            share[g] = v / gTotal
            if (v / gTotal >= GENRE_MIN_SHARE) top.add(g)
        }
        val active = totalW > 0 && knownW / totalW >= 0.35 && knownN >= 4 && top.isNotEmpty()

        val unresolved = LinkedHashMap<String, String>()
        loop@ for (a in core + periph) for (tr in a.tracks) {
            if (unresolved.size >= 16) break@loop
            if (store.data.genres.containsKey(tr.id) || genreFor(tr) != null) continue
            unresolved.putIfAbsent(waveToken(tr), tr.id)
        }
        return Profile(map, core, periph, share, top, active, unresolved.map { it.key to it.value })
    }

    private fun <T> weightedOrder(items: List<Pair<T, Double>>): List<T> {
        val pool = items.toMutableList()
        val out = ArrayList<T>()
        while (pool.isNotEmpty()) {
            var r = rng.nextDouble() * pool.sumOf { it.second }
            var i = pool.indexOfFirst { r -= it.second; r <= 0 }
            if (i < 0) i = pool.size - 1
            out.add(pool.removeAt(i).first)
        }
        return out
    }

    fun pickSeeds(profile: Profile, n: Int = 6): Seeds {
        val nCore = min(profile.core.size, if (profile.periph.isNotEmpty()) max(1, (n * CORE_SHARE).roundToInt()) else n)
        val nPer = min(profile.periph.size, n - nCore)
        val used = HashSet<String>()
        fun grab(list: List<ArtistW>, k: Int, weight: (ArtistW) -> Double): List<Track> {
            val out = ArrayList<Track>()
            for (a in weightedOrder(list.map { it to weight(it) })) {
                if (out.size >= k) break
                val src = a.liked.ifEmpty { a.tracks }
                val t = src.getOrNull(rng.nextInt(max(1, src.size))) ?: continue
                if (!used.add(t.id)) continue
                out.add(t)
            }
            return out
        }
        return Seeds(grab(profile.core, nCore) { it.w.pow(0.8) }, grab(profile.periph, nPer) { 1 + sqrt(it.w) })
    }

    private fun favorites(): Set<String> {
        val w = HashMap<String, Double>()
        val skipped = store.data.skips.toHashSet()
        for (t in library.likes) splitArtists(t.artist).let { l -> l.forEach { w[lc(it)] = (w[lc(it)] ?: 0.0) + 3.0 / l.size } }
        for (t in library.recent) if (t.id !in skipped) splitArtists(t.artist).let { l -> l.forEach { w[lc(it)] = (w[lc(it)] ?: 0.0) + 1.0 / l.size } }
        return w.entries.sortedByDescending { it.value }.take(40).map { it.key }.toHashSet()
    }

    // ---------- сеть ----------

    private suspend fun <T> safe(default: T, block: suspend () -> T): T =
        try {
            block()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            default
        }

    private fun seedQuery(t: Track): String = "${splitArtists(t.artist).firstOrNull() ?: t.artist} ${t.title}".replace("|", " ").trim()

    private suspend fun pooled(seeds: List<Track>): PoolResult {
        val queries = seeds.map(::seedQuery).filter { it.isNotEmpty() }
        if (queries.isEmpty()) return PoolResult(emptyList(), emptyList())
        val key = queries.joinToString("|")
        val t = now()
        poolCache[key]?.let { if (t - it.at < POOL_TTL_MS) return it.value }
        val res = source.pool(queries)
        poolCache[key] = PoolCache(t, res)
        while (poolCache.size > 20) poolCache.remove(poolCache.keys.first())
        return res
    }

    private fun released(t: Track): Long? =
        try {
            t.released?.let { OffsetDateTime.parse(it).toInstant().toEpochMilli() }
        } catch (_: Exception) {
            null
        }

    // ---------- батч ----------

    /** Собирает до [size] треков. Пустой список значит «сервер не ответил»: звать запасной вариант (чарт и лайки). */
    suspend fun batch(size: Int = 16, exclude: Set<String> = emptySet()): List<Track> {
        val t0 = now()
        val st = settings()
        var prof = buildProfile(t0)
        val seeds = pickSeeds(prof, 6)
        val empty = PoolResult(emptyList(), emptyList())
        val tokens = prof.unresolved
        val fetched = coroutineScope {
            val core = async { safe(empty) { pooled(seeds.core) } }
            val periph = async { safe(empty) { pooled(seeds.periph) } }
            val top = async { safe(emptyList()) { source.topChart() } }
            val weekly = async { safe(emptyList()) { source.periodChart("weekly") } }
            val monthly = async { if (rng.nextDouble() < 0.5) safe(emptyList()) { source.periodChart("monthly") } else emptyList() }
            val genres = async { if (tokens.isEmpty()) emptyMap() else safe(emptyMap()) { source.genres(tokens.map { it.first }) } }
            Fetched(core.await(), periph.await(), top.await(), weekly.await(), monthly.await(), genres.await())
        }
        if (fetched.core.tracks.isEmpty() && fetched.periph.tracks.isEmpty() && fetched.top.isEmpty() && fetched.weekly.isEmpty() && fetched.monthly.isEmpty()) return emptyList()

        learnGenres(seeds, fetched, tokens)
        prof = buildProfile(t0)

        val freshW = if (st.mode == WaveMode.FRESH) 2.0 else 1.0
        val cands = LinkedHashMap<String, Cand>()
        fun add(t: Track, base: Double, bucket: String, hits: Int) {
            val c = cands[t.id]
            if (c == null) cands[t.id] = Cand(t, base, bucket, hits) else { c.score += base * 0.5; c.hits = max(c.hits, hits) }
        }
        fun addPool(p: PoolResult, countHits: Boolean) {
            for (c in p.tracks) {
                val h = if (countHits) c.hits else 0
                when (c.src) {
                    "popular" -> add(c.track, 1.4, "pop", h)
                    "simArtist" -> add(c.track, 0.9, "pop", h)
                    else -> add(c.track, 1.2 + 0.6 * min(3, max(1, c.hits)), "similar", h)
                }
            }
        }
        addPool(fetched.core, true)
        addPool(fetched.periph, false)
        fetched.top.forEachIndexed { i, t -> add(t, 1.6 - i.toDouble() / fetched.top.size * 1.2, "chart", 0) }
        fetched.weekly.take(60).forEachIndexed { i, t -> add(t, 1.4 - i / 60.0 * 1.0 + 0.5 * freshW, "chart", 0) }
        fetched.monthly.take(60).forEachIndexed { i, t -> add(t, 1.0 - i / 60.0 * 0.8 + 0.3 * freshW, "chart", 0) }

        val d = store.data
        val neg = negIds(t0)
        val banned = d.banIds.toHashSet()
        val skipped = d.skips.toHashSet()
        val recent30 = library.recent.take(30).map { it.id }.toHashSet()
        val likedIds = library.likes.map { it.id }.toHashSet()
        val fav = favorites()
        val tired = fatigue(t0)
        val year = OffsetDateTime.now(ZoneOffset.UTC).year
        val survivors = ArrayList<Cand>()
        for (c in cands.values) {
            val t = c.track
            val keys = artistKeys(t)
            if (t.id in exclude || t.id in recent30 || t.id in banned || t.id in skipped || t.id in neg) continue
            if (keys.any { (d.banArtists[it] ?: 0) >= 2 || (d.skipArtists[it] ?: 0) >= 3 }) continue
            if (st.mode == WaveMode.DISCOVER && keys.any { it in fav }) continue
            val seenP = seenPenalty(t.id, t0)
            if (seenP.isInfinite()) continue
            val g = genreFor(t)
            val gPen = genrePenalty(g, t0)
            if (gPen >= 3) continue
            var sc = c.score - seenP
            if (g != null && g in prof.top) sc += 0.2 + 0.5 * min(1.0, (prof.share[g] ?: 0.0) / 0.3)
            sc -= 0.6 * gPen
            val rel = released(t)
            val y = t.year.toIntOrNull()
            sc += when {
                rel != null && t0 - rel < 90 * DAY -> 1.0 * freshW
                y != null && y >= year -> 0.6 * freshW
                y != null && y == year - 1 -> 0.2 * freshW
                else -> 0.0
            }
            if (st.mode != WaveMode.DISCOVER) sc += 0.9 * prof.aff(t)
            sc -= 0.5 * min(3, tired[firstKey(t)] ?: 0)
            sc -= 1.2 * keys.sumOf { d.banArtists[it] ?: 0 }
            if (t.id in likedIds) sc -= 3.0
            if (st.mode == WaveMode.KNOWN && keys.any { it in fav }) sc += 1.0
            c.total = sc
            c.tier = when {
                !prof.active || (g != null && g in prof.top) || c.hits >= 2 -> 'A'
                g == null -> 'U'
                else -> 'E'
            }
            survivors.add(c)
        }

        val hasTaste = prof.core.isNotEmpty()
        val nExplore = if (prof.active && st.explore) max(1, (size * 0.1).roundToInt()) else 0
        val mainSize = size - nExplore
        val quotas = if (hasTaste) listOf("similar" to 0.45, "pop" to 0.25, "chart" to 0.3) else listOf("chart" to 1.0)
        val chosen = LinkedHashMap<String, Cand>()
        val perArtist = HashMap<String, Int>()
        fun take(pool: List<Cand>, n: Int, limit: Int) {
            if (n <= 0) return
            var got = 0
            for (c in sample(pool.filter { it.track.id !in chosen }, n * 3)) {
                if (got >= n || chosen.size >= limit) break
                val k = firstKey(c.track)
                if ((perArtist[k] ?: 0) >= 2) continue
                chosen[c.track.id] = c
                perArtist[k] = (perArtist[k] ?: 0) + 1
                got++
            }
        }
        val a = survivors.filter { it.tier == 'A' }
        val u = survivors.filter { it.tier == 'U' }
        val e = survivors.filter { it.tier == 'E' }
        for ((bucket, share) in quotas) take(a.filter { it.bucket == bucket }, (mainSize * share).roundToInt(), mainSize)
        take(a, mainSize - chosen.size, mainSize)
        take(u, mainSize - chosen.size, mainSize)
        take(e, nExplore, size)
        take(a, size - chosen.size, size)
        take(u, size - chosen.size, size)
        take(e, size - chosen.size, size)

        val out = chosen.values.map { it.track }
        val rest = (a + u).filter { it.track.id !in chosen }
        val spare = sample(rest, 24).map { it.track }
        store.update { it.copy(spare = spare) }
        markSeen(out, t0)
        return out.shuffled(rng)
    }

    private class Fetched(val core: PoolResult, val periph: PoolResult, val top: List<Track>, val weekly: List<Track>, val monthly: List<Track>, val genres: Map<String, String>)

    private fun learnGenres(seeds: Seeds, f: Fetched, tokens: List<Pair<String, String>>) {
        val byQuery = HashMap<String, String>()
        for (t in seeds.core + seeds.periph) byQuery[seedQuery(t)] = t.id
        val learned = HashMap<String, String>()
        for (sg in f.core.seedGenre + f.periph.seedGenre) {
            val id = byQuery[sg.query] ?: continue
            if (sg.genre.isNotEmpty()) learned[id] = sg.genre
        }
        if (tokens.isNotEmpty() && f.genres.isNotEmpty()) for ((token, id) in tokens) if (id !in learned) learned[id] = f.genres[token]?.takeIf { it.isNotEmpty() } ?: NO_GENRE
        if (learned.isEmpty()) return
        store.update { d ->
            var g = d.genres + learned
            if (g.size > 2500) g = g.entries.toList().takeLast(2000).associate { it.key to it.value }
            d.copy(genres = g)
        }
    }

    private fun <T : Any> sampleBy(items: List<T>, n: Int, score: (T) -> Double): List<T> {
        val pool = items.map { it to exp(max(-6.0, min(8.0, score(it))) / 1.2) }.toMutableList()
        val out = ArrayList<T>()
        while (pool.isNotEmpty() && out.size < n) {
            var r = rng.nextDouble() * pool.sumOf { it.second }
            var i = pool.indexOfFirst { r -= it.second; r <= 0 }
            if (i < 0) i = pool.size - 1
            out.add(pool.removeAt(i).first)
        }
        return out
    }

    private fun sample(items: List<Cand>, n: Int): List<Cand> = sampleBy(items, n) { it.total }

    private fun markSeen(tracks: List<Track>, t: Long) {
        store.update { d ->
            var seen = d.seen + tracks.associate { it.id to SeenEntry(t, firstKey(it)) }
            if (seen.size > 900) seen = seen.entries.sortedByDescending { it.value.at }.take(700).associate { it.key to it.value }
            d.copy(seen = seen)
        }
    }

    // ---------- быстрый старт, обратная связь ----------

    /** Несколько треков для мгновенного старта без сети: из запаса прошлого батча или из истории. */
    fun quickStart(): List<Track> {
        val t = now()
        val d = store.data
        val banned = d.banIds.toHashSet() + d.skips
        val neg = negIds(t)
        val recent30 = library.recent.take(30).map { it.id }.toHashSet()
        val liked = library.likes.map { it.id }.toHashSet()
        val spare = d.spare.filter { it.id !in banned && it.id !in neg && it.id !in recent30 && it.id !in liked && !seenPenalty(it.id, t).isInfinite() }
        if (spare.size >= 3) return spare.shuffled(rng).take(4)
        val base = (library.recent.ifEmpty { library.likes + library.recent }).filter { it.id !in banned }
        return base.shuffled(rng).take(3)
    }

    /** Дослушал до конца или почти (доля трека, 0..1): плюс артисту. */
    fun noteListen(track: Track, fraction: Double) {
        if (fraction < 0.7) return
        val t = now()
        val cur = listenScores(t)
        store.update { d ->
            val m = d.listen.toMutableMap()
            for (k in artistKeys(track)) m[k] = ListenEntry((cur[k] ?: 0.0) + 1, t)
            if (m.size > 400) {
                val keep = m.entries.sortedByDescending { it.value.score }.take(300)
                m.clear()
                keep.forEach { m[it.key] = it.value }
            }
            d.copy(listen = m)
        }
    }

    /** Ручной пропуск в первые секунды: трек в чёрный список пропусков, артисту минус; три пропуска и артист исключён. */
    fun noteSkip(track: Track) {
        store.update { d ->
            val sa = d.skipArtists.toMutableMap()
            for (k in artistKeys(track)) sa[k] = (sa[k] ?: 0) + 1
            d.copy(skips = (d.skips + track.id).takeLast(500), skipArtists = sa)
        }
    }

    /** «Не моё»: трек уходит навсегда, артист и жанр получают штраф, похожие на него идут в чёрный список на 30 дней. */
    suspend fun dislike(track: Track) {
        val t = now()
        val known = genreFor(track)
        store.update { d ->
            val ba = d.banArtists.toMutableMap()
            for (k in artistKeys(track)) ba[k] = (ba[k] ?: 0) + 1
            var ng = d.negGenres
            if (known != null) ng = ng + (known to GenreNeg(genrePenalty(known, t) + 1, t))
            d.copy(
                banIds = (d.banIds + track.id).distinct().takeLast(500),
                banArtists = ba,
                negIds = trimNeg(d.negIds + (track.id to t)),
                negGenres = ng,
            )
        }
        val similar = safe(null) { source.similarIds(waveToken(track)) } ?: return
        store.update { d ->
            var ng = d.negGenres
            var genres = d.genres
            if (known == null && similar.genre.isNotEmpty()) {
                ng = ng + (similar.genre to GenreNeg((ng[similar.genre]?.let { max(0.0, it.pen) } ?: 0.0) + 1, t))
                genres = genres + (track.id to similar.genre)
            }
            d.copy(negIds = trimNeg(d.negIds + similar.ids.associateWith { t }), negGenres = ng, genres = genres)
        }
    }

    private fun trimNeg(m: Map<String, Long>): Map<String, Long> =
        if (m.size <= 600) m else m.entries.sortedByDescending { it.value }.take(600).associate { it.key to it.value }
}
