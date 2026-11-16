// Tests/APITests/PatternFamilies/OctaveCellContainsMustDifferTests.swift
//
// The Octave `.cellContains` renderer's must-differ-from branch, at the source
// level. The execution suite (`OctaveNotebookCheckExecutionTests`) covers the
// literal and regex matchers but not this branch, and it needs octave-cli. These
// tests pin what the branch writes: the example as an Octave literal, the
// whitespace-normalized comparison over every matched cell, and the order of
// the steps (no match fails first, a copy of the example fails second, a pass
// comes last).

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct OctaveCellContainsMustDifferTests {

    private static func render(containsText: String, regex: Bool? = nil, mustDifferFrom: String?) -> String {
        let check = NotebookCheck(
            id: "loop", kind: .cellContains, containsText: containsText, regex: regex,
            mustDifferFrom: mustDifferFrom)
        return renderNotebookCheck(check, language: .octave).script.source
    }

    @Test func mustDifferFromEmitsTheExampleAndTheComparison() throws {
        let example = "for i = 1:10\n  disp(i);\nend"
        let source = Self.render(containsText: "for i", mustDifferFrom: example)

        #expect(source.contains("must_differ_from = \(JSONValue.string(example).octaveLiteral);"))
        #expect(source.contains("reference = ck_ws_normalize(must_differ_from);"))
        #expect(source.contains("if !strcmp(ck_ws_normalize(matched{i}), reference)"))
        #expect(source.contains("is identical to the example."))
        #expect(source.contains("write your own version, not a copy of the prompt's example"))
        #expect(!source.contains("% (no must-differ-from constraint)"))
    }

    @Test func mustDifferCheckRunsAfterTheNoMatchCheckAndBeforeThePass() throws {
        let source = Self.render(containsText: "plot(", mustDifferFrom: "plot(x, y)")

        let noMatch = try #require(source.range(of: "if isempty(matched)"))
        let identical = try #require(source.range(of: "if all_identical"))
        let passed = try #require(source.range(of: "chickadee.passed("))
        #expect(noMatch.upperBound < identical.lowerBound)
        #expect(identical.upperBound < passed.lowerBound)
    }

    @Test func aCellThatDiffersClearsTheFlagAndStopsTheLoop() throws {
        let source = Self.render(containsText: "x", mustDifferFrom: "x = 1;")
        let start = try #require(source.range(of: "all_identical = true;"))
        let tail = source[start.upperBound...]
        let clear = try #require(tail.range(of: "all_identical = false;"))
        let stop = try #require(tail.range(of: "break;"))
        #expect(clear.upperBound <= stop.lowerBound)
    }

    @Test func anExampleWithQuotesIsEscapedNotSpliced() {
        let example = #"disp("done")"#
        let source = Self.render(containsText: "disp", mustDifferFrom: example)
        let literal = JSONValue.string(example).octaveLiteral

        #expect(source.contains("must_differ_from = \(literal);"))
        #expect(!source.contains(#"must_differ_from = "disp("done")";"#))
    }

    @Test func withoutMustDifferFromOnlyThePlaceholderComment() {
        let source = Self.render(containsText: "for i", mustDifferFrom: nil)

        #expect(source.contains("% (no must-differ-from constraint)"))
        #expect(!source.contains("must_differ_from ="))
        #expect(!source.contains("all_identical"))
    }

    @Test func mustDifferFromAppliesToTheRegexMatcherToo() {
        let source = Self.render(containsText: #"for\s+\w+"#, regex: true, mustDifferFrom: "for k = 1:3\nend")

        #expect(source.contains(#"!isempty(regexp(cell_text, needle, "once"))"#))
        #expect(!source.contains("strfind(cell_text, needle)"))
        #expect(source.contains("if all_identical"))
    }
}
