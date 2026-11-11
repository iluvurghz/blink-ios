import XCTest
@testable import BlinkCore

final class KeyContentTests: XCTestCase {
    func testFkeyIsHexOfUtf8KeyContractVector() {
        XCTAssertEqual(Key.fkey("blink:abc"), "626c696e6b3a616263")
        XCTAssertEqual(Key.fromFkey("626c696e6b3a616263"), "blink:abc")
        XCTAssertEqual(Key.fromFkey(Key.fkey("blink:трек")), "blink:трек")
        XCTAssertNil(Key.fromFkey("zz"))
        XCTAssertNil(Key.fromFkey("abc"))
    }

    func testContentTypes() {
        XCTAssertTrue(Content.typeOk("audio/mpeg"))
        XCTAssertTrue(Content.typeOk("Audio/MP4; charset=binary"))
        XCTAssertTrue(Content.typeOk("application/octet-stream"))
        XCTAssertTrue(Content.typeOk(nil))
        XCTAssertFalse(Content.typeOk("text/html; charset=utf-8"))
        XCTAssertFalse(Content.typeOk("application/json"))
    }

    private func pad(_ a: [UInt8], _ n: Int = 16) -> [UInt8] {
        return a + [UInt8](repeating: 0, count: max(0, n - a.count))
    }

    private func text(_ s: String) -> [UInt8] {
        return Array(s.utf8)
    }

    func testMagicBytes() {
        XCTAssertTrue(Content.magicOk(pad(text("ID3"))))
        XCTAssertTrue(Content.magicOk(pad([0xFF, 0xFB, 0x90])))
        XCTAssertTrue(Content.magicOk(pad([0xFF, 0xE3])))
        XCTAssertFalse(Content.magicOk(pad([0xFF, 0x1B])))
        XCTAssertTrue(Content.magicOk(pad([0, 0, 0, 0x20] + text("ftypM4A "))))
        XCTAssertTrue(Content.magicOk(pad(text("OggS"))))
        XCTAssertTrue(Content.magicOk(pad(text("fLaC"))))
        XCTAssertTrue(Content.magicOk(pad(text("RIFF") + [1, 2, 3, 4] + text("WAVE"))))
        XCTAssertFalse(Content.magicOk(pad(text("RIFF") + [1, 2, 3, 4] + text("AVI "))))
        XCTAssertFalse(Content.magicOk(pad(text("<!DOCTYPE html>"))))
        XCTAssertFalse(Content.magicOk(pad(text("{\"error\":1}"))))
        XCTAssertFalse(Content.magicOk([]))
        XCTAssertFalse(Content.magicOk([UInt8](repeating: 0, count: 12)))
    }

    private func verifyReason(_ have: Int64, _ total: Int64?, _ resolved: Int64?, _ duration: Int) -> String? {
        do {
            try Content.verifyFinal(have: have, total: total, resolvedBytes: resolved, durationSec: duration)
            return nil
        } catch let e as OfflineError {
            XCTAssertEqual(e.code, .badContent)
            return e.reason
        } catch {
            return "unexpected \(error)"
        }
    }

    func testLowerBoundByDurationContractVector213s() {
        XCTAssertEqual(Content.minBytes(durationSec: 213), 426_000)
        XCTAssertEqual(Content.minBytes(durationSec: 3), 16_384)
        XCTAssertEqual(verifyReason(300_000, 300_000, 300_000, 213), "too_small")
        XCTAssertNil(verifyReason(426_000, 426_000, 426_000, 213))
    }

    func testFinalVerification() {
        XCTAssertEqual(verifyReason(100_000, 200_000, 200_000, 10), "truncated")
        XCTAssertEqual(verifyReason(200_000, 200_000, 199_999, 10), "size_mismatch")
        XCTAssertEqual(verifyReason(200_000, nil, nil, 10), "no_size")
        XCTAssertEqual(verifyReason(Content.maxBytes + 1, Content.maxBytes + 1, nil, 10), "too_big")
        XCTAssertNil(verifyReason(200_000, 200_000, nil, 10)) // обход через /api/play: bytes нет
    }

    func testTextsMatchTheContract() {
        XCTAssertEqual(OfflineTexts.of(.notAllowed, "source").message, "Этот трек играет только онлайн")
        XCTAssertEqual(OfflineTexts.of(.notAllowed, "plus").message, "Сохранение для офлайна доступно с Blink+")
        XCTAssertEqual(OfflineTexts.of(.notAllowed, "plus").action, .openPlus)
        XCTAssertEqual(OfflineTexts.of(.notAllowed, "artist").message, "Артист не разрешил сохранять этот трек")
        XCTAssertEqual(OfflineTexts.of(.notAllowed, "auth").message, "Войдите в аккаунт")
        XCTAssertEqual(OfflineTexts.of(.noNetwork).message, "Нет интернета")
        XCTAssertEqual(OfflineTexts.of(.badContent).message, "Файл пришёл повреждённым")
        XCTAssertEqual(OfflineTexts.of(.noSpace).message, "Не хватает места на устройстве")
        XCTAssertTrue(OfflineCode.notAllowed.isRefusal && OfflineCode.badContent.isRefusal && !OfflineCode.noSpace.isRefusal)
        XCTAssertTrue(OfflineCode.timeout.retryable && OfflineCode.sourceError.retryable && !OfflineCode.badContent.retryable)
    }
}
