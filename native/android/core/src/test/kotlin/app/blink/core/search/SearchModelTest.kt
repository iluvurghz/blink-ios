package app.blink.core.search

import app.blink.core.model.Track
import java.io.IOException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class SearchModelTest {
    private fun t(id: String) = Track(id = id, title = id, artist = "A")

    @Test
    fun `waits 350 ms, the last query wins`() = runTest {
        val asked = ArrayList<String>()
        val model = SearchModel(backgroundScope, { q -> asked += q; listOf(t(q)) }, { emptyList() }, { emptyList() })
        runCurrent()
        model.setQuery("b")
        runCurrent()
        assertTrue(model.state.value.loading)
        advanceTimeBy(200)
        model.setQuery("bl")
        advanceTimeBy(200)
        runCurrent()
        assertTrue(asked.isEmpty(), "ещё идёт задержка")
        advanceTimeBy(200)
        runCurrent()
        assertEquals(listOf("bl"), asked)
        assertEquals(listOf("bl"), model.state.value.results.map { it.id })
        assertTrue(model.state.value.searched)
        assertFalse(model.state.value.loading)
    }

    @Test
    fun `a slow old answer never overwrites a newer one`() = runTest {
        val model = SearchModel(
            backgroundScope,
            { q ->
                if (q == "slow") delay(10_000)
                listOf(t(q))
            },
            { emptyList() },
            { emptyList() },
        )
        runCurrent()
        model.setQuery("slow")
        advanceTimeBy(400)
        model.setQuery("fast")
        advanceTimeBy(400)
        runCurrent()
        advanceTimeBy(20_000)
        runCurrent()
        assertEquals(listOf("fast"), model.state.value.results.map { it.id })
    }

    @Test
    fun `empty query clears at once, error is reported and retry runs without waiting`() = runTest {
        var fail = true
        var calls = 0
        val model = SearchModel(
            backgroundScope,
            { q ->
                calls++
                if (fail) throw IOException("offline")
                listOf(t(q))
            },
            { emptyList() },
            { emptyList() },
        )
        runCurrent()
        model.setQuery("abc")
        advanceTimeBy(400)
        runCurrent()
        assertTrue(model.state.value.error)
        assertTrue(model.state.value.searched)
        fail = false
        model.retry()
        runCurrent()
        assertFalse(model.state.value.error)
        assertEquals(listOf("abc"), model.state.value.results.map { it.id })
        assertEquals(2, calls)
        model.setQuery("  ")
        runCurrent()
        assertFalse(model.state.value.searched)
        assertTrue(model.state.value.results.isEmpty())
    }

    @Test
    fun `home survives one failing half`() = runTest {
        val model = SearchModel(backgroundScope, { emptyList() }, { listOf(t("new")) }, { throw IOException("x") })
        runCurrent()
        model.refreshHome()
        runCurrent()
        val s = model.state.value
        assertEquals(listOf("new"), s.newest.map { it.id })
        assertTrue(s.chart.isEmpty())
        assertFalse(s.homeError)
        assertFalse(s.homeLoading)
    }

    @Test
    fun `home error only when both halves fail and nothing is shown`() = runTest {
        val model = SearchModel(backgroundScope, { emptyList() }, { throw IOException("x") }, { throw IOException("y") })
        runCurrent()
        model.refreshHome()
        runCurrent()
        assertTrue(model.state.value.homeError)
    }
}
