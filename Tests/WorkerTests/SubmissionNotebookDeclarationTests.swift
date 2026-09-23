// Tests/WorkerTests/SubmissionNotebookDeclarationTests.swift
//
// When no language owns the manifest (a plain `.sh` suite), the submission's
// own notebook metadata decides how it is prepared. The mutation sweep of
// 2026-09-22 (#1574) found two unpinned decisions on that path:
//
//   * `submissionNotebookLanguage` reads the named file only when it is an
//     `.ipynb`, and otherwise looks for a notebook in the staged directory —
//     the zip-upload case. Flipping the `== "ipynb"` check made a zip upload
//     read the zip itself as JSON and report no language at all.
//   * `submissionNormalization` step 3 honours a declared NON-Python language.
//     Flipping `declared != .python` sent an R notebook down Python's
//     heuristics, which turn it into a Python module the R suite cannot grade.

import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(1))) final class SubmissionNotebookDeclarationTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-declaration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private static let rNotebook = #"""
        {"cells":[{"cell_type":"code","metadata":{},"source":["x <- 1\n"]}],"metadata":{"kernelspec":{"name":"xr","display_name":"R (xeus-r)","language":"R"},"language_info":{"name":"r"}},"nbformat":4,"nbformat_minor":5}
        """#

    private static let shellOnlyManifest =
        #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_x.sh"}],"timeLimitSeconds":10}"#

    /// A zip upload: the named file is the archive, and the notebook it held
    /// sits unpacked in the staged directory.
    @Test func aZipUploadIsReadFromTheNotebookItContained() throws {
        try Data("PK\u{3}\u{4} not json".utf8).write(to: directory.appendingPathComponent("submission.zip"))
        try Self.rNotebook.write(
            to: directory.appendingPathComponent("analysis.ipynb"), atomically: true, encoding: .utf8)
        #expect(
            submissionNotebookLanguage(submissionDirectory: directory, submissionFilename: "submission.zip")
                == .r)
    }

    @Test func aDeclaredNonPythonNotebookIsExtractedInItsOwnLanguage() throws {
        try Self.rNotebook.write(
            to: directory.appendingPathComponent("solution.ipynb"), atomically: true, encoding: .utf8)
        let manifest = try JSONDecoder().decode(TestProperties.self, from: Data(Self.shellOnlyManifest.utf8))
        #expect(
            submissionNormalization(
                manifest: manifest, submissionFilename: "solution.ipynb", submissionDirectory: directory)
                == .extractToSource(forcedLanguage: .r))
    }
}
