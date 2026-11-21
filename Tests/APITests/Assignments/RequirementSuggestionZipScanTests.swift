// Tests/APITests/Assignments/RequirementSuggestionZipScanTests.swift
//
// `detectRequirementSuggestions` suggests the runner requirements for a new
// assignment. It reads the starter notebook and the entries of the test setup
// zip. The zip half had no test: an entry in an assignment language adds that
// language, a Python entry's imports add capabilities, and a shell, Swift or
// JavaScript entry adds what its extension names. The suggestion is what an
// instructor accepts, so a missing language lets the assignment go to a runner
// with no interpreter for it.
//
// A time limit, because the scan runs `unzip` subprocesses. `.serialized` as
// in `SetupZipRewriteTests`: zip subprocesses race under within-suite
// parallelism.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) struct RequirementSuggestionZipScanTests {

    private func suggestions(
        zipEntries: [(String, String)], notebook: String? = nil
    ) async throws -> DraftRequirementSuggestions {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("requirement-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zipPath = root.appendingPathComponent("setup.zip").path
        try await writeZipFixture(at: zipPath, entries: zipEntries)
        let setup = APITestSetup(id: "setup_scan", manifest: "{}", zipPath: zipPath, courseID: UUID())
        return await detectRequirementSuggestions(
            assignmentNotebookData: notebook.map { Data($0.utf8) }, solutionNotebookData: nil, setup: setup)
    }

    @Test func aPythonEntryAddsPythonAndTheCapabilitiesItImports() async throws {
        let result = try await suggestions(zipEntries: [
            (
                "publictest_stats.py",
                "import numpy as np\nfrom pandas.api import types\nimport os\nimport scipy.stats\n"
            )
        ])
        #expect(result.languages == ["python"])
        // `os` is not on the allowlist, so it adds nothing.
        #expect(result.capabilities == ["numpy", "pandas", "scipy"])
    }

    @Test func entriesInOtherLanguagesAddTheirLanguageButAreNotScannedForImports() async throws {
        let result = try await suggestions(zipEntries: [
            ("publictest_a.R", "import numpy\n"),
            ("publictest_b.lua", "import pandas\n"),
        ])
        #expect(result.languages == ["lua", "r"])
        #expect(result.capabilities.isEmpty)
    }

    @Test func shellSwiftAndJavaScriptEntriesAddWhatTheirExtensionNames() async throws {
        let result = try await suggestions(zipEntries: [
            ("run.sh", "exit 0\n"),
            ("run_z.zsh", "exit 0\n"),
            ("Helper.swift", "let x = 1\n"),
            ("helper.js", "let x = 1;\n"),
        ])
        #expect(result.languages == ["javascript", "swift"])
        #expect(result.capabilities == ["shell-bash", "shell-zsh"])
    }

    @Test func entriesWithNoRequirementAddNothing() async throws {
        let result = try await suggestions(zipEntries: [
            ("data.csv", "a,b\n1,2\n"),
            ("README.txt", "import numpy\n"),
        ])
        #expect(result.languages.isEmpty)
        #expect(result.capabilities.isEmpty)
    }

    @Test func theNotebookAndTheZipAreMerged() async throws {
        let notebook = """
            {"metadata":{"kernelspec":{"name":"xpython","language":"python"}},
             "nbformat":4,"nbformat_minor":5,
             "cells":[{"cell_type":"code","source":"import matplotlib.pyplot as plt","metadata":{},"outputs":[]}]}
            """
        let result = try await suggestions(
            zipEntries: [("publictest_a.py", "import numpy\n"), ("run.sh", "exit 0\n")], notebook: notebook)
        #expect(result.languages == ["python"])
        #expect(result.capabilities == ["matplotlib", "numpy", "shell-bash"])
    }
}
