// Tests/WorkerTests/NestedJSONNotebookTests.swift
//
// A notebook saved without the `.ipynb` extension is still recognised by its
// content and extracted to `<name>.extracted.py` in its OWN directory. The
// mutation sweep of 2026-09-22 (#1574) replaced `parent == "."` with `!=` and
// nothing failed, because no test submitted such a notebook below the root.
// Under the mutation, `labs/work.json` was extracted to the workspace root, so
// a nested helper could replace a root-level module of the same name.

import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) final class NestedJSONNotebookTests {
    private let submission: URL
    private let workspace: URL
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-json-notebook-\(UUID().uuidString)", isDirectory: true)
        submission = root.appendingPathComponent("submission", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: submission.appendingPathComponent("labs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test func aNestedJSONNotebookIsExtractedBesideItself() async throws {
        let notebook = #"""
            {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","metadata":{},"source":["x = 1\n"]}]}
            """#
        try notebook.write(
            to: submission.appendingPathComponent("labs/work.json"), atomically: true, encoding: .utf8)
        let manifest = try JSONDecoder().decode(
            TestProperties.self,
            from: Data(
                #"""
                {"schemaVersion": 1, "gradingMode": "worker", "requiredFiles": [],
                 "testSuites": [{"tier": "public", "script": "test_public.py"}],
                 "timeLimitSeconds": 10, "makefile": null}
                """#.utf8))

        let result = try await SubmissionNormalizer().normalizePythonSubmission(
            manifest: manifest, submissionDirectory: submission, workspaceDirectory: workspace,
            submissionFilename: nil)

        let produced = result.producedPythonFiles.map(\.lastPathComponent)
        #expect(produced == ["work.extracted.py"])
        #expect(
            FileManager.default.fileExists(atPath: workspace.appendingPathComponent("labs/work.extracted.py").path))
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("work.extracted.py").path))
    }
}
