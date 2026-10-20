// Tests/WorkerTests/NotebookExtractorPythonParityTests.swift
//
// Pins the generic Python notebook path to RunnerCore (#2715). The worker's
// `extractNotebooksToCode` and the browser runner's wasm `extractPython` must
// write the same bytes for the same notebook. The worker once assembled Python
// cells by hand, with no `# --- cell N ---` labels and a header-only file for a
// notebook with no code cells; this suite fails if a second copy comes back.
// It pins the routing (both language routes reach `extractPython` and the
// `.py` file holds its module). `NotebookExtractionTests` pins the bytes.

import ChickadeeTestSupport
import Core
import Foundation
import RunnerCore
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) struct NotebookExtractorPythonParityTests {

    /// One notebook, as `(cell_type, source)` pairs.
    private struct Notebook: Sendable, CustomTestStringConvertible {
        let name: String
        let cells: [(type: String, source: String)]
        var testDescription: String { name }
    }

    private static let notebooks: [Notebook] = [
        Notebook(
            name: "definitions and calls",
            cells: [
                ("code", "def add(a, b):\n    return a + b\n"),
                ("markdown", "# Heading"),
                ("code", "result = add(1, 2)\nprint(result)"),
            ]),
        Notebook(
            name: "magics, blank cells and a future import",
            cells: [
                ("code", "from __future__ import annotations"),
                ("code", "   \n  "),
                ("code", "%matplotlib inline\n!pip install x\nimport math"),
                ("code", "%time"),
                ("code", "x = math.pi"),
            ]),
        Notebook(
            name: "no code cells",
            cells: [("markdown", "Only prose.")]),
        Notebook(
            name: "quotes and escapes",
            cells: [("code", "s = \"a/b\\n\"\nt = '''x\ny'''")]),
    ]

    private func notebookData(_ notebook: Notebook) throws -> Data {
        let cells = notebook.cells.map { cell in
            ["cell_type": cell.type, "source": cell.source, "metadata": [:] as [String: Any]] as [String: Any]
        }
        let json: [String: Any] = [
            "cells": cells,
            "nbformat": 4,
            "nbformat_minor": 5,
            "metadata": ["kernelspec": ["name": "python3", "language": "python"]],
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }

    @Test(arguments: notebooks)
    private func workerWritesTheRunnerCoreModule(_ notebook: Notebook) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ck-pyparity-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try notebookData(notebook).write(to: dir.appendingPathComponent("analysis.ipynb"))

        try extractNotebooksToCode(in: dir, forcedLanguage: nil)
        let written = try String(contentsOf: dir.appendingPathComponent("analysis.py"), encoding: .utf8)

        let expected = extractPython(
            cells: notebook.cells.map { NotebookCell(cellType: $0.type, source: $0.source) },
            filename: "analysis.ipynb"
        ).executableModule
        #expect(written == expected)
    }

    /// The forced-language route reaches the same arm, so it must agree too.
    @Test func forcedPythonWritesTheRunnerCoreModule() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ck-pyparity-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let notebook = Self.notebooks[0]
        try notebookData(notebook).write(to: dir.appendingPathComponent("analysis.ipynb"))

        try extractNotebooksToCode(in: dir, forcedLanguage: .python)
        let written = try String(contentsOf: dir.appendingPathComponent("analysis.py"), encoding: .utf8)

        let expected = extractPython(
            cells: notebook.cells.map { NotebookCell(cellType: $0.type, source: $0.source) },
            filename: "analysis.ipynb"
        ).executableModule
        #expect(written == expected)
        #expect(written.contains("# --- cell 1 ---"))
    }
}
