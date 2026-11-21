// Tests/APITests/Assignments/CurrentSetupFilesSolutionLinkTests.swift
//
// `currentSetupFiles` builds the Files panel of the assignment edit page. Two
// paths had no test, and the suite pins the rows around them too. When no
// solution was saved but the setup zip bundles a `solution.*` file, the panel
// links that zip entry. When the stored manifest does not decode, every file in
// the zip is listed as a support file, in name order, and none is lost.
//
// A time limit, because the builder runs `unzip` subprocesses. `.serialized`
// as in `SetupZipRewriteTests`: zip subprocesses race under within-suite
// parallelism.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) struct CurrentSetupFilesSolutionLinkTests {

    private let manifest = """
        {
          "schemaVersion": 1,
          "gradingMode": "worker",
          "requiredFiles": [],
          "testSuites": [{"tier":"release","script":"releasetest_b.py","points":2}],
          "timeLimitSeconds": 10,
          "makefile": null
        }
        """

    private func withSetup(
        manifest: String, notebookPath: String? = nil, _ body: (APITestSetup) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("current-setup-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zipPath = root.appendingPathComponent("setup.zip").path
        try await writeZipFixture(
            at: zipPath,
            entries: [
                ("assignment.ipynb", "{}"),
                ("solution.py", "x = 1\n"),
                ("notes.txt", "notes"),
                ("releasetest_b.py", "print('ok')"),
            ])
        let setup = APITestSetup(
            id: "setup_files", manifest: manifest, zipPath: zipPath, notebookPath: notebookPath,
            courseID: UUID())
        try await body(setup)
    }

    @Test func aBundledSolutionIsLinkedWhenNoSolutionWasSaved() async throws {
        try await withSetup(manifest: manifest) { setup in
            let files = await currentSetupFiles(for: setup, assignmentID: "asg123", solutionFilename: nil)
            let solution = try #require(files.solutionFile)
            #expect(solution.name == "solution.py")
            #expect(solution.url == "/instructor/asg123/files/item?name=solution.py")
            // The solution and the notebook are not listed as suite rows.
            #expect(files.existingSuiteRows.map(\.name) == ["releasetest_b.py", "notes.txt"])
        }
    }

    @Test func aSavedSolutionIsLinkedBeforeABundledOne() async throws {
        try await withSetup(manifest: manifest) { setup in
            for saved in [nil, ""] as [String?] {
                let fallback = await currentSetupFiles(for: setup, assignmentID: "asg123", solutionFilename: saved)
                #expect(fallback.solutionFile?.name == "solution.py", "an empty name is not a saved solution")
            }
            let files = await currentSetupFiles(
                for: setup, assignmentID: "asg123", solutionFilename: "solution.ipynb")
            #expect(files.solutionFile?.name == "solution.ipynb")
            #expect(files.solutionFile?.url == "/instructor/asg123/files/solution")
        }
    }

    @Test func testRowsComeFirstAndCarryTheirManifestFields() async throws {
        try await withSetup(manifest: manifest, notebookPath: "/data/setups/lab1.ipynb") { setup in
            let files = await currentSetupFiles(for: setup, assignmentID: "asg123", solutionFilename: nil)
            #expect(files.assignmentFile.name == "lab1.ipynb")
            let test = try #require(files.existingSuiteRows.first)
            #expect(test.name == "releasetest_b.py")
            #expect(test.isTest)
            #expect(test.tier == "release")
            #expect(test.points == 2)
            let support = try #require(files.existingSuiteRows.last)
            #expect(support.isTest == false)
            #expect(support.tier == "support")
        }
    }

    @Test func anUnreadableManifestListsEveryFileAsSupportInNameOrder() async throws {
        try await withSetup(manifest: "{ not json") { setup in
            let files = await currentSetupFiles(for: setup, assignmentID: "asg123", solutionFilename: nil)
            #expect(files.existingSuiteRows.map(\.name) == ["notes.txt", "releasetest_b.py"])
            #expect(files.existingSuiteRows.allSatisfy { !$0.isTest && $0.tier == "support" && !$0.isDataset })
            #expect(files.existingSuiteRows.map(\.order) == [1, 2])
            #expect(files.assignmentFile.name == "assignment.ipynb")
        }
    }
}
