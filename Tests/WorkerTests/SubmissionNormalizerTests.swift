import XCTest
@testable import chickadee_runner
import Core
import Foundation

final class SubmissionNormalizerTests: XCTestCase {
    private var rootDir: URL!
    private var submissionDir: URL!
    private var workspaceDir: URL!

    override func setUp() async throws {
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("submission-normalizer-\(UUID().uuidString)", isDirectory: true)
        submissionDir = rootDir.appendingPathComponent("submission", isDirectory: true)
        workspaceDir = rootDir.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: submissionDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootDir)
    }

    private func makeManifest(requiredFiles: [String] = []) throws -> TestProperties {
        let jsonObject: [String: Any] = [
            "schemaVersion": 1,
            "gradingMode": "worker",
            "requiredFiles": requiredFiles,
            "testSuites": [["tier": "public", "script": "test_public.py"]],
            "timeLimitSeconds": 10,
            "makefile": NSNull()
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

    func testValidPythonFileCopiedUnchanged() throws {
        try writeSubmissionFile(name: "submission.py", contents: "print('hello')\n")

        let result = try SubmissionNormalizer().normalizePythonSubmission(
            manifest: makeManifest(),
            submissionDirectory: submissionDir,
            workspaceDirectory: workspaceDir,
            submissionFilename: "submission.py"
        )

        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.preferredStudentModule, "submission.py")
        XCTAssertEqual(try readWorkspaceFile("submission.py"), "print('hello')\n")
    }

    func testNotebookNormalizesToPyWithCellSeparators() throws {
        try writeSubmissionFile(name: "assignment.ipynb", contents: """
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

        XCTAssertEqual(result.warnings, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceDir.appendingPathComponent("assignment.py").path))
        let extracted = try readWorkspaceFile("assignment.py")
        XCTAssertTrue(extracted.contains("# --- cell 1 ---"))
        XCTAssertTrue(extracted.contains("# --- cell 3 ---"))
        XCTAssertFalse(extracted.contains("# ignored"))
    }

    func testNotebookRenamedToPyIsDetectedByContent() throws {
        try writeSubmissionFile(name: "submission.py", contents: """
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

        XCTAssertEqual(result.preferredStudentModule, "submission.extracted.py")
        XCTAssertTrue(result.warnings.contains { $0.contains("appears to be a Jupyter notebook") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceDir.appendingPathComponent("submission.extracted.py").path))
    }

    func testJSONFileThatIsNotNotebookFailsWithTargetedError() throws {
        try writeSubmissionFile(name: "data.json", contents: #"{"hello":"world"}"#)

        XCTAssertThrowsError(
            try SubmissionNormalizer().normalizePythonSubmission(
                manifest: makeManifest(),
                submissionDirectory: submissionDir,
                workspaceDirectory: workspaceDir,
                submissionFilename: "data.json"
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Uploaded file data.json is not a valid Python script or Jupyter notebook."
            )
        }
    }

    func testInvalidNotebookJSONFailsEarly() throws {
        try writeSubmissionFile(name: "bad.ipynb", contents: "{not json")

        XCTAssertThrowsError(
            try SubmissionNormalizer().normalizePythonSubmission(
                manifest: makeManifest(),
                submissionDirectory: submissionDir,
                workspaceDirectory: workspaceDir,
                submissionFilename: "bad.ipynb"
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Notebook file appears to be invalid JSON.")
        }
    }

    func testNotebookWithNoCodeCellsFailsEarly() throws {
        try writeSubmissionFile(name: "notes.ipynb", contents: """
        {
          "nbformat": 4,
          "metadata": {},
          "cells": [{"cell_type": "markdown", "source": ["Only text"]}]
        }
        """)

        XCTAssertThrowsError(
            try SubmissionNormalizer().normalizePythonSubmission(
                manifest: makeManifest(),
                submissionDirectory: submissionDir,
                workspaceDirectory: workspaceDir,
                submissionFilename: "notes.ipynb"
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Notebook file contained no code cells to grade.")
        }
    }

    func testMultiplePythonFilesDoNotCreateCompatibilityCopy() throws {
        try writeSubmissionFile(name: "alpha.py", contents: "x = 1\n")
        try writeSubmissionFile(name: "beta.py", contents: "y = 2\n")

        let result = try SubmissionNormalizer().normalizePythonSubmission(
            manifest: makeManifest(requiredFiles: ["main.py"]),
            submissionDirectory: submissionDir,
            workspaceDirectory: workspaceDir,
            submissionFilename: nil
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceDir.appendingPathComponent("main.py").path))
        XCTAssertFalse(result.warnings.contains { $0.contains("compatibility copy") })
    }

    func testSinglePythonSourceCreatesCompatibilityCopy() throws {
        try writeSubmissionFile(name: "submission.py", contents: "answer = 42\n")

        let result = try SubmissionNormalizer().normalizePythonSubmission(
            manifest: makeManifest(requiredFiles: ["main.py"]),
            submissionDirectory: submissionDir,
            workspaceDirectory: workspaceDir,
            submissionFilename: "submission.py"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceDir.appendingPathComponent("main.py").path))
        XCTAssertTrue(result.warnings.contains { $0.contains("compatibility copy") })
    }

    func testUnsupportedFilesAreIgnoredWhenPythonExists() throws {
        try writeSubmissionFile(name: "submission.py", contents: "print('ok')\n")
        let binaryURL = submissionDir.appendingPathComponent("archive.bin")
        try Data([0x00, 0x01, 0x02]).write(to: binaryURL)

        let result = try SubmissionNormalizer().normalizePythonSubmission(
            manifest: makeManifest(),
            submissionDirectory: submissionDir,
            workspaceDirectory: workspaceDir,
            submissionFilename: nil
        )

        XCTAssertTrue(result.warnings.contains { $0.contains("Ignoring unsupported file archive.bin") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceDir.appendingPathComponent("submission.py").path))
    }
}
