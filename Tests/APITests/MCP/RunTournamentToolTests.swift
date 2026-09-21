// Tests/APITests/MCP/RunTournamentToolTests.swift
//
// run_tournament: starts a run on a tournament kind and reports its shape
// without naming a student; refuses an unknown schedule, any other kind, and
// a class with fewer than two entrants; instructor-level.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct RunTournamentToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read, .write]
        )
    }

    private func manifest(kind: ActivityKind) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            activity: ClassActivity(kind: kind))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    /// The tester's course with one assignment of `kind` and `students`
    /// enrolled students, each with a complete submission.
    private func fixture(on app: Application, kind: ActivityKind, students: Int) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS135", name: "Designing Programs")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_cup", courseID: courseID, manifest: try manifest(kind: kind))
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "setup_cup", courseID: courseID, title: "Cup")
        for index in 1...max(students, 1) where students > 0 {
            let student = try await makeTestUser(on: app, username: "cup_s\(index)", role: "student")
            try await makeTestEnrollment(on: app, userID: student.requireID(), courseID: courseID)
            try await APISubmission(
                id: "cup_sub_\(index)", testSetupID: "setup_cup", zipPath: "/tmp/cup_\(index).zip",
                attemptNumber: 1, status: SubmissionStatus.complete.rawValue, filename: "s.py",
                userID: try student.requireID()
            ).save(on: app.db)
        }
        return assignment
    }

    @Test func startsARunAndReportsItsShape() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, kind: .elimination, students: 3)
            let out = try await RunTournamentTool().execute(
                .init(assignmentPublicID: assignment.publicID, schedule: nil), context(app))
            #expect(out.schedule == "bracket")
            #expect(out.entrantCount == 3)
            #expect(out.roundCount == 2)
            #expect(out.status == "running")
            #expect(out.leaderboardPath == "/testsetups/setup_cup/leaderboard")
            let run = try #require(try await APITournamentRun.find(UUID(uuidString: out.tournamentID), on: app.db))
            #expect(run.entrants.count == 3)
            #expect(
                try await APISubmission.query(on: app.db)
                    .filter(\.$kind == APISubmission.Kind.tournamentMatch).count() == 1)

            let swiss = try await RunTournamentTool().execute(
                .init(assignmentPublicID: assignment.publicID, schedule: "swiss"), context(app))
            #expect(swiss.schedule == "swiss")
            #expect(
                try await APITournamentRun.find(UUID(uuidString: out.tournamentID), on: app.db)?.status == "superseded")
        }
    }

    @Test func refusesAnUnknownScheduleAndTooFewEntrants() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, kind: .elimination, students: 1)
            await #expect(throws: MCPToolError.self) {
                _ = try await RunTournamentTool().execute(
                    .init(assignmentPublicID: assignment.publicID, schedule: "ladder"), context(app))
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await RunTournamentTool().execute(
                    .init(assignmentPublicID: assignment.publicID, schedule: "bracket"), context(app))
            }
            #expect(try await APITournamentRun.query(on: app.db).count() == 0)
        }
    }

    @Test func refusesAnyOtherKind() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, kind: .roundRobin, students: 3)
            await #expect(throws: MCPToolError.self) {
                _ = try await RunTournamentTool().execute(
                    .init(assignmentPublicID: assignment.publicID, schedule: nil), context(app))
            }
            #expect(try await APITournamentRun.query(on: app.db).count() == 0)
        }
    }
}
