// Tests/CoreTests/ReflectionCellsTests.swift
//
// `ReflectionCells` pairs each `reflection`-tagged starter cell with the
// student's matching cell for AI-assisted feedback
// (docs/ai-assisted-feedback.md). These tests pin that the prompt comes from
// the starter, that matching is by cell id and then by position, and that
// nothing untagged leaves the type.

import Foundation
import Testing

@testable import Core

@Suite struct ReflectionCellsTests {
    private func notebook(_ cells: [String]) -> Data {
        Data(#"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[\#(cells.joined(separator: ","))]}"#.utf8)
    }

    private func markdown(_ source: String, id: String? = nil, tagged: Bool = false) -> String {
        let idField = id.map { #""id":"\#($0)","# } ?? ""
        let tags = tagged ? #"{"tags":["reflection"]}"# : "{}"
        return #"{"cell_type":"markdown",\#(idField)"metadata":\#(tags),"source":"\#(source)"}"#
    }

    private func code(_ source: String) -> String {
        #"{"cell_type":"code","metadata":{},"source":"\#(source)","outputs":[],"execution_count":null}"#
    }

    @Test func thePromptIsTheStarterMarkdownBeforeTheTaggedCell() {
        let starter = notebook([markdown("Why?"), markdown("Answer here", tagged: true)])
        let submission = notebook([markdown("I changed the question"), markdown("Because.", tagged: true)])
        #expect(
            ReflectionCells.pairs(starter: starter, submission: submission)
                == [ReflectionPair(index: 1, prompt: "Why?", response: "Because.")])
    }

    @Test func codeAndUntaggedCellsNeverLeave() {
        let starter = notebook([markdown("Q"), markdown("A", tagged: true)])
        let submission = notebook([code("secret = 1"), markdown("notes"), markdown("Mine.", tagged: true)])
        let pairs = ReflectionCells.pairs(starter: starter, submission: submission)
        #expect(pairs.map(\.response) == ["Mine."])
    }

    @Test func cellsMatchByIDBeforePosition() {
        let starter = notebook([
            markdown("Q1"), markdown("A1", id: "a1", tagged: true),
            markdown("Q2"), markdown("A2", id: "a2", tagged: true),
        ])
        // The student's tagged cells are in the other order.
        let submission = notebook([
            markdown("Second answer", id: "a2", tagged: true),
            markdown("First answer", id: "a1", tagged: true),
        ])
        #expect(
            ReflectionCells.pairs(starter: starter, submission: submission).map(\.response)
                == ["First answer", "Second answer"])
    }

    @Test func aMissingCellHasNoResponse() {
        let starter = notebook([
            markdown("Q1"), markdown("A1", tagged: true), markdown("Q2"), markdown("A2", tagged: true),
        ])
        let submission = notebook([markdown("Only one.", tagged: true)])
        #expect(
            ReflectionCells.pairs(starter: starter, submission: submission).map(\.response)
                == ["Only one.", nil])
    }

    @Test func aMissingOrBrokenSubmissionStillListsThePrompts() {
        let starter = notebook([markdown("Q"), markdown("A", tagged: true)])
        #expect(
            ReflectionCells.pairs(starter: starter, submission: nil)
                == [ReflectionPair(index: 1, prompt: "Q", response: nil)])
        #expect(ReflectionCells.pairs(starter: starter, submission: Data("not json".utf8)).first?.response == nil)
    }

    @Test func aStarterWithNoTagsHasNoPairs() {
        let starter = notebook([markdown("Q"), markdown("A")])
        #expect(ReflectionCells.pairs(starter: starter, submission: starter).isEmpty)
        #expect(!ReflectionCells.hasTaggedCells(starter))
        #expect(ReflectionCells.hasTaggedCells(notebook([markdown("A", tagged: true)])))
    }
}
