// Tests/APITests/StuckSubmissionReaperTests.swift
//
// reapStuckAssignedSubmissions: `assigned` rows older than the cutoff return
// to `pending` (worker cleared) in one bulk UPDATE; fresh rows are untouched.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized) final class StuckSubmissionReaperTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-reaper")
    }

    @discardableResult
    private func insertAssignedSubmission(
        id: String,
        workerID: String,
        assignedAt: Date
    ) async throws -> APISubmission {
        let setupID = "setup_reaper"
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
            status: SubmissionStatus.assigned.rawValue
        )
        sub.workerID = workerID
        sub.assignedAt = assignedAt
        try await sub.save(on: app.db)
        return sub
    }

    @Test func reapsOnlySubmissionsOlderThanCutoff() async throws {
        try await withApp(app) { _ in
            let now = Date()
            try await insertAssignedSubmission(
                id: "sub_stuck_old1", workerID: "w_dead",
                assignedAt: now.addingTimeInterval(-20 * 60))
            try await insertAssignedSubmission(
                id: "sub_stuck_old2", workerID: "w_dead",
                assignedAt: now.addingTimeInterval(-15 * 60))
            try await insertAssignedSubmission(
                id: "sub_stuck_fresh", workerID: "w_alive",
                assignedAt: now.addingTimeInterval(-60))

            let reaped = try await reapStuckAssignedSubmissions(
                on: app.db, logger: app.logger, now: now)
            #expect(reaped == 2)

            let old1 = try #require(try await APISubmission.find("sub_stuck_old1", on: app.db))
            #expect(old1.status == SubmissionStatus.pending.rawValue)
            #expect(old1.workerID == nil)
            #expect(old1.assignedAt == nil)

            let old2 = try #require(try await APISubmission.find("sub_stuck_old2", on: app.db))
            #expect(old2.status == SubmissionStatus.pending.rawValue)

            let fresh = try #require(try await APISubmission.find("sub_stuck_fresh", on: app.db))
            #expect(fresh.status == SubmissionStatus.assigned.rawValue)
            #expect(fresh.workerID == "w_alive")
            #expect(fresh.assignedAt != nil)
        }
    }

    @Test func reapWithNothingStuckIsANoOp() async throws {
        try await withApp(app) { _ in
            let now = Date()
            try await insertAssignedSubmission(
                id: "sub_noop_fresh", workerID: "w_alive",
                assignedAt: now.addingTimeInterval(-30))

            let reaped = try await reapStuckAssignedSubmissions(
                on: app.db, logger: app.logger, now: now)
            #expect(reaped == 0)

            let fresh = try #require(try await APISubmission.find("sub_noop_fresh", on: app.db))
            #expect(fresh.status == SubmissionStatus.assigned.rawValue)
        }
    }
}
