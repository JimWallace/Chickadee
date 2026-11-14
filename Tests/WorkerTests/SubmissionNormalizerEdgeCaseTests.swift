// Tests/WorkerTests/SubmissionNormalizerEdgeCaseTests.swift
//
// Paths of `SubmissionNormalizer.normalizePythonSubmission` that no other
// suite reached: an upload with no usable source among several files, a
// compatibility copy refused because the single source is not Python, a
// compatibility copy that becomes the preferred module, a `.ipynb` that is
// JSON but not a notebook, and two notebook outputs that want the same name.
//
// The fixture is duplicated from `SubmissionNormalizerTests` on purpose, as
// `SubmissionNormalizerGapTests` explains: a shared fixture edited for one
// file silently changes what another file proves.

import Core
import Foundation
import Testing

@testable import chickadee_runner

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
