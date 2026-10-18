// Tests/APITests/MCP/SetDatasetFormatNoiseTests.swift
//
// MCP `set_dataset` stores a `formatNoise` step and reports it back, and the
// save-time check refuses one that names a column the file lacks
// (docs/datasets.md, "formatNoise").

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

/// `set_dataset` reads the setup zip with `unzip`, so the suite has a time
/// limit.
@Suite(.serialized, .timeLimit(.minutes(5))) struct SetDatasetFormatNoiseTests {

    private func fixture(on app: Application) async throws -> APIAssignment {
        let courseID = try await makeTestCourse(on: app, code: "FMN1").requireID()
        let tester = try await makeTestUser(on: app, username: "fmn_tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        let manifest = """
            {"schemaVersion":1,"testSuites":[{"tier":"public","script":"test_a.sh","points":1}],"timeLimitSeconds":10}
            """
        try await makeTestSetup(on: app, id: "setup_fmn", courseID: courseID, manifest: manifest)
        try await writeZipFixture(
            at: app.testSetupsDirectory + "setup_fmn.zip",
            entries: [("test_a.sh", "exit 0\n"), ("cases.csv", "id,ward\n1,Ward A\n2,Ward B\n3,Ward A\n4,Ward B\n")])
        return try await makeTestAssignment(on: app, testSetupID: "setup_fmn", courseID: courseID, title: "Lab 4")
    }

    private func set(
        _ app: Application, _ assignment: APIAssignment, columns: [String]
    ) async throws -> SetDatasetTool.Output {
        try await SetDatasetTool().execute(
            .init(
                assignmentPublicID: assignment.publicID, filename: "cases.csv", sampleSize: 4, stratumColumn: nil,
                remove: nil, transforms: [.init(kind: "formatNoise", columns: columns, rate: 0.5)]),
            ToolContext(request: makeTestRequest(on: app), subject: "fmn_tester", grantedScopes: [.read, .write]))
    }

    @Test func aNoiseStepIsStoredAndReportedBack() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let out = try await set(app, assignment, columns: ["ward"])
            #expect(out.datasets.first?.transforms.map(\.kind) == ["formatNoise"])
            let setup = try #require(try await APITestSetup.find("setup_fmn", on: app.db))
            let spec = try #require(setup.decodedManifest()?.datasetSpecsByFile["cases.csv"])
            #expect(spec.transforms == [DatasetTransform(kind: .formatNoise, columns: ["ward"], rate: 0.5)])
        }
    }

    @Test func aNoiseStepOnAColumnTheFileLacksIsRefused() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) { _ = try await set(app, assignment, columns: ["pulse"]) }
        }
    }
}
