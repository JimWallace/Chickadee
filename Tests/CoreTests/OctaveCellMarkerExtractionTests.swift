// Tests/CoreTests/OctaveCellMarkerExtractionTests.swift
//
// `extractOctave` and its cell-boundary marker — the Octave sibling of
// LuaCellMarkerExtractionTests. The end-to-end half (the extractor's output
// read back by `chickadee.student_cells()` under a real octave-cli) lives in
// OctaveNativeGradingTests; this pins the RunnerCore shape directly.

import Testing

@testable import RunnerCore

@Suite struct OctaveCellMarkerExtractionTests {

    private func cell(_ source: String, type: String = "code") -> NotebookCell {
        NotebookCell(cellType: type, source: source)
    }

    @Test func codeCellsAreEmittedVerbatimBehindAMarker() {
        let out = extractOctave(
            cells: [cell("x = 1;"), cell("disp(x)")], filename: "lab.ipynb")
        #expect(
            out.source == """
                % Generated from lab.ipynb

                % ---- chickadee:cell 1 ----
                x = 1;

                % ---- chickadee:cell 2 ----
                disp(x)


                """)
        #expect(out.codeCellCount == 2)
    }

    @Test func markerNumbersAreTheOriginalCellPositions() {
        let out = extractOctave(
            cells: [cell("a = 1;"), cell("notes", type: "markdown"), cell("b = 2;")],
            filename: "lab.ipynb")
        #expect(out.source.contains("% ---- chickadee:cell 1 ----"))
        #expect(out.source.contains("% ---- chickadee:cell 3 ----"))
        #expect(!out.source.contains("chickadee:cell 2"))
        #expect(out.codeCellCount == 2)
    }

    @Test func theMarkerIsAnInertOctaveComment() {
        // The flattened file is EXECUTED as the submission (behind the
        // grading runtime's `1;` script guard), so a marker that is not a
        // comment in this language would be a syntax error for every student.
        // `%` is Octave's line comment.
        let marker = octaveCellBoundaryMarker(cellNumber: 7)
        #expect(marker == "% ---- chickadee:cell 7 ----")
        #expect(marker.hasPrefix("%"))
    }

    @Test func aNotebookWithNoCodeCellsIsHeaderOnly() {
        let out = extractOctave(cells: [cell("prose", type: "markdown")], filename: "lab.ipynb")
        #expect(out.source == "% Generated from lab.ipynb\n\n")
        #expect(out.codeCellCount == 0)
    }

    @Test func theThreeMarkerExtractorsShareOneImplementation() {
        // R, Lua and Octave all route through `extractWithCellMarkers`; this is
        // what would catch a future edit that forked one of them.
        let cells = [cell("x = 1"), cell("y = 2")]
        let octaveSource = extractOctave(cells: cells, filename: "lab.ipynb").source
        let rSource = extractR(cells: cells, filename: "lab.ipynb").source

        func stripped(_ source: String, comment: String) -> String {
            source.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    line.hasPrefix(comment + " ")
                        ? String(line.dropFirst(comment.count)) : String(line)
                }
                .joined(separator: "\n")
        }
        #expect(stripped(octaveSource, comment: "%") == stripped(rSource, comment: "#"))
    }
}
