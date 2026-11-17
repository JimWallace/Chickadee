// Tests/APITests/Infrastructure/ProseParagraphsSplitTests.swift
//
// `ProseParagraphs.split` turns free text (a student's written answer, staff
// feedback) into the paragraphs that the AI-assisted feedback review page
// renders as `<p>` elements. It is pure, so no app or database is needed.

import Testing

@testable import APIServer

@Suite struct ProseParagraphsSplitTests {

    @Test func emptyAndBlankTextGiveNoParagraphs() {
        #expect(ProseParagraphs.split("").isEmpty)
        #expect(ProseParagraphs.split("   \n\n \t \n").isEmpty)
    }

    @Test func textWithoutBlankLineIsOneParagraph() {
        #expect(ProseParagraphs.split("One line.") == ["One line."])
    }

    @Test func singleNewlineStaysInsideTheParagraph() {
        #expect(ProseParagraphs.split("First line\nsecond line") == ["First line\nsecond line"])
    }

    @Test func blankLineSeparatesParagraphs() {
        #expect(ProseParagraphs.split("First.\n\nSecond.") == ["First.", "Second."])
    }

    @Test func windowsLineEndingsSplitLikeUnixOnes() {
        #expect(ProseParagraphs.split("First.\r\n\r\nSecond.\r\nMore.") == ["First.", "Second.\nMore."])
    }

    @Test func eachParagraphIsTrimmed() {
        #expect(ProseParagraphs.split("  First.  \n\n\tSecond.\t") == ["First.", "Second."])
    }

    @Test func extraBlankLinesDoNotMakeEmptyParagraphs() {
        #expect(ProseParagraphs.split("\n\nFirst.\n\n\n\n\nSecond.\n\n") == ["First.", "Second."])
    }

    @Test func whitespaceOnlyLineBetweenParagraphsIsDropped() {
        // "A\n\n  \n\nB" splits into "A", "  " and "B". The middle piece is
        // empty after the trim, so it is dropped.
        #expect(ProseParagraphs.split("A\n\n  \n\nB") == ["A", "B"])
    }
}
