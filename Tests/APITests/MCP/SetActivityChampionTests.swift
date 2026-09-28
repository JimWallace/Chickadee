// Tests/APITests/MCP/SetActivityChampionTests.swift
//
// set_activity for king of the hill: the kind seeds a `champion` record
// beside the leaderboard record, is refused on a browser-graded assignment
// with or without a bot, reports its source, and takes its seeded record
// with it when the kind changes.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct SetActivityChampionTests {
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
            on: app, id: "setup_hill", courseID: courseID,
            manifest: #"{"schemaVersion":1,"gradingMode":"\#(gradingMode)","testSuites":[],"timeLimitSeconds":10}"#)
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_hill", courseID: courseID, title: "Hill")
    }

    private func manifest(on app: Application) async throws -> TestProperties {
        let setup = try #require(try await APITestSetup.find("setup_hill", on: app.db))
        return try #require(setup.decodedManifest())
    }

    @Test func theHillKindSeedsBothRecordsAndReportsItsSource() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, gradingMode: "worker")
            let out = try await SetActivityTool().execute(
                .init(assignmentPublicID: assignment.publicID, kind: "kingOfTheHill", leaderboardVisibility: nil),
                context(app))
            #expect(out.opponentSource == "champion")
            #expect(out.recordAchievementSeeded)
            let props = try await manifest(on: app)
            #expect(props.achievements.contains { $0.id == ActivityAuthoring.seededRecordID })
            #expect(props.achievements.contains { $0.id == ActivityAuthoring.seededChampionRecordID })
            #expect(props.achievements.filter { $0.recordDimension == .champion }.count == 1)

            // Switching to a kind with no hill takes the seeded champion
            // record away and keeps the leaderboard record.
            _ = try await SetActivityTool().execute(
                .init(assignmentPublicID: assignment.publicID, kind: "bestMetric", leaderboardVisibility: nil),
                context(app))
            let switched = try await manifest(on: app)
            #expect(!switched.achievements.contains { $0.id == ActivityAuthoring.seededChampionRecordID })
            #expect(switched.achievements.contains { $0.id == ActivityAuthoring.seededRecordID })
        }
    }

    /// The hill is worker-only by construction: refused on a browser-graded
    /// assignment even with no bot chosen, unlike the bot kind.
    @Test func theHillKindIsRefusedOnABrowserGradedAssignment() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, gradingMode: "browser")
            await #expect(throws: MCPToolError.self) {
                _ = try await SetActivityTool().execute(
                    .init(assignmentPublicID: assignment.publicID, kind: "kingOfTheHill", leaderboardVisibility: nil),
                    context(app))
            }
            #expect(try await manifest(on: app).activity == nil)
        }
    }
}
