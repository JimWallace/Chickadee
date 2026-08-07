// Tests/WorkerTests/SubmissionPolicyTests.swift
//
// The submission policy, asserted as policy: every guarantee, for every
// language, either provided or exempted with a reason.
//
// The point is the FAIL-CLOSED shape. A new language cannot compile without
// answering `submissionGuaranteeExemption` for every guarantee, and this suite
// then requires that the answer is either "provided" or a non-empty reason —
// so "unbuilt" cannot masquerade as "not applicable", which is exactly how R
// and Lua ended up with no submission validation at all while Python had 445
// lines of it.

import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite struct SubmissionPolicyTests {

    /// Every (guarantee, language) pair is a decision someone made.
    @Test func everyGuaranteeIsAnsweredForEveryLanguage() {
        for guarantee in SubmissionGuarantee.allCases {
            for language in AssignmentLanguage.allCases {
                if let reason = submissionGuaranteeExemption(guarantee, for: language) {
                    #expect(
                        !reason.trimmingCharacters(in: .whitespaces).isEmpty,
                        """
                        \(language) exempts itself from \(guarantee.rawValue) with an empty reason. \
                        The reason IS the release valve — an exemption with nothing behind it is \
                        indistinguishable from unbuilt work, which is the failure this policy exists \
                        to prevent.
                        """)
                }
            }
        }
    }

    /// The guarantees that are properties of the UPLOAD rather than of the
    /// language admit no exemption. Stated as a test so weakening one is a
    /// deliberate edit here, with this comment in the diff, rather than a quiet
    /// arm added to a switch.
    @Test func theUniversalGuaranteesHaveNoExemptions() {
        let universal: [SubmissionGuarantee] = [
            .validNotebookJSON, .notebookHasCodeCells, .unsupportedFilesWarn,
            .producedSourceOrErrored,
        ]
        for guarantee in universal {
            for language in AssignmentLanguage.allCases {
                #expect(
                    submissionGuaranteeExemption(guarantee, for: language) == nil,
                    """
                    \(language) exempts itself from \(guarantee.rawValue), which is a property of the \
                    student's upload and not of the language: a corrupt notebook is corrupt whatever \
                    kernel wrote it, and silence is not actionable in any language. If this is a real \
                    limitation, say so here — but the default answer is to build it.
                    """)
            }
        }
    }

    /// The one exemption that exists today, pinned so it stays a named decision.
    @Test func onlyTheIntrospectableSidecarIsExempt() {
        var exempted: [String] = []
        for guarantee in SubmissionGuarantee.allCases {
            for language in AssignmentLanguage.allCases
            where submissionGuaranteeExemption(guarantee, for: language) != nil {
                exempted.append("\(language)/\(guarantee.rawValue)")
            }
        }
        #expect(
            exempted.sorted() == ["lua/introspectableSidecar", "r/introspectableSidecar"],
            "the exemption list changed: \(exempted.sorted())")
    }

    // MARK: - The guarantees actually hold

    static func notebookData(cells: [[String: Any]], kernel: String) -> Data {
        let notebook: [String: Any] = [
            "nbformat": 4,
            "metadata": ["kernelspec": ["name": kernel]],
            "cells": cells,
        ]
        return (try? JSONSerialization.data(withJSONObject: notebook)) ?? Data()
    }

    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// THE regression this policy was written for: a student's notebook with no
    /// code cells used to be silently skipped on R and Lua, producing no source
    /// — and the suite then told the student "No R submission file was found to
    /// grade", blaming them for a platform failure.
    @Test(arguments: AssignmentLanguage.allCases)
    func anEmptyStudentNotebookIsAnActionableError(_ language: AssignmentLanguage) throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let markdownOnly = [["cell_type": "markdown", "source": "# notes"]]
        try Self.notebookData(cells: markdownOnly, kernel: "python3")
            .write(to: dir.appendingPathComponent("lab.ipynb"))

        #expect(throws: SubmissionNormalizationError.self) {
            try extractNotebooksToCode(
                in: dir, forcedLanguage: language, studentNotebookName: "lab.ipynb")
        }
    }

    /// A student's notebook that is not valid JSON, likewise.
    @Test(arguments: AssignmentLanguage.allCases)
    func aCorruptStudentNotebookIsAnActionableError(_ language: AssignmentLanguage) throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("{ this is not json".utf8).write(to: dir.appendingPathComponent("lab.ipynb"))

        #expect(throws: SubmissionNormalizationError.self) {
            try extractNotebooksToCode(
                in: dir, forcedLanguage: language, studentNotebookName: "lab.ipynb")
        }
    }

    /// …but an INSTRUCTOR's helper notebook keeps the lenient skip. Failing a
    /// whole job because a bundled reference notebook is markdown-only would be
    /// a regression dressed as a fix.
    @Test(arguments: AssignmentLanguage.allCases)
    func anInstructorHelperNotebookStaysLenient(_ language: AssignmentLanguage) throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("{ not json either".utf8).write(to: dir.appendingPathComponent("reference.ipynb"))
        try Self.notebookData(
            cells: [["cell_type": "code", "source": "x = 1"]], kernel: "python3"
        ).write(to: dir.appendingPathComponent("lab.ipynb"))

        let warnings = try extractNotebooksToCode(
            in: dir, forcedLanguage: language, studentNotebookName: "lab.ipynb")

        // The student's notebook still extracted…
        let produced = dir.appendingPathComponent("lab.\(language.generatedScriptExtension)")
        #expect(FileManager.default.fileExists(atPath: produced.path))
        // …and the unreadable helper produced a warning rather than silence.
        #expect(
            warnings.contains { $0.contains("reference.ipynb") },
            "the unreadable helper was skipped with no warning: \(warnings)")
    }

    /// A well-formed student notebook is unaffected in every language — the
    /// guarantee only bites on genuinely broken input.
    @Test(arguments: AssignmentLanguage.allCases)
    func aGoodStudentNotebookExtractsNormally(_ language: AssignmentLanguage) throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Self.notebookData(
            cells: [["cell_type": "code", "source": "x = 1"]], kernel: "python3"
        ).write(to: dir.appendingPathComponent("lab.ipynb"))

        let warnings = try extractNotebooksToCode(
            in: dir, forcedLanguage: language, studentNotebookName: "lab.ipynb")
        #expect(warnings.isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("lab.\(language.generatedScriptExtension)").path))
    }

    /// Without a named student notebook — every existing caller — behaviour is
    /// exactly as before: lenient, no throwing. This is what keeps the change
    /// scoped to the job path that actually knows whose file it is.
    @Test func withoutAStudentNameNothingThrows() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("{ broken".utf8).write(to: dir.appendingPathComponent("whatever.ipynb"))
        #expect(throws: Never.self) {
            try extractNotebooksToCode(in: dir, forcedLanguage: .r)
        }
    }
}
