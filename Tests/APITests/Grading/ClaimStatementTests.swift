// Tests/APITests/Grading/ClaimStatementTests.swift
//
// The one-statement claim and the paged fresh scan, end to end: a job past
// the first page is claimed when every first-page job is held for another
// runner, the claimed submission decodes as a stored row, rows with no
// submission time still reach the second page, and a validation group still
// refuses a missing setup after its setups are read in one query.

import Fluent
import Foundation
import SQLKit
import Testing
import Vapor
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized) final class ClaimStatementTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-claim-statement")
    }

    private func setup(_ id: String, on app: Application) async throws {
        try await APITestSetup(
            id: id, manifest: TestManifests.workerOnePythonSuite,
            zipPath: app.testSetupsDirectory + "\(id).zip", courseID: try await app.testCourseID()
        ).save(on: app.db)
    }

    private func pending(
        _ id: String, setupID: String, kind: String = APISubmission.Kind.student, on app: Application
    ) async throws {
        try await APISubmission(
            id: id, testSetupID: setupID, zipPath: app.submissionsDirectory + "\(id).zip",
            attemptNumber: 1, status: SubmissionStatus.pending.rawValue, kind: kind
        ).save(on: app.db)
    }

    private func body(_ workerID: String) -> WorkerActivityPayload {
        WorkerActivityPayload(
            workerID: workerID, hostname: "host-\(workerID)", runnerVersion: "runner/1.0",
            maxConcurrentJobs: 1, activeJobs: 0)
    }

    @Test func aJobPastTheFirstPageIsClaimedWhenTheFirstPageIsHeld() async throws {
        try await withApp(app) { app in
            try await setup("setup_stmt", on: app)
            let pageSize = ClaimCandidateLoader.firstPageSize
            // The first page is held for another runner: queued just now, so
            // inside the target gate's fallback window.
            for index in 0..<pageSize {
                let id = String(cFormat: "sub_held_%02d", index)
                try await pending(id, setupID: "setup_stmt", on: app)
                try await APISubmission.query(on: app.db).filter(\.$id == id)
                    .set(\.$targetRunnerID, to: "someone-else")
                    .set(\.$submittedAt, to: Date().addingTimeInterval(-10 + Double(index) * 0.01))
                    .update()
            }
            try await pending("sub_free", setupID: "setup_stmt", on: app)

            let claimed = try await WorkerJobClaim.claimNextEligibleJob(
                body: body("runner-a"), runnerProfile: nil, reportsNoCompatibleRunner: false,
                db: app.db, application: app, logger: app.logger)
            #expect(claimed?.submission.id == "sub_free")
            #expect(claimed?.submission.status == SubmissionStatus.assigned.rawValue)
            #expect(claimed?.submission.workerID == "runner-a")
        }
    }

    @Test func theClaimedSubmissionDecodesAsAStoredRow() async throws {
        try await withApp(app) { app in
            try await setup("setup_stmt_row", on: app)
            try await pending("sub_row", setupID: "setup_stmt_row", on: app)

            let claimed = try #require(
                try await WorkerJobClaim.claimSubmission(id: "sub_row", workerID: "runner-b", db: app.db))
            #expect(claimed.$id.exists)
            #expect(claimed.assignedAt != nil)
            // A later save updates the row rather than inserting a second one.
            claimed.filename = "renamed.zip"
            try await claimed.save(on: app.db)
            #expect(try await APISubmission.query(on: app.db).filter(\.$id == "sub_row").count() == 1)

            // A second claim of the same row finds it no longer pending.
            let again = try await WorkerJobClaim.claimSubmission(id: "sub_row", workerID: "runner-c", db: app.db)
            #expect(again == nil)
        }
    }

    @Test func rowsWithNoSubmissionTimeReachTheSecondPage() async throws {
        try await withApp(app) { app in
            try await setup("setup_stmt_null", on: app)
            let pageSize = ClaimCandidateLoader.firstPageSize
            for index in 0..<pageSize {
                try await pending(String(cFormat: "sub_timed_%02d", index), setupID: "setup_stmt_null", on: app)
            }
            for index in 0..<3 {
                let id = "sub_untimed_\(index)"
                try await pending(id, setupID: "setup_stmt_null", on: app)
                try await APISubmission.query(on: app.db).filter(\.$id == id)
                    .set(\.$submittedAt, to: nil).update()
            }

            let read = try await collectClaimCandidates(on: app.db).compactMap { $0.0.id }
            #expect(read.count == pageSize + 3)
            #expect(Set(read).isSuperset(of: ["sub_untimed_0", "sub_untimed_1", "sub_untimed_2"]))
        }
    }

    @Test func aValidationRunWithAMissingSetupStillFails() async throws {
        try await withApp(app) { app in
            try await setup("setup_stmt_gone", on: app)
            try await pending(
                "sub_validation", setupID: "setup_stmt_gone", kind: APISubmission.Kind.validation, on: app)
            // The setup is gone under the submission, as a deletion race would
            // leave it: delete the setup without its cascade.
            try await app.db.transaction { tx in
                let txSQL = try #require(tx as? any SQLDatabase)
                try await txSQL.raw("SET LOCAL session_replication_role = replica").run()
                try await txSQL.raw("DELETE FROM test_setups WHERE id = 'setup_stmt_gone'").run()
            }

            var loader = ClaimCandidateLoader(db: app.db)
            await #expect(throws: WorkerJobError.self) {
                _ = try await loader.load(.solutionValidation)
            }
        }
    }
}
