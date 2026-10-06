// Tests/APITests/CreateIgnoringConflictTests.swift
//
// "First insert wins" ignores only a constraint failure (#2300). Every other
// error reaches the caller, so the lock retry around the result side
// effects can see a stale snapshot instead of losing the row.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct InsertConflictClassifierTests {

    private struct FakeDatabaseError: DatabaseError, Error {
        var isSyntaxError: Bool { false }
        let isConstraintFailure: Bool
        var isConnectionClosed: Bool { false }
    }

    private struct OtherError: Error {}

    @Test func aConstraintFailureIsAConflict() {
        #expect(isInsertConflict(FakeDatabaseError(isConstraintFailure: true)))
    }

    @Test func anyOtherDatabaseErrorIsNot() {
        #expect(!isInsertConflict(FakeDatabaseError(isConstraintFailure: false)))
    }

    @Test func aNonDatabaseErrorIsNot() {
        #expect(!isInsertConflict(OtherError()))
    }
}

@Suite(.serialized) final class CreateIgnoringConflictTests {

    let app: Application

    init() async throws {
        app = try await makeTestApp()
    }

    /// A second leaderboard row for the same student and assignment hits the
    /// unique index. The helper returns, and the first row stays.
    @Test func aDuplicateRowIsIgnoredAndTheFirstStays() async throws {
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CIC101")
            try await makeTestSetup(on: app, id: "cic_setup", courseID: try course.requireID())
            let userID = try await makeTestUser(on: app, username: "cic_student").requireID()
            try await makeTestSubmission(on: app, id: "cic_sub_1", setupID: "cic_setup", userID: userID)
            try await makeTestSubmission(on: app, id: "cic_sub_2", setupID: "cic_setup", userID: userID)

            try await APILeaderboardEntry(
                testSetupID: "cic_setup", userID: userID, submissionID: "cic_sub_1", metric: 1, reachedAt: Date()
            ).createIgnoringConflict(on: app.db)
            try await APILeaderboardEntry(
                testSetupID: "cic_setup", userID: userID, submissionID: "cic_sub_2", metric: 2, reachedAt: Date()
            ).createIgnoringConflict(on: app.db)

            let rows = try await APILeaderboardEntry.query(on: app.db)
                .filter(\.$testSetupID == "cic_setup").all()
            #expect(rows.map(\.submissionID) == ["cic_sub_1"])
        }
    }
}
