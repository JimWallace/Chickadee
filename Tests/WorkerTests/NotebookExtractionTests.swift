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
