// Tests/CoreTests/LuaCellMarkerExtractionTests.swift
//
// `extractLua` and its cell-boundary marker. The R pair is pinned end-to-end by
// Tests/WorkerTests/NotebookExtractorRCellMarkerTests (which drives the worker);
// this covers the RunnerCore half directly, because `extractLua` has no worker
// call site yet — `AssignmentLanguage` has no `.lua` case, so nothing routes a
// notebook to it (docs/adding-a-xeus-kernel.md, "The second half").
//
// It is tested now rather than later for the reason that section gives: this is
// the piece of the second half that can be proven in isolation, and shipping it
// untested would make it exactly the kind of groundwork that rots.

import Testing

@testable import RunnerCore

@Suite struct LuaCellMarkerExtractionTests {

    private func cell(_ source: String, type: String = "code") -> NotebookCell {
        NotebookCell(cellType: type, source: source)
    }

    @Test func codeCellsAreEmittedVerbatimBehindAMarker() {
        let out = extractLua(
            cells: [cell("local x = 1"), cell("print(x)")], filename: "lab.ipynb")
        #expect(
            out.source == """
                -- Generated from lab.ipynb

                -- ---- chickadee:cell 1 ----
                local x = 1

                -- ---- chickadee:cell 2 ----
                print(x)


                """)
        #expect(out.codeCellCount == 2)
    }

    @Test func markerNumbersAreTheOriginalCellPositions() {
        // A markdown cell between two code cells shows as a GAP rather than
        // silently renumbering, so a check that names "cell 3" still means the
        // third cell of the notebook the student saw.
        let out = extractLua(
            cells: [cell("a = 1"), cell("notes", type: "markdown"), cell("b = 2")],
            filename: "lab.ipynb")
        #expect(out.source.contains("-- ---- chickadee:cell 1 ----"))
        #expect(out.source.contains("-- ---- chickadee:cell 3 ----"))
        #expect(!out.source.contains("chickadee:cell 2"))
        #expect(out.codeCellCount == 2)
    }

    @Test func emptyAndWhitespaceOnlyCellsAreSkipped() {
        let out = extractLua(
            cells: [cell(""), cell("   \n\t"), cell("print(1)")], filename: "lab.ipynb")
        #expect(out.codeCellCount == 1)
        #expect(out.source.contains("-- ---- chickadee:cell 3 ----"))
    }

    @Test func aNotebookWithNoCodeCellsIsHeaderOnly() {
        let out = extractLua(cells: [cell("prose", type: "markdown")], filename: "lab.ipynb")
        #expect(out.source == "-- Generated from lab.ipynb\n\n")
        #expect(out.codeCellCount == 0)
    }

    @Test func theMarkerIsAnInertLuaComment() {
        // The flattened file is EXECUTED as the submission, so a marker that is
        // not a comment in this language would be a syntax error for every
        // student. `--` is Lua's line comment; `#` (R's) is not.
        let marker = luaCellBoundaryMarker(cellNumber: 7)
        #expect(marker == "-- ---- chickadee:cell 7 ----")
        #expect(marker.hasPrefix("--"))
    }

    @Test func theWriterAndTheRuntimePatternAgree() {
        // The runtime's copy is a Lua pattern, not a regex, and lives in a
        // byte-for-byte mirror (Tools/runner-support/test_runtime.lua) that
        // cannot interpolate this constant — which is why the two need pinning.
        // Lua patterns escape `-` as `%-` and spell a digit run `%d+`.
        #expect(luaCellBoundaryMarkerPattern == "^%-%- ---- chickadee:cell %d+ ----$")
        // Sanity: the pattern's literal prefix is what the writer emits.
        #expect(luaCellBoundaryMarker(cellNumber: 1).hasPrefix("-- ---- chickadee:cell "))
    }

    @Test func rAndLuaShareOneImplementationAndDifferOnlyInTheMarker() {
        // They route through `extractWithCellMarkers`; this is what would catch
        // a future edit that forked them.
        let cells = [cell("x = 1"), cell("y = 2")]
        let luaSource = extractLua(cells: cells, filename: "lab.ipynb").source
        let rSource = extractR(cells: cells, filename: "lab.ipynb").source

        // Strip the comment token from the FRONT of each comment line only. A
        // blind replace would also hit the `----` inside the marker text, which
        // is how the first version of this test failed.
        func stripped(_ source: String, comment: String) -> String {
            source.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    line.hasPrefix(comment + " ") ? String(line.dropFirst(comment.count)) : String(line)
                }
                .joined(separator: "\n")
        }
        #expect(stripped(luaSource, comment: "--") == stripped(rSource, comment: "#"))
    }
}
