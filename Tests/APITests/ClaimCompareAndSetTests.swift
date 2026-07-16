// Tests/APITests/ClaimCompareAndSetTests.swift
//
// atomicallyClaimSubmission is the atomic claim at the heart of the job
// hand-out. On SQLite it is a compare-and-set (#1153): the UPDATE's
// `status == pending` guard means concurrent claimers cannot both win. On
// Postgres it is a `FOR UPDATE SKIP LOCKED` row lock in a short transaction
// (#1172). Either way a lost race returns nil and leaves the winner's row
// untouched — these tests pin that contract on whichever backend the suite
// runs against (SQLite on api-tests, Postgres on api-tests-postgres). The
// endpoint-level race is covered by
// WorkerRoutesTests.requestJob_concurrentClaims_onlyOneSucceeds.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized) final class ClaimCompareAndSetTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-claimcas")
    }

    private func seedPendingSubmission(id: String) async throws {
        let setupID = "setup_cas"
        if try await APITestSetup.find(setupID, on: app.db) == nil {
            let courseID = try await app.testCourseID()
            let setup = APITestSetup(
                id: setupID,
                manifest:
                    #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"tests.py"}],"timeLimitSeconds":10,"makefile":null}"#,
                zipPath: app.testSetupsDirectory + "\(setupID).zip",
                courseID: courseID
            )
            try await setup.save(on: app.db)
        }
        let sub = APISubmission(
            id: id,
            testSetupID: setupID,
            zipPath: app.submissionsDirectory + "\(id).zip",
            attemptNumber: 1,
            status: SubmissionStatus.pending.rawValue
        )
        try await sub.save(on: app.db)
    }

    private func makeRequest() -> Request {
        Request(
            application: app,
            method: .POST,
            url: URI(path: "/api/v1/worker/request"),
            on: app.eventLoopGroup.next()
        )
    }

    private func payload(workerID: String) -> WorkerActivityPayload {
        WorkerActivityPayload(
            workerID: workerID,
            hostname: "host-\(workerID)",
            runnerVersion: "runner/1.0",
            maxConcurrentJobs: 1,
            activeJobs: 0,
            profile: nil
        )
    }

    @Test func pendingSubmissionIsClaimedAndStamped() async throws {
        try await withApp(app) { _ in
            try await seedPendingSubmission(id: "sub_cas_win")

            let claimed = try await WorkerJobRoutes().atomicallyClaimSubmission(
                id: "sub_cas_win", req: makeRequest(), body: payload(workerID: "w1"))

            let row = try #require(claimed)
            #expect(row.status == SubmissionStatus.assigned.rawValue)
            #expect(row.workerID == "w1")
            #expect(row.assignedAt != nil)
        }
    }

    @Test func lostRaceReturnsNilAndLeavesWinnerUntouched() async throws {
        try await withApp(app) { _ in
            try await seedPendingSubmission(id: "sub_cas_race")
            let routes = WorkerJobRoutes()

            let first = try await routes.atomicallyClaimSubmission(
                id: "sub_cas_race", req: makeRequest(), body: payload(workerID: "w1"))
            #expect(first != nil)

            // Second claimer arrives after the CAS flipped the row — must
            // lose without disturbing the winner's stamp.
            let second = try await routes.atomicallyClaimSubmission(
                id: "sub_cas_race", req: makeRequest(), body: payload(workerID: "w2"))
            #expect(second == nil)

            let row = try #require(try await APISubmission.find("sub_cas_race", on: app.db))
            #expect(row.status == SubmissionStatus.assigned.rawValue)
            #expect(row.workerID == "w1")
        }
    }

    @Test func unknownSubmissionReturnsNil() async throws {
        try await withApp(app) { _ in
            let claimed = try await WorkerJobRoutes().atomicallyClaimSubmission(
                id: "sub_cas_missing", req: makeRequest(), body: payload(workerID: "w1"))
            #expect(claimed == nil)
        }
    }
}
