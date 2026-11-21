import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(3))) final class SubmissionNormalizerTests {
    private let rootDir: URL
    private let submissionDir: URL
    private let workspaceDir: URL

    init() throws {
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("submission-normalizer-\(UUID().uuidString)", isDirectory: true)
        submissionDir = rootDir.appendingPathComponent("submission", isDirectory: true)
        workspaceDir = rootDir.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: submissionDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootDir)
    }

    private func makeManifest(requiredFiles: [String] = []) throws -> RunnerManifest {
        let jsonObject: [String: Any] = [
            "schemaVersion": 1,
            "gradingMode": "worker",
            "requiredFiles": requiredFiles,
            "testSuites": [["tier": "public", "script": "test_public.py"]],
            "timeLimitSeconds": 10,
            "makefile": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        return try JSONDecoder().decode(RunnerManifest.self, from: data)
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

    private func readWorkspaceFile(_ name: String) throws -> String {
        try String(contentsOf: workspaceDir.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func validPythonFileCopiedUnchanged() async throws {
        try writeSubmissionFile(name: "submission.py", contents: "print('hello')\n")

        let result = try await SubmissionNormalizer().normalizePythonSubmission(
            manifest: makeManifest(),
            submissionDirectory: submissionDir,
            workspaceDirectory: workspaceDir,
            submissionFilename: "submission.py"
        )

        #expect(result.warnings.isEmpty)
        #expect(result.preferredStudentModule == "submission.py")
        #expect(try readWorkspaceFile("submission.py") == "print('hello')\n")
    }

    @Test func notebookNormalizesToPyWithCellSeparators() async throws {
        try writeSubmissionFile(
            name: "assignment.ipynb",
            contents: """
                {
                  "nbformat": 4,
                  "metadata": {},
                  "cells": [
                    {"cell_type": "code", "source": ["x = 1\\n"]},
                    {"cell_type": "markdown", "source": ["# ignored"]},
                    {"cell_type": "code", "source": ["print(x)\\n"]}
                  ]
                }
                """)

        let result = try await SubmissionNormalizer().normalizePythonSubmission(
            manifest: makeManifest(),
            submissionDirectory: submissionDir,
            workspaceDirectory: workspaceDir,
            submissionFilename: "assignment.ipynb"
        )

        #expect(result.warnings.isEmpty)
        #expect(FileManager.default.fileExists(atPath: workspaceDir.appendingPathComponent("assignment.py").path))
        let extracted = try readWorkspaceFile("assignment.py")
        #expect(extracted.contains("# --- cell 1 ---"))
        #expect(extracted.contains("# --- cell 3 ---"))
        #expect(extracted.contains("# ignored") == false)
    }

    @Test func notebookRenamedToPyIsDetectedByContent() async throws {
        try writeSubmissionFile(
            name: "submission.py",
            contents: """
                {
                  "nbformat": 4,
                  "metadata": {},
                  "cells": [{"cell_type": "code", "source": ["value = 42\\n"]}]
                }
                """)

        let result = try await SubmissionNormalizer().normalizePythonSubmission(
            manifest: makeManifest(),
            submissionDirectory: submissionDir,
            workspaceDirectory: workspaceDir,
            submissionFilename: "submission.py"
        )

        #expect(result.preferredStudentModule == "submission.extracted.py")
        #expect(result.warnings.contains { $0.contains("appears to be a Jupyter notebook") })
        #expect(
            FileManager.default.fileExists(atPath: workspaceDir.appendingPathComponent("submission.extracted.py").path))
    }

    @Test func jSONFileThatIsNotNotebookFailsWithTargetedError() async throws {
        try writeSubmissionFile(name: "data.json", contents: #"{"hello":"world"}"#)

        await #expect {
            try await SubmissionNormalizer().normalizePythonSubmission(
                manifest: makeManifest(),
                submissionDirectory: submissionDir,
                workspaceDirectory: workspaceDir,
                submissionFilename: "data.json"
            )
        } throws: { error in
            #expect(
                error.localizedDescription
                    == "Uploaded file data.json is not a valid Python script or Jupyter notebook.")

            return true
        }
    }

    @Test func invalidNotebookJSONFailsEarly() async throws {
        try writeSubmissionFile(name: "bad.ipynb", contents: "{not json")

        await #expect {
            try await SubmissionNormalizer().normalizePythonSubmission(
                manifest: makeManifest(),
                submissionDirectory: submissionDir,
                workspaceDirectory: workspaceDir,
                submissionFilename: "bad.ipynb"
            )
        } throws: { error in
            #expect(error.localizedDescription == "Notebook file appears to be invalid JSON.")

            return true
        }
    }

    @Test func notebookWithNoCodeCellsFailsEarly() async throws {
        try writeSubmissionFile(
            name: "notes.ipynb",
            contents: """
                {
                  "nbformat": 4,
                  "metadata": {},
                  "cells": [{"cell_type": "markdown", "source": ["Only text"]}]
                }
                """)

        await #expect {
            try await SubmissionNormalizer().normalizePythonSubmission(
                manifest: makeManifest(),
                submissionDirectory: submissionDir,
                workspaceDirectory: workspaceDir,
                submissionFilename: "notes.ipynb"
            )
        } throws: { error in
            #expect(error.localizedDescription == "Notebook file contained no code cells to grade.")

            return true
        }
    }

    @Test func multiplePythonFilesDoNotCreateCompatibilityCopy() async throws {
        try writeSubmissionFile(name: "alpha.py", contents: "x = 1\n")
        try writeSubmissionFile(name: "beta.py", contents: "y = 2\n")

        let result = try await SubmissionNormalizer().normalizePythonSubmission(
            manifest: makeManifest(requiredFiles: ["main.py"]),
            submissionDirectory: submissionDir,
            workspaceDirectory: workspaceDir,
            submissionFilename: nil
        )

        #expect(FileManager.default.fileExists(atPath: workspaceDir.appendingPathComponent("main.py").path) == false)
        #expect(result.warnings.contains { $0.contains("compatibility copy") } == false)
    }

    @Test func singlePythonSourceCreatesCompatibilityCopy() async throws {
        try writeSubmissionFile(name: "submission.py", contents: "answer = 42\n")

        let result = try await SubmissionNormalizer().normalizePythonSubmission(
            manifest: makeManifest(requiredFiles: ["main.py"]),
            submissionDirectory: submissionDir,
            workspaceDirectory: workspaceDir,
            submissionFilename: "submission.py"
        )

        #expect(FileManager.default.fileExists(atPath: workspaceDir.appendingPathComponent("main.py").path))
        #expect(result.warnings.contains { $0.contains("compatibility copy") })
    }

    @Test func unsupportedFilesAreIgnoredWhenPythonExists() async throws {
        try writeSubmissionFile(name: "submission.py", contents: "print('ok')\n")
        let binaryURL = submissionDir.appendingPathComponent("archive.bin")
        try Data([0x00, 0x01, 0x02]).write(to: binaryURL)

        let result = try await SubmissionNormalizer().normalizePythonSubmission(
            manifest: makeManifest(),
            submissionDirectory: submissionDir,
            workspaceDirectory: workspaceDir,
            submissionFilename: nil
        )

        #expect(result.warnings.contains { $0.contains("Ignoring unsupported file archive.bin") })
        #expect(FileManager.default.fileExists(atPath: workspaceDir.appendingPathComponent("submission.py").path))
    }
}

// MARK: - SubmissionNormalizerEdgeCaseTests

// Paths of `SubmissionNormalizer.normalizePythonSubmission` that no other
// suite reached: an upload with no usable source among several files, a
// compatibility copy refused because the single source is not Python, a
// compatibility copy that becomes the preferred module, a `.ipynb` that is
// JSON but not a notebook, and two notebook outputs that want the same name.
//
// The fixture is duplicated from `SubmissionNormalizerTests` on purpose, as
// `SubmissionNormalizerGapTests` explains: a shared fixture edited for one
// file silently changes what another file proves.

@Suite(.timeLimit(.minutes(3))) final class SubmissionNormalizerEdgeCaseTests {
    private let rootDir: URL
    private let submissionDir: URL
    private let workspaceDir: URL

    init() throws {
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("submission-normalizer-edge-\(UUID().uuidString)", isDirectory: true)
        submissionDir = rootDir.appendingPathComponent("submission", isDirectory: true)
        workspaceDir = rootDir.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: submissionDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootDir)
    }

    private func makeManifest(requiredFiles: [String] = []) throws -> RunnerManifest {
        let jsonObject: [String: Any] = [
            "schemaVersion": 1,
            "gradingMode": "worker",
            "requiredFiles": requiredFiles,
            "testSuites": [["tier": "public", "script": "test_public.py"]],
            "timeLimitSeconds": 10,
            "makefile": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        return try JSONDecoder().decode(RunnerManifest.self, from: data)
    }

    private func writeSubmissionFile(name: String, contents: String) throws {
        let fileURL = submissionDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func writePNG(name: String) throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x00, count: 64))
        try png.write(to: submissionDir.appendingPathComponent(name))
    }

    private func normalize(
        requiredFiles: [String] = [], submissionDirectory: URL? = nil
    ) async throws
        -> NormalizationResult
    {
        try await SubmissionNormalizer().normalizePythonSubmission(
            manifest: makeManifest(requiredFiles: requiredFiles),
            submissionDirectory: submissionDirectory ?? submissionDir,
            workspaceDirectory: workspaceDir,
            submissionFilename: nil
        )
    }

    private static let notebook = """
        {
          "nbformat": 4,
          "metadata": {},
          "cells": [{"cell_type": "code", "source": ["value = 42\\n"]}]
        }
        """

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: workspaceDir.appendingPathComponent(relativePath).path)
    }

    // MARK: - No sources

    /// Two unsupported files: the lone-file message does not apply, so the
    /// student reads the general "no sources" message.
    @Test func severalUnsupportedFilesFailWithNoSourcesFound() async throws {
        try writePNG(name: "diagram.png")
        try writePNG(name: "photo.png")

        await #expect {
            _ = try await self.normalize()
        } throws: { error in
            guard case SubmissionNormalizationError.noSourcesFound(let language) = error else { return false }
            #expect(language == .python)
            #expect(
                error.localizedDescription
                    == "No Python source files were found after submission normalisation.")
            return true
        }
    }

    @Test func anEmptySubmissionDirectoryFailsWithNoSourcesFound() async throws {
        await #expect {
            _ = try await self.normalize()
        } throws: { error in
            guard case SubmissionNormalizationError.noSourcesFound = error else { return false }
            return true
        }
    }

    @Test func aMissingSubmissionDirectoryFailsWithNoSourcesFound() async throws {
        let missing = rootDir.appendingPathComponent("does-not-exist", isDirectory: true)
        await #expect {
            _ = try await self.normalize(submissionDirectory: missing)
        } throws: { error in
            guard case SubmissionNormalizationError.noSourcesFound = error else { return false }
            return true
        }
    }

    // MARK: - Compatibility copy

    /// `classify` accepts any text file as a Python script, so a lone
    /// `solution.lua` is produced. It is not Python, so no copy is made to
    /// the expected name, and a warning says why.
    @Test func aSingleNonPythonSourceGetsNoCompatibilityCopy() async throws {
        try writeSubmissionFile(name: "solution.lua", contents: "print('hello')\n")

        let result = try await normalize(requiredFiles: ["solution.py"])

        #expect(!exists("solution.py"))
        #expect(
            result.warnings.contains(
                "Expected file solution.py was not present, and solution.lua is not a Python file, "
                    + "so no compatibility copy was made."))
        #expect(!result.warnings.contains { $0.contains("created a compatibility copy") })
        #expect(result.producedPythonFiles.map(\.lastPathComponent) == ["solution.lua"])
    }

    /// A single source in a subdirectory names no preferred module, so the
    /// root-level compatibility copy becomes the preferred module.
    @Test func aCompatibilityCopyBecomesThePreferredModuleWhenNoneWasChosen() async throws {
        try writeSubmissionFile(name: "src/work.py", contents: "answer = 42\n")

        let result = try await normalize(requiredFiles: ["solution.py"])

        #expect(exists("solution.py"))
        #expect(result.preferredStudentModule == "solution.py")
        #expect(result.producedPythonFiles.map(\.lastPathComponent) == ["work.py", "solution.py"])
        #expect(result.warnings.contains { $0.contains("created a compatibility copy") })
    }

    // MARK: - Notebooks

    /// A file with the `.ipynb` extension is parsed as a notebook whatever
    /// its MIME type. Valid JSON that is not a notebook is refused by name.
    @Test func anIpynbThatIsNotANotebookIsRejectedByName() async throws {
        try writeSubmissionFile(name: "work.ipynb", contents: #"{"hello": "world"}"#)

        await #expect {
            _ = try await self.normalize()
        } throws: { error in
            guard case SubmissionNormalizationError.invalidSubmission(let filename, let language) = error else {
                return false
            }
            #expect(filename == "work.ipynb")
            #expect(language == .python)
            #expect(
                error.localizedDescription
                    == "Uploaded file work.ipynb is not a valid Python script or Jupyter notebook.")
            return true
        }
    }

    /// A notebook saved as `hw.py` extracts to `hw.extracted.py`. When the
    /// student also uploaded a script with that name, the extracted source
    /// takes the next free numbered name and the script is kept.
    @Test func aNotebookOutputThatCollidesTakesTheNextNumberedName() async throws {
        try writeSubmissionFile(name: "hw.extracted.py", contents: "script = True\n")
        try writeSubmissionFile(name: "hw.py", contents: Self.notebook)

        let result = try await normalize()

        #expect(exists("hw.extracted.py"))
        #expect(exists("hw.extracted.1.py"))
        let script = try String(
            contentsOf: workspaceDir.appendingPathComponent("hw.extracted.py"), encoding: .utf8)
        #expect(script == "script = True\n")
        let extracted = try String(
            contentsOf: workspaceDir.appendingPathComponent("hw.extracted.1.py"), encoding: .utf8)
        #expect(extracted.contains("value = 42"))
        #expect(
            result.producedPythonFiles.map(\.lastPathComponent) == ["hw.extracted.py", "hw.extracted.1.py"])
        // The script came first in sorted order, so it is the preferred module.
        #expect(result.preferredStudentModule == "hw.extracted.py")
    }

    // MARK: - Error descriptions

    @Test func aMimeDetectionFailureNamesTheFile() {
        #expect(
            SubmissionNormalizationError.mimeDetectionFailed("upload.bin").errorDescription
                == "Could not detect content type for upload.bin.")
    }

    @Test(arguments: [AssignmentLanguage.r, .lua])
    func theNoSourcesMessageNamesTheLanguage(_ language: AssignmentLanguage) {
        #expect(
            SubmissionNormalizationError.noSourcesFound(language).errorDescription
                == "No \(language.displayName) source files were found after submission normalisation.")
    }
}

// MARK: - SubmissionNormalizerGapTests

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

@Suite(.timeLimit(.minutes(3))) final class SubmissionNormalizerGapTests {
    private let rootDir: URL
    private let submissionDir: URL
    private let workspaceDir: URL

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

    private func makeManifest(requiredFiles: [String] = []) throws -> RunnerManifest {
        let jsonObject: [String: Any] = [
            "schemaVersion": 1,
            "gradingMode": "worker",
            "requiredFiles": requiredFiles,
            "testSuites": [["tier": "public", "script": "test_public.py"]],
            "timeLimitSeconds": 10,
            "makefile": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        return try JSONDecoder().decode(RunnerManifest.self, from: data)
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
        manifest: RunnerManifest, submissionFilename: String?
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
                thrown = error
                throw error
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
