// Tests for GetAchievementsTool / UpdateAchievementsTool (read + replace an
// assignment's composable Achievements list), backed by a real test database.
// Achievements are display-only, so updating never rebuilds the zip, retests,
// or closes the assignment — these exercise the manifest round-trip + the
// shared validation that the web editor also runs.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct AchievementsToolsTests {
    private func context(_ app: Application, scopes: Set<ContentScope>) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: scopes)
    }

    private let emptyManifest = #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#

    /// Course + enrolled instructor + setup (empty manifest) + assignment.
    private func fixture(on app: Application) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_ach", courseID: courseID, manifest: emptyManifest)
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_ach", courseID: courseID, title: "Lab")
    }

    private func authored(_ setupID: String, on db: Database) async throws -> [Achievement] {
        let setup = try #require(try await APITestSetup.find(setupID, on: db))
        let props = try JSONDecoder().decode(TestProperties.self, from: Data(setup.manifest.utf8))
        return props.achievements
    }

    @Test func getReturnsBuiltInDefaultsBeforeCuration() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let output = try await GetAchievementsTool().execute(
                .init(assignmentPublicID: assignment.publicID), context(app, scopes: [.read]))
            #expect(output.achievements.count == BuiltInAchievements.all.count)
            #expect(output.achievements.contains { $0.name == "Ace" && $0.scope == "individual" })
            #expect(output.achievements.contains { $0.scope == "record" })
        }
    }

    @Test func updateReplacesListWholesaleAndSeedsBuiltIns() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let rows: [AchievementRow] = [
                AchievementRow(
                    name: "Mastery", scope: "classWide", match: "all",
                    conditions: [ConditionRow(signal: "grade", comparator: "atLeast", value: 80)],
                    classPercent: 75, points: 5),
                AchievementRow(
                    name: "Sharpshooter", scope: "individual",
                    conditions: [ConditionRow(signal: "grade", comparator: "atLeast", value: 90)]),
                AchievementRow(name: "Speedy", scope: "record", recordDimension: "fastest"),
            ]
            let output = try await UpdateAchievementsTool().execute(
                .init(assignmentPublicID: assignment.publicID, achievements: rows),
                context(app, scopes: [.write]))
            #expect(output.achievements.map(\.name) == ["Mastery", "Sharpshooter", "Speedy"])

            // Persisted to the manifest, with the class goal's reward parameters.
            let saved = try await authored("setup_ach", on: app.db)
            #expect(saved.count == 3)
            #expect(saved.contains { $0.name == "Mastery" && $0.classFraction == 0.75 && $0.reward.points == 5 })

            // Built-ins are now seeded — GET returns only the curated three.
            let reread = try await GetAchievementsTool().execute(
                .init(assignmentPublicID: assignment.publicID), context(app, scopes: [.read]))
            #expect(reread.achievements.map(\.name) == ["Mastery", "Sharpshooter", "Speedy"])
        }
    }

    @Test func updateWithEmptyArrayClearsAll() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await UpdateAchievementsTool().execute(
                .init(
                    assignmentPublicID: assignment.publicID,
                    achievements: [AchievementRow(name: "Ace", scope: "individual")]),
                context(app, scopes: [.write]))
            _ = try await UpdateAchievementsTool().execute(
                .init(assignmentPublicID: assignment.publicID, achievements: []),
                context(app, scopes: [.write]))
            #expect(try await authored("setup_ach", on: app.db).isEmpty)
        }
    }

    @Test func invalidScopeThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateAchievementsTool().execute(
                    .init(
                        assignmentPublicID: assignment.publicID,
                        achievements: [AchievementRow(name: "Bad", scope: "nonsense")]),
                    context(app, scopes: [.write]))
            }
        }
    }

    @Test func classWideWithoutShareThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateAchievementsTool().execute(
                    .init(
                        assignmentPublicID: assignment.publicID,
                        achievements: [AchievementRow(name: "Goal", scope: "classWide")]),
                    context(app, scopes: [.write]))
            }
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            _ = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestSetup(on: app, id: "setup_ach", courseID: courseID, manifest: emptyManifest)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_ach", courseID: courseID, title: "Lab")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetAchievementsTool().execute(
                    .init(assignmentPublicID: assignment.publicID), context(app, scopes: [.read]))
            }
        }
    }
}
