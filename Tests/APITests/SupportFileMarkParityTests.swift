// Tests/APITests/SupportFileMarkParityTests.swift
//
// The web and MCP doors apply one rule to a support file's marks (#2487).
//
// - A web delete clears the file's grader-only mark and dataset spec, as MCP
//   `delete_support_file` does. It used to remove only the suite entry, so a
//   dataset spec named a missing file and a grader-only mark blocked browser
//   grading.
// - The web `PUT /datasets` refuses the specs that MCP `set_dataset` refuses.
//   It used to accept a graded script or a notebook as a dataset, and a spec
//   with no `sampleSize`. (`SetDatasetToolTests` covers the MCP side.)

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) final class SupportFileMarkParityTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-mark-parity")
    }

    /// A setup that bundles a graded script, a dataset and a grader-only file,
    /// with both marks in the manifest.
    private func makeSetup() async throws -> APITestSetup {
        let course = try await makeTestCourse(on: app, code: "MARKS")
        let setupID = "marks_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        try await writeZipFixture(
            at: zipPath,
            entries: [
                ("publictest_a.py", "print('ok')\n"), ("cases.csv", "id\n1\n2\n3\n"),
                ("answers.csv", "id\n1\n"),
            ])
        let manifest = """
            {"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],\
            "testSuites":[{"tier":"public","script":"publictest_a.py"}],\
            "graderOnlyFiles":["answers.csv"],"datasets":[{"file":"cases.csv","sampleSize":2}],\
            "timeLimitSeconds":10}
            """
        let setup = APITestSetup(id: setupID, manifest: manifest, zipPath: zipPath, courseID: try course.requireID())
        try await setup.save(on: app.db)
        return setup
    }

    @Test func aWebDeleteClearsTheFilesMarks() async throws {
        try await withApp(app) { app in
            let setup = try await makeSetup()

            try await deleteScriptFromSetup(setup: setup, filename: "cases.csv", on: app.db)
            try await deleteScriptFromSetup(setup: setup, filename: "answers.csv", on: app.db)

            let stored = try #require(try await APITestSetup.find(setup.id, on: app.db))
            let props = try #require(stored.decodedManifest())
            #expect(props.datasets.isEmpty)
            #expect(props.graderOnlyFiles.isEmpty)
            #expect(props.testSuites.map(\.script) == ["publictest_a.py"])
        }
    }

    @Test(arguments: [
        DatasetSpec(file: "publictest_a.py", sampleSize: 2),
        DatasetSpec(file: "assignment.ipynb", sampleSize: 2),
        DatasetSpec(file: "cases.csv", sampleSize: nil),
        DatasetSpec(file: "cases.csv", sampleSize: 0),
        DatasetSpec(file: "missing.csv", sampleSize: 2),
        DatasetSpec(file: "../cases.csv", sampleSize: 2),
    ])
    func theWebDatasetEditRefusesWhatMCPRefuses(_ spec: DatasetSpec) async throws {
        try await withApp(app) { app in
            let setup = try await makeSetup()
            let before = setup.manifest

            await #expect(throws: (any Error).self) {
                try await applyDatasetsEdit(setup: setup, datasets: [spec], on: app.db)
            }
            let stored = try #require(try await APITestSetup.find(setup.id, on: app.db))
            #expect(stored.manifest == before)
        }
    }

    @Test func theWebDatasetEditStillAcceptsASupportFile() async throws {
        try await withApp(app) { app in
            let setup = try await makeSetup()
            try await applyDatasetsEdit(
                setup: setup, datasets: [DatasetSpec(file: "cases.csv", sampleSize: 3)], on: app.db)
            let stored = try #require(try await APITestSetup.find(setup.id, on: app.db))
            #expect(stored.decodedManifest()?.datasets == [DatasetSpec(file: "cases.csv", sampleSize: 3)])
        }
    }
}
