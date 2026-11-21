// Tests/APITests/Gamification/LeaderboardBuilderTests.swift
//
// The leaderboard builders read directly (docs/class-activities.md): the
// metric board ranks highest first with tied ranks, a student reader gets
// no name, username or submission count, a viewer who is not enrolled gets
// no card, a union viewer with no submission gets the invitation card, a
// tournament bracket names a decided match and a superseded run, and a
// per-group standings board for a student in no group is empty.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct LeaderboardBuilderTests {

    private func manifest(_ activity: ClassActivity) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")], language: nil, activity: activity)
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    private func enrolledStudents(_ prefix: String, count: Int, on app: Application) async throws -> [APIUser] {
        var users: [APIUser] = []
        for index in 0..<count {
            let user = try await makeTestUser(on: app, username: "\(prefix)_\(index)", role: "student")
            try await wrEnrollUser(user, on: app)
            users.append(user)
        }
        return users
    }

    // MARK: - Metric board

    /// Highest metric first; an equal metric shares the rank and the next
    /// rank skips; the earlier of a tie lists first. A student reads handles
    /// only. Staff read the username and the submission count.
    @Test func theMetricBoardRanksHighestFirstAndHidesIdentityFromStudents() async throws {
        try await withTestApp { app in
            let setup = try await wrInsertSetup(
                id: "lbg_metric",
                manifest: try manifest(ClassActivity(kind: .bestMetric, leaderboardVisibility: .visible)), on: app)
            let users = try await enrolledStudents("lbg_metric", count: 3, on: app)
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            // Inserted lowest first, so the order on the board is the sort's.
            let seeds: [(user: Int, metric: Double, reached: Double)] = [(2, 10, 0), (1, 30, 60), (0, 30, 30)]
            for seed in seeds {
                try await APILeaderboardEntry(
                    testSetupID: "lbg_metric", userID: try users[seed.user].requireID(),
                    submissionID: "lbg_metric_best_\(seed.user)", metric: seed.metric,
                    reachedAt: base.addingTimeInterval(seed.reached)
                ).save(on: app.db)
            }
            for (user, count) in [(0, 2), (1, 1)] {
                for index in 0..<count {
                    _ = try await makeTestSubmission(
                        on: app, id: "lbg_metric_sub_\(user)_\(index)", setupID: "lbg_metric",
                        userID: try users[user].requireID())
                }
            }

            let student = try await buildLeaderboard(
                setup: setup, reader: .page(user: users[1], isStaff: false), showAll: true, on: app.db)
            #expect(student.rows.map(\.rank) == [1, 1, 3])
            #expect(student.rows.map(\.isTied) == [true, true, false])
            #expect(student.rows.map(\.metricText) == ["30", "30", "10"])
            #expect(student.rows.map(\.isViewer) == [false, true, false])
            #expect(student.rows.allSatisfy { $0.name.isEmpty && $0.username.isEmpty })
            #expect(student.rows.allSatisfy { $0.submissionCountText.isEmpty && $0.bestSubmissionURL.isEmpty })
            #expect(
                student.rows.map(\.tieNote) == [
                    "Tied · reached it first", "Tied · reached it under a minute later", "",
                ])
            #expect(student.you?.isRanked == true)

            let staffReader = LeaderboardReader.page(user: users[0], isStaff: true)
            let staff = try await buildLeaderboard(setup: setup, reader: staffReader, showAll: true, on: app.db)
            #expect(staff.rows.map(\.username) == ["lbg_metric_0", "lbg_metric_1", "lbg_metric_2"])
            #expect(staff.rows.map(\.submissionCountText) == ["2 submissions", "1 submission", "0 submissions"])
            #expect(staff.you == nil)
        }
    }

    /// A reader who is not on the course roster gets no card of their own;
    /// an enrolled student with no metric gets the invitation.
    @Test func aViewerOffTheRosterGetsNoCard() async throws {
        try await withTestApp { app in
            let setup = try await wrInsertSetup(
                id: "lbg_card",
                manifest: try manifest(ClassActivity(kind: .bestMetric, leaderboardVisibility: .visible)), on: app)
            let users = try await enrolledStudents("lbg_card", count: 2, on: app)
            try await APILeaderboardEntry(
                testSetupID: "lbg_card", userID: try users[0].requireID(), submissionID: "lbg_card_best",
                metric: 5, reachedAt: Date()
            ).save(on: app.db)
            let outsider = try await makeTestUser(on: app, username: "lbg_card_outsider", role: "student")

            let outside = try await buildLeaderboard(
                setup: setup, reader: .page(user: outsider, isStaff: false), showAll: true, on: app.db)
            #expect(outside.you == nil)
            #expect(outside.rankedCount == 1)

            let unranked = try await buildLeaderboard(
                setup: setup, reader: .page(user: users[1], isStaff: false), showAll: true, on: app.db)
            let card = try #require(unranked.you)
            #expect(!card.isRanked)
            #expect(card.rankHeadline == "Not on the board yet")
        }
    }

    // MARK: - Union

    @Test func aUnionViewerWithNoSubmissionGetsTheInvitationCard() async throws {
        try await withTestApp { app in
            let setup = try await wrInsertSetup(
                id: "lbg_union", manifest: try manifest(ClassActivity(kind: .testsVersusImplementations)), on: app)
            let users = try await enrolledStudents("lbg_union", count: 2, on: app)
            _ = try await makeTestSubmission(
                on: app, id: "lbg_union_sub", setupID: "lbg_union", userID: try users[0].requireID())

            let union = try #require(
                try await buildUnionPresentation(
                    setup: setup, reader: .page(user: users[1], isStaff: false), showAll: true,
                    allURL: "/testsetups/lbg_union/leaderboard?all=1", on: app.db))
            #expect(union.hasYou)
            let you = try #require(union.you)
            #expect(!you.isRanked)
            #expect(you.titleText == "Not on the board yet")
            #expect(you.noteText.isEmpty)
            #expect(you.submitURL == "/testsetups/lbg_union/submit")
            #expect(union.kills.allSatisfy { $0.name.isEmpty && !$0.isViewer })
            #expect(union.defences.allSatisfy { $0.name.isEmpty })

            let outsider = try await makeTestUser(on: app, username: "lbg_union_outsider", role: "student")
            let outside = try #require(
                try await buildUnionPresentation(
                    setup: setup, reader: .page(user: outsider, isStaff: false), showAll: true,
                    allURL: "/testsetups/lbg_union/leaderboard?all=1", on: app.db))
            #expect(!outside.hasYou)
            #expect(outside.you == nil)
        }
    }

    // MARK: - Tournament

    /// A match with a winner reads "decided", one without reads "in
    /// progress", and a seed with no opponent reads "bye". A superseded run
    /// says so and shows no match as live. A student reader gets no name.
    @Test func aSupersededBracketShowsDecidedMatchesAndNoLiveOnes() async throws {
        try await withTestApp { app in
            let setup = try await wrInsertSetup(
                id: "lbg_bracket",
                manifest: try manifest(ClassActivity(kind: .bestMetric, leaderboardVisibility: .visible)), on: app)
            let users = try await enrolledStudents("lbg_bracket", count: 4, on: app)
            let entrants = try users.enumerated().map { index, user in
                TournamentEntrant(seed: index + 1, userID: try user.requireID(), submissionID: "lbg_bracket_\(index)")
            }
            let run = try APITournamentRun(
                testSetupID: "lbg_bracket", schedule: .bracket, startedBy: nil,
                startedAt: Date(timeIntervalSince1970: 1_800_000_000), entrants: entrants)
            run.status = APITournamentRun.Status.superseded
            try await run.save(on: app.db)
            let runID = try run.requireID()
            let slots = [
                TournamentSlot(round: 1, position: 0, homeSeed: 1, awaySeed: 4, winnerSeed: 4),
                TournamentSlot(round: 1, position: 1, homeSeed: 2, awaySeed: 3),
                TournamentSlot(round: 2, position: 0, homeSeed: 4, awaySeed: nil),
            ]
            for slot in slots {
                try await APITournamentMatch(
                    tournamentID: runID, slot: slot, matchSubmissionID: nil, completedAt: nil
                ).save(on: app.db)
            }

            let bracket = try #require(
                try await buildTournamentPresentation(
                    setup: setup, viewerID: try users[3].requireID(), includeNames: false, on: app.db))
            #expect(bracket.progressLabel == "Run")
            #expect(bracket.progressValue == "Superseded")
            #expect(!bracket.isComplete)
            #expect(!bracket.hasWinner)
            #expect(bracket.rounds.map(\.label) == ["Round 1", "Final"])
            let first = bracket.rounds[0].matches
            #expect(first.map(\.resultText) == ["decided", "in progress"])
            #expect(first.map(\.awayWon) == [true, false])
            #expect(first.map(\.homeWon) == [false, false])
            #expect(bracket.rounds.flatMap(\.matches).allSatisfy { !$0.isLive })
            #expect(bracket.rounds[1].matches.map(\.resultText) == ["bye"])
            #expect(first[0].away?.isViewer == true)
            #expect(bracket.rounds.flatMap(\.matches).compactMap(\.home).allSatisfy { $0.name.isEmpty })

            let staffView = try #require(
                try await buildTournamentPresentation(setup: setup, viewerID: nil, includeNames: true, on: app.db))
            #expect(staffView.rounds[0].matches[0].home?.name == "lbg_bracket_0")
        }
    }

    // MARK: - Per-group standings

    @Test func aStudentInNoGroupGetsAnEmptyStandingsBoard() async throws {
        try await withTestApp { app in
            let setup = try await wrInsertSetup(
                id: "lbg_standings",
                manifest: try manifest(ClassActivity(kind: .bestMetric, leaderboardVisibility: .visible)), on: app)
            let users = try await enrolledStudents("lbg_standings", count: 1, on: app)
            let noGroup = LeaderboardGroupScope(groupID: nil, groupName: nil, options: [], isLive: false)

            let board = try await buildStandingsBoard(
                setup: setup, reader: .page(user: users[0], isStaff: false), showAll: true, scope: noGroup,
                on: app.db)
            #expect(board.rows.isEmpty)
            #expect(board.items.isEmpty)
            #expect(board.you == nil)
            #expect(board.rankedCount == 0)
        }
    }
}
