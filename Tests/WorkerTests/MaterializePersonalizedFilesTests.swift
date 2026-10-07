// Tests/WorkerTests/MaterializePersonalizedFilesTests.swift
//
// `materializePersonalizedFiles` writes a job's per-student files into the
// grading workspace (#1799). Each refusal here stands in for a grade that
// would otherwise be silently wrong: inputs rendered in a guessed language,
// or a dataset slice written outside the workspace.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite final class MaterializePersonalizedFilesTests {

    /// A directory of this test's own, so a file written outside the
    /// workspace lands where the test can see it and nowhere shared.
    let root: URL
    let workspace: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-materialize-\(UUID().uuidString)", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func job(
        inputs: [String: String]? = nil, files: [String: String]? = nil, language: AssignmentLanguage?
    ) -> Job {
        Job(
            submissionID: "sub_1",
            testSetupID: "ts_1",
            attemptNumber: 1,
            submissionURL: testURL("https://server.test/sub.zip"),
            testSetupURL: testURL("https://server.test/ts.zip"),
            manifest: TestProperties(language: nil),
            personalizedInputs: inputs,
            personalizedFiles: files,
            language: language
        )
    }

    private func contents(_ name: String) throws -> String {
        try String(contentsOf: workspace.appendingPathComponent(name), encoding: .utf8)
    }

    private func names() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: workspace.path))
    }

    /// The inputs file takes the language's own name and its own rendering,
    /// so a generated test in that language finds it where it looks.
    @Test(arguments: AssignmentLanguage.allCases)
    func theInputsFileIsWrittenInTheJobsLanguage(language: AssignmentLanguage) throws {
        let inputs = ["threshold": "42"]
        try materializePersonalizedFiles(job: job(inputs: inputs, language: language), into: workspace)
        #expect(try names() == [language.inputsFileName])
        #expect(try contents(language.inputsFileName) == language.renderInputsFile(inputs))
    }

    @Test func inputsWithoutALanguageAreRefusedAndNothingIsWritten() throws {
        let error = #expect(throws: WorkerDaemonError.self) {
            try materializePersonalizedFiles(
                job: self.job(inputs: ["a": "1", "b": "2"], language: nil), into: self.workspace)
        }
        guard case .personalizedInputsWithoutLanguage(let count) = error else {
            Issue.record("expected personalizedInputsWithoutLanguage, got \(String(describing: error))")
            return
        }
        #expect(count == 2)
        #expect(try names().isEmpty)
    }

    /// A plain `.sh` suite has no language and no inputs; that job writes
    /// nothing and does not throw.
    @Test func aJobWithNothingPersonalWritesNothing() throws {
        try materializePersonalizedFiles(job: job(inputs: [:], files: [:], language: nil), into: workspace)
        try materializePersonalizedFiles(job: job(language: nil), into: workspace)
        #expect(try names().isEmpty)
    }

    /// A dataset slice replaces the pool copy the test setup brought in.
    @Test func aDatasetSliceOverwritesThePoolFile() throws {
        try "the whole pool\n".write(
            to: workspace.appendingPathComponent("data.csv"), atomically: true, encoding: .utf8)
        try materializePersonalizedFiles(
            job: job(files: ["data.csv": "this student's slice\n"], language: .python), into: workspace)
        #expect(try contents("data.csv") == "this student's slice\n")
    }

    @Test(arguments: ["../escape.csv", "nested/data.csv", "/tmp/data.csv"])
    func aFilenameThatCarriesAPathIsRefused(name: String) throws {
        let error = #expect(throws: WorkerDaemonError.self) {
            try materializePersonalizedFiles(
                job: self.job(files: [name: "x"], language: .python), into: self.workspace)
        }
        guard case .unsafePersonalizedFilename(let refused) = error else {
            Issue.record("expected unsafePersonalizedFilename, got \(String(describing: error))")
            return
        }
        #expect(refused == name)
        #expect(try names().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["workspace"])
    }
}
