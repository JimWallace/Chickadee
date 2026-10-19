// Tests/APITests/MCP/SetDatasetPartitionTests.swift
//
// MCP `set_dataset` stores a partition and reports it back
// (docs/datasets-course-library.md §4.11). A part count replaces the stored
// sample, an omitted one keeps the partition, 0 ends it, and a partition that
// cannot be stored is refused. An activity that ranks students refuses one.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

/// `set_dataset` reads the setup zip with `unzip`, so the suite has a time
/// limit.
@Suite(.serialized, .timeLimit(.minutes(5))) struct SetDatasetPartitionTests {

    /// A Python setup whose `cases.csv` has a sample of 2, or no dataset
    /// spec when `sampled` is false.
    private func fixture(
        on app: Application, code: String, activity: ActivityKind? = nil, sampled: Bool = true
    ) async throws -> APIAssignment {
        let courseID = try await makeTestCourse(on: app, code: code).requireID()
        let tester = try await makeTestUser(on: app, username: "\(code.lowercased())_tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        var props = TestProperties(testSuites: [TestSuiteEntry(tier: .pub, script: "test_a.sh")], language: .python)
        props.activity = activity.map { ClassActivity(kind: $0) }
        props.datasets = sampled ? [DatasetSpec(file: "cases.csv", sampleSize: 2)] : []
        let setupID = "setup_\(code.lowercased())"
        try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: try encodeManifest(props))
        try await writeZipFixture(
            at: app.testSetupsDirectory + setupID + ".zip",
            entries: [("test_a.sh", "exit 0\n"), ("cases.csv", "id,ward\n1,A\n2,B\n3,A\n4,B\n")])
        return try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID, title: "Registry")
    }

    private func set(
        _ app: Application, _ assignment: APIAssignment, code: String, sampleSize: Int? = nil, partCount: Int?,
        transforms: [SetDatasetTool.TransformInput]? = nil
    ) async throws -> SetDatasetTool.Output {
        try await SetDatasetTool().execute(
            .init(
                assignmentPublicID: assignment.publicID, filename: "cases.csv", sampleSize: sampleSize,
                stratumColumn: nil, remove: nil, transforms: transforms, partCount: partCount),
            ToolContext(
                request: makeTestRequest(on: app), subject: "\(code.lowercased())_tester",
                grantedScopes: [.read, .write]))
    }

    private func storedSpec(_ app: Application, code: String) async throws -> DatasetSpec {
        let setup = try #require(try await APITestSetup.find("setup_\(code.lowercased())", on: app.db))
        return try #require(setup.decodedManifest()?.datasetSpecsByFile["cases.csv"])
    }

    @Test func aPartCountReplacesTheSampleAndIsReportedBack() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, code: "PTN1")
            let out = try await set(app, assignment, code: "PTN1", partCount: 2)
            #expect(out.datasets.first?.kind == "partition")
            #expect(out.datasets.first?.partCount == 2)
            #expect(
                try await storedSpec(app, code: "PTN1")
                    == DatasetSpec(file: "cases.csv", kind: .partition, partCount: 2))
        }
    }

    @Test func anOmittedPartCountKeepsThePartitionAndZeroEndsIt() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, code: "PTN2")
            _ = try await set(app, assignment, code: "PTN2", partCount: 2)
            _ = try await set(
                app, assignment, code: "PTN2", partCount: nil,
                transforms: [.init(kind: "missingValues", columns: ["ward"], rate: 0.5)])
            #expect(try await storedSpec(app, code: "PTN2").partCount == 2)

            // 0 ends the partition; a sample then needs a size.
            await #expect(throws: MCPToolError.self) {
                _ = try await set(app, assignment, code: "PTN2", partCount: 0, transforms: [])
            }
            _ = try await set(app, assignment, code: "PTN2", sampleSize: 3, partCount: 0, transforms: [])
            #expect(try await storedSpec(app, code: "PTN2") == DatasetSpec(file: "cases.csv", sampleSize: 3))
        }
    }

    @Test func anUnusablePartitionIsRefused() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, code: "PTN3")
            // A sample beside a part count, and more parts than rows.
            await #expect(throws: MCPToolError.self) {
                _ = try await set(app, assignment, code: "PTN3", sampleSize: 2, partCount: 2)
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await set(app, assignment, code: "PTN3", partCount: 5)
            }
            #expect(try await storedSpec(app, code: "PTN3") == DatasetSpec(file: "cases.csv", sampleSize: 2))
        }
    }

    /// A partition gives each student their own rows, so an activity that
    /// ranks students refuses it, as it refuses a sample.
    @Test func aRankedActivityRefusesAPartition() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, code: "PTN4", activity: .bestMetric, sampled: false)
            await #expect(throws: MCPToolError.self) {
                _ = try await set(app, assignment, code: "PTN4", partCount: 2)
            }
            let setup = try #require(try await APITestSetup.find("setup_ptn4", on: app.db))
            #expect(setup.decodedManifest()?.datasets.isEmpty == true)
        }
    }
}
