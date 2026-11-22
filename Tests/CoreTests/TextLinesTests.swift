// Tests/CoreTests/TextLinesTests.swift
//
// `textLines` — the line split for code outside RunnerCore. In Swift "\r\n" is
// one `Character`, so a split on "\n" alone does not split CRLF text on Linux.
// These tests pin that CRLF, LF and a lone CR give the same lines, and that
// empty lines are kept in the `components(separatedBy:)` shape.

import Testing

@testable import Core

@Suite struct TextLinesTests {

    @Test(arguments: ["\r\n", "\n", "\r"])
    func everyLineEndingGivesTheSameLines(_ ending: String) {
        let text = ["first", "", "  third", ""].joined(separator: ending)
        #expect(textLines(text) == ["first", "", "  third", ""])
    }

    @Test func aMixOfLineEndingsSplitsAtEachOne() {
        #expect(textLines("a\r\nb\nc\rd") == ["a", "b", "c", "d"])
    }

    @Test func aCRThenAnLFIsOneBreakButAnLFThenACRIsTwo() {
        #expect(textLines("a\r\nb") == ["a", "b"])
        #expect(textLines("a\n\rb") == ["a", "", "b"])
    }

    @Test func emptyTextIsOneEmptyLine() {
        #expect(textLines("") == [""])
    }

    @Test func otherUnicodeLineSeparatorsStayInTheText() {
        #expect(textLines("a\u{2028}b") == ["a\u{2028}b"])
    }
}
