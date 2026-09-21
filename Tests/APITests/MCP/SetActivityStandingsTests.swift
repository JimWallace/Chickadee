// Tests/APITests/MCP/SetActivityStandingsTests.swift
//
// set_activity for a round robin: the kind seeds the standings-leader record
// INSTEAD of the leaderboard record (its page ranks on standings, not a
// metric), reports its source, is refused on a browser-graded assignment,
// and swaps its seeded record back when the kind changes to a metric kind.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct SetActivityStandingsTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read, .write]
        )
    }

    private func fixture(on app: Application, gradingMode: String) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS135", name: "Designing Programs")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(
            on: app, id: "setup_robin", courseID: courseID,
            manifest: #"{"schemaVersion":1,"gradingMode":"\#(gradingMode)","testSuites":[],"timeLimitSeconds":10}"#)
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_robin", courseID: courseID, title: "Robin")
    }

    private func manifest(on app: Application) async throws -> TestProperties {
        let setup = try #require(try await APITestSetup.find("setup_robin", on: app.db))
        return try #require(setup.decodedManifest())
    }

    @Test func theRoundRobinSeedsTheLeaderRecordInsteadOfTheMetricRecord() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, gradingMode: "worker")
            let out = try await SetActivityTool().execute(
                .init(assignmentPublicID: assignment.publicID, kind: "roundRobin", leaderboardVisibility: nil),
                context(app))
            #expect(out.opponentSource == "classmates")
            let props = try await manifest(on: app)
            #expect(props.achievements.contains { $0.id == ActivityAuthoring.seededWinnerRecordID })
            #expect(!props.achievements.contains { $0.id == ActivityAuthoring.seededRecordID })
            #expect(props.achievements.filter { $0.recordDimension == .tournamentWinner }.count == 1)
            // The built-ins were curated alongside it, as the editor's first
            // Save would have done.
            #expect(props.builtInAchievementsSeeded)

            // Switching to a metric kind swaps the seeded records.
            _ = try await SetActivityTool().execute(
                .init(assignmentPublicID: assignment.publicID, kind: "bestMetric", leaderboardVisibility: nil),
                context(app))
            let switched = try await manifest(on: app)
            #expect(!switched.achievements.contains { $0.id == ActivityAuthoring.seededWinnerRecordID })
            #expect(switched.achievements.contains { $0.id == ActivityAuthoring.seededRecordID })
        }
    }

    /// Worker-only by construction, like the hill.
    @Test func theRoundRobinIsRefusedOnABrowserGradedAssignment() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, gradingMode: "browser")
            await #expect(throws: MCPToolError.self) {
                _ = try await SetActivityTool().execute(
                    .init(assignmentPublicID: assignment.publicID, kind: "roundRobin", leaderboardVisibility: nil),
                    context(app))
            }
            #expect(try await manifest(on: app).activity == nil)
        }
    }
}
