// Tests/APITests/ActivityUnionTests.swift
//
// The union reading of a matrix activity (docs/class-activities.md, "Tests
// and code"): the same completed match rows read as what each student's
// tests defeated and as how each student's own code held up.
//
// The rules pinned here are the ones `ActivityUnion.swift` documents — a
// kill stays with its author after the target fixes the fault, a defence
// counts only the code that stands today, untested code is neither holding
// nor defeated, and a union kind writes no standings row.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct ActivityUnionTests {

    private func outcome(_ name: String, metric: Double?, status: TestStatus = .pass) -> TestOutcome {
        TestOutcome(
            testName: name, testClass: nil, tier: .pub, status: status,
            shortResult: status.defaultShortResult, longResult: nil, score: status == .pass ? 1 : 0,
            metric: metric, executionTimeMs: 1, memoryUsageBytes: nil,
            attemptNumber: 1, isFirstPassSuccess: false)
    }

    private func unionManifest() throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            activity: ClassActivity(kind: .testsVersusImplementations))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    private struct Fixture {
        let setup: APITestSetup
        let activity: ClassActivity
        let a: APIUser
        let b: APIUser
        let c: APIUser
        var setupID: String { setup.id ?? "" }
    }

    private func fixture(_ app: Application, prefix: String) async throws -> Fixture {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let setupID = "\(prefix)_setup"
        let setup = APITestSetup(
            id: setupID, manifest: try unionManifest(),
            zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID)
        try await setup.save(on: app.db)
        _ = try await arInsertAssignment(testSetupID: setupID, title: "Lab \(prefix)", isOpen: true, on: app)
        var users: [APIUser] = []
        for name in ["a", "b", "c"] {
            let user = try await arInsertStudent(username: "\(prefix)_\(name)", on: app)
            try await arEnrollStudentInTestCourse(user, on: app)
            users.append(user)
        }
        return Fixture(
            setup: setup, activity: try #require(setup.decodedManifest()?.activity),
            a: users[0], b: users[1], c: users[2])
    }

    /// Runs one student's job the way the claim and result paths do: choose
    /// the classmates, open a row each, then land a verdict per opponent.
    /// `defeats` names the opponent submissions this student's tests killed.
    private func play(
        _ app: Application, fx: Fixture, user: APIUser, submissionID: String, defeats: Set<String>
    ) async throws {
        let submission: APISubmission
        if let existing = try await APISubmission.find(submissionID, on: app.db) {
            submission = existing
        } else {
            submission = try await arInsertSubmission(
                id: submissionID, testSetupID: fx.setupID, userID: try user.requireID(), on: app)
        }
        let chosen = try await chooseClassmates(for: submission, activity: fx.activity, on: app.db)
        var reports: [MatchReport] = []
        for opponent in chosen {
            let seed = JobOpponent.matchSeed(
                submissionID: submissionID, opponentIdentity: opponent.identity)
            try await openMatch(
                testSetupID: fx.setupID, submissionID: submissionID, opponent: opponent,
                seed: seed, on: app.db)
            let won = defeats.contains(opponent.champion?.id ?? "")
            reports.append(
                MatchReport(
                    opponentIdentity: opponent.identity, opponentSubmissionID: opponent.champion?.id,
                    seed: seed, score: won ? 1 : 0, metric: won ? 1 : 0, won: won))
        }
        try await recordActivityMatch(
            testSetupID: fx.setupID, userID: try user.requireID(), submissionID: submissionID,
            outcomes: [outcome("match", metric: reports.isEmpty ? nil : 1)],
            matches: reports.isEmpty ? nil : reports, on: app.db)
    }

    private func tally(_ app: Application, _ fx: Fixture) async throws -> UnionTally {
        try await unionTally(setup: fx.setup, on: app.db)
    }

    private func kill(_ tally: UnionTally, _ user: APIUser) throws -> UnionKillTally {
        let id = try user.requireID()
        return try #require(tally.kills.first { $0.userID == id })
    }

    private func defence(_ tally: UnionTally, _ user: APIUser) throws -> UnionDefenceTally {
        let id = try user.requireID()
        return try #require(tally.defences.first { $0.userID == id })
    }

    // MARK: - Reading one round of matches both ways

    /// A defeats B and not C; the same rows give A two tests run and one
    /// kill, and give B a defeat while C keeps holding.
    @Test func oneJobIsReadAsBothAKillAndADefeat() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "read")
            _ = try await arInsertSubmission(
                id: "read_b1", testSetupID: fx.setupID, userID: try fx.b.requireID(), on: app)
            _ = try await arInsertSubmission(
                id: "read_c1", testSetupID: fx.setupID, userID: try fx.c.requireID(), on: app)
            try await play(app, fx: fx, user: fx.a, submissionID: "read_a1", defeats: ["read_b1"])

            let tally = try await tally(app, fx)
            #expect(tally.targetCount == 3)
            #expect(tally.defeatedCount == 1)

            let aKills = try kill(tally, fx.a)
            #expect(aKills.defeated == 1)
            #expect(aKills.faced == 2)
            // B and C have not run their own tests yet.
            #expect(try kill(tally, fx.b).faced == 0)
            #expect(try kill(tally, fx.c).defeated == 0)

            let bCode = try defence(tally, fx.b)
            #expect(bCode.defeated)
            #expect(bCode.faced == 1)
            #expect(bCode.defeatedByUserID == (try fx.a.requireID()))

            let cCode = try defence(tally, fx.c)
            #expect(!cCode.defeated)
            #expect(cCode.faced == 1)

            // A's own code has faced nobody: neither holding nor defeated.
            let aCode = try defence(tally, fx.a)
            #expect(!aCode.defeated)
            #expect(aCode.faced == 0)

            // Best first, both ways: A leads the tests, A and C lead the code.
            #expect(tally.kills.first?.userID == (try fx.a.requireID()))
            #expect(tally.defences.last?.userID == (try fx.b.requireID()))
        }
    }

    /// A union kind writes no standings row and moves no standings record:
    /// a stored number would answer only the tester's half.
    @Test func aUnionKindMaterialisesNoStandings() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "nostand")
            _ = try await arInsertSubmission(
                id: "nostand_b1", testSetupID: fx.setupID, userID: try fx.b.requireID(), on: app)
            try await play(app, fx: fx, user: fx.a, submissionID: "nostand_a1", defeats: ["nostand_b1"])

            #expect(try await APIActivityStanding.query(on: app.db).count() == 0)
            #expect(
                try await APIClassAchievement.query(on: app.db)
                    .filter(\.$achievementID == ActivityAuthoring.seededWinnerRecordID).count() == 0)
            // The rows themselves still completed — the union reads them.
            let rows = try await APIMatchResult.query(on: app.db)
                .filter(\.$submissionID == "nostand_a1").all()
            #expect(rows.count == 1)
            #expect(rows.first?.won == true)
            #expect(rows.first?.completedAt != nil)
        }
    }

    // MARK: - The asymmetry between a kill and a defence

    /// A kill stays with the student whose test found the fault after the
    /// author resubmits; the author's fresh code is untested again.
    @Test func aKillSurvivesTheTargetsResubmissionButTheDefenceDoesNot() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "resub")
            _ = try await arInsertSubmission(
                id: "resub_b1", testSetupID: fx.setupID, userID: try fx.b.requireID(), on: app)
            _ = try await arInsertSubmission(
                id: "resub_c1", testSetupID: fx.setupID, userID: try fx.c.requireID(), on: app)
            try await play(app, fx: fx, user: fx.a, submissionID: "resub_a1", defeats: ["resub_b1"])
            #expect(try await tally(app, fx).defeatedCount == 1)

            // B fixes the fault and resubmits.
            _ = try await arInsertSubmission(
                id: "resub_b2", testSetupID: fx.setupID, userID: try fx.b.requireID(),
                attemptNumber: 2, on: app)

            let tally = try await tally(app, fx)
            #expect(try kill(tally, fx.a).defeated == 1, "A's test still found that fault")
            #expect(try kill(tally, fx.a).faced == 2)
            let bCode = try defence(tally, fx.b)
            #expect(!bCode.defeated, "the code that stands today has not been defeated")
            #expect(bCode.faced == 0)
            #expect(bCode.submissionID == "resub_b2")
            #expect(tally.defeatedCount == 0)
            #expect(tally.targetCount == 3)
        }
    }

    /// A student's own earlier submission is not a target of their own
    /// tests, and staff never enter either half.
    @Test func aStudentNeverTestsThemselvesAndStaffNeverAppear() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "self")
            _ = try await arInsertSubmission(
                id: "self_a0", testSetupID: fx.setupID, userID: try fx.a.requireID(), on: app)
            _ = try await arInsertSubmission(
                id: "self_b1", testSetupID: fx.setupID, userID: try fx.b.requireID(), on: app)
            let ta = try await arInsertStudent(username: "self_ta", on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            try await APICourseEnrollment(userID: try ta.requireID(), courseID: courseID, role: .ta)
                .save(on: app.db)
            _ = try await arInsertSubmission(
                id: "self_ta1", testSetupID: fx.setupID, userID: try ta.requireID(), on: app)

            try await play(
                app, fx: fx, user: fx.a, submissionID: "self_a1",
                defeats: ["self_a0", "self_b1", "self_ta1"])

            let tally = try await tally(app, fx)
            #expect(try kill(tally, fx.a).faced == 1, "only B is a classmate to test")
            #expect(try kill(tally, fx.a).defeated == 1)
            // A and B have code; C never submitted and the TA is not a
            // student, so neither is a target.
            #expect(tally.targetCount == 2)
            #expect(!tally.defences.contains { $0.userID == (try? ta.requireID()) })
            #expect(!tally.kills.contains { $0.userID == (try? ta.requireID()) })
        }
    }

    /// An assignment nobody has submitted to reads as nothing rather than
    /// as everybody holding.
    @Test func anUntouchedAssignmentHasNoUnion() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "empty")
            let tally = try await tally(app, fx)
            #expect(tally.targetCount == 0)
            #expect(tally.defeatedCount == 0)
            #expect(tally.kills.isEmpty)
            #expect(tally.defences.isEmpty)
        }
    }
}
