// The class-wide union of covered items: one row per (assignment, item),
// attributed to the submission that covered it first.
//
// The properties asserted here are the ones the class goal will grade on, so
// they are the ones that must not be merely intended:
//
//   * FIRST-FINDER WINS and attribution never moves, so the number is monotone
//     and a re-test cannot rewrite history;
//   * ORDER INDEPENDENCE, so the same submissions in any order reach the same
//     final state — a ranking rule would break this, which is why the design
//     rejected one;
//   * ROSTER SCOPING, because an unscoped numerator is how the class-goal sweep
//     once granted unearned bonus points all the way to the LMS (audit A7).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct ClassItemCoverageTests {

    private func outcome(_ name: String, _ status: TestStatus) -> TestOutcome {
        TestOutcome(
            testName: name, testClass: nil, tier: .pub, status: status,
            shortResult: status.defaultShortResult, longResult: nil,
            executionTimeMs: 1, memoryUsageBytes: nil,
            attemptNumber: 1, isFirstPassSuccess: false)
    }

    /// A setup + assignment + two enrolled students, the shape every test needs.
    private func fixture(
        _ app: Application, prefix: String
    ) async throws -> (setupID: String, a: APIUser, b: APIUser) {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let setupID = "\(prefix)_setup"
        let setup = APITestSetup(
            id: setupID,
            manifest: #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#,
            zipPath: app.testSetupsDirectory + "\(setupID).zip",
            courseID: courseID)
        try await setup.save(on: app.db)
        // Title varies by prefix: the assignment slug is unique per course, and
        // one test builds two fixtures in the same course.
        _ = try await arInsertAssignment(
            testSetupID: setupID, title: "Bug Hunt \(prefix)", isOpen: true, on: app)

        let a = try await arInsertStudent(username: "\(prefix)_a", on: app)
        try await arEnrollStudentInTestCourse(a, on: app)
        let b = try await arInsertStudent(username: "\(prefix)_b", on: app)
        try await arEnrollStudentInTestCourse(b, on: app)
        return (setupID, a, b)
    }

    // MARK: - What counts as covered

    @Test func onlyPassingOutcomesAreCovered() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "onlypass")
            _ = try await arInsertSubmission(
                id: "onlypass_s1", testSetupID: fx.setupID, userID: try fx.a.requireID(), on: app)

            try await recordClassItemCoverage(
                testSetupID: fx.setupID, userID: try fx.a.requireID(),
                submissionID: "onlypass_s1",
                outcomes: [
                    outcome("variant_01", .pass), outcome("variant_02", .fail),
                    outcome("variant_03", .error), outcome("variant_04", .timeout),
                ],
                on: app.db)

            let rows = try await classItemCoverage(testSetupID: fx.setupID, on: app.db)
            #expect(rows.map(\.item) == ["variant_01"])
        }
    }

    /// Coverage is per item, not per student, so a submission that scores badly
    /// overall still contributes whatever it did cover.
    @Test func aLowScoringSubmissionStillContributesWhatItCovered() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "lowscore")
            _ = try await arInsertSubmission(
                id: "lowscore_s1", testSetupID: fx.setupID, userID: try fx.a.requireID(), on: app)

            var outcomes = [outcome("variant_07", .pass)]
            for index in 1...9 { outcomes.append(outcome("variant_1\(index)", .fail)) }
            try await recordClassItemCoverage(
                testSetupID: fx.setupID, userID: try fx.a.requireID(),
                submissionID: "lowscore_s1", outcomes: outcomes, on: app.db)

            let rows = try await classItemCoverage(testSetupID: fx.setupID, on: app.db)
            #expect(rows.map(\.item) == ["variant_07"])
        }
    }

    // MARK: - First finder wins, and keeps it

    @Test func theFirstSubmissionToCoverAnItemKeepsTheAttribution() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "firstwins")
            let aID = try fx.a.requireID()
            let bID = try fx.b.requireID()
            _ = try await arInsertSubmission(
                id: "firstwins_a", testSetupID: fx.setupID, userID: aID, on: app)
            _ = try await arInsertSubmission(
                id: "firstwins_b", testSetupID: fx.setupID, userID: bID, on: app)

            try await recordClassItemCoverage(
                testSetupID: fx.setupID, userID: aID, submissionID: "firstwins_a",
                outcomes: [outcome("variant_03", .pass)], on: app.db)
            try await recordClassItemCoverage(
                testSetupID: fx.setupID, userID: bID, submissionID: "firstwins_b",
                outcomes: [outcome("variant_03", .pass)], on: app.db)

            let rows = try await classItemCoverage(testSetupID: fx.setupID, on: app.db)
            #expect(rows.count == 1, "one item covered twice must not produce two rows")
            #expect(rows.first?.userID == aID, "attribution must stay with the first finder")
            #expect(rows.first?.submissionID == "firstwins_a")
        }
    }

    /// A re-test replays the same outcomes. Nothing may duplicate, and the
    /// original finder must keep the credit — the number can only go up.
    @Test func replayingASubmissionChangesNothing() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "replay")
            let aID = try fx.a.requireID()
            _ = try await arInsertSubmission(
                id: "replay_a", testSetupID: fx.setupID, userID: aID, on: app)

            let outcomes = [outcome("variant_01", .pass), outcome("variant_02", .pass)]
            for _ in 1...3 {
                try await recordClassItemCoverage(
                    testSetupID: fx.setupID, userID: aID, submissionID: "replay_a",
                    outcomes: outcomes, on: app.db)
            }

            let rows = try await classItemCoverage(testSetupID: fx.setupID, on: app.db)
            #expect(rows.map(\.item) == ["variant_01", "variant_02"])
        }
    }

    /// Order independence: the same two submissions, interleaved either way,
    /// reach the same final set. Only attribution differs, and only by who
    /// genuinely got there first.
    @Test func theFinalUnionDoesNotDependOnArrivalOrder() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "order")
            let aID = try fx.a.requireID()
            let bID = try fx.b.requireID()
            _ = try await arInsertSubmission(
                id: "order_a", testSetupID: fx.setupID, userID: aID, on: app)
            _ = try await arInsertSubmission(
                id: "order_b", testSetupID: fx.setupID, userID: bID, on: app)

            try await recordClassItemCoverage(
                testSetupID: fx.setupID, userID: bID, submissionID: "order_b",
                outcomes: [outcome("variant_02", .pass), outcome("variant_03", .pass)], on: app.db)
            try await recordClassItemCoverage(
                testSetupID: fx.setupID, userID: aID, submissionID: "order_a",
                outcomes: [outcome("variant_01", .pass), outcome("variant_02", .pass)], on: app.db)

            let rows = try await classItemCoverage(testSetupID: fx.setupID, on: app.db)
            #expect(rows.map(\.item) == ["variant_01", "variant_02", "variant_03"])
            // variant_02 was covered by B first, even though A submitted it too.
            let variant2 = try #require(rows.first { $0.item == "variant_02" })
            #expect(variant2.userID == bID)
        }
    }

    // MARK: - Roster scoping (audit A7)

    /// A staff member testing their own assignment must not appear in a number
    /// that carries bonus points to the LMS.
    @Test func aNonStudentContributesNoCoverage() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "staff")
            let staff = try await arInsertStudent(username: "staff_instructor", on: app)
            let staffID = try staff.requireID()
            _ = try await arInsertSubmission(
                id: "staff_s1", testSetupID: fx.setupID, userID: staffID, on: app)

            // Deliberately NOT enrolled as a student in the setup's course.
            try await recordClassItemCoverage(
                testSetupID: fx.setupID, userID: staffID, submissionID: "staff_s1",
                outcomes: [outcome("variant_01", .pass)], on: app.db)

            let rows = try await classItemCoverage(testSetupID: fx.setupID, on: app.db)
            #expect(rows.isEmpty)
        }
    }

    // MARK: - Degenerate inputs

    @Test func aSubmissionCoveringNothingWritesNothing() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "empty")
            let aID = try fx.a.requireID()
            _ = try await arInsertSubmission(
                id: "empty_s1", testSetupID: fx.setupID, userID: aID, on: app)

            try await recordClassItemCoverage(
                testSetupID: fx.setupID, userID: aID, submissionID: "empty_s1",
                outcomes: [outcome("variant_01", .fail)], on: app.db)
            try await recordClassItemCoverage(
                testSetupID: fx.setupID, userID: aID, submissionID: "empty_s1",
                outcomes: [], on: app.db)

            #expect(try await classItemCoverage(testSetupID: fx.setupID, on: app.db).isEmpty)
        }
    }

    /// Coverage is scoped per assignment: the same item name in another
    /// assignment is a different item.
    @Test func coverageIsScopedToItsAssignment() async throws {
        try await withAssignmentRoutesApp { app in
            let one = try await fixture(app, prefix: "scopeone")
            let two = try await fixture(app, prefix: "scopetwo")
            let aID = try one.a.requireID()
            _ = try await arInsertSubmission(
                id: "scope_s1", testSetupID: one.setupID, userID: aID, on: app)

            try await recordClassItemCoverage(
                testSetupID: one.setupID, userID: aID, submissionID: "scope_s1",
                outcomes: [outcome("variant_01", .pass)], on: app.db)

            #expect(try await classItemCoverage(testSetupID: one.setupID, on: app.db).count == 1)
            #expect(try await classItemCoverage(testSetupID: two.setupID, on: app.db).isEmpty)
        }
    }
}
