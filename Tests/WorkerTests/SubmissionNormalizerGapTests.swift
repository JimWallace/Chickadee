// Tests/WorkerTests/SubmissionNormalizerGapTests.swift
//
// Closes mutation survivors in `Sources/Worker/SubmissionNormalizer.swift`
// carried by every sweep since Sources/Worker joined the scope (2026-08-26).
// Each test names the survivor it answers, so a later reader can tell what the
// assertion is load-bearing for -- these are not general-purpose tests of the
// normalizer, they pin the specific decisions the suite could not previously
// see change.
//
// Kept apart from SubmissionNormalizerTests so the existing suite stays as it
// was; the fixture is duplicated deliberately rather than shared, because a
// shared fixture edited for one file's survivors silently changes what the
// other file proves.
//
// Protocol: docs/mutation-triage.md. Every survivor below was confirmed
// SURVIVED by Tools/mutation/verify-survivor.py before the test was written,
// and KILLED by this suite afterwards.

import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(3))) final class SubmissionNormalizerGapTests {
    private var rootDir: URL!
    private var submissionDir: URL!
    private var workspaceDir: URL!

    init() throws {
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("submission-normalizer-gap-\(UUID().uuidString)", isDirectory: true)
        submissionDir = rootDir.appendingPathComponent("submission", isDirectory: true)
        workspaceDir = rootDir.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: submissionDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootDir)
    }

    private func makeManifest(requiredFiles: [String] = []) throws -> TestProperties {
        let jsonObject: [String: Any] = [
            "schemaVersion": 1,
            "gradingMode": "worker",
            "requiredFiles": requiredFiles,
            "testSuites": [["tier": "public", "script": "test_public.py"]],
            "timeLimitSeconds": 10,
            "makefile": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        return try JSONDecoder().decode(TestProperties.self, from: data)
    }

    @discardableResult
    private func writeSubmissionFile(name: String, contents: String) throws -> URL {
        let fileURL = submissionDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func writeBinarySubmissionFile(name: String) throws {
        // PNG magic, so the MIME detector classifies it as a binary image and
        // `classify` returns `.unsupported`.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x00, count: 64))
        try png.write(to: submissionDir.appendingPathComponent(name))
    }

    private func normalize(
        manifest: TestProperties, submissionFilename: String?
    ) async throws
        -> NormalizationResult
    {
        try await SubmissionNormalizer().normalizePythonSubmission(
            manifest: manifest,
            submissionDirectory: submissionDir,
            workspaceDirectory: workspaceDir,
            submissionFilename: submissionFilename
        )
    }

    /// Survivor: `SubmissionNormalizer.swift:86 RemoveSideEffects` — deleting
    /// `progress.warnings.append(protectedFileSkippedWarning(...))`.
    ///
    /// The file is refused either way, so nothing about the workspace changes;
    /// what the mutant removes is the student's only explanation for why a file
    /// they submitted is not there (#1357). Skipping silently is the exact
    /// outcome `protectedFileSkippedWarning` exists to prevent, so the warning
    /// is the behaviour under test, not the refusal.
    @Test func aProtectedFileIsRefusedWithAWarningThatNamesIt() async throws {
        try writeSubmissionFile(name: "test_public.py", contents: "print('not mine to write')\n")
        try writeSubmissionFile(name: "solution.py", contents: "print('hello')\n")

        let result = try await normalize(manifest: makeManifest(), submissionFilename: "solution.py")

        #expect(
            result.warnings.contains { $0.contains("test_public.py") },
            "a refused protected file must be reported by name; got \(result.warnings)")
    }

    /// Survivors: `:292 RelationalOperatorReplacement` (`unsupportedOnlyFilename
    /// == nil` → `!= nil`) and `:311 RelationalOperatorReplacement`
    /// (`submissionFiles.count == 1` → `!= 1`).
    ///
    /// Both decide the same student-visible outcome: a submission that is one
    /// unsupported file is rejected as *that file being wrong*, naming it,
    /// rather than as the generic "no sources found". Either mutant downgrades
    /// the specific error to the generic one, so asserting the error's
    /// associated filename pins both.
    @Test func aLoneUnsupportedFileIsRejectedByNameNotAsNoSources() async throws {
        try writeBinarySubmissionFile(name: "diagram.png")

        // Matched structurally rather than with `#expect(throws:)`: the error
        // type is not Equatable, and the associated filename is the whole
        // point of the assertion.
        var thrown: (any Error)?
        await #expect(throws: (any Error).self) {
            do { _ = try await normalize(manifest: makeManifest(), submissionFilename: "diagram.png") } catch {
                thrown = error; throw error
            }
        }
        guard
            case .invalidSubmission(let filename, let language)? =
                thrown as? SubmissionNormalizationError
        else {
            Issue.record("expected invalidSubmission, got \(String(describing: thrown))")
            return
        }
        #expect(filename == "diagram.png")
        #expect(language == .python)
    }

    /// Survivor: `:357 RelationalOperatorReplacement` — `progress
    /// .preferredStudentModule == nil` → `!= nil` in the compatibility-copy
    /// path.
    ///
    /// When a student's single source has the wrong name, Chickadee copies it
    /// to the expected filename. The preferred student module must stay the
    /// file the student actually wrote: the mutant repoints it at the
    /// compatibility copy, which is the name the student did NOT use.
    @Test func aCompatibilityCopyDoesNotRepointThePreferredStudentModule() async throws {
        try writeSubmissionFile(name: "solution.py", contents: "def area(r):\n    return r\n")

        let result = try await normalize(
            manifest: makeManifest(requiredFiles: ["warmup.py"]),
            submissionFilename: "solution.py"
        )

        #expect(
            result.preferredStudentModule == "solution.py",
            "the preferred module must remain the student's own file, not the compatibility copy")
        #expect(FileManager.default.fileExists(atPath: workspaceDir.appendingPathComponent("warmup.py").path))
    }

    /// Survivor: `:414 RelationalOperatorReplacement` — the `<` that orders
    /// `regularFiles(in:)` → `>`.
    ///
    /// File order is not cosmetic here: the first root-level Python file
    /// processed becomes `preferredStudentModule`, which is what notebook
    /// checks introspect. Reversing the sort silently changes which of a
    /// student's files is treated as their submission.
    @Test func theFirstRootLevelSourceInSortedOrderBecomesThePreferredModule() async throws {
        try writeSubmissionFile(name: "aaa_first.py", contents: "def f():\n    return 1\n")
        try writeSubmissionFile(name: "zzz_last.py", contents: "def g():\n    return 2\n")

        let result = try await normalize(manifest: makeManifest(), submissionFilename: nil)

        #expect(
            result.preferredStudentModule == "aaa_first.py",
            "files must be walked in ascending path order; got \(result.preferredStudentModule ?? "nil")")
    }
}
