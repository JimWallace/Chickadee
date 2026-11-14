// Tests/APITests/Languages/KernelImportGuardEdgeTests.swift
//
// The `KernelImportGuard` paths that the scanner suites do not reach: the
// languages whose environment reports nothing by design, the bundled-file
// name rule, and both shapes of the rejection message.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct KernelImportGuardEdgeTests {

    // MARK: - language(forFile:)

    @Test func onlyPythonAndRFilesSelectAnInventory() {
        #expect(KernelImportGuard.language(forFile: "publictest_a.py") == .python)
        #expect(KernelImportGuard.language(forFile: "publictest_a.R") == .r)
        #expect(KernelImportGuard.language(forFile: "publictest_a.r") == .r)
        #expect(KernelImportGuard.language(forFile: "publictest_a.lua") == nil)
        #expect(KernelImportGuard.language(forFile: "publictest_a.m") == nil)
        #expect(KernelImportGuard.language(forFile: "publictest_a.sh") == nil)
        #expect(KernelImportGuard.language(forFile: "README") == nil)
    }

    // MARK: - unsatisfied(in:environment:localModules:)

    /// Every language without a scannable inventory reports nothing, whatever
    /// the source says: a false positive blocks an instructor with no fix.
    @Test(arguments: [AssignmentLanguage.lua, .octave, .cpp, .racket, .java])
    func aLanguageWithoutAScannerReportsNothing(_ language: AssignmentLanguage) {
        let environment = KernelEnvironment(language: language, packageModules: [], stdlibModules: [])
        let source = """
            require("missing")
            pkg load missing
            import missing
            library(missing)
            """
        #expect(KernelImportGuard.unsatisfied(in: source, environment: environment, localModules: []).isEmpty)
    }

    @Test func aPythonImportIsReportedWithItsLine() {
        let environment = KernelEnvironment(language: .python, packageModules: ["numpy"], stdlibModules: ["math"])
        let found = KernelImportGuard.unsatisfied(
            in: "import math\nimport numpy\nimport scipy\nimport helper\n",
            environment: environment, localModules: ["helper"])
        #expect(found == [KernelImportGuard.Unsatisfied(name: "scipy", line: 3)])
    }

    // MARK: - localModuleName(forFile:)

    @Test func bundledSourceFilesAreImportableByTheirStem() {
        #expect(KernelImportGuard.localModuleName(forFile: "helpers.py") == "helpers")
        #expect(KernelImportGuard.localModuleName(forFile: "lib/_private.py") == "_private")
        #expect(KernelImportGuard.localModuleName(forFile: "utils.R") == "utils")
        #expect(KernelImportGuard.localModuleName(forFile: "my.pkg.r") == "my.pkg")
    }

    @Test func otherFilesHaveNoModuleName() {
        #expect(KernelImportGuard.localModuleName(forFile: "data.csv") == nil)
        #expect(KernelImportGuard.localModuleName(forFile: "1st.py") == nil)
        #expect(KernelImportGuard.localModuleName(forFile: "bad-name.py") == nil)
        #expect(KernelImportGuard.localModuleName(forFile: ".py") == nil)
    }

    // MARK: - message(for:filename:language:)

    @Test func aKernelLessLanguageGetsTheShortSentence() {
        let message = KernelImportGuard.message(
            for: [KernelImportGuard.Unsatisfied(name: "x", line: 1)], filename: "t.cpp", language: .cpp)
        #expect(message == "t.cpp is in a language with no browser grading environment.")
    }

    @Test func theMessageNamesEachReferenceAndTheEnvironmentFile() throws {
        guard
            case .notebookKernel(let envFile, _, _, let failure, _) = AssignmentLanguage.python.editorSupport
        else {
            throw IssueRecorded("Python has no notebook kernel")
        }
        let message = KernelImportGuard.message(
            for: [
                KernelImportGuard.Unsatisfied(name: "scipy", line: 3),
                KernelImportGuard.Unsatisfied(name: "sklearn", line: 7),
            ],
            filename: "publictest_a.py", language: .python)
        #expect(message.hasPrefix("publictest_a.py needs `scipy`, `sklearn`, which"))
        #expect(message.contains("so they would fail with \(failure)"))
        #expect(message.contains("Found at: scipy (line 3), sklearn (line 7)."))
        #expect(message.contains("Tools/jupyterlite/\(envFile)"))
    }

    @Test func oneReferenceUsesTheSingular() {
        let message = KernelImportGuard.message(
            for: [KernelImportGuard.Unsatisfied(name: "ggplot2", line: 2)], filename: "t.R", language: .r)
        #expect(message.hasPrefix("t.R needs `ggplot2`, which"))
        #expect(message.contains(", so it would fail with "))
    }
}
