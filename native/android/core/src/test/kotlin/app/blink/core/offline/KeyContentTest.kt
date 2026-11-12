package app.blink.core.offline

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class KeyContentTest {
    @Test
    fun `fkey is hex of utf8 key (contract vector)`() {
        assertEquals("626c696e6b3a616263", Key.fkey("blink:abc"))
        assertEquals("blink:abc", Key.fromFkey("626c696e6b3a616263"))
        assertEquals("blink:трек", Key.fromFkey(Key.fkey("blink:трек")))
        assertNull(Key.fromFkey("zz"))
        assertNull(Key.fromFkey("abc"))
    }

    @Test
    fun `content types`() {
        assertTrue(Content.typeOk("audio/mpeg"))
        assertTrue(Content.typeOk("Audio/MP4; charset=binary"))
        assertTrue(Content.typeOk("application/octet-stream"))
        assertTrue(Content.typeOk(null))
        assertFalse(Content.typeOk("text/html; charset=utf-8"))
        assertFalse(Content.typeOk("application/json"))
    }

    private fun b(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }
    private fun pad(a: ByteArray, n: Int = 16) = a.copyOf(maxOf(n, a.size))

    @Test
    fun `magic bytes`() {
        assertTrue(Content.magicOk(pad("ID3".toByteArray())))
        assertTrue(Content.magicOk(pad(b(0xff, 0xfb, 0x90))))
        assertTrue(Content.magicOk(pad(b(0xff, 0xe3))))
        assertFalse(Content.magicOk(pad(b(0xff, 0x1b))))
        assertTrue(Content.magicOk(pad(b(0, 0, 0, 0x20) + "ftypM4A ".toByteArray())))
        assertTrue(Content.magicOk(pad("OggS".toByteArray())))
        assertTrue(Content.magicOk(pad("fLaC".toByteArray())))
        assertTrue(Content.magicOk(pad("RIFF".toByteArray() + b(1, 2, 3, 4) + "WAVE".toByteArray())))
        assertFalse(Content.magicOk(pad("RIFF".toByteArray() + b(1, 2, 3, 4) + "AVI ".toByteArray())))
        assertFalse(Content.magicOk(pad("<!DOCTYPE html>".toByteArray())))
        assertFalse(Content.magicOk(pad("{\"error\":1}".toByteArray())))
        assertFalse(Content.magicOk(ByteArray(0)))
        assertFalse(Content.magicOk(ByteArray(12)))
    }

    @Test
    fun `lower bound by duration (contract vector 213 s)`() {
        assertEquals(426_000L, Content.minBytes(213))
        assertEquals(16_384L, Content.minBytes(3))
        val e = assertFailsWith<OfflineException> { Content.verifyFinal(300_000, 300_000, 300_000, 213) }
        assertEquals(OfflineCode.BAD_CONTENT, e.code)
        assertEquals("too_small", e.reason)
        Content.verifyFinal(426_000, 426_000, 426_000, 213)
    }

    @Test
    fun `final verification`() {
        assertEquals("truncated", assertFailsWith<OfflineException> { Content.verifyFinal(100_000, 200_000, 200_000, 10) }.reason)
        assertEquals("size_mismatch", assertFailsWith<OfflineException> { Content.verifyFinal(200_000, 200_000, 199_999, 10) }.reason)
        assertEquals("no_size", assertFailsWith<OfflineException> { Content.verifyFinal(200_000, null, null, 10) }.reason)
        assertEquals("too_big", assertFailsWith<OfflineException> { Content.verifyFinal(Content.MAX_BYTES + 1, Content.MAX_BYTES + 1, null, 10) }.reason)
        Content.verifyFinal(200_000, 200_000, null, 10) // обход через /api/play: bytes нет
    }

    @Test
    fun `texts match the contract`() {
        assertEquals("Этот трек играет только онлайн", OfflineTexts.of(OfflineCode.NOT_ALLOWED, "source").message)
        assertEquals("Сохранение для офлайна доступно с Blink+", OfflineTexts.of(OfflineCode.NOT_ALLOWED, "plus").message)
        assertEquals(OfflineText.Action.OPEN_PLUS, OfflineTexts.of(OfflineCode.NOT_ALLOWED, "plus").action)
        assertEquals("Артист не разрешил сохранять этот трек", OfflineTexts.of(OfflineCode.NOT_ALLOWED, "artist").message)
        assertEquals("Войдите в аккаунт", OfflineTexts.of(OfflineCode.NOT_ALLOWED, "auth").message)
        assertEquals("Нет интернета", OfflineTexts.of(OfflineCode.NO_NETWORK).message)
        assertEquals("Файл пришёл повреждённым", OfflineTexts.of(OfflineCode.BAD_CONTENT).message)
        assertEquals("Не хватает места на устройстве", OfflineTexts.of(OfflineCode.NO_SPACE).message)
        assertTrue(OfflineCode.NOT_ALLOWED.isRefusal && OfflineCode.BAD_CONTENT.isRefusal && !OfflineCode.NO_SPACE.isRefusal)
        assertTrue(OfflineCode.TIMEOUT.retryable && OfflineCode.SOURCE_ERROR.retryable && !OfflineCode.BAD_CONTENT.retryable)
    }
}
