// Tests/CoreTests/DatasetNormalizedLinesEquivalenceTests.swift
//
// `DatasetMaterializer.normalizedLines` cuts a CSV into lines with one pass
// over its UTF-8 bytes instead of two `replacingOccurrences` copies and a
// grapheme split. Every sampled, partitioned and stratified dataset a student
// receives is built from these lines, so they must be the lines the old
// computation (`normalizedLinesByReplacing`) returns, Character for
// Character: CR, LF and CR LF endings, empty lines, trailing breaks, and a
// break followed by a combining mark, a joiner or an emoji modifier (the case
// `replacingOccurrences` treats differently, which takes the old path).

import Foundation
import Testing

@testable import Core

@Suite struct DatasetNormalizedLinesEquivalenceTests {

    /// SplitMix64, so the sweep visits the same strings on every run.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static func expectSameLines(_ csv: String) {
        let scanned = DatasetMaterializer.normalizedLines(of: csv)
        let replaced = DatasetMaterializer.normalizedLinesByReplacing(csv)
        let scalars = { (lines: [Substring]) in lines.map { Array($0.unicodeScalars) } }
        #expect(scanned.trailingNewline == replaced.trailingNewline, "\(Array(csv.unicodeScalars))")
        #expect(scanned.lines.map(Array.init) == replaced.lines.map(Array.init), "\(Array(csv.unicodeScalars))")
        #expect(scalars(scanned.lines) == scalars(replaced.lines), "\(Array(csv.unicodeScalars))")
    }

    @Test(arguments: [
        "", "\n", "\r", "\r\n", "\n\r", "a", "a\n", "a\r\n", "a\r", "a\r\n\r\n", "a\n\r", "a\r\r\nb",
        "h,v\n1,2\n3,4", "h,v\r\n1,2\r\n3,4\r\n", "h,v\r1,2\r3,4\r", "\n\na\n\n", "é,ü\nñ,ø\n",
        "a\n\u{301}b", "a\r\n\u{301}", "a\r\u{301}b", "a\n\u{200D}b", "a\n\u{1F3FB}", "a\n\u{0903}b",
        "a\n\u{1F44D}\u{1F3FB}\n", "a\n\u{1100}\u{1161}\n", "a\n\u{2028}b", "a\n\u{85}b", "e\u{301}\r\nb",
        "\u{1F1E6}\u{1F1E8}\r\n\u{1F1E6}",
    ])
    func edgeCasesMatchTheReplacingSplit(csv: String) {
        Self.expectSameLines(csv)
    }

    @Test func seededSweepMatchesTheReplacingSplit() {
        let alphabet = [
            "a", "Z", "1", ",", "\"", " ", "\r", "\n", "\r\n", "é", "e\u{301}", "\u{301}", "\u{200D}", "\u{1F44D}",
            "\u{1F3FB}", "\u{1100}", "\u{1161}", "\u{AC00}", "\u{2028}", "\u{85}", "\u{0903}", "\u{1F1E6}",
        ]
        var generator = SeededGenerator(state: 1_160)
        for _ in 0..<20_000 {
            let length = Int.random(in: 0...12, using: &generator)
            let csv = (0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }
                .joined()
            Self.expectSameLines(csv)
        }
    }

    @Test func aLargeCRLFFileMatchesTheReplacingSplit() {
        let csv = (0..<5_000).map { "row\($0),Ünïcødé \($0),\($0 % 7)\r\n" }.joined()
        Self.expectSameLines(csv)
        #expect(DatasetMaterializer.normalizedLines(of: csv).lines.count == 5_000)
    }
}
