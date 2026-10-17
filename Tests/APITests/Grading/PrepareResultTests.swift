// One result-row step for both ingest paths (#2259, item 5).
//
// The worker report and the browser result each encoded the collection, built
// the result row, flagged it for grade sync and saved it. The browser copy
// once skipped the flag, so notebook labs never reached LEARN on their own.
// `ResultIngestEffects.prepareResult` now encodes, builds and flags the row.
// Each route saves it inside its own transaction or retry.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized)
struct PrepareResultTests {

    private func collection(_ submissionID: String, setupID: String) -> TestOutcomeCollection {
        TestOutcomeCollection(
            submissionID: submissionID, testSetupID: setupID, attemptNumber: 1, buildStatus: .passed,
            compilerOutput: nil, outcomes: [wrMakeOutcome(name: "t1", status: .pass)], totalTests: 1,
            passCount: 1, failCount: 0, errorCount: 0, timeoutCount: 0, executionTimeMs: 50,
            runnerVersion: "test", timestamp: Date())
    }

    @Test(arguments: ["worker", "browser"])
    func thePreparedRowStoresWithItsSourceGradeAndCollection(source: String) async throws {
        try await withAssignmentRoutesApp { app in
            let setupID = "store_result_\(source)"
            _ = try await arInsertSetup(id: setupID, on: app)
            let student = try await arInsertStudent(username: "store_\(source)", on: app)
            let submission = try await arInsertSubmission(
                id: "store_sub_\(source)", testSetupID: setupID, userID: try student.requireID(), on: app)
            let submissionID = try submission.requireID()

            let prepared = try await ResultIngestEffects.prepareResult(
                collection(submissionID, setupID: setupID), source: source, testSetupID: setupID,
                application: app, on: app.db)
            try await prepared.row.saveWithCollection(json: prepared.json, on: app.db)

            let row = try #require(try await APIResult.find(try prepared.row.requireID(), on: app.db))
            #expect(row.submissionID == submissionID)
            #expect(row.source == source)
            #expect(row.passCount == 1)
            let json = try #require(try await row.loadCollectionJSON(on: app.db))
            #expect(json.contains(submissionID))
        }
    }

    /// Seeds a setup whose assignment is bound to a LEARN grade item, with a
    /// student submission, and returns the submission ID.
    private func seedBoundAssignment(_ prefix: String, on app: Application) async throws -> (String, String) {
        let setupID = "\(prefix)_setup"
        _ = try await arInsertSetup(id: setupID, on: app)
        let assignment = try await arInsertAssignment(
            testSetupID: setupID, title: "Bound lab", isOpen: true, on: app)
        assignment.brightspaceGradeObjectID = "777"
        try await assignment.save(on: app.db)
        let course = try #require(try await APICourse.find(assignment.courseID, on: app.db))
        course.brightspaceOrgUnitID = "12345"
        try await course.save(on: app.db)
        let student = try await arInsertStudent(username: "\(prefix)_student", on: app)
        let submission = try await arInsertSubmission(
            id: "\(prefix)_sub", testSetupID: setupID, userID: try student.requireID(), on: app)
        return (setupID, try submission.requireID())
    }

    /// The prepared row is marked for grade sync. This is the step the
    /// browser copy once skipped.
    @Test func thePreparedRowIsMarkedForGradeSync() async throws {
        try await withAssignmentRoutesApp { app in
            app.brightSpaceAppCredentials = BrightSpaceAppCredentials(
                baseURL: "https://learn.test", appID: "a", appKey: "k", debounceSecs: 90)
            let (setupID, submissionID) = try await seedBoundAssignment("prep_flag", on: app)

            let prepared = try await ResultIngestEffects.prepareResult(
                collection(submissionID, setupID: setupID), source: "browser", testSetupID: setupID,
                application: app, on: app.db)

            #expect(prepared.row.brightspaceSyncPending == true)
            #expect(prepared.row.brightspacePendingSince != nil)
        }
    }

    /// With no BrightSpace configuration the row is not marked, so the flag
    /// above comes from the deployment's binding and not from a default.
    @Test func thePreparedRowIsNotMarkedWithoutBrightSpace() async throws {
        try await withAssignmentRoutesApp { app in
            app.brightSpaceAppCredentials = nil
            let (setupID, submissionID) = try await seedBoundAssignment("prep_noflag", on: app)

            let prepared = try await ResultIngestEffects.prepareResult(
                collection(submissionID, setupID: setupID), source: "worker", testSetupID: setupID,
                application: app, on: app.db)

            #expect(prepared.row.brightspaceSyncPending != true)
        }
    }

    /// The ingest routes must build their row through the shared step. A
    /// route that builds its own result row is how the browser path lost the
    /// grade-sync flag.
    @Test func theIngestRoutesBuildTheirRowThroughTheSharedStep() throws {
        for path in [
            "Sources/APIServer/Routes/ResultRoutes.swift", "Sources/APIServer/Routes/BrowserResultRoutes.swift",
        ] {
            let code = try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(code.contains("ResultIngestEffects.prepareResult("), "\(path) does not call prepareResult.")
            #expect(!code.contains("APIResult("), "\(path) builds its own result row.")
            #expect(!code.contains("requestGradePush("), "\(path) flags its own result row.")
        }
    }
}
