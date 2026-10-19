// Tests/APITests/Groups/TournamentPerGroupTests.swift
//
// A tournament run once per lab group (docs/lab-groups.md, slice 3d): a
// group's run is entered by the students who joined its session, two labs
// play at once and each reads its own bracket, the run control offers the
// groups and warns before it supersedes a lab's run, a run needs a group and a
// started session, no lab's winner holds the course's class record and none
// is seeded, turning the flag off supersedes the labs' runs, and MCP starts
// no per-group run.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class TournamentPerGroupTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-tournament-groups")
    }

    private struct Fixture {
        let setup: APITestSetup
        let assignmentID: UUID
        let labA: UUID
        let labB: UUID
        let ada: UUID
        let ben: UUID
        let alan: UUID
        let ari: UUID
    }

    private let setupID = "tpg_setup"

    /// A per-group tournament with ada and ben in Lab 101 and alan and ari in
    /// Lab 102, each with a complete submission.
    private func fixture() async throws -> Fixture {
        let course = try await makeTestCourse(on: app, code: "TPG1", mode: .closed)
        let courseID = try course.requireID()
        let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
        let labA = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db).requireID()
        let labB = try await CourseGroupStore.addGroup(named: "Lab 102", to: set, on: app.db).requireID()
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")], language: nil,
            activity: ClassActivity(kind: .elimination, runsPerGroup: true),
            achievements: [ActivityAuthoring.seededTournamentRecord])
        let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
        let setup = try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest)
        let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        var students: [UUID] = []
        for (name, group) in [("tpg_ada", labA), ("tpg_ben", labA), ("tpg_alan", labB), ("tpg_ari", labB)] {
            let id = try await makeTestStudent(on: app, username: name).requireID()
            try await makeTestEnrollment(on: app, userID: id, courseID: courseID)
            try await CourseGroupStore.setMembership(userID: id, groupID: group, in: set, on: app.db)
            try await makeTestSubmission(on: app, id: "\(name)_s1", setupID: setupID, userID: id)
            students.append(id)
        }
        return Fixture(
            setup: setup, assignmentID: try assignment.requireID(), labA: labA, labB: labB,
            ada: students[0], ben: students[1], alan: students[2], ari: students[3])
    }

    /// Opens the group's session, unless it is open, and joins `userID`.
    private func join(_ f: Fixture, group: UUID, userID: UUID) async throws {
        let session = try await ActivitySessionStore.open(
            assignmentID: f.assignmentID, groupID: group, by: nil, now: Date().addingTimeInterval(-60), on: app.db)
        let joinedAt = Date().addingTimeInterval(-30)
        try await ActivitySessionStore.join(
            code: ActivitySessionCode.code(secret: session.codeSecret, at: joinedAt), userID: userID,
            now: joinedAt, on: app.db)
    }

    private func joinEveryone(_ f: Fixture) async throws {
        for (student, group) in [(f.ada, f.labA), (f.ben, f.labA), (f.alan, f.labB), (f.ari, f.labB)] {
            try await join(f, group: group, userID: student)
        }
    }

    private func start(_ f: Fixture, group: UUID?) async throws -> APITournamentRun {
        try await startTournament(setup: f.setup, schedule: .bracket, startedBy: nil, groupID: group, on: app.db)
    }

    /// The refusal `start` throws, or nil when it starts a run.
    private func refusal(_ f: Fixture, group: UUID?) async -> String? {
        do {
            _ = try await start(f, group: group)
            return nil
        } catch let error as TournamentStartError {
            return error.reason
        } catch {
            return "\(error)"
        }
    }

    @Test func aGroupsRunIsEnteredByItsSessionsStudents() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            try await joinEveryone(f)
            let run = try await start(f, group: f.labA)
            #expect(run.groupID == f.labA)
            #expect(Set(run.entrants.map(\.userID)) == [f.ada, f.ben])
            #expect(run.entrants.map(\.seed) == [1, 2])
        }
    }

    @Test func twoLabsPlayAtOnceAndEachReadsItsOwnBracket() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            try await joinEveryone(f)
            let runA = try await start(f, group: f.labA)
            let runB = try await start(f, group: f.labB)

            let reloadedA = try #require(try await APITournamentRun.find(runA.requireID(), on: app.db))
            #expect(reloadedA.status == APITournamentRun.Status.running, "Lab 102's run supersedes nothing in Lab 101")
            #expect(try await latestTournament(testSetupID: setupID, groupID: f.labA, on: app.db)?.run.id == runA.id)
            #expect(try await latestTournament(testSetupID: setupID, groupID: f.labB, on: app.db)?.run.id == runB.id)
            #expect(try await latestTournament(testSetupID: setupID, on: app.db) == nil, "no whole-class run")

            // A second run in Lab 101 supersedes only Lab 101's.
            _ = try await start(f, group: f.labA)
            #expect(try await APITournamentRun.find(runA.requireID(), on: app.db)?.status == "superseded")
            #expect(try await APITournamentRun.find(runB.requireID(), on: app.db)?.status == "running")
        }
    }

    @Test func theRunControlOffersTheGroupsAndWarnsBeforeSuperseding() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            let before = try await TournamentControlFacts.make(setup: f.setup, on: app.db)
            #expect(before.isPerGroup)
            #expect(before.groupOptions.map(\.name) == ["Lab 101", "Lab 102"])
            #expect(!before.hasRunInProgress)

            try await joinEveryone(f)
            _ = try await start(f, group: f.labA)
            let after = try await TournamentControlFacts.make(setup: f.setup, on: app.db)
            #expect(after.hasRunInProgress, "the form asks before it supersedes a lab's run")
            #expect(after.supersedeConfirm.contains("chosen group"))
        }
    }

    @Test func aPerGroupTournamentSeedsNoWinnerRecord() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            func hasRecord() async throws -> Bool {
                let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
                return setup.decodedManifest()?.achievements.contains {
                    $0.id == ActivityAuthoring.seededTournamentRecordID
                } == true
            }
            #expect(try await hasRecord(), "the fixture carries the seeded record")
            _ = try await ActivityAuthoring.setActivity(
                setup: f.setup, to: ClassActivity(kind: .elimination, runsPerGroup: true), on: app.db)
            #expect(try await !hasRecord())
        }
    }

    @Test func turningTheFlagOffSupersedesTheLabsRuns() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            try await joinEveryone(f)
            let runA = try await start(f, group: f.labA)
            let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
            _ = try await ActivityAuthoring.setActivity(setup: setup, to: ClassActivity(kind: .elimination), on: app.db)
            #expect(
                try await APITournamentRun.find(runA.requireID(), on: app.db)?.status
                    == APITournamentRun.Status.superseded,
                "a lab's run does not play on where no page shows it")
        }
    }

    @Test func aPerGroupRunNeedsAGroupAndAStartedSession() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            #expect(await refusal(f, group: nil) == TournamentStartError.noGroupChosen.reason)
            #expect(await refusal(f, group: f.labA) == TournamentStartError.noSession.reason)

            // Only ada joined: one entrant is too few.
            try await join(f, group: f.labA, userID: f.ada)
            #expect(await refusal(f, group: f.labA) == TournamentStartError.tooFewEntrants(1).reason)
        }
    }

    @Test func aLabsWinnerHoldsNoClassRecord() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            try await joinEveryone(f)
            let run = try await start(f, group: f.labA)
            // Two entrants: one match decides the run.
            let slot = try #require(
                try await APITournamentMatch.query(on: app.db).filter(\.$tournamentID == run.requireID()).first())
            let match = try #require(try await APISubmission.find(slot.matchSubmissionID ?? "", on: app.db))
            let paired = try #require(try await pairedOpponent(for: match, on: app.db))
            let chosen = ChosenOpponent(
                champion: paired.away, identity: JobOpponent.submissionIdentity(try paired.away.requireID()))
            let matchID = try match.requireID()
            try await openMatch(
                testSetupID: setupID, submissionID: matchID, opponent: chosen,
                seed: JobOpponent.matchSeed(submissionID: matchID, opponentIdentity: chosen.identity),
                round: slot.round, on: app.db)
            try await recordTournamentMatch(submission: match, collection: homeWins(), on: app.db)

            let finished = try #require(try await APITournamentRun.find(run.requireID(), on: app.db))
            #expect(finished.status == APITournamentRun.Status.complete)
            #expect(finished.winnerUserID != nil)
            let record = try await APIClassAchievement.query(on: app.db)
                .filter(\.$testSetupID == setupID)
                .filter(\.$achievementID == ActivityAuthoring.seededTournamentRecordID)
                .first()
            #expect(record == nil)
        }
    }

    @Test func mcpStartsNoPerGroupRun() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            try await joinEveryone(f)
            let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: f.setup.courseID)
            let assignment = try #require(try await APIAssignment.find(f.assignmentID, on: app.db))
            let context = ToolContext(
                request: makeTestRequest(on: app), subject: "tester", grantedScopes: [.read, .write])
            await #expect(throws: MCPToolError.self) {
                _ = try await RunTournamentTool().execute(
                    .init(assignmentPublicID: assignment.publicID, schedule: nil), context)
            }
            #expect(try await APITournamentRun.query(on: app.db).count() == 0)
        }
    }

    private func homeWins() -> TestOutcomeCollection {
        let outcome = TestOutcome(
            testName: "match", testClass: nil, tier: .pub, status: .pass, shortResult: "", longResult: nil,
            score: 1, metric: 1, executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1,
            isFirstPassSuccess: false)
        return TestOutcomeCollection(
            submissionID: "x", testSetupID: "t", attemptNumber: 1, buildStatus: .passed, compilerOutput: nil,
            outcomes: [outcome], totalTests: 1, passCount: 1, failCount: 0, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 1, runnerVersion: "test", timestamp: Date())
    }
}
