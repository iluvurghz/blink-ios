import Foundation

public struct LrcWord: Equatable, Sendable {
    public let timeMs: Int64
    public let text: String

    public init(timeMs: Int64, text: String) {
        self.timeMs = timeMs
        self.text = text
    }
}

public struct LrcLine: Equatable, Sendable {
    public let timeMs: Int64
    public let text: String
    public let words: [LrcWord]?

    public init(timeMs: Int64, text: String, words: [LrcWord]? = nil) {
        self.timeMs = timeMs
        self.text = text
        self.words = words
    }
}

/// Разбор LRC: те же правила, что у `parseLrc` на сайте (метки `[mm:ss.xx]`, у строки может быть несколько меток).
public enum Lrc {
    public static func parse(_ text: String) -> [LrcLine] {
        guard
            let tagRe = try? NSRegularExpression(pattern: "\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]"),
            let wordRe = try? NSRegularExpression(pattern: "<(\\d+):(\\d+(?:\\.\\d+)?)>([^<]*)"),
            let hasWordsRe = try? NSRegularExpression(pattern: "<\\d+:\\d+(?:\\.\\d+)?>")
        else { return [] }

        var out: [LrcLine] = []
        // components(separatedBy:) режет по \n даже внутри \r\n (в отличие от split по Character).
        for raw in text.components(separatedBy: "\n") {
            var line = raw
            while line.hasSuffix("\r") { line.removeLast() }
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            let tags = tagRe.matches(in: line, range: full)
            if tags.isEmpty { continue }

            var body = tagRe.stringByReplacingMatches(in: line, range: full, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var words: [LrcWord]?
            let bodyNS = body as NSString
            let bodyRange = NSRange(location: 0, length: bodyNS.length)
            if hasWordsRe.firstMatch(in: body, range: bodyRange) != nil {
                var list: [LrcWord] = []
                for m in wordRe.matches(in: body, range: bodyRange) {
                    let w = bodyNS.substring(with: m.range(at: 3))
                    if !w.isEmpty {
                        list.append(LrcWord(timeMs: ms(bodyNS.substring(with: m.range(at: 1)), bodyNS.substring(with: m.range(at: 2))), text: w))
                    }
                }
                words = list
                body = list.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for t in tags {
                out.append(LrcLine(timeMs: ms(ns.substring(with: t.range(at: 1)), ns.substring(with: t.range(at: 2))), text: body, words: words))
            }
        }
        // Стабильная сортировка: равные метки остаются в порядке строк.
        return out.enumerated()
            .sorted { a, b in a.element.timeMs != b.element.timeMs ? a.element.timeMs < b.element.timeMs : a.offset < b.offset }
            .map { $0.element }
    }

    /// Индекс строки, которая звучит в этот момент, или -1 до первой.
    public static func activeIndex(_ lines: [LrcLine], positionMs: Int64) -> Int {
        var lo = 0
        var hi = lines.count - 1
        var ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].timeMs <= positionMs {
                ans = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return ans
    }

    private static func ms(_ min: String, _ sec: String) -> Int64 {
        let m = Int64(min) ?? 0
        let s = Double(sec) ?? 0
        return m * 60_000 + Int64((s * 1000).rounded())
    }
}
