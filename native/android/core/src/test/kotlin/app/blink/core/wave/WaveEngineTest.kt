package app.blink.core.wave

import app.blink.core.model.Track
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

private class Mem : BlobStore {
    var value: String? = null
    override fun load() = value
    override fun save(value: String?) { this.value = value }
}

private class Lib(override val likes: List<Track>, override val recent: List<Track> = emptyList()) : Library

private fun tr(id: Int, artist: String, genre: String, title: String = "Song $id") = Track(id = "cr$id", title = title, artist = artist, genre = genre, source = "chart")

private class FakeSource(val pool: List<WaveCandidate>, val top: List<Track>, val weekly: List<Track> = emptyList()) : WaveSource {
    var down = false
    val similarCalls = ArrayList<String>()
    override suspend fun pool(seeds: List<String>): PoolResult {
        if (down) error("down")
        return PoolResult(pool, emptyList())
    }
    override suspend fun genres(items: List<String>): Map<String, String> = emptyMap()
    override suspend fun similarIds(seed: String): SimilarResult {
        similarCalls.add(seed)
        return SimilarResult(listOf("cr777", "cr778"), "rap")
    }
    override suspend fun topChart(): List<Track> { if (down) error("down"); return top }
    override suspend fun periodChart(kind: String): List<Track> { if (down) error("down"); return if (kind == "weekly") weekly else emptyList() }
}

class WaveEngineTest {
    private val clock = longArrayOf(1_800_000_000_000L)
    private val genres = listOf("rusrap", "local-indie", "pop")

    /** 3 жанра по 4 артиста по 3 лайка и две «шумовые» одиночки из метала (≈4% профиля, меньше порога 6%). */
    private fun likes(): List<Track> {
        val out = ArrayList<Track>()
        var id = 1
        for (g in genres) for (a in 1..4) for (k in 1..3) out.add(tr(id++, "$g artist $a", g))
        out.add(tr(900, "Noise one", "metal"))
        out.add(tr(901, "Noise two", "metal"))
        return out
    }

    private fun pool(): List<WaveCandidate> {
        val out = ArrayList<WaveCandidate>()
        var id = 100
        for (g in genres) for (a in 1..14) out.add(WaveCandidate(tr(id++, "pool ${g} $a", g), if (a % 3 == 0) "popular" else "similar", "seed", 1))
        for (n in 1..4) out.add(WaveCandidate(tr(800 + n, "Metal band $n", "metal"), "similar", "seed", 1))
        return out
    }

    private fun top(): List<Track> = (1..12).map { tr(300 + it, "chart ${genres[it % 3]} $it", genres[it % 3]) } + (1..3).map { tr(850 + it, "Chart metal $it", "metal") }

    private fun engine(src: WaveSource, store: WaveStore, lib: Library = Lib(likes()), settings: WaveSettings = WaveSettings(), seed: Int = 1) =
        WaveEngine(src, store, lib, { settings }, { clock[0] }, Random(seed))

    @Test
    fun `profile keeps single likes out of the core and out of the genre top`() {
        val e = engine(FakeSource(pool(), top()), WaveStore(Mem()))
        val p = e.buildProfile(clock[0])
        assertEquals(12, p.core.size, "ядро: 12 артистов по три лайка")
        assertEquals(setOf("rusrap", "local-indie", "pop"), p.top)
        assertFalse("metal" in p.top, "две одиночки из метала меньше 6% вкуса")
        assertTrue(p.active)
    }

    @Test
    fun `batch has the right size and does not take foreign genres without the explore slot`() = runBlocking {
        val e = engine(FakeSource(pool(), top()), WaveStore(Mem()), settings = WaveSettings(explore = false))
        val b = e.batch(16)
        assertEquals(16, b.size)
        assertTrue(b.none { it.genre == "metal" }, "метал не в профиле: ${b.filter { it.genre == "metal" }.map { it.artist }}")
        assertTrue(b.groupBy { it.artist.lowercase() }.values.all { it.size <= 2 }, "не больше двух треков артиста")
        assertEquals(b.size, b.map { it.id }.toSet().size)
    }

    @Test
    fun `explore slot lets at most a couple of foreign tracks through`() = runBlocking {
        val e = engine(FakeSource(pool(), top()), WaveStore(Mem()), settings = WaveSettings(explore = true))
        var metal = 0
        repeat(5) { metal += e.batch(16, emptySet()).count { it.genre == "metal" }; clock[0] += 3 * 86_400_000L }
        assertTrue(metal <= 5 * 2, "слот исследования: около двух из шестнадцати, было $metal")
    }

    @Test
    fun `the next batch does not repeat what was just shown`() = runBlocking {
        val e = engine(FakeSource(pool(), top()), WaveStore(Mem()))
        val a = e.batch(16).map { it.id }.toSet()
        clock[0] += 60_000
        val b = e.batch(16).map { it.id }.toSet()
        assertTrue(a.intersect(b).isEmpty(), "повторы: ${a.intersect(b)}")
    }

    @Test
    fun `tracks already in the queue and in recent are skipped`() = runBlocking {
        val recent = listOf(tr(101, "pool rusrap 1", "rusrap"))
        val e = engine(FakeSource(pool(), top()), WaveStore(Mem()), Lib(likes(), recent))
        val b = e.batch(16, exclude = setOf("cr102", "cr103"))
        assertTrue(b.none { it.id == "cr101" || it.id == "cr102" || it.id == "cr103" })
    }

    @Test
    fun `dislike twice removes the artist for good and blacklists similar tracks`() = runBlocking {
        val src = FakeSource(pool(), top())
        val store = WaveStore(Mem())
        val e = engine(src, store)
        val victim = tr(101, "pool rusrap 1", "rusrap")
        e.dislike(victim)
        e.dislike(tr(555, "pool rusrap 1", "rusrap", "Another"))
        assertEquals(2, store.data.banArtists["pool rusrap 1"])
        assertTrue("cr777" in store.data.negIds && "cr778" in store.data.negIds)
        assertEquals(listOf("cr101", "cr555"), store.data.banIds)
        assertEquals("cr101", src.similarCalls.first())
        repeat(4) { assertTrue(e.batch(16).none { it.artist == "pool rusrap 1" }); clock[0] += 2 * 86_400_000L }
    }

    @Test
    fun `three early skips exclude the artist, listening to the end raises it`() = runBlocking {
        val store = WaveStore(Mem())
        val e = engine(FakeSource(pool(), top()), store)
        val t = tr(102, "pool rusrap 2", "rusrap")
        repeat(3) { e.noteSkip(t) }
        assertTrue(e.batch(16).none { it.artist == "pool rusrap 2" })
        e.noteListen(tr(103, "pool rusrap 3", "rusrap"), 0.5)
        assertTrue(store.data.listen.isEmpty(), "меньше 70% не считается")
        e.noteListen(tr(103, "pool rusrap 3", "rusrap"), 0.9)
        assertEquals(1.0, store.data.listen["pool rusrap 3"]?.score)
    }

    @Test
    fun `discover mode never returns favourite artists`() = runBlocking {
        val withFavourite = pool() + WaveCandidate(tr(150, "rusrap artist 1", "rusrap"), "similar", "seed", 3)
        val e = engine(FakeSource(withFavourite, top()), WaveStore(Mem()), settings = WaveSettings(WaveMode.DISCOVER))
        repeat(3) { assertTrue(e.batch(16).none { it.artist.startsWith("rusrap artist") }); clock[0] += 2 * 86_400_000L }
    }

    @Test
    fun `server down means an empty batch so the caller can fall back`() = runBlocking {
        val src = FakeSource(pool(), top())
        src.down = true
        assertEquals(emptyList(), engine(src, WaveStore(Mem())).batch(16))
    }

    @Test
    fun `quick start uses the spare from the last batch and then the history`() = runBlocking {
        val store = WaveStore(Mem())
        val e = engine(FakeSource(pool(), top()), store)
        assertEquals(3, e.quickStart().size, "первый запуск: из лайков и истории")
        clock[0] += 3 * 86_400_000L
        e.batch(16)
        assertTrue(store.data.spare.size >= 3)
        clock[0] += 3 * 86_400_000L
        val q = e.quickStart()
        assertEquals(4, q.size)
        assertTrue(q.all { it.id in store.data.spare.map { s -> s.id } })
    }

    @Test
    fun `state survives a restart`() = runBlocking {
        val mem = Mem()
        val s1 = WaveStore(mem)
        engine(FakeSource(pool(), top()), s1).batch(16)
        val s2 = WaveStore(mem)
        assertEquals(s1.data.seen.keys, s2.data.seen.keys)
        assertTrue(s2.data.seen.isNotEmpty())
    }

    @Test
    fun `splitArtists handles collaborations`() {
        assertEquals(listOf("A", "B", "C"), splitArtists("A, B feat. C"))
        assertEquals(listOf("Kid", "Mad"), splitArtists("Kid & Mad"))
        assertEquals(listOf("Solo"), splitArtists("Solo"))
    }
}
