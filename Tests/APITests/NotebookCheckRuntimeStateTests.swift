// Tests/APITests/NotebookCheckRuntimeStateTests.swift
//
// End-to-end coverage for runtime-state notebook checks against the notebook
// extractor's import quarantine (#371).  A data-analysis notebook builds its
// state with function calls (`df = pd.read_csv(...)`, `plt.figure()`), which
// the extractor quarantines into `if __name__ == "__main__":` — so a check
// that merely imports the student module can never see that state.  The
// runtime-state check renderers therefore read
// `test_runtime.student_main_state()` (the notebook AS EXECUTED).  These
// tests run the real pipeline: RunnerCore.extractPython → rendered check
// script → python3 with the canonical Tools/runner-support/test_runtime.py.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(3))) struct NotebookCheckRuntimeStateTests {

    static let requiresPython3: ConditionTrait = .enabled("requires python3 on PATH") { Self.python3Available }
    static let requiresPandas: ConditionTrait = .enabled("requires python3 with pandas") {
        guard Self.python3Available else { return false }
        return await Self.pythonModuleAvailable("pandas")
    }
    static let requiresMatplotlib: ConditionTrait = .enabled("requires python3 with matplotlib") {
        guard Self.python3Available else { return false }
        return await Self.pythonModuleAvailable("matplotlib")
    }

    // MARK: - Harness

    private static let python3Available = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
        .contains { FileManager.default.fileExists(atPath: $0) }

    /// Mirrors the worker's `pythonBootstrap` (ScriptInvocation.swift) closely
    /// enough for these tests: bind the test_runtime builtins, load the
    /// student module, then run the check script as __main__.
    private static let bootstrap = """
        import builtins
        import runpy
        import sys

        import test_runtime as _tr

        builtins.passed = _tr.passed
        builtins.failed = _tr.failed
        builtins.errored = _tr.errored
        builtins.require_function = _tr.require_function
        builtins.student_module = _tr.load_student_module()

        sys.argv = sys.argv[1:]
        runpy.run_path(sys.argv[0], run_name="__main__")
        """

    private struct RunResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var lastStdoutLine: String {
            stdout.split(separator: "\n").last.map(String.init) ?? ""
        }
    }

    /// Repo root derived from this file's location.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // APITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    /// Builds a grading workspace from notebook cells + a rendered check, runs
    /// the check under python3, and returns the outcome.  Extra support files
    /// (e.g. a CSV) are written verbatim.
    private func runCheck(
        cells: [NotebookCell],
        check: NotebookCheck,
        supportFiles: [(name: String, content: String)] = []
    ) async throws -> RunResult {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("chickadee-runtime-check-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let runtime = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Tools/runner-support/test_runtime.py"),
            encoding: .utf8)
        try runtime.write(
            to: workDir.appendingPathComponent("test_runtime.py"), atomically: true, encoding: .utf8)

        let extracted = extractPython(cells: cells, filename: "solution.ipynb")
        try extracted.executableModule.write(
            to: workDir.appendingPathComponent("solution.py"), atomically: true, encoding: .utf8)
        try "solution.py".write(
            to: workDir.appendingPathComponent(".chickadee_student_module"),
            atomically: true, encoding: .utf8)

        for file in supportFiles {
            try file.content.write(
                to: workDir.appendingPathComponent(file.name), atomically: true, encoding: .utf8)
        }

        let bundle = renderNotebookCheck(check, language: .python)
        let scriptName = "publiccheck_\(check.id).py"
        try bundle.script.source.write(
            to: workDir.appendingPathComponent(scriptName), atomically: true, encoding: .utf8)
        for (filename, content) in bundle.sidecars {
            try content.write(
                to: workDir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }

        let run = try await runTool(
            ["python3", "-c", Self.bootstrap, scriptName], workingDirectory: workDir)
        return RunResult(
            exitCode: run.exitCode,
            stdout: run.stdout,
            stderr: run.stderr)
    }

    private static func pythonModuleAvailable(_ module: String) async -> Bool {
        return await toolIsAvailable("python3", arguments: ["-c", "import \(module)"])
    }

    // MARK: - variable_exists sees quarantined assignments

    @Test(Self.requiresPython3) func variableExists_seesCallProducedVariable() async throws {
        // `answer = compute()` has a call on the RHS, so the extractor
        // quarantines it — an import-only check would report "not defined".
        let cells = [
            NotebookCell(
                cellType: "code",
                source: "def compute():\n    return 41 + 1\n\nanswer = compute()")
        ]
        let check = NotebookCheck(id: "answer_defined", kind: .variableExists, variable: "answer")

        let result = try await runCheck(cells: cells, check: check)
        #expect(result.exitCode == 0, "check should pass; stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(result.lastStdoutLine.contains("\"status\": \"pass\""))
    }

    @Test(Self.requiresPython3) func variableExists_missingVariableStillFails() async throws {
        let cells = [
            NotebookCell(cellType: "code", source: "def compute():\n    return 1")
        ]
        let check = NotebookCheck(id: "answer_defined", kind: .variableExists, variable: "answer")

        let result = try await runCheck(cells: cells, check: check)
        #expect(result.exitCode == 1, "missing variable must still fail; stdout: \(result.stdout)")
        #expect(result.stdout.contains("is not defined in the student notebook"))
    }

    @Test(Self.requiresPython3) func variableExists_brokenLaterCellDoesNotHideEarlierState() async throws {
        // The second cell raises at execution; the per-cell resilient
        // wrappers must keep the first cell's state visible.
        let cells = [
            NotebookCell(cellType: "code", source: "answer = int(\"42\")"),
            NotebookCell(cellType: "code", source: "print(undefined_name)"),
        ]
        let check = NotebookCheck(id: "answer_defined", kind: .variableExists, variable: "answer")

        let result = try await runCheck(cells: cells, check: check)
        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
    }

    // MARK: - data_frame_columns sees a loaded DataFrame (needs pandas)

    @Test(Self.requiresPandas) func dataFrameColumns_seesLoadedCSV() async throws {
        let cells = [
            NotebookCell(cellType: "code", source: "import pandas as pd"),
            NotebookCell(cellType: "code", source: "df = pd.read_csv(\"cases.csv\")"),
        ]
        let check = NotebookCheck(
            id: "df_cols", kind: .dataFrameColumns,
            variable: "df", expectedColumns: ["age", "weight"], columnMatch: .superset)

        let result = try await runCheck(
            cells: cells, check: check,
            supportFiles: [("cases.csv", "age,weight,dept\n61,70.2,a\n45,55.6,b\n")])
        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(result.lastStdoutLine.contains("\"status\": \"pass\""))
    }

    // MARK: - figure_count sees quarantined plotting calls (needs matplotlib)

    @Test(Self.requiresMatplotlib) func figureCount_seesPlottedFigures() async throws {
        let cells = [
            NotebookCell(
                cellType: "code",
                source: "import matplotlib\nmatplotlib.use(\"Agg\")\nimport matplotlib.pyplot as plt"),
            NotebookCell(cellType: "code", source: "plt.figure()\nplt.plot([1, 2, 3])\nplt.show()"),
            NotebookCell(cellType: "code", source: "plt.figure()\nplt.plot([3, 2, 1])\nplt.show()"),
        ]
        let check = NotebookCheck(id: "two_figs", kind: .figureCount, minFigures: 2)

        let result = try await runCheck(cells: cells, check: check)
        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(result.lastStdoutLine.contains("\"status\": \"pass\""))
    }

    @Test(Self.requiresMatplotlib) func figureCount_countsPerShowFlush_withoutExplicitFigures() async throws {
        // Notebook-style plotting with NO plt.figure() calls: in Jupyter each
        // plt.show() renders its own chart, but under batch Agg execution both
        // plots would overlay one figure. The check's show-flush emulation must
        // count 2, not 1.
        let cells = [
            NotebookCell(
                cellType: "code",
                source: "import matplotlib\nmatplotlib.use(\"Agg\")\nimport matplotlib.pyplot as plt"),
            NotebookCell(cellType: "code", source: "plt.plot([1, 2, 3])\nplt.show()"),
            NotebookCell(cellType: "code", source: "plt.plot([3, 2, 1])\nplt.show()"),
        ]
        let check = NotebookCheck(id: "two_figs_flush", kind: .figureCount, minFigures: 2)

        let result = try await runCheck(cells: cells, check: check)
        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(result.lastStdoutLine.contains("\"status\": \"pass\""))
    }
}
