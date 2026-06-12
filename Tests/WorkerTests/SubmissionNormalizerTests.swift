import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite final class SubmissionNormalizerTests {
    private var rootDir: URL!
    private var submissionDir: URL!
    private var workspaceDir: URL!

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

    private func readWorkspaceFile(_ name: String) throws -> String {
        try String(contentsOf: workspaceDir.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func validPythonFileCopiedUnchanged() throws {
        try writeSubmissionFile(name: "submission.py", contents: "print('hello')\n")

        let result = try SubmissionNormalizer().normalizePythonSubmission(
            manifest: makeManifest(),
            submissionDirectory: submissionDir,
            workspaceDirectory: workspaceDir,
            submissionFilename: "submission.py"
        )

        #expect(result.warnings.isEmpty)
        #expect(result.preferredStudentModule == "submission.py")
        #expect(try readWorkspaceFile("submission.py") == "print('hello')\n")
    }

    @Test func notebookNormalizesToPyWithCellSeparators() throws {
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

        let result = try SubmissionNormalizer().normalizePythonSubmission(
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

    @Test func notebookRenamedToPyIsDetectedByContent() throws {
        try writeSubmissionFile(
            name: "submission.py",
            contents: """
                {
                  "nbformat": 4,
                  "metadata": {},
                  "cells": [{"cell_type": "code", "source": ["value = 42\\n"]}]
                }
                """)

        let result = try SubmissionNormalizer().normalizePythonSubmission(
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

    @Test func jSONFileThatIsNotNotebookFailsWithTargetedError() throws {
        try writeSubmissionFile(name: "data.json", contents: #"{"hello":"world"}"#)

        #expect {
            try SubmissionNormalizer().normalizePythonSubmission(
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

    @Test func invalidNotebookJSONFailsEarly() throws {
        try writeSubmissionFile(name: "bad.ipynb", contents: "{not json")

        #expect {
            try SubmissionNormalizer().normalizePythonSubmission(
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

    @Test func notebookWithNoCodeCellsFailsEarly() throws {
        try writeSubmissionFile(
            name: "notes.ipynb",
            contents: """
                {
                  "nbformat": 4,
                  "metadata": {},
                  "cells": [{"cell_type": "markdown", "source": ["Only text"]}]
                }
                """)

        #expect {
            try SubmissionNormalizer().normalizePythonSubmission(
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

    @Test func multiplePythonFilesDoNotCreateCompatibilityCopy() throws {
        try writeSubmissionFile(name: "alpha.py", contents: "x = 1\n")
        try writeSubmissionFile(name: "beta.py", contents: "y = 2\n")

        let result = try SubmissionNormalizer().normalizePythonSubmission(
            manifest: makeManifest(requiredFiles: ["main.py"]),
            submissionDirectory: submissionDir,
            workspaceDirectory: workspaceDir,
            submissionFilename: nil
        )

        #expect(FileManager.default.fileExists(atPath: workspaceDir.appendingPathComponent("main.py").path) == false)
        #expect(result.warnings.contains { $0.contains("compatibility copy") } == false)
    }

    @Test func singlePythonSourceCreatesCompatibilityCopy() throws {
        try writeSubmissionFile(name: "submission.py", contents: "answer = 42\n")

        let result = try SubmissionNormalizer().normalizePythonSubmission(
            manifest: makeManifest(requiredFiles: ["main.py"]),
            submissionDirectory: submissionDir,
            workspaceDirectory: workspaceDir,
            submissionFilename: "submission.py"
        )

        #expect(FileManager.default.fileExists(atPath: workspaceDir.appendingPathComponent("main.py").path))
        #expect(result.warnings.contains { $0.contains("compatibility copy") })
    }

    @Test func unsupportedFilesAreIgnoredWhenPythonExists() throws {
        try writeSubmissionFile(name: "submission.py", contents: "print('ok')\n")
        let binaryURL = submissionDir.appendingPathComponent("archive.bin")
        try Data([0x00, 0x01, 0x02]).write(to: binaryURL)

        let result = try SubmissionNormalizer().normalizePythonSubmission(
            manifest: makeManifest(),
            submissionDirectory: submissionDir,
            workspaceDirectory: workspaceDir,
            submissionFilename: nil
        )

        #expect(result.warnings.contains { $0.contains("Ignoring unsupported file archive.bin") })
        #expect(FileManager.default.fileExists(atPath: workspaceDir.appendingPathComponent("submission.py").path))
    }
}
