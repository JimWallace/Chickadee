// Tests/APITests/TournamentRunTests.swift
//
// A tournament from start to winner (docs/class-activities.md,
// "Tournaments"): the snapshot of entrants, the match jobs a round enqueues,
// the opponent a match job stages, the rows the claim opens, how a landed
// result decides a slot, that a round advances only when its last match
// lands, that a resubmission after the start changes nothing, that a replay
// is a no-op, that a match which could not run advances the opponent, and
// that a later run supersedes the one in progress.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct TournamentRunTests {

    private func robinOrTournamentManifest(kind: ActivityKind, opponentFile: String? = nil) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            activity: ClassActivity(kind: kind, opponentFile: opponentFile),
            achievements: [ActivityAuthoring.seededTournamentRecord])
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    private struct Fixture {
        let setup: APITestSetup
        let students: [APIUser]
        var setupID: String { setup.id ?? "" }
        func user(seed: Int) -> APIUser { students[seed - 1] }
    }

    /// A tournament setup plus `count` enrolled students, each with one
    /// complete submission `<prefix>_s<n>` submitted in seed order.
    private func fixture(
        _ app: Application, prefix: String, students count: Int, kind: ActivityKind = .elimination
    ) async throws -> Fixture {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let setupID = "\(prefix)_setup"
        let setup = APITestSetup(
            id: setupID, manifest: try robinOrTournamentManifest(kind: kind),
            zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID)
        try await setup.save(on: app.db)
        _ = try await arInsertAssignment(testSetupID: setupID, title: "Cup \(prefix)", isOpen: true, on: app)
        var students: [APIUser] = []
        for index in 1...count {
            let user = try await arInsertStudent(username: "\(prefix)_u\(index)", on: app)
            try await arEnrollStudentInTestCourse(user, on: app)
            let sub = try await arInsertSubmission(
                id: "\(prefix)_s\(index)", testSetupID: setupID, userID: try user.requireID(), on: app)
            sub.submittedAt = Date(timeIntervalSince1970: 1_000_000 + Double(index * 60))
            try await sub.save(on: app.db)
            students.append(user)
        }
        return Fixture(setup: setup, students: students)
    }

    private func slots(_ app: Application, _ run: APITournamentRun) async throws -> [APITournamentMatch] {
        try await APITournamentMatch.query(on: app.db)
            .filter(\.$tournamentID == (try run.requireID()))
            .sort(\.$round).sort(\.$position)
            .all()
    }

    private func matchSubmission(_ app: Application, _ slot: APITournamentMatch) async throws -> APISubmission {
        try #require(try await APISubmission.find(slot.matchSubmissionID ?? "", on: app.db))
    }

    private func collection(passed: Bool, built: Bool = true) -> TestOutcomeCollection {
        let outcome = TestOutcome(
            testName: "match", testClass: nil, tier: .pub, status: passed ? .pass : .fail,
            shortResult: "", longResult: nil, score: passed ? 1 : 0, metric: passed ? 1 : 0,
            executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: false)
        return TestOutcomeCollection(
            submissionID: "x", testSetupID: "t", attemptNumber: 1, buildStatus: built ? .passed : .failed,
            compilerOutput: nil, outcomes: built ? [outcome] : [], totalTests: built ? 1 : 0,
            passCount: passed && built ? 1 : 0, failCount: !passed && built ? 1 : 0, errorCount: 0,
            timeoutCount: 0, executionTimeMs: 1, runnerVersion: "test", timestamp: Date())
    }

    /// Claims and lands one slot's match the way the claim and result paths
    /// do: stage the paired opponent (opening the row), then record.
    private func land(
        _ app: Application, slot: APITournamentMatch, homeWins: Bool, built: Bool = true
    ) async throws {
        let submission = try await matchSubmission(app, slot)
        let paired = try #require(try await pairedOpponent(for: submission, on: app.db))
        let chosen = ChosenOpponent(
            champion: paired.away, identity: JobOpponent.submissionIdentity(try paired.away.requireID()))
        try await openMatch(
            testSetupID: submission.testSetupID, submissionID: try submission.requireID(), opponent: chosen,
            seed: JobOpponent.matchSeed(submissionID: try submission.requireID(), opponentIdentity: chosen.identity),
            round: slot.round, on: app.db)
        try await recordTournamentMatch(
            submission: submission, collection: collection(passed: homeWins, built: built), on: app.db)
    }

    private func reload(_ app: Application, _ run: APITournamentRun) async throws -> APITournamentRun {
        try #require(try await APITournamentRun.find(try run.requireID(), on: app.db))
    }

    // MARK: - Starting

    /// Five entrants are seeded by submission order, the top three seeds get
    /// byes, and one match job is enqueued for 4 against 5 — a frozen copy
    /// of seed 4's upload, invisible to every student-kind listing.
    @Test func startingSnapshotsTheClassAndEnqueuesTheFirstRound() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "start", students: 5)
            // A pending upload and a staff run never enter.
            _ = try await arInsertSubmission(
                id: "start_pending", testSetupID: fx.setupID, userID: try fx.user(seed: 1).requireID(),
                attemptNumber: 2, status: "pending", on: app)
            let run = try await startTournament(setup: fx.setup, schedule: .bracket, startedBy: nil, on: app.db)
            #expect(run.status == APITournamentRun.Status.running)
            #expect(run.roundCount == 3)
            #expect(run.currentRound == 1)
            #expect(run.entrants.map(\.seed) == [1, 2, 3, 4, 5])
            #expect(run.entrants.map(\.submissionID) == (1...5).map { "start_s\($0)" })
            #expect(run.entrants.map(\.userID) == (try fx.students.map { try $0.requireID() }))

            let first = try await slots(app, run)
            #expect(first.map(\.homeSeed) == [1, 4, 2, 3])
            #expect(first.map(\.winnerSeed) == [1, nil, 2, 3])
            #expect(first.filter { $0.matchSubmissionID != nil }.count == 1)
            let match = try await matchSubmission(app, first[1])
            #expect(match.kind == APISubmission.Kind.tournamentMatch)
            #expect(match.status == SubmissionStatus.pending.rawValue)
            #expect(match.userID == (try fx.user(seed: 4).requireID()))
            let original = try #require(try await APISubmission.find("start_s4", on: app.db))
            #expect(match.zipPath == original.zipPath)
            #expect(match.filename == original.filename)
            // The claim path finds it and stages seed 5's snapshotted upload.
            let paired = try #require(try await pairedOpponent(for: match, on: app.db))
            #expect(paired.away.id == "start_s5")
            #expect(paired.slot.round == 1)
            // A student's own submission is not a match.
            #expect(try await pairedOpponent(for: original, on: app.db) == nil)
        }
    }

    @Test func startingIsRefusedOffATournamentKindAndWithOneEntrant() async throws {
        try await withAssignmentRoutesApp { app in
            let hill = try await fixture(app, prefix: "refuse_hill", students: 3, kind: .kingOfTheHill)
            await #expect(throws: TournamentStartError.self) {
                _ = try await startTournament(setup: hill.setup, schedule: .bracket, startedBy: nil, on: app.db)
            }
            let lonely = try await fixture(app, prefix: "refuse_one", students: 1)
            do {
                _ = try await startTournament(setup: lonely.setup, schedule: .swiss, startedBy: nil, on: app.db)
                Issue.record("one entrant must be refused")
            } catch let error as TournamentStartError {
                #expect(error.reason.contains("at least two"))
                #expect(error.reason.contains("is 1"))
            }
            #expect(try await APITournamentRun.query(on: app.db).count() == 0)
        }
    }

    // MARK: - Landing matches

    /// A bracket of five, played to the end: each landed match decides its
    /// slot, the round advances only when its last open match lands, the
    /// winner of a slot (not its seed) plays on, and the last one standing
    /// takes the record.
    @Test func roundsAdvanceAsMatchesLandAndTheWinnerTakesTheRecord() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "play", students: 5)
            let run = try await startTournament(setup: fx.setup, schedule: .bracket, startedBy: nil, on: app.db)
            var all = try await slots(app, run)
            // Round 1: 4 beats 5.
            try await land(app, slot: all[1], homeWins: true)
            let row = try #require(
                try await APIMatchResult.query(on: app.db)
                    .filter(\.$submissionID == (all[1].matchSubmissionID ?? "")).first())
            #expect(row.round == 1)
            #expect(row.won == true)
            #expect(row.completedAt != nil)

            // Round 2 is out: (1 v 4) and (2 v 3).
            all = try await slots(app, run)
            #expect(all.count == 6)
            #expect(try await reload(app, run).currentRound == 2)
            let second = all.filter { $0.round == 2 }
            #expect(second.map { [$0.homeSeed, $0.awaySeed ?? 0] } == [[1, 4], [2, 3]])
            #expect(second.allSatisfy { $0.matchSubmissionID != nil && $0.winnerSeed == nil })

            // Only one of the two lands: no round 3 yet.
            try await land(app, slot: second[0], homeWins: true)
            #expect(try await slots(app, run).count == 6)
            #expect(try await reload(app, run).currentRound == 2)
            // 3 upsets 2 (the away entrant wins when the script fails).
            try await land(app, slot: second[1], homeWins: false)
            all = try await slots(app, run)
            #expect(all.count == 7)
            let final = try #require(all.last)
            #expect(final.round == 3)
            #expect([final.homeSeed, final.awaySeed] == [1, 3])

            // The final: 3 wins.
            try await land(app, slot: final, homeWins: false)
            let done = try await reload(app, run)
            #expect(done.status == APITournamentRun.Status.complete)
            #expect(done.completedAt != nil)
            #expect(done.winnerUserID == (try fx.user(seed: 3).requireID()))
            let record = try await APIClassAchievement.query(on: app.db)
                .filter(\.$testSetupID == fx.setupID)
                .filter(\.$achievementID == ActivityAuthoring.seededTournamentRecordID)
                .first()
            #expect(record?.userID == (try fx.user(seed: 3).requireID()))
            #expect(record?.submissionID == "play_s3")

            // A replayed report for the final finds the slot decided.
            try await land(app, slot: final, homeWins: true)
            #expect(try await reload(app, run).winnerUserID == (try fx.user(seed: 3).requireID()))
            #expect(try await slots(app, run).count == 7)
        }
    }

    /// A match that never built advances the opponent, so a broken
    /// submission cannot stall a round.
    @Test func aMatchThatCouldNotRunAdvancesTheOpponent() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "broken", students: 2)
            let run = try await startTournament(setup: fx.setup, schedule: .bracket, startedBy: nil, on: app.db)
            let only = try #require(try await slots(app, run).first)
            try await land(app, slot: only, homeWins: true, built: false)
            #expect(try await slots(app, run).first?.winnerSeed == 2)
            let done = try await reload(app, run)
            #expect(done.status == APITournamentRun.Status.complete)
            #expect(done.winnerUserID == (try fx.user(seed: 2).requireID()))
        }
    }

    /// A submission after the start is not an entrant; the rounds keep
    /// playing the snapshotted uploads.
    @Test func aResubmissionAfterTheStartChangesNothing() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "frozen", students: 3)
            let run = try await startTournament(setup: fx.setup, schedule: .bracket, startedBy: nil, on: app.db)
            let late = try await arInsertSubmission(
                id: "frozen_late", testSetupID: fx.setupID, userID: try fx.user(seed: 2).requireID(),
                attemptNumber: 2, on: app)
            late.filename = "late.py"
            try await late.save(on: app.db)
            // Round 1 of three: (1 bye), (2 v 3). Seed 2 wins → final (1 v 2).
            let first = try await slots(app, run)
            try await land(app, slot: first[1], homeWins: true)
            let final = try #require(try await slots(app, run).last)
            #expect(final.round == 2)
            let finalMatch = try await matchSubmission(app, final)
            let original = try #require(try await APISubmission.find("frozen_s1", on: app.db))
            #expect(finalMatch.zipPath == original.zipPath)
            let paired = try #require(try await pairedOpponent(for: finalMatch, on: app.db))
            #expect(paired.away.id == "frozen_s2")
            #expect(try await reload(app, run).entrants.map(\.submissionID) == ["frozen_s1", "frozen_s2", "frozen_s3"])
        }
    }

    /// Starting again supersedes the run in progress: its outstanding match
    /// still decides its slot when it lands, but moves nothing.
    @Test func aLaterRunSupersedesTheOneInProgress() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "super", students: 2)
            let old = try await startTournament(setup: fx.setup, schedule: .bracket, startedBy: nil, on: app.db)
            let new = try await startTournament(setup: fx.setup, schedule: .swiss, startedBy: nil, on: app.db)
            #expect(try await reload(app, old).status == APITournamentRun.Status.superseded)
            #expect(try await reload(app, new).status == APITournamentRun.Status.running)
            let latest = try #require(try await latestTournament(testSetupID: fx.setupID, on: app.db))
            #expect(latest.run.id == new.id)

            let oldSlot = try #require(try await slots(app, old).first)
            try await land(app, slot: oldSlot, homeWins: true)
            #expect(try await slots(app, old).first?.winnerSeed == 1)
            let stale = try await reload(app, old)
            #expect(stale.status == APITournamentRun.Status.superseded)
            #expect(stale.winnerUserID == nil)
            #expect(
                try await APIClassAchievement.query(on: app.db)
                    .filter(\.$achievementID == ActivityAuthoring.seededTournamentRecordID).count() == 0)
        }
    }

    // MARK: - The submissions page control

    /// The Tournament section renders only on a tournament kind, says where
    /// the latest run stands, and its form starts one; an ordinary
    /// assignment gets no control and refuses the post.
    @Test func theSubmissionsPageRunsATournament() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let fx = try await fixture(app, prefix: "page", students: 2)
            let assignment = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$testSetupID == fx.setupID).first())
            let path = "/instructor/\(assignment.publicID)/submissions"
            var html = ""
            try await app.asyncTest(
                .GET, path,
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    html = res.body.string
                })
            #expect(html.contains("Run tournament"))
            #expect(html.contains("No tournament has been run yet."))
            #expect(html.contains("Single elimination"))

            let (csrf, sessionCookie) = try await csrfFields(for: path, cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/instructor/\(assignment.publicID)/tournament/run",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf, "schedule": "swiss"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("notice=Tournament+started") == true)
                })
            let run = try #require(try await latestTournament(testSetupID: fx.setupID, on: app.db))
            #expect(run.run.schedule == "swiss")
            #expect(run.run.entrants.count == 2)
            try await app.asyncTest(
                .GET, path,
                beforeRequest: { req in req.headers.add(name: .cookie, value: sessionCookie) },
                afterResponse: { res in
                    #expect(res.body.string.contains("Swiss: round 1 of 1 in progress."))
                })

            // An ordinary assignment: no control, and the post bounces.
            try await arInsertSetup(id: "page_plain", on: app)
            let plain = try await arInsertAssignment(testSetupID: "page_plain", title: "Plain", isOpen: true, on: app)
            try await app.asyncTest(
                .GET, "/instructor/\(plain.publicID)/submissions",
                beforeRequest: { req in req.headers.add(name: .cookie, value: sessionCookie) },
                afterResponse: { res in #expect(!res.body.string.contains("Run tournament")) })
            try await app.asyncTest(
                .POST, "/instructor/\(plain.publicID)/tournament/run",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf, "schedule": "bracket"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("error=") == true)
                })
        }
    }

    /// Swiss on five: three rounds, everyone plays every round, the bye
    /// rotates, and the most points wins.
    @Test func aSwissTournamentPlaysEveryRoundToAPointsWinner() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "swiss", students: 5)
            let run = try await startTournament(setup: fx.setup, schedule: .swiss, startedBy: nil, on: app.db)
            #expect(run.roundCount == 3)
            for round in 1...3 {
                let open = try await slots(app, run).filter { $0.round == round && $0.winnerSeed == nil }
                #expect(open.count == 2, "round \(round)")
                for slot in open { try await land(app, slot: slot, homeWins: true) }
            }
            let done = try await reload(app, run)
            #expect(done.status == APITournamentRun.Status.complete)
            #expect(done.currentRound == 3)
            let all = try await slots(app, run)
            #expect(all.count == 9)
            #expect(Set(all.filter { $0.awaySeed == nil }.map(\.homeSeed)).count == 3)
            #expect(done.winnerUserID == (try fx.user(seed: 1).requireID()))
        }
    }
}
