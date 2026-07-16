// Tests/APITests/SecretRevealStoreTests.swift
//
// Exercises the per-(user, assignment) secret-reveal token store: idempotent
// spend, staff re-grant, roster query, cascade delete, and the
// `SecretRevealState` resolver's gating rules.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class SecretRevealStoreTests {

    let app: Application

    init() async throws {
        app = try await makeTestingApplication { app in
            try await configureTestDatabase(app)
        }
    }

    // MARK: - Helpers

    private func makeUser(username: String) async throws -> APIUser {
        let user = APIUser(username: username, passwordHash: "x", role: "student")
        try await user.save(on: app.db)
        return user
    }

    private func makeAssignment(
        courseID: UUID, secretRevealEnabled: Bool = false
    ) async throws
        -> APIAssignment
    {
        let setupID = UUID().uuidString
        let testSetup = APITestSetup(
            id: setupID,
            manifest: "{}",
            zipPath: "/tmp/\(setupID).zip",
            courseID: courseID
        )
        try await testSetup.save(on: app.db)

        let assignment = APIAssignment(
            testSetupID: setupID,
            title: "Test Assignment \(setupID.prefix(6))",
            courseID: courseID
        )
        if secretRevealEnabled {
            assignment.secretRevealEnabled = true
        }
        try await assignment.save(on: app.db)
        return assignment
    }

    private func makeCourse() async throws -> APICourse {
        let course = APICourse(code: "TEST-\(UUID().uuidString.prefix(6))", name: "Test Course")
        try await course.save(on: app.db)
        return course
    }

    // MARK: - Store

    @Test func spendToken_createsRowAndIsIdempotent() async throws {
        try await withApp(app) { _ in
            let user = try await makeUser(username: "alice")
            let course = try await makeCourse()
            let assignment = try await makeAssignment(courseID: try course.requireID())
            let userID = try user.requireID()
            let assignmentID = try assignment.requireID()

            let before = try await SecretRevealStore.hasSpentToken(
                userID: userID, assignmentID: assignmentID, on: app.db)
            #expect(before == false)

            try await SecretRevealStore.spendToken(
                userID: userID, assignmentID: assignmentID, on: app.db)
            try await SecretRevealStore.spendToken(
                userID: userID, assignmentID: assignmentID, on: app.db)

            let spent = try await SecretRevealStore.hasSpentToken(
                userID: userID, assignmentID: assignmentID, on: app.db)
            #expect(spent)
            let rowCount = try await APISecretRevealUnlock.query(on: app.db)
                .filter(\.$userID == userID)
                .filter(\.$assignmentID == assignmentID)
                .count()
            #expect(rowCount == 1, "double-spend must not create a second row")
        }
    }

    @Test func regrantToken_deletesRowAndReportsExistence() async throws {
        try await withApp(app) { _ in
            let user = try await makeUser(username: "bob")
            let course = try await makeCourse()
            let assignment = try await makeAssignment(courseID: try course.requireID())
            let userID = try user.requireID()
            let assignmentID = try assignment.requireID()

            try await SecretRevealStore.spendToken(
                userID: userID, assignmentID: assignmentID, on: app.db)

            let first = try await SecretRevealStore.regrantToken(
                userID: userID, assignmentID: assignmentID, on: app.db)
            #expect(first, "re-grant of a spent token reports the deleted row")
            let second = try await SecretRevealStore.regrantToken(
                userID: userID, assignmentID: assignmentID, on: app.db)
            #expect(second == false, "re-grant with no spend row is a no-op")

            let spent = try await SecretRevealStore.hasSpentToken(
                userID: userID, assignmentID: assignmentID, on: app.db)
            #expect(spent == false)
        }
    }

    @Test func spentUserIDs_returnsExactlyTheSpenders() async throws {
        try await withApp(app) { _ in
            let alice = try await makeUser(username: "alice2")
            let bob = try await makeUser(username: "bob2")
            let carol = try await makeUser(username: "carol2")
            let course = try await makeCourse()
            let assignment = try await makeAssignment(courseID: try course.requireID())
            let other = try await makeAssignment(courseID: try course.requireID())
            let assignmentID = try assignment.requireID()

            try await SecretRevealStore.spendToken(
                userID: try alice.requireID(), assignmentID: assignmentID, on: app.db)
            try await SecretRevealStore.spendToken(
                userID: try bob.requireID(), assignmentID: assignmentID, on: app.db)
            // Carol spends on a different assignment — must not appear.
            try await SecretRevealStore.spendToken(
                userID: try carol.requireID(), assignmentID: try other.requireID(), on: app.db)

            let spenders = try await SecretRevealStore.spentUserIDs(
                assignmentID: assignmentID, on: app.db)
            #expect(spenders == Set([try alice.requireID(), try bob.requireID()]))
        }
    }

    @Test func spendRows_cascadeDeleteWithAssignment() async throws {
        try await withApp(app) { _ in
            let user = try await makeUser(username: "dave")
            let course = try await makeCourse()
            let assignment = try await makeAssignment(courseID: try course.requireID())
            let userID = try user.requireID()
            let assignmentID = try assignment.requireID()

            try await SecretRevealStore.spendToken(
                userID: userID, assignmentID: assignmentID, on: app.db)
            try await assignment.delete(on: app.db)

            let rowCount = try await APISecretRevealUnlock.query(on: app.db)
                .filter(\.$assignmentID == assignmentID)
                .count()
            #expect(rowCount == 0, "spend rows follow their assignment on delete")
        }
    }

    // MARK: - SecretRevealState.resolve

    @Test func resolve_revealedOnlyWhenEnabledAndSpent() async throws {
        try await withApp(app) { _ in
            let user = try await makeUser(username: "erin")
            let course = try await makeCourse()
            let assignment = try await makeAssignment(
                courseID: try course.requireID(), secretRevealEnabled: true)
            let userID = try user.requireID()

            let unspent = try await SecretRevealState.resolve(
                assignment: assignment, userID: userID, isStaff: false, on: app.db)
            #expect(unspent.enabled)
            #expect(unspent.spent == false)
            #expect(unspent.revealed == false)

            try await SecretRevealStore.spendToken(
                userID: userID, assignmentID: try assignment.requireID(), on: app.db)
            let spent = try await SecretRevealState.resolve(
                assignment: assignment, userID: userID, isStaff: false, on: app.db)
            #expect(spent.revealed)
        }
    }

    @Test func resolve_toggleOffHidesEvenWithSpendRow() async throws {
        try await withApp(app) { _ in
            let user = try await makeUser(username: "frank")
            let course = try await makeCourse()
            let assignment = try await makeAssignment(
                courseID: try course.requireID(), secretRevealEnabled: true)
            let userID = try user.requireID()
            try await SecretRevealStore.spendToken(
                userID: userID, assignmentID: try assignment.requireID(), on: app.db)

            // Instructor turns the toggle off: the reveal stops, but the spend
            // row survives so re-enabling restores it.
            assignment.secretRevealEnabled = false
            try await assignment.save(on: app.db)

            let state = try await SecretRevealState.resolve(
                assignment: assignment, userID: userID, isStaff: false, on: app.db)
            #expect(state.revealed == false)
            let stillSpent = try await SecretRevealStore.hasSpentToken(
                userID: userID, assignmentID: try assignment.requireID(), on: app.db)
            #expect(stillSpent, "toggle-off must not consume or delete the spend row")
        }
    }

    @Test func resolve_staffAndMissingInputsShortCircuit() async throws {
        try await withApp(app) { _ in
            let user = try await makeUser(username: "grace")
            let course = try await makeCourse()
            let assignment = try await makeAssignment(
                courseID: try course.requireID(), secretRevealEnabled: true)
            let userID = try user.requireID()
            try await SecretRevealStore.spendToken(
                userID: userID, assignmentID: try assignment.requireID(), on: app.db)

            let staff = try await SecretRevealState.resolve(
                assignment: assignment, userID: userID, isStaff: true, on: app.db)
            #expect(staff.revealed == false, "staff itemize secret anyway — state is .none")

            let noAssignment = try await SecretRevealState.resolve(
                assignment: nil, userID: userID, isStaff: false, on: app.db)
            #expect(noAssignment.revealed == false)

            let noUser = try await SecretRevealState.resolve(
                assignment: assignment, userID: nil, isStaff: false, on: app.db)
            #expect(noUser.revealed == false)
        }
    }
}
