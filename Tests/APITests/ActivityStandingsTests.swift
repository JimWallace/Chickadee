// Tests/APITests/ActivityStandingsTests.swift
//
// The round robin (docs/class-activities.md, "Round robin"): who a challenger
// plays, how a matrix result completes the rows the claim opened, how the
// standings are recomputed from the challenger's latest submission alone,
// and who the standings-leader record goes to. Pinned here are the rules
// `recordMatrixMatches` documents — a replayed report is a no-op, a row the
// worker never reported stays open and counts nothing, a resubmission
// replaces the standings row, a bot-only job completes from the collection.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct ActivityStandingsTests {

    private func outcome(
        _ name: String, metric: Double?, status: TestStatus = .pass, score: Double = 1
    ) -> TestOutcome {
        TestOutcome(
            testName: name, testClass: nil, tier: .pub, status: status,
            shortResult: status.defaultShortResult, longResult: nil, score: score, metric: metric,
            executionTimeMs: 1, memoryUsageBytes: nil,
            attemptNumber: 1, isFirstPassSuccess: false)
    }

    private func robinManifest(opponentFile: String? = nil) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            activity: ClassActivity(kind: .roundRobin, opponentFile: opponentFile),
            achievements: [ActivityAuthoring.seededWinnerRecord])
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    /// A round-robin setup plus three enrolled students.
    private struct RobinFixture {
        let setup: APITestSetup
        let activity: ClassActivity
        let a: APIUser
        let b: APIUser
        let c: APIUser
        var setupID: String { setup.id ?? "" }
    }

    private func fixture(_ app: Application, prefix: String, manifest: String) async throws -> RobinFixture {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let setupID = "\(prefix)_setup"
        let setup = APITestSetup(
            id: setupID, manifest: manifest,
            zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID)
        try await setup.save(on: app.db)
        _ = try await arInsertAssignment(testSetupID: setupID, title: "Robin \(prefix)", isOpen: true, on: app)
        var users: [APIUser] = []
        for name in ["a", "b", "c"] {
            let user = try await arInsertStudent(username: "\(prefix)_\(name)", on: app)
            try await arEnrollStudentInTestCourse(user, on: app)
            users.append(user)
        }
        return RobinFixture(
            setup: setup, activity: try #require(setup.decodedManifest()?.activity),
            a: users[0], b: users[1], c: users[2])
    }

    private func report(_ opponent: ChosenOpponent, submissionID: String, won: Bool, score: Double) -> MatchReport {
        MatchReport(
            opponentIdentity: opponent.identity, opponentSubmissionID: opponent.champion?.id,
            seed: JobOpponent.matchSeed(submissionID: submissionID, opponentIdentity: opponent.identity),
            score: score, metric: won ? 1 : 0, won: won)
    }

    /// Runs one challenger's claim the way `jobOpponents` does: choose the
    /// classmates and open a row per opponent.
    private func claim(
        _ app: Application, fx: RobinFixture, user: APIUser, submissionID: String
    ) async throws -> [ChosenOpponent] {
        let submission: APISubmission
        if let existing = try await APISubmission.find(submissionID, on: app.db) {
            submission = existing
        } else {
            submission = try await arInsertSubmission(
                id: submissionID, testSetupID: fx.setupID, userID: try user.requireID(), on: app)
        }
        let chosen = try await chooseClassmates(for: submission, activity: fx.activity, on: app.db)
        for opponent in chosen {
            try await openMatch(
                testSetupID: fx.setupID, submissionID: submissionID, opponent: opponent,
                seed: JobOpponent.matchSeed(submissionID: submissionID, opponentIdentity: opponent.identity),
                on: app.db)
        }
        return chosen
    }

    private func standing(_ app: Application, fx: RobinFixture, user: APIUser) async throws -> APIActivityStanding? {
        try await APIActivityStanding.query(on: app.db)
            .filter(\.$testSetupID == fx.setupID)
            .filter(\.$userID == (try user.requireID()))
            .first()
    }

    private func winnerRecord(_ app: Application, fx: RobinFixture) async throws -> APIClassAchievement? {
        try await APIClassAchievement.query(on: app.db)
            .filter(\.$testSetupID == fx.setupID)
            .filter(\.$achievementID == ActivityAuthoring.seededWinnerRecordID)
            .first()
    }

    // MARK: - Who a challenger plays

    /// Every OTHER enrolled student's latest complete submission, one each,
    /// in submission-id order; a pending upload and the challenger's own
    /// earlier entry are never opponents.
    @Test func aChallengerPlaysEachClassmatesLatestCompleteSubmission() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "pick", manifest: try robinManifest())
            _ = try await arInsertSubmission(
                id: "pick_b1", testSetupID: fx.setupID, userID: try fx.b.requireID(), on: app)
            _ = try await arInsertSubmission(
                id: "pick_b2", testSetupID: fx.setupID, userID: try fx.b.requireID(), attemptNumber: 2, on: app)
            _ = try await arInsertSubmission(
                id: "pick_c1", testSetupID: fx.setupID, userID: try fx.c.requireID(), status: "pending", on: app)
            _ = try await arInsertSubmission(
                id: "pick_a0", testSetupID: fx.setupID, userID: try fx.a.requireID(), on: app)
            let challenger = try await arInsertSubmission(
                id: "pick_a1", testSetupID: fx.setupID, userID: try fx.a.requireID(), attemptNumber: 2, on: app)

            let chosen = try await chooseClassmates(for: challenger, activity: fx.activity, on: app.db)
            #expect(chosen.map { $0.champion?.id } == ["pick_b2"])
            #expect(chosen.map(\.identity) == [JobOpponent.submissionIdentity("pick_b2")])

            // A kind with no classmates source never chooses any.
            let hill = ClassActivity(kind: .kingOfTheHill)
            #expect(try await chooseClassmates(for: challenger, activity: hill, on: app.db).isEmpty)
        }
    }

    /// The first submitter has no classmate to play.
    @Test func theFirstSubmitterHasNoClassmates() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "first", manifest: try robinManifest())
            let chosen = try await claim(app, fx: fx, user: fx.a, submissionID: "first_a1")
            #expect(chosen.isEmpty)
        }
    }

    // MARK: - Landing a matrix result

    /// The worker's reports complete the rows by identity; the challenger's
    /// standings row is computed from them; the leader holds the record.
    @Test func aMatrixResultCompletesTheRowsAndComputesTheStandings() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "land", manifest: try robinManifest())
            _ = try await arInsertSubmission(
                id: "land_b1", testSetupID: fx.setupID, userID: try fx.b.requireID(), on: app)
            _ = try await arInsertSubmission(
                id: "land_c1", testSetupID: fx.setupID, userID: try fx.c.requireID(), on: app)
            let chosen = try await claim(app, fx: fx, user: fx.a, submissionID: "land_a1")
            #expect(chosen.count == 2)
            let (vsB, vsC) = (try #require(chosen.first), try #require(chosen.last))

            // Beat b, draw c.
            try await recordActivityMatch(
                testSetupID: fx.setupID, userID: try fx.a.requireID(), submissionID: "land_a1",
                outcomes: [outcome("match", metric: 1)],
                matches: [
                    report(vsB, submissionID: "land_a1", won: true, score: 1),
                    report(vsC, submissionID: "land_a1", won: false, score: 0.5),
                ],
                on: app.db)

            let rows = try await APIMatchResult.query(on: app.db)
                .filter(\.$submissionID == "land_a1").sort(\.$opponentIdentity).all()
            #expect(rows.count == 2)
            #expect(rows.allSatisfy { $0.completedAt != nil })
            #expect(rows.map(\.won) == [true, false])
            #expect(rows.map(\.score) == [1, 0.5])

            let a = try #require(try await standing(app, fx: fx, user: fx.a))
            #expect(a.submissionID == "land_a1")
            #expect(a.played == 2)
            #expect(a.wins == 1)
            #expect(a.draws == 1)
            #expect(a.losses == 0)
            #expect(a.averageScore == 0.75)
            // Only the challenger's row is written: b and c have played nothing.
            #expect(try await standing(app, fx: fx, user: fx.b) == nil)
            #expect(try await winnerRecord(app, fx: fx)?.userID == (try fx.a.requireID()))
            let signals = try #require(
                try await standingSignals(testSetupID: fx.setupID, userID: try fx.a.requireID(), on: app.db))
            #expect(signals.standing == 1)
            #expect(signals.matchesWon == 1)
            #expect(try await standingSignals(testSetupID: fx.setupID, userID: try fx.b.requireID(), on: app.db) == nil)

            // A replayed report finds no open row and changes nothing.
            try await recordActivityMatch(
                testSetupID: fx.setupID, userID: try fx.a.requireID(), submissionID: "land_a1",
                outcomes: [outcome("match", metric: 0, status: .fail, score: 0)],
                matches: [report(vsB, submissionID: "land_a1", won: false, score: 0)],
                on: app.db)
            #expect(try await standing(app, fx: fx, user: fx.a)?.wins == 1)
        }
    }

    /// The standings order and the leader record follow the average score,
    /// then wins; a resubmission REPLACES the student's row rather than
    /// keeping their best, and the record moves with the lead.
    @Test func theStandingsRankOnAverageScoreAndAResubmissionReplacesTheRow() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "rank", manifest: try robinManifest())
            _ = try await arInsertSubmission(
                id: "rank_c1", testSetupID: fx.setupID, userID: try fx.c.requireID(), on: app)
            // a loses to c.
            let aPlays = try await claim(app, fx: fx, user: fx.a, submissionID: "rank_a1")
            try await recordActivityMatch(
                testSetupID: fx.setupID, userID: try fx.a.requireID(), submissionID: "rank_a1",
                outcomes: [outcome("match", metric: 0, status: .fail, score: 0)],
                matches: aPlays.map { report($0, submissionID: "rank_a1", won: false, score: 0) }, on: app.db)
            // b beats both a and c.
            let bPlays = try await claim(app, fx: fx, user: fx.b, submissionID: "rank_b1")
            #expect(bPlays.count == 2)
            try await recordActivityMatch(
                testSetupID: fx.setupID, userID: try fx.b.requireID(), submissionID: "rank_b1",
                outcomes: [outcome("match", metric: 2)],
                matches: bPlays.map { report($0, submissionID: "rank_b1", won: true, score: 1) }, on: app.db)

            let standings = try await activityStandings(testSetupID: fx.setupID, on: app.db)
            #expect(standings.map(\.userID) == [try fx.b.requireID(), try fx.a.requireID()])
            #expect(try await winnerRecord(app, fx: fx)?.userID == (try fx.b.requireID()))

            // a resubmits and beats b and c: a's row is a1's no longer.
            let aAgain = try await claim(app, fx: fx, user: fx.a, submissionID: "rank_a2")
            #expect(aAgain.count == 2)
            try await recordActivityMatch(
                testSetupID: fx.setupID, userID: try fx.a.requireID(), submissionID: "rank_a2",
                outcomes: [outcome("match", metric: 2)],
                matches: aAgain.map { report($0, submissionID: "rank_a2", won: true, score: 1) }, on: app.db)
            let a = try #require(try await standing(app, fx: fx, user: fx.a))
            #expect(a.submissionID == "rank_a2")
            #expect(a.played == 2)
            #expect(a.wins == 2)
            #expect(a.losses == 0)
            // Both now average 1 with 2 wins and 2 played: the earlier row leads.
            let after = try await activityStandings(testSetupID: fx.setupID, on: app.db)
            #expect(after.first?.userID == (try fx.b.requireID()))
            #expect(try await winnerRecord(app, fx: fx)?.userID == (try fx.b.requireID()))
            #expect(try await APIActivityStanding.query(on: app.db).filter(\.$testSetupID == fx.setupID).count() == 2)
        }
    }

    /// A row the worker never reported stays open and counts nothing; a
    /// bot-only job (no reports at all) completes its one row from the
    /// collection's match entry, as a hill match does.
    @Test func anUnreportedRowStaysOpenAndABotOnlyJobCompletesFromTheCollection() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "open", manifest: try robinManifest(opponentFile: "bot.py"))
            _ = try await arInsertSubmission(
                id: "open_b1", testSetupID: fx.setupID, userID: try fx.b.requireID(), on: app)
            _ = try await arInsertSubmission(
                id: "open_c1", testSetupID: fx.setupID, userID: try fx.c.requireID(), on: app)
            let chosen = try await claim(app, fx: fx, user: fx.a, submissionID: "open_a1")
            let vsB = try #require(chosen.first)
            try await recordActivityMatch(
                testSetupID: fx.setupID, userID: try fx.a.requireID(), submissionID: "open_a1",
                outcomes: [outcome("match", metric: 1)],
                matches: [report(vsB, submissionID: "open_a1", won: true, score: 1)], on: app.db)
            let rows = try await APIMatchResult.query(on: app.db)
                .filter(\.$submissionID == "open_a1").sort(\.$opponentIdentity).all()
            #expect(rows.map { $0.completedAt != nil } == [true, false])
            let a = try #require(try await standing(app, fx: fx, user: fx.a))
            #expect(a.played == 1)
            #expect(a.wins == 1)

            // The bot-only path: one row, opened under the bot, no reports.
            let bot = ChosenOpponent(champion: nil, identity: JobOpponent.supportFileIdentity("bot.py"))
            let botSub = try await arInsertSubmission(
                id: "open_d1", testSetupID: fx.setupID, userID: try fx.b.requireID(), attemptNumber: 2, on: app)
            try await openMatch(
                testSetupID: fx.setupID, submissionID: try botSub.requireID(), opponent: bot,
                seed: JobOpponent.matchSeed(submissionID: "open_d1", opponentIdentity: bot.identity), on: app.db)
            try await recordActivityMatch(
                testSetupID: fx.setupID, userID: try fx.b.requireID(), submissionID: "open_d1",
                outcomes: [outcome("match", metric: 3, score: 0.9)], on: app.db)
            let botRow = try #require(
                try await APIMatchResult.query(on: app.db).filter(\.$submissionID == "open_d1").first())
            #expect(botRow.won == true)
            #expect(botRow.score == 0.9)
            #expect(botRow.metric == 3)
            #expect(try await standing(app, fx: fx, user: fx.b)?.wins == 1)
        }
    }

    // MARK: - The standings badges

    /// An authored `standing` / `matchesWon` badge is awarded from the
    /// standings the submission page loads, and never without them.
    @Test func aStandingBadgeIsAwardedFromTheLoadedStandings() {
        let podium = Achievement(
            id: "podium", name: "Podium", scope: .individual,
            conditions: [AchievementCondition(signal: .standing, comparator: .atMost, value: 3)],
            reward: AchievementReward(type: .badge, label: "Podium"))
        let streak = Achievement(
            id: "streak", name: "Streak", scope: .individual,
            conditions: [AchievementCondition(signal: .matchesWon, comparator: .atLeast, value: 2)],
            reward: AchievementReward(type: .badge, label: "Streak"))
        let props = TestProperties(activity: ClassActivity(kind: .roundRobin), achievements: [podium, streak])
        let outcomes = [outcome("match", metric: 1)]
        #expect(earnedIndividualBadges(props: props, gradePercent: 100, outcomes: outcomes).isEmpty)
        let third = earnedIndividualBadges(
            props: props, gradePercent: 100, outcomes: outcomes, standings: (standing: 3, matchesWon: 1))
        #expect(third.map(\.id) == ["podium"])
        let leader = earnedIndividualBadges(
            props: props, gradePercent: 0, outcomes: outcomes, standings: (standing: 1, matchesWon: 5))
        #expect(leader.map(\.id) == ["podium", "streak"])
    }

    /// Only a `.student` in the setup's course gets a standings row: a staff
    /// validation run completes its rows and stands nowhere.
    @Test func staffNeverStandInTheStandings() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "staff", manifest: try robinManifest())
            _ = try await arInsertSubmission(
                id: "staff_b1", testSetupID: fx.setupID, userID: try fx.b.requireID(), on: app)
            let ta = try await arInsertStudent(username: "staff_ta", on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            try await APICourseEnrollment(userID: try ta.requireID(), courseID: courseID, role: .ta).save(on: app.db)
            let run = try await arInsertSubmission(
                id: "staff_run", testSetupID: fx.setupID, userID: try ta.requireID(), on: app)
            let chosen = try await chooseClassmates(for: run, activity: fx.activity, on: app.db)
            for opponent in chosen {
                try await openMatch(
                    testSetupID: fx.setupID, submissionID: "staff_run", opponent: opponent,
                    seed: JobOpponent.matchSeed(submissionID: "staff_run", opponentIdentity: opponent.identity),
                    on: app.db)
            }
            try await recordActivityMatch(
                testSetupID: fx.setupID, userID: try ta.requireID(), submissionID: "staff_run",
                outcomes: [outcome("match", metric: 1)],
                matches: chosen.map { report($0, submissionID: "staff_run", won: true, score: 1) }, on: app.db)
            #expect(try await standing(app, fx: fx, user: ta) == nil)
            #expect(try await winnerRecord(app, fx: fx) == nil)
        }
    }
}
