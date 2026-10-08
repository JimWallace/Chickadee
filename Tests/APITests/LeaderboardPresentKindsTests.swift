// Tests/APITests/LeaderboardPresentKindsTests.swift
//
// Present mode for each kind: a title that names what the board ranks, a
// tournament at display scale under its winner, and the hill's holder marked
// where they stand.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct LeaderboardPresentKindsTests {

    private func manifest(_ kind: ActivityKind) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            language: nil,
            activity: ClassActivity(kind: kind, leaderboardVisibility: .visible))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    /// An activity of `kind` and a logged-in instructor enrolled as staff.
    private func seedSetup(_ id: String, kind: ActivityKind, on app: Application) async throws -> String {
        _ = try await wrLoginAsStudent(on: app)
        let setup = try await wrInsertSetup(id: id, manifest: try manifest(kind), on: app)
        _ = try await makeTestAssignment(
            on: app, testSetupID: id, courseID: setup.courseID, title: id)
        let cookie = try await wrLoginAsInstructor(on: app)
        let instructor = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
        try await wrEnrollUser(instructor, on: app)
        return cookie
    }

    private func classmate(_ name: String, on app: Application) async throws -> APIUser {
        let user = try await makeTestUser(on: app, username: name, role: "student")
        try await wrEnrollUser(user, on: app)
        return user
    }

    private func handle(of user: APIUser, on app: Application) async throws -> String {
        let enrollment = try #require(
            try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == user.requireID()).first())
        return try #require(enrollment.avatarHandle)
    }

    private func present(_ id: String, cookie: String, on app: Application) async throws -> String {
        let res = try await getResponse("/testsetups/\(id)/leaderboard?present=1", cookie: cookie, on: app)
        #expect(res.status == .ok)
        return res.body.string
    }

    @Test func aMetricBoardStandsOnTheStageWithTheFindYourselfFooter() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await seedSetup("lpk_metric", kind: .bestMetric, on: app)
            for index in 0..<4 {
                let user = try await classmate("lpk_metric_\(index)", on: app)
                try await APILeaderboardEntry(
                    testSetupID: "lpk_metric", userID: try user.requireID(),
                    submissionID: "lpk_metric_\(index)", metric: Double(10 - index), reachedAt: Date()
                ).save(on: app.db)
            }
            let html = try await present("lpk_metric", cookie: cookie, on: app)
            #expect(html.contains(">Leaderboard · highest metric<"))
            #expect(html.contains("class=\"present-stage\""))
            #expect(html.contains("Find yourself by your bird and handle on your own Leaderboard page"))
            // No session window, so the page polls and says so.
            #expect(html.contains("class=\"tier tier-preview\">Live<"))
            #expect(!html.contains("class=\"podium-kicker\""))
        }
    }

    @Test func aRoundRobinIsTitledAsStandings() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await seedSetup("lpk_robin", kind: .roundRobin, on: app)
            let user = try await classmate("lpk_robin_0", on: app)
            try await APIActivityStanding(
                testSetupID: "lpk_robin", userID: try user.requireID(), submissionID: "lpk_robin_0",
                played: 2, wins: 2, draws: 0, losses: 0, scoreSum: 2, updatedAt: Date()
            ).save(on: app.db)
            let html = try await present("lpk_robin", cookie: cookie, on: app)
            #expect(html.contains(">Standings · highest average<"))
            #expect(!html.contains("highest metric"))
        }
    }

    @Test func aTestsAndCodeActivityIsTitledByFaultsFound() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await seedSetup("lpk_union", kind: .testsVersusImplementations, on: app)
            let html = try await present("lpk_union", cookie: cookie, on: app)
            #expect(html.contains(">Tests · most faults found<"))
        }
    }

    @Test func aTournamentShowsItsBracketAtDisplayScaleAndThenItsWinner() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await seedSetup("lpk_cup", kind: .elimination, on: app)
            let first = try await classmate("lpk_cup_1", on: app)
            let second = try await classmate("lpk_cup_2", on: app)
            let third = try await classmate("lpk_cup_3", on: app)
            let run = try APITournamentRun(
                testSetupID: "lpk_cup", schedule: .bracket, startedBy: nil, startedAt: Date(),
                entrants: [
                    TournamentEntrant(seed: 1, userID: try first.requireID(), submissionID: "lpk_cup_a"),
                    TournamentEntrant(seed: 2, userID: try second.requireID(), submissionID: "lpk_cup_b"),
                    TournamentEntrant(seed: 3, userID: try third.requireID(), submissionID: "lpk_cup_c"),
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
                matchSubmissionID: "lpk_cup_match", completedAt: nil
            ).save(on: app.db)

            let live = try await present("lpk_cup", cookie: cookie, on: app)
            #expect(live.contains(">Tournament · single elimination<"))
            #expect(!live.contains("highest metric"))
            // Where the run stands goes in the clock's place, not the title.
            #expect(live.contains("class=\"present-clock-label\">Round<"))
            #expect(live.contains("class=\"present-clock-time\">1 of "))
            #expect(live.contains("class=\"present-bracket\""))
            // Three entrants, the one with a bye counted once.
            #expect(live.contains("3 on the board"))
            #expect(!live.contains("aria-label=\"Winner\""))
            #expect(!live.contains("Student One"))
            #expect(live.contains("class=\"tier tier-preview\">Live<"))

            run.status = APITournamentRun.Status.complete
            run.winnerUserID = try first.requireID()
            try await run.update(on: app.db)
            let done = try await present("lpk_cup", cookie: cookie, on: app)
            #expect(done.contains("class=\"champion-card card\" aria-label=\"Winner\""))
            #expect(done.contains(try await handle(of: first, on: app)))
            // The winner's bird is drawn at the champion card's size, not the bracket's.
            #expect(done.contains("avatar avatar-lg"))
            #expect(done.contains("class=\"present-clock-label\">Complete<"))
            // A finished run cannot change: no Live mark and no poll.
            #expect(!done.contains(">Live<"))
            #expect(!done.contains("data-poll-url"))
        }
    }

    @Test func theHillHolderOnThePodiumCarriesTheKicker() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await seedSetup("lpk_hill", kind: .kingOfTheHill, on: app)
            var users: [APIUser] = []
            for index in 0..<3 {
                let user = try await classmate("lpk_hill_\(index)", on: app)
                users.append(user)
                try await APILeaderboardEntry(
                    testSetupID: "lpk_hill", userID: try user.requireID(),
                    submissionID: "lpk_hill_\(index)", metric: Double(10 - index), reachedAt: Date()
                ).save(on: app.db)
            }
            // Second on the metric board, yet the holder.
            try await APIActivityChampion(
                testSetupID: "lpk_hill", userID: try users[1].requireID(), submissionID: "lpk_hill_1",
                crownedAt: Date()
            ).save(on: app.db)
            let html = try await present("lpk_hill", cookie: cookie, on: app)
            #expect(html.components(separatedBy: "class=\"podium-kicker\">Holds the hill<").count - 1 == 1)
            #expect(!html.contains("aria-label=\"Holder of the hill\""))
            let placeTwo = try #require(html.range(of: "aria-label=\"Place 2\""))
            let kicker = try #require(html.range(of: "Holds the hill"))
            let placeOne = try #require(html.range(of: "aria-label=\"Place 1\""))
            // Podium order is 2-1-3: the kicker sits in place 2, before place 1.
            #expect(placeTwo.lowerBound < kicker.lowerBound)
            #expect(kicker.lowerBound < placeOne.lowerBound)
        }
    }

    @Test func aHillHolderOffThePodiumGetsACardOfTheirOwn() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await seedSetup("lpk_off", kind: .kingOfTheHill, on: app)
            let holder = try await classmate("lpk_off_holder", on: app)
            try await APIActivityChampion(
                testSetupID: "lpk_off", userID: try holder.requireID(), submissionID: "lpk_off_h",
                crownedAt: Date()
            ).save(on: app.db)
            let html = try await present("lpk_off", cookie: cookie, on: app)
            #expect(html.contains("class=\"champion-card card\" aria-label=\"Holder of the hill\""))
            #expect(html.contains(try await handle(of: holder, on: app)))
            #expect(!html.contains("Holds the hill:"))
        }
    }

    @Test func resizingABirdChangesOnlyItsSize() {
        let bird = AvatarPresentation(
            for: AvatarSpec.drawn(fromSeed: 7), size: .small, accessibility: .decorative, isStaff: false)
        let drawnBig = AvatarPresentation(
            for: AvatarSpec.drawn(fromSeed: 7), size: .podium, accessibility: .decorative, isStaff: false)
        #expect(bird.resized(to: .podium) == drawnBig)
        #expect(bird.resized(to: .podium).layerRefs == bird.layerRefs)
    }
}
