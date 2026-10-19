// Tests/APITests/Gamification/TournamentArenaTests.swift
//
// The projector arena (docs/class-activities.md, "Projector arena"): a
// tournament on a browser-graded assignment waits for the present page, not
// a runner. These pin that its matches are stored `arena` and never claimed,
// which match the arena plays next and with which seed, that a landed result
// decides the slot and opens the next round in the arena too, that a match
// lands once, and who may reach the three routes.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct TournamentArenaTests {

    private func browserTournamentManifest() throws -> String {
        let props = TestProperties(
            gradingMode: .browser,
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.py")],
            language: .python,
            activity: ClassActivity(kind: .elimination),
            achievements: [ActivityAuthoring.seededTournamentRecord])
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    /// A browser-graded tournament setup plus `count` enrolled students, each
    /// with one complete submission `<prefix>_s<n>` submitted in seed order.
    private func fixture(_ app: Application, prefix: String, students count: Int) async throws -> APITestSetup {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let setupID = "\(prefix)_setup"
        let setup = APITestSetup(
            id: setupID, manifest: try browserTournamentManifest(),
            zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID)
        try await setup.save(on: app.db)
        _ = try await arInsertAssignment(testSetupID: setupID, title: "Arena \(prefix)", isOpen: true, on: app)
        for index in 1...count {
            let user = try await arInsertStudent(username: "\(prefix)_u\(index)", on: app)
            try await arEnrollStudentInTestCourse(user, on: app)
            let sub = try await arInsertSubmission(
                id: "\(prefix)_s\(index)", testSetupID: setupID, userID: try user.requireID(), on: app)
            sub.submittedAt = Date(timeIntervalSince1970: 1_000_000 + Double(index * 60))
            try await sub.save(on: app.db)
        }
        return setup
    }

    private func collection(setupID: String, passed: Bool, submissionID: String = "browser") -> TestOutcomeCollection {
        let outcome = TestOutcome.stub(
            status: passed ? .pass : .fail, shortResult: "", score: passed ? 1 : 0, metric: passed ? 1 : 0)
        return TestOutcomeCollection(
            submissionID: submissionID, testSetupID: setupID, attemptNumber: 1, buildStatus: .passed,
            compilerOutput: nil, outcomes: [outcome], totalTests: 1,
            passCount: passed ? 1 : 0, failCount: passed ? 0 : 1, errorCount: 0,
            timeoutCount: 0, executionTimeMs: 1, runnerVersion: "browser", timestamp: Date())
    }

    // MARK: - The service

    /// Four entrants, two first-round matches: both wait for the arena, and
    /// the runner's claim scan finds neither.
    @Test func aBrowserGradedRoundWaitsForTheArenaAndNoRunnerClaimsIt() async throws {
        try await withAssignmentRoutesApp { app in
            let setup = try await fixture(app, prefix: "wait", students: 4)
            let run = try await startTournament(setup: setup, schedule: .bracket, startedBy: nil, on: app.db)
            let matches = try await APISubmission.query(on: app.db)
                .filter(\.$kind == APISubmission.Kind.tournamentMatch)
                .all()
            #expect(matches.count == 2)
            #expect(matches.allSatisfy { $0.statusValue == .arena })
            let candidates = try await collectClaimCandidates(on: app.db)
            #expect(!candidates.contains { $0.0.kind == APISubmission.Kind.tournamentMatch })
            #expect(run.status == APITournamentRun.Status.running)
        }
    }

    /// The lowest undecided slot comes first, with the seed a runner would
    /// set for the same match.
    @Test func theNextMatchIsTheLowestWaitingSlotWithTheWorkerSeed() async throws {
        try await withAssignmentRoutesApp { app in
            let setup = try await fixture(app, prefix: "next", students: 4)
            try await startTournament(setup: setup, schedule: .bracket, startedBy: nil, on: app.db)
            let match = try #require(try await nextArenaMatch(testSetupID: "next_setup", on: app.db))
            #expect(match.round == 1)
            #expect(match.position == 0)
            #expect(match.homeSeed == 1)
            #expect(match.awaySeed == 4)
            #expect(match.awaySubmissionID == "next_s4")
            #expect(
                match.matchSeed
                    == JobOpponent.matchSeed(
                        submissionID: match.matchSubmissionID,
                        opponentIdentity: JobOpponent.submissionIdentity("next_s4")))
            #expect(try await nextArenaMatch(testSetupID: "no_such_setup", on: app.db) == nil)
        }
    }

    /// Playing every match in order: each result decides its slot, the
    /// second round also waits for the arena, and the last result names the
    /// winner. Seed 1 wins every match it plays as the home side.
    @Test func resultsDecideSlotsAndTheNextRoundAlsoWaitsForTheArena() async throws {
        try await withAssignmentRoutesApp { app in
            let setup = try await fixture(app, prefix: "play", students: 4)
            let run = try await startTournament(setup: setup, schedule: .bracket, startedBy: nil, on: app.db)
            var rounds: [Int] = []
            while let match = try await nextArenaMatch(testSetupID: "play_setup", on: app.db) {
                rounds.append(match.round)
                let pending = try #require(try await APISubmission.find(match.matchSubmissionID, on: app.db))
                #expect(pending.statusValue == .arena)
                try await recordArenaMatch(
                    matchSubmissionID: match.matchSubmissionID, testSetupID: "play_setup",
                    collection: collection(
                        setupID: "play_setup", passed: true, submissionID: match.matchSubmissionID),
                    application: app, on: app.db)
                let played = try #require(try await APISubmission.find(match.matchSubmissionID, on: app.db))
                #expect(played.statusValue == .complete)
                let row = try #require(
                    try await APIMatchResult.query(on: app.db)
                        .filter(\.$submissionID == match.matchSubmissionID)
                        .first())
                #expect(row.won == true)
                #expect(row.seed == match.matchSeed)
            }
            #expect(rounds == [1, 1, 2])
            let done = try #require(try await APITournamentRun.find(try run.requireID(), on: app.db))
            #expect(done.status == APITournamentRun.Status.complete)
            #expect(done.winnerUserID == run.entrants.first { $0.seed == 1 }?.userID)
        }
    }

    /// A match lands once; a submission that is no arena match never does.
    @Test func aMatchLandsOnceAndNothingElseLands() async throws {
        try await withAssignmentRoutesApp { app in
            let setup = try await fixture(app, prefix: "once", students: 2)
            try await startTournament(setup: setup, schedule: .bracket, startedBy: nil, on: app.db)
            let match = try #require(try await nextArenaMatch(testSetupID: "once_setup", on: app.db))
            let result = collection(setupID: "once_setup", passed: false, submissionID: match.matchSubmissionID)
            try await recordArenaMatch(
                matchSubmissionID: match.matchSubmissionID, testSetupID: "once_setup", collection: result,
                application: app, on: app.db)
            await #expect(throws: ArenaResultError.alreadyPlayed) {
                try await recordArenaMatch(
                    matchSubmissionID: match.matchSubmissionID, testSetupID: "once_setup", collection: result,
                    application: app, on: app.db)
            }
            await #expect(throws: ArenaResultError.notAnArenaMatch) {
                try await recordArenaMatch(
                    matchSubmissionID: "once_s1", testSetupID: "once_setup",
                    collection: collection(setupID: "once_setup", passed: true, submissionID: "once_s1"),
                    application: app, on: app.db)
            }
            // A collection for another setup, or for another submission, is
            // refused before anything is read.
            await #expect(throws: ArenaResultError.notAnArenaMatch) {
                try await recordArenaMatch(
                    matchSubmissionID: match.matchSubmissionID, testSetupID: "once_setup",
                    collection: collection(setupID: "once_setup", passed: true), application: app, on: app.db)
            }
            await #expect(throws: ArenaResultError.notAnArenaMatch) {
                try await recordArenaMatch(
                    matchSubmissionID: match.matchSubmissionID, testSetupID: "once_setup",
                    collection: collection(
                        setupID: "elsewhere", passed: true, submissionID: match.matchSubmissionID),
                    application: app, on: app.db)
            }
            // The away side won the one match.
            let run = try #require(try await latestTournament(testSetupID: "once_setup", on: app.db))
            #expect(run.run.status == APITournamentRun.Status.complete)
            #expect(run.run.winnerUserID == run.run.entrants.first { $0.seed == 2 }?.userID)
        }
    }

    // MARK: - The routes

    /// Staff read the next match, download its two sides and post its
    /// result; a second post is a conflict, and a student reaches nothing.
    @Test func staffPlayAMatchThroughTheRoutes() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let setup = try await fixture(app, prefix: "route", students: 2)
            try await startTournament(setup: setup, schedule: .bracket, startedBy: nil, on: app.db)
            let base = "/testsetups/route_setup/arena"

            var match: ArenaMatchResponse?
            try await app.asyncTest(
                .GET, base + "/next",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    match = try? res.content.decode(ArenaMatchResponse.self)
                })
            let next = try #require(match)
            #expect(next.awaySubmissionID == "route_s2")
            // The match is a frozen copy of seed 1's upload, so they share a file.
            for id in ["route_s1", "route_s2"] {
                try Data("upload \(id)".utf8).write(to: URL(fileURLWithPath: app.submissionsDirectory + "\(id).zip"))
            }

            let downloads: [(String, HTTPStatus)] = [
                (next.matchSubmissionID, .ok), ("route_s2", .ok), ("route_s1", .notFound),
            ]
            for (id, expected) in downloads {
                try await app.asyncTest(
                    .GET, base + "/submissions/\(id)",
                    beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                    afterResponse: { res in
                        #expect(res.status == expected, "\(id)")
                        if expected == .ok { #expect(res.body.string.hasPrefix("upload route_s")) }
                    })
            }

            let assignment = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$testSetupID == "route_setup").first())
            let (csrf, sessionCookie) = try await csrfFields(
                for: "/instructor/\(assignment.publicID)/submissions", cookie: cookie, on: app)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let body = ArenaResultBody(
                collection: try #require(
                    String(data: encoder.encode(collection(setupID: "route_setup", passed: true)), encoding: .utf8)))
            for expected in [HTTPStatus.noContent, .conflict] {
                try await app.asyncTest(
                    .POST, base + "/matches/\(next.matchSubmissionID)/result",
                    beforeRequest: { req in
                        req.headers.add(name: .cookie, value: sessionCookie)
                        req.headers.add(name: "x-csrf-token", value: csrf)
                        try req.content.encode(body, as: .json)
                    },
                    afterResponse: { res in #expect(res.status == expected) })
            }
            try await app.asyncTest(
                .GET, base + "/next",
                beforeRequest: { req in req.headers.add(name: .cookie, value: sessionCookie) },
                afterResponse: { res in #expect(res.status == .noContent) })

            let student = try await arLoginAsStudent(on: app)
            try await app.asyncTest(
                .GET, base + "/next",
                beforeRequest: { req in req.headers.add(name: .cookie, value: student) },
                afterResponse: { res in #expect(res.status == .notFound) })
        }
    }

    /// The present page shows the arena control only on a browser-graded
    /// tournament, and loads the grading stack with it.
    @Test func thePresentPageCarriesTheArenaOnlyWhenBrowserGraded() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            _ = try await fixture(app, prefix: "show", students: 2)
            try await app.asyncTest(
                .GET, "/testsetups/show_setup/leaderboard?present=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Play matches"))
                    #expect(html.contains("data-arena-setup-id=\"show_setup\""))
                    #expect(html.contains("/tournament-arena.js"))
                    #expect(html.contains("/browser-runner.js"))
                    #expect(html.contains("name=\"csrf-token\""))
                })

            let worker = APITestSetup(
                id: "show_worker",
                manifest: try browserTournamentManifest().replacingOccurrences(
                    of: "\"gradingMode\":\"browser\"", with: "\"gradingMode\":\"worker\""),
                zipPath: app.testSetupsDirectory + "show_worker.zip",
                courseID: try await app.testCourseID(enrollmentMode: .auto))
            try await worker.save(on: app.db)
            try await app.asyncTest(
                .GET, "/testsetups/show_worker/leaderboard?present=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(!res.body.string.contains("Play matches"))
                    #expect(!res.body.string.contains("/browser-runner.js"))
                })
        }
    }
}
