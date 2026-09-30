// Tests/APITests/LeaderboardKindsPageTests.swift
//
// The leaderboard page for the kinds that are not a plain metric ranking: a
// round robin's standings, a tests-and-code activity, a hill, and a bracket.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct LeaderboardKindsPageTests {

    private func manifest(_ kind: ActivityKind) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            activity: ClassActivity(kind: kind, leaderboardVisibility: .visible))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    private func get(_ path: String, cookie: String, on app: Application) async throws -> String {
        var captured: TestingHTTPResponse?
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in captured = res })
        return try #require(captured).body.string
    }

    private func seedSetup(
        _ id: String, kind: ActivityKind, on app: Application
    ) async throws -> APIUser {
        let setup = try await wrInsertSetup(id: id, manifest: try manifest(kind), on: app)
        _ = try await makeTestAssignment(
            on: app, testSetupID: id, courseID: setup.courseID, title: id)
        let viewer = try await wrStudentUser(on: app)
        try await wrEnrollUser(viewer, on: app)
        return viewer
    }

    private func classmate(_ name: String, on app: Application) async throws -> APIUser {
        let user = try await makeTestUser(on: app, username: name, role: "student")
        try await wrEnrollUser(user, on: app)
        return user
    }

    // MARK: - Round robin

    @Test func standingsShowTheRecordAsDetailsAndAWindowAroundTheViewer() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let viewer = try await seedSetup("lk_robin", kind: .roundRobin, on: app)
            // Twelve students; the viewer is ninth.
            for place in 0..<12 {
                let user = place == 8 ? viewer : try await classmate("lk_robin_\(place)", on: app)
                try await APIActivityStanding(
                    testSetupID: "lk_robin", userID: try user.requireID(),
                    submissionID: "lk_robin_\(place)", played: 4, wins: 12 - place, draws: 0,
                    losses: place, scoreSum: Double(12 - place), updatedAt: Date()
                ).save(on: app.db)
            }
            let html = try await get("/testsetups/lk_robin/leaderboard", cookie: cookie, on: app)
            #expect(html.contains("P 4 · W 4 · D 0 · L 8"))
            #expect(html.contains("9th"))
            #expect(html.contains("of 12"))
            #expect(html.contains("Your average"))
            #expect(html.contains("3 more · 4–6"))
            #expect(!html.contains("<th class=\"time\">Played</th>"))
        }
    }

    // MARK: - Tests and code

    @Test func theUnionCardPicksTheViewersOwnRowsFromBothHalves() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let viewer = try await seedSetup("lk_union", kind: .testsVersusImplementations, on: app)
            let mate = try await classmate("lk_union_mate", on: app)
            for (id, user) in [("lk_union_v", viewer), ("lk_union_m", mate)] {
                try await APISubmission(
                    id: id, testSetupID: "lk_union", zipPath: "/tmp/\(id).zip", attemptNumber: 1,
                    status: SubmissionStatus.complete.rawValue, filename: "\(id).py",
                    userID: try user.requireID()
                ).save(on: app.db)
            }
            let row = APIMatchResult(
                testSetupID: "lk_union", submissionID: "lk_union_v",
                opponentSubmissionID: "lk_union_m",
                opponentIdentity: JobOpponent.submissionIdentity("lk_union_m"),
                seed: "s", createdAt: Date())
            row.won = true
            row.completedAt = Date()
            try await row.save(on: app.db)

            let html = try await get("/testsetups/lk_union/leaderboard", cookie: cookie, on: app)
            #expect(html.contains("Your tests found 1 fault · your code is not tested yet"))
            #expect(html.contains("Tested 1 classmate · 0 have tested you"))
            #expect(html.contains("class=\"you-card-kicker\">You · "))
            // The Tests list carries the record as details and the defeated
            // count as its value; the Code list carries the status as text.
            #expect(html.contains("tested 1"))
            #expect(html.contains("not tested yet · tested by 0"))
            #expect(html.contains("defeated · tested by 1"))
            #expect(!html.contains("tier-preview\">defeated"))
        }
    }

    // MARK: - The hill

    @Test func theChampionCardReplacesTheParagraphAndTintsForTheHolder() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let viewer = try await seedSetup("lk_hill", kind: .kingOfTheHill, on: app)
            let holder = try await classmate("lk_hill_holder", on: app)

            let none = try await get("/testsetups/lk_hill/leaderboard", cookie: cookie, on: app)
            #expect(none.contains("No student holds the hill yet."))
            #expect(!none.contains("champion-card"))

            try await APIActivityChampion(
                testSetupID: "lk_hill", userID: try holder.requireID(), submissionID: "lk_hill_h",
                crownedAt: Date(), defences: 1
            ).save(on: app.db)
            let other = try await get("/testsetups/lk_hill/leaderboard", cookie: cookie, on: app)
            #expect(other.contains("class=\"champion-card card\""))
            #expect(other.contains("Holds the hill"))
            #expect(other.contains("1 defence"))
            #expect(other.contains("beat their submission to take it"))
            #expect(other.contains("avatar avatar-lg"))
            #expect(!other.contains("Champion:"))

            let champion = try #require(
                try await APIActivityChampion.query(on: app.db).first())
            champion.userID = try viewer.requireID()
            try await champion.update(on: app.db)
            let mine = try await get("/testsetups/lk_hill/leaderboard", cookie: cookie, on: app)
            #expect(mine.contains("class=\"champion-card card you-card\""))
            #expect(mine.contains("you-pill"))
        }
    }

    // MARK: - The bracket

    @Test func theBracketLabelsItsFinalMarksByesLiveMatchesAndTheViewer() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let viewer = try await seedSetup("lk_cup", kind: .elimination, on: app)
            let mate = try await classmate("lk_cup_mate", on: app)
            let third = try await classmate("lk_cup_third", on: app)
            let run = try APITournamentRun(
                testSetupID: "lk_cup", schedule: .bracket, startedBy: nil, startedAt: Date(),
                entrants: [
                    TournamentEntrant(seed: 1, userID: try viewer.requireID(), submissionID: "lk_cup_v"),
                    TournamentEntrant(seed: 2, userID: try mate.requireID(), submissionID: "lk_cup_m"),
                    TournamentEntrant(seed: 3, userID: try third.requireID(), submissionID: "lk_cup_t"),
                ])
            try await run.save(on: app.db)
            let runID = try run.requireID()
            try await APITournamentMatch(
                tournamentID: runID,
                slot: TournamentSlot(round: 1, position: 0, homeSeed: 1, awaySeed: nil, winnerSeed: 1),
                matchSubmissionID: nil, completedAt: Date()
            ).save(on: app.db)
            try await APITournamentMatch(
                tournamentID: runID, slot: TournamentSlot(round: 1, position: 1, homeSeed: 2, awaySeed: 3),
                matchSubmissionID: "lk_cup_match", completedAt: nil
            ).save(on: app.db)
            try await APITournamentMatch(
                tournamentID: runID, slot: TournamentSlot(round: 2, position: 0, homeSeed: 1, awaySeed: 2),
                matchSubmissionID: nil, completedAt: nil
            ).save(on: app.db)

            let html = try await get("/testsetups/lk_cup/leaderboard", cookie: cookie, on: app)
            #expect(html.contains(">Round 1<"))
            #expect(html.contains(">Final<"))
            #expect(html.contains("class=\"bracket\""))
            #expect(html.contains("class=\"bracket-entrant text-muted\">bye<"))
            #expect(html.contains("tier tier-preview\">live"))
            #expect(html.contains("bracket-entrant bracket-entrant--you"))
            #expect(html.contains("table-scroll"))
            // No winner yet, so no winner card.
            #expect(!html.contains("aria-label=\"Winner\""))

            run.status = APITournamentRun.Status.complete
            run.winnerUserID = try viewer.requireID()
            try await run.update(on: app.db)
            let done = try await get("/testsetups/lk_cup/leaderboard", cookie: cookie, on: app)
            #expect(done.contains("aria-label=\"Winner\""))
            #expect(done.contains("champion-card card you-card"))
        }
    }
}
