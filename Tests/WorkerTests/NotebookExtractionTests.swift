import Foundation
import Testing

@testable import RunnerCore

// Direct tests for RunnerCore's notebook extraction (the shared, dependency-free
// transform). The native worker (NotebookExtractor) and, in a follow-up, the
// browser runner both call this, so its behaviour is the single source of truth.
// The existing NotebookExtractorTests additionally exercise this logic through
// the worker's thin delegations, guarding against any drift in the port.
@Suite struct NotebookExtractionTests {

    private func code(_ src: String) -> NotebookCell { NotebookCell(cellType: "code", source: src) }

    @Test func executableModuleByteFormat() {
        let result = extractPython(cells: [code("x = 1")], filename: "t.ipynb")
        #expect(result.codeCellCount == 1)
        #expect(
            result.executableModule == """
                # Generated from t.ipynb

                # --- cell 1 ---
                try:
                    exec(compile("x = 1", "cell 1", "exec"), globals())
                except Exception:
                    pass

                """)
    }

    @Test func introspectableSourceIsRealUnwrappedCode() {
        let result = extractPython(
            cells: [code("x = 1")],
            filename: "t.ipynb"
        )
        #expect(
            result.introspectableSource == """
                # Generated from t.ipynb

                # --- cell 1 ---
                x = 1

                """)
        // The whole point: NOT exec-wrapped, so inspect.getsource + ast.parse work.
        #expect(!result.introspectableSource.contains("exec(compile("))
    }

    // The HLTH-230 structural-check scenario: a defined function must appear as a
    // real module-level `def` in the introspectable source (so ast.parse finds
    // it), while the executable module keeps the resilient exec-wrap.
    @Test func definedFunctionIsASTVisibleInIntrospectableSource() {
        let cell = code("def tax(income: float) -> float:\n    \"\"\"doc\"\"\"\n    return income * 0.1")
        let result = extractPython(cells: [cell], filename: "sol.ipynb")

        // Introspectable view: real def at module level, no exec wrapper.
        #expect(result.introspectableSource.contains("\ndef tax(income: float) -> float:"))
        #expect(!result.introspectableSource.contains("exec(compile("))

        // Executable view: resilient exec-wrap that defines the function at runtime.
        #expect(result.executableModule.contains("exec(compile("))
        #expect(result.executableModule.contains("def tax(income: float) -> float:"))
    }

    // Module-level asserts are quarantined into `if __name__` but stay visible in
    // the introspectable source, so the structural check's min_module_asserts
    // count (which walks __main__) can see them.
    @Test func moduleAssertsSurviveInIntrospectableSource() {
        let cell = code("def f():\n    return 1\n\nassert f() == 1\nassert True\nassert 2 > 1")
        let result = extractPython(cells: [cell], filename: "a.ipynb")
        #expect(result.introspectableSource.contains("if __name__ == \"__main__\":"))
        let assertCount =
            result.introspectableSource
            .components(separatedBy: "assert ").count - 1
        #expect(assertCount == 3)
    }

    @Test func nonCodeCellsAreSkippedButKeepCellNumbering() {
        let cells = [
            NotebookCell(cellType: "markdown", source: "# Title"),
            code("y = 2"),
        ]
        let result = extractPython(cells: cells, filename: "n.ipynb")
        #expect(result.codeCellCount == 1)
        // The code cell is cell index 2 (1-based) — numbering follows the notebook.
        #expect(result.executableModule.contains("# --- cell 2 ---"))
        #expect(result.executableModule.contains("\"cell 2\""))
    }

    @Test func emptyOrMagicOnlyNotebookYieldsNoCodeCells() {
        let result = extractPython(cells: [code("%matplotlib inline\n!pip install foo")], filename: "m.ipynb")
        #expect(result.codeCellCount == 0)
        #expect(result.executableModule.isEmpty)
        #expect(result.introspectableSource.isEmpty)
    }

    @Test func forwardSlashIsNotEscaped() {
        let result = extractPython(cells: [code("daily_l = daily_ml / 1000")], filename: "d.ipynb")
        #expect(result.executableModule.contains("daily_ml / 1000"))
        #expect(!result.executableModule.contains("\\/"))
    }

    // Regression (HLTH-230 Lab 1): a cell that parks a multi-line triple-quoted
    // block (prose / an alternate solution) at module level above the real code.
    // Before triple-quote tracking, the interior prose lines were re-classified
    // as new top-level statements and ripped into `if __name__`, splitting the
    // string and producing invalid Python — which the resilient-load wrapper then
    // silently dropped, wiping out the cell's real definitions and variables.
    @Test func tripleQuotedBlockDoesNotSwallowFollowingDefinitions() {
        let cell = code(
            """
            \"\"\"
            This is a different way I got this to work
            beats = beatsCalculated(72, 24*60)
            print(beats)
            \"\"\"

            heartRate = 72
            beats = heartRate * 60 * 24
            print(beats)
            """
        )
        let sanitized = sanitizeCellForModule(cell.source)

        // The real module-level assignment survives at module level (NOT pushed
        // into the __main__ quarantine), so `beats` is importable on the module.
        let moduleLevel = sanitized.components(separatedBy: "if __name__").first ?? sanitized
        #expect(moduleLevel.contains("beats = heartRate * 60 * 24"))

        // The interior prose line never leaks out of the string as bare code.
        let quarantine =
            sanitized.range(of: "if __name__").map { String(sanitized[$0.lowerBound...]) } ?? ""
        #expect(!quarantine.contains("This is a different way I got this to work"))
    }

    // A bare `'''…'''` block with a `def` inside it must stay intact and the
    // function defined after it must remain at module level.
    @Test func singleQuoteTripleBlockKeepsLaterDefAtModuleLevel() {
        let cell = code(
            """
            '''
            def shadow(price):
                return price
            shadow(100)
            '''
            def tax(price):
                return round(price * 1.13, 2)
            """
        )
        let sanitized = sanitizeCellForModule(cell.source)
        let moduleLevel = sanitized.components(separatedBy: "if __name__").first ?? sanitized
        #expect(moduleLevel.contains("def tax(price):"))
    }
}

// Direct tests for RunnerCore's R extraction (hoisted from the worker's inline
// loop in PR #1235 so the browser runner shares it via wasm). The byte format
// is load-bearing twice over: the worker's extracted `.R` must not change
// across the hoist (regrades compare against history), and the runtime's
// `chickadee_student_cells()` splits on the marker lines.
@Suite struct RNotebookExtractionTests {

    private func code(_ src: String) -> NotebookCell { NotebookCell(cellType: "code", source: src) }

    @Test func byteFormatIsHeaderThenMarkedCells() {
        let result = extractR(
            cells: [code("a <- 1\n"), code("b <- 2")], filename: "lab.ipynb")
        #expect(result.codeCellCount == 2)
        #expect(
            result.source == """
                # Generated from lab.ipynb

                # ---- chickadee:cell 1 ----
                a <- 1

                # ---- chickadee:cell 2 ----
                b <- 2


                """)
    }

    @Test func markerNumbersFollowNotebookPositionNotCodeCellIndex() {
        let result = extractR(
            cells: [
                code("a <- 1"),
                NotebookCell(cellType: "markdown", source: "## Notes"),
                code("b <- 2"),
            ],
            filename: "lab.ipynb")
        #expect(result.codeCellCount == 2)
        #expect(result.source.contains(rCellBoundaryMarker(cellNumber: 1)))
        #expect(result.source.contains(rCellBoundaryMarker(cellNumber: 3)))
        #expect(!result.source.contains(rCellBoundaryMarker(cellNumber: 2)))
    }

    @Test func trailingWhitespaceTrimmedButLeadingPreserved() {
        let result = extractR(cells: [code("  x <- 1  \n\n")], filename: "t.ipynb")
        #expect(result.source.contains("\n  x <- 1\n"))
        #expect(!result.source.contains("x <- 1  "))
    }

    @Test func whitespaceOnlyAndNonCodeCellsAreSkipped() {
        let result = extractR(
            cells: [
                code("   \n\t\n"),
                NotebookCell(cellType: "markdown", source: "prose"),
                code("y <- 2"),
            ],
            filename: "t.ipynb")
        #expect(result.codeCellCount == 1)
        #expect(!result.source.contains(rCellBoundaryMarker(cellNumber: 1)))
        #expect(result.source.contains(rCellBoundaryMarker(cellNumber: 3)))
    }

    /// A notebook with no code cells still produces the header — matching the
    /// worker's pre-hoist behaviour, which wrote the file unconditionally.
    @Test func noCodeCellsProducesHeaderOnly() {
        let result = extractR(
            cells: [NotebookCell(cellType: "markdown", source: "## Only prose")],
            filename: "empty.ipynb")
        #expect(result.codeCellCount == 0)
        #expect(result.source == "# Generated from empty.ipynb\n\n")
    }

    /// Every emitted marker matches the pattern the grading runtime splits on.
    @Test func emittedMarkersMatchTheRuntimePattern() throws {
        let result = extractR(
            cells: [code("a <- 1"), code("b <- 2"), code("c <- 3")], filename: "t.ipynb")
        let regex = try NSRegularExpression(pattern: rCellBoundaryMarkerPattern, options: [])
        let markerLines = result.source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("# ---- chickadee") }
        #expect(markerLines.count == 3)
        for line in markerLines {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            #expect(regex.firstMatch(in: text, options: [], range: range) != nil)
        }
    }
}
