import XCTest
@testable import BlinkCore

final class SvgPathTests: XCTestCase {
    func testPlayIsATriangle() {
        XCTAssertEqual(
            SvgPath.parse("M8,5v14l11,-7z"),
            [.move(x: 8, y: 5), .line(x: 8, y: 19), .line(x: 19, y: 12), .close]
        )
    }

    func testHorizontalAndVerticalCommandsAndTwoSubpaths() {
        XCTAssertEqual(
            SvgPath.parse("M6,19h4V5H6v14zM14,5v14h4V5h-4z"),
            [
                .move(x: 6, y: 19), .line(x: 10, y: 19), .line(x: 10, y: 5), .line(x: 6, y: 5), .line(x: 6, y: 19), .close,
                .move(x: 14, y: 5), .line(x: 14, y: 19), .line(x: 18, y: 19), .line(x: 18, y: 5), .line(x: 14, y: 5), .close,
            ]
        )
    }

    func testRelativeCurveRepeatsWithoutALetterAndStaysRelativeToTheNewPoint() {
        XCTAssertEqual(
            SvgPath.parse("M0,0c1,1 2,2 3,3 4,4 5,5 6,6"),
            [
                .move(x: 0, y: 0),
                .curve(c1x: 1, c1y: 1, c2x: 2, c2y: 2, x: 3, y: 3),
                .curve(c1x: 7, c1y: 7, c2x: 8, c2y: 8, x: 9, y: 9),
            ]
        )
    }

    func testSmoothCurveReflectsThePreviousControlPoint() {
        XCTAssertEqual(
            SvgPath.parse("M0,0C1,2 3,4 5,6S7,8 9,10"),
            [
                .move(x: 0, y: 0),
                .curve(c1x: 1, c1y: 2, c2x: 3, c2y: 4, x: 5, y: 6),
                .curve(c1x: 7, c1y: 8, c2x: 7, c2y: 8, x: 9, y: 10),
            ]
        )
        // без кривой перед S первая опорная точка совпадает с текущей
        XCTAssertEqual(
            SvgPath.parse("M1,1S2,2 3,3"),
            [.move(x: 1, y: 1), .curve(c1x: 1, c1y: 1, c2x: 2, c2y: 2, x: 3, y: 3)]
        )
    }

    func testNumbersGluedTogetherAndImplicitLineTo() {
        XCTAssertEqual(SvgPath.parse("M1-2L.5.5"), [.move(x: 1, y: -2), .line(x: 0.5, y: 0.5)])
        XCTAssertEqual(SvgPath.parse("M0,0 1,1 2,2"), [.move(x: 0, y: 0), .line(x: 1, y: 1), .line(x: 2, y: 2)])
        XCTAssertEqual(SvgPath.parse("m1,1 1,1"), [.move(x: 1, y: 1), .line(x: 2, y: 2)])
    }

    func testCloseReturnsToTheStartOfTheSubpath() {
        XCTAssertEqual(
            SvgPath.parse("M2,2l3,0l0,3zl1,1"),
            [.move(x: 2, y: 2), .line(x: 5, y: 2), .line(x: 5, y: 5), .close, .line(x: 3, y: 3)]
        )
    }

    func testUnsupportedCommandsAndGarbageStopTheParserKeepingWhatItHas() {
        XCTAssertEqual(SvgPath.parse("M1,1L2,2A5,5 0 0 1 9,9L3,3"), [.move(x: 1, y: 1), .line(x: 2, y: 2)])
        XCTAssertEqual(SvgPath.parse(""), [])
        XCTAssertEqual(SvgPath.parse("5,5"), [])
        XCTAssertEqual(SvgPath.parse("M1"), [])
    }

    func testEveryGlyphParsesAndStaysInsideTheGrid() {
        for g in Glyphs.allCases {
            let ops = g.ops
            XCTAssertFalse(ops.isEmpty, "\(g)")
            guard case .move? = ops.first else { return XCTFail("\(g): путь должен начинаться с M") }
            XCTAssertEqual(ops.last, .close, "\(g): контур должен быть замкнут")
            var points: [(Double, Double)] = []
            for op in ops {
                switch op {
                case .move(let x, let y), .line(let x, let y): points.append((x, y))
                case .curve(let a, let b, let c, let d, let x, let y): points += [(a, b), (c, d), (x, y)]
                case .close: break
                }
            }
            for (x, y) in points {
                XCTAssertTrue(x >= -0.5 && x <= 24.5 && y >= -0.5 && y <= 24.5, "\(g): точка (\(x), \(y)) вне сетки 24×24")
            }
        }
    }

    func testGlyphsFillTheirSquare() {
        // Значок, у которого путь съехал или стал крошечным, виден сразу: он занимает хотя бы половину сетки по одной оси.
        for g in Glyphs.allCases {
            var xs: [Double] = []
            var ys: [Double] = []
            for op in g.ops {
                switch op {
                case .move(let x, let y), .line(let x, let y), .curve(_, _, _, _, let x, let y):
                    xs.append(x)
                    ys.append(y)
                case .close: break
                }
            }
            let w = (xs.max() ?? 0) - (xs.min() ?? 0)
            let h = (ys.max() ?? 0) - (ys.min() ?? 0)
            XCTAssertTrue(max(w, h) >= 10, "\(g): значок слишком мелкий (\(w)×\(h))")
        }
    }
}
