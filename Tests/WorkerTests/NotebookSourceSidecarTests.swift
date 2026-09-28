// Tests/WorkerTests/NotebookSourceSidecarTests.swift
//
// A root-level notebook gets an introspectable `<name>.source.py` sidecar and a
// `.chickadee_student_source` hint naming it, which the structural and AST
// notebook checks read through `student_source()`. The mutation sweep of
// 2026-09-22 (#1574) flipped both halves of the condition that writes them and
// nothing failed, so those checks could have lost their source, or read a
// nested helper notebook's source in place of the student's.

import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) final class NotebookSourceSidecarTests {
    private let submission: URL
    private let workspace: URL
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-sidecar-\(UUID().uuidString)", isDirectory: true)
        submission = root.appendingPathComponent("submission", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: submission, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private static let notebook = #"""
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","metadata":{},"source":["def f():\n","    return 1\n"]}]}
        """#

    private func normalize(notebookAt relativePath: String) async throws {
        let url = submission.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.notebook.write(to: url, atomically: true, encoding: .utf8)
        let manifest = try JSONDecoder().decode(
            TestProperties.self,
            from: Data(
                #"""
                {"schemaVersion": 1, "gradingMode": "worker", "requiredFiles": [],
                 "testSuites": [{"tier": "public", "script": "test_public.py"}],
                 "timeLimitSeconds": 10, "makefile": null}
                """#.utf8))
        _ = try await SubmissionNormalizer().normalizePythonSubmission(
            manifest: manifest, submissionDirectory: submission, workspaceDirectory: workspace,
            submissionFilename: nil)
    }

    @Test func aRootLevelNotebookGetsTheSourceSidecarAndItsHint() async throws {
        try await normalize(notebookAt: "work.ipynb")
        let hint = try String(
            contentsOf: workspace.appendingPathComponent(".chickadee_student_source"), encoding: .utf8)
        #expect(hint == "work.source.py")
        let sidecar = try String(contentsOf: workspace.appendingPathComponent(hint), encoding: .utf8)
        #expect(sidecar.contains("def f():"))
    }

    @Test func aNestedNotebookGetsNoSidecar() async throws {
        try await normalize(notebookAt: "helpers/work.ipynb")
        #expect(
            !FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent(".chickadee_student_source").path))
    }
}
