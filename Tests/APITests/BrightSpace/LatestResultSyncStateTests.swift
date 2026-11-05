// Tests/APITests/BrightSpace/LatestResultSyncStateTests.swift
//
// #2882: the LEARN sync summary counts each student by their latest result row,
// which Postgres now picks with DISTINCT ON. These tests give students rows
// whose states disagree, so a wrong pick changes the count.

import Fluent
import Foundation
import SQLKit
import Testing
import Vapor
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized, .timeLimit(.minutes(2)))
final class LatestResultSyncStateTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-latestsync")
    }

    private static let synced = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Seeded {
        let setupID: String
        let users: [UUID]
    }

    private func seedCourse(studentCount: Int) async throws -> Seeded {
        let course = APICourse(code: "SYNC101", name: "Latest Sync Course")
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        let setupID = "setup_latestsync"
        try await APITestSetup(
            id: setupID, manifest: TestManifests.workerOnePythonSuite,
            zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID
        ).save(on: app.db)
        var users: [UUID] = []
        for index in 0..<studentCount {
            let user = APIUser(username: "latestsync-\(index)", passwordHash: "", role: UserRole.user.rawValue)
            try await user.save(on: app.db)
            users.append(try user.requireID())
        }
        return Seeded(setupID: setupID, users: users)
    }

    /// One submission with one result. `receivedAt` is written after the
    /// insert, because the model stamps it on create; nil stores NULL.
    private func addResult(
        _ id: String, setupID: String, userID: UUID?, receivedAt: Date?, errored: Bool
    ) async throws {
        try await APISubmission(
            id: "sub_\(id)", testSetupID: setupID,
            zipPath: app.submissionsDirectory + "sub_\(id).zip",
            attemptNumber: 1, status: SubmissionStatus.complete.rawValue, userID: userID
        ).create(on: app.db)
        let result = APIResult(id: "res_\(id)", submissionID: "sub_\(id)")
        if errored {
            result.brightspaceSyncError = "LEARN refused the grade"
        } else {
            result.brightspaceSyncedAt = Self.synced
        }
        try await result.create(on: app.db)
        let sql = try #require(app.db as? (any SQLDatabase))
        try await sql.raw(
            "UPDATE results SET received_at = \(bind: receivedAt) WHERE id = \(bind: "res_\(id)")"
        ).run()
    }

    @Test func eachStudentIsCountedByTheirNewestResult() async throws {
        try await withApp(app) { app in
            let seeded = try await seedCourse(studentCount: 3)
            let older = Date(timeIntervalSince1970: 1_700_000_100)
            let newer = Date(timeIntervalSince1970: 1_700_000_200)
            // Errored first, then synced: synced.
            try await addResult(
                "a1", setupID: seeded.setupID, userID: seeded.users[0], receivedAt: older, errored: true)
            try await addResult(
                "a2", setupID: seeded.setupID, userID: seeded.users[0], receivedAt: newer, errored: false)
            // Synced first, then errored: errored.
            try await addResult(
                "b1", setupID: seeded.setupID, userID: seeded.users[1], receivedAt: older, errored: false)
            try await addResult(
                "b2", setupID: seeded.setupID, userID: seeded.users[1], receivedAt: newer, errored: true)
            // A row with no receipt time ranks below any dated row: errored.
            try await addResult("c1", setupID: seeded.setupID, userID: seeded.users[2], receivedAt: nil, errored: false)
            try await addResult(
                "c2", setupID: seeded.setupID, userID: seeded.users[2], receivedAt: older, errored: true)
            // A submission with no student is not counted.
            try await addResult("d1", setupID: seeded.setupID, userID: nil, receivedAt: newer, errored: true)

            let latest = try await BrightSpacePagePresenter.latestResultSyncStates(
                setupIDs: [seeded.setupID], on: app.db)
            #expect(latest.count == 3)
            let (summary, perSetup) = try await BrightSpacePagePresenter.syncSummary(
                courseUUID: UUID(), setupIDs: [seeded.setupID], on: app.db)
            #expect(summary.synced == 1)
            #expect(summary.errored == 2)
            #expect(summary.pending == 0)
            #expect(perSetup[seeded.setupID]?.synced == 1)
            #expect(perSetup[seeded.setupID]?.errored == 2)
        }
    }

    @Test func noSetupsReadsNothing() async throws {
        try await withApp(app) { app in
            let latest = try await BrightSpacePagePresenter.latestResultSyncStates(setupIDs: [], on: app.db)
            #expect(latest.isEmpty)
        }
    }
}
