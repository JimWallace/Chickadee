// Tests/APITests/ActivityChampionTests.swift
//
// The hill (docs/class-activities.md, "King of the hill"): who a challenger
// plays, and how a landed result moves the hill. The rules pinned here are
// the ones `recordActivityMatch` documents — a replayed report is a no-op, a
// re-test of the champion never dethrones by itself, a stale-champion win
// crowns nobody, a champion's own better entry moves the hill forward, a
// loss to the champion counts a defence, and only an enrolled student can
// hold the hill.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct ActivityChampionTests {

    private func outcome(
        _ name: String, metric: Double?, status: TestStatus = .pass, score: Double = 1
    )
        -> TestOutcome
    {
        TestOutcome(
            testName: name, testClass: nil, tier: .pub, status: status,
            shortResult: status.defaultShortResult, longResult: nil, score: score, metric: metric,
            executionTimeMs: 1, memoryUsageBytes: nil,
            attemptNumber: 1, isFirstPassSuccess: false)
    }

    private func hillManifest(opponentFile: String? = nil) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            activity: ClassActivity(kind: .kingOfTheHill, opponentFile: opponentFile),
            achievements: [ActivityAuthoring.seededChampionRecord])
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    /// A hill setup plus two enrolled students.
    private struct HillFixture {
        let setup: APITestSetup
        let activity: ClassActivity
        let a: APIUser
        let b: APIUser
    }

    private func fixture(
        _ app: Application, prefix: String, manifest: String
    ) async throws -> HillFixture {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let setupID = "\(prefix)_setup"
        let setup = APITestSetup(
            id: setupID, manifest: manifest,
            zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID)
        try await setup.save(on: app.db)
        _ = try await arInsertAssignment(testSetupID: setupID, title: "Hill \(prefix)", isOpen: true, on: app)
        let a = try await arInsertStudent(username: "\(prefix)_a", on: app)
        try await arEnrollStudentInTestCourse(a, on: app)
        let b = try await arInsertStudent(username: "\(prefix)_b", on: app)
        try await arEnrollStudentInTestCourse(b, on: app)
        return HillFixture(setup: setup, activity: try #require(setup.decodedManifest()?.activity), a: a, b: b)
    }

    /// Runs one challenger's job the way the claim and result paths do:
    /// choose the opponent, open the row, then land `outcomes`.
    @discardableResult
    private func play(
        _ app: Application, setup: APITestSetup, activity: ClassActivity, user: APIUser,
        submissionID: String, outcomes: [TestOutcome]
    ) async throws -> ChosenOpponent {
        let existing = try await APISubmission.find(submissionID, on: app.db)
        let submission: APISubmission
        if let existing {
            submission = existing
        } else {
            submission = try await arInsertSubmission(
                id: submissionID, testSetupID: try setup.requireID(), userID: try user.requireID(), on: app)
        }
        let chosen = try await chooseOpponent(for: submission, activity: activity, on: app.db)
        try await openMatch(
            testSetupID: try setup.requireID(), submissionID: submissionID, opponent: chosen,
            seed: JobOpponent.matchSeed(submissionID: submissionID, opponentIdentity: chosen.identity),
            on: app.db)
        try await recordActivityMatch(
            testSetupID: try setup.requireID(), userID: try user.requireID(), submissionID: submissionID,
            outcomes: outcomes, on: app.db)
        return chosen
    }

    private func champion(_ app: Application, _ setup: APITestSetup) async throws -> APIActivityChampion? {
        try await currentChampion(testSetupID: try setup.requireID(), on: app.db)
    }

    private func championRecord(_ app: Application, _ setup: APITestSetup) async throws -> APIClassAchievement? {
        try await APIClassAchievement.query(on: app.db)
            .filter(\.$testSetupID == (try setup.requireID()))
            .filter(\.$achievementID == ActivityAuthoring.seededChampionRecordID)
            .first()
    }

    private let win = "w"
    private let loss = "l"

    // MARK: - The match entry

    @Test func theMatchEntryIsTheHighestMetricOutcome() {
        let entries = [outcome("gate", metric: nil), outcome("m", metric: 3, status: .fail), outcome("n", metric: 9)]
        #expect(matchOutcome(from: entries)?.testName == "n")
        #expect(matchOutcome(from: [outcome("gate", metric: nil)]) == nil)
    }

    // MARK: - Taking and holding the hill

    @Test func aPassingMatchTakesAnEmptyHillAndTheNextChallengerPlaysIt() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "take", manifest: try hillManifest())
            // Nobody holds the hill: the first challenger plays nobody.
            let first = try await play(
                app, setup: fx.setup, activity: fx.activity, user: fx.a, submissionID: "take_a1",
                outcomes: [outcome("m", metric: 5)])
            #expect(first.champion == nil)
            #expect(first.identity == JobOpponent.noOpponentIdentity)
            let crowned = try #require(try await champion(app, fx.setup))
            #expect(crowned.userID == (try fx.a.requireID()))
            #expect(crowned.submissionID == "take_a1")
            #expect(crowned.defences == 0)
            #expect(try await championRecord(app, fx.setup)?.userID == (try fx.a.requireID()))

            // The next challenger plays a1 — and loses, which counts a defence.
            let second = try await play(
                app, setup: fx.setup, activity: fx.activity, user: fx.b, submissionID: "take_b1",
                outcomes: [outcome("m", metric: 2, status: .fail, score: 0.4)])
            #expect(second.champion?.id == "take_a1")
            #expect(second.identity == JobOpponent.submissionIdentity("take_a1"))
            let held = try #require(try await champion(app, fx.setup))
            #expect(held.submissionID == "take_a1")
            #expect(held.defences == 1)

            // And then wins, taking the hill with a fresh streak.
            try await play(
                app, setup: fx.setup, activity: fx.activity, user: fx.b, submissionID: "take_b2",
                outcomes: [outcome("m", metric: 5)])
            let taken = try #require(try await champion(app, fx.setup))
            #expect(taken.userID == (try fx.b.requireID()))
            #expect(taken.submissionID == "take_b2")
            #expect(taken.defences == 0)
            #expect(try await championRecord(app, fx.setup)?.userID == (try fx.b.requireID()))
        }
    }

    /// The row records what was played: score, metric, verdict, completion.
    @Test func theMatchRowIsCompletedWithTheEntrysNumbers() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "row", manifest: try hillManifest(opponentFile: "bot.py"))
            let chosen = try await play(
                app, setup: fx.setup, activity: fx.activity, user: fx.a, submissionID: "row_a1",
                outcomes: [outcome("m", metric: 3, status: .fail, score: 0.6)])
            #expect(chosen.identity == JobOpponent.supportFileIdentity("bot.py"))
            let row = try #require(
                try await APIMatchResult.query(on: app.db).filter(\.$submissionID == "row_a1").first())
            #expect(row.opponentIdentity == "supportFile:bot.py")
            #expect(row.opponentSubmissionID == nil)
            #expect(row.score == 0.6)
            #expect(row.metric == 3)
            #expect(row.won == false)
            #expect(row.completedAt != nil)
            // Lost to the bot: nobody holds the hill.
            #expect(try await champion(app, fx.setup) == nil)
        }
    }

    @Test func aReplayedReportIsANoOp() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "replay", manifest: try hillManifest())
            try await play(
                app, setup: fx.setup, activity: fx.activity, user: fx.a, submissionID: "replay_a1",
                outcomes: [outcome("m", metric: 5)])
            try await play(
                app, setup: fx.setup, activity: fx.activity, user: fx.b, submissionID: "replay_b1",
                outcomes: [outcome("m", metric: 1, status: .fail)])
            let before = try #require(try await champion(app, fx.setup))
            #expect(before.defences == 1)
            // The worker re-reports b1's loss without a new claim: no open row.
            try await recordActivityMatch(
                testSetupID: try fx.setup.requireID(), userID: try fx.b.requireID(),
                submissionID: "replay_b1", outcomes: [outcome("m", metric: 1, status: .fail)], on: app.db)
            let after = try #require(try await champion(app, fx.setup))
            #expect(after.defences == 1)
            #expect(after.submissionID == "replay_a1")
        }
    }

    /// The champion's own submission, re-tested, plays the bot (never itself)
    /// and cannot lose the hill, whatever it scores.
    @Test func aRetestOfTheChampionPlaysTheBotAndKeepsTheHill() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "retest", manifest: try hillManifest(opponentFile: "bot.py"))
            try await play(
                app, setup: fx.setup, activity: fx.activity, user: fx.a, submissionID: "retest_a1",
                outcomes: [outcome("m", metric: 5)])
            let retest = try await play(
                app, setup: fx.setup, activity: fx.activity, user: fx.a, submissionID: "retest_a1",
                outcomes: [outcome("m", metric: 0, status: .fail)])
            #expect(retest.champion == nil)
            #expect(retest.identity == JobOpponent.supportFileIdentity("bot.py"))
            let held = try #require(try await champion(app, fx.setup))
            #expect(held.submissionID == "retest_a1")
            #expect(held.defences == 0)
        }
    }

    /// A champion who resubmits plays their own earlier entry: beating it
    /// moves the hill's submission forward with the streak intact.
    @Test func aChampionsBetterEntryMovesTheHillForward() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "upgrade", manifest: try hillManifest())
            try await play(
                app, setup: fx.setup, activity: fx.activity, user: fx.a, submissionID: "up_a1",
                outcomes: [outcome("m", metric: 5)])
            try await play(
                app, setup: fx.setup, activity: fx.activity, user: fx.b, submissionID: "up_b1",
                outcomes: [outcome("m", metric: 1, status: .fail)])
            let chosen = try await play(
                app, setup: fx.setup, activity: fx.activity, user: fx.a, submissionID: "up_a2",
                outcomes: [outcome("m", metric: 6)])
            #expect(chosen.champion?.id == "up_a1")
            let held = try #require(try await champion(app, fx.setup))
            #expect(held.submissionID == "up_a2")
            #expect(held.defences == 1)
            #expect(held.userID == (try fx.a.requireID()))
        }
    }

    /// A win against a champion who was replaced while the job was out crowns
    /// nobody: the student beat the wrong opponent.
    @Test func aStaleChampionWinCrownsNobody() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "stale", manifest: try hillManifest())
            try await play(
                app, setup: fx.setup, activity: fx.activity, user: fx.a, submissionID: "stale_a1",
                outcomes: [outcome("m", metric: 5)])
            // b's job is claimed against a1 ...
            let bSub = try await arInsertSubmission(
                id: "stale_b1", testSetupID: try fx.setup.requireID(), userID: try fx.b.requireID(), on: app)
            let bOpponent = try await chooseOpponent(for: bSub, activity: fx.activity, on: app.db)
            try await openMatch(
                testSetupID: try fx.setup.requireID(), submissionID: "stale_b1", opponent: bOpponent,
                seed: "s", on: app.db)
            // ... and while it is out, a's newer entry takes the hill.
            try await play(
                app, setup: fx.setup, activity: fx.activity, user: fx.a, submissionID: "stale_a2",
                outcomes: [outcome("m", metric: 7)])
            try await recordActivityMatch(
                testSetupID: try fx.setup.requireID(), userID: try fx.b.requireID(),
                submissionID: "stale_b1", outcomes: [outcome("m", metric: 9)], on: app.db)
            let held = try #require(try await champion(app, fx.setup))
            #expect(held.submissionID == "stale_a2")
            #expect(held.userID == (try fx.a.requireID()))
            let row = try #require(
                try await APIMatchResult.query(on: app.db).filter(\.$submissionID == "stale_b1").first())
            #expect(row.won == true)
            #expect(row.completedAt != nil)
        }
    }

    /// An ordinary activity and a non-student both leave the hill alone.
    @Test func onlyAStudentOnAHillActivityCanHoldIt() async throws {
        try await withAssignmentRoutesApp { app in
            let bot = try await fixture(
                app, prefix: "botonly",
                manifest: try {
                    let props = TestProperties(
                        testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
                        activity: ClassActivity(kind: .beatTheInstructor, opponentFile: "bot.py"))
                    return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
                }())
            try await play(
                app, setup: bot.setup, activity: bot.activity, user: bot.a, submissionID: "botonly_a1",
                outcomes: [outcome("m", metric: 5)])
            #expect(try await champion(app, bot.setup) == nil)

            let hill = try await fixture(app, prefix: "staff", manifest: try hillManifest())
            let staff = try await makeTestUser(on: app, username: "staff_hill", role: "instructor")
            try await makeTestEnrollment(
                on: app, userID: try staff.requireID(), courseID: hill.setup.courseID)
            try await play(
                app, setup: hill.setup, activity: hill.activity, user: staff, submissionID: "staff_s1",
                outcomes: [outcome("m", metric: 5)])
            #expect(try await champion(app, hill.setup) == nil)
        }
    }
}
