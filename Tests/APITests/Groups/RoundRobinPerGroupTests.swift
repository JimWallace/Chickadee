// Tests/APITests/Groups/RoundRobinPerGroupTests.swift
//
// A round robin run once per lab group (docs/lab-groups.md, slice 3c): a
// challenger plays only the students in the session they submitted in, each
// standings row carries the group it was played in and ranks only there, a
// submission made with no session open plays nobody and leaves the standings
// as they were, a student whom staff removed leaves the standings, and no
// lab's leader holds the course's class record, which a per-group round robin
// does not seed.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class RoundRobinPerGroupTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-robin-groups")
    }

    private typealias Fixture = PerGroupActivityFixture

    private let setupID = "rrg_setup"

    /// A per-group round robin with ada and ben in Lab 101 and alan and ari
    /// in Lab 102.
    private func fixture() async throws -> Fixture {
        try await .make(
            on: app, code: "RRG1", setupID: setupID,
            activity: ClassActivity(kind: .roundRobin, runsPerGroup: true),
            achievements: [ActivityAuthoring.seededWinnerRecord],
            students: [("rrg_ada", .a), ("rrg_ben", .a), ("rrg_alan", .b), ("rrg_ari", .b)])
    }

    private func outcome() -> TestOutcome {
        .stub(metric: 1)
    }

    /// Runs one challenger's job as the claim and result paths do: choose the
    /// classmates, open a row for each, then land a report that wins every
    /// match. Returns the submissions played.
    @discardableResult
    private func play(_ f: Fixture, userID: UUID, id: String) async throws -> [String] {
        let submission = try await makeTestSubmission(on: app, id: id, setupID: setupID, userID: userID)
        let chosen = try await chooseClassmates(for: submission, activity: f.activity, on: app.db)
        let opponents =
            chosen.isEmpty ? [ChosenOpponent(champion: nil, identity: JobOpponent.noOpponentIdentity)] : chosen
        var reports: [MatchReport] = []
        for opponent in opponents {
            let seed = JobOpponent.matchSeed(submissionID: id, opponentIdentity: opponent.identity)
            try await openMatch(testSetupID: setupID, submissionID: id, opponent: opponent, seed: seed, on: app.db)
            reports.append(
                MatchReport(
                    opponentIdentity: opponent.identity, opponentSubmissionID: opponent.champion?.id, seed: seed,
                    score: 1, metric: 1, won: true))
        }
        try await recordActivityMatch(
            testSetupID: setupID, userID: userID, submissionID: id, outcomes: [outcome()],
            matches: chosen.isEmpty ? nil : reports, on: app.db)
        return chosen.compactMap { $0.champion?.id }
    }

    private func standing(_ userID: UUID) async throws -> APIActivityStanding? {
        try await APIActivityStanding.query(on: app.db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$userID == userID)
            .first()
    }

    @Test func aChallengerPlaysOnlyTheStudentsInTheirSession() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            for (student, group) in [(f.ada, f.labA), (f.ben, f.labA), (f.alan, f.labB), (f.ari, f.labB)] {
                try await f.join(student, to: group, on: app.db)
            }
            #expect(try await play(f, userID: f.ada, id: "rrg_a1").isEmpty)
            #expect(try await play(f, userID: f.alan, id: "rrg_l1").isEmpty, "Lab 102 plays nobody from Lab 101")
            #expect(try await play(f, userID: f.ben, id: "rrg_b1") == ["rrg_a1"])
            #expect(try await play(f, userID: f.ari, id: "rrg_r1") == ["rrg_l1"])
        }
    }

    @Test func eachLabRanksItsOwnStandings() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            for (student, group) in [(f.ada, f.labA), (f.ben, f.labA), (f.alan, f.labB), (f.ari, f.labB)] {
                try await f.join(student, to: group, on: app.db)
            }
            try await play(f, userID: f.ada, id: "rrg_a2")
            try await play(f, userID: f.ben, id: "rrg_b2")
            try await play(f, userID: f.alan, id: "rrg_l2")
            try await play(f, userID: f.ari, id: "rrg_r2")

            #expect(try await standing(f.ben)?.groupID == f.labA)
            #expect(try await standing(f.ari)?.groupID == f.labB)
            let labA = try await rankedStandings(
                testSetupID: setupID, courseID: f.setup.courseID, groupID: f.labA, on: app.db)
            #expect(labA.map(\.standing.userID) == [f.ben])
            let labB = try await rankedStandings(
                testSetupID: setupID, courseID: f.setup.courseID, groupID: f.labB, on: app.db)
            #expect(labB.map(\.standing.userID) == [f.ari])
            #expect(try await standingSignals(testSetupID: setupID, userID: f.ari, on: app.db)?.standing == 1)

            let board = try await buildStandingsBoard(
                setup: f.setup, reader: .presenting(as: try #require(try await APIUser.find(f.ada, on: app.db))),
                showAll: true, groupID: f.labB, on: app.db)
            #expect(board.rows.count == 1)

            let record = try await APIClassAchievement.query(on: app.db)
                .filter(\.$testSetupID == setupID)
                .filter(\.$achievementID == ActivityAuthoring.seededWinnerRecordID)
                .first()
            #expect(record == nil, "no lab's leader holds the class record")
        }
    }

    @Test func aPerGroupRoundRobinSeedsNoWinnerRecord() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            func hasWinnerRecord() async throws -> Bool {
                let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
                return setup.decodedManifest()?.achievements.contains {
                    $0.id == ActivityAuthoring.seededWinnerRecordID
                } == true
            }
            #expect(try await hasWinnerRecord(), "the fixture carries the seeded record")
            _ = try await ActivityAuthoring.setActivity(
                setup: f.setup, to: ClassActivity(kind: .roundRobin, runsPerGroup: true), on: app.db)
            #expect(try await !hasWinnerRecord())
            let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
            _ = try await ActivityAuthoring.setActivity(setup: setup, to: ClassActivity(kind: .roundRobin), on: app.db)
            #expect(try await hasWinnerRecord(), "the whole class's round robin seeds it again")
        }
    }

    @Test func aLabsRowsStayOffTheClassStandingsAfterTheFlagGoesOff() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            try await f.join(f.ada, to: f.labA, on: app.db)
            try await f.join(f.ben, to: f.labA, on: app.db)
            try await play(f, userID: f.ada, id: "rrg_a7")
            try await play(f, userID: f.ben, id: "rrg_b7")
            #expect(try await standing(f.ben)?.groupID == f.labA)

            _ = try await ActivityAuthoring.setActivity(
                setup: f.setup, to: ClassActivity(kind: .roundRobin), on: app.db)
            let classStandings = try await rankedStandings(
                testSetupID: setupID, courseID: f.setup.courseID, on: app.db)
            #expect(classStandings.isEmpty, "a lab's row is not a class row")
            #expect(
                try await standingSignals(testSetupID: setupID, userID: f.ben, on: app.db) == nil,
                "the badge reads the board the page shows")
        }
    }

    @Test func aRemovedStudentLeavesTheGroupsStandings() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            try await f.join(f.ada, to: f.labA, on: app.db)
            try await f.join(f.ben, to: f.labA, on: app.db)
            try await play(f, userID: f.ada, id: "rrg_a5")
            try await play(f, userID: f.ben, id: "rrg_b5")
            #expect(try await standing(f.ben) != nil)

            let session = try #require(
                try await ActivitySessionStore.session(assignmentID: f.assignmentID, groupID: f.labA, on: app.db))
            #expect(try await ActivitySessionStore.remove(userID: f.ben, from: session, on: app.db))
            #expect(try await standing(f.ben) == nil)
            #expect(try await play(f, userID: f.ada, id: "rrg_a6").isEmpty, "nobody plays a removed student")
        }
    }

    @Test func aSubmissionWithNoSessionPlaysNobodyAndLeavesTheStandings() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            try await f.join(f.ada, to: f.labA, on: app.db)
            try await f.join(f.ben, to: f.labA, on: app.db)
            try await play(f, userID: f.ada, id: "rrg_a3")
            try await play(f, userID: f.ben, id: "rrg_b3")
            let before = try #require(try await standing(f.ben))
            #expect(before.submissionID == "rrg_b3")

            // The session closes; ben's next submission grades and plays nobody.
            let session = try #require(
                try await ActivitySessionStore.session(assignmentID: f.assignmentID, groupID: f.labA, on: app.db))
            try await ActivitySessionStore.close(session, now: Date().addingTimeInterval(-1), on: app.db)
            #expect(try await play(f, userID: f.ben, id: "rrg_b4").isEmpty)
            #expect(try await standing(f.ben)?.submissionID == "rrg_b3")
        }
    }
}

private extension PerGroupActivityFixture {
    var ada: UUID { students[0] }
    var ben: UUID { students[1] }
    var alan: UUID { students[2] }
    var ari: UUID { students[3] }
}
