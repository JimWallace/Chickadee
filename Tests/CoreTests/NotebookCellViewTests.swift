// Tests/CoreTests/NotebookCellViewTests.swift
//
// `NotebookCellView` replaced `NotebookCellSources.cells(from:)` and
// `cellSource(_:)` in the read-only cell walkers (reflection cells, the
// definition and function scans, the solution extractor and the notebook
// guide). These tests pin that it keeps the rules of the casts it replaced,
// and the documented differences from `JSONSerialization`.

import Foundation
import Testing

@testable import Core

@Suite struct NotebookCellViewTests {

    private func cells(_ json: String) -> [NotebookCellView]? {
        NotebookCellView.cells(from: Data(json.utf8))
    }

    @Test func readsTypeSourceIDAndTags() throws {
        let read = try #require(
            cells(
                """
                {"cells": [
                  {"cell_type": "markdown", "id": "a1", "source": "## Part 1"},
                  {"cell_type": "code", "id": "b2", "metadata": {"tags": ["reflection", "x"]},
                   "source": ["y = 1\\n", "y += 1"], "outputs": [{"data": {"text/plain": ["2"]}}]}
                ]}
                """))
        #expect(
            read == [
                NotebookCellView(cellType: "markdown", source: "## Part 1", id: "a1"),
                NotebookCellView(cellType: "code", source: "y = 1\ny += 1", id: "b2", tags: ["reflection", "x"]),
            ])
    }

    @Test(arguments: [
        "[]", "{}", "{\"cells\": {}}", "{\"cells\": null}", "{\"cells\": [{}, \"not a cell\"]}", "", "{not json",
    ])
    func isNilUnlessCellsIsAnArrayOfObjects(_ json: String) {
        #expect(cells(json) == nil)
    }

    @Test func anEmptyCellListIsEmpty() throws {
        #expect(try #require(cells("{\"cells\": []}")).isEmpty)
    }

    /// The rules of `NotebookCellSources.cellSource`: an array source counts
    /// only when every element is a string, and anything else is empty.
    @Test func sourceOfAnotherShapeIsEmpty() throws {
        let read = try #require(
            cells(
                """
                {"cells": [{"source": ["a", 1]}, {"source": 3}, {"source": null}, {}]}
                """))
        #expect(read.map(\.source) == ["", "", "", ""])
    }

    @Test func fieldsOfTheWrongTypeReadAsAbsent() throws {
        let read = try #require(
            cells(
                """
                {"cells": [
                  {"cell_type": 1, "id": 2, "metadata": {"tags": ["ok", 3]}},
                  {"metadata": {"tags": "reflection"}},
                  {"metadata": ["tags"]}
                ]}
                """))
        #expect(read.allSatisfy { $0.cellType == nil && $0.id == nil && $0.tags == nil })
    }

    /// Documented difference: invalid JSON in a part that is not read does not
    /// stop the read. `JSONSerialization` rejects the whole document.
    @Test func invalidJSONInAnOutputStillReadsTheCells() throws {
        let json = "{\"cells\": [{\"cell_type\": \"code\", \"source\": \"x\", \"outputs\": [\"a\nb\"]}]}"
        #expect((try? JSONSerialization.jsonObject(with: Data(json.utf8))) == nil)
        #expect(try #require(cells(json)).map(\.source) == ["x"])
    }

    /// Documented difference: when a key appears twice, the first value wins.
    @Test func theFirstOfTwoDuplicateKeysWins() throws {
        let read = try #require(cells("{\"cells\": [{\"source\": \"first\", \"source\": \"last\"}]}"))
        #expect(read.map(\.source) == ["first"])
    }
}
