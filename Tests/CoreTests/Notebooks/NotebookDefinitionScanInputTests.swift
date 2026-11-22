// Tests/CoreTests/Notebooks/NotebookDefinitionScanInputTests.swift
//
// `scanNotebookDefinitions(_:language:)` on input that is not a plain run of
// markdown and code cells. `NotebookTestAnchoringTests` covers the normal
// scan. The coverage report showed that no test gave it bytes that are not a
// notebook, or a notebook with a raw cell. The scan must give an empty result
// for the first, and must skip the raw cell without moving any cell index.

import Foundation
import Testing

@testable import Core

@Suite struct NotebookDefinitionScanInputTests {

    @Test func bytesThatAreNotANotebookGiveAnEmptyScan() {
        let scan = scanNotebookDefinitions(Data("not a notebook".utf8), language: .python)

        #expect(scan == NotebookDefinitionScan(definitions: [], sections: [], codeCellIndices: []))
    }

    @Test func aRawCellIsSkippedAndKeepsItsIndex() throws {
        let notebook = """
            {"cells": [
              {"cell_type": "raw", "source": "## Not a section\\nx = 1"},
              {"cell_type": "markdown", "source": "## Task 1"},
              {"cell_type": "code", "source": "total = 3"}
            ], "metadata": {}, "nbformat": 4, "nbformat_minor": 5}
            """

        let scan = scanNotebookDefinitions(Data(notebook.utf8), language: .python)

        #expect(scan.unsupportedReason == nil)
        #expect(scan.sections == [NotebookSectionHeading(name: "Task 1", cellIndex: 1)])
        #expect(scan.codeCellIndices == [2])
        #expect(scan.definition(of: "total") == NotebookDefinition(name: "total", kind: .variable, cellIndex: 2))
        #expect(scan.definition(of: "x") == nil)
        #expect(scan.firstCodeCell(inSection: "Task 1") == 2)
    }

    /// In Swift "\r\n" is one `Character`, so a split on "\n" alone does not
    /// split a CRLF cell on Linux. A notebook saved with CRLF line endings must
    /// give the same sections and definitions as one with LF.
    @Test(arguments: ["\\r\\n", "\\r"])
    func aCellWithOtherLineEndingsGivesItsSectionsAndDefinitions(_ ending: String) throws {
        let notebook = """
            {"cells": [
              {"cell_type": "markdown", "source": "Intro\(ending)## Task 1\(ending)Text"},
              {"cell_type": "code", "source": "total = 3\(ending)count = 4\(ending)"}
            ], "metadata": {}, "nbformat": 4, "nbformat_minor": 5}
            """

        let scan = scanNotebookDefinitions(Data(notebook.utf8), language: .python)

        #expect(scan.sections == [NotebookSectionHeading(name: "Task 1", cellIndex: 0)])
        #expect(scan.definition(of: "total") == NotebookDefinition(name: "total", kind: .variable, cellIndex: 1))
        #expect(scan.definition(of: "count") == NotebookDefinition(name: "count", kind: .variable, cellIndex: 1))
    }
}
