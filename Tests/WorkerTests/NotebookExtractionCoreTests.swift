import Testing

@testable import NotebookExtractionCore

// Direct tests for the shared, dependency-free extraction core. The native
// worker (NotebookExtractor) and, in a follow-up, the browser runner both call
// this, so its behaviour is the single source of truth. The existing
// NotebookExtractorTests additionally exercise this logic through the worker's
// thin delegations, guarding against any drift in the port.
@Suite struct NotebookExtractionCoreTests {

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
}
