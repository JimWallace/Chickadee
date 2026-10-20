// Tests for SetTimeLimitTool (set an assignment's default per-test execution
// time limit), backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct SetTimeLimitToolTests {
    private let manifest =
        TestManifests.workerEmpty

    private func fixture(on app: Application) async throws -> APIAssignment {
        try await seedMCPAssignment(
            on: app, setupID: "setup_tl", manifest: manifest)
    }

    @Test func setsDefaultTimeLimitWithoutClosing() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            #expect(assignment.visibility == .open)

            let out = try await SetTimeLimitTool().execute(
                .init(assignmentPublicID: assignment.publicID, seconds: 30), mcpContext(app))
            #expect(out.timeLimitSeconds == 30)

            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(setup.decodedManifest()?.timeLimitSeconds == 30)
            // Metadata-style edit: the assignment stays open, not closed.
            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reloaded.visibility == .open)
        }
    }

    @Test func rejectsZero() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetTimeLimitTool().execute(
                    .init(assignmentPublicID: assignment.publicID, seconds: 0), mcpContext(app))
            }
        }
    }

    @Test func rejectsNegative() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetTimeLimitTool().execute(
                    .init(assignmentPublicID: assignment.publicID, seconds: -5), mcpContext(app))
            }
        }
    }

    @Test func rejectsAboveMax() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetTimeLimitTool().execute(
                    .init(assignmentPublicID: assignment.publicID, seconds: 601), mcpContext(app))
            }
        }
    }

    @Test func acceptsBoundaryValues() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let low = try await SetTimeLimitTool().execute(
                .init(assignmentPublicID: assignment.publicID, seconds: 1), mcpContext(app))
            #expect(low.timeLimitSeconds == 1)
            let high = try await SetTimeLimitTool().execute(
                .init(assignmentPublicID: assignment.publicID, seconds: 600), mcpContext(app))
            #expect(high.timeLimitSeconds == 600)
        }
    }
}
