// Tests/WorkerTests/NotebookExtractorRCellMarkerTests.swift
//
// Pins the two halves of the R cell-boundary contract against each other: the
// marker `extractNotebooksToCode` writes, and the regex the grading runtime's
// `chickadee_student_cells()` splits on. They are spelled out separately —
// `Tools/runner-support/test_runtime.R` is a byte-for-byte mirror, so it cannot
// interpolate the Swift constant — which is exactly why they need a test.

import Foundation
import RunnerCore
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) struct NotebookExtractorRCellMarkerTests {

    private func rNotebook(cells: [String]) -> Data {
        let cellObjects = cells.map { source in
            ["cell_type": "code", "source": source, "metadata": [:] as [String: Any]] as [String: Any]
        }
        let notebook: [String: Any] = [
            "cells": cellObjects,
            "nbformat": 4,
            "nbformat_minor": 5,
            "metadata": ["kernelspec": ["name": "xr", "language": "R"]],
        ]
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: notebook)
    }

    private func extract(cells: [String]) throws -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ck-rcells-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try rNotebook(cells: cells).write(to: dir.appendingPathComponent("analysis.ipynb"))
        try extractNotebooksToCode(in: dir)
        return try String(
            contentsOf: dir.appendingPathComponent("analysis.R"), encoding: .utf8)
    }

    /// The contract: every marker the extractor writes is recognized by the
    /// pattern the runtime splits on. A change to either spelling fails here
    /// rather than silently making every `cell_contains` check see one cell.
    @Test func everyEmittedMarkerMatchesTheRuntimePattern() throws {
        let extracted = try extract(cells: [
            "df <- read.csv(\"cases.csv\")",
            "summary(df)",
            "hist(df$age)",
        ])
        let regex = try NSRegularExpression(pattern: rCellBoundaryMarkerPattern, options: [])
        let markerLines = extracted.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("# ---- chickadee") }
        #expect(markerLines.count == 3)
        for line in markerLines {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            #expect(
                regex.firstMatch(in: text, options: [], range: range) != nil,
                "runtime pattern does not match emitted marker: \(text)")
        }
    }

    /// A marker precedes each cell's body, so splitting on them reproduces the
    /// original cells.
    @Test func markersDelimitTheOriginalCells() throws {
        let extracted = try extract(cells: ["a <- 1", "b <- 2"])
        #expect(extracted.contains("\(rCellBoundaryMarker(cellNumber: 1))\na <- 1"))
        #expect(extracted.contains("\(rCellBoundaryMarker(cellNumber: 2))\nb <- 2"))
    }

    /// Markers are numbered by position in the notebook, so a markdown cell
    /// between two code cells is visible as a gap rather than silently
    /// renumbering the code cells.
    @Test func markerNumbersFollowNotebookPositionNotCodeCellIndex() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ck-rcells-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let notebook: [String: Any] = [
            "cells": [
                ["cell_type": "code", "source": "a <- 1"] as [String: Any],
                ["cell_type": "markdown", "source": "## Notes"] as [String: Any],
                ["cell_type": "code", "source": "b <- 2"] as [String: Any],
            ],
            "nbformat": 4, "nbformat_minor": 5,
            "metadata": ["kernelspec": ["name": "ir"]],
        ]
        try JSONSerialization.data(withJSONObject: notebook)
            .write(to: dir.appendingPathComponent("analysis.ipynb"))
        try extractNotebooksToCode(in: dir)
        let extracted = try String(
            contentsOf: dir.appendingPathComponent("analysis.R"), encoding: .utf8)
        #expect(extracted.contains(rCellBoundaryMarker(cellNumber: 1)))
        #expect(extracted.contains(rCellBoundaryMarker(cellNumber: 3)))
        #expect(!extracted.contains(rCellBoundaryMarker(cellNumber: 2)))
    }

    /// The marker is an ordinary R comment, so the flattened file still runs.
    @Test func markersAreInertRComments() async throws {
        let extracted = try extract(cells: ["total <- 1 + 1"])
        for line in extracted.split(separator: "\n") where line.hasPrefix("# ---- chickadee") {
            #expect(line.hasPrefix("#"))
        }
        guard await rscriptIsAvailable() else { return }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ck-rcells-run-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let script = dir.appendingPathComponent("flattened.R")
        try (extracted + "\nstopifnot(total == 2)\n").write(
            to: script, atomically: true, encoding: .utf8)
        let proc = try await runProcessRobustly {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["Rscript", script.path]
            proc.standardOutput = makeCloexecPipe()
            proc.standardError = makeCloexecPipe()
            return proc
        }
        #expect(proc.terminationStatus == 0, "flattened R with cell markers must still run")
    }

    /// Python's extraction is untouched — it already labels cells through
    /// `wrapCellForResilientLoad`, and its bytes must not move.
    @Test func pythonExtractionDoesNotGainMarkers() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ck-pycells-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let notebook: [String: Any] = [
            "cells": [["cell_type": "code", "source": "x = 1"] as [String: Any]],
            "nbformat": 4, "nbformat_minor": 5,
            "metadata": ["kernelspec": ["name": "python3"]],
        ]
        try JSONSerialization.data(withJSONObject: notebook)
            .write(to: dir.appendingPathComponent("analysis.ipynb"))
        try extractNotebooksToCode(in: dir)
        let extracted = try String(
            contentsOf: dir.appendingPathComponent("analysis.py"), encoding: .utf8)
        #expect(!extracted.contains("chickadee:cell"))
    }

}
