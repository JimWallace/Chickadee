// Tests/APITests/PatternFamilies/NotebookCheckUploadOnlyRendererTests.swift
//
// The backstop arms of `renderNotebookCheck` for the three upload-only
// languages (C++, Racket, Java). Authoring refuses every notebook-check kind
// for them, so these arms are unreachable through the editor. They must still
// produce a script that ERRORS (exit 2) under the runner's contract, in the
// file type the runner hands to the right interpreter, and never one that
// could grade a submission as passed.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(1))) struct NotebookCheckUploadOnlyRendererTests {

    private static func check(id: String = "chk", name: String? = nil, tier: TestTier = .pub) -> NotebookCheck {
        NotebookCheck(id: id, name: name, kind: .variableExists, tier: tier, points: 3, variable: "total")
    }

    /// Runs a rendered shell script in an empty directory.
    private static func runShell(_ source: String) async throws -> ToolRun {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-nbcheck-uploadonly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try source.write(to: dir.appendingPathComponent("check.sh"), atomically: true, encoding: .utf8)
        return try await runTool(["/bin/sh", "check.sh"], workingDirectory: dir)
    }

    @Test(arguments: [AssignmentLanguage.cpp, .java])
    func shellBackstopErrorsWithANamedReason(language: AssignmentLanguage) async throws {
        let generated = renderNotebookCheck(Self.check(), language: language)
        let source = generated.script.source

        #expect(source.hasPrefix("#!/bin/sh"))
        #expect(generated.script.filename == "publiccheck_chk.sh")

        let run = try await Self.runShell(source)
        #expect(run.exitCode == 2, "the backstop must error, not pass or fail")
        #expect(run.stdout.isEmpty, "a non-empty last line would become the result text")
        let languageName = language == .cpp ? "C++" : "Java"
        #expect(run.stderr.contains("Notebook checks are not available for \(languageName) assignments."))
    }

    @Test func racketBackstopIsARacketModuleThatExitsTwo() {
        let generated = renderNotebookCheck(Self.check(), language: .racket)
        let source = generated.script.source

        // The runner hands a `.rkt` file to `racket`, so the backstop must be
        // a module, not a shell script.
        #expect(generated.script.filename == "publiccheck_chk.rkt")
        #expect(source.hasPrefix("#lang racket/base"))
        #expect(!source.contains("#!/bin/sh"))
        #expect(source.contains("(exit 2)"))
        #expect(source.contains(#"(eprintf "Notebook checks are not available for Racket assignments.\n")"#))
    }

    @Test(arguments: [AssignmentLanguage.cpp, .racket, .java])
    func backstopKeepsTheCheckMetadata(language: AssignmentLanguage) {
        let check = NotebookCheck(
            id: "late", name: "Total exists", kind: .variableExists, tier: .secret, points: 4,
            timeLimitSeconds: 7, variable: "total")
        let generated = renderNotebookCheck(check, language: language)

        #expect(generated.script.tier == .secret)
        #expect(generated.script.points == 4)
        #expect(generated.script.displayName == "Total exists")
        #expect(generated.script.timeLimitSeconds == 7)
        #expect(generated.script.filename.hasPrefix("secretcheck_late."))
        #expect(generated.sidecars.isEmpty)
    }

    @Test func backstopFallsBackToTheKindLabelWithoutAName() {
        let check = Self.check(name: nil)
        let generated = renderNotebookCheck(check, language: .java)
        let expected = notebookCheckKindHandler(for: check.kind).defaultLabel(check)

        #expect(generated.script.displayName == expected)
        #expect(!expected.isEmpty)
    }
}
